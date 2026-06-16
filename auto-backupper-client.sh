#!/usr/bin/env bash
export PATH=/sbin:/opt/bin:/usr/local/bin:/usr/contrib/bin:/bin:/usr/bin:/usr/sbin:/usr/bin/X11
# ==============================================================================
# AUTO-BACKUPPER-CLIENT
# ==============================================================================
# Desktop backup client for the Auto-Backupper suite (Linux & macOS).
#
# Runs on family/client Linux and macOS machines to produce TWO archives per
# machine -- a USER-data archive and a SYSTEM-state archive -- in the suite's
# exact FamilyBackups layout (./-rooted tar.gz + dated .checksums), then deliver
# them to one or more destinations (local/external drive, a mounted SMB/NFS
# share, or a push to the central server over rsync-over-SSH, typically across
# Tailscale/VPN). It can also restore archives locally. Output drops straight
# into the server's BACKUP_BASE/shares/FamilyBackups/<member>/{users,systems}/,
# so the server's watchtower/auto-restorer treat it as a first-class backup.
#
# This is the Linux/macOS counterpart to auto-backupper-client.py (which is the
# cross-platform client and the only option on Windows -- bash does not run
# natively there). Unlike the server tools it does NOT require root: it degrades
# to the current user's data with warnings when unprivileged.
#
# USAGE:
#   auto-backupper-client.sh --backup [users|system|both]
#   auto-backupper-client.sh --restore ARCHIVE --target PATH [--only ./users/p]
#   auto-backupper-client.sh --list [PATTERN] | --verify ARCHIVE | --verify-all
#   auto-backupper-client.sh --inspect ARCHIVE
#   auto-backupper-client.sh --install-schedule | --uninstall-schedule
#
# OPTIONS:
#   -c, --config FILE   Config file (platform default if omitted)
#   --member NAME       Override the FamilyBackups <member> directory name
#   --dest NAME         Restrict delivery to named dest(s) (repeatable)
#   --target PATH       Restore destination
#   --only PATH         Partial-restore member (repeatable; leading ./ honored)
#   --dry-run --no-verify --force --debug -h/--help
#
# DEPENDENCIES:
#   bash 4+, tar, rsync; a SHA-256 tool (sha256sum or `shasum -a 256`).
#   Optional: pigz (faster compression), ssh (for the rsync_ssh destination),
#   systemctl/launchd/crontab (for --install-schedule).
# ==============================================================================
# LICENSE: GPLv3
# ==============================================================================

# NOTE: the server scripts use `set -Eeuo pipefail`. This client uses only
# `pipefail` (no `-e`, no `-u`): it is an interactive tool (restore prompts)
# with many best-effort capability probes whose non-zero exits are expected, so
# a global errexit would abort legitimate flows. `-u` is dropped too because the
# many optional/empty arrays here would otherwise inject spurious empty args
# (e.g. into tar) on bash builds that predate safe empty-array expansion -- this
# keeps the script portable down to the macOS stock bash. Every global is
# initialized explicitly, so unbound-variable safety is preserved by hand.
set -o pipefail

# ==============================================================================
# 1. BOOTSTRAP: IDENTITY & PER-OS PATHS
# ==============================================================================
CHECKSUM_DIR=".checksums"
TAR_EXT=".tar.gz"
CDATE="$(date +%Y%m%d)"   # LOCAL date, matches the suite's create_archive

# OS detection (Linux / macOS only).
if [[ "${OSTYPE:-}" == darwin* ]]; then
	OS_TYPE="macos"
else
	OS_TYPE="linux"
fi

# Member default: UPPERCASE short hostname (the suite's canonical casing -- a
# case-variant <member> dir creates a parallel tree the server can't reconcile).
# cfg MEMBER_NAME and then --member override this.
_DEFAULT_MEMBER="$(hostname 2>/dev/null | cut -d. -f1 | tr '[:lower:]' '[:upper:]')"
[[ -z "$_DEFAULT_MEMBER" ]] && _DEFAULT_MEMBER="UNKNOWN"

LOG_MAX_SIZE="$((10 * 1024 * 1024))"
LOG_BACKUPS=5

# Per-OS default config location (read-only access is fine for non-root).
if [[ "$OS_TYPE" == "macos" ]]; then
	_SYS_BASE_DIR="/Library/Application Support/auto-backupper"
else
	_SYS_BASE_DIR="/etc/auto-backupper"
fi
DEFAULT_CONFIG_FILE="${_SYS_BASE_DIR}/auto_backupper_client.cfg"

# This client is designed to run UNPRIVILEGED (it degrades to the current user's
# data). When not root, the system base dirs (/etc, /Library) aren't writable,
# so the lock/state/log there would silently fail and the backup would no-op.
# Pick a user-writable base when non-root; root keeps the system locations.
# (Use `id -u` directly — is_privileged() is defined later in the file.)
if [[ "$(id -u 2>/dev/null || echo 0)" -eq 0 ]]; then
	_BASE_DIR="$_SYS_BASE_DIR"
	LOGFILE="/var/log/auto-backupper-client.log"
else
	_BASE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/auto-backupper"
	LOGFILE="${_BASE_DIR}/auto-backupper-client.log"
fi
LOCKDIR="${_BASE_DIR}/auto-backupper-client.lock.d"
STATE_DIR="${_BASE_DIR}/state"

# Runtime globals.
CURRENT_ARCHIVE_FILE=""
LOCK_HELD=0
MEMBER="$_DEFAULT_MEMBER"
MODE=""
BACKUP_SCOPE="both"
RESTORE_ARCHIVE=""
RESTORE_TARGET=""
ONLY_PATHS=()
LIST_PATTERN="*"
DEST_FILTER=()
NO_VERIFY=0
FORCE=0
CLI_DRY_RUN=""
CLI_DEBUG=""
STAGING_BASE=""
PRODUCED_ARCHIVES=()
MANIFEST_SOURCES=()
MANIFEST_STATUS=""
MANIFEST_NOTES=()
SESSION_MANIFEST=""

# ==============================================================================
# 2. DEFAULT CONFIGURATION (cfg is sourced and overrides these)
# ==============================================================================
MEMBER_NAME=""
DRY_RUN="false"
LOG_VERBOSITY="info"

BACKUP_USERS="true"
BACKUP_SYSTEM="true"
INCLUDE_ALL_USERS="false"
USERS_INCLUDE=()
USER_INCLUDE_FOLDERS=()
EXCLUDES=()
SYSTEM_EXTRA_PATHS=()

PRESERVE_POSIX_META="true"

DEST_NAMES=()
DEST_TYPES=()
DEST_PATHS=()
RSYNC_SSH_TARGET=""
RSYNC_SSH_IDENTITY=""
RSYNC_SSH_PORT="22"

SERVER_BACKUP_BASE=""
STAGING_DIR=""
LOCAL_KEEP="2"
ROTATE_DAYS="0"
VERIFY_AFTER_CREATE="true"
VERIFY_BEFORE_RESTORE="true"

SCHEDULE_CADENCE="daily"
SCHEDULE_TIME="02:30"
SCHEDULE_DAY="Sunday"
SCHEDULE_WAKE="true"

NOTIFY_WEBHOOK_URL=""
NOTIFY_WEBHOOK_FORMAT=""

CPU_THREADS="1"
LOADED_CONFIG=""

# ==============================================================================
# 3. LOGGING (copytruncate rotation + verbosity tiers; UTC timestamps)
# ==============================================================================
rotate_logs() {
	local logfile="$1" max_size="$2" backups="$3"
	[[ -f "$logfile" ]] || return 0
	local current_size
	if [[ "$OS_TYPE" == "macos" ]]; then
		current_size=$(stat -f%z "$logfile" 2>/dev/null || echo 0)
	else
		current_size=$(stat -c%s "$logfile" 2>/dev/null || echo 0)
	fi
	[[ "$current_size" -ge "$max_size" ]] || return 0
	[[ -f "${logfile}.${backups}" ]] && rm -f "${logfile}.${backups}"
	local i
	for ((i = backups - 1; i >= 1; i--)); do
		[[ -f "${logfile}.${i}" ]] && mv "${logfile}.${i}" "${logfile}.$((i + 1))"
	done
	cp "$logfile" "${logfile}.1" 2>/dev/null && : >"$logfile" 2>/dev/null
	chmod 644 "$logfile" 2>/dev/null || true
}

_log_verbosity_threshold() {
	case "${LOG_VERBOSITY:-info}" in
		error) echo 2 ;; phase) echo 3 ;; info) echo 4 ;; debug) echo 99 ;; *) echo 4 ;;
	esac
}

_log_level_for() {
	case "$1" in
		FATAL*|CRITICAL*|ERROR:*|ERROR\ *|WARN:*|WARN\ *|"  WARN:"*|"  ERROR:"*) echo 2 ;;
		"==="*|Phase:*|Archiving:*|ACTION:*|RECOVERY:*|SUCCESS:*|NOTIFY*|Delivering:*) echo 3 ;;
		*) echo 4 ;;
	esac
}

log() {
	local msg="$1" lvl thresh line
	lvl=$(_log_level_for "$msg")
	thresh=$(_log_verbosity_threshold)
	if ((lvl <= thresh)); then
		line="$(date -u '+%Y-%m-%dT%H:%M:%SZ') ${msg}"
		printf '%s\n' "$line"
		printf '%s\n' "$line" >>"$LOGFILE" 2>/dev/null || true
	fi
	rotate_logs "$LOGFILE" "$LOG_MAX_SIZE" "$LOG_BACKUPS"
}

setup_logging() {
	# Fall back to a writable dir if the system location isn't writable.
	if ! mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null || ! { : >>"$LOGFILE"; } 2>/dev/null; then
		LOGFILE="${TMPDIR:-/tmp}/auto-backupper-client.log"
	fi
	rotate_logs "$LOGFILE" "$LOG_MAX_SIZE" "$LOG_BACKUPS"
	touch "$LOGFILE" 2>/dev/null || true
}

# ==============================================================================
# 4. PORTABLE HELPERS (macOS lacks sha256sum / timeout / GNU tar -S)
# ==============================================================================
# Resolved SHA-256 binary (a command string, possibly with args, so `timeout`
# can wrap it -- timeout cannot invoke a shell function). Set by _resolve_tar_tools.
HASH_BIN=""

_sha256() {
	# Echo the lowercase 64-hex digest of "$1", or nothing on failure.
	[[ -n "$HASH_BIN" ]] || return 0
	# shellcheck disable=SC2086  (intentional word-split for "shasum -a 256")
	$HASH_BIN "$1" 2>/dev/null | awk '{print $1}'
}

_with_timeout() {
	# _with_timeout SECONDS cmd...   (no-op wrapper when `timeout` is absent)
	local secs="$1"; shift
	if command -v timeout >/dev/null 2>&1; then
		timeout "$secs" "$@"
	elif command -v gtimeout >/dev/null 2>&1; then
		gtimeout "$secs" "$@"
	else
		"$@"
	fi
}

is_privileged() { [[ "$(id -u 2>/dev/null || echo 1)" -eq 0 ]]; }

ensure_dir() { mkdir -p "$1"; }

is_dry() { [[ "$DRY_RUN" == "true" ]]; }

# Compression program (matches the suite). pigz if present, else gzip.
_resolve_tar_tools() {
	local pigz_threads=""
	if [[ "$CPU_THREADS" != "all" && "$CPU_THREADS" =~ ^[0-9]+$ ]]; then
		pigz_threads="-p ${CPU_THREADS}"
	fi
	if command -v pigz >/dev/null 2>&1; then
		TAR_CMD="pigz ${pigz_threads} --best"
	else
		TAR_CMD="gzip"
	fi
	# Resolve a SHA-256 binary string (macOS has no sha256sum; shasum -a 256).
	if command -v sha256sum >/dev/null 2>&1; then
		HASH_BIN="sha256sum"
	elif command -v shasum >/dev/null 2>&1; then
		HASH_BIN="shasum -a 256"
	elif command -v gsha256sum >/dev/null 2>&1; then
		HASH_BIN="gsha256sum"
	else
		HASH_BIN=""
	fi
	# GNU tar supports sparse (-S) on create; bsdtar (stock macOS) does not.
	TAR_SPARSE=()
	if tar --version 2>/dev/null | grep -qi "GNU tar"; then
		TAR_SPARSE=(-S)
	fi
	TAR_VERBOSE_FLAG=""
	[[ "${LOG_VERBOSITY:-info}" == "debug" ]] && TAR_VERBOSE_FLAG="v"
}

# ==============================================================================
# 5. NOTIFICATIONS (log always; best-effort OS-native + optional webhook)
# ==============================================================================
_native_notify() {
	local title="$2" message="$3"
	if [[ "$OS_TYPE" == "macos" ]] && command -v osascript >/dev/null 2>&1; then
		osascript -e "display notification \"${message}\" with title \"${title}\"" >/dev/null 2>&1 || true
	elif command -v notify-send >/dev/null 2>&1; then
		notify-send "$title" "$message" >/dev/null 2>&1 || true
	fi
}

_webhook_notify() {
	local level="$1" title="$2" message="$3"
	[[ -z "$NOTIFY_WEBHOOK_URL" ]] && return 0
	command -v curl >/dev/null 2>&1 || return 0
	local host="$MEMBER" fmt="$NOTIFY_WEBHOOK_FORMAT"
	if [[ -z "$fmt" ]]; then
		case "$NOTIFY_WEBHOOK_URL" in
			*discord*) fmt="discord" ;; *slack*) fmt="slack" ;; *) fmt="generic" ;;
		esac
	fi
	local prefix="[INFO]"
	case "$level" in alert) prefix="[ALERT]";; warning) prefix="[WARN]";; normal) prefix="[OK]";; esac
	local body
	case "$fmt" in
		discord) body="{\"content\":\"${prefix} **${title}**\\n${message} (${host})\"}" ;;
		slack)   body="{\"text\":\"*${prefix} ${title}*\\n${message}\\n_host: ${host}_\"}" ;;
		*)       body="{\"host\":\"${host}\",\"level\":\"${level}\",\"title\":\"${title}\",\"message\":\"${message}\"}" ;;
	esac
	curl -fsS --max-time 10 -H "Content-Type: application/json" -d "$body" "$NOTIFY_WEBHOOK_URL" >/dev/null 2>&1 || true
}

send_notify() {
	local level="$1" title="$2" message="$3"
	[[ "$level" == "alert" || "$level" == "warning" || "$level" == "normal" ]] && log "NOTIFY [$level]: $title - $message"
	is_dry && return 0
	_native_notify "$level" "$title" "$message"
	_webhook_notify "$level" "$title" "$message"
}

# ==============================================================================
# 6. CHECKSUM + ARCHIVE LAYER (dated _YYYYMMDD.sha256 contract)
# ==============================================================================
checksum_dir_for() {
	local file="$1" base="${2%/}"
	local rel="${file#"$base"/}"
	echo "${base}/${CHECKSUM_DIR}/$(dirname "$rel")"
}

# Echo the newest dated checksum sibling for a data file; return 1 if none.
checksum_find_path() {
	local file="$1" base="${2%/}"
	local rel="${file#"$base"/}"
	local chk_dir="${base}/${CHECKSUM_DIR}/$(dirname "$rel")"
	local name; name="$(basename "$rel")"
	local matches=() m
	shopt -s nullglob
	for m in "${chk_dir}/${name}"_[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9].sha256; do matches+=("$m"); done
	shopt -u nullglob
	[[ ${#matches[@]} -eq 0 ]] && return 1
	printf '%s\n' "${matches[@]}" | sort | tail -1
	return 0
}

write_checksum() {
	local file="$1" base="${2%/}"
	local rel="${file#"$base"/}"
	local chk_dir="${base}/${CHECKSUM_DIR}/$(dirname "$rel")"
	local name; name="$(basename "$rel")"
	ensure_dir "$chk_dir"
	shopt -s nullglob
	local old
	for old in "${chk_dir}/${name}"_[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9].sha256; do rm -f "$old"; done
	shopt -u nullglob
	local chk="${chk_dir}/${name}_${CDATE}.sha256" tmp digest
	tmp="${chk}.tmp.$$"
	digest="$(_sha256 "$file")"
	[[ -z "$digest" ]] && return 1
	# Bare 64-hex + single newline (matches the suite's sha256sum|awk output).
	printf '%s\n' "$digest" >"$tmp" && mv -f "$tmp" "$chk" || { rm -f "$tmp"; return 1; }
}

# Return token: OK / NO_FILE / NO_CHECKSUM / MISMATCH / HASH_ERROR
verify_file() {
	local file="$1" base="${2%/}"
	[[ ! -f "$file" ]] && { echo NO_FILE; return; }
	local chk
	if ! chk="$(checksum_find_path "$file" "$base")"; then echo NO_CHECKSUM; return; fi
	local exp act
	exp="$(tr -d ' \t\r\n' <"$chk" 2>/dev/null || true)"
	# Wrap the resolved hash binary in timeout (a hung mount fails instead of
	# blocking). HASH_BIN is unquoted so "shasum -a 256" splits into args.
	# shellcheck disable=SC2086
	[[ -n "$HASH_BIN" ]] && act="$(_with_timeout 600 $HASH_BIN "$file" 2>/dev/null | awk '{print $1}')"
	[[ -z "${act:-}" ]] && { echo HASH_ERROR; return; }
	[[ "$exp" == "$act" ]] && echo OK || echo MISMATCH
}

_client_write_manifest() {
	local out="$1" archive_name="$2" base_dir="$3"
	{
		echo "# Auto-Backupper archive manifest"
		echo "archive: $archive_name"
		echo "created_at: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
		echo "host: $MEMBER"
		echo "host_long: $(hostname 2>/dev/null || echo unknown)"
		echo "os: $OS_TYPE"
		echo "kernel: $(uname -srm 2>/dev/null || echo unknown)"
		echo "base_dir: $base_dir"
		[[ -n "$MANIFEST_STATUS" ]] && echo "status: $MANIFEST_STATUS"
		echo "source_paths:"
		local p
		for p in "${MANIFEST_SOURCES[@]}"; do [[ -n "$p" ]] && echo "  - $p"; done
		if [[ ${#MANIFEST_NOTES[@]} -gt 0 ]]; then
			echo "notes:"
			for p in "${MANIFEST_NOTES[@]}"; do echo "  - $p"; done
		fi
		echo "tools:"
		echo "  tar: $(tar --version 2>/dev/null | head -1 || echo unknown)"
		echo "  compress: ${TAR_CMD:-unknown}"
		echo "  bash: ${BASH_VERSION:-unknown}"
	} >"$out"
}

# client_create_archive ARCHIVE MANIFEST_BASE_LABEL TARARGS...
# TARARGS is the tar segment list: excludes (--exclude=...) then one or more
# `-C <dir> <member>` groups. Members are ./-rooted to match the contract.
client_create_archive() {
	local archive="$1" mbase="$2"; shift 2
	local targs=("$@")
	ensure_dir "$(dirname "$archive")"
	CURRENT_ARCHIVE_FILE="$archive"
	log "Archiving: $archive"
	if is_dry; then
		log "[DRY] tar ${TAR_SPARSE[*]:-} -c -f $archive ${targs[*]}"
		CURRENT_ARCHIVE_FILE=""
		PRODUCED_ARCHIVES+=("$archive")
		return 0
	fi
	local partial="${archive}.abpartial"
	local manifest_dir manifest_args=()
	manifest_dir="$(mktemp -d "${TMPDIR:-/tmp}/abclient_manifest.XXXXXX" 2>/dev/null || echo "")"
	if [[ -n "$manifest_dir" ]]; then
		mkdir -p "${manifest_dir}/.auto-backupper" 2>/dev/null || true
		if _client_write_manifest "${manifest_dir}/.auto-backupper/MANIFEST.txt" "$(basename "$archive")" "$mbase" 2>/dev/null; then
			manifest_args=(-C "$manifest_dir" .auto-backupper/MANIFEST.txt)
		else
			rm -rf "$manifest_dir"; manifest_dir=""
		fi
	fi
	local rc=0
	tar "${TAR_SPARSE[@]}" --use-compress-program="$TAR_CMD" "-c${TAR_VERBOSE_FLAG}f" "$partial" \
		"${targs[@]}" "${manifest_args[@]}" || rc=$?
	[[ -n "$manifest_dir" ]] && rm -rf "$manifest_dir"
	if [[ $rc -ne 0 ]]; then
		log "ERROR: Archive failed: $archive"
		send_notify "alert" "Backup Failed" "$archive"
		rm -f "$partial"
		CURRENT_ARCHIVE_FILE=""
		return 1
	fi
	mv -f "$partial" "$archive"
	write_checksum "$archive" "$STAGING_BASE" || log "WARN: Checksum write failed for ${archive}"
	printf '%s\n' "$archive" >>"$SESSION_MANIFEST" 2>/dev/null || true
	PRODUCED_ARCHIVES+=("$archive")
	CURRENT_ARCHIVE_FILE=""
	return 0
}

# ==============================================================================
# 7. COLLECTION LAYER (per-OS user data + system state)
# ==============================================================================
_default_user_folders() {
	if [[ "$OS_TYPE" == "macos" ]]; then
		printf '%s\n' Documents Desktop Pictures Movies Music Downloads "Library/Preferences" "Library/Application Support"
	fi
	# Linux: none => whole home minus excludes.
}

_default_excludes() {
	printf '%s\n' "*/.cache/*" "*/Cache/*" "*/Caches/*" "*/Code Cache/*" "*/GPUCache/*" "*.tmp" "*/.DS_Store" "Thumbs.db"
	if [[ "$OS_TYPE" == "macos" ]]; then
		printf '%s\n' "*/Library/Caches/*" "*.app" "*/Library/Application Support/MobileSync/*"
	else
		printf '%s\n' "*/.local/share/Trash/*" "*/.thumbnails/*" "*/.mozilla/firefox/*/cache2/*"
	fi
}

# Echo "user|home" lines.
detect_homes() {
	if [[ ${#USERS_INCLUDE[@]} -gt 0 ]]; then
		local u
		for u in "${USERS_INCLUDE[@]}"; do
			if [[ -d "$u" ]]; then
				echo "$(basename "$u")|$u"
			else
				local h; h="$(_home_for_user "$u")"
				[[ -d "$h" ]] && echo "${u}|${h}"
			fi
		done
		return
	fi
	if [[ "$INCLUDE_ALL_USERS" == "true" ]] && is_privileged; then
		local root_dir="/home"; [[ "$OS_TYPE" == "macos" ]] && root_dir="/Users"
		local d name
		if [[ -d "$root_dir" ]]; then
			for d in "$root_dir"/*/; do
				name="$(basename "$d")"
				[[ "$OS_TYPE" == "macos" && ( "$name" == "Shared" || "$name" == "Guest" ) ]] && continue
				echo "${name}|${d%/}"
			done
			return
		fi
	fi
	echo "$(basename "$HOME")|$HOME"
}

_home_for_user() {
	if [[ "$OS_TYPE" == "macos" ]]; then echo "/Users/$1"; else echo "/home/$1"; fi
}

# Populate the global USER_TARGS array with tar segments for the USER archive.
_add_exclude() {
	# Append --exclude for a glob. A "X/*" pattern also excludes the directory
	# X itself, so an excluded cache dir doesn't leave an empty entry behind.
	local ex="$1"
	[[ -z "$ex" ]] && return 0
	USER_TARGS+=("--exclude=$ex")
	[[ "$ex" == */\* ]] && USER_TARGS+=("--exclude=${ex%/\*}")
}

build_user_targs() {
	USER_TARGS=()
	MANIFEST_SOURCES=()
	local ex
	while IFS= read -r ex; do _add_exclude "$ex"; done < <(_default_excludes)
	if [[ ${#EXCLUDES[@]} -gt 0 ]]; then
		for ex in "${EXCLUDES[@]}"; do _add_exclude "$ex"; done
	fi
	local folders=()
	if [[ ${#USER_INCLUDE_FOLDERS[@]} -gt 0 ]]; then
		folders=("${USER_INCLUDE_FOLDERS[@]}")
	else
		local f
		while IFS= read -r f; do [[ -n "$f" ]] && folders+=("$f"); done < <(_default_user_folders)
	fi
	local line user home parent hbase
	while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		user="${line%%|*}"; home="${line#*|}"
		[[ -d "$home" ]] || continue
		parent="$(dirname "$home")"; hbase="$(basename "$home")"
		if [[ ${#folders[@]} -eq 0 ]]; then
			# Whole home rooted at ./<home-basename>
			USER_TARGS+=(-C "$parent" "./${hbase}")
			MANIFEST_SOURCES+=("$home")
		else
			local fol
			for fol in "${folders[@]}"; do
				if [[ -e "${home}/${fol}" ]]; then
					USER_TARGS+=(-C "$parent" "./${hbase}/${fol}")
					MANIFEST_SOURCES+=("${home}/${fol}")
				fi
			done
		fi
	done < <(detect_homes)
}

# Stage system state into "$1"; sets MANIFEST_STATUS / MANIFEST_NOTES.
collect_system_stage() {
	local stage="$1"
	MANIFEST_STATUS=""
	MANIFEST_NOTES=()
	mkdir -p "$stage"
	if [[ "$OS_TYPE" == "macos" ]]; then
		_collect_system_macos "$stage"
	else
		_collect_system_linux "$stage"
	fi
	local extra
	for extra in "${SYSTEM_EXTRA_PATHS[@]}"; do
		[[ -z "$extra" || ! -e "$extra" ]] && continue
		local dst="${stage}/extra/$(basename "$extra")"
		mkdir -p "$(dirname "$dst")"
		cp -a "$extra" "$dst" 2>/dev/null || log "  WARN: could not copy extra path $extra"
	done
}

_cap() {
	# _cap STAGE RELPATH cmd...   -- capture stdout to STAGE/RELPATH (tolerant)
	local stage="$1" rel="$2"; shift 2
	local dest="${stage}/${rel}"
	mkdir -p "$(dirname "$dest")" 2>/dev/null || return 0
	"$@" >"$dest" 2>>"${dest}.err" || true
	[[ -s "${dest}.err" ]] || rm -f "${dest}.err" 2>/dev/null || true
}

_collect_system_linux() {
	local stage="$1"
	# /etc (skip shadow files unless root).
	if [[ -d /etc ]]; then
		mkdir -p "${stage}/etc"
		if is_privileged; then
			cp -a /etc/. "${stage}/etc/" 2>/dev/null || log "  WARN: /etc copy partial"
		else
			# rsync excludes shadow files when available; else tar-pipe with excludes.
			if command -v rsync >/dev/null 2>&1; then
				rsync -a --exclude='shadow*' --exclude='gshadow*' /etc/ "${stage}/etc/" 2>/dev/null || log "  WARN: /etc copy partial"
			else
				(cd /etc && tar -cf - --exclude='shadow*' --exclude='gshadow*' . 2>/dev/null | tar -xf - -C "${stage}/etc" 2>/dev/null) || log "  WARN: /etc copy partial"
			fi
			MANIFEST_STATUS="SYSTEM_INCOMPLETE"
			MANIFEST_NOTES+=("/etc shadow files skipped (not root)")
			log "  WARN: not elevated -- /etc shadow files skipped; system archive is INCOMPLETE."
		fi
	fi
	command -v dpkg    >/dev/null 2>&1 && _cap "$stage" packages/pkgs.dpkg    dpkg --get-selections
	command -v rpm     >/dev/null 2>&1 && _cap "$stage" packages/pkgs.rpm     rpm -qa
	command -v pacman  >/dev/null 2>&1 && _cap "$stage" packages/pkgs.pacman  pacman -Qqe
	command -v flatpak >/dev/null 2>&1 && _cap "$stage" packages/pkgs.flatpak flatpak list --app --columns=application
	command -v snap    >/dev/null 2>&1 && _cap "$stage" packages/pkgs.snap    snap list
	command -v systemctl >/dev/null 2>&1 && _cap "$stage" services/systemd-enabled.txt systemctl list-unit-files --state=enabled --no-pager
	command -v ip      >/dev/null 2>&1 && _cap "$stage" network/ip-addr.txt   ip addr
	command -v crontab >/dev/null 2>&1 && _cap "$stage" cron/crontab.txt      crontab -l
}

_collect_system_macos() {
	local stage="$1"
	_cap "$stage" info/sw_vers.txt sw_vers
	_cap "$stage" installed/applications.txt /bin/ls -1 /Applications
	if command -v brew >/dev/null 2>&1; then
		_cap "$stage" installed/brew_leaves.txt brew leaves
		brew bundle dump --file="${stage}/installed/Brewfile" --force >/dev/null 2>&1 || true
	fi
	local etc
	for etc in /etc/hosts /etc/shells /etc/ssh/sshd_config; do
		if [[ -f "$etc" ]]; then
			mkdir -p "${stage}/etc$(dirname "${etc#/etc}")" 2>/dev/null || true
			cp "$etc" "${stage}/etc${etc#/etc}" 2>/dev/null || true
		fi
	done
	# Full Disk Access probe (cannot be auto-granted).
	local probe="$HOME/Library/Safari/Bookmarks.plist"
	if [[ -e "$probe" ]] && ! head -c1 "$probe" >/dev/null 2>&1; then
		MANIFEST_NOTES+=("Full Disk Access not granted (Mail/Messages/Safari not captured)")
		send_notify "warning" "Full Disk Access required" "Grant Full Disk Access to Terminal to back up Mail/Safari/Messages."
	fi
}

# ==============================================================================
# 8. PRODUCE
# ==============================================================================
_member_archive_path() {
	# $1 = sub (users|systems); echoes the staging archive path
	local sub="$1"
	echo "${STAGING_BASE}/shares/FamilyBackups/${MEMBER}/${sub}/${MEMBER}_${sub}_${CDATE}${TAR_EXT}"
}

produce_backup() {
	STAGING_BASE="${STAGING_DIR:-${TMPDIR:-/tmp}/auto-backupper-staging}"
	STAGING_BASE="${STAGING_BASE%/}"
	if ! is_dry; then
		rm -rf "$STAGING_BASE"
		mkdir -p "$STAGING_BASE"
	fi
	SESSION_MANIFEST="${STAGING_BASE}/.session_manifest"
	: >"$SESSION_MANIFEST" 2>/dev/null || true
	log "=== Backup: member=${MEMBER} scope=${BACKUP_SCOPE} os=${OS_TYPE} staging=${STAGING_BASE} ==="

	local do_users=0 do_system=0 produce_fail=0
	[[ ( "$BACKUP_SCOPE" == "users" || "$BACKUP_SCOPE" == "both" ) && "$BACKUP_USERS" == "true" ]] && do_users=1
	[[ ( "$BACKUP_SCOPE" == "system" || "$BACKUP_SCOPE" == "both" ) && "$BACKUP_SYSTEM" == "true" ]] && do_system=1

	if [[ $do_users -eq 1 ]]; then
		log "Phase: USER data archive"
		MANIFEST_STATUS=""; MANIFEST_NOTES=()
		build_user_targs
		if [[ ${#USER_TARGS[@]} -eq 0 ]]; then
			log "  WARN: no user sources resolved; skipping users archive."
		else
			# USER_TARGS still contains only --exclude entries if no member matched.
			local has_member=0 a
			for a in "${USER_TARGS[@]}"; do [[ "$a" == "-C" ]] && has_member=1; done
			if [[ $has_member -eq 0 ]]; then
				log "  WARN: no user data found in configured folders; skipping users archive."
			else
				client_create_archive "$(_member_archive_path users)" "FamilyBackups/${MEMBER}/users" "${USER_TARGS[@]}" || produce_fail=1
			fi
		fi
	fi

	if [[ $do_system -eq 1 ]]; then
		log "Phase: SYSTEM state archive"
		local sysparent; sysparent="$(mktemp -d "${TMPDIR:-/tmp}/abclient_sys.XXXXXX" 2>/dev/null || echo "")"
		# Guard against mktemp failure: with an empty sysparent, stage would be
		# "/system" and the real run would tar the FILESYSTEM ROOT (and never clean
		# it up). Skip the phase and flag failure instead.
		if ! is_dry && [[ -z "$sysparent" ]]; then
			log "  ERROR: could not create a system-staging temp dir (mktemp failed); skipping SYSTEM archive."
			produce_fail=1
		else
			local stage="${sysparent}/system"
			MANIFEST_SOURCES=("(generated system state)")
			if is_dry; then
				log "[DRY] collect system state"
				MANIFEST_STATUS=""; MANIFEST_NOTES=()
				client_create_archive "$(_member_archive_path systems)" "FamilyBackups/${MEMBER}/systems" -C "${stage:-/nonexistent}" .
			else
				collect_system_stage "$stage"
				client_create_archive "$(_member_archive_path systems)" "FamilyBackups/${MEMBER}/systems" -C "$stage" . || produce_fail=1
				if [[ "$MANIFEST_STATUS" == "SYSTEM_INCOMPLETE" ]]; then
					send_notify "warning" "System backup incomplete" "${MEMBER}: system archive degraded. Run elevated for a complete capture."
				fi
			fi
			[[ -n "$sysparent" ]] && rm -rf "$sysparent"
		fi
	fi

	is_dry && return 0
	# Fail the run if NOTHING was produced, OR if any REQUESTED archive failed
	# (e.g. users failed while system succeeded). Without this, main reports a
	# partial failure as an overall SUCCESS "Backup complete" notification.
	[[ ${#PRODUCED_ARCHIVES[@]} -gt 0 ]] || return 1
	return "$produce_fail"
}

# ==============================================================================
# 9. DELIVERY (local | share | rsync_ssh; data before checksum)
# ==============================================================================
_dest_count() { echo "${#DEST_NAMES[@]}"; }

_dest_selected() {
	# $1 = dest name; honor --dest filter
	[[ ${#DEST_FILTER[@]} -eq 0 ]] && return 0
	local n
	for n in "${DEST_FILTER[@]}"; do [[ "$n" == "$1" ]] && return 0; done
	return 1
}

deliver_all() {
	[[ ${#DEST_NAMES[@]} -gt 0 ]] || { log "WARN: no destinations configured; archives remain in staging only."; return 0; }
	local ok_all=0 i name type path
	for i in "${!DEST_NAMES[@]}"; do
		name="${DEST_NAMES[$i]}"
		type="${DEST_TYPES[$i]:-local}"
		path="${DEST_PATHS[$i]:-}"
		_dest_selected "$name" || continue
		log "Delivering: -> ${name} (${type})"
		case "$type" in
			local|share) deliver_fs "$path" || ok_all=1 ;;
			rsync_ssh)    deliver_ssh || ok_all=1 ;;
			*) log "  ERROR: unknown dest type '$type'"; ok_all=1 ;;
		esac
	done
	return $ok_all
}

deliver_fs() {
	# Per-file copy (no rsync dependency) so local/external drives and mounted
	# shares work even where rsync isn't installed. Atomic via .abpartial->rename;
	# data is delivered and verified before its checksum lands.
	local base="${1%/}"
	[[ -n "$base" ]] || { log "  ERROR: destination path is empty."; return 1; }
	if is_dry; then log "[DRY] copy staged archives -> ${base}"; return 0; fi
	mkdir -p "$base" 2>/dev/null || { log "  ERROR: cannot create destination $base"; return 1; }
	local rc=0 a rel dst exp act chk chkrel cdst
	for a in "${PRODUCED_ARCHIVES[@]}"; do
		[[ -z "$a" || ! -f "$a" ]] && continue
		rel="${a#"$STAGING_BASE"/}"
		dst="${base}/${rel}"
		mkdir -p "$(dirname "$dst")"
		if ! { cp "$a" "${dst}.abpartial" && mv -f "${dst}.abpartial" "$dst"; }; then
			log "  ERROR: copy failed for ${rel}"; rc=1; continue
		fi
		if [[ "$VERIFY_AFTER_CREATE" == "true" ]]; then
			# `exp` hashes the local staging copy (fast). `act` reads BACK from the
			# delivery target, which may be a stale SMB/NFS mount — timeout-bound it
			# (like verify_file) so a wedged mount can't hang the whole run; a
			# timeout yields empty act and is treated as a delivery failure below.
			exp="$(_sha256 "$a")"
			act=""; [[ -n "$HASH_BIN" ]] && act="$(_with_timeout 600 $HASH_BIN "$dst" 2>/dev/null | awk '{print $1}')"
			if [[ -z "$act" || "$exp" != "$act" ]]; then
				log "  ERROR: post-delivery checksum mismatch for ${rel}"; rm -f "$dst"; rc=1; continue
			fi
		fi
		# Checksum after the data is in final position.
		if chk="$(checksum_find_path "$a" "$STAGING_BASE")"; then
			chkrel="${chk#"$STAGING_BASE"/}"
			cdst="${base}/${chkrel}"
			mkdir -p "$(dirname "$cdst")"
			cp "$chk" "${cdst}.tmp" && mv -f "${cdst}.tmp" "$cdst" || log "  WARN: checksum copy failed for ${chkrel}"
		fi
	done
	[[ $rc -eq 0 ]] && prune_local "$base"
	return $rc
}

deliver_ssh() {
	[[ -n "$RSYNC_SSH_TARGET" ]] || { log "  ERROR: RSYNC_SSH_TARGET not set."; return 1; }
	if is_dry; then log "[DRY] rsync push -> ${RSYNC_SSH_TARGET}"; return 0; fi
	# Build an ssh CONFIG file rather than inlining `-i $IDENTITY` in rsync's `-e`
	# string: rsync word-splits the -e value, so an identity PATH WITH SPACES
	# (e.g. macOS "/Library/Application Support/...") would break. ssh config
	# quotes the path properly; the temp config's own path (mktemp under TMPDIR)
	# has no spaces.
	local sshconf
	sshconf="$(mktemp "${TMPDIR:-/tmp}/abclient_ssh.XXXXXX" 2>/dev/null)" || { log "  ERROR: could not create ssh config temp."; return 1; }
	{
		echo "BatchMode yes"
		echo "StrictHostKeyChecking accept-new"
		echo "Port ${RSYNC_SSH_PORT}"
		echo "ConnectTimeout 30"
		[[ -n "$RSYNC_SSH_IDENTITY" ]] && printf 'IdentityFile "%s"\n' "$RSYNC_SSH_IDENTITY"
	} >"$sshconf" 2>/dev/null
	local rc=0 sub
	# Data subtree first, then checksums.
	for sub in shares "$CHECKSUM_DIR"; do
		[[ -d "${STAGING_BASE}/${sub}" ]] || continue
		rsync -a --compress --omit-dir-times --partial-dir=.abpartial --timeout=60 \
			-e "ssh -F $sshconf" "${STAGING_BASE}/${sub}/" "${RSYNC_SSH_TARGET%/}/${sub}/"
		local code=$?
		if [[ $code -ne 0 && $code -ne 24 ]]; then
			log "  ERROR: rsync of ${sub}/ failed (code ${code})."
			rc=1
		fi
	done
	rm -f "$sshconf" 2>/dev/null || true
	return $rc
}

prune_local() {
	local base="${1%/}" keep="${LOCAL_KEEP:-2}"
	[[ "$keep" =~ ^[0-9]+$ ]] || return 0
	[[ "$keep" -le 0 ]] && return 0
	local sub d arcs n old
	for sub in users systems; do
		d="${base}/shares/FamilyBackups/${MEMBER}/${sub}"
		[[ -d "$d" ]] || continue
		arcs=()
		shopt -s nullglob
		for old in "${d}/${MEMBER}_${sub}_"[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]"${TAR_EXT}"; do arcs+=("$old"); done
		shopt -u nullglob
		n=${#arcs[@]}
		[[ $n -le $keep ]] && continue
		# Sort by name (date) ascending; remove the oldest (n-keep).
		IFS=$'\n' arcs=($(printf '%s\n' "${arcs[@]}" | sort)); unset IFS
		local remove=$((n - keep)) idx=0
		for old in "${arcs[@]}"; do
			[[ $idx -ge $remove ]] && break
			rm -f "$old"
			log "  Pruned old local copy: $(basename "$old")"
			idx=$((idx + 1))
		done
	done
}

# ==============================================================================
# 10. PRE-FLIGHT
# ==============================================================================
preflight() {
	log "Phase: Pre-flight checks"
	command -v tar >/dev/null 2>&1   || { log "FATAL: 'tar' not found."; return 1; }
	[[ -n "$(_sha256 /dev/null)" ]]  || { log "FATAL: no SHA-256 tool (sha256sum / shasum) found."; return 1; }
	local i name type path parent
	for i in "${!DEST_NAMES[@]}"; do
		name="${DEST_NAMES[$i]}"; type="${DEST_TYPES[$i]:-local}"; path="${DEST_PATHS[$i]:-}"
		_dest_selected "$name" || continue
		case "$type" in
			local|share)
				parent="$path"; [[ -d "$parent" ]] || parent="$(dirname "$path")"
				[[ -d "$parent" && ! -w "$parent" ]] && log "WARN: destination '${path}' may not be writable."
				;;
			rsync_ssh)
				[[ -z "$RSYNC_SSH_TARGET" ]] && log "WARN: rsync_ssh dest has no RSYNC_SSH_TARGET."
				command -v rsync >/dev/null 2>&1 || log "WARN: 'rsync' not found; the rsync_ssh push will fail (install rsync)."
				;;
		esac
	done
	is_privileged || log "WARN: not elevated -- all-users data and full system state are limited. Run with sudo for a complete whole-machine backup."
	return 0
}

# ==============================================================================
# 11. SCHEDULER INSTALL / UNINSTALL
# ==============================================================================
_schedule_invocation() {
	local script cfg
	script="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
	cfg="${LOADED_CONFIG:-$DEFAULT_CONFIG_FILE}"
	echo "${script}|${cfg}"
}

# Map SCHEDULE_DAY ("Sunday", "wed", ...) to a cron/launchd weekday number
# (0=Sun..6=Sat) and a systemd 3-letter abbreviation. Used only for weekly.
_dow_num() {
	case "$(printf '%s' "${1:-Sunday}" | tr '[:upper:]' '[:lower:]')" in
		sun*) echo 0 ;; mon*) echo 1 ;; tue*) echo 2 ;; wed*) echo 3 ;;
		thu*) echo 4 ;; fri*) echo 5 ;; sat*) echo 6 ;; *) echo 0 ;;
	esac
}
_dow_abbr() {
	case "$(_dow_num "$1")" in
		0) echo Sun ;; 1) echo Mon ;; 2) echo Tue ;; 3) echo Wed ;;
		4) echo Thu ;; 5) echo Fri ;; 6) echo Sat ;;
	esac
}

install_schedule() {
	local inv script cfg hh mm
	inv="$(_schedule_invocation)"; script="${inv%%|*}"; cfg="${inv#*|}"
	hh="${SCHEDULE_TIME%%:*}"; mm="${SCHEDULE_TIME#*:}"
	case "$SCHEDULE_CADENCE" in
		daily|weekly) ;;
		*) log "WARN: unknown SCHEDULE_CADENCE='${SCHEDULE_CADENCE}', defaulting to daily."; SCHEDULE_CADENCE="daily" ;;
	esac
	if [[ "$SCHEDULE_CADENCE" == "weekly" ]]; then
		log "Installing weekly schedule on ${SCHEDULE_DAY} at ${SCHEDULE_TIME} (${OS_TYPE})."
	else
		log "Installing daily schedule at ${SCHEDULE_TIME} (${OS_TYPE})."
	fi
	if [[ "$OS_TYPE" == "macos" ]]; then
		_install_launchd "$script" "$cfg" "$hh" "$mm"
	elif command -v systemctl >/dev/null 2>&1; then
		_install_systemd "$script" "$cfg" "$hh" "$mm"
	else
		_install_cron "$script" "$cfg" "$hh" "$mm"
	fi
}

uninstall_schedule() {
	log "Uninstalling schedule (${OS_TYPE})."
	if [[ "$OS_TYPE" == "macos" ]]; then
		local plist="/Library/LaunchDaemons/com.auto-backupper.client.plist"
		launchctl bootout system "$plist" 2>/dev/null || true
		rm -f "$plist" 2>/dev/null || true
	elif command -v systemctl >/dev/null 2>&1; then
		systemctl disable --now auto-backupper-client.timer 2>/dev/null || true
		rm -f /etc/systemd/system/auto-backupper-client.timer /etc/systemd/system/auto-backupper-client.service 2>/dev/null || true
		systemctl daemon-reload 2>/dev/null || true
	else
		( crontab -l 2>/dev/null | grep -v "auto-backupper-client" ) | crontab - 2>/dev/null || true
	fi
	return 0
}

_install_systemd() {
	local script="$1" cfg="$2" hh="$3" mm="$4"
	local wake=""; [[ "$SCHEDULE_WAKE" == "true" ]] && wake="WakeSystem=true"
	local oncal="*-*-* ${hh}:${mm}:00"
	[[ "$SCHEDULE_CADENCE" == "weekly" ]] && oncal="$(_dow_abbr "$SCHEDULE_DAY") *-*-* ${hh}:${mm}:00"
	if ! cat >/etc/systemd/system/auto-backupper-client.service 2>/dev/null <<EOF
[Unit]
Description=Auto-Backupper desktop client
[Service]
Type=oneshot
ExecStart=${script} --backup both --config ${cfg}
EOF
	then log "ERROR: systemd install failed (need sudo?)."; return 1; fi
	cat >/etc/systemd/system/auto-backupper-client.timer 2>/dev/null <<EOF
[Unit]
Description=Run Auto-Backupper client
[Timer]
OnCalendar=${oncal}
Persistent=true
${wake}
[Install]
WantedBy=timers.target
EOF
	systemctl daemon-reload && systemctl enable --now auto-backupper-client.timer
}

_install_cron() {
	local script="$1" cfg="$2" hh="$3" mm="$4"
	local dow="*"
	[[ "$SCHEDULE_CADENCE" == "weekly" ]] && dow="$(_dow_num "$SCHEDULE_DAY")"
	local line="${mm##0} ${hh##0} * * ${dow} ${script} --backup both --config ${cfg}"
	( crontab -l 2>/dev/null | grep -v "auto-backupper-client"; echo "$line" ) | crontab - \
		&& return 0 || { log "ERROR: cron install failed."; return 1; }
}

_install_launchd() {
	local script="$1" cfg="$2" hh="$3" mm="$4"
	local plist="/Library/LaunchDaemons/com.auto-backupper.client.plist"
	local weekday_xml=""
	[[ "$SCHEDULE_CADENCE" == "weekly" ]] && weekday_xml="<key>Weekday</key><integer>$(_dow_num "$SCHEDULE_DAY")</integer>"
	if ! cat >"$plist" 2>/dev/null <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.auto-backupper.client</string>
  <key>ProgramArguments</key><array>
    <string>${script}</string><string>--backup</string><string>both</string>
    <string>--config</string><string>${cfg}</string></array>
  <key>StartCalendarInterval</key><dict><key>Hour</key><integer>${hh##0}</integer><key>Minute</key><integer>${mm##0}</integer>${weekday_xml}</dict>
  <key>StandardOutPath</key><string>/var/log/auto-backupper-client.log</string>
  <key>StandardErrorPath</key><string>/var/log/auto-backupper-client.log</string>
  <key>RunAtLoad</key><false/>
</dict></plist>
EOF
	then log "ERROR: launchd install failed (need sudo?)."; return 1; fi
	launchctl bootout system "$plist" 2>/dev/null || true
	log "NOTE: launchd does not catch up missed runs; an asleep Mac runs at the next scheduled time."
	launchctl bootstrap system "$plist"
}

# ==============================================================================
# 12. RESTORE / LIST / VERIFY / INSPECT
# ==============================================================================
_search_roots() {
	[[ -n "$SERVER_BACKUP_BASE" && -d "$SERVER_BACKUP_BASE" ]] && echo "${SERVER_BACKUP_BASE%/}"
	local i
	for i in "${!DEST_NAMES[@]}"; do
		[[ "${DEST_TYPES[$i]:-local}" == "local" || "${DEST_TYPES[$i]:-local}" == "share" ]] || continue
		local p="${DEST_PATHS[$i]:-}"
		[[ -n "$p" && -d "$p" ]] && echo "${p%/}"
	done
	local stg="${STAGING_DIR:-${TMPDIR:-/tmp}/auto-backupper-staging}"
	[[ -d "$stg" ]] && echo "${stg%/}"
}

_find_archives() {
	local base="${1%/}"
	find "$base" -path "${base}/${CHECKSUM_DIR}" -prune -o -type f \( -name '*.tar.gz' -o -name '*.tgz' -o -name '*.tar' \) -print 2>/dev/null | sort
}

cmd_list() {
	local roots total=0 base f size chk
	roots="$(_search_roots | sort -u)"
	[[ -z "$roots" ]] && { echo "No reachable backup roots (set SERVER_BACKUP_BASE, a local/share dest, or STAGING_DIR)."; return 0; }
	while IFS= read -r base; do
		[[ -z "$base" ]] && continue
		local found=0
		while IFS= read -r f; do
			[[ -z "$f" ]] && continue
			case "$(basename "$f")" in $LIST_PATTERN) ;; *) continue ;; esac
			[[ $found -eq 0 ]] && { echo; echo "=== ${base} ==="; found=1; }
			size="$( (du -h "$f" 2>/dev/null || echo '?') | awk '{print $1}')"
			if checksum_find_path "$f" "$base" >/dev/null 2>&1; then chk="[chk]"; else chk="[NO CHK]"; fi
			printf '  %-64s %8s  %s\n' "${f#"$base"/}" "$size" "$chk"
			total=$((total + 1))
		done < <(_find_archives "$base")
	done <<<"$roots"
	echo; echo "Total: ${total} archive(s)."
	return 0
}

cmd_inspect() {
	[[ -f "$RESTORE_ARCHIVE" ]] || { log "ERROR: archive not found: $RESTORE_ARCHIVE"; return 1; }
	tar -tf "$RESTORE_ARCHIVE" 2>/dev/null | head -100
	local n; n="$(tar -tf "$RESTORE_ARCHIVE" 2>/dev/null | wc -l | tr -d ' ')"
	echo; echo "Total entries: ${n} (first 100 shown)"
}

_verify_with_base() {
	# Echo a verify token for an archive by locating its BACKUP_BASE.
	local archive="$1" base
	while IFS= read -r base; do
		[[ -z "$base" ]] && continue
		case "$archive" in
			"$base"/*) if checksum_find_path "$archive" "$base" >/dev/null 2>&1; then verify_file "$archive" "$base"; return; fi ;;
		esac
	done < <(_search_roots; echo "$(dirname "$archive")")
	echo NO_CHECKSUM
}

cmd_verify() {
	[[ -f "$RESTORE_ARCHIVE" ]] || { log "ERROR: archive not found: $RESTORE_ARCHIVE"; return 1; }
	local status; status="$(_verify_with_base "$RESTORE_ARCHIVE")"
	log "VERIFY ${status}: ${RESTORE_ARCHIVE}"
	[[ "$status" == "OK" || "$status" == "NO_CHECKSUM" ]] && return 0 || return 1
}

cmd_verify_all() {
	local base f status rc=0
	while IFS= read -r base; do
		[[ -z "$base" ]] && continue
		while IFS= read -r f; do
			[[ -z "$f" ]] && continue
			if checksum_find_path "$f" "$base" >/dev/null 2>&1; then status="$(verify_file "$f" "$base")"; else status="NO_CHECKSUM"; fi
			log "  ${status}: ${f}"
			[[ "$status" == "MISMATCH" ]] && rc=1
		done < <(_find_archives "$base")
	done < <(_search_roots | sort -u)
	return $rc
}

_confirm() {
	[[ "$FORCE" -eq 1 ]] && return 0
	local ans
	read -r -p "$1 [y/N] " ans </dev/tty 2>/dev/null || return 1
	[[ "$ans" == "y" || "$ans" == "Y" || "$ans" == "yes" ]]
}

cmd_restore() {
	local archive="$RESTORE_ARCHIVE" target="$RESTORE_TARGET"
	[[ -f "$archive" ]] || { log "ERROR: archive not found: $archive"; return 1; }
	[[ -n "$target" ]] || { log "ERROR: --target is required for --restore"; return 1; }

	if [[ "$VERIFY_BEFORE_RESTORE" == "true" && "$NO_VERIFY" -eq 0 ]]; then
		local status; status="$(_verify_with_base "$archive")"
		case "$status" in
			OK) log "  Pre-restore checksum OK." ;;
			NO_CHECKSUM) log "  WARN: no checksum recorded."; _confirm "Proceed without verification?" || return 1 ;;
			MISMATCH) log "FATAL: archive checksum does NOT match. Refusing (override with --no-verify)."; return 1 ;;
			*) log "FATAL: could not verify archive (${status})."; return 1 ;;
		esac
	fi
	# Surface a degraded system archive.
	if tar -xOf "$archive" .auto-backupper/MANIFEST.txt 2>/dev/null | grep -q "SYSTEM_INCOMPLETE"; then
		log "  NOTE: this SYSTEM archive is marked INCOMPLETE (captured without elevation)."
	fi
	if [[ ! -d "$target" ]]; then
		if ! is_dry && _confirm "Target ${target} does not exist. Create it?"; then mkdir -p "$target" || { log "FATAL: could not create $target"; return 1; }
		elif ! is_dry; then return 1; fi
	fi
	echo; echo "================ RESTORE PLAN ================"
	echo "  Archive: ${archive}"
	echo "  Target:  ${target}"
	[[ ${#ONLY_PATHS[@]} -gt 0 ]] && echo "  Only:    ${ONLY_PATHS[*]}"
	echo "=============================================="; echo
	_confirm "Proceed with restore?" || return 1
	if is_dry; then log "[DRY] tar -xpf ${archive} -C ${target} ${ONLY_PATHS[*]:-}"; return 0; fi
	local same_owner=(); is_privileged && same_owner=(--same-owner)
	local rc=0
	tar -xpf "$archive" -C "$target" "${same_owner[@]}" "${ONLY_PATHS[@]}" || rc=$?
	if [[ $rc -ne 0 ]]; then log "ERROR: extraction failed (code ${rc})."; return 1; fi
	is_privileged || log "NOTE: ran unprivileged -- file ownership not restored."
	log "RESTORE SUCCEEDED: ${archive} -> ${target}"
	return 0
}

# ==============================================================================
# 13. LIFECYCLE & MAIN
# ==============================================================================
acquire_lock() {
	# Portable atomic lock via mkdir (flock is Linux-only; macOS lacks it).
	# Fail LOUDLY if the lock dir's parent can't be made writable — otherwise a
	# permission failure here returns 1 and main misreports it as "another
	# instance is running" and exits 0, silently skipping the backup.
	local _parent; _parent="$(dirname "$LOCKDIR")"
	if ! mkdir -p "$_parent" 2>/dev/null || [[ ! -w "$_parent" ]]; then
		log "FATAL: lock directory '$_parent' is not writable; cannot ensure a single instance."
		log "       Run as root, or point LOCK/STATE at a writable path. Refusing to run blind."
		exit 1
	fi
	if mkdir "$LOCKDIR" 2>/dev/null; then
		echo $$ >"${LOCKDIR}/pid" 2>/dev/null || true
		LOCK_HELD=1
		return 0
	fi
	# Stale-lock detection: steal if the recorded PID is dead.
	local oldpid=""
	[[ -f "${LOCKDIR}/pid" ]] && oldpid="$(cat "${LOCKDIR}/pid" 2>/dev/null || echo "")"
	if [[ -n "$oldpid" ]] && ! kill -0 "$oldpid" 2>/dev/null; then
		log "WARN: removing stale lock (pid ${oldpid} not running)."
		rm -rf "$LOCKDIR" 2>/dev/null || true
		if mkdir "$LOCKDIR" 2>/dev/null; then echo $$ >"${LOCKDIR}/pid" 2>/dev/null || true; LOCK_HELD=1; return 0; fi
	fi
	return 1
}

cleanup() {
	[[ -n "$CURRENT_ARCHIVE_FILE" && -f "${CURRENT_ARCHIVE_FILE}.abpartial" ]] && rm -f "${CURRENT_ARCHIVE_FILE}.abpartial" 2>/dev/null || true
	[[ "$LOCK_HELD" -eq 1 ]] && rm -rf "$LOCKDIR" 2>/dev/null || true
}

interrupt_trap() { log "WARN: Interrupt detected. Cleaning up..."; cleanup; exit 130; }
trap 'cleanup' EXIT
trap 'interrupt_trap' INT TERM

usage() {
	cat <<EOF
Usage: $(basename "$0") MODE [OPTIONS]
Modes:
  --backup [users|system|both]   Produce + deliver archives (default: both)
  --restore ARCHIVE --target P   Restore an archive (--only ./path for partial)
  --list [PATTERN]               List reachable archives
  --verify ARCHIVE | --verify-all
  --inspect ARCHIVE              List archive members
  --install-schedule | --uninstall-schedule
Options:
  -c, --config FILE   Config file (default: per-OS location)
  --member NAME       Override the FamilyBackups <member> dir
  --dest NAME         Restrict delivery to named dest(s) (repeatable)
  --target PATH       Restore destination
  --only PATH         Partial-restore member (repeatable; leading ./ honored)
  --dry-run --no-verify --force --debug -h/--help
EOF
}

parse_args() {
	CLI_CONFIG=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--backup) MODE="backup"
				case "${2:-}" in users|system|both) BACKUP_SCOPE="$2"; shift ;; esac ;;
			--restore) MODE="restore"; RESTORE_ARCHIVE="${2:-}"; [[ -z "$RESTORE_ARCHIVE" || "$RESTORE_ARCHIVE" == -* ]] && { echo "ERROR: --restore requires an archive" >&2; exit 1; }; shift ;;
			--target) RESTORE_TARGET="${2:-}"; [[ -z "$RESTORE_TARGET" || "$RESTORE_TARGET" == -* ]] && { echo "ERROR: --target requires a value" >&2; exit 1; }; shift ;;
			--only) [[ -z "${2:-}" || "${2:-}" == -* ]] && { echo "ERROR: --only requires a value" >&2; exit 1; }; ONLY_PATHS+=("$2"); shift ;;
			--list) MODE="list"; case "${2:-}" in ""|-*) ;; *) LIST_PATTERN="$2"; shift ;; esac ;;
			--verify) MODE="verify"; RESTORE_ARCHIVE="${2:-}"; [[ -z "$RESTORE_ARCHIVE" || "$RESTORE_ARCHIVE" == -* ]] && { echo "ERROR: --verify requires an archive" >&2; exit 1; }; shift ;;
			--verify-all) MODE="verify-all" ;;
			--inspect) MODE="inspect"; RESTORE_ARCHIVE="${2:-}"; [[ -z "$RESTORE_ARCHIVE" || "$RESTORE_ARCHIVE" == -* ]] && { echo "ERROR: --inspect requires an archive" >&2; exit 1; }; shift ;;
			--install-schedule) MODE="install-schedule" ;;
			--uninstall-schedule) MODE="uninstall-schedule" ;;
			--member) MEMBER="${2:-}"; [[ -z "$MEMBER" || "$MEMBER" == -* ]] && { echo "ERROR: --member requires a value" >&2; exit 1; }; shift ;;
			--dest) [[ -z "${2:-}" || "${2:-}" == -* ]] && { echo "ERROR: --dest requires a value" >&2; exit 1; }; DEST_FILTER+=("$2"); shift ;;
			--config|-c) CLI_CONFIG="${2:-}"; shift ;;
			--config=*) CLI_CONFIG="${1#--config=}" ;;
			--dry-run) CLI_DRY_RUN="true" ;;
			--no-verify) NO_VERIFY=1 ;;
			--force) FORCE=1 ;;
			--debug) CLI_DEBUG="debug" ;;
			-h|--help) usage; exit 0 ;;
			*) echo "ERROR: unknown argument: $1" >&2; exit 1 ;;
		esac
		shift
	done
}

main() {
	parse_args "$@"

	local cfg="${CLI_CONFIG:-$DEFAULT_CONFIG_FILE}"
	setup_logging
	if [[ -f "$cfg" ]]; then
		log "INFO: loading configuration from ${cfg}"
		# shellcheck disable=SC1090
		source "$cfg"
		LOADED_CONFIG="$cfg"
	else
		log "INFO: no config file at ${cfg}; using defaults."
		LOADED_CONFIG="$cfg"
	fi
	# CLI flags win over the config file.
	[[ -n "$CLI_DRY_RUN" ]] && DRY_RUN="$CLI_DRY_RUN"
	[[ -n "$CLI_DEBUG" ]] && LOG_VERBOSITY="$CLI_DEBUG"
	# Resolve member: explicit --member > cfg MEMBER_NAME > UPPERCASE hostname.
	[[ "$MEMBER" == "$_DEFAULT_MEMBER" && -n "$MEMBER_NAME" ]] && MEMBER="$MEMBER_NAME"
	_resolve_tar_tools

	[[ -z "$MODE" ]] && { usage; exit 1; }

	case "$MODE" in
		list) cmd_list; exit $? ;;
		inspect) cmd_inspect; exit $? ;;
		verify) cmd_verify; exit $? ;;
		verify-all) cmd_verify_all; exit $? ;;
		restore) cmd_restore; exit $? ;;
		install-schedule) install_schedule; exit $? ;;
		uninstall-schedule) uninstall_schedule; exit $? ;;
	esac

	# MODE == backup
	if ! acquire_lock; then log "Another instance is running. Exiting."; exit 0; fi
	preflight || exit 1
	local produce_rc=0 deliver_rc=0
	produce_backup || produce_rc=$?
	if [[ ${#PRODUCED_ARCHIVES[@]} -eq 0 ]] && ! is_dry; then
		log "ERROR: nothing was produced."
		send_notify "alert" "Backup failed" "${MEMBER}: produce stage created no archives."
		exit 1
	fi
	# Deliver whatever DID build, then fold in any per-archive produce failure so
	# a partial run (e.g. users failed, system succeeded) is never reported as a
	# clean success.
	deliver_all || deliver_rc=$?
	if [[ "$produce_rc" -ne 0 ]]; then
		log "ERROR: one or more requested archives failed to build."
		send_notify "alert" "Backup incomplete" "${MEMBER}: a requested archive failed to build (delivered ${#PRODUCED_ARCHIVES[@]}). See ${LOGFILE}."
		exit 1
	fi
	if [[ "$deliver_rc" -ne 0 ]]; then
		log "ERROR: one or more deliveries failed."
		send_notify "alert" "Backup delivery failed" "${MEMBER}: see log ${LOGFILE}."
		exit 1
	fi
	log "SUCCESS: backup complete."
	send_notify "normal" "Backup complete" "${MEMBER}: ${#PRODUCED_ARCHIVES[@]} archive(s) delivered."
	exit 0
}

main "$@"
