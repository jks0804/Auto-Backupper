#!/usr/bin/env bash
export PATH=/sbin:/opt/bin:/usr/local/bin:/usr/contrib/bin:/bin:/usr/bin:/usr/sbin:/usr/bin/X11
# ==============================================================================
# AUTO-RESTORER
# Companion restore tool for the Auto-Backupper suite
# ==============================================================================
#
# USAGE:
#   ./auto-restorer.sh --list [PATTERN]       # List archives (optional glob)
#   ./auto-restorer.sh --inspect ARCHIVE      # Show tar -t contents
#   ./auto-restorer.sh --verify  ARCHIVE      # Checksum verify
#   ./auto-restorer.sh --verify-all           # Checksum verify every archive
#   ./auto-restorer.sh --restore ARCHIVE --target PATH [OPTIONS]
#     --stop-docker    Stop Docker service/containers before restore, restart after
#     --force          Skip confirmation prompts; create target if missing
#     --no-verify      Skip pre-restore checksum check (NOT recommended)
#
# GLOBAL:
#   -c, --config FILE   Config file path (default: /boot/config/auto_backupper.cfg)
#   --dry-run           Show planned actions without modifying anything
#   -h, --help
#
# TARGET HINTS (how auto-backupper archives were built — use to pick --target):
#   shares/SHARE/*.tar.gz        → --target $SHARES_BASE_FOLDER     (usually /mnt/user)
#   shares/SHARE/SUB/*.tar.gz    → --target $SHARES_BASE_FOLDER/SHARE
#   shares/FamilyBackups/...     → --target PATH/TO/member/sub
#   systems/HOST/*.tar.gz        → --target /                       (re-extracts appdata,
#                                                                     boot, docker.img)
#   services/mysql|mongo|redis/  → --target /tmp/restore            (then import via
#                                                                     mysql/mongorestore/etc.)
#
# LICENSE: GPLv3
# ==============================================================================

set -Eeuo pipefail

# ==============================================================================
# 1. BOOTSTRAP & DEFAULTS
# ==============================================================================

DEFAULT_CONFIG_FILE="/boot/config/auto_backupper.cfg"
LOGFILE="/var/log/auto_restorer.log"
LOCKFILE="/var/lock/auto_restorer.lock"
CHECKSUM_DIR=".checksums"

# --- Log Rotation & Verbosity Defaults ---
# Matches the auto-backupper.sh model so all suite scripts share the
# same knobs. See README's "Configuration Reference > General Settings".
LOG_MAX_SIZE="$((10 * 1024 * 1024))" # 10 MB
LOG_BACKUPS=5
LOG_VERBOSITY="info"

# --- Config defaults (overridden when auto_backupper.cfg is sourced) ---
# Only values actually referenced by this script are declared here. The
# config file may set many more variables (SHARES_TO_BACKUP etc.); sourcing
# it lets those variables flow through to any future restore code that
# needs them, but we don't shadow them with unused defaults.
BACKUP_BASE="/mnt/user/backup"
DOCKER_STOP_TIMEOUT=60

# --- Runtime flags ---
DRY_RUN="false"
MODE=""
ARCHIVE=""
TARGET=""
STOP_DOCKER="false"
FORCE="false"
VERIFY_BEFORE_RESTORE="true"
LIST_PATTERN="*"
# --prune-checksums: duration string (e.g. 5y, 12m, 365d). --commit flips
# the prune from dry-run preview to actual deletion. Defaults are
# deliberately the safe side — no threshold + no commit = no-op.
PRUNE_OLDER_THAN=""
PRUNE_COMMIT="false"
# --corruption-report / cross-referencing: hostname override so a restore
# on a replacement box can read the original machine's report. Empty =
# fall back to the local short hostname at read time (matches watchtower's writer).
HOST_OVERRIDE=""
# --restore --only PATH: extract only specific path(s) from the archive
# rather than the whole thing. May be repeated. Each value is passed
# verbatim to `tar -xf <archive> PATH...`, so tar's matching rules apply:
# a path equal to a directory inside the archive extracts that whole
# subtree; an exact file path extracts just that file.
ONLY_PATHS=()

# --- Root check ---
if [[ $EUID -ne 0 ]]; then
	echo "CRITICAL: auto-restorer must be run as root." >&2
	exit 1
fi

# --- Logging ---
mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null || true
touch "$LOGFILE" 2>/dev/null || true

# Copytruncate log rotation — same pattern as auto-backupper.sh and
# watchtower.sh. Even though the restorer writes per-line via `echo >>`
# (no held FD), copytruncate is the suite-wide standard for
# consistency and forward-compatibility.
rotate_logs() {
	local logfile="$1"
	local max_size="$2"
	local backups="$3"

	[[ -f "$logfile" ]] || return 0

	local current_size
	if command -v stat >/dev/null 2>&1; then
		if [[ "$OSTYPE" == "darwin"* ]]; then
			current_size=$(stat -f%z "$logfile" 2>/dev/null || echo 0)
		else
			current_size=$(stat -c%s "$logfile" 2>/dev/null || echo 0)
		fi
	else
		current_size=$(wc -c <"$logfile" 2>/dev/null || echo 0)
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

# Periodic mid-run rotation check. The restorer doesn't fork verify
# workers like auto-backupper does, but the BASHPID guard is kept for
# uniformity with the other scripts.
rotate_log_if_needed() {
	[[ "$BASHPID" == "$$" ]] || return 0
	rotate_logs "$LOGFILE" "${LOG_MAX_SIZE:-10485760}" "${LOG_BACKUPS:-5}"
}

# Verbosity → numeric threshold (lower = more restrictive). Same model
# as auto-backupper.sh.
_log_verbosity_threshold() {
	case "${LOG_VERBOSITY:-info}" in
		error) echo 2 ;;
		phase) echo 3 ;;
		info)  echo 4 ;;
		debug) echo 99 ;;
		*)     echo 4 ;;
	esac
}

# Detect a restorer message's level from its prefix. Tuned to the
# restorer's actual log call conventions (audited via grep).
_log_level_for() {
	case "$1" in
		FATAL*|CRITICAL*|ERROR:*|ERROR\ *|WARN:*|WARN\ *) echo 2 ;;
		"==="*|"RESTORE SUCCEEDED:"*|RECOVERY:*|Verifying:*|Inspecting:*|Phase:*|Summary:*) echo 3 ;;
		DEBUG:*) echo 99 ;;
		*) echo 4 ;;
	esac
}

log() {
	local msg lvl thresh
	lvl=$(_log_level_for "$1")
	thresh=$(_log_verbosity_threshold)
	((lvl <= thresh)) || { rotate_log_if_needed; return 0; }

	msg="$(date -u '+%Y-%m-%dT%H:%M:%SZ') $1"
	echo "$msg"
	if [[ -w "$LOGFILE" ]]; then echo "$msg" >>"$LOGFILE"; fi
	rotate_log_if_needed
}

# ==============================================================================
# 2. ARGUMENT PARSING
# ==============================================================================

# Capture --config first so we can load it before the rest of the args need
# config-defined values (notably BACKUP_BASE). Accepts both `--config PATH`
# and `--config=PATH`, matching auto-backupper's parser.
CLI_CONFIG=""
prev_arg=""
for arg in "$@"; do
	if [[ "$arg" == --config=* || "$arg" == -c=* ]]; then
		CLI_CONFIG="${arg#*=}"
	elif [[ "$prev_arg" == "--config" || "$prev_arg" == "-c" ]]; then
		CLI_CONFIG="$arg"
	fi
	prev_arg="$arg"
done

CFG_TO_LOAD="${CLI_CONFIG:-$DEFAULT_CONFIG_FILE}"
if [[ -f "$CFG_TO_LOAD" ]]; then
	# shellcheck disable=SC1090
	source "$CFG_TO_LOAD"
fi

# Normalise BACKUP_BASE just like auto-backupper does.
BACKUP_BASE="${BACKUP_BASE%/}"

usage() {
	cat <<EOF
auto-restorer.sh — Companion restore tool for the Auto-Backupper suite

Usage: $0 COMMAND [OPTIONS]

Commands:
  --list [PATTERN]          List archives (optional glob matched against basename)
  --inspect ARCHIVE         Show tar -t contents of an archive
  --verify ARCHIVE          Verify one archive against its recorded checksum
  --verify-all              Verify every archive under BACKUP_BASE
  --corruption-report       Show watchtower's per-host corruption log,
                            aggregated by path with current SHA status:
                              BAD = path exists & hash fails (active)
                              OK  = path exists & hash matches (stale entry)
                              -   = path no longer present
    --host HOSTNAME           Read another host's report (default: local short hostname)
  --restore ARCHIVE         Extract an archive (requires --target)
    --target PATH             Extraction destination
    --only PATH               Extract only PATH from the archive (repeatable).
                              Matches tar's selection semantics: a directory
                              name pulls the whole subtree; a file name pulls
                              just that file. PATH must match the member name as
                              STORED: systems/ archives store it root-relative
                              (e.g. mnt/cache/appdata/plex, not appdata/plex),
                              and FamilyBackups archives prefix it with ./ (e.g.
                              ./users/docs). Run --inspect ARCHIVE to see exact
                              member names. The pre-restore checksum still
                              verifies the entire archive — the bytes on disk
                              haven't changed, so partial extraction is safe.
    --stop-docker             Stop Docker before extraction, restart after
    --force                   Skip confirmation prompts; create target if missing
    --no-verify               Skip pre-restore checksum check (NOT recommended)
  --prune-checksums         Bulk-delete orphan entries from .checksums/ (the
                            distributed historical index). Only checksums whose
                            data file is missing locally are candidates — files
                            with data on disk are never touched.
    --older-than DURATION     Required. Grammar: Nd / Nm / Ny (e.g. 5y, 12m, 365d).
                              Strongly recommend years, not days — peers with
                              indefinite retention may still hold the data.
    --commit                  Default is dry-run preview. Pass --commit to
                              actually delete; prompts for confirmation unless
                              --force is also supplied.

Global options:
  -c, --config FILE         Config file (default: $DEFAULT_CONFIG_FILE)
  --dry-run                 Show planned actions without modifying anything
  -h, --help                Show this help

Archive target hints (match how auto-backupper built the archive):
  shares/SHARE/*.tar.gz         → --target \$SHARES_BASE_FOLDER  (usually /mnt/user)
  shares/SHARE/SUB/*.tar.gz     → --target \$SHARES_BASE_FOLDER/SHARE
  shares/FamilyBackups/...      → --target PATH/TO/member/sub
  systems/HOST/*.tar.gz         → --target /   (re-extracts appdata, boot, docker.img)
  services/mysql|mongo|redis/   → --target /tmp/restore  (then import with db tools)

Examples:
  $0 --list
  $0 --list 'codebase*'
  $0 --verify-all
  $0 --corruption-report
  $0 --corruption-report --host srv01
  $0 --inspect /mnt/user/backup/shares/codebase/codebase_20260118.tar.gz
  $0 --restore /mnt/user/backup/shares/codebase/codebase_20260118.tar.gz \\
               --target /mnt/user --force
  $0 --restore /mnt/user/backup/systems/host/host_20260118.tar.gz \\
               --target / --stop-docker
  $0 --prune-checksums --older-than 5y                # dry-run preview
  $0 --prune-checksums --older-than 5y --commit       # delete after prompt
  $0 --prune-checksums --older-than 5y --commit --force   # no prompt
EOF
}

# Main arg loop. --list takes an optional positional pattern; everything else
# takes a mandatory following value. Anything unknown is an error.
if [[ $# -eq 0 ]]; then
	usage
	exit 1
fi

# Require a value for a flag: reject BOTH a missing next token AND a flag-shaped
# one (begins with '-'). The old guards only checked emptiness, so e.g.
# `--target --stop-docker` silently swallowed --stop-docker as the target value,
# dropped the real flag, and (with --force skipping confirmation) extracted to a
# CWD dir literally named "--stop-docker". A backup path/duration/hostname never
# legitimately begins with '-', so rejecting it is safe.
_need_val() {  # $1 = flag name, $2 = next token (pass "${2:-}")
	if [[ -z "$2" || "$2" == -* ]]; then
		echo "ERROR: $1 requires a value (got '${2:-<none>}')" >&2
		exit 1
	fi
}

# Reject a second, different command flag instead of silently letting the last
# one win (which would drop the operator's earlier operands — e.g. a --restore
# that never takes the restore lock).
_set_mode() {  # $1 = the command being requested
	if [[ -n "$MODE" && "$MODE" != "$1" ]]; then
		echo "ERROR: conflicting commands: --$MODE and --$1 (choose one)" >&2
		exit 1
	fi
	MODE="$1"
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--list)
		_set_mode "list"
		# Optional pattern follows only if the next arg isn't another flag.
		if [[ -n "${2:-}" && "${2:0:2}" != "--" && "${2:0:1}" != "-" ]]; then
			LIST_PATTERN="$2"
			shift
		fi
		;;
	--inspect)
		_set_mode "inspect"
		_need_val "--inspect" "${2:-}"
		ARCHIVE="$2"
		shift
		;;
	--verify)
		_set_mode "verify"
		_need_val "--verify" "${2:-}"
		ARCHIVE="$2"
		shift
		;;
	--verify-all) _set_mode "verify-all" ;;
	--corruption-report) _set_mode "corruption-report" ;;
	--host)
		_need_val "--host" "${2:-}"
		HOST_OVERRIDE="$2"
		shift
		;;
	--restore)
		_set_mode "restore"
		_need_val "--restore" "${2:-}"
		ARCHIVE="$2"
		shift
		;;
	--target)
		_need_val "--target" "${2:-}"
		TARGET="$2"
		shift
		;;
	--only)
		_need_val "--only" "${2:-}"
		ONLY_PATHS+=("$2")
		shift
		;;
	--stop-docker) STOP_DOCKER="true" ;;
	--force) FORCE="true" ;;
	--no-verify) VERIFY_BEFORE_RESTORE="false" ;;
	--dry-run) DRY_RUN="true" ;;
	--prune-checksums) _set_mode "prune-checksums" ;;
	--older-than)
		_need_val "--older-than" "${2:-}"
		PRUNE_OLDER_THAN="$2"
		shift
		;;
	--commit) PRUNE_COMMIT="true" ;;
	--config=* | -c=*) ;;                # already captured by the pre-pass
	--config | -c)
		_need_val "$1" "${2:-}"
		shift
		;;
	-h | --help) usage; exit 0 ;;
	*)
		echo "ERROR: Unknown argument: $1" >&2
		echo "Try $0 --help" >&2
		exit 1
		;;
	esac
	shift
done

if [[ -z "$MODE" ]]; then
	usage
	exit 1
fi

# ==============================================================================
# 3. UTILITIES
# ==============================================================================

# Parse a duration string like "5y", "12m", "365d" into a cutoff date
# (YYYYMMDD) representing "today minus that duration". Echoes the
# cutoff on stdout; returns non-zero (and emits nothing) if the input
# doesn't match the strict Nd / Nm / Ny grammar. Months and years use GNU
# date calendar arithmetic, so the cutoff honours real month lengths and
# leap days (e.g. 12m == 1y, and 1y is exactly one calendar year back).
parse_duration_to_cutoff() {
	local input="$1"
	local n unit
	if [[ "$input" =~ ^([0-9]+)([dmy])$ ]]; then
		n="${BASH_REMATCH[1]}"
		unit="${BASH_REMATCH[2]}"
	else
		return 1
	fi
	case "$unit" in
		d) date -d "${n} days ago"   +%Y%m%d 2>/dev/null ;;
		m) date -d "${n} months ago" +%Y%m%d 2>/dev/null ;;
		y) date -d "${n} years ago"  +%Y%m%d 2>/dev/null ;;
	esac
}

# Format byte count as human-readable with an appropriate unit.
human_size() {
	local bytes="$1"
	awk -v b="$bytes" 'BEGIN {
		if      (b >= 1099511627776) printf "%.1fT", b/1099511627776
		else if (b >= 1073741824)    printf "%.1fG", b/1073741824
		else if (b >= 1048576)       printf "%.1fM", b/1048576
		else if (b >= 1024)          printf "%.1fK", b/1024
		else                         printf "%dB", b
	}'
}

# Resolve the dated .sha256 sibling path for an archive. Mirrors
# auto-backupper's checksum_find_path(): the on-disk filename embeds a
# discovery date as an _<YYYYMMDD> suffix before .sha256, so the lookup
# is a glob rather than a 1:1 path map. Echoes the resolved path on
# stdout. Exit codes distinguish three failure modes so the caller can
# preserve the historical NO_BASE / NO_CHECKSUM distinction:
#   0 — found (path on stdout)
#   1 — file is not under BACKUP_BASE      (NO_BASE)
#   2 — under base but no dated checksum   (NO_CHECKSUM)
checksum_find_path() {
	local file="$1"
	case "$file" in
	"$BACKUP_BASE"/*) ;;
	*)
		return 1
		;;
	esac
	local rel="${file#"$BACKUP_BASE"/}"
	local chk_dir="$BACKUP_BASE/${CHECKSUM_DIR}/$(dirname "$rel")"
	local name
	name="$(basename "$rel")"
	local matches=()
	local m
	shopt -s nullglob
	for m in "${chk_dir}/${name}"_[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9].sha256; do
		matches+=("$m")
	done
	shopt -u nullglob
	if [[ ${#matches[@]} -eq 0 ]]; then
		return 2
	fi
	# YYYYMMDD sorts chronologically as a string; lexicographic tail
	# wins gives the newest discovery date if multiple siblings exist
	# (transient duplicate after a regen on a later day).
	printf '%s\n' "${matches[@]}" | sort | tail -1
	return 0
}

# Verify one archive. Echoes a status token and returns a specific exit code
# so callers can differentiate between missing-checksum and actual corruption.
#
# Status tokens (stdout):     Return code:
#   OK           match              0
#   NO_CHECKSUM  no sha256 file     3
#   MISMATCH     hash differs       1
#   HASH_ERROR   sha256sum failed   4
#   NO_BASE      not under base     2
verify_archive() {
	local archive="$1"
	local chk fp_rc=0
	chk=$(checksum_find_path "$archive" 2>/dev/null) || fp_rc=$?
	case "$fp_rc" in
	0) : ;;
	1)
		echo "NO_BASE"
		return 2
		;;
	2)
		echo "NO_CHECKSUM"
		return 3
		;;
	*)
		echo "NO_CHECKSUM"
		return 3
		;;
	esac

	local exp act
	exp=$(tr -d ' \t\r\n' <"$chk" 2>/dev/null)
	# Mirror auto-backupper's 10-minute ceiling on the hash so a stale FUSE
	# mount or frozen disk fails the verification instead of wedging.
	act=$(timeout 600 sha256sum "$archive" 2>/dev/null | awk '{print $1}')
	if [[ -z "$act" ]]; then
		echo "HASH_ERROR"
		return 4
	fi
	if [[ "$exp" != "$act" ]]; then
		echo "MISMATCH"
		return 1
	fi
	echo "OK"
	return 0
}

# ------------------------------------------------------------------------------
# Corruption-report cross-reference
#
# Watchtower writes a per-host append-only log at
#   $BACKUP_BASE/$CHECKSUM_DIR/<hostname>_corruption_report.txt
# with one line per SHA-mismatch event:
#   [<date>] CORRUPTION: <absolute path>
# It is never pruned by the daemon, so any entry means *"flagged at some
# point in the past"* — not *"currently corrupt"*. We aggregate by path
# into an associative array so every callsite in the restorer can ask
# the same question ("how many times has this been flagged?") in O(1).
#
# Why one shared map rather than re-parsing per file: cmd_list and
# cmd_verify_all touch every archive, and re-grepping a multi-MB report
# per file would dominate their runtime. Loading once is also closer to
# the documented mental model — "the report" is a single artifact.
# ------------------------------------------------------------------------------

declare -A CORRUPTION_COUNTS=()
CORRUPTION_REPORT_LOADED=""

# Resolve the corruption-report path for the active host. --host overrides
# the default local short hostname so a restore on a replacement machine
# can read the original host's report.
#
# `hostname -s` is inetutils-only and breaks on hosts that ship the GNU
# coreutils hostname (Debian/Ubuntu/Arch default), so the resolver here
# pipes through cut to keep the suite portable. The output is then
# uppercased to match the canonical hostname convention used by every
# writer in the suite (watchtower, auto-backupper, warphole) — see
# the matching block in auto-backupper.sh for the full rationale.
# `--host` values are NOT uppercased: a user passing `--host srv01`
# can still read a literal lowercase legacy report by typing the case
# they want.
corruption_report_path() {
	local host="${HOST_OVERRIDE:-$(hostname | cut -d. -f1 | tr '[:lower:]' '[:upper:]')}"
	printf '%s/%s/%s_corruption_report.txt' "$BACKUP_BASE" "$CHECKSUM_DIR" "$host"
}

# List sibling host reports we found under .checksums/ — used when the
# requested host's report is missing so the user knows what's available.
# Echoes one hostname per line; nothing if no reports are present.
list_other_host_reports() {
	local dir="$BACKUP_BASE/$CHECKSUM_DIR"
	[[ -d "$dir" ]] || return 0
	shopt -s nullglob
	local f host_part
	for f in "$dir"/*_corruption_report.txt; do
		host_part="$(basename "$f")"
		printf '%s\n' "${host_part%_corruption_report.txt}"
	done
	shopt -u nullglob
}

# Populate CORRUPTION_COUNTS from the active host's report. Safe to call
# multiple times — the map is cleared on each call. Missing report is
# not an error: the map ends up empty and every hist_corrupt_count
# lookup returns 0, so all integration points become no-ops.
load_corruption_report() {
	CORRUPTION_COUNTS=()
	CORRUPTION_REPORT_LOADED=""
	local path
	path=$(corruption_report_path)
	[[ -f "$path" ]] || return 0
	CORRUPTION_REPORT_LOADED="$path"
	local line file prev
	while IFS= read -r line || [[ -n "$line" ]]; do
		# Match watchtower's format: `[<date>] CORRUPTION: <path>`.
		# Anything else (rotated header, blank line) is skipped.
		if [[ "$line" =~ \]\ CORRUPTION:\ (.+)$ ]]; then
			file="${BASH_REMATCH[1]}"
			prev="${CORRUPTION_COUNTS[$file]:-0}"
			CORRUPTION_COUNTS["$file"]=$((prev + 1))
		fi
	done <"$path"
}

# Return the recorded count for a path. 0 = never flagged. The lookup
# uses `${arr[$k]:-0}` which is safe under set -u on bash 4.4+ (our
# documented floor is 4.0 but in practice all suite hosts run 5.x).
hist_corrupt_count() {
	echo "${CORRUPTION_COUNTS["$1"]:-0}"
}

# Detect OS family — same logic as auto-backupper, copied (not sourced) to
# keep the restorer self-contained. Used only to pick the Docker strategy.
detect_os() {
	if [[ -f "/etc/unraid-version" ]]; then
		echo "unraid"
	elif command -v omv-notify >/dev/null 2>&1; then
		echo "omv"
	else
		echo "linux"
	fi
}

# Pick a compression flag for tar based on the archive's extension. We don't
# rely on tar's -a auto-detect because some older busybox tars don't support
# it. Echoes the appropriate short flag.
tar_decompress_flag() {
	case "$1" in
	*.tar.gz | *.tgz) echo "-z" ;;
	*.tar.bz2 | *.tbz2) echo "-j" ;;
	*.tar.xz | *.txz) echo "-J" ;;
	*.tar.zst) echo "--zstd" ;;
	*.tar) echo "" ;;
	*)
		log "ERROR: Unrecognised archive extension: $1"
		return 1
		;;
	esac
}

# ==============================================================================
# 4. DOCKER MANAGEMENT (restore-side)
# ==============================================================================
#
# Deliberately simpler than auto-backupper's full strategy tree. We only need
# "stop everything before we clobber /mnt/cache/appdata, restart everything
# after". No container enumeration, no docker.img remount — if the user is
# doing a system restore that overwrites docker.img, they MUST pass
# --stop-docker; on Unraid the service stop takes care of the mount, on
# other Linuxes the daemon will re-open the fresh file on restart.

# Restore-time record of which containers we stopped (to restart them after).
# Lives in the shared enclave with the rest of the suite's IPC/working state.
UNRAID_CONTAINERS_LIST="/var/opt/enclave/auto_restorer_containers.list"

docker_stop_for_restore() {
	if [[ "$DRY_RUN" == "true" ]]; then
		log "[DRY] Would stop Docker for restore"
		return 0
	fi

	local os_type
	os_type=$(detect_os)

	case "$os_type" in
	unraid)
		if [[ -x "/etc/rc.d/rc.docker" ]]; then
			log "Stopping Unraid Docker service..."
			/etc/rc.d/rc.docker stop >/dev/null 2>&1 || true
			# Give the service a moment to release locks on docker.img
			local elapsed=0
			while /etc/rc.d/rc.docker status 2>/dev/null | grep -q "running"; do
				sleep 3
				elapsed=$((elapsed + 3))
				if [[ $elapsed -ge $DOCKER_STOP_TIMEOUT ]]; then
					log "WARN: Docker service stop timed out at ${DOCKER_STOP_TIMEOUT}s; forcing."
					/etc/rc.d/rc.docker force_stop >/dev/null 2>&1 || true
					break
				fi
			done
		else
			log "WARN: /etc/rc.d/rc.docker not found on Unraid (skipping stop)"
		fi
		;;
	*)
		if command -v docker >/dev/null 2>&1; then
			log "Recording running containers, then stopping them..."
			# Record so we can restart the same set afterward. If the list
			# file already exists from a crashed previous run, overwrite it
			# — stale state is worse than a partial list.
			mkdir -p "$(dirname "$UNRAID_CONTAINERS_LIST")" 2>/dev/null || true
			docker ps --format '{{.Names}}' >"$UNRAID_CONTAINERS_LIST" 2>/dev/null || true
			# `xargs -r` avoids invoking docker with no args when there are
			# no containers to stop. --time flag matches auto-backupper's
			# DOCKER_STOP_TIMEOUT semantics.
			if [[ -s "$UNRAID_CONTAINERS_LIST" ]]; then
				xargs -r docker stop --time "$DOCKER_STOP_TIMEOUT" <"$UNRAID_CONTAINERS_LIST" >/dev/null 2>&1 || true
			fi
		else
			log "INFO: docker command not present — nothing to stop"
		fi
		;;
	esac
}

docker_start_after_restore() {
	if [[ "$DRY_RUN" == "true" ]]; then
		log "[DRY] Would restart Docker after restore"
		return 0
	fi

	local os_type
	os_type=$(detect_os)

	case "$os_type" in
	unraid)
		if [[ -x "/etc/rc.d/rc.docker" ]]; then
			log "Restarting Unraid Docker service..."
			/etc/rc.d/rc.docker start >/dev/null 2>&1 || true
		fi
		;;
	*)
		if [[ -s "$UNRAID_CONTAINERS_LIST" ]] && command -v docker >/dev/null 2>&1; then
			log "Restarting previously-recorded containers..."
			while IFS= read -r c; do
				[[ -z "$c" ]] && continue
				docker start "$c" >/dev/null 2>&1 || log "  WARN: could not start $c"
			done <"$UNRAID_CONTAINERS_LIST"
			rm -f "$UNRAID_CONTAINERS_LIST"
		else
			log "INFO: No container list to restart (either nothing was stopped or the list is missing)"
		fi
		;;
	esac
}

# Safety net: if the script exits during a restore while Docker is stopped,
# try to bring it back. Mirrors auto-backupper's STATE_FILE recovery approach
# (simplified: no persistent state — if we stopped it, we try to start it).
DOCKER_WAS_STOPPED="false"

on_exit() {
	if [[ "$DOCKER_WAS_STOPPED" == "true" ]]; then
		log "RECOVERY: Exit detected while Docker was stopped; attempting restart..."
		docker_start_after_restore || true
	fi
}
trap 'on_exit' EXIT

# ==============================================================================
# 5. COMMANDS
# ==============================================================================

# --- LIST ----------------------------------------------------------------------

cmd_list() {
	if [[ ! -d "$BACKUP_BASE" ]]; then
		log "ERROR: BACKUP_BASE not found: $BACKUP_BASE"
		return 1
	fi

	# Load the historical corruption report once so we can annotate
	# previously-flagged files with [HIST-CORRUPT] / [HIST-CORRUPT×N].
	load_corruption_report

	log "Listing archives in $BACKUP_BASE (pattern: $LIST_PATTERN)"

	# Gather all archives into an array. -path prune excludes the .checksums
	# tree; find's -name matches the basename so patterns like 'codebase*'
	# Just Work without users having to anchor them.
	local -a archives=()
	while IFS= read -r -d '' f; do
		archives+=("$f")
	done < <(find "$BACKUP_BASE" \
		-path "$BACKUP_BASE/${CHECKSUM_DIR}" -prune -o \
		-type f \( -name "*.tar.gz" -o -name "*.tgz" -o -name "*.tar" \) \
		-name "$LIST_PATTERN" -print0 2>/dev/null | sort -z)

	if [[ ${#archives[@]} -eq 0 ]]; then
		echo "No archives found matching '$LIST_PATTERN' under $BACKUP_BASE."
		return 0
	fi

	# Categorise by top-level directory under BACKUP_BASE. Anything that
	# doesn't match the known layout goes into OTHER so the user sees it.
	local -a systems=() shares=() services=() other=()
	local f
	for f in "${archives[@]}"; do
		case "$f" in
		"$BACKUP_BASE"/systems/*) systems+=("$f") ;;
		"$BACKUP_BASE"/shares/*) shares+=("$f") ;;
		"$BACKUP_BASE"/services/*) services+=("$f") ;;
		*) other+=("$f") ;;
		esac
	done

	# strip_prefix is the leading "<category>/" segment that's redundant
	# under the section header — pass empty for OTHER, where no shared
	# prefix exists.
	_print_category() {
		local title="$1"
		local strip_prefix="$2"
		shift 2
		[[ $# -eq 0 ]] && return
		echo ""
		echo "=== $title ==="
		local f size_bytes size_h date_h chk chk_status rel hist_count hist_marker
		for f in "$@"; do
			size_bytes=$(stat -c%s "$f" 2>/dev/null || echo 0)
			size_h=$(human_size "$size_bytes")
			date_h=$(date -r "$f" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "    unknown    ")
			if chk=$(checksum_find_path "$f" 2>/dev/null); then
				chk_status="[chk]"
			else
				chk_status="[NO CHK]"
			fi
			hist_count=$(hist_corrupt_count "$f")
			if ((hist_count == 1)); then
				hist_marker=" [HIST-CORRUPT]"
			elif ((hist_count > 1)); then
				hist_marker=" [HIST-CORRUPT×${hist_count}]"
			else
				hist_marker=""
			fi
			rel="${f#"$BACKUP_BASE"/}"
			[[ -n "$strip_prefix" ]] && rel="${rel#"$strip_prefix"}"
			printf "  %-58s %8s  %s  %s%s\n" "$rel" "$size_h" "$date_h" "$chk_status" "$hist_marker"
		done
	}

	(( ${#systems[@]}  > 0 )) && _print_category "SYSTEMS"  "systems/"  "${systems[@]}"
	(( ${#shares[@]}   > 0 )) && _print_category "SHARES"   "shares/"   "${shares[@]}"
	(( ${#services[@]} > 0 )) && _print_category "SERVICES" "services/" "${services[@]}"
	(( ${#other[@]}    > 0 )) && _print_category "OTHER"    ""          "${other[@]}"

	echo ""
	echo "Total: ${#archives[@]} archive(s) in $BACKUP_BASE"
}

# --- INSPECT -------------------------------------------------------------------

cmd_inspect() {
	local archive="$ARCHIVE"
	if [[ ! -f "$archive" ]]; then
		log "ERROR: Archive not found: $archive"
		return 1
	fi

	local dflag
	dflag=$(tar_decompress_flag "$archive") || return 1

	log "Inspecting: $archive"
	echo ""

	# Previewing an archive is a "best effort" operation — even a corrupt
	# archive should let the user see whatever is readable. With `set -o
	# pipefail` enabled globally, a `tar -tf | head -100` pipeline exits
	# non-zero if tar trips on trailing garbage (gzip's "trailing garbage
	# ignored" surfaces as tar exit 2), which under set -e would kill the
	# whole script mid-inspect. `|| true` absorbs that so we always print
	# what we got.
	local total
	if [[ -n "$dflag" ]]; then
		total=$(tar "$dflag" -tf "$archive" 2>/dev/null | wc -l || true)
		tar "$dflag" -tvf "$archive" 2>/dev/null | head -100 || true
	else
		total=$(tar -tf "$archive" 2>/dev/null | wc -l || true)
		tar -tvf "$archive" 2>/dev/null | head -100 || true
	fi

	echo ""
	echo "Total entries: $total (first 100 shown)"
}

# --- VERIFY ONE ----------------------------------------------------------------

cmd_verify() {
	local archive="$ARCHIVE"
	if [[ ! -f "$archive" ]]; then
		log "ERROR: Archive not found: $archive"
		return 1
	fi

	# Load the corruption report so a FAIL line can be annotated `chronic`
	# (i.e. the file has been flagged before — operator may want to retire
	# the underlying disk rather than just re-pull).
	load_corruption_report

	log "Verifying: $archive"
	local status rc=0 hc chronic_tag
	status=$(verify_archive "$archive") || rc=$?
	hc=$(hist_corrupt_count "$archive")
	chronic_tag=""
	if ((hc > 0)); then
		chronic_tag=" (chronic — ${hc} prior event(s))"
	fi
	case "$status" in
	OK)
		if ((hc > 0)); then
			log "  OK: $archive [HIST-CLEARED — ${hc} prior event(s), now clean]"
		else
			log "  OK: $archive"
		fi
		;;
	NO_CHECKSUM) log "  WARN: No checksum file for $archive (watchtower may not have scanned yet)" ;;
	MISMATCH)    log "  FAIL: Checksum mismatch for $archive${chronic_tag}" ;;
	HASH_ERROR)  log "  FAIL: Could not hash $archive (timeout or I/O error)${chronic_tag}" ;;
	NO_BASE)     log "  WARN: $archive is not under BACKUP_BASE; no checksum resolvable" ;;
	esac
	# A not-yet-scanned archive (NO_CHECKSUM) or one outside BACKUP_BASE
	# (NO_BASE) is a warning, not a failure — match cmd_verify_all's policy so
	# `--verify FILE || alert` does not false-alarm on a benign just-made
	# backup. MISMATCH(1)/HASH_ERROR(4) still propagate as failures.
	case "$status" in NO_CHECKSUM | NO_BASE) rc=0 ;; esac
	return "$rc"
}

# --- VERIFY ALL ----------------------------------------------------------------

cmd_verify_all() {
	if [[ ! -d "$BACKUP_BASE" ]]; then
		log "ERROR: BACKUP_BASE not found: $BACKUP_BASE"
		return 1
	fi

	# Load the corruption report so each FAIL line can be flagged `chronic`
	# and each OK line on a previously-flagged file gets [HIST-CLEARED].
	load_corruption_report

	log "Verifying every archive under $BACKUP_BASE..."

	local ok=0 missing=0 failed=0 cleared=0 chronic=0 total=0
	local f status rc hc
	while IFS= read -r -d '' f; do
		total=$((total + 1))
		rc=0
		status=$(verify_archive "$f") || rc=$?
		hc=$(hist_corrupt_count "$f")
		case "$status" in
		OK)
			ok=$((ok + 1))
			if ((hc > 0)); then
				cleared=$((cleared + 1))
				log "  [HIST-CLEARED] ${f#"$BACKUP_BASE"/}  (${hc} prior event(s))"
			fi
			;;
		NO_CHECKSUM)
			missing=$((missing + 1))
			log "  [NO CHK] ${f#"$BACKUP_BASE"/}"
			;;
		MISMATCH | HASH_ERROR)
			failed=$((failed + 1))
			if ((hc > 0)); then
				chronic=$((chronic + 1))
				log "  [FAIL]   ${f#"$BACKUP_BASE"/}  ($status, chronic — ${hc} prior event(s))"
			else
				log "  [FAIL]   ${f#"$BACKUP_BASE"/}  ($status)"
			fi
			;;
		esac
	done < <(find "$BACKUP_BASE" \
		-path "$BACKUP_BASE/${CHECKSUM_DIR}" -prune -o \
		-type f \( -name "*.tar.gz" -o -name "*.tgz" -o -name "*.tar" \) \
		-print0 2>/dev/null)

	echo ""
	log "Summary: $total total, $ok verified, $failed failed, $missing without checksum"
	if ((cleared > 0 || chronic > 0)); then
		log "         History: $cleared cleared (stale report entries), $chronic chronic (current+past failure)"
	fi

	# Non-zero exit iff something actually failed (missing checksums are a
	# warning, not a failure — they'll be created by watchtower's next pass).
	[[ $failed -gt 0 ]] && return 1
	return 0
}

# --- RESTORE -------------------------------------------------------------------

confirm() {
	# $1 = prompt text. Returns 0 on y/Y, 1 otherwise. --force bypasses.
	[[ "$FORCE" == "true" ]] && return 0
	local ans
	printf '%s [y/N]: ' "$1"
	read -r ans
	[[ "$ans" == "y" || "$ans" == "Y" ]]
}

cmd_restore() {
	local archive="$ARCHIVE"
	local target="$TARGET"

	# ---- Input validation ----
	if [[ -z "$archive" ]]; then
		log "ERROR: --restore requires an archive path"
		return 1
	fi
	if [[ ! -f "$archive" ]]; then
		log "ERROR: Archive not found: $archive"
		return 1
	fi
	if [[ -z "$target" ]]; then
		log "ERROR: --target is required for --restore (see 'Archive target hints' in --help)"
		return 1
	fi

	# Load the corruption report so the plan can surface any prior events
	# against this archive. The SHA compare below remains authoritative
	# (a clean archive will always restore); history is advisory only.
	load_corruption_report
	local hist_count
	hist_count=$(hist_corrupt_count "$archive")

	local dflag
	dflag=$(tar_decompress_flag "$archive") || return 1

	# ---- Pre-restore checksum ----
	if [[ "$VERIFY_BEFORE_RESTORE" == "true" ]]; then
		log "Pre-restore verification..."
		local status rc=0
		status=$(verify_archive "$archive") || rc=$?
		case "$status" in
		OK)
			log "  Archive checksum OK."
			;;
		NO_CHECKSUM)
			log "  WARN: No checksum recorded for this archive."
			if ! confirm "Proceed without verification?"; then
				log "Aborted by user."
				return 1
			fi
			;;
		NO_BASE)
			log "  WARN: Archive is outside BACKUP_BASE; cannot verify."
			if ! confirm "Proceed without verification?"; then
				log "Aborted by user."
				return 1
			fi
			;;
		MISMATCH)
			log "FATAL: Archive checksum does NOT match recorded value."
			log "       Refusing to restore corrupt data. Override with --no-verify if"
			log "       you've audited the file and believe the checksum is stale."
			return 1
			;;
		HASH_ERROR)
			log "FATAL: Could not hash archive (timeout or I/O error). Retry later."
			return 1
			;;
		*)
			log "FATAL: Unknown verification status: $status"
			return 1
			;;
		esac
	else
		log "WARN: --no-verify supplied; skipping pre-restore checksum."
	fi

	# ---- Target existence ----
	if [[ ! -d "$target" ]]; then
		log "Target directory does not exist: $target"
		if [[ "$DRY_RUN" != "true" ]]; then
			if confirm "Create it?"; then
				mkdir -p -- "$target" || {
					log "FATAL: Could not create $target"
					return 1
				}
			else
				log "Aborted."
				return 1
			fi
		fi
	fi

	# ---- Restore plan (shown before execution) ----
	# A `NOTE:` banner is printed before the plan when the archive has
	# prior corruption events. The SHA check above is authoritative, so
	# we wouldn't reach this point if the archive was currently corrupt
	# — the warning exists so the operator knows to spot-check the
	# extracted data even though the bits look clean today.
	if ((hist_count > 0)); then
		echo ""
		echo "!! NOTE: This archive was flagged as corrupt ${hist_count} time(s) in the past."
		echo "!!       The current SHA matches, so the restore will proceed, but consider"
		echo "!!       spot-checking the extracted data and investigating the underlying"
		echo "!!       storage (see --corruption-report for the full picture)."
	fi
	echo ""
	echo "================ RESTORE PLAN ================"
	echo "  Archive:      $archive"
	echo "  Target:       $target"
	echo "  Stop Docker:  $STOP_DOCKER"
	echo "  Dry run:      $DRY_RUN"
	echo "  Force:        $FORCE"
	if ((${#ONLY_PATHS[@]} > 0)); then
		echo "  Only paths:   (${#ONLY_PATHS[@]}) — partial extraction"
		local _p
		for _p in "${ONLY_PATHS[@]}"; do
			echo "                  $_p"
		done
	fi
	if ((hist_count > 0)); then
		echo "  History:      ${hist_count} prior corruption event(s) for this archive"
	fi
	echo ""
	if ((${#ONLY_PATHS[@]} > 0)); then
		echo "  First 10 entries matching --only filter:"
		# Use the same dflag-aware tar invocation as the full preview but
		# pass the user-supplied paths so the preview reflects exactly
		# what will be extracted.
		if [[ -n "$dflag" ]]; then
			tar "$dflag" -tf "$archive" -- "${ONLY_PATHS[@]}" 2>/dev/null | head -10 | sed 's/^/    /' || true
		else
			tar -tf "$archive" -- "${ONLY_PATHS[@]}" 2>/dev/null | head -10 | sed 's/^/    /' || true
		fi
	else
		echo "  First 10 entries in the archive:"
		# `|| true` — see cmd_inspect. A corrupt archive should still show a
		# preview rather than aborting the whole plan screen.
		if [[ -n "$dflag" ]]; then
			tar "$dflag" -tf "$archive" 2>/dev/null | head -10 | sed 's/^/    /' || true
		else
			tar -tf "$archive" 2>/dev/null | head -10 | sed 's/^/    /' || true
		fi
	fi
	echo "=============================================="
	echo ""

	# Big warning for restoring to /  —  this overwrites system paths and
	# should absolutely not be a silent operation.
	if [[ "$target" == "/" ]]; then
		echo "!! Target is / — this will overwrite whatever paths are in the archive."
		echo "!! Commonly this is appdata + boot + docker.img; make sure you know what's"
		echo "!! in the archive and that Docker is stopped (use --stop-docker)."
		echo ""
	fi

	if ! confirm "Proceed with restore?"; then
		log "Aborted by user."
		return 1
	fi

	# ---- Docker stop ----
	if [[ "$STOP_DOCKER" == "true" ]]; then
		docker_stop_for_restore
		DOCKER_WAS_STOPPED="true"
	fi

	# ---- Extraction ----
	if ((${#ONLY_PATHS[@]} > 0)); then
		log "Extracting ${#ONLY_PATHS[@]} path(s) from $archive into $target ..."
	else
		log "Extracting $archive into $target ..."
	fi
	local extract_rc=0
	if [[ "$DRY_RUN" == "true" ]]; then
		if ((${#ONLY_PATHS[@]} > 0)); then
			log "[DRY] tar -x${dflag:+ $dflag} -f $archive -C $target ${ONLY_PATHS[*]}"
		else
			log "[DRY] tar -x${dflag:+ $dflag} -f $archive -C $target"
		fi
	else
		# -p preserves permissions; --same-owner preserves UID/GID (matters
		# for appdata restore where container UIDs must match). Both are
		# defaults under root on GNU tar but explicit is better.
		#
		# With --only, the path filter goes at the end of the argv as
		# positional args (tar's "MEMBERS" selection); without it, tar
		# extracts the full archive.
		if [[ -n "$dflag" ]]; then
			if ((${#ONLY_PATHS[@]} > 0)); then
				tar "$dflag" -xpf "$archive" -C "$target" --same-owner -- "${ONLY_PATHS[@]}" || extract_rc=$?
			else
				tar "$dflag" -xpf "$archive" -C "$target" --same-owner || extract_rc=$?
			fi
		else
			if ((${#ONLY_PATHS[@]} > 0)); then
				tar -xpf "$archive" -C "$target" --same-owner -- "${ONLY_PATHS[@]}" || extract_rc=$?
			else
				tar -xpf "$archive" -C "$target" --same-owner || extract_rc=$?
			fi
		fi
	fi

	if [[ $extract_rc -ne 0 ]]; then
		log "ERROR: Extraction failed with code $extract_rc"
		# Still try to restart Docker if we stopped it — leaving the user
		# with a stopped Docker is worse than leaving them with a half-
		# restored tree they can re-run against.
		if [[ "$STOP_DOCKER" == "true" ]]; then
			docker_start_after_restore
			DOCKER_WAS_STOPPED="false"
		fi
		return 1
	fi
	log "Extraction complete."

	# ---- Docker restart ----
	if [[ "$STOP_DOCKER" == "true" ]]; then
		docker_start_after_restore
		DOCKER_WAS_STOPPED="false"
	fi

	log "RESTORE SUCCEEDED: $archive -> $target"
	return 0
}

# --- CORRUPTION REPORT ---------------------------------------------------------
#
# Read-only summary of watchtower's per-host corruption log, aggregated
# by path with the file's *current* SHA status. Because the underlying
# log is append-only and never pruned, this command is the
# user-friendly way to ask "what's still bad vs. what aged out vs. what
# was a transient blip" without grepping a raw text file.
#
# Status column semantics (mirrors README):
#   BAD  Path still exists, SHA currently fails → active corruption.
#   OK   Path still exists, SHA matches now → stale report entry.
#   -    Path is no longer on disk (rotated away or deleted).
#   ?    Path exists but no checksum recorded (or outside BACKUP_BASE).
#
# This command takes no lock — it is read-only and safe to run during a
# scheduled backup.
cmd_corruption_report() {
	if [[ ! -d "$BACKUP_BASE" ]]; then
		log "ERROR: BACKUP_BASE not found: $BACKUP_BASE"
		return 1
	fi

	load_corruption_report

	# Match the casing convention used by corruption_report_path() so the
	# "no report for host X" diagnostic agrees with the path probed.
	local host="${HOST_OVERRIDE:-$(hostname | cut -d. -f1 | tr '[:lower:]' '[:upper:]')}"
	local report_path
	report_path=$(corruption_report_path)

	# Missing report: show the path we looked for, then hint at any
	# sibling host reports the operator might have meant. Common when
	# restoring on a replacement box whose hostname differs from the
	# original.
	if [[ -z "$CORRUPTION_REPORT_LOADED" ]]; then
		log "No corruption report found for host '$host' at $report_path"
		local other
		other=$(list_other_host_reports)
		if [[ -n "$other" ]]; then
			echo ""
			echo "Available host reports under $BACKUP_BASE/$CHECKSUM_DIR:"
			while IFS= read -r h; do
				[[ -n "$h" ]] && echo "  $h"
			done <<<"$other"
			echo ""
			echo "Re-run with --host HOSTNAME to read another host's report."
		fi
		return 0
	fi

	local total_paths=${#CORRUPTION_COUNTS[@]}
	log "Corruption report: $report_path"
	log "Unique paths flagged: ${total_paths}"

	if ((total_paths == 0)); then
		echo "(report file is present but contains no CORRUPTION lines)"
		return 0
	fi

	echo ""
	printf "  %-6s  %-7s  %s\n" "STATUS" "COUNT" "PATH"
	printf "  %-6s  %-7s  %s\n" "------" "-------" "----"

	# Sort paths alphabetically for stable output across runs. The map
	# is small enough (one entry per unique flagged file) that sort
	# overhead is negligible.
	local -a sorted=()
	local p
	while IFS= read -r p; do
		[[ -n "$p" ]] && sorted+=("$p")
	done < <(printf '%s\n' "${!CORRUPTION_COUNTS[@]}" | sort)

	local n_bad=0 n_ok=0 n_gone=0 n_unknown=0
	local status verify_status verify_rc count
	for p in "${sorted[@]}"; do
		count="${CORRUPTION_COUNTS[$p]}"
		if [[ ! -e "$p" ]]; then
			status="-"
			n_gone=$((n_gone + 1))
		else
			verify_rc=0
			verify_status=$(verify_archive "$p") || verify_rc=$?
			case "$verify_status" in
				OK)
					status="OK"
					n_ok=$((n_ok + 1))
					;;
				MISMATCH | HASH_ERROR)
					status="BAD"
					n_bad=$((n_bad + 1))
					;;
				NO_CHECKSUM | NO_BASE | *)
					status="?"
					n_unknown=$((n_unknown + 1))
					;;
			esac
		fi
		printf "  %-6s  %-7s  %s\n" "$status" "$count" "$p"
	done

	echo ""
	log "Summary: ${n_bad} BAD (active), ${n_ok} OK (stale), ${n_gone} no longer present, ${n_unknown} unknown"

	# Non-zero exit iff we found currently-failing files. Makes the
	# command usable as a cron health check ("cron @daily
	# auto-restorer --corruption-report || mail ...").
	((n_bad > 0)) && return 1
	return 0
}

# --- PRUNE CHECKSUMS -----------------------------------------------------------
#
# Manual, opt-in cleanup of the .checksums/ index. The index is the suite's
# distributed historical record (auto-backupper.sh's rotation_phase
# intentionally leaves checksums behind when it evicts data), so it grows
# monotonically as backups age out across the fleet. This command lets an
# operator reclaim space once the index has truly outlived its usefulness.
#
# Safety properties:
#   - Only orphan checksums (data file missing locally) are considered. A
#     checksum whose data file is still present is never deleted, because
#     that would leave a present-but-unverifiable backup until watchtower
#     re-stamps it on the next scan.
#   - Default is dry-run preview. --commit is required to actually delete.
#   - --commit prompts for confirmation unless --force is also given.
#   - The candidate list is written to a temp file so it can be inspected
#     out-of-band (preserved in dry-run, removed after a successful commit).
cmd_prune_checksums() {
	if [[ -z "$PRUNE_OLDER_THAN" ]]; then
		log "ERROR: --prune-checksums requires --older-than DURATION (e.g. 5y, 12m, 90d)"
		return 1
	fi

	local cutoff_date
	# Use `if !` so a grammar mismatch (the function's `return 1`) doesn't trip
	# set -e at the assignment before this friendly message can print.
	if ! cutoff_date=$(parse_duration_to_cutoff "$PRUNE_OLDER_THAN") || [[ -z "$cutoff_date" ]]; then
		log "ERROR: Invalid --older-than format: '$PRUNE_OLDER_THAN' — use Nd / Nm / Ny (e.g. 90d, 6m, 5y)"
		return 1
	fi

	if [[ ! -d "$BACKUP_BASE/$CHECKSUM_DIR" ]]; then
		log "No .checksums/ tree at $BACKUP_BASE/$CHECKSUM_DIR — nothing to prune."
		return 0
	fi

	local action_word="DRY-RUN"
	[[ "$PRUNE_COMMIT" == "true" ]] && action_word="COMMIT"

	log "Scanning $BACKUP_BASE/$CHECKSUM_DIR for orphan checksums older than ${PRUNE_OLDER_THAN}"
	log "Mode: ${action_word} | Cutoff: discovery date < ${cutoff_date}"

	local list_file
	list_file=$(mktemp /tmp/auto_restorer_prune.XXXXXX)
	local candidates_count=0

	while IFS= read -r -d '' chk; do
		local cbase date_suffix
		cbase="$(basename "$chk")"
		# Strict suffix anchor — only the trailing _<8 digits>.sha256 counts.
		if [[ "$cbase" =~ _([0-9]{8})\.sha256$ ]]; then
			date_suffix="${BASH_REMATCH[1]}"
		else
			continue
		fi
		# Old enough?
		((10#${date_suffix} < 10#${cutoff_date})) || continue
		# Orphan check: skip if the data file is still present locally.
		# This is the key safety invariant — never delete a checksum
		# whose data file is on disk, because watchtower would have to
		# re-stamp before the file is verifiable again.
		local rel_with_suffix="${chk#"${BACKUP_BASE}/${CHECKSUM_DIR}/"}"
		local data_rel="${rel_with_suffix%_${date_suffix}.sha256}"
		[[ -f "${BACKUP_BASE}/${data_rel}" ]] && continue
		# A legacy un-dated checksum is "<dataname>.sha256"; if <dataname> itself
		# ends in _<8digits> (e.g. data file "report_20231231"), the suffix regex
		# above mis-reads it as dated. Also honour the un-dated reading so a
		# present data file is never classified as an orphan.
		[[ -f "${BACKUP_BASE}/${rel_with_suffix%.sha256}" ]] && continue
		printf '%s\n' "$chk" >>"$list_file"
		candidates_count=$((candidates_count + 1))
	done < <(find "${BACKUP_BASE}/${CHECKSUM_DIR}" -type f -name "*_[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9].sha256" -print0 2>/dev/null)

	log "Found ${candidates_count} orphan checksum(s) older than ${PRUNE_OLDER_THAN}"

	if [[ $candidates_count -eq 0 ]]; then
		rm -f "$list_file"
		return 0
	fi

	# Preview — first 20 candidates by default.
	local preview_limit=20
	echo ""
	echo "Sample of candidates (up to ${preview_limit}):"
	head -n "$preview_limit" "$list_file" | sed 's|^|  |'
	if [[ $candidates_count -gt $preview_limit ]]; then
		echo "  ... and $((candidates_count - preview_limit)) more"
	fi
	echo ""

	if [[ "$PRUNE_COMMIT" != "true" ]]; then
		log "DRY-RUN: pass --commit to actually delete the listed files."
		log "         Full list preserved at: $list_file"
		return 0
	fi

	# --commit path: confirm (unless --force), then delete.
	if ! confirm "Delete ${candidates_count} orphan checksum file(s)?"; then
		log "Aborted by user. Full list preserved at: $list_file"
		return 1
	fi

	local deleted=0 skipped_reappeared=0
	while IFS= read -r chk; do
		[[ -z "$chk" ]] && continue
		# Re-check data-file presence at DELETE time, not just at scan time. The
		# scan->confirm window can be long (operator reading the prompt) and prune
		# holds no lock, so watchtower could have re-stamped or a pull re-created
		# the data file since the scan. Deleting its checksum now would strand a
		# present-but-unverifiable backup. Re-derive data_rel exactly as the scan
		# loop does and skip if the data has reappeared.
		local cbase date_suffix rel_with_suffix data_rel
		cbase="$(basename "$chk")"
		if [[ "$cbase" =~ _([0-9]{8})\.sha256$ ]]; then
			date_suffix="${BASH_REMATCH[1]}"
			rel_with_suffix="${chk#"${BACKUP_BASE}/${CHECKSUM_DIR}/"}"
			data_rel="${rel_with_suffix%_${date_suffix}.sha256}"
			# Skip if EITHER the dated reading's data file is present (TOCTOU
			# reappearance) OR the un-dated reading's data file is present (a
			# legacy "<name>_<8digits>.sha256" whose data is "<name>_<8digits>").
			if [[ -f "${BACKUP_BASE}/${data_rel}" || -f "${BACKUP_BASE}/${rel_with_suffix%.sha256}" ]]; then
				log "SKIP (data file present, keeping checksum): $chk"
				skipped_reappeared=$((skipped_reappeared + 1))
				continue
			fi
		fi
		if rm -f "$chk"; then
			deleted=$((deleted + 1))
		fi
	done <"$list_file"
	log "Deleted ${deleted}/${candidates_count} orphan checksum(s)."
	[[ $skipped_reappeared -gt 0 ]] && log "Skipped ${skipped_reappeared} whose data file reappeared since the scan (kept their checksum)."
	rm -f "$list_file"

	# Tidy now-empty subdirs under .checksums/ (but never the root).
	find "${BACKUP_BASE}/${CHECKSUM_DIR}" -mindepth 1 -type d -empty -delete 2>/dev/null || true
	return 0
}

# ==============================================================================
# 6. EXECUTION
# ==============================================================================

# Acquire a lock for mutating operations only. Listing/inspecting/verifying
# are read-only and safely concurrent with a scheduled backup.
case "$MODE" in
restore)
	# Serialize against the backup worker too: it holds
	# /var/lock/auto_backupper.lock for its whole run, including the rotation
	# phase that rm's aged archives. Without this a restore could read an
	# archive the worker deletes mid-extraction (an operator-initiated restore
	# is not covered by the cross-host "schedules never overlap" guarantee).
	# Use a NON-BLOCKING probe (flock -n), not a wait: the worker unlinks its
	# lockfile while still holding it (anti-stale-inode), so a restore that
	# waited could win a lock on a now-unlinked inode while the next worker
	# creates a fresh inode at the path and runs unserialized. Refusing while a
	# backup is active avoids that race entirely. Open with <> so we never
	# truncate the worker's lockfile, and hold the FD for the restore's
	# lifetime so a backup cannot start mid-restore.
	exec 201<>"/var/lock/auto_backupper.lock"
	if ! flock -n 201; then
		echo "ERROR: auto-backupper worker is active (holds its lock); refusing restore to avoid racing rotation. Retry once the backup finishes, or stop it first." >&2
		exit 1
	fi
	exec 200>"$LOCKFILE"
	if ! flock -n 200; then
		echo "ERROR: Another auto-restorer restore is already running (lockfile held)." >&2
		exit 1
	fi
	# Write our PID into the lockfile so external observers (notably
	# `watchtower.sh --ab-graph`) can attribute the running restore to
	# a specific process. The flock above guarantees we're the sole
	# writer; the FD stays open via `exec 200>` so the lock is held for
	# the lifetime of the script.
	echo $$ >"$LOCKFILE" 2>/dev/null || true
	;;
esac

case "$MODE" in
list)                cmd_list ;;
inspect)             cmd_inspect ;;
verify)              cmd_verify ;;
verify-all)          cmd_verify_all ;;
corruption-report)   cmd_corruption_report ;;
restore)             cmd_restore ;;
prune-checksums)     cmd_prune_checksums ;;
*)
	echo "ERROR: Unknown mode: $MODE" >&2
	exit 1
	;;
esac