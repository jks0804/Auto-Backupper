#!/usr/bin/env bash
export PATH=/sbin:/opt/bin:/usr/local/bin:/usr/contrib/bin:/bin:/usr/bin:/usr/sbin:/usr/bin/X11
#arrayStarted=true
##
#
# ________  ___  ___  _________  ________                 ________  ________  ________  ___  __    ___  ___  ________  ________  _______   ________
#|\   __  \|\  \|\  \|\___   ___\\   __  \               |\   __  \|\   __  \|\   ____\|\  \|\  \ |\  \|\  \|\   __  \|\   __  \|\  ___ \ |\   __  \
#\ \  \|\  \ \  \\\  \|___ \  \_\ \  \|\  \  ____________\ \  \|\ /\ \  \|\  \ \  \___|\ \  \/  /|\ \  \\\  \ \  \|\  \ \  \|\  \ \   __/|\ \  \|\  \
# \ \   __  \ \  \\\  \   \ \  \ \ \  \\\  \|\____________\ \   __  \ \   __  \ \  \    \ \   ___  \ \  \\\  \ \   ____\ \   ____\ \  \_|/_\ \   _  _\
#  \ \  \ \  \ \  \\\  \   \ \  \ \ \  \\\  \|____________|\ \  \|\  \ \  \ \  \ \  \____\ \  \\ \  \ \  \\\  \ \  \___|\ \  \___|\ \  \_|\ \ \  \\  \|
#   \ \__\ \__\ \_______\   \ \__\ \ \_______\              \ \_______\ \__\ \__\ \_______\ \__\\ \__\ \_______\ \__\    \ \__\    \ \_______\ \__\\ _\
#    \|__|\|__|\|_______|    \|__|  \|_______|               \|_______|\|__|\|__|\|_______|\|__| \|__|\|_______|\|__|     \|__|     \|_______|\|__|\|__|
#
#
##
# ==============================================================================
# AUTO-BACKUPPER
# ==============================================================================
# A unified, fault-tolerant backup solution for Unraid, OMV, and Linux.
# ==============================================================================
# LICENSE: GPLv3
# ==============================================================================

set -Eeuo pipefail

# ==============================================================================
# 1. BOOTSTRAP & STATE ENGINE
# ==============================================================================
DEFAULT_CONFIG_FILE="/boot/config/auto_backupper.cfg"
LOGFILE="/var/log/auto_backupper.log"
LOCKFILE="/var/lock/auto_backupper.lock"
# PID file for reliable process identification (read by watchtower --stop-backup).
# Using /var/run survives accidental /tmp clearing but is typically cleared on boot.
BACKUP_PIDFILE="/var/run/auto_backupper.pid"

# --- Enclave & State Paths ---
ENCLAVE_DIR="/tmp/enclave"
STATE_FILE="${ENCLAVE_DIR}/ab_state"
RUNNING_CONTAINERS_LIST="${ENCLAVE_DIR}/containers.list"

# --- IPC / Queue Settings ---
IPC_BASE="${ENCLAVE_DIR}/queue"
IPC_ERRORS="${IPC_BASE}/errors"

# Session manifest: a list of absolute paths to files created by THIS run.
# Populated by create_archive on success, consumed by the verification phase.
# Lives under IPC_BASE so the existing cleanup trap wipes it automatically.
SESSION_MANIFEST="${IPC_BASE}/session_manifest"

CHECKSUM_DIR=".checksums"
# `hostname -s` is inetutils-only and breaks on hosts that ship the
# GNU coreutils hostname (Debian/Ubuntu/Arch default). Pipe through cut
# to keep the short form portable across all supported targets.
#
# Normalised to UPPERCASE. Different OSes/init systems hand back the
# hostname in different case (Unraid often returns UPPERCASE, Debian
# usually lowercase). Without normalisation, a host whose returned
# casing drifts produces parallel artifacts — `systems/DAEDALUS/` and
# `systems/daedalus/`, `DAEDALUS_corruption_report.txt` next to
# `daedalus_corruption_report.txt` — that retention can't reconcile.
# UPPERCASE chosen as the canonical form because it matches the
# convention Unraid (the suite's primary target) reports natively. To
# override (e.g. keep an existing lowercase tree), set
# `HOSTNAME_VAR="my-host"` in auto_backupper.cfg — the config is
# sourced after this default and wins.
HOSTNAME_VAR="$(hostname | cut -d. -f1 | tr '[:lower:]' '[:upper:]')"
CDATE=$(date +%Y%m%d)
CURRENT_ARCHIVE_FILE=""
# Count of archives that failed this run. try_archive increments it; the
# end-of-produce notification reports it. A failed archive never aborts
# the run — remaining archives, verification and rotation still execute.
ARCHIVE_FAILURES=0

# --- Log Rotation Settings (Defaults) ---
LOG_MAX_SIZE="$((10 * 1024 * 1024))" # 10MB
LOG_BACKUPS=5

# --- Log Verbosity (Default) ---
# Controls how much detail the script emits to the log. Most of the
# log-bloat in older runs came from `tar -v` (per-file listing during
# archive creation) and `rsync --progress` (per-file output during
# pulls); both are gated off at "info" and below.
#
# Levels (most-restrictive to most-verbose):
#   error  — only ERROR / FATAL / CRITICAL / WARN lines
#   phase  — error tier + phase markers, archive announcements, ACTION lines
#   info   — phase tier + all script-level INFO chatter (DEFAULT)
#   debug  — info tier + tar -v + rsync --progress (large logs on big shares)
LOG_VERBOSITY="info"

# Ensure Root
if [[ $EUID -ne 0 ]]; then
	echo "CRITICAL: This script must be run as root." >&2
	exit 1
fi

# Log Rotation Function
#
# Uses copytruncate semantics rather than rename-and-touch, because this
# script holds an open FD on $LOGFILE for the duration of the run (via
# `exec >>"$LOGFILE"` or `exec > >(tee -a "$LOGFILE")`). Rename-based
# rotation leaves the held FD pointing at the renamed inode, so writes
# continue to flow into the old file and the new $LOGFILE stays empty —
# exactly the failure mode that let the log partition fill on Unraid.
# Copytruncate preserves the inode, so the held FD keeps writing to the
# now-truncated same file.
#
# Trade-off: a brief race window during the cp where log lines emitted
# between the cp completing and the truncate may appear in both the
# rotated archive (.1) and the current log. Acceptable — beats the
# bounded-then-crashes alternative.
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

	# Shift the existing rotated archives one slot down.
	[[ -f "${logfile}.${backups}" ]] && rm -f "${logfile}.${backups}"
	local i
	for ((i = backups - 1; i >= 1; i--)); do
		[[ -f "${logfile}.${i}" ]] && mv "${logfile}.${i}" "${logfile}.$((i + 1))"
	done

	# Copy current → .1, then truncate current. Order matters: cp first
	# so we have the archive even if truncate fails; truncate via `: >`
	# is a single O_TRUNC syscall on the same inode, so the held FD
	# stays valid.
	cp "$logfile" "${logfile}.1" 2>/dev/null && : >"$logfile" 2>/dev/null
	chmod 644 "$logfile" 2>/dev/null || true
}

# Periodic mid-run rotation check, called from log() on each line. The
# cost is one stat() per log message — microseconds — which is
# negligible next to the I/O the script is actually doing. Without this
# the rotation only fires at script startup, so a multi-hour backup run
# that exceeds LOG_MAX_SIZE during the run would never rotate.
#
# We only trigger when the caller is the main shell ($BASHPID == $$);
# parallel verify workers run in subshells and would race each other
# trying to rotate the same file.
rotate_log_if_needed() {
	[[ "$BASHPID" == "$$" ]] || return 0
	rotate_logs "$LOGFILE" "$LOG_MAX_SIZE" "$LOG_BACKUPS"
}

# Setup Logging
mkdir -p "$(dirname "$LOGFILE")"
rotate_logs "$LOGFILE" "$LOG_MAX_SIZE" "$LOG_BACKUPS"
touch "$LOGFILE" 2>/dev/null || true
if [[ -t 1 ]]; then
	exec > >(stdbuf -oL tee -a "$LOGFILE") 2>&1
else
	exec >>"$LOGFILE" 2>&1
fi

# Map LOG_VERBOSITY string → numeric threshold (lower = more restrictive).
# A message is emitted iff its detected level number <= the threshold.
#   error=2  phase=3  info=4  debug=99
_log_verbosity_threshold() {
	case "${LOG_VERBOSITY:-info}" in
		error) echo 2 ;;
		phase) echo 3 ;;
		info)  echo 4 ;;
		debug) echo 99 ;;
		*)     echo 4 ;;  # unknown → info default
	esac
}

# Detect a message's level from its prefix. Pattern set kept small &
# explicit; anything that doesn't match a stricter tier defaults to
# info (4) so existing log calls without an explicit tag still
# appear at the default verbosity.
_log_level_for() {
	case "$1" in
		FATAL*|CRITICAL*|ERROR:*|ERROR\ *|WARN:*|WARN\ *|"  WARN:"*|"  ERROR:"*) echo 2 ;;
		"==="*|Phase:*|Archiving:*|ACTION:*|RECOVERY:*|SUCCESS:*|NOTIFY*) echo 3 ;;
		*) echo 4 ;;
	esac
}

log() {
	local msg="$1"
	local lvl thresh
	lvl=$(_log_level_for "$msg")
	thresh=$(_log_verbosity_threshold)
	if ((lvl <= thresh)); then
		printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$msg"
	fi
	# Defense-in-depth mid-run rotation. Costs one stat() per line.
	rotate_log_if_needed
}

# State & IPC Management
init_state() {
	# State/IPC bookkeeping lives under /tmp and is required for the run's
	# own plumbing, so it is created for real even in dry-run mode (where
	# the mkdir/rm names are shadowed by the [DRY] logging overrides).
	/bin/mkdir -p "$ENCLAVE_DIR"

	# Crash recovery: if a previous run was SIGKILLed while Docker was stopped,
	# the state file survives in /tmp and the running_containers list survives
	# too. Restart Docker BEFORE truncating the state file.
	if [[ -f "$STATE_FILE" ]] && grep -q '^DOCKER_STOPPED=true$' "$STATE_FILE" 2>/dev/null; then
		log "RECOVERY: Previous run left Docker stopped. Attempting restart before proceeding..."
		# sys_docker_start is defined later in the file via OS detection, so this
		# function is only called from main() after binding is done.
		if sys_docker_start; then
			log "RECOVERY: Docker restart succeeded."
		else
			log "WARN: Recovery restart failed. Manual intervention may be required."
		fi
	fi

	: >"$STATE_FILE"

	# Reset IPC Queue (real even in dry-run — see /bin/mkdir note above)
	/bin/rm -rf "$IPC_BASE"
	/bin/mkdir -p "$IPC_ERRORS"
	: >"$SESSION_MANIFEST"
}

set_state() {
	local key="$1"
	local val="$2"
	# Atomic update: build the new full file body in a temp, then a single
	# mv to swap it into place. Previously the function did
	#   grep -v "$key" >tmp; mv tmp $STATE_FILE; echo "$k=$v" >>$STATE_FILE
	# which left a torn-write window between the mv and the append — a
	# SIGKILL or power loss in that window produced a state file that
	# was missing the very key we were trying to set. Recovery on the
	# next run would then read it as "DOCKER_STOPPED is unset" and skip
	# the Docker restart, leaving containers down indefinitely.
	local tmp="${STATE_FILE}.tmp.$$"
	if [[ -f "$STATE_FILE" ]]; then
		grep -v "^${key}=" "$STATE_FILE" >"$tmp" 2>/dev/null || true
	else
		: >"$tmp"
	fi
	echo "${key}=${val}" >>"$tmp"
	mv -f "$tmp" "$STATE_FILE"
}

get_state() {
	if [[ -f "$STATE_FILE" ]]; then
		grep "^${1}=" "$STATE_FILE" | cut -d= -f2
	else
		echo ""
	fi
}

# ==============================================================================
# 2. DEFAULT CONFIGURATION
# ==============================================================================

# --- Internal Defaults ---
CPU_THREADS="1" # "all" = Use all cores | "1" = Disable Multi-threading | "4" = Limit to 4 threads, etc...
MODE="produce"  # "produce" = Create local backups | "pull" = Sync from remote (Additive only) | "both"  = Produce then Pull
DRY_RUN="true"  # set to "false" for execution in production mode

# --- Paths ---
BACKUP_BASE="/mnt/user/backup"
SHARES_BASE_FOLDER="/mnt/user"
SYSTEM_APPDATA_PATH="/mnt/cache/appdata"
SYSTEM_BOOT_PATH="/boot"

# --- OMV Clone Path ---
# If set, this folder is rsynced instead of creating a tar of SYSTEM_APPDATA_PATH
OMV_DOCKER_BACKUP_PATH=""

# --- Unraid Specifics ---
UNRAID_DOCKER_CFG="/boot/config/docker.cfg"
DOCKER_IMG_PATH="/mnt/cache/system/docker/docker.img"
DOCKER_IMG_SIZE="80"
BACKUP_DOCKER_IMG=true

# --- Docker Strategy ---
DOCKER_MODE="auto"
DOCKER_STOP_TIMEOUT=60

# --- Retention & Integrity ---
ROTATE_DAYS=90                  # Days to keep files (0 = forever)
ROTATE_UNSTAMPED_GRACE_HOURS=24 # A file with NO dated checksum is exempt from
                                # mtime-fallback rotation until it has been on
                                # disk (ctime) at least this long — gives
                                # watchtower a window to stamp out-of-band
                                # arrivals whose preserved mtime is old.
VERIFY_LOCAL_BACKUPS=true       # Hash-verify files CREATED THIS SESSION after produce
VERIFY_ALL_LOCAL_BACKUPS=false  # Also re-hash the entire BACKUP_BASE tree on every
                                # run. Redundant with watchtower's scheduled deep
                                # verify — leave false unless watchtower isn't used.
VERIFY_PULLED_BACKUPS=true      # Hash-verify files TRANSFERRED THIS SESSION after pull
VERIFY_ALL_PULLED_BACKUPS=false # Also re-hash every file in the pulled folders.
                                # Same tradeoff as VERIFY_ALL_LOCAL_BACKUPS.
BACKUP_SYSTEM=true
BACKUP_SHARES=true

# --- Databases ---
BACKUP_SQL=false
SQL_TYPE="mysql"             # 'mysql' or 'postgres'
SQL_CONTAINER_NAME="mariadb" # Container Name (or "" for Host)
SQL_HOST="172.18.0.4"        # Host IP (used if Container Name is empty)
SQL_USER="root"
SQL_PASS="${SQL_PASS:-YourMySQLPassword}"
SQL_DATABASES=() # Empty = ALL

BACKUP_MONGO=false
MONGO_CONTAINER_NAME="mongodb"
MONGO_USER="root"
MONGO_PASS="${MONGO_PASS:-YourMongoPassword}"
MONGO_AUTH_DB="admin"
MONGO_DATABASES=()

BACKUP_REDIS=false
REDIS_CONTAINER_NAME="redis"
REDIS_PASS="${REDIS_PASS:-}"

# --- Share Definitions ---
SHARES_TO_BACKUP=(
	"codebase"
	"assets"
	"domains" # Triggers Granular folder backups
	"iscsi"   # Triggers Granular folder backups
	"isos"
	"liz"
	"stroh"
	"sites"
	"mebula"
	"media/Games/saves/"
	"FamilyBackups" # Triggers Special-hierarchy backups
)

# Complex Exclusions
declare -A SHARES_EXCLUDE
SHARES_EXCLUDE["isos"]='--exclude "asset-mirror" --exclude "*-squash"'
SHARES_EXCLUDE["iscsi"]='--exclude ".fuse_hidden*"'

# --- Remotes ---
REMOTE_PULL_SOURCES=(
	"/mnt/remotes/DBACKUPS"
	"/mnt/remotes/KBACKUPS"
)

# ==============================================================================
# 3. ARGUMENTS & EXTERNAL CONFIG LOADING
# ==============================================================================

CLI_CONFIG=""
# Accept both --config=PATH and --config PATH forms.
prev_arg=""
for arg in "$@"; do
	if [[ "$arg" == --config=* ]]; then
		CLI_CONFIG="${arg#*=}"
	elif [[ "$prev_arg" == "--config" || "$prev_arg" == "-c" ]]; then
		CLI_CONFIG="$arg"
	fi
	prev_arg="$arg"
done

CFG_TO_LOAD="${CLI_CONFIG:-$DEFAULT_CONFIG_FILE}"
if [[ -f "$CFG_TO_LOAD" ]]; then
	log "INFO: Loading configuration from $CFG_TO_LOAD"
	# shellcheck disable=SC1090
	source "$CFG_TO_LOAD"
else
	log "INFO: No config file found at $CFG_TO_LOAD. Using internal defaults."
fi

usage() {
	echo "Usage: $0 [OPTIONS]"
	echo "  -c, --config FILE   Path to config file"
	echo "  -m, --mode MODE     produce | pull | both"
	echo "  --only PHASES       Restrict produce flow to a comma-separated list of"
	echo "                      phases: db (alias: services) | systems | shares."
	echo "                      Skips rotation. Affects --mode produce / both only;"
	echo "                      --mode pull is unaffected."
	echo "                      Example: --only=db,shares"
	echo "  --dry-run           Simulate actions"
	echo "  --no-docker         Disable Docker management"
	exit 1
}

# --only filter: empty array means "run every phase" (legacy behavior).
# Populated by parsing below; downstream phase gates consult _phase_enabled.
ONLY_PHASES=()

while [[ $# -gt 0 ]]; do
	case $1 in
	--dry-run) DRY_RUN=true ;;
	--mode | -m)
		[[ -z "${2:-}" ]] && { echo "ERROR: --mode requires a value (produce|pull|both)"; exit 1; }
		MODE="$2"
		shift
		;;
	--only)
		[[ -z "${2:-}" ]] && { echo "ERROR: --only requires a comma-separated phase list (db,systems,shares)"; exit 1; }
		IFS=',' read -r -a ONLY_PHASES <<<"$2"
		shift
		;;
	--only=*)
		IFS=',' read -r -a ONLY_PHASES <<<"${1#--only=}"
		;;
	--config | -c)
		# Value already captured by the pre-scan loop above; just consume it.
		shift
		;;
	--config=*)
		# Equals form — value already captured by the pre-scan loop above.
		# Previously this fell through to `*)` Unknown argument, which broke
		# `watchtower.sh --start-backup` (watchtower invokes the backup
		# script with `--config=$CFG_TO_LOAD`).
		;;
	--debug) set -x ;;
	--no-docker) DOCKER_MODE="disabled" ;;
	-h | --help) usage ;;
	*)
		echo "Unknown argument: $1"
		exit 1
		;;
	esac
	shift
done

# Validate + normalise --only values. `services` is an operator-friendly
# alias for `db` (the layout under BACKUP_BASE is services/{sql,mongo,redis},
# but the phase itself is conceptually "databases"). Normalising at parse
# time keeps every downstream gate working against a single canonical name.
if [[ ${#ONLY_PHASES[@]} -gt 0 ]]; then
	for _i in "${!ONLY_PHASES[@]}"; do
		_p="${ONLY_PHASES[$_i]}"
		# Trim incidental whitespace from user input like `--only=db, shares`.
		_p="${_p# }"; _p="${_p% }"
		case "$_p" in
			db|services) ONLY_PHASES[$_i]="db" ;;
			systems) ONLY_PHASES[$_i]="systems" ;;
			shares) ONLY_PHASES[$_i]="shares" ;;
			"")
				# Empty token (e.g. trailing comma) — drop it later via dedup;
				# for now mark and continue.
				ONLY_PHASES[$_i]=""
				;;
			*)
				echo "ERROR: --only: unknown phase '$_p' (allowed: db, services, systems, shares)" >&2
				exit 1
				;;
		esac
	done
	# Drop any empties produced by trimming.
	_tmp=()
	for _p in "${ONLY_PHASES[@]}"; do
		[[ -n "$_p" ]] && _tmp+=("$_p")
	done
	ONLY_PHASES=("${_tmp[@]}")
	unset _tmp _p _i
fi

# Phase gate. Returns 0 when the named phase should run (either no --only
# filter is set, or the name is on the allow-list). Used at the top of
# each production block in produce_flow.
_phase_enabled() {
	[[ ${#ONLY_PHASES[@]} -eq 0 ]] && return 0
	local p
	for p in "${ONLY_PHASES[@]}"; do
		[[ "$p" == "$1" ]] && return 0
	done
	return 1
}

# ==============================================================================
# 4. OS ABSTRACTION & STRATEGY DEFINITIONS
# ==============================================================================

DOCKER_CMD="docker"
if ! command -v docker >/dev/null 2>&1; then DOCKER_CMD="true"; fi

_find_loop_for_file() {
	local file="$1"
	if command -v losetup >/dev/null 2>&1; then
		losetup -j "$file" 2>/dev/null | awk -F: '{print $1}' | sed -n '1p' || true
	fi
}

# --- Notification Strategies ---
strategy_notify_unraid() {
	local level="$1" title="$2" message="$3"
	if [[ -x "/usr/local/emhttp/webGui/scripts/notify" ]]; then
		/usr/local/emhttp/webGui/scripts/notify -e "$title" -s "Auto-Backupper" -d "$message" -i "$level" >/dev/null 2>&1 || true
	fi
}

strategy_notify_omv() {
	local level="$1" title="$2" message="$3"
	local omv_lvl="info"
	[[ "$level" == "warning" ]] && omv_lvl="warning"
	[[ "$level" == "alert" ]] && omv_lvl="error"
	omv-notify -k "${omv_lvl}" -t "${title}" -m "${message}" >/dev/null 2>&1 || true
}

strategy_notify_generic() {
	local level="$1" title="$2" message="$3"
	if command -v notify-send >/dev/null 2>&1; then
		notify-send -u "${level}" "${title}" "${message}" >/dev/null 2>&1 || true
	fi
}

# Escape a string for safe inclusion in a JSON string literal. Pure-bash
# so we don't need jq as a runtime dep here (jq is only required by
# warphole, not the core suite). Handles the four characters that
# actually appear in suite-generated titles/messages: backslash, double
# quote, newline, and tab. Anything more exotic (control chars in file
# paths) gets through but won't break a typical Discord/Slack/ntfy POST.
_json_escape() {
	local s="$1"
	s="${s//\\/\\\\}"
	s="${s//\"/\\\"}"
	s="${s//$'\n'/\\n}"
	s="${s//$'\t'/\\t}"
	printf '%s' "$s"
}

# Remote-webhook notifier. Fires *in addition* to the OS-native strategy
# so users can keep their Unraid/OMV/desktop notifications and also get
# pushed to a chat/phone target. Off unless NOTIFY_WEBHOOK_URL is set in
# auto_backupper.cfg.
#
# Format auto-detection (overridable via NOTIFY_WEBHOOK_FORMAT):
#   *discord.com*, *discordapp.com*  → discord (POST {content, username})
#   *slack.com*, *slack-edge.com*    → slack   (POST {text})
#   anything else                    → generic (POST {host,level,title,message,timestamp})
#   ntfy needs explicit NOTIFY_WEBHOOK_FORMAT=ntfy (URL host varies; can't
#                                    be auto-detected). Uses ntfy's header
#                                    convention rather than JSON.
#
# Failure is silent and non-fatal: a backup run must not be blocked by a
# misbehaving chat server. curl --max-time keeps a hung endpoint from
# stalling the whole script.
strategy_notify_webhook() {
	local level="$1" title="$2" message="$3"
	[[ -z "${NOTIFY_WEBHOOK_URL:-}" ]] && return 0
	command -v curl >/dev/null 2>&1 || return 0

	local fmt="${NOTIFY_WEBHOOK_FORMAT:-}"
	if [[ -z "$fmt" ]]; then
		case "$NOTIFY_WEBHOOK_URL" in
			*discord.com*|*discordapp.com*) fmt="discord" ;;
			*slack.com*|*slack-edge.com*) fmt="slack" ;;
			*) fmt="generic" ;;
		esac
	fi

	# Plain-text level prefix — emoji deliberately avoided to keep the
	# script body emoji-free; Discord/Slack render `[ALERT]` fine.
	local prefix
	case "$level" in
		alert)   prefix="[ALERT]" ;;
		warning) prefix="[WARN]" ;;
		normal)  prefix="[OK]" ;;
		*)       prefix="[INFO]" ;;
	esac

	local esc_title esc_message body=""
	esc_title=$(_json_escape "$title")
	esc_message=$(_json_escape "$message")

	case "$fmt" in
	discord)
		body="{\"username\":\"Auto-Backupper@${HOSTNAME_VAR}\",\"content\":\"${prefix} **${esc_title}**\\n${esc_message}\"}"
		;;
	slack)
		body="{\"text\":\"*${prefix} ${esc_title}*\\n${esc_message}\\n_host: ${HOSTNAME_VAR}_\"}"
		;;
	ntfy)
		# ntfy: body is the message, headers carry title/priority/tags.
		local ntfy_pri
		case "$level" in
			alert) ntfy_pri="high" ;;
			warning) ntfy_pri="default" ;;
			normal) ntfy_pri="low" ;;
			*) ntfy_pri="default" ;;
		esac
		curl -fsS --max-time 10 \
			-H "Title: ${title}" \
			-H "Priority: ${ntfy_pri}" \
			-H "Tags: backup,${level},${HOSTNAME_VAR}" \
			-d "${message}" \
			"$NOTIFY_WEBHOOK_URL" >/dev/null 2>&1 || true
		return 0
		;;
	generic)
		local ts
		ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
		body="{\"host\":\"${HOSTNAME_VAR}\",\"level\":\"${level}\",\"title\":\"${esc_title}\",\"message\":\"${esc_message}\",\"timestamp\":\"${ts}\"}"
		;;
	*)
		# Unknown format — silently no-op so an admin typo doesn't break the run.
		return 0
		;;
	esac

	curl -fsS --max-time 10 -H "Content-Type: application/json" \
		-d "$body" "$NOTIFY_WEBHOOK_URL" >/dev/null 2>&1 || true
}

# --- Docker Management Strategies ---
strategy_docker_unraid_mount() {
	[[ "${DRY_RUN}" == "true" ]] && {
		log "[DRY] Unraid mount docker.img"
		return 0
	}
	local IMG_FILE="${DOCKER_IMG_PATH}"
	local IMG_SIZE="${DOCKER_IMG_SIZE}"

	if [[ ! -f "$IMG_FILE" ]]; then return 1; fi
	if mountpoint -q /var/lib/docker 2>/dev/null; then return 0; fi

	log "ACTION: Mounting Unraid Docker Image ($IMG_FILE)..."
	mkdir -p /var/lib/docker

	if command -v /usr/local/sbin/mount_image >/dev/null 2>&1; then
		if /usr/local/sbin/mount_image "${IMG_FILE}" /var/lib/docker "${IMG_SIZE}" >/dev/null 2>&1; then return 0; fi
	fi

	if command -v losetup >/dev/null 2>&1; then
		local LOOP
		LOOP=$(losetup -f --show -P "$IMG_FILE" 2>/dev/null || losetup -f --show "$IMG_FILE" 2>/dev/null || true)
		if [[ -n "$LOOP" ]]; then
			if [[ -b "${LOOP}p1" ]] && mount "${LOOP}p1" /var/lib/docker 2>/dev/null; then return 0; fi
			if mount "${LOOP}" /var/lib/docker 2>/dev/null; then return 0; fi
			losetup -d "$LOOP" >/dev/null 2>&1 || true
		fi
	fi
	if mount -o loop "$IMG_FILE" /var/lib/docker 2>/dev/null; then return 0; fi
	return 1
}

strategy_docker_unraid_unmount() {
	[[ "${DRY_RUN}" == "true" ]] && {
		log "[DRY] Unraid unmount docker.img"
		return 0
	}
	local img="${DOCKER_IMG_PATH}"
	if [[ -f "$img" ]]; then
		local LOOP_DEV
		LOOP_DEV="$(_find_loop_for_file "$img")"
		if mountpoint -q /var/lib/docker; then
			umount /var/lib/docker || umount -l /var/lib/docker || true
		fi
		if [[ -n "$LOOP_DEV" ]]; then
			mount | awk -v dev="$LOOP_DEV" '$1==dev{print $3}' | while read -r mp; do
				umount "$mp" || umount -l "$mp" || true
			done
			losetup -d "$LOOP_DEV" >/dev/null 2>&1 || true
		fi
	fi
}

strategy_docker_unraid_stop() {
	[[ "${DRY_RUN}" == "true" ]] && {
		log "[DRY] Stop Unraid Docker Svc"
		set_state "DOCKER_STOPPED" "true"
		return
	}
	log "ACTION: Stopping Unraid Docker Service..."
	/etc/rc.d/rc.docker stop >/dev/null 2>&1 || true

	local elapsed=0
	while /etc/rc.d/rc.docker status | grep -q "running"; do
		sleep 5
		elapsed=$((elapsed + 5))
		if [[ $elapsed -ge $DOCKER_STOP_TIMEOUT ]]; then
			log "WARN: Docker stop timed out. Forcing."
			/etc/rc.d/rc.docker force_stop >/dev/null 2>&1 || true
			break
		fi
	done
	strategy_docker_unraid_unmount
	set_state "DOCKER_STOPPED" "true"
}

strategy_docker_unraid_start() {
	if [[ "$(get_state "DOCKER_STOPPED")" != "true" ]]; then return; fi
	[[ "${DRY_RUN}" == "true" ]] && {
		log "[DRY] Start Unraid Docker Svc"
		set_state "DOCKER_STOPPED" "false"
		return
	}
	log "ACTION: Starting Unraid Docker Service..."
	strategy_docker_unraid_mount || log "ERROR: Failed to mount docker image"
	/etc/rc.d/rc.docker start >/dev/null 2>&1 || true
	sleep 5
	set_state "DOCKER_STOPPED" "false"
}

strategy_docker_container_stop() {
	rm -f "$RUNNING_CONTAINERS_LIST"
	if ! $DOCKER_CMD ps --format "{{.Names}}" >"$RUNNING_CONTAINERS_LIST"; then return; fi
	[[ ! -s "$RUNNING_CONTAINERS_LIST" ]] && return

	set_state "DOCKER_STOPPED" "true"
	[[ "${DRY_RUN}" == "true" ]] && {
		log "[DRY] Stop Containers"
		return
	}

	log "ACTION: Stopping running containers..."
	while read -r c; do
		[[ -z "$c" ]] && continue
		$DOCKER_CMD stop -t "$DOCKER_STOP_TIMEOUT" "$c" >/dev/null 2>&1 || $DOCKER_CMD kill "$c" >/dev/null 2>&1 || true
	done <"$RUNNING_CONTAINERS_LIST"
}

strategy_docker_container_start() {
	if [[ "$(get_state "DOCKER_STOPPED")" != "true" ]]; then return; fi
	[[ ! -f "$RUNNING_CONTAINERS_LIST" ]] && return
	[[ "${DRY_RUN}" == "true" ]] && {
		log "[DRY] Start Containers"
		set_state "DOCKER_STOPPED" "false"
		return
	}

	log "ACTION: Restarting containers..."
	while read -r c; do
		[[ -n "$c" ]] && $DOCKER_CMD start "$c" >/dev/null 2>&1 || true
	done <"$RUNNING_CONTAINERS_LIST"
	rm -f "$RUNNING_CONTAINERS_LIST"
	set_state "DOCKER_STOPPED" "false"
}

strategy_docker_noop() { :; }

# --- OS Detection & Binding ---
OS_TYPE="linux"
if [[ -f "/etc/unraid-version" ]]; then
	OS_TYPE="unraid"
	if [[ -f "$UNRAID_DOCKER_CFG" ]]; then
		# shellcheck disable=SC1090
		source "$UNRAID_DOCKER_CFG" || true
		[[ -n "${DOCKER_IMAGE_FILE:-}" ]] && DOCKER_IMG_PATH="$DOCKER_IMAGE_FILE"
		[[ -n "${DOCKER_IMAGE_SIZE:-}" ]] && DOCKER_IMG_SIZE="$DOCKER_IMAGE_SIZE"
	fi
elif command -v omv-notify >/dev/null 2>&1; then
	OS_TYPE="omv"
fi

if [[ "$DOCKER_MODE" == "auto" ]]; then
	if [[ "$OS_TYPE" == "unraid" ]]; then
		DOCKER_MODE="unraid_service"
	elif [[ "$DOCKER_CMD" != "true" ]]; then
		DOCKER_MODE="container"
	else DOCKER_MODE="disabled"; fi
fi

# The OS-native strategy is always tried; strategy_notify_webhook is
# tacked on so a configured Discord/Slack/ntfy/generic webhook fires
# in addition to (not instead of) the local notification. Webhook is a
# no-op when NOTIFY_WEBHOOK_URL is empty, so this is backward-compatible.
case "$OS_TYPE" in
unraid) sys_notify() { strategy_notify_unraid "$@"; strategy_notify_webhook "$@"; } ;;
omv) sys_notify() { strategy_notify_omv "$@"; strategy_notify_webhook "$@"; } ;;
*) sys_notify() { strategy_notify_generic "$@"; strategy_notify_webhook "$@"; } ;;
esac

case "$DOCKER_MODE" in
unraid_service)
	sys_docker_stop() { strategy_docker_unraid_stop; }
	sys_docker_start() { strategy_docker_unraid_start; }
	;;
container)
	sys_docker_stop() { strategy_docker_container_stop; }
	sys_docker_start() { strategy_docker_container_start; }
	;;
*)
	sys_docker_stop() { strategy_docker_noop; }
	sys_docker_start() { strategy_docker_noop; }
	;;
esac

send_notify() {
	local level="$1" title="$2" message="$3"
	[[ "$level" == "alert" || "$level" == "normal" ]] && log "NOTIFY [$level]: $title - $message"
	[[ "${DRY_RUN}" == "true" ]] && return 0
	sys_notify "$level" "$title" "$message"
}

# ==============================================================================
# 5. TRAPS & CLEANUP
# ==============================================================================
LOCKFD=9
# Set to 1 only after flock(2) succeeds. cleanup() consults this so a
# second instance that loses the race for the flock cannot wipe the
# winning instance's PID file, IPC tree, or lockfile on its way out.
LOCK_HELD=0

cleanup() {
	# Best-effort: every step tolerates failure so one bad rm cannot
	# abort the chain under `set -e`. Guarded by LOCK_HELD because the
	# trap is installed BEFORE the flock is acquired (so a signal
	# between trap registration and lock acquisition can never strand
	# artifacts) — but until the lock is actually held, the paths below
	# belong to another instance and must not be touched.
	[[ "$LOCK_HELD" -eq 1 ]] || return 0
	# Absolute /bin/rm here (not the bare `rm`): these artifacts are
	# created for real on every run — including dry-run, where init_state
	# uses /bin/mkdir and the PID/lock files are written before the [DRY]
	# overrides matter. A bare `rm` would hit the dry-run no-op stub and
	# leave the whole enclave + PID + lockfile on disk after every dry-run.
	/bin/rm -f "$RUNNING_CONTAINERS_LIST" 2>/dev/null || true
	/bin/rm -f "$BACKUP_PIDFILE" 2>/dev/null || true
	/bin/rm -rf "$IPC_BASE" 2>/dev/null || true
	# Unlink while still holding the flock: a concurrent starter that opens
	# the file between our unlock and unlink would otherwise acquire a lock
	# on an inode we're about to delete, letting a third instance open a
	# fresh file and lock it independently (no mutual exclusion).
	/bin/rm -f "$LOCKFILE" 2>/dev/null || true
	flock -u "${LOCKFD}" 2>/dev/null || true
}

err_trap() {
	local exit_code=$? lineno="${1:-unknown}" last_cmd="${BASH_COMMAND:-unknown}"
	local msg="FATAL: exit=${exit_code} line=${lineno} cmd='${last_cmd}'"
	log "$msg"
	send_notify "alert" "Backup Critical Failure" "$msg"
	if [[ "$(get_state "DOCKER_STOPPED")" == "true" ]]; then
		log "EMERGENCY: State indicates Docker is stopped. Attempting restart..."
		sys_docker_start || true
	fi
	exit "${exit_code}"
}

interrupt_trap() {
	log "WARN: Interrupt detected. Stopping..."
	if [[ -n "$CURRENT_ARCHIVE_FILE" && -f "$CURRENT_ARCHIVE_FILE" ]]; then
		rm -f "$CURRENT_ARCHIVE_FILE"
	fi
	if [[ "$(get_state "DOCKER_STOPPED")" == "true" ]]; then
		sys_docker_start || true
	fi
	exit 130
}

# Traps go in BEFORE any side effect so a signal between opening the
# lockfile and acquiring the flock cannot leave the file orphaned.
# cleanup() is a no-op until LOCK_HELD=1, so installing it here is safe
# even when we exit early from a failed lock acquisition.
trap 'cleanup' EXIT
trap 'err_trap ${LINENO}' ERR
trap 'interrupt_trap' INT TERM

exec {LOCKFD}>"${LOCKFILE}" || {
	log "FATAL: Cannot open lockfile."
	exit 1
}
if ! flock -n "${LOCKFD}"; then
	log "Instance already running. Exiting."
	exit 0
fi
LOCK_HELD=1

# Record our PID so watchtower --stop-backup can find us reliably.
# (Using pgrep -f against basename is unsafe — it matches editors, greps, etc.)
mkdir -p "$(dirname "$BACKUP_PIDFILE")" 2>/dev/null || true
echo $$ >"$BACKUP_PIDFILE" 2>/dev/null || true

# ==============================================================================
# 6. TOOLS & HELPERS
# ==============================================================================

# Build RSYNC_OPTS conditionally on verbosity. `--progress` emits a
# per-file progress line; on a large pull that's the single biggest
# source of log bloat. Only include it at debug verbosity. The base
# options (archive/compress/timeout/etc.) are always present because
# they affect correctness, not output volume.
RSYNC_OPTS=(--archive --compress --human-readable --omit-dir-times --update --partial-dir=.abpartial --include="${CHECKSUM_DIR}" --exclude=.abpartial --timeout=60)
if [[ "${LOG_VERBOSITY:-info}" == "debug" ]]; then
	RSYNC_OPTS+=(--progress)
fi

# tar's -v flag is the other major log-bloat source — every file in
# the archive emits a line. At info/phase/error verbosity we drop it;
# the archive's stdout becomes near-silent (errors still emerge on
# stderr). At debug we restore the per-file listing for diagnostics.
TAR_VERBOSE_FLAG=""
if [[ "${LOG_VERBOSITY:-info}" == "debug" ]]; then
	TAR_VERBOSE_FLAG="v"
fi
# Strip any trailing slashes from BACKUP_BASE so "${BACKUP_BASE}/${folder}"
# can never produce a // artifact regardless of how the user configured it.
BACKUP_BASE="${BACKUP_BASE%/}"
TAR_EXT=".tar.gz"

PIGZ_THREAD_FLAG=""
if [[ "$CPU_THREADS" != "all" && "$CPU_THREADS" =~ ^[0-9]+$ ]]; then
	PIGZ_THREAD_FLAG="-p ${CPU_THREADS}"
fi

if command -v pigz >/dev/null 2>&1; then
	TAR_CMD="pigz ${PIGZ_THREAD_FLAG} --best"
else
	TAR_CMD="gzip"
fi

# --- SAFE WRAPPERS & PREFLIGHT ---

safe_rsync() {
	if [[ "${DRY_RUN}" == "true" ]]; then
		log "[DRY] safe_rsync $*"
		return 0
	fi

	set +e
	rsync "$@"
	local code=$?
	set -e

	case $code in
	0) return 0 ;;
	24)
		log "WARN: RSync partial transfer (Code 24 - files vanished). Continuing."
		return 0
		;;
	*)
		log "ERROR: RSync failed with fatal code $code."
		return $code
		;;
	esac
}

# Hostname-case drift detector. The suite standardises HOSTNAME_VAR to
# UPPERCASE; this scans for legacy artifacts in a different case that
# would otherwise stay invisible as separate-but-equal trees. Emits one
# WARN log line per drifted artifact with the exact `mv`/`cat` command
# to consolidate. No auto-migration — populated backup trees need an
# operator's eyes before rewriting.
warn_hostname_case_drift() {
	local base="${BACKUP_BASE:-}"
	[[ -d "$base" ]] || return 0
	local canonical="$HOSTNAME_VAR"
	local sib base_name f host_part

	# 1. Case-variant systems/<HOST>/ directories.
	if [[ -d "$base/systems" ]]; then
		shopt -s nullglob
		for sib in "$base/systems"/*/; do
			base_name="${sib%/}"
			base_name="$(basename "$base_name")"
			if [[ "${base_name^^}" == "${canonical^^}" && "$base_name" != "$canonical" ]]; then
				log "WARN: Found case-variant hostname directory: $sib"
				log "      Suite now uses UPPERCASE canonical: ${base}/systems/${canonical}/"
				log "      Migrate: mkdir -p '${base}/systems/${canonical}' && mv '${sib}'* '${base}/systems/${canonical}/' && rmdir '${sib%/}'"
				log "      Or set HOSTNAME_VAR=\"${base_name}\" in $CFG_TO_LOAD to keep current behaviour."
			fi
		done
		shopt -u nullglob
	fi

	# 2. Case-variant <host>_corruption_report.txt under .checksums/.
	local chk_dir="$base/.checksums"
	if [[ -d "$chk_dir" ]]; then
		shopt -s nullglob
		for f in "$chk_dir"/*_corruption_report.txt; do
			host_part="$(basename "$f")"
			host_part="${host_part%_corruption_report.txt}"
			if [[ "${host_part^^}" == "${canonical^^}" && "$host_part" != "$canonical" ]]; then
				log "WARN: Found case-variant corruption report: $f"
				log "      Suite now uses UPPERCASE canonical: ${chk_dir}/${canonical}_corruption_report.txt"
				log "      Migrate: cat '$f' >>'${chk_dir}/${canonical}_corruption_report.txt' && rm '$f'"
				log "      Or read the legacy report via: auto-restorer.sh --corruption-report --host ${host_part}"
			fi
		done
		shopt -u nullglob
	fi
}

preflight_checks() {
	log "Phase: Pre-flight Checks"

	# 1. Writability
	if [[ ! -w "$BACKUP_BASE" && "${DRY_RUN}" != "true" ]]; then
		log "FATAL: Backup destination '$BACKUP_BASE' is not writable or does not exist."
		return 1
	fi

	# 2. Binary Availability
	local req_cmds=("tar" "rsync" "find")
	for cmd in "${req_cmds[@]}"; do
		if ! command -v "$cmd" >/dev/null 2>&1; then
			log "FATAL: Required command '$cmd' not found."
			return 1
		fi
	done

	# 3. Network (If Pulling)
	if [[ "$MODE" == "pull" || "$MODE" == "both" ]]; then
		if [[ ${#REMOTE_PULL_SOURCES[@]} -gt 0 ]]; then
			for remote in "${REMOTE_PULL_SOURCES[@]}"; do
				if [[ ! -d "$remote" ]]; then
					log "WARN: Remote mount '$remote' is missing."
				fi
			done
		fi
	fi

	# 4. Free space on destination (opt-out via PREFLIGHT_SPACE_CHECK=false).
	# Runs only for produce/both — pull-only can't be pre-sized without
	# stat-walking the remote, which is slow and often flaky.
	if [[ "${PREFLIGHT_SPACE_CHECK:-true}" == "true" && "$MODE" != "pull" ]]; then
		if ! preflight_free_space_check; then
			return 1
		fi
	fi

	log "Pre-flight checks passed."
}

# S15b: Estimate uncompressed source size vs destination free space. Catches
# the "40GB free / 200GB system backup" class of disaster BEFORE we spend
# hours compressing data that won't fit. Deliberately conservative: assumes
# a pessimistic 40% compression ratio (media and already-compressed db
# dumps barely compress at all), plus a 1 GiB safety margin.
preflight_free_space_check() {
	# In dry-run we still run the check — it's informational only, and it
	# surfaces sizing problems before the user flips DRY_RUN off.

	log "Pre-flight: Estimating space requirements (this may take a moment on large shares)..."

	local total_source_bytes=0
	local -a sources_to_measure=()

	# System paths (only if BACKUP_SYSTEM=true and we're NOT using the OMV
	# clone path, which takes a different code path in produce_flow).
	if [[ "$BACKUP_SYSTEM" == "true" && -z "$OMV_DOCKER_BACKUP_PATH" ]]; then
		[[ -d "$SYSTEM_APPDATA_PATH" ]] && sources_to_measure+=("$SYSTEM_APPDATA_PATH")
		[[ -d "$SYSTEM_BOOT_PATH" ]] && sources_to_measure+=("$SYSTEM_BOOT_PATH")
	fi

	# OMV clone path (when set, replaces the SYSTEM_APPDATA_PATH tar).
	if [[ -n "$OMV_DOCKER_BACKUP_PATH" && -d "$OMV_DOCKER_BACKUP_PATH" ]]; then
		sources_to_measure+=("$OMV_DOCKER_BACKUP_PATH")
	fi

	# docker.img — counted only on the Unraid path that actually includes it.
	# Use apparent-size (du -sb) so a sparse 100GB image with 40GB of real
	# data is counted as 40GB, matching what -S in create_archive will write.
	if [[ "$DOCKER_MODE" == "unraid_service" && "$BACKUP_DOCKER_IMG" == "true" ]]; then
		if [[ -f "$DOCKER_IMG_PATH" ]]; then
			sources_to_measure+=("$DOCKER_IMG_PATH")
		fi
	fi

	# Shares. For recursive shares (domains, iscsi, FamilyBackups) we measure
	# the whole subtree here — close enough; the produce flow will split it
	# into per-subfolder archives but the total bytes on disk are the same.
	if [[ "$BACKUP_SHARES" == "true" ]]; then
		for share in "${SHARES_TO_BACKUP[@]}"; do
			local src="${SHARES_BASE_FOLDER}/${share}"
			[[ -d "$src" ]] && sources_to_measure+=("$src")
		done
	fi

	if [[ ${#sources_to_measure[@]} -eq 0 ]]; then
		log "  No measurable sources (BACKUP_SYSTEM=false, BACKUP_SHARES=false, no OMV path)."
		log "Pre-flight: Space check skipped."
		return 0
	fi

	# Measure. `du -sb` reports apparent size in bytes (GNU) — exactly what
	# we want for sparse-aware sizing. Use timeout so a stalled fuse/SMB
	# mount doesn't block preflight forever; if a measurement times out we
	# log a warning and continue (estimate becomes a lower bound).
	local src size
	for src in "${sources_to_measure[@]}"; do
		size=$(timeout 120 du -sb "$src" 2>/dev/null | awk '{print $1}')
		if [[ -n "$size" && "$size" =~ ^[0-9]+$ ]]; then
			total_source_bytes=$((total_source_bytes + size))
		else
			log "  WARN: Could not measure '$src' (timeout or error). Estimate may be low."
		fi
	done

	# Destination free space (bytes). -PB1 = POSIX, 1-byte blocks. Works on
	# every df implementation we care about (coreutils, busybox, etc.).
	local free_bytes
	free_bytes=$(df -PB1 "$BACKUP_BASE" 2>/dev/null | awk 'NR==2 {print $4}')
	[[ ! "$free_bytes" =~ ^[0-9]+$ ]] && free_bytes=0

	# Human-readable for log output.
	local total_gib free_gib
	total_gib=$(awk -v b="$total_source_bytes" 'BEGIN {printf "%.1f", b/1073741824}')
	free_gib=$(awk -v b="$free_bytes" 'BEGIN {printf "%.1f", b/1073741824}')

	log "  Source total (uncompressed): ${total_gib} GiB across ${#sources_to_measure[@]} path(s)"
	log "  Destination free:            ${free_gib} GiB on $BACKUP_BASE"

	# Pessimistic sizing: assume backups take 40% of uncompressed size on
	# disk. Plus 1 GiB margin for rotation overlap (old + new coexisting
	# briefly) and metadata (checksums, partial dirs, etc.). Tunable via
	# config if a user's dataset compresses much better or worse.
	local compression_ratio="${PREFLIGHT_COMPRESSION_RATIO:-0.4}"
	local margin_bytes="${PREFLIGHT_MARGIN_BYTES:-1073741824}"
	local required_bytes
	required_bytes=$(awk -v b="$total_source_bytes" -v r="$compression_ratio" -v m="$margin_bytes" \
		'BEGIN {printf "%d", b*r + m}')
	local required_gib margin_gib
	required_gib=$(awk -v b="$required_bytes" 'BEGIN {printf "%.1f", b/1073741824}')
	margin_gib=$(awk -v b="$margin_bytes" 'BEGIN {printf "%.1f", b/1073741824}')

	if (( free_bytes < required_bytes )); then
		log "FATAL: Estimated ${required_gib} GiB required, only ${free_gib} GiB free on $BACKUP_BASE"
		log "       (Ratio=${compression_ratio}, margin=${margin_gib} GiB.)"
		log "       Options: free up space, trim SHARES_TO_BACKUP, lower ROTATE_DAYS,"
		log "                or override PREFLIGHT_COMPRESSION_RATIO / PREFLIGHT_MARGIN_BYTES"
		log "                if your dataset compresses better than the default estimate."
		log "       To disable this check entirely: PREFLIGHT_SPACE_CHECK=false"
		send_notify "alert" "Backup Aborted" "Insufficient space: ${free_gib} GiB free, ${required_gib} GiB needed"
		return 1
	fi

	# Soft warning: destination has enough by the ratio-adjusted estimate but
	# less than the raw uncompressed total. Should succeed due to
	# compression, but any unexpectedly-incompressible payload (already-
	# compressed media, encrypted blobs) could blow through the headroom.
	if (( free_bytes < total_source_bytes )); then
		log "  WARN: Free space (${free_gib} GiB) < uncompressed source total (${total_gib} GiB)."
		log "        Backup should fit after compression, but margin is thin."
	fi

	log "Pre-flight: Space check passed (need ~${required_gib} GiB, have ${free_gib} GiB)."
	return 0
}

if [[ "${DRY_RUN}" == "true" ]]; then
	log "--- DRY RUN ENABLED ---"
	rsync() { log "[DRY] rsync $*"; }
	tar() { log "[DRY] tar $*"; }
	rm() { log "[DRY] rm $*"; }
	mkdir() { log "[DRY] mkdir $*"; }
	find() { if [[ "$*" == *"-delete"* || "$*" == *"-exec rm"* ]]; then log "[DRY] find $*"; else /usr/bin/find "$@"; fi; }
	# Stub docker only when a real docker binary exists. When docker is
	# absent DOCKER_CMD is the no-op "true", and defining a function named
	# `true` would shadow the shell builtin for the rest of the run.
	if [[ "$DOCKER_CMD" != "true" ]]; then
		eval "${DOCKER_CMD}() { log \"[DRY] ${DOCKER_CMD} \$*\"; }"
	fi
	mysqldump() { log "[DRY] mysqldump $*"; }
	pg_dump() { log "[DRY] pg_dump $*"; }
	losetup() { log "[DRY] losetup $*"; }
	mount() { log "[DRY] mount $*"; }
	umount() { log "[DRY] umount $*"; }
fi

ensure_dir() { mkdir -p "$1"; }

# --- Checksum path helpers ---
# A checksum file's on-disk name embeds a discovery date as an _<YYYYMMDD>
# suffix before .sha256 — e.g. archive.tar.gz_20250517.sha256. This makes a
# file's age portable across hosts: pull-side retention and rotation can be
# decided from the suffix alone, independent of mtime (which rsync's
# --archive preserves from the source, masking actual landing time) or
# filename (heterogeneous remotes may upload files that don't carry a
# CDATE-style date in their name).

# checksum_write_path: compose the absolute path a new checksum should be
# written to, stamped with the supplied date.
checksum_write_path() {
	local file="$1" base="$2" date_suffix="$3"
	echo "${base}/${CHECKSUM_DIR}/${file#"$base"/}_${date_suffix}.sha256"
}

# checksum_find_path: locate the existing dated checksum sibling for a data
# file. Echoes the path on stdout; returns 0 on success, 1 if no checksum
# is recorded. When more than one dated checksum exists for the same data
# file (transient state — e.g. an archive was regenerated on a later day
# before rotation pruned the stale sibling), the newest by date suffix
# wins. YYYYMMDD sorts chronologically as a string, so a lexicographic
# sort + tail does the job without parsing.
checksum_find_path() {
	local file="$1" base="$2"
	local rel="${file#"$base"/}"
	local chk_dir="${base}/${CHECKSUM_DIR}/$(dirname "$rel")"
	local name
	name="$(basename "$rel")"
	local matches=()
	local m
	shopt -s nullglob
	for m in "${chk_dir}/${name}"_[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9].sha256; do
		matches+=("$m")
	done
	shopt -u nullglob
	[[ ${#matches[@]} -eq 0 ]] && return 1
	printf '%s\n' "${matches[@]}" | sort | tail -1
	return 0
}

# checksum_date_from_path: extract the YYYYMMDD suffix from a checksum
# file path. Echoes the date on stdout; returns 1 if the filename does
# not carry a dated suffix (e.g. a legacy un-dated .sha256 that the
# legacy generator hasn't migrated yet).
checksum_date_from_path() {
	local base
	base="$(basename "$1")"
	if [[ "$base" =~ _([0-9]{8})\.sha256$ ]]; then
		echo "${BASH_REMATCH[1]}"
		return 0
	fi
	return 1
}

write_checksum() {
	local file="$1" base="$2"
	local rel="${file#"$base"/}"
	local chk_dir="${base}/${CHECKSUM_DIR}/$(dirname "$rel")"
	local name
	name="$(basename "$rel")"
	ensure_dir "$chk_dir"

	# Drop any stale dated sibling(s) for the same data file before
	# writing the new one. The common case where this matters is an
	# archive regenerated on a later day with the same base name — we
	# never want more than one dated checksum per data file in steady
	# state, otherwise rotation/find logic has to disambiguate.
	shopt -s nullglob
	local old
	for old in "${chk_dir}/${name}"_[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9].sha256; do
		/bin/rm -f "$old"
	done
	shopt -u nullglob

	local chk="${chk_dir}/${name}_${CDATE}.sha256"
	# Atomic write: temp + rename. A torn write (process killed between
	# sha256sum emitting its hash and the redirect flushing) would leave
	# a zero-byte or partial checksum that every later verify reads as a
	# false-positive corruption. The temp+rename pattern guarantees that
	# the final path either does not exist or holds a complete checksum.
	local tmp="${chk}.tmp.$$"
	if sha256sum "$file" | awk '{print $1}' >"$tmp"; then
		mv -f "$tmp" "$chk"
	else
		/bin/rm -f "$tmp"
		return 1
	fi
}

verify_file() {
	local file="$1" base="$2"
	[[ ! -f "$file" ]] && return 2

	local chk
	if ! chk="$(checksum_find_path "$file" "$base")"; then
		# No dated checksum recorded. Under normal operation this should
		# not happen: watchtower stamps a dated checksum on every stable
		# file in BACKUP_BASE, and the produce/pull flows ensure dated
		# checksums are present before this code runs. A missing
		# checksum means either watchtower hasn't scanned yet or the
		# file was placed here out-of-band. We pass the file through
		# rather than flagging it as corrupt — watchtower will create
		# the checksum on its next pass and the next verify run will
		# hash-check it properly.
		return 0
	fi

	# A dated checksum exists; treat it as authoritative. Watchtower only
	# writes one after file_is_stable() confirms the upload/archive is
	# complete, and the produce flow writes one only after the archive is
	# finalized. A sha256 match therefore proves the file is in the same
	# valid state as when it was recorded.
	local exp act
	exp="$(tr -d ' \t\r\n' <"${chk}" || true)"
	# Wrap sha256sum in `timeout` so a hung filesystem read (stale mount,
	# disk contention, uninterruptible sleep) fails the verification with
	# a specific exit code rather than blocking the whole script forever.
	# 10 minutes is generous for even very large archives on slow disks.
	act="$(timeout 600 sha256sum "${file}" 2>/dev/null | awk '{print $1}')"
	if [[ -z "$act" ]]; then
		log "WARN: sha256sum timed out or failed for ${file}"
		return 5
	fi
	[[ "${exp}" != "${act}" ]] && return 4
	return 0
}

# Write a small human-readable manifest describing the archive being
# created. Restorers can read this with `tar -xOf <archive>
# .auto-backupper/MANIFEST.txt` (or after extracting via the restorer)
# to audit what's inside before touching anything.
#
# Stored under `.auto-backupper/` so restoring to a populated tree drops
# a discoverable but unobtrusive hidden directory rather than a bare
# MANIFEST.txt at the target root.
_write_manifest() {
	local out_path="$1" archive_name="$2" base="$3"
	shift 3
	local fqdn
	fqdn="$(hostname 2>/dev/null || echo unknown)"
	{
		echo "# Auto-Backupper archive manifest"
		echo "archive: $archive_name"
		echo "created_at: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
		echo "host: $HOSTNAME_VAR"
		echo "host_long: $fqdn"
		echo "os: $OS_TYPE"
		echo "kernel: $(uname -srm 2>/dev/null || echo unknown)"
		echo "base_dir: $base"
		echo "source_paths:"
		local p
		for p in "$@"; do
			echo "  - $p"
		done
		echo "tools:"
		echo "  tar: $(tar --version 2>/dev/null | head -1 || echo unknown)"
		echo "  compress: ${TAR_CMD:-unknown}"
		echo "  bash: ${BASH_VERSION:-unknown}"
	} >"$out_path"
}

create_archive() {
	local archive="$1" base="$2"
	shift 2
	ensure_dir "$(dirname "$archive")"
	CURRENT_ARCHIVE_FILE="$archive"

	log "Archiving: ${archive}"

	# Build the manifest into a private temp dir, then add it to the
	# tar via an interleaved `-C` switch. Tar processes its args
	# left-to-right, so `-C $base "$@" -C $manifest_dir <path>`
	# archives all source files from $base first and then the manifest
	# from a different directory. The tempdir is cleaned up immediately
	# after tar exits — manifest data is bonus, not required, so any
	# mktemp / write failure silently falls back to an un-manifested
	# archive rather than failing the backup.
	local manifest_dir=""
	manifest_dir=$(mktemp -d /tmp/ab_manifest.XXXXXX 2>/dev/null || echo "")
	if [[ -n "$manifest_dir" ]]; then
		# The manifest tempdir is private scratch under /tmp: create and
		# remove it for real even in dry-run (where mkdir/rm are shadowed
		# by the [DRY] logging overrides), so mktemp dirs never leak.
		/bin/mkdir -p "${manifest_dir}/.auto-backupper" 2>/dev/null || true
		if ! _write_manifest "${manifest_dir}/.auto-backupper/MANIFEST.txt" \
			"$(basename "$archive")" "$base" "$@" 2>/dev/null; then
			/bin/rm -rf "$manifest_dir"
			manifest_dir=""
		fi
	fi

	# S15: `-S` / `--sparse` tells tar to detect holes in sparse files and
	# encode them efficiently rather than reading gigabytes of zeros off the
	# disk and feeding them to the compressor. Matters most for `docker.img`
	# (qcow2/ext4 backing files typically 50-80% hole by volume) and for any
	# VM disk images that might be included via SHARES_TO_BACKUP. On a 100GB
	# docker.img with 60GB of holes this is the difference between a 30-min
	# I/O-bound archive and a ~5-min one. Tar restores the sparseness on
	# extract, so docker.img stays thin after a restore. No downside for
	# non-sparse files — the flag just inspects each file for holes.
	# -v is conditional via $TAR_VERBOSE_FLAG (set in section 6 from
	# LOG_VERBOSITY). Empty at info/phase/error; "v" at debug. Single
	# combined short-option group `-c${TAR_VERBOSE_FLAG}f` so the
	# command line stays syntactically clean either way.
	local tar_rc=0
	if [[ -n "$manifest_dir" && -f "${manifest_dir}/.auto-backupper/MANIFEST.txt" ]]; then
		tar -S --use-compress-program="$TAR_CMD" "-c${TAR_VERBOSE_FLAG}f" "$archive" \
			-C "$base" "$@" \
			-C "$manifest_dir" .auto-backupper/MANIFEST.txt || tar_rc=$?
	else
		tar -S --use-compress-program="$TAR_CMD" "-c${TAR_VERBOSE_FLAG}f" "$archive" \
			-C "$base" "$@" || tar_rc=$?
	fi
	[[ -n "$manifest_dir" ]] && /bin/rm -rf "$manifest_dir"

	if [[ $tar_rc -eq 0 ]]; then
		# Dry-run stops here: the tar stub produced no file, so there is
		# nothing to checksum and nothing for the verify phase to hash.
		if [[ "${DRY_RUN}" == "true" ]]; then
			log "[DRY] checksum + session-manifest entry for ${archive}"
			CURRENT_ARCHIVE_FILE=""
			return 0
		fi
		# A failed checksum write leaves a valid archive without its
		# dated checksum; watchtower stamps it on its next scan. Not a
		# reason to discard the archive or abort the run.
		if ! write_checksum "$archive" "$BACKUP_BASE"; then
			log "WARN: Checksum write failed for ${archive} (watchtower will stamp it on its next scan)"
		fi
		# Record this archive in the session manifest so verification only
		# hashes what we actually produced this run — not the whole backup
		# tree. The manifest lives under IPC_BASE, so cleanup wipes it on exit.
		printf '%s\n' "$archive" >>"$SESSION_MANIFEST"
		CURRENT_ARCHIVE_FILE=""
	else
		log "ERROR: Archive failed: ${archive}"
		send_notify "alert" "Backup Failed" "${archive}"
		rm -f "$archive"
		CURRENT_ARCHIVE_FILE=""
		return 1
	fi
}

# Production-flow wrapper around create_archive. create_archive already
# logs, notifies and removes the partial file when an archive fails;
# this wrapper counts the failure and returns success, so one failed
# archive never aborts the run — the remaining archives, verification
# and rotation still execute. The failure count is reported by the
# end-of-produce notification.
try_archive() {
	if ! create_archive "$@"; then
		ARCHIVE_FAILURES=$((ARCHIVE_FAILURES + 1))
	fi
}

backup_recursive_folder() {
	local share_name="$1"
	local parent_path="${SHARES_BASE_FOLDER}/${share_name}"

	if [[ ! -d "$parent_path" ]]; then
		log "WARN: Share '$share_name' not found."
		return
	fi
	log "Phase: Granular Backup for '$share_name'"

	while IFS= read -r -d '' sub_path; do
		local folder_name
		folder_name="$(basename "$sub_path")"
		local dest_dir="${BACKUP_BASE}/shares/${share_name}/${folder_name}"
		local archive_name="${folder_name}_${CDATE}${TAR_EXT}"

		local ex_str=""
		[[ -n "${SHARES_EXCLUDE[$share_name]:-}" ]] && ex_str="${SHARES_EXCLUDE[$share_name]}"
		if [[ -n "$ex_str" ]]; then eval "ex_arr=($ex_str)"; else ex_arr=(); fi

		try_archive "${dest_dir}/${archive_name}" "$parent_path" "${ex_arr[@]}" "$folder_name"
	done < <(find "$parent_path" -mindepth 1 -maxdepth 1 -type d -print0 || true)
}

# --- PARALLELIZATION & IPC WORKERS ---

get_thread_count() {
	if [[ "$CPU_THREADS" == "all" ]]; then
		nproc 2>/dev/null || echo 1
	elif [[ "$CPU_THREADS" =~ ^[0-9]+$ ]]; then
		echo "$CPU_THREADS"
	else
		echo 1
	fi
}

# IPC Worker: Local Verification
verify_worker_local() {
	local file="$1"
	local base="$2"
	if ! verify_file "$file" "$base"; then
		# Generate unique ID to avoid collisions
		local uid
		uid="$(date +%s%N)-$$-${RANDOM}"
		echo "$file" >"${IPC_ERRORS}/${uid}"
	fi
}

# IPC Worker: Pull Verification.
# Takes a RELATIVE path (relative to BACKUP_BASE). Writes the relative path
# to the IPC queue on failure. Used by xargs -P for parallel pull-verify.
#
# Logs its start/finish so a hang is diagnosable from the log: if the log
# shows "verify-start X.tar.gz" with no matching "verify-done", that specific
# file is what's hanging the pipeline.
verify_worker_pull() {
	local rel="$1"
	local local_file="${BACKUP_BASE}/${rel}"
	local t0=$SECONDS
	log "  verify-start: $rel"
	if ! verify_file "$local_file" "$BACKUP_BASE"; then
		local uid
		uid="$(date +%s%N)-$$-${RANDOM}"
		echo "$rel" >"${IPC_ERRORS}/${uid}"
		log "  verify-FAIL:  $rel ($((SECONDS - t0))s)"
	else
		log "  verify-done:  $rel ($((SECONDS - t0))s)"
	fi
}

# Export everything the parallel workers need. BACKUP_BASE and CHECKSUM_DIR
# are referenced inside verify_file / verify_worker_pull; IPC_ERRORS is the
# queue they write to. log is called from both verify_worker_pull (for
# per-file progress) and verify_file (for timeout warnings). All must be
# exported because xargs -P spawns fresh `bash -c` subshells which only
# inherit exported names.
export -f log checksum_find_path checksum_date_from_path verify_file verify_worker_local verify_worker_pull
export BACKUP_BASE CHECKSUM_DIR IPC_ERRORS

# Compute the rotation date (YYYYMMDD) for a data file. Source-of-truth
# order: the newest dated checksum's suffix, then mtime as fallback for
# files that haven't been stamped yet (e.g. just dropped on the disk,
# watchtower hasn't scanned). Echoes the date on stdout; empty string if
# neither source yields a usable date.
rotation_date_for() {
	local file="$1" base="$2"
	local rel="${file#"$base"/}"
	local chk_dir="${base}/${CHECKSUM_DIR}/$(dirname "$rel")"
	local name
	name="$(basename "$rel")"
	local best="" d
	shopt -s nullglob
	local c
	for c in "${chk_dir}/${name}"_[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9].sha256; do
		if [[ "$(basename "$c")" =~ _([0-9]{8})\.sha256$ ]]; then
			d="${BASH_REMATCH[1]}"
			if [[ -z "$best" ]] || ((10#${d} > 10#${best})); then
				best="$d"
			fi
		fi
	done
	shopt -u nullglob
	if [[ -n "$best" ]]; then
		echo "$best"
		return 0
	fi
	# Fallback: mtime-derived date. Same semantics as the original
	# pre-dated-suffix rotation, scoped to files watchtower hasn't yet
	# stamped. Logged at INFO once per run by the rotation loop so
	# scan-lag is visible without flooding the log.
	date -r "$file" +%Y%m%d 2>/dev/null
}

# Rotation phase. Drives eviction off the dated checksum suffix — which
# is portable across hosts and immune to rsync's mtime preservation
# (rsync's --archive copies the source mtime, so a file pulled fresh
# today still looks "old" by mtime if the remote wrote it months ago).
# Falls back to mtime only for files that lack a dated checksum.
#
# IMPORTANT: only the *data file* is deleted. Its dated checksum sibling
# is retained intentionally. Under this suite's design model, the
# `.checksums/` tree is a distributed historical index — every peer
# accumulates the union of all checksums that ever existed across the
# fleet, so even after a host ages out a file, the checksum stays as
# evidence that the backup existed (and what its hash was). Peers with
# longer retention may still hold the data file; their checksum will
# additively re-merge through every pull regardless.
#
# Bulk pruning of orphan checksums is an explicit operator action
# exposed by auto-restorer.sh (--prune-checksums --older-than DURATION),
# not an automatic side effect of rotation.
rotation_phase() {
	[[ "${ROTATE_DAYS:-0}" -gt 0 ]] || return 0

	local cutoff_date
	cutoff_date="$(date -d "${ROTATE_DAYS} days ago" +%Y%m%d 2>/dev/null || echo "")"
	if [[ -z "$cutoff_date" ]]; then
		log "WARN: Could not compute rotation cutoff (date -d unsupported?). Skipping rotation."
		return 0
	fi

	log "Phase: Rotation (retention ${ROTATE_DAYS}d, cutoff YYYYMMDD < ${cutoff_date})"

	local rotate_count=0
	local mtime_fallback_count=0
	local grace_skip_count=0
	local now_epoch
	now_epoch=$(date +%s)
	# Coerce a malformed config value back to the default rather than let
	# it abort the run (a non-numeric token under set -u raises an
	# unbound-variable error inside $(( )) ) or silently disable rotation
	# (a value like "24h" fails the arithmetic and, masked by `local`,
	# would early-return the whole function). Mirrors how ROTATE_DAYS is
	# treated defensively elsewhere.
	local grace_hours="${ROTATE_UNSTAMPED_GRACE_HOURS:-24}"
	[[ "$grace_hours" =~ ^[0-9]+$ ]] || grace_hours=24
	local grace_seconds=$(( grace_hours * 3600 ))
	while IFS= read -r -d '' old_file; do
		local d
		d="$(rotation_date_for "$old_file" "$BACKUP_BASE")"
		[[ -z "$d" ]] && continue
		((10#${d} < 10#${cutoff_date})) || continue

		# Track the date source for visibility, but only for files past
		# the cutoff — saves a glob on every fresh file.
		local has_dated_chk
		if checksum_find_path "$old_file" "$BACKUP_BASE" >/dev/null 2>&1; then
			has_dated_chk=true
		else
			has_dated_chk=false
		fi

		# Un-stamped files are aged by mtime, which rsync/scp preserve
		# from the source — so a file that LANDED here minutes ago can
		# carry a months-old mtime. Exempt any un-stamped file whose
		# ctime (local landing time) is inside the grace window, leaving
		# it for watchtower to stamp with a real discovery date first.
		if [[ "$has_dated_chk" == "false" ]]; then
			local ctime_epoch
			ctime_epoch=$(stat -c %Z "$old_file" 2>/dev/null || echo 0)
			if (( now_epoch - ctime_epoch < grace_seconds )); then
				grace_skip_count=$((grace_skip_count + 1))
				continue
			fi
			mtime_fallback_count=$((mtime_fallback_count + 1))
		fi
		rotate_count=$((rotate_count + 1))

		if [[ "${DRY_RUN}" == "true" ]]; then
			log "[DRY-ROTATE] ${old_file#"$BACKUP_BASE"/} (date=${d}, source=$([[ "$has_dated_chk" == "true" ]] && echo suffix || echo mtime))"
			continue
		fi

		# Data only — checksum is retained as historical record. See
		# the function header for the rationale.
		/bin/rm -f "$old_file"
	done < <(find "$BACKUP_BASE" -path "$BACKUP_BASE/${CHECKSUM_DIR}" -prune -o -type f -print0 2>/dev/null)

	[[ $mtime_fallback_count -gt 0 ]] && log "INFO: Rotation used mtime fallback for ${mtime_fallback_count} un-stamped file(s)"
	[[ $grace_skip_count -gt 0 ]] && log "INFO: Rotation grace: ${grace_skip_count} un-stamped recent file(s) left for watchtower to stamp first"

	if [[ "${DRY_RUN}" == "true" ]]; then
		log "Rotation [DRY]: ${rotate_count} file(s) would be removed"
		return 0
	fi

	[[ $rotate_count -gt 0 ]] && log "Rotation: ${rotate_count} data file(s) removed (checksums retained as historical index)"

	# Cleanup now-empty directories under BACKUP_BASE (but never
	# BACKUP_BASE itself, hence -mindepth 2). The .checksums/ subtree
	# generally won't become empty under the new policy (we don't
	# delete checksums here), but the data-side subdirs can if every
	# archive under them was rotated this pass.
	find "$BACKUP_BASE" -mindepth 2 -type d -empty -delete 2>/dev/null || true
}

# ==============================================================================
# 7. LOGIC FLOWS
# ==============================================================================

produce_flow() {
	log "=== Starting PRODUCE Flow ==="
	if [[ ${#ONLY_PHASES[@]} -gt 0 ]]; then
		log "Phase filter (--only): ${ONLY_PHASES[*]} — rotation skipped"
	fi
	send_notify "normal" "Backup Started" "Mode: Produce"
	ensure_dir "$BACKUP_BASE"

	# 1. DATABASE DUMPS
	local SQL_BACKUP_PATH="$BACKUP_BASE/services/$SQL_TYPE"
	local MONGO_BACKUP_PATH="$BACKUP_BASE/services/mongo"
	local REDIS_BACKUP_PATH="$BACKUP_BASE/services/redis"

	if ! _phase_enabled db; then
		log "Skipping database phase (--only does not include 'db')"
	elif [[ "$DOCKER_CMD" == "true" ]]; then
		log "INFO: Docker not detected. Skipping Database Dumps."
	else
		if [[ "$BACKUP_SQL" == "true" ]]; then
			if [[ -z "$SQL_CONTAINER_NAME" ]]; then
				log "ERROR: BACKUP_SQL=true but SQL_CONTAINER_NAME is empty."
				log "       Host-based SQL backup is not currently implemented."
				log "       Either set SQL_CONTAINER_NAME to a running container, or set BACKUP_SQL=false."
				send_notify "alert" "SQL Backup Misconfigured" "Set SQL_CONTAINER_NAME or disable BACKUP_SQL."
			else
			ensure_dir "$SQL_BACKUP_PATH"
			log "Phase: SQL Backup"
			if $DOCKER_CMD ps -q -f name="^/${SQL_CONTAINER_NAME}$" >/dev/null 2>&1; then
				# Resolve MySQL/MariaDB binary names once per run.
				# The MariaDB project is renaming mysql-* → mariadb-* (since 10.5);
				# the old names are deprecated compat symlinks that will eventually
				# disappear. Prefer mariadb-* when present, fall back to mysql-*
				# for Oracle MySQL containers or older MariaDB. The two toolchains
				# are flag-compatible and produce byte-identical SQL output, and
				# both read the MYSQL_PWD env var for authentication.
				local SQL_CLI_BIN="mysql" SQL_DUMP_BIN="mysqldump"
				if [[ "$SQL_TYPE" == "mysql" ]]; then
					if $DOCKER_CMD exec "$SQL_CONTAINER_NAME" sh -c 'command -v mariadb-dump' >/dev/null 2>&1; then
						SQL_CLI_BIN="mariadb"
						SQL_DUMP_BIN="mariadb-dump"
					fi
					log "SQL: using '$SQL_CLI_BIN' / '$SQL_DUMP_BIN' inside $SQL_CONTAINER_NAME"
				fi

				local dbs=()
				if [[ ${#SQL_DATABASES[@]} -gt 0 ]]; then
					dbs=("${SQL_DATABASES[@]}")
				else
					if [[ "$SQL_TYPE" == "mysql" ]]; then
						mapfile -t dbs < <($DOCKER_CMD exec -e "MYSQL_PWD=$SQL_PASS" "$SQL_CONTAINER_NAME" "$SQL_CLI_BIN" -h "$SQL_HOST" -u "$SQL_USER" -e 'show databases' -s --skip-column-names | grep -Ev '^(information_schema|mysql|performance_schema|sys)$' || true)
					else
						mapfile -t dbs < <($DOCKER_CMD exec -e PGPASSWORD="$SQL_PASS" "$SQL_CONTAINER_NAME" psql -h "$SQL_HOST" -U "$SQL_USER" -At -c "SELECT datname FROM pg_database WHERE datistemplate = false;" || true)
					fi
				fi
				for db in "${dbs[@]}"; do
					[[ -z "$db" ]] && continue
					local tmp_dir
					tmp_dir=$(mktemp -d)
					local dump_file="${db}.sql"
					local full_dump_path="${tmp_dir}/${dump_file}"
					local final="${SQL_BACKUP_PATH}/${SQL_TYPE}_${db}_${CDATE}${TAR_EXT}"

					log "Dumping $db..."
					local dump_cmd=()
					if [[ "$SQL_TYPE" == "mysql" ]]; then
						# S8: pass password via env var so it doesn't appear in ps / /proc/*/cmdline
						dump_cmd=("$DOCKER_CMD" exec -e "MYSQL_PWD=$SQL_PASS" "$SQL_CONTAINER_NAME" "$SQL_DUMP_BIN" -h "$SQL_HOST" -u "$SQL_USER" --routines --triggers --databases "$db")
					else
						dump_cmd=("$DOCKER_CMD" exec -e PGPASSWORD="$SQL_PASS" "$SQL_CONTAINER_NAME" pg_dump -h "$SQL_HOST" -U "$SQL_USER" -d "$db")
					fi

					if "${dump_cmd[@]}" >"$full_dump_path" 2>/dev/null; then
						try_archive "$final" "$tmp_dir" "$dump_file"
					else
						log "ERROR: SQL Dump failed for $db"
						ARCHIVE_FAILURES=$((ARCHIVE_FAILURES + 1))
					fi
					# /bin/rm: mktemp -d is not stubbed in dry-run, so this
					# tempdir is real and the bare (shadowed) rm would leak it.
					/bin/rm -rf "$tmp_dir"
				done
			else
				log "WARN: SQL Container $SQL_CONTAINER_NAME not running."
			fi
			fi
		fi

		if [[ "$BACKUP_MONGO" == "true" ]]; then
			ensure_dir "$MONGO_BACKUP_PATH"
			log "Phase: Mongo Backup"
			if ! $DOCKER_CMD ps -q -f name="^/${MONGO_CONTAINER_NAME}$" >/dev/null 2>&1; then
				log "WARN: Mongo Container $MONGO_CONTAINER_NAME not running."
			else
				# S13: keep MONGO_PASS out of argv / /proc/<pid>/cmdline.
				# mongodump's --config flag (mongodb-database-tools 100.0+, Aug
				# 2020) reads username/password/authenticationDatabase from a
				# YAML file. We create one on the host with mode 600, docker-cp
				# it into the container, use it, then scrub both copies. The
				# alternative (--password on argv) leaks to `ps` for every user
				# on the host — which matters even on single-admin boxes because
				# container monitoring sidecars routinely scan /proc.
				#
				# Symmetric with the MySQL path, which uses MYSQL_PWD env var
				# (S8). Env var would be simpler here too, but mongodump does
				# not honour an equivalent variable for password, so the config
				# file is the only argv-safe route.
				local mongo_host_creds="" mongo_container_creds="" mongo_ok=true
				mongo_host_creds=$(mktemp 2>/dev/null) || {
					log "ERROR: could not create temp credentials file for mongo"
					mongo_ok=false
				}
				if [[ "$mongo_ok" == "true" ]]; then
					chmod 600 "$mongo_host_creds"
					cat >"$mongo_host_creds" <<EOF
username: "$MONGO_USER"
password: "$MONGO_PASS"
authenticationDatabase: "$MONGO_AUTH_DB"
EOF
					# Unique container-side path so parallel runs (shouldn't
					# happen due to the lockfile, but defence in depth) never
					# clobber each other's creds file.
					mongo_container_creds="/tmp/ab_mongo_creds_$$_${RANDOM}.yml"
					if ! $DOCKER_CMD cp "$mongo_host_creds" "${MONGO_CONTAINER_NAME}:${mongo_container_creds}" >/dev/null 2>&1; then
						log "ERROR: Failed to copy mongo credentials into container $MONGO_CONTAINER_NAME"
						mongo_ok=false
					else
						# chmod inside the container — if the image ships a
						# non-root user, the file's ownership is whatever
						# docker cp produced, but 600 makes it unreadable
						# to any other tenant in the container anyway.
						$DOCKER_CMD exec "$MONGO_CONTAINER_NAME" chmod 600 "$mongo_container_creds" 2>/dev/null || true
					fi
				fi

				if [[ "$mongo_ok" == "true" ]]; then
					local mdbs=()
					if [[ ${#MONGO_DATABASES[@]} -gt 0 ]]; then mdbs=("${MONGO_DATABASES[@]}"); else mdbs=("ALL"); fi
					for mdb in "${mdbs[@]}"; do
						local tmp_dir
						tmp_dir=$(mktemp -d)
						local dump_file="${mdb}.archive.gz"
						local full_dump_path="${tmp_dir}/${dump_file}"
						local final="${MONGO_BACKUP_PATH}/mongo_${mdb}_${CDATE}${TAR_EXT}"
						# --config supplies username / password /
						# authenticationDatabase; nothing sensitive on argv.
						local cmd_args=("mongodump" "--config" "$mongo_container_creds" "--archive" "--gzip")
						[[ "$mdb" != "ALL" ]] && cmd_args+=("--db" "$mdb")
						if $DOCKER_CMD exec "$MONGO_CONTAINER_NAME" "${cmd_args[@]}" >"$full_dump_path" 2>/dev/null; then
							try_archive "$final" "$tmp_dir" "$dump_file"
						else
							log "ERROR: Mongo dump failed for $mdb"
							ARCHIVE_FAILURES=$((ARCHIVE_FAILURES + 1))
						fi
						# /bin/rm: real tempdir even in dry-run (see SQL note).
						/bin/rm -rf "$tmp_dir"
					done

					# Scrub container-side creds as soon as we're done with
					# them. `rm -f` so a missing file (edge case) doesn't
					# trip set -e.
					$DOCKER_CMD exec "$MONGO_CONTAINER_NAME" rm -f "$mongo_container_creds" 2>/dev/null || true
				fi

				# Always try to scrub host-side creds file, even on failure
				# paths. Prefer shred when available so the content isn't
				# recoverable from free inodes.
				if [[ -n "$mongo_host_creds" && -f "$mongo_host_creds" ]]; then
					# /bin/rm in the fallback: this file holds the plaintext
					# MONGO_PASS. mktemp creates it for real even in dry-run, so a
					# bare (shadowed) rm would leave the password in /tmp.
					if command -v shred >/dev/null 2>&1; then
						shred -u "$mongo_host_creds" 2>/dev/null || /bin/rm -f "$mongo_host_creds"
					else
						/bin/rm -f "$mongo_host_creds"
					fi
				fi
			fi
		fi

		if [[ "$BACKUP_REDIS" == "true" ]]; then
			ensure_dir "$REDIS_BACKUP_PATH"
			log "Phase: Redis Backup"
			if $DOCKER_CMD ps -q -f name="^/${REDIS_CONTAINER_NAME}$" >/dev/null 2>&1; then
				local tmp_dir
				tmp_dir=$(mktemp -d)
				local dump_file="dump.rdb"
				local final="${REDIS_BACKUP_PATH}/redis_${CDATE}${TAR_EXT}"

				# S14: keep REDIS_PASS out of argv. redis-cli honours
				# REDISCLI_AUTH (Redis 5.0+), so pass it via `docker exec -e`
				# the same way we do MYSQL_PWD for MariaDB/MySQL (S8). The
				# env var name/value don't appear in the child's argv
				# (ps / /proc/*/cmdline), only in /proc/*/environ, which
				# requires root or the same UID to read — much less exposed
				# than argv.
				local docker_env_args=()
				[[ -n "$REDIS_PASS" ]] && docker_env_args=(-e "REDISCLI_AUTH=$REDIS_PASS")

				if $DOCKER_CMD exec "${docker_env_args[@]}" "$REDIS_CONTAINER_NAME" redis-cli --rdb - >"${tmp_dir}/${dump_file}" 2>/dev/null; then
					try_archive "$final" "$tmp_dir" "$dump_file"
				else
					log "ERROR: Redis dump failed"
					ARCHIVE_FAILURES=$((ARCHIVE_FAILURES + 1))
				fi
				# /bin/rm: real tempdir even in dry-run (see SQL note).
				/bin/rm -rf "$tmp_dir"
			else
				log "WARN: Redis Container $REDIS_CONTAINER_NAME not running."
			fi
		fi
	fi

	# 2. SYSTEM / OMV BACKUP
	local use_omv_clone=false
	[[ -n "$OMV_DOCKER_BACKUP_PATH" && -d "$OMV_DOCKER_BACKUP_PATH" ]] && use_omv_clone=true
	# --only=db,shares means "no systems phase" → docker doesn't need to
	# stop. Folding the filter into need_docker_stop here avoids stopping
	# Docker for a phase we won't actually run.
	local need_docker_stop=false
	if [[ "$DOCKER_MODE" != "disabled" ]] && _phase_enabled systems; then
		if [[ "$BACKUP_SYSTEM" == "true" ]] || [[ "$use_omv_clone" == "true" ]]; then need_docker_stop=true; fi
	fi

	if [[ "$need_docker_stop" == "true" ]]; then sys_docker_stop; fi

	if ! _phase_enabled systems; then
		log "Skipping systems phase (--only does not include 'systems')"
	elif [[ "$use_omv_clone" == "true" ]]; then
		log "Phase: Cloning OMV Backups"
		ensure_dir "$BACKUP_BASE/systems/$HOSTNAME_VAR/omv_docker_clones"
		if ! safe_rsync "${RSYNC_OPTS[@]}" "${OMV_DOCKER_BACKUP_PATH}/" "$BACKUP_BASE/systems/$HOSTNAME_VAR/omv_docker_clones/"; then
			log "WARN: OMV Docker Clone safe_rsync reported errors. Continuing..."
		fi
	elif [[ "$BACKUP_SYSTEM" == "true" ]]; then
		log "Phase: System Backup"
		local sys_path="$BACKUP_BASE/systems/$HOSTNAME_VAR/${HOSTNAME_VAR}_${CDATE}${TAR_EXT}"
		local targets=()
		[[ -d "$SYSTEM_APPDATA_PATH" ]] && targets+=("$SYSTEM_APPDATA_PATH")
		[[ -d "$SYSTEM_BOOT_PATH" ]] && targets+=("$SYSTEM_BOOT_PATH")

		if [[ "$DOCKER_MODE" == "unraid_service" && "$BACKUP_DOCKER_IMG" == "true" ]]; then
			if [[ -f "$DOCKER_IMG_PATH" ]]; then
				log "Including Docker Image: $DOCKER_IMG_PATH"
				targets+=("$DOCKER_IMG_PATH")
			else
				log "WARN: Docker image file not found: $DOCKER_IMG_PATH"
			fi
		fi
		[[ ${#targets[@]} -gt 0 ]] && try_archive "$sys_path" "/" "${targets[@]}"
	fi

	if [[ "$need_docker_stop" == "true" ]]; then sys_docker_start; fi

	# 3. SHARES BACKUP (Hot)
	if ! _phase_enabled shares; then
		log "Skipping shares phase (--only does not include 'shares')"
	elif [[ "$BACKUP_SHARES" == "true" ]]; then
		log "Phase: Shares Backup"
		for share in "${SHARES_TO_BACKUP[@]}"; do
			if [[ "$share" == "domains" ]]; then
				backup_recursive_folder "domains"
				continue
			fi
			if [[ "$share" == "iscsi" ]]; then
				backup_recursive_folder "iscsi"
				continue
			fi

			if [[ "$share" == "FamilyBackups" ]]; then
				local fam_root="${SHARES_BASE_FOLDER}/FamilyBackups"
				if [[ -d "$fam_root" ]]; then
					while IFS= read -r -d '' m_path; do
						local m_name
						m_name="$(basename "$m_path")"
						for sub in "users" "systems"; do
							local sub_full_path="${m_path}/${sub}"
							if [[ -d "$sub_full_path" ]]; then
								local archive_dest="${BACKUP_BASE}/shares/FamilyBackups/${m_name}/${sub}/${m_name}_${sub}_${CDATE}${TAR_EXT}"
								try_archive "$archive_dest" "$sub_full_path" "."
							fi
						done
					done < <(find "$fam_root" -mindepth 1 -maxdepth 1 -type d -print0 || true)
				fi
				continue
			fi

			local src="${SHARES_BASE_FOLDER}/$share"
			[[ ! -d "$src" ]] && continue
			local ex_str=""
			[[ -n "${SHARES_EXCLUDE[$share]:-}" ]] && ex_str="${SHARES_EXCLUDE[$share]}"
			if [[ -n "$ex_str" ]]; then eval "ex_arr=($ex_str)"; else ex_arr=(); fi
			local share_clean_name
			share_clean_name="$(basename "$share")"
			try_archive "${BACKUP_BASE}/shares/$share/${share_clean_name}_${CDATE}${TAR_EXT}" "$SHARES_BASE_FOLDER" "${ex_arr[@]}" "$share"
		done
	fi

	# 4. VERIFY & ROTATE (IPC Optimized with Native Job Control)
	#
	# Two behaviours here, controlled by config:
	#
	#   VERIFY_LOCAL_BACKUPS=true     → verify ONLY files produced this session
	#                                   (read from SESSION_MANIFEST). Fast: hashes
	#                                   what we just created, nothing else.
	#
	#   VERIFY_ALL_LOCAL_BACKUPS=true → additionally walk the entire BACKUP_BASE
	#                                   tree and re-hash every file. Redundant
	#                                   with the watchtower's scheduled deep
	#                                   verify, so default this to false. Only
	#                                   enable if you don't run watchtower or
	#                                   want belt-and-suspenders on every run.
	if [[ "$VERIFY_LOCAL_BACKUPS" == "true" || "${VERIFY_ALL_LOCAL_BACKUPS:-false}" == "true" ]]; then
		local threads
		threads=$(get_thread_count)
		export CHECKSUM_DIR IPC_ERRORS

		/bin/rm -f "${IPC_ERRORS:?}"/*

		local max_jobs="$threads"
		local current_jobs=0

		# Choose the input stream:
		#  - Full tree: find everything under BACKUP_BASE (skipping .checksums)
		#  - Session-only: read paths from SESSION_MANIFEST, one per line
		#
		# Either way, files flow through the same job-controlled worker loop.
		local verify_source_desc
		if [[ "${VERIFY_ALL_LOCAL_BACKUPS:-false}" == "true" ]]; then
			verify_source_desc="FULL TREE"
			log "Phase: Local Verification [${verify_source_desc}] (Threads: $threads) [IPC: $IPC_BASE]"
			while IFS= read -r -d '' file_to_verify; do
				(verify_worker_local "$file_to_verify" "$BACKUP_BASE") &
				current_jobs=$((current_jobs + 1))
				if [[ $current_jobs -ge $max_jobs ]]; then
					wait -n 2>/dev/null || wait
					current_jobs=$((current_jobs - 1))
				fi
			done < <(find "$BACKUP_BASE" -path "$BACKUP_BASE/${CHECKSUM_DIR}" -prune -o -type f -print0)
		else
			# Session-only path. If nothing was produced this run, skip silently
			# instead of blocking on an empty find.
			local session_count=0
			[[ -f "$SESSION_MANIFEST" ]] && session_count=$(wc -l <"$SESSION_MANIFEST" 2>/dev/null || echo 0)
			verify_source_desc="SESSION ONLY — $session_count file(s)"
			log "Phase: Local Verification [${verify_source_desc}] (Threads: $threads) [IPC: $IPC_BASE]"
			if [[ $session_count -gt 0 ]]; then
				while IFS= read -r file_to_verify; do
					[[ -z "$file_to_verify" ]] && continue
					# Skip anything that no longer exists (e.g. rotated away
					# between creation and verify — shouldn't happen but guard).
					[[ ! -f "$file_to_verify" ]] && continue
					(verify_worker_local "$file_to_verify" "$BACKUP_BASE") &
					current_jobs=$((current_jobs + 1))
					if [[ $current_jobs -ge $max_jobs ]]; then
						wait -n 2>/dev/null || wait
						current_jobs=$((current_jobs - 1))
					fi
				done <"$SESSION_MANIFEST"
			fi
		fi

		# Wait for remaining jobs
		wait

		# Check Queue for Error Files
		if [[ -d "$IPC_ERRORS" ]]; then
			if [[ -n "$(ls -A "$IPC_ERRORS" 2>/dev/null)" ]]; then
				for err_file in "$IPC_ERRORS"/*; do
					local failed_file
					failed_file=$(cat "$err_file")
					send_notify "alert" "Verify Failed" "$failed_file"
					log "ERROR: Verification failed for $failed_file"
				done
				# Clean up so that a subsequent pull_flow's verify starts with an
				# empty queue even if its own rm -f guard is ever bypassed.
				/bin/rm -f "${IPC_ERRORS:?}"/*
			else
				log "Verification Successful (No IPC Error Exceptions)"
			fi
		fi
	fi

	# Skip retention rotation when this is a partial run (--only). The
	# rotation walks the entire BACKUP_BASE tree and evicts by age, so it
	# would happily delete old shares backups during a --only=db run.
	# Operators expect a partial run to leave everything else untouched;
	# rotation will catch up on the next full run.
	if [[ ${#ONLY_PHASES[@]} -gt 0 ]]; then
		log "Skipping rotation: --only is set (partial run)"
	else
		rotation_phase
	fi
	if [[ "$ARCHIVE_FAILURES" -gt 0 ]]; then
		log "WARN: Produce finished with ${ARCHIVE_FAILURES} failed archive(s) — see ERROR lines above."
		send_notify "warning" "Backup Complete (with failures)" "Local produce finished: ${ARCHIVE_FAILURES} archive(s) failed."
	else
		send_notify "normal" "Backup Complete" "Local produce finished."
	fi
}

pull_flow() {
	log "=== Starting PULL Flow ==="
	[[ ${#REMOTE_PULL_SOURCES[@]} -eq 0 ]] && return

	local threads
	threads=$(get_thread_count)
	export CHECKSUM_DIR IPC_ERRORS

	ensure_dir "$BACKUP_BASE"

	for remote_root in "${REMOTE_PULL_SOURCES[@]}"; do
		if [[ ! -d "$remote_root" ]]; then
			log "ERROR: Remote path not found: $remote_root. Skipping."
			continue
		fi

		# --- 1. DETECT ACTIVE ROOT ---
		# Use the presence of CHECKSUM_DIR (.checksums) as the sentinel — it is
		# always written by this script's produce_flow and is unique to a backup
		# root. This is more reliable than looking for a user-defined share name
		# like "shares", which may not exist on all backup sets.
		local active_source="$remote_root"
		if [[ ! -d "${remote_root}/${CHECKSUM_DIR}" ]]; then
			local found_root
			# Note: no -not -path '*/.*' filter here — we ARE looking for a
			# hidden directory (.checksums). maxdepth 5 prevents runaway traversal.
			found_root=$(find "$remote_root" -maxdepth 5 -type d -name "${CHECKSUM_DIR}" -print -quit 2>/dev/null)
			if [[ -n "$found_root" ]]; then
				active_source="$(dirname "$found_root")"
				log "REDIRECT: Found nested backup root at: $active_source"
			fi
		fi

		log "Syncing from detected source: $active_source"

		# --- 2. DYNAMIC FOLDER DISCOVERY ---
		local folders_to_sync=()
		while IFS= read -r -d '' folder_path; do
			local folder_name
			folder_name="$(basename -- "$folder_path")"
			# A valid backup folder name is a simple, non-empty name with no
			# path separators. basename returns "/" for input "/", which the
			# system-folder regex does not catch — but "/"  matches */* because
			# every "/" contains a "/". Catching it here means
			# "${BACKUP_BASE}/${folder_name}" can never be "${BACKUP_BASE}//"
			# which would scan all of BACKUP_BASE unexpectedly.
			if [[ -z "$folder_name" || "$folder_name" == */* ]]; then
				log "WARN: Skipping unexpected directory entry (path='${folder_path}' name='${folder_name}')"
				continue
			fi
			if [[ "$folder_name" =~ ^(srv|mnt|proc|sys|dev|run|tmp|var|boot|etc|usr|bin|sbin|lib|lib64|opt|root)$ ]]; then
				log "WARN: Safety Filter - Ignoring system folder: $folder_name"
				continue
			fi
			folders_to_sync+=("$folder_name")
		done < <(find "$active_source" -mindepth 1 -maxdepth 1 -type d -not -name '.*' -print0 || true)

		if [[ ${#folders_to_sync[@]} -eq 0 ]]; then
			log "WARN: No valid folders found in $active_source."
			continue
		fi

		# --- 3. EXECUTE SYNC ---
		# Drop a marker file BEFORE the first rsync. Pull verification uses
		# `find -cnewer $marker` to target only files whose ctime was updated
		# during this pull (i.e. files rsync actually wrote). rsync skips
		# unchanged files entirely, so their ctime stays put and they don't
		# match the marker — exactly the selectivity we want.
		local pull_marker="${IPC_BASE}/pull_start_marker"
		: >"$pull_marker"
		# Brief pause so the marker's ctime is strictly less than any
		# file written by the rsync calls below, even on filesystems
		# with coarse timestamp resolution.
		sleep 1

		# --- 3a. CHECKSUMS FIRST ---
		# Pull the remote's .checksums/ tree BEFORE the data folders. This
		# was previously step 4 (after data). Moving it ahead lets us read
		# each remote file's dated discovery suffix to build a retention
		# exclude list (3b) so we can skip stale data files at the wire
		# instead of pulling and then having to evict them. Crucial when
		# the remote has a longer ROTATE_DAYS than we do, or when its own
		# rotation hasn't yet caught up.
		if [[ -d "${active_source}/${CHECKSUM_DIR}" ]]; then
			log "Pulling checksums first (for retention filter)"
			safe_rsync "${RSYNC_OPTS[@]}" "${active_source}/${CHECKSUM_DIR}/" "${BACKUP_BASE}/${CHECKSUM_DIR}/" || true
		fi

		# --- 3b. BUILD PER-FOLDER RETENTION EXCLUDE LISTS ---
		# Walk the REMOTE's .checksums/ (not the local merged tree — we
		# only want to filter what THIS remote is offering us), find any
		# dated suffix older than our ROTATE_DAYS cutoff, and queue the
		# corresponding data file for exclusion. Per-folder lists because
		# each data folder gets its own rsync invocation and rsync
		# matches --exclude-from patterns relative to its source root.
		declare -A FOLDER_EXCLUDES
		local pull_exclude_count=0
		if [[ "${ROTATE_DAYS:-0}" -gt 0 && -d "${active_source}/${CHECKSUM_DIR}" ]]; then
			local pull_cutoff_date
			pull_cutoff_date="$(date -d "${ROTATE_DAYS} days ago" +%Y%m%d 2>/dev/null || echo "")"
			if [[ -n "$pull_cutoff_date" ]]; then
				log "Pull retention cutoff: YYYYMMDD < ${pull_cutoff_date}"
				while IFS= read -r -d '' chk; do
					local date_suffix
					date_suffix="$(checksum_date_from_path "$chk")" || continue
					((10#${date_suffix} < 10#${pull_cutoff_date})) || continue
					local rel_with_suffix="${chk#"${active_source}/${CHECKSUM_DIR}/"}"
					local data_rel="${rel_with_suffix%_${date_suffix}.sha256}"
					# Split into top-level folder and per-folder subpath.
					# folders_to_sync only enumerates subdirectories of
					# active_source, so files sitting directly at the
					# root are never synced and need no exclusion.
					local top_folder="${data_rel%%/*}"
					if [[ "$top_folder" == "$data_rel" ]]; then
						continue
					fi
					local sub_rel="${data_rel#*/}"
					# Leading "/" anchors the pattern at the rsync source
					# root, preventing accidental matches on same-named
					# files deeper in the tree.
					FOLDER_EXCLUDES[$top_folder]+="/${sub_rel}"$'\n'
					pull_exclude_count=$((pull_exclude_count + 1))
				done < <(find "${active_source}/${CHECKSUM_DIR}" -type f -name "*_[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9].sha256" -print0 2>/dev/null)
				log "Pull retention: ${pull_exclude_count} stale file(s) will be skipped"
			else
				log "WARN: Could not compute pull retention cutoff. Proceeding without retention filter."
			fi
		fi

		# --- 3c. DATA SYNC (with per-folder retention exclude-from) ---
		for folder in "${folders_to_sync[@]}"; do
			local src_path="${active_source}/${folder}"
			local dest_path="${BACKUP_BASE}/${folder}"
			log "Pulling folder: $folder"
			ensure_dir "$dest_path"

			local excl_file=""
			local -a rsync_extra=()
			if [[ -n "${FOLDER_EXCLUDES[$folder]:-}" ]]; then
				excl_file="$(mktemp "${IPC_BASE}/pull_exclude_${folder//\//_}.XXXXXX" 2>/dev/null || mktemp)"
				printf '%s' "${FOLDER_EXCLUDES[$folder]}" >"$excl_file"
				rsync_extra+=(--exclude-from="$excl_file")
			fi

			safe_rsync "${RSYNC_OPTS[@]}" "${rsync_extra[@]}" "${src_path}/" "${dest_path}/" || log "WARN: safe_rsync reported issues with $folder"

			[[ -n "$excl_file" ]] && /bin/rm -f "$excl_file"
		done
		unset FOLDER_EXCLUDES

		# --- 5. VERIFICATION (IPC Optimized with Native Job Control) ---
		#
		# Two behaviours, symmetric with the local side:
		#
		#   VERIFY_PULLED_BACKUPS=true     → verify ONLY files touched by this
		#                                    pull, identified by ctime newer
		#                                    than $pull_marker. Fast.
		#
		#   VERIFY_ALL_PULLED_BACKUPS=true → additionally re-hash every file
		#                                    in the pulled folders. Redundant
		#                                    with watchtower's scheduled deep
		#                                    verify — leave false unless
		#                                    watchtower isn't used on this box.
		if [[ "$VERIFY_PULLED_BACKUPS" == "true" ]]; then
			local verify_scope="SESSION ONLY"
			[[ "${VERIFY_ALL_PULLED_BACKUPS:-false}" == "true" ]] && verify_scope="FULL TREE"
			log "Verifying Pull [${verify_scope}] (Threads: $threads) [IPC: $IPC_BASE]..."
			/bin/rm -f "${IPC_ERRORS:?}"/*

			# Build the list of relative folder names that exist locally.
			# We keep them RELATIVE so the find below can be run from inside
			# BACKUP_BASE, guaranteeing purely relative output paths with no
			# risk of // appearing from absolute path concatenation.
			local verify_rel_dirs=()
			for folder in "${folders_to_sync[@]}"; do
				[[ -d "${BACKUP_BASE}/${folder}" ]] && verify_rel_dirs+=("$folder")
			done

			if [[ ${#verify_rel_dirs[@]} -gt 0 ]]; then
				# Assemble the find predicate. In session mode, add -cnewer so
				# only files rsync wrote this run are emitted. Everything else
				# (old archives, unchanged files from previous pulls) is skipped.
				local find_args=("${verify_rel_dirs[@]}" -type f)
				if [[ "${VERIFY_ALL_PULLED_BACKUPS:-false}" != "true" ]]; then
					find_args+=(-cnewer "$pull_marker")
				fi

				# Pre-scan: materialize the list of files to verify to disk
				# BEFORE hashing. This serves three purposes:
				#   1. Gives us an accurate count up front so the user knows
				#      the scope of work (a 10-file session vs a 10000-file
				#      backlog look identical in logs otherwise).
				#   2. The user can inspect /tmp/enclave/queue/pull_verify_list
				#      from another shell to see what's queued.
				#   3. Separates find-tree-walk time from hash time in the log,
				#      making it clearer where any slowness is coming from.
				local pull_verify_list="${IPC_BASE}/pull_verify_list"
				( cd "$BACKUP_BASE" && find "${find_args[@]}" -print0 2>/dev/null || true ) > "$pull_verify_list"

				local verify_count=0
				if [[ -s "$pull_verify_list" ]]; then
					verify_count=$(tr -cd '\0' < "$pull_verify_list" | wc -c)
				fi

				log "Pull verify scope: $verify_count file(s). List: $pull_verify_list"

				if [[ $verify_count -eq 0 ]]; then
					log "Pull Verification: nothing transferred this run, skipping."
				else
					local t_start=$SECONDS

					# xargs -P handles parallelism far more reliably than a
					# hand-rolled `wait -n` loop: proper process reaping, no
					# silent subshell hangs, clean signal handling, and it
					# reads NUL-delimited input directly from our list file.
					#
					# The worker (verify_worker_pull) logs START/DONE for each
					# file — if the run ever hangs again, grep the log for
					# "verify-start" entries without matching "verify-done"
					# entries to see exactly which file blocked.
					xargs -0 -n 1 -P "$threads" \
						bash -c 'verify_worker_pull "$1"' _ \
						<"$pull_verify_list" || true

					local t_end=$SECONDS
					local final_corrupt=0
					if [[ -d "$IPC_ERRORS" ]]; then
						final_corrupt=$(find "$IPC_ERRORS" -mindepth 1 -maxdepth 1 -type f 2>/dev/null | wc -l)
					fi
					log "Pull verification hashing complete: $verify_count checked, $final_corrupt corrupt, $((t_end - t_start))s elapsed."

					# IPC files hold relative paths written above. Batch them into a
					# single rsync --files-from invocation: one session, one walk, all
					# files in one shot. This is dramatically faster than calling rsync
					# once per file, and adding --timeout means a stale mount fails fast
					# instead of hanging for hours on kernel-level NFS/SMB timeouts.
					if [[ -d "$IPC_ERRORS" && -n "$(ls -A "$IPC_ERRORS" 2>/dev/null)" ]]; then
						local repull_list
						repull_list="$(mktemp)"
						local repull_count=0
						for err_file in "$IPC_ERRORS"/*; do
							local rel_f
							rel_f=$(cat "$err_file")
							[[ -z "$rel_f" ]] && continue
							printf '%s\n' "$rel_f" >>"$repull_list"
							repull_count=$((repull_count + 1))
						done

						if [[ $repull_count -gt 0 ]]; then
							log "WARN: Corruption detected: $repull_count file(s). Batch re-pulling from $active_source..."
							send_notify "warning" "Pull Corruption Detected" "$repull_count file(s) failed verification; re-pulling from $active_source."
							# --progress removed: per-file progress floods the log for
							# large batches. --timeout=60 makes rsync fail fast on a
							# stale remote mount instead of hanging indefinitely on
							# kernel-level NFS/SMB timeouts. --files-from=- reads the
							# relative paths we queued above.
							if ! safe_rsync \
								--archive --compress --human-readable --omit-dir-times \
								--partial-dir=.abpartial --exclude=.abpartial \
								--timeout=60 \
								--files-from="$repull_list" \
								"${active_source}/" "${BACKUP_BASE}/"; then
								log "ERROR: Batch re-pull reported errors (see rsync output above)."
							else
								log "Batch re-pull finished ($repull_count file(s))."
							fi
						fi
						rm -f "$repull_list"
					else
						log "Pull Verification Successful."
					fi
				fi
			fi
		fi
	done

	# Apply the same retention sweep we run after produce. Catches:
	#   (a) any data file that slipped through 3b's exclude-from (e.g. a
	#       remote without a .checksums/ tree, where we fall back to
	#       additive sync and let rotation_phase clean up via mtime), and
	#   (b) the orphan checksums left behind when 3b correctly skipped a
	#       data file but the corresponding .sha256 still merged through
	#       3a's blanket checksum rsync.
	rotation_phase
	send_notify "normal" "Pull Complete" "Remote sync finished."
}

main() {
	init_state
	log "Startup [OS:${OS_TYPE} | Mode:${MODE} | Docker:${DOCKER_MODE}]"

	# Earlier versions preserved whatever case the OS returned from
	# `hostname`, so a host whose returned casing drifted (or whose
	# operator renamed/recased it) could end up with parallel
	# `systems/<HOST>/` trees that retention couldn't reconcile. The
	# suite now standardises on UPPERCASE; this check surfaces any
	# pre-existing case-variant artifacts with a clear `mv` suggestion.
	# Read-only — we never auto-migrate (rewriting a populated backup
	# tree without operator review is unsafe).
	warn_hostname_case_drift

	# Execute Pre-Flight Checks (Fast Fail)
	if ! preflight_checks; then
		log "FATAL: Pre-flight checks failed. Aborting."
		send_notify "alert" "Backup Aborted" "Pre-flight checks failed."
		exit 1
	fi

	case "$MODE" in
	"produce") produce_flow ;;
	"pull") pull_flow ;;
	"both")
		produce_flow
		pull_flow
		;;
	*)
		log "Invalid MODE"
		exit 1
		;;
	esac
	# Record successful completion timestamp for the watchtower scheduler.
	# Atomic write: torn writes would leave the file empty and watchtower's
	# should_run_schedule would either re-fire the backup or fail to parse.
	{
		_lr_tmp="/tmp/auto_backupper_last_run_backup.tmp.$$"
		date +%Y%m%d >"$_lr_tmp" 2>/dev/null \
			&& mv -f "$_lr_tmp" "/tmp/auto_backupper_last_run_backup" 2>/dev/null \
			|| rm -f "$_lr_tmp" 2>/dev/null
	} || true
	log "Job Finished."
}

main "$@"