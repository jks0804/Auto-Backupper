#!/usr/bin/env bash
# ==============================================================================
# AUTO-BACKUPPER WATCHTOWER
# ==============================================================================
# USAGE:
#   ./watchtower.sh --monitor                # Continuous Daemon
#   ./watchtower.sh --logs                   # Smart Log Monitor (Auto-Switching)
#   ./watchtower.sh --status                 # One-shot daemon + scheduler snapshot
#   ./watchtower.sh --ab-graph               # Live full-terminal dashboard for an
#                                            #   in-progress backup or restore
#                                            #   (warns and exits to --status when
#                                            #   neither worker is running)
#   ./watchtower.sh --hub                    # Houston-style command center: live
#                                            #   header + single-key shortcuts to
#                                            #   trigger watchtower / backupper /
#                                            #   restorer actions. Aliases:
#                                            #   --center, --command-center.
#   ./watchtower.sh --scan                   # One-Time Checksum Scan (or signal daemon)
#   ./watchtower.sh --scan --verify          # Verify ALL files (or signal daemon)
#   ./watchtower.sh --cleanup                # One-Time Junk Cleanup (or signal daemon)
#   ./watchtower.sh --update                 # Update Docker Containers (or signal daemon)
#   ./watchtower.sh --recover                # Repair ghost Docker containers (or signal daemon)
#   ./watchtower.sh --recover --dry-run      # Show what recovery WOULD do; change nothing
#                                            #   (--dry-run / --no-recreate apply to a
#                                            #   standalone run only; a running daemon
#                                            #   uses its DOCKER_RECOVERY_* config)
#   ./watchtower.sh --force                  # Wake up daemon immediately
#   ./watchtower.sh --start-backup           # Force Start Backup
#   ./watchtower.sh --stop-backup            # Force Stop Backup
#   ./watchtower.sh --config /path/to/cfg    # Manually define config location
#   ./watchtower.sh --reload                 # Signal the daemon to reload config
#   ./watchtower.sh --reload --config /path  # Reload daemon with NEW config
# ==============================================================================

set -u

# ==============================================================================
# 1. CONFIGURATION & DEFAULTS
# ==============================================================================

# Internal Defaults (Overridden by Config)
STARTUP_MODE="monitor"
# `hostname -s` is inetutils-only and breaks on hosts that ship the
# GNU coreutils hostname (Debian/Ubuntu/Arch default). Pipe through cut
# to keep the short form portable across all supported targets.
#
# Normalised to UPPERCASE — see the matching block in auto-backupper.sh
# for the full rationale. Short version: hostname casing drifts across
# OSes / shells / init systems, producing parallel artifact trees that
# retention can't reconcile. Pick one canonical case; uppercase matches
# what Unraid (primary target) reports natively. Config can override
# (`HOSTNAME_VAR="my-host"` in auto_backupper.cfg wins, since the
# config is sourced after this default).
HOSTNAME_VAR="$(hostname | cut -d. -f1 | tr '[:lower:]' '[:upper:]')"
WATCH_DIR="/mnt/user/backup"
CHECKSUM_DIR=".checksums"
MAIN_BACKUP_SCRIPT="/usr/local/bin/auto_backupper.sh"
WATCHTOWER_LOGFILE="/var/log/auto_backupper_watchtower.log"
BACKUP_LOGFILE="/var/log/auto_backupper.log"
DEFAULT_CONFIG_FILE="/boot/config/auto_backupper.cfg"
BACKUP_LOCKFILE="/var/lock/auto_backupper.lock"
WATCHTOWER_LOCK="/var/lock/ab_watchtower.lock"
PID_FILE="/var/run/ab_watchtower.pid"

# IPC Trigger Files
TRIGGER_UPDATE="/tmp/ab_watchtower_trigger_update"
TRIGGER_SCAN="/tmp/ab_watchtower_trigger_scan"
TRIGGER_VERIFY="/tmp/ab_watchtower_trigger_verify"
TRIGGER_CONFIG="/tmp/ab_watchtower_trigger_config"
TRIGGER_CLEANUP="/tmp/ab_watchtower_trigger_cleanup"
TRIGGER_FORCE="/tmp/ab_watchtower_trigger_force"
TRIGGER_RECOVERY="/tmp/ab_watchtower_trigger_recovery"
STATUS_FILE="/tmp/ab_watchtower.status"

# State Tracking (Prevents Log Flooding)
LAST_LOGGED_THREADS="-1"

# PIDs of backgrounded daemon tasks (docker update / recovery pass). The
# shutdown handler waits on these so a stop signal doesn't orphan an in-flight
# container recreate. Declared here to stay set -u safe.
_BG_TASK_PIDS=()

# Log Rotation Defaults
LOG_MAX_SIZE="$((10 * 1024 * 1024))" # 10MB
LOG_BACKUPS=5

# Log Verbosity — same model as auto-backupper.sh. Four levels:
#   error  — only ERROR / FATAL / CRITICAL / WARN lines
#   phase  — error tier + phase markers, ACTION lines, scheduler events
#   info   — phase tier + all daemon chatter incl. per-file NEW CHECKSUM (DEFAULT)
#   debug  — info tier + dlog/DEBUG-tagged lines
LOG_VERBOSITY="info"

# Defaults for Updater
UPDATE_SCHEDULER_ENABLE=false
DOCKER_UPDATE_EXCLUDE="mariadb"

# Scheduler timing defaults. *_ENABLE gates each job, but MODE/VALUE/TIME had no
# in-script default — an enabled-but-incomplete config (or an older cfg that only
# set *_ENABLE) made the should_run_schedule call dereference an unset var under
# set -u. The error fires inside the $() subshell so the daemon survives, but the
# job then NEVER fires and the log fills with 'unbound variable'. Defaulting them
# here (before the config is sourced, so the cfg still overrides) makes an enabled
# schedule run on sane values instead of silently never firing.
BACKUP_SCHEDULER_MODE="monthly";  BACKUP_SCHEDULER_VALUE="1";   BACKUP_SCHEDULER_TIME="02:00"
CLEANUP_SCHEDULER_MODE="daily";   CLEANUP_SCHEDULER_VALUE="Sun"; CLEANUP_SCHEDULER_TIME="04:00"
VERIFY_SCHEDULER_MODE="monthly";  VERIFY_SCHEDULER_VALUE="15";  VERIFY_SCHEDULER_TIME="03:00"
UPDATE_SCHEDULER_MODE="weekly";   UPDATE_SCHEDULER_VALUE="Sun"; UPDATE_SCHEDULER_TIME="05:00"

# Defaults for Docker Container Recovery (Unraid ghost-container repair)
DOCKER_RECOVERY_ENABLE=false
DOCKER_RECOVERY_RUN_ON_STARTUP=true
DOCKER_RECOVERY_INTERVAL=3600
DOCKER_RECOVERY_NO_RECREATE=false
DOCKER_RECOVERY_DRYRUN=false
# How recovery decides a non-running container should be brought back:
#   autostart — recover anything Unraid is set to autostart that isn't running
#               (catches stopped/errored/missing); leave autostart-off alone.
#   states    — recover only DOCKER_RECOVERY_GHOST_STATES below; ignore autostart.
DOCKER_RECOVERY_DETECT="autostart"
# Unraid's autostart list (one managed container name per line). Read for the
# "autostart" detect mode; lives on the host so it's readable even for missing
# containers. Override if your Unraid version stores it elsewhere.
DOCKER_AUTOSTART_FILE="/var/lib/docker/unraid-autostart"
# Used by DOCKER_RECOVERY_DETECT=states, and as the fallback when the autostart
# list can't be read. A non-running container in ANY other state (notably a
# clean "exited") is then treated as intentionally stopped and left untouched.
DOCKER_RECOVERY_GHOST_STATES="created dead restarting"
# Also recover a MISSING container (no docker record) when its template's image
# is still present (an "orphaned image") — even if autostart is off/unreadable.
# The leftover image is treated as proof it was installed and vanished.
DOCKER_RECOVERY_USE_ORPHAN_IMAGES=true
DOCKER_TEMPLATE_DIR="/boot/config/plugins/dockerMan/templates-user"
DOCKER_RECOVERY_DIR="/boot/config/ab_recovery"

# Defaults for Cache Monitor (prevents `set -u` crashes when config is missing)
ENABLE_CACHE_MONITOR=false
CACHE_DIR="/mnt/cache"
ARRAY_BASE_PATH="/mnt/user"
MOVER_TYPE="unraid"
CACHE_THRESHOLD=75
CACHE_CRITICAL=90
FORCE_MOVER_ON_CRITICAL=false
RUN_MOVER_DURING_PARITY=false

# Defaults for opt-in cleanup behaviours (see run_cleanup_task)
CLEANUP_MEDIA_METADATA=false

# Integrity-scan stability check (see file_is_stable). A file is only
# checksummed/moved once it has been quiet for SCAN_STABLE_MIN_AGE seconds AND
# its size+mtime are unchanged across SCAN_STABLE_SAMPLES samples taken
# SCAN_STABLE_INTERVAL seconds apart. Defaults are deliberately conservative so
# the scan never stamps a checksum over a still-writing archive.
SCAN_STABLE_SAMPLES=3
SCAN_STABLE_INTERVAL=2
SCAN_STABLE_MIN_AGE=15

# Bounded grace period (seconds) the daemon waits on INT/TERM for an in-flight
# backgrounded task (docker update / recovery pass) to reach a safe point
# before exiting, so a stop signal can't orphan a container mid-recreate.
DAEMON_SHUTDOWN_GRACE=30

# PID file written by auto-backupper.sh at startup; used by --stop-backup.
BACKUP_PIDFILE="/var/run/auto_backupper.pid"

# Defaults for Threading
CPU_THREADS="1"

# --- Load Initial Config ---
# Accept both --config=PATH and --config PATH forms.
CLI_CONFIG=""
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
	# shellcheck disable=SC1090
	source "$CFG_TO_LOAD"
else
	if [[ ! "$*" == *"--reload"* ]]; then
		echo "[WARN] Config file not found at $CFG_TO_LOAD. Using internal defaults."
	fi
fi

# Derived Variables
CORRUPTION_REPORT="${WATCH_DIR}/${CHECKSUM_DIR}/${HOSTNAME_VAR}_corruption_report.txt"
LOGFILE="$WATCHTOWER_LOGFILE"
# Scheduler "last run" markers. These must survive a reboot: on Unraid /tmp
# (and /var) are tmpfs wiped on boot, so a job that already ran would re-fire
# after a same-day reboot if its marker lived in /tmp. Anchor them under the
# backup tree's .checksums/ — which every find walk in the suite already
# prunes — and fall back to /tmp only if that directory cannot be created.
# auto-backupper.sh stamps last_run_backup at the SAME path on completion, so
# the two must agree (they do whenever WATCH_DIR == BACKUP_BASE, the norm).
AB_STATE_DIR="${WATCH_DIR}/${CHECKSUM_DIR}/.watchtower_state"
mkdir -p "$AB_STATE_DIR" 2>/dev/null || AB_STATE_DIR="/tmp"
LAST_RUN_BACKUP="$AB_STATE_DIR/last_run_backup"
LAST_RUN_CLEANUP="$AB_STATE_DIR/last_run_cleanup"
LAST_RUN_VERIFY="$AB_STATE_DIR/last_run_verify"
LAST_RUN_UPDATE="$AB_STATE_DIR/last_run_update"
LAST_RUN_RECOVERY="$AB_STATE_DIR/last_run_recovery"
# Sub-day interval gate for periodic recovery passes (epoch seconds; the
# YYYYMMDD LAST_RUN_RECOVERY above is only for the --status age display).
RECOVERY_LAST_PASS_EPOCH="$AB_STATE_DIR/recovery_epoch"

# ==============================================================================
# 2. CORE TOOLS
# ==============================================================================

get_thread_count() {
	local config_val="${CPU_THREADS:-1}"
	if [[ "${config_val,,}" == "all" ]]; then
		if command -v nproc >/dev/null 2>&1; then nproc; else echo 1; fi
		return
	fi
	if [[ "$config_val" =~ ^[0-9]+$ ]] && ((config_val > 0)); then
		echo "$config_val"
		return
	fi
	echo 1
}

# Log rotation — copytruncate variant matching auto-backupper.sh's
# pattern. Even though watchtower's log() uses per-line `echo >>` (no
# held FD), we standardise on copytruncate across the suite so the
# rotation logic stays identical everywhere. The mid-run rotation
# semantics are unchanged: rotation fires as soon as the next log()
# call sees the file past LOG_MAX_SIZE.
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

# Periodic mid-run rotation check, called from log(). Guarded by
# BASHPID == $$ so parallel subshells (perform_scan workers) don't
# race rotating the same file.
rotate_log_if_needed() {
	[[ "$BASHPID" == "$$" ]] || return 0
	rotate_logs "$LOGFILE" "${LOG_MAX_SIZE:-10485760}" "${LOG_BACKUPS:-5}"
}

# Rotate the corruption report when it exceeds CORRUPTION_REPORT_MAX_SIZE
# (default 1 MiB). Previously the report was append-only with no bound,
# so on a host with chronic disk-flake corruption the file would grow
# without limit. Same N-backups scheme as the daemon log (LOG_BACKUPS).
# Called from process_file() right before appending a new entry.
rotate_corruption_report_if_large() {
	[[ -f "$CORRUPTION_REPORT" ]] || return 0
	local cr_size
	cr_size=$(stat -c%s "$CORRUPTION_REPORT" 2>/dev/null || echo 0)
	local max_size="${CORRUPTION_REPORT_MAX_SIZE:-1048576}"
	((cr_size >= max_size)) || return 0
	local max_backups="${LOG_BACKUPS:-5}"
	[[ -f "${CORRUPTION_REPORT}.${max_backups}" ]] && rm -f "${CORRUPTION_REPORT}.${max_backups}"
	local i
	for ((i = max_backups - 1; i >= 1; i--)); do
		[[ -f "${CORRUPTION_REPORT}.${i}" ]] && mv "${CORRUPTION_REPORT}.${i}" "${CORRUPTION_REPORT}.$((i + 1))"
	done
	mv "$CORRUPTION_REPORT" "${CORRUPTION_REPORT}.1"
	touch "$CORRUPTION_REPORT"
}

# Verbosity → numeric threshold (lower = more restrictive).
_log_verbosity_threshold() {
	case "${LOG_VERBOSITY:-info}" in
		error) echo 2 ;;
		phase) echo 3 ;;
		info)  echo 4 ;;
		debug) echo 99 ;;
		*)     echo 4 ;;
	esac
}

# Detect a watchtower message's level from its prefix. Tuned to the
# daemon's actual log call conventions (audited via grep).
#   2 = error tier (always emit unless verbosity=phase or lower)
#   3 = phase tier (start/end of major operations)
#   4 = info tier (per-file / detail / chatter)
#  99 = debug tier (DEBUG: from dlog or explicit debug calls)
_log_level_for() {
	case "$1" in
		FATAL*|CRITICAL*|ERROR:*|ERROR\ *|WARN:*|WARN\ *|CORRUPTION:*|"UPDATER WARN:"*|"UPDATER ERROR:"*) echo 2 ;;
		"==="*|ACTION:*|STARTUP:*|STATUS:*|MANUAL:*|RECOVERY:*|CLEANUP:*|SCHEDULER:*|CONFIG:*|NOTIFY*|EVENT:*|RELOAD:*|LOGS:*|UPDATER:*|SCAN:*) echo 3 ;;
		DEBUG:*) echo 99 ;;
		*) echo 4 ;;
	esac
}

log() {
	local msg lvl thresh
	lvl=$(_log_level_for "$1")
	thresh=$(_log_verbosity_threshold)
	((lvl <= thresh)) || { rotate_log_if_needed; return 0; }

	msg="$(date '+%Y-%m-%d %H:%M:%S') [WATCHTOWER] $1"
	echo "$msg"

	if [[ ! -f "$LOGFILE" ]]; then touch "$LOGFILE" 2>/dev/null || true; fi
	if [[ -w "$LOGFILE" ]]; then
		echo "$msg" >>"$LOGFILE"
	fi
	rotate_log_if_needed
}

set_status() {
	echo "$1" >"$STATUS_FILE"
}

# Atomic write of a single short value to a file. Used for LAST_RUN_*
# schedule markers — a torn `date +%Y%m%d >"$f"` (killed mid-redirect,
# /tmp full, etc.) would leave the file empty, and should_run_schedule
# would then either re-fire the job on the next cycle (perceived
# overdue) or fail to parse the empty value and silently skip. Both
# failure modes are subtle and hard to debug. Temp + rename eliminates
# the torn-write window because the file either still contains the old
# value or atomically becomes the new one.
atomic_write() {
	local target="$1"
	local content="$2"
	local tmp="${target}.tmp.$$"
	if printf '%s\n' "$content" >"$tmp" 2>/dev/null; then
		mv -f "$tmp" "$target" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
	fi
}

# --- SMART SLEEP (THE FIX) ---
# Replaces all blocking 'sleep' commands.
# Wakes up every 3 seconds to check for triggers.
smart_sleep() {
	local duration="${1:-300}"
	# Validate numeric. A non-numeric MONITOR_INTERVAL ("5 min") would otherwise
	# either kill the daemon (unbound-var in the $((current_ts + duration))
	# arithmetic under set -u) or busy-spin it (a bare "5m" fails the arithmetic,
	# leaving wake_time=0 so the loop never sleeps and pegs a CPU).
	[[ "$duration" =~ ^[0-9]+$ ]] || duration=300
	local current_ts
	current_ts=$(date +%s)
	local wake_time=$((current_ts + duration))

	# Loop in 3-second bursts until duration is met
	while [[ $(date +%s) -lt $wake_time ]]; do
		if [[ -f "$TRIGGER_SCAN" || -f "$TRIGGER_UPDATE" || -f "$TRIGGER_VERIFY" || -f "$TRIGGER_CONFIG" || -f "$TRIGGER_CLEANUP" || -f "$TRIGGER_FORCE" || -f "$TRIGGER_RECOVERY" ]]; then
			# Trigger detected! Exit sleep immediately.
			# The main loop will catch the trigger at the top of the next cycle.
			return 0
		fi
		sleep 3
	done
}

OS_TYPE="linux"
if [[ -f "/etc/unraid-version" ]]; then OS_TYPE="unraid"; fi
# Use the same OMV probe as auto-backupper.sh and auto-restorer.sh
# (omv-notify, not omv-firstaid). All three scripts must agree on OS_TYPE
# or notification routing / restart heuristics can diverge on borderline
# installs where one tool is present but the other isn't.
if command -v omv-notify >/dev/null 2>&1; then OS_TYPE="omv"; fi

# Escape a string for safe inclusion in a JSON string literal. Pure-bash
# so we don't require jq (not a watchtower dep). Duplicated verbatim from
# auto-backupper.sh — the suite deliberately avoids a shared library, so
# the small helper is copied across the two scripts that need it.
_json_escape() {
	local s="$1"
	s="${s//\\/\\\\}"
	s="${s//\"/\\\"}"
	s="${s//$'\n'/\\n}"
	s="${s//$'\t'/\\t}"
	printf '%s' "$s"
}

# Remote-webhook notifier. Identical contract to auto-backupper.sh's copy:
# off unless NOTIFY_WEBHOOK_URL is set in auto_backupper.cfg; format
# auto-detected from URL (discord / slack / generic), or set explicitly
# via NOTIFY_WEBHOOK_FORMAT (also: ntfy, which uses headers instead of
# JSON and so can't be auto-detected from the URL host). Failures are
# silent and bounded by curl --max-time so a hung endpoint can't stall
# the daemon's poll loop.
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
		body="{\"username\":\"Watchtower@${HOSTNAME_VAR}\",\"content\":\"${prefix} **${esc_title}**\\n${esc_message}\"}"
		;;
	slack)
		body="{\"text\":\"*${prefix} ${esc_title}*\\n${esc_message}\\n_host: ${HOSTNAME_VAR}_\"}"
		;;
	ntfy)
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
			-H "Tags: watchtower,${level},${HOSTNAME_VAR}" \
			-d "${message}" \
			"$NOTIFY_WEBHOOK_URL" >/dev/null 2>&1 || true
		return 0
		;;
	generic)
		local ts
		ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
		body="{\"host\":\"${HOSTNAME_VAR}\",\"level\":\"${level}\",\"title\":\"${esc_title}\",\"message\":\"${esc_message}\",\"timestamp\":\"${ts}\",\"source\":\"watchtower\"}"
		;;
	*)
		return 0
		;;
	esac

	curl -fsS --max-time 10 -H "Content-Type: application/json" \
		-d "$body" "$NOTIFY_WEBHOOK_URL" >/dev/null 2>&1 || true
}

send_notify() {
	local level="$1" title="$2" message="$3"
	log "NOTIFY [$level]: $title - $message"
	# Always attempt the webhook (no-op when NOTIFY_WEBHOOK_URL is empty).
	# This fires alongside the OS-native notification below, so an Unraid
	# user can keep their on-box banner *and* get pushed to chat.
	strategy_notify_webhook "$level" "$title" "$message"
	if [[ "$OS_TYPE" == "unraid" && -x "/usr/local/emhttp/webGui/scripts/notify" ]]; then
		/usr/local/emhttp/webGui/scripts/notify -e "$title" -s "WATCHTOWER" -d "$message" -i "$level" >/dev/null 2>&1 || true
		return
	fi
	if command -v notify-send >/dev/null 2>&1; then
		notify-send -u "$level" "$title" "$message" >/dev/null 2>&1 || true
	fi
}

# --- UNIFIED SIGNAL HANDLER ---
daemon_signal_handler() {
	log "EVENT: Signal received. Interrupting sleep cycle..."
	# We do NOT process triggers here.
	# The signal interrupts the 'sleep' in smart_sleep.
	# smart_sleep will then see the trigger file exists, return 0,
	# and the main loop will call check_manual_triggers immediately.
}

# Graceful daemon shutdown. On INT/TERM, give any in-flight backgrounded task
# (docker update or recovery pass) a bounded chance to finish its current
# container operation before we exit, so a stop/reboot signal doesn't orphan a
# container between `docker rm` and recreate. Bounded by DAEMON_SHUTDOWN_GRACE.
#
# Scope note: this protects against a signal sent to the daemon itself
# (watchtower's own stop, `kill <pid>`, a hub stop). A systemd control-group
# kill (the default KillMode=control-group) also signals the child tasks
# directly, which this cannot intercept — use KillMode=mixed in the unit if you
# schedule updates near array-stop/shutdown windows.
# Drop completed PIDs so _BG_TASK_PIDS stays small (it would otherwise grow
# unbounded over a long-running daemon) and never matches a recycled PID at
# shutdown. Called right before each new background task is appended.
_bg_reap() {
	local _p _live=()
	for _p in ${_BG_TASK_PIDS[@]+"${_BG_TASK_PIDS[@]}"}; do
		kill -0 "$_p" 2>/dev/null && _live+=("$_p")
	done
	_BG_TASK_PIDS=(${_live[@]+"${_live[@]}"})
}

_daemon_shutdown() {
	local grace="${DAEMON_SHUTDOWN_GRACE:-30}" p
	[[ "$grace" =~ ^[0-9]+$ ]] || grace=30
	# ONE total deadline shared across all tracked PIDs (not a per-PID budget),
	# so shutdown can never block longer than DAEMON_SHUTDOWN_GRACE in aggregate
	# even if several entries are still alive (or are recycled PIDs).
	local deadline=$((SECONDS + grace))
	for p in ${_BG_TASK_PIDS[@]+"${_BG_TASK_PIDS[@]}"}; do
		kill -0 "$p" 2>/dev/null || continue
		((SECONDS >= deadline)) && { log "SHUTDOWN: grace (${grace}s) elapsed; leaving remaining task(s) to finish."; break; }
		log "SHUTDOWN: waiting (up to ${grace}s total) for in-flight task (pid $p) to finish..."
		while kill -0 "$p" 2>/dev/null && ((SECONDS < deadline)); do sleep 1; done
	done
	rm -f "$PID_FILE" "$STATUS_FILE" 2>/dev/null || true
}

rainbow_sleep() {
	local duration_sec="$1"
	local status_text="$2"
	local steps=$((duration_sec * 10))
	# Frames stored as an array because the horizontal stroke is now the
	# Unicode BOX DRAWINGS LIGHT HORIZONTAL (U+2500, 3 bytes in UTF-8) —
	# bash's ${var:offset:1} indexes BYTES, so a string-form spinner would
	# slice the multi-byte char and print a mojibake fragment. Array
	# subscripting is character-safe.
	local spin=('─' '\' '|' '/')
	local idx=0
	local colors=('\033[31m' '\033[33m' '\033[32m' '\033[36m' '\033[34m' '\033[35m' '\033[37m')
	local color_idx=0
	local NC='\033[0m'

	# Hide cursor
	printf "\033[?25l"

	for ((i = 0; i < steps; i++)); do
		idx=$(((idx + 1) % 4))
		color_idx=$(((color_idx + 1) % 7))

		local char="${spin[$idx]}"
		local curr_color="${colors[$color_idx]}"

		# Print spinner line at bottom left
		printf "\r   %b[%s]%b Monitoring: %s \033[K" "$curr_color" "$char" "$NC" "$status_text"
		sleep 0.1
	done

	# Show cursor again
	printf "\033[?25h"
	# Clear the spinner line so it doesn't linger
	printf "\r\033[K"
}

monitor_logs() {
	local log_ab="${BACKUP_LOGFILE:-/var/log/auto_backupper.log}"
	local log_wt="${WATCHTOWER_LOGFILE:-/var/log/auto_backupper_watchtower.log}"
	local tail_pid=""
	local current_target=""

	trap 'printf "\033[?25h"; [[ -n "$tail_pid" ]] && kill "$tail_pid" 2>/dev/null; echo; log "LOGS: Monitor exited."; exit 0' INT TERM EXIT

	echo "=============================================================================="
	echo " WATCHTOWER LIVE LOG MONITOR"
	echo "=============================================================================="
	echo " [?] Auto-Switching between Watchtower (Idle) and Auto-Backupper (Active)"
	echo " [?] Press Ctrl+C to exit"
	echo "=============================================================================="

	while true; do
		local new_target=""
		local context_name=""
		local status_msg="Idle"

		# Get dynamic status from daemon
		if [[ -f "$STATUS_FILE" ]]; then
			status_msg=$(cat "$STATUS_FILE")
		fi

		if is_backup_running; then
			new_target="$log_ab"
			context_name="AUTO-BACKUPPER (Active)"
		else
			new_target="$log_wt"
			context_name="WATCHTOWER ($status_msg)"
		fi

		if [[ "$new_target" != "$current_target" ]]; then
			if [[ -n "$tail_pid" ]]; then
				kill "$tail_pid" 2>/dev/null
				wait "$tail_pid" 2>/dev/null
			fi

			echo ""
			echo ">>> SWITCHING CONTEXT: $context_name"
			echo ">>> SOURCE: $new_target"
			echo "------------------------------------------------------------------------------"

			if [[ ! -f "$new_target" ]]; then
				echo " [WAITING FOR LOG FILE TO BE CREATED...]"
				while [[ ! -f "$new_target" ]]; do sleep 1; done
			fi

			tail -n 15 -F "$new_target" &
			tail_pid=$!
			current_target="$new_target"
		fi

		rainbow_sleep 2 "$context_name"
	done
}

# ==============================================================================
# 3. STATUS CHECKS
# ==============================================================================

file_is_stable() {
	local file="$1"
	# The old check compared size only, twice, 1 second apart. A write that
	# paused for >1s between bytes — a sparse-hole tar -S, a stalled rsync
	# source, disk contention — read as "stable", so the scan would stamp a
	# checksum over a still-growing file; every later verify then treats that
	# premature checksum as authoritative. Harden it two ways:
	#   1. Minimum quiet age: skip any file touched within the last
	#      SCAN_STABLE_MIN_AGE seconds (it may still be mid-write).
	#   2. Multi-sample stability: size AND mtime must be identical across
	#      SCAN_STABLE_SAMPLES samples taken SCAN_STABLE_INTERVAL apart.
	# (The worker also holds BACKUP_LOCKFILE while writing, and the scan is
	# gated off whenever is_backup_running — see the monitor loop and
	# check_manual_triggers — so this primarily protects against out-of-band
	# uploads writing directly into WATCH_DIR.)
	# Optional overrides (min_age, samples, interval) let a caller use a lighter
	# check than the scan's conservative defaults. The internal mover passes a
	# short window so it isn't slowed to ~scan speed or made to skip files that
	# only just finished writing — see trigger_mover.
	local min_age="${2:-${SCAN_STABLE_MIN_AGE:-15}}"
	local samples="${3:-${SCAN_STABLE_SAMPLES:-3}}"
	local interval="${4:-${SCAN_STABLE_INTERVAL:-2}}"
	[[ "$samples"  =~ ^[0-9]+$ ]] || samples=3
	[[ "$interval" =~ ^[0-9]+$ ]] || interval=2
	[[ "$min_age"  =~ ^[0-9]+$ ]] || min_age=15
	((samples < 2)) && samples=2

	local now mtime
	now=$(date +%s)
	if ! mtime=$(timeout 2s stat -c%Y "$file" 2>/dev/null); then return 1; fi
	[[ "$mtime" =~ ^[0-9]+$ ]] || return 1
	# Apply the min-age gate only when mtime is in the past. A future mtime (NTP
	# skew, a -p-preserved timestamp) would otherwise make the file look
	# perpetually "too young" and never stabilise — so it would never be
	# checksummed by the scan nor moved off a full cache by the internal mover.
	if ((now >= mtime)); then
		((now - mtime < min_age)) && return 1
	fi

	local prev="" sig i
	for ((i = 0; i < samples; i++)); do
		if ! sig=$(timeout 2s stat -c'%s:%Y' "$file" 2>/dev/null); then return 1; fi
		[[ -n "$prev" && "$sig" != "$prev" ]] && return 1
		prev="$sig"
		((i < samples - 1)) && sleep "$interval"
	done
	return 0
}

is_backup_running() {
	if [[ -f "$BACKUP_LOCKFILE" ]]; then
		exec 9<"$BACKUP_LOCKFILE"
		if ! flock -n -s 9; then
			exec 9<&-
			return 0
		fi
		exec 9<&-
	fi
	return 1
}

is_mover_running() {
	pgrep -f '/usr/local/sbin/mover' >/dev/null 2>&1 && return 0
	pgrep -f '\bmover\b' >/dev/null 2>&1 && return 0
	return 1
}

is_parity_running() {
	local ini="/var/local/emhttp/var.ini"
	if [[ -f "${ini}" ]]; then
		local val
		val="$(awk -F= '/^mdResync/ {gsub(/^[ \t]+|[ \t]+$/,"",$2); print tolower($2)}' "${ini}" 2>/dev/null || true)"
		[[ "$val" =~ ^(1|true|yes|on)$ ]] && return 0
	fi
	pgrep -f "mdcmd.*check" >/dev/null 2>&1 && return 0
	return 1
}

is_array_started() {
	[[ "$OS_TYPE" != "unraid" ]] && { [[ -d "$ARRAY_BASE_PATH" ]] && return 0 || return 1; }
	if [[ -f /var/local/emhttp/state ]] && grep -q '^started$' /var/local/emhttp/state 2>/dev/null; then return 0; fi
	mountpoint -q /mnt/user && return 0
	return 1
}

# ==============================================================================
# 4. CACHE MANAGER
# ==============================================================================

get_cache_usage() {
	local df_out usage
	if ! df_out="$(df -P "${CACHE_DIR}" 2>/dev/null)"; then
		echo "0"
		return 1
	fi
	usage="$(echo "${df_out}" | awk 'NR==2 {print $5}' | tr -d '%')"
	# Guard against a non-numeric token (locale-mangled df, a diagnostic line
	# landing on NR==2, an erroring mount). A non-digit value would otherwise
	# reach `((usage >= CACHE_CRITICAL))` in manage_cache_state and, under
	# set -u, abort the entire daemon with an "unbound variable" error.
	[[ "$usage" =~ ^[0-9]+$ ]] || usage=0
	echo "${usage:-0}"
}

trigger_mover() {
	log "ACTION: Triggering Mover ($MOVER_TYPE)..."
	if [[ "$MOVER_TYPE" == "internal" ]]; then
		# Prune the .abpartial DIRECTORY (rsync's --partial-dir), not merely a
		# file literally named ".abpartial": it holds in-progress transfer chunks
		# under their real names, which must never be moved to the array or have
		# their source removed. `-not -name` failed to prune the directory, so
		# find descended into it and could move/delete a live partial.
		# `--update` stops an older cache copy from overwriting a NEWER file
		# already on the array; rsync then leaves that skipped source in place
		# (not transferred -> --remove-source-files won't delete it) rather than
		# clobbering the newer copy and deleting the source.
		find "$CACHE_DIR" -name ".abpartial" -prune -o -type f -print0 | while IFS= read -r -d '' src; do
			# Lighter stability check than the integrity scan: a short 5s quiet
			# window + 2 quick samples (~1s), so the inline mover doesn't stall
			# the monitor loop (~scan cost per file) or skip a file that only
			# just finished writing. In-progress rsync transfers are already
			# excluded by the .abpartial prune above and protected by --update.
			if file_is_stable "$src" 5 2 1; then
				local rel="${src#"$CACHE_DIR"/}"
				local dest="$ARRAY_BASE_PATH/$rel"
				mkdir -p "$(dirname "$dest")"
				rsync -a --update --remove-source-files "$src" "$dest"
			fi
		done
		find "$CACHE_DIR" -type d -empty -delete
		return
	fi

	local mover_bin="/usr/local/sbin/mover"
	[[ ! -x "$mover_bin" ]] && mover_bin="$(command -v mover)"
	if [[ -x "$mover_bin" ]]; then "$mover_bin" start >/dev/null 2>&1 & else log "ERROR: Mover binary not found."; fi
}

manage_cache_state() {
	[[ "${ENABLE_CACHE_MONITOR:-false}" != "true" ]] && return
	! is_array_started && return
	is_mover_running && return

	local usage
	usage=$(get_cache_usage)
	if ((usage >= CACHE_CRITICAL)); then
		send_notify "alert" "Cache Critical" "Cache is at ${usage}%"
		# Honour the parity guard even at the critical threshold. Running the
		# mover concurrently with a parity check/rebuild causes heavy disk-head
		# contention that slows parity and extends the reduced-redundancy
		# window. The lower THRESHOLD branch already does this; the critical
		# branch used to skip it and start the mover mid-parity.
		# Defer during a parity check unless explicitly overridden. FORCE_MOVER_ON_CRITICAL
		# is the operator's "run the mover at critical fill no matter what" escape
		# hatch, so it must bypass the parity guard too — otherwise a cache could
		# climb to 100% during a multi-hour parity check with no way through.
		if is_parity_running && [[ "${RUN_MOVER_DURING_PARITY:-false}" != "true" && "${FORCE_MOVER_ON_CRITICAL:-false}" != "true" ]]; then
			log "Cache critical (${usage}%) but a parity check is running; deferring mover (set RUN_MOVER_DURING_PARITY=true or FORCE_MOVER_ON_CRITICAL=true to override)."
			return
		fi
		if is_backup_running && [[ "${FORCE_MOVER_ON_CRITICAL:-false}" != "true" ]]; then return; fi
		trigger_mover
		return
	fi
	if ((usage >= CACHE_THRESHOLD)); then
		if is_backup_running; then return; fi
		if is_parity_running && [[ "${RUN_MOVER_DURING_PARITY:-false}" != "true" ]]; then return; fi
		log "Cache at ${usage}% (Threshold ${CACHE_THRESHOLD}%). Triggering Mover."
		trigger_mover
	fi
}

# ==============================================================================
# 5. DOCKER AUTO-UPDATER
# ==============================================================================

update_container_unraid() {
	local container="$1"
	if /usr/local/emhttp/plugins/dynamix.docker.manager/scripts/update_container "$container" >/dev/null 2>&1; then
		log "UPDATER: [Unraid] Successfully updated $container."
		return 0
	else
		log "UPDATER ERROR: [Unraid] Failed to update $container."
		return 1
	fi
}

update_container_compose() {
	local container="$1"

	# S9: Prefer modern "docker compose" (v2 plugin). Fall back to legacy
	# docker-compose (v1 Python, deprecated since 2022, absent on most modern systems).
	local compose_cmd=()
	if docker compose version >/dev/null 2>&1; then
		compose_cmd=(docker compose)
	elif command -v docker-compose >/dev/null 2>&1; then
		compose_cmd=(docker-compose)
	else
		log "UPDATER WARN: No 'docker compose' or 'docker-compose' available. Cannot update $container via compose."
		return 1
	fi

	local compose_file
	compose_file=$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project.config_files" }}' "$container")

	if [[ -z "$compose_file" ]]; then
		local work_dir
		work_dir=$(docker inspect --format '{{ .Config.WorkingDir }}' "$container")
		if [[ -f "$work_dir/docker-compose.yml" ]]; then compose_file="$work_dir/docker-compose.yml"; fi
	fi

	if [[ -f "$compose_file" ]]; then
		log "UPDATER: [Compose] Updating $container via $compose_file using '${compose_cmd[*]}'..."
		if "${compose_cmd[@]}" -f "$compose_file" pull "$container" && "${compose_cmd[@]}" -f "$compose_file" up -d "$container"; then
			log "UPDATER: [Compose] Success."
			return 0
		fi
	fi
	return 1
}

run_docker_update_task() {
	set_status "Checking Containers"
	log "UPDATER: Starting Container Check..."
	local containers
	containers=$(docker ps --format '{{.Names}}')

	for container in $containers; do
		if [[ " ${DOCKER_UPDATE_EXCLUDE} " == *" ${container} "* ]]; then continue; fi

		local image_name current_id new_id
		image_name=$(docker inspect --format='{{.Config.Image}}' "$container")
		current_id=$(docker inspect --format='{{.Image}}' "$container")

		if ! docker pull "$image_name" >/dev/null 2>&1; then
			log "UPDATER WARN: Failed to pull $image_name"
			continue
		fi

		new_id=$(docker inspect --format='{{.Id}}' "$image_name")

		if [[ "$current_id" != "$new_id" ]]; then
			set_status "Updating $container"
			log "UPDATER: Update found for $container. Applying..."
			send_notify "normal" "Auto-Updater" "Updating $container..."

			if [[ "$OS_TYPE" == "unraid" ]]; then
				update_container_unraid "$container"
			else
				if ! update_container_compose "$container"; then
					log "UPDATER: [Manual] New image downloaded for $container. Restart manually."
					send_notify "warning" "Update Ready" "New image for $container. Restart manually."
				fi
			fi
		fi
	done
	log "UPDATER: Job Finished."
	set_status "Idle"
}

check_update_scheduler() {
	[[ "${UPDATE_SCHEDULER_ENABLE:-false}" != "true" ]] && return
	is_backup_running && return
	if [[ "$(should_run_schedule "$UPDATE_SCHEDULER_MODE" "$UPDATE_SCHEDULER_VALUE" "$UPDATE_SCHEDULER_TIME" "$LAST_RUN_UPDATE")" == "true" ]]; then
		_bg_reap   # drop finished PIDs before tracking the new one
		run_docker_update_task &
		_BG_TASK_PIDS+=($!)   # tracked so the shutdown handler can wait on it
		atomic_write "$LAST_RUN_UPDATE" "$(date +%Y%m%d)"
	fi
}

# ==============================================================================
# 5b. DOCKER CONTAINER RECOVERY
# ==============================================================================
# Hands-off repair for Unraid Docker containers that come back broken after a
# reboot — the "RWLayer is unexpectedly nil" / "name already in use" case, where
# a container's config survives but its writable layer is gone, so it can't be
# started, only removed and recreated. Folded in from the standalone
# ghost-recovery tool so the daemon catches ghosts on startup (post-reboot) and
# on an interval, reusing the suite's logging, notifications and status.
#
# Each pass: for every container backed by an Unraid user template, healthy
# (running) ones get their "recovery recipe" (the exact docker run, reconstructed
# from `docker inspect`) refreshed on flash. A non-running one is recovered only
# if it is supposed to be running, decided by DOCKER_RECOVERY_DETECT:
#   autostart (default) — recover anything Unraid is set to autostart that isn't
#       running. Because the autostart list lives on the host, this catches
#       stopped, errored AND completely missing (orphaned) containers, while
#       leaving autostart-OFF containers (deliberately stopped) untouched.
#   states — recover only containers in DOCKER_RECOVERY_GHOST_STATES (default
#       created/dead/restarting); a clean "exited" is treated as intentionally
#       stopped. (Also the fallback when the autostart list can't be read.)
# To recover: `docker start` is tried first and, if that fails and recreate is
# allowed, the container is removed (if present) and recreated from the best
# blueprint available — a live `docker inspect`, the saved recipe, or (last
# resort, via php) the container's Unraid template — with its GUI labels
# preserved so it stays managed. A true ghost ("RWLayer unexpectedly nil") can't
# be inspected, so the recipe/template path is what actually rebuilds it. Either
# way recovery NEVER starts a container that is not supposed to be running.
#
# DATA SAFETY: app data lives in the bind-mounted appdata paths, not in the
# container. Removing/recreating a container does not touch those paths. This
# code never deletes a volume, an appdata path, or an image, and never changes
# the run-state of a container that is simply stopped.
#
# Unraid-targeted: discovery keys off the user-template dir, so on non-Unraid
# hosts (no templates) every pass is a no-op.

# Per-pass state. Globals (reset at the top of run_docker_recovery_task) so the
# helpers below can share the reconstructed args + counters without threading
# them through every call. Declared here to stay set -u safe.
declare -A _REC_TEMPLATE_OF=()
declare -A _REC_STATE_OF=()
declare -A _REC_AUTOSTART_ON=()       # set of container names Unraid is set to autostart
_REC_AUTOSTART_AVAILABLE=0            # 1 once the autostart list was read this pass
declare -a _REC_RUN_ARGS=()
_REC_CANDIDATE_REASON=""               # why the last candidate matched: autostart|orphan-image|ghost-state
declare -i _REC_N_OK=0 _REC_N_GHOST=0 _REC_N_SKIPPED=0 _REC_N_IMG=0 _REC_N_START=0 _REC_N_RECREATE=0 _REC_N_MANUAL=0 _REC_N_ERROR=0

# Reconstruct a container's `docker run` invocation from its (surviving) config
# into _REC_RUN_ARGS. Returns 1 if the container can't be inspected (the caller
# then falls back to a saved recipe).
_recovery_build_run_args() {
	local name="$1" id image netmode priv hostname restart maxretry shm cpuset mem line
	_REC_RUN_ARGS=()

	id=$(docker inspect -f '{{.Id}}' "$name" 2>/dev/null) || return 1
	[[ -z "$id" ]] && return 1

	# The image is the one field whose absence yields a broken recipe (an empty
	# positional arg -> `docker run ... ''`). Guard it so a container that vanishes
	# between this call and the .Id call above makes the whole build fail — the
	# caller then falls back to the saved recipe instead of recreating from, or
	# persisting, a corrupt one. The remaining fields being empty is benign: it
	# just omits an optional flag, which is correct for an unset value.
	image=$(docker inspect -f '{{.Config.Image}}' "$name" 2>/dev/null) || return 1
	[[ -z "$image" ]] && return 1
	netmode=$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$name")
	priv=$(docker inspect -f '{{.HostConfig.Privileged}}' "$name")
	hostname=$(docker inspect -f '{{.Config.Hostname}}' "$name")
	restart=$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$name")
	maxretry=$(docker inspect -f '{{.HostConfig.RestartPolicy.MaximumRetryCount}}' "$name")
	shm=$(docker inspect -f '{{.HostConfig.ShmSize}}' "$name")
	cpuset=$(docker inspect -f '{{.HostConfig.CpusetCpus}}' "$name")
	mem=$(docker inspect -f '{{.HostConfig.Memory}}' "$name")

	_REC_RUN_ARGS+=(run -d --name "$name")
	[[ -n "$netmode" && "$netmode" != "default" ]] && _REC_RUN_ARGS+=(--network "$netmode")
	[[ "$priv" == "true" ]] && _REC_RUN_ARGS+=(--privileged)

	if [[ -n "$restart" && "$restart" != "no" ]]; then
		if [[ "$restart" == "on-failure" && "${maxretry:-0}" -gt 0 ]]; then
			_REC_RUN_ARGS+=(--restart "on-failure:${maxretry}")
		else
			_REC_RUN_ARGS+=(--restart "$restart")
		fi
	fi

	# Skip a stale auto-generated hostname (the short container id).
	[[ -n "$hostname" && "$hostname" != "${id:0:12}" ]] && _REC_RUN_ARGS+=(--hostname "$hostname")
	[[ -n "$shm" && "$shm" != "67108864" && "$shm" != "0" ]] && _REC_RUN_ARGS+=(--shm-size "$shm")
	[[ -n "$cpuset" ]] && _REC_RUN_ARGS+=(--cpuset-cpus "$cpuset")
	[[ -n "$mem" && "$mem" != "0" ]] && _REC_RUN_ARGS+=(--memory "$mem")

	# --user: a container created with a non-default UID must keep it, or the
	# recreated one writes files as the image-default user.
	local user
	user=$(docker inspect -f '{{.Config.User}}' "$name")
	[[ -n "$user" ]] && _REC_RUN_ARGS+=(--user "$user")

	# --entrypoint: docker inspect reports the EFFECTIVE entrypoint, which
	# INCLUDES the image's own ENTRYPOINT. Emit --entrypoint ONLY when the
	# container actually OVERRIDES the image's entrypoint — otherwise the image
	# default already applies and forcing it is at best redundant and, for a
	# multi-element image entrypoint (e.g. ["/usr/bin/tini","--"]), would be
	# truncated to the first element and break the container. docker run can
	# express only a single entrypoint string, so a genuine multi-element
	# override can't be faithfully rebuilt: leave the image default and warn,
	# rather than recreate a knowingly-broken container.
	local -a ep=() img_ep=()
	while IFS= read -r line; do ep+=("$line"); done \
		< <(docker inspect -f '{{range .Config.Entrypoint}}{{println .}}{{end}}' "$name")
	while IFS= read -r line; do img_ep+=("$line"); done \
		< <(docker image inspect -f '{{range .Config.Entrypoint}}{{println .}}{{end}}' "$image" 2>/dev/null)
	local ep_join img_join
	printf -v ep_join '%s\n' ${ep[@]+"${ep[@]}"}
	printf -v img_join '%s\n' ${img_ep[@]+"${img_ep[@]}"}
	if [[ "$ep_join" != "$img_join" ]]; then
		if ((${#ep[@]} == 1)); then
			_REC_RUN_ARGS+=(--entrypoint "${ep[0]}")
		elif ((${#ep[@]} > 1)); then
			log "WARN: RECOVERY — $name overrides the image entrypoint with a multi-element value that 'docker run --entrypoint' cannot express; leaving the image default. Verify the recreated container and re-apply the override manually if needed."
		fi
	fi

	while IFS= read -r line; do [[ -n "$line" ]] && _REC_RUN_ARGS+=(-v "$line"); done \
		< <(docker inspect -f '{{range .HostConfig.Binds}}{{println .}}{{end}}' "$name")
	while IFS= read -r line; do [[ -n "$line" ]] && _REC_RUN_ARGS+=(-e "$line"); done \
		< <(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$name")
	while IFS= read -r line; do [[ -n "$line" ]] && _REC_RUN_ARGS+=(--label "$line"); done \
		< <(docker inspect -f '{{range $k,$v := .Config.Labels}}{{printf "%s=%s\n" $k $v}}{{end}}' "$name")
	while IFS= read -r line; do [[ -n "$line" ]] && _REC_RUN_ARGS+=(--device "$line"); done \
		< <(docker inspect -f '{{range .HostConfig.Devices}}{{printf "%s:%s:%s\n" .PathOnHost .PathInContainer .CgroupPermissions}}{{end}}' "$name")
	while IFS= read -r line; do [[ -n "$line" ]] && _REC_RUN_ARGS+=(--cap-add "$line"); done \
		< <(docker inspect -f '{{range .HostConfig.CapAdd}}{{println .}}{{end}}' "$name")
	while IFS= read -r line; do [[ -n "$line" ]] && _REC_RUN_ARGS+=(--cap-drop "$line"); done \
		< <(docker inspect -f '{{range .HostConfig.CapDrop}}{{println .}}{{end}}' "$name")
	while IFS= read -r line; do [[ -n "$line" ]] && _REC_RUN_ARGS+=(--add-host "$line"); done \
		< <(docker inspect -f '{{range .HostConfig.ExtraHosts}}{{println .}}{{end}}' "$name")

	# Additional HostConfig fields commonly set on hand-crafted containers. All
	# optional/additive — a flag is emitted only when the field is non-empty.
	while IFS= read -r line; do [[ -n "$line" ]] && _REC_RUN_ARGS+=(--group-add "$line"); done \
		< <(docker inspect -f '{{range .HostConfig.GroupAdd}}{{println .}}{{end}}' "$name")
	while IFS= read -r line; do [[ -n "$line" ]] && _REC_RUN_ARGS+=(--security-opt "$line"); done \
		< <(docker inspect -f '{{range .HostConfig.SecurityOpt}}{{println .}}{{end}}' "$name")
	while IFS= read -r line; do [[ -n "$line" ]] && _REC_RUN_ARGS+=(--dns "$line"); done \
		< <(docker inspect -f '{{range .HostConfig.Dns}}{{println .}}{{end}}' "$name")
	while IFS= read -r line; do [[ -n "$line" ]] && _REC_RUN_ARGS+=(--tmpfs "$line"); done \
		< <(docker inspect -f '{{range $p,$o := .HostConfig.Tmpfs}}{{if $o}}{{printf "%s:%s\n" $p $o}}{{else}}{{println $p}}{{end}}{{end}}' "$name")
	while IFS= read -r line; do [[ -n "$line" ]] && _REC_RUN_ARGS+=(--sysctl "$line"); done \
		< <(docker inspect -f '{{range $k,$v := .HostConfig.Sysctls}}{{printf "%s=%s\n" $k $v}}{{end}}' "$name")

	# --log-driver / --log-opt: only when a non-default driver is set (emitting
	# the json-file default with no opts would be redundant noise and could
	# override a differently-configured daemon default).
	local logdriver
	logdriver=$(docker inspect -f '{{.HostConfig.LogConfig.Type}}' "$name")
	if [[ -n "$logdriver" && "$logdriver" != "json-file" ]]; then
		_REC_RUN_ARGS+=(--log-driver "$logdriver")
		while IFS= read -r line; do [[ -n "$line" ]] && _REC_RUN_ARGS+=(--log-opt "$line"); done \
			< <(docker inspect -f '{{range $k,$v := .HostConfig.LogConfig.Config}}{{printf "%s=%s\n" $k $v}}{{end}}' "$name")
	fi

	# Port publishes (not valid with host networking).
	if [[ "$netmode" != "host" ]]; then
		local hip hport cport
		while IFS='|' read -r hip hport cport; do
			[[ -z "$cport" ]] && continue
			if [[ -n "$hip" ]]; then _REC_RUN_ARGS+=(-p "${hip}:${hport}:${cport}")
			else _REC_RUN_ARGS+=(-p "${hport}:${cport}"); fi
		done < <(docker inspect -f '{{range $p,$arr := .HostConfig.PortBindings}}{{range $arr}}{{printf "%s|%s|%s\n" .HostIp .HostPort $p}}{{end}}{{end}}' "$name")
	fi

	# Static IP on a custom network (br0, etc.).
	case "$netmode" in
		bridge|host|none|default|container:*) : ;;
		*)
			local ip
			ip=$(docker inspect -f "{{with (index .NetworkSettings.Networks \"$netmode\")}}{{if .IPAMConfig}}{{.IPAMConfig.IPv4Address}}{{end}}{{end}}" "$name" 2>/dev/null)
			[[ -n "$ip" ]] && _REC_RUN_ARGS+=(--ip "$ip")
			;;
	esac

	_REC_RUN_ARGS+=("$image")   # image is positional: after options, before cmd
	while IFS= read -r line; do _REC_RUN_ARGS+=("$line"); done \
		< <(docker inspect -f '{{range .Config.Cmd}}{{println .}}{{end}}' "$name")

	return 0
}

# Persist / load the recovery recipe, null-delimited so no eval is needed on
# replay. _recovery_save_args only writes when the recipe changed (flash-friendly).
_recovery_save_args() {
	local name="$1" file="$DOCKER_RECOVERY_DIR/${name}.args" tmp
	tmp=$(mktemp) || return 0
	printf '%s\0' "${_REC_RUN_ARGS[@]}" >"$tmp"
	if [[ -f "$file" ]] && cmp -s "$tmp" "$file"; then rm -f "$tmp"; else mv -f "$tmp" "$file"; fi
}
_recovery_load_args() {
	local name="$1" file="$DOCKER_RECOVERY_DIR/${name}.args"
	[[ -f "$file" ]] || return 1
	_REC_RUN_ARGS=()
	mapfile -d '' _REC_RUN_ARGS <"$file"
	((${#_REC_RUN_ARGS[@]} > 0))
}
_recovery_printable_cmd() {   # human-readable, copy-pasteable
	local out="docker" a
	for a in "${_REC_RUN_ARGS[@]}"; do out+=" $(printf '%q' "$a")"; done
	printf '%s' "$out"
}

# Reconstruct _REC_RUN_ARGS from a container's Unraid template — the last-resort
# source for a ghost that can't be inspected ("RWLayer unexpectedly nil") and has
# no saved recipe (the only blueprint left is the user template the GUI installs
# from). Parsed with php (SimpleXML), emitted NUL-delimited so values with
# spaces/commas/quotes survive. php ships with Unraid; without it this fallback
# is skipped. Returns 1 if there's no template, no php, or nothing usable parses.
_recovery_build_run_args_from_template() {
	local name="$1" tmpl="${_REC_TEMPLATE_OF[$name]:-}"
	[[ -n "$tmpl" && -f "$tmpl" ]] || return 1
	command -v php >/dev/null 2>&1 || return 1
	local parser
	parser=$(mktemp) || return 1
	cat >"$parser" <<'PHP'
<?php
// Build a `docker run` arg list from an Unraid container template, NUL-delimited.
$f = $argv[1] ?? '';
if ($f === '' || !is_file($f)) { exit(1); }
$xml = @simplexml_load_file($f);
if ($xml === false) { exit(1); }

// Minimal shell-style tokenizer for ExtraParams / PostArgs (handles quotes).
function tok($s) {
  $t=[]; $cur=''; $inS=false; $inD=false; $has=false; $n=strlen($s);
  for ($i=0;$i<$n;$i++){ $c=$s[$i];
    if ($inS){ if($c=="'") $inS=false; else $cur.=$c; continue; }
    if ($inD){ if($c=='"') $inD=false; elseif($c=='\\' && $i+1<$n && strpos('"\\$',$s[$i+1])!==false){ $cur.=$s[++$i]; } else $cur.=$c; continue; }
    if ($c=="'"){ $inS=true; $has=true; continue; }
    if ($c=='"'){ $inD=true; $has=true; continue; }
    if ($c===' '||$c==="\t"||$c==="\n"||$c==="\r"){ if($has){$t[]=$cur;$cur='';$has=false;} continue; }
    $cur.=$c; $has=true;
  }
  if ($has) $t[]=$cur;
  return $t;
}

$args=['run','-d'];
$name=trim((string)$xml->Name);
if ($name==='') exit(1);
$args[]='--name'; $args[]=$name;

$net=trim((string)$xml->Network); $netl=strtolower($net);
if ($net!=='' && $netl!=='default'){ $args[]='--network'; $args[]=$net; }
if (strtolower(trim((string)$xml->Privileged))==='true'){ $args[]='--privileged'; }

foreach (tok(trim((string)$xml->ExtraParams)) as $a){ if($a!=='') $args[]=$a; }

foreach ($xml->Config as $c){
  $type=(string)$c['Type']; $target=trim((string)$c['Target']); $mode=trim((string)$c['Mode']);
  $val=trim((string)$c); if ($val==='') $val=trim((string)$c['Default']);
  switch ($type){
    case 'Port':     if($netl!=='host' && $val!=='' && $target!==''){ $args[]='-p'; $args[]=$val.':'.$target.($mode!==''?'/'.$mode:''); } break;
    case 'Variable': if($target!==''){ $args[]='-e'; $args[]=$target.'='.$val; } break;
    case 'Path':     if($val!=='' && $target!==''){ $args[]='-v'; $args[]=$val.':'.$target.($mode!==''?':'.$mode:''); } break;
    case 'Label':    if($target!==''){ $args[]='--label'; $args[]=$target.'='.$val; } break;
    case 'Device':   if($val!==''){ $args[]='--device'; $args[]=($target!==''?$val.':'.$target:$val); } break;
  }
}

$myip=trim((string)$xml->MyIP);
if ($myip!=='' && !in_array($netl,['','bridge','host','none','default'],true)){ $args[]='--ip'; $args[]=$myip; }

$repo=trim((string)$xml->Repository);
if ($repo==='') exit(1);
$args[]=$repo;

foreach (tok(trim((string)$xml->PostArgs)) as $a){ if($a!=='') $args[]=$a; }

foreach ($args as $a){ echo $a."\0"; }
PHP
	_REC_RUN_ARGS=()
	# Pipe NUL output straight into mapfile (a bash var can't hold NULs).
	mapfile -d '' _REC_RUN_ARGS < <(php "$parser" "$tmpl" 2>/dev/null)
	rm -f "$parser"
	((${#_REC_RUN_ARGS[@]} >= 5))   # run -d --name <name> <image> at minimum
}

# UNRAID ONLY: ensure the recreated container carries dockerMan's management
# labels, so the GUI shows version/autostart and allows Edit (without
# net.unraid.docker.managed it appears as a "3rd party" container). dockerMan
# stamps these; our blueprints can lack them (a label-less saved recipe, or the
# generic template translation), so splice in any that are missing right after
# `run -d`. icon/webui come from the template. No-op off Unraid (OS_TYPE is set
# in section 2) — those labels are meaningless on OMV / generic Linux.
_recovery_ensure_unraid_labels() {
	[[ "${OS_TYPE:-linux}" == "unraid" ]] || return 0
	local name="$1" tmpl="${_REC_TEMPLATE_OF[$name]:-}" icon="" webui="" key a found
	local -a want=("net.unraid.docker.managed=dockerman") ins=()
	if [[ -n "$tmpl" && -f "$tmpl" ]]; then
		icon=$(sed -n 's:.*<Icon>\(.*\)</Icon>.*:\1:p' "$tmpl" | head -n1)
		webui=$(sed -n 's:.*<WebUI>\(.*\)</WebUI>.*:\1:p' "$tmpl" | head -n1)
		[[ -n "$icon" ]]  && want+=("net.unraid.docker.icon=$icon")
		[[ -n "$webui" ]] && want+=("net.unraid.docker.webui=$webui")
	fi
	for key in "${want[@]}"; do
		found=0
		for a in "${_REC_RUN_ARGS[@]}"; do [[ "$a" == "$key" ]] && { found=1; break; }; done
		((found)) || ins+=(--label "$key")
	done
	((${#ins[@]})) && _REC_RUN_ARGS=("${_REC_RUN_ARGS[@]:0:2}" "${ins[@]}" "${_REC_RUN_ARGS[@]:2}")
}

# Recover one broken ("ghost") container. Increments the _REC_N_* counters.
_recovery_one() {
	local name="$1" st newid
	if docker start "$name" >/dev/null 2>&1; then
		sleep 2
		st=$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null)
		if [[ "$st" == "running" ]]; then
			log "RECOVERY: recovered (start): $name is running again."
			_REC_N_START+=1
			return 0
		fi
		log "WARN: RECOVERY — $name started but is now '$st' (possible crash loop); check: docker logs $name"
		_REC_N_START+=1
		return 0
	fi

	if [[ "${DOCKER_RECOVERY_NO_RECREATE:-false}" == "true" ]]; then
		log "WARN: RECOVERY — $name will not start and DOCKER_RECOVERY_NO_RECREATE=true. Remove it and re-apply its template."
		_REC_N_MANUAL+=1
		return 1
	fi

	log "RECOVERY: plain start failed for $name (nil RWLayer / corrupt layer); recreating from config."

	if ! _recovery_build_run_args "$name"; then
		if _recovery_load_args "$name"; then
			log "RECOVERY: $name not inspectable; using saved recovery recipe."
		elif _recovery_build_run_args_from_template "$name"; then
			log "RECOVERY: $name not inspectable and no saved recipe; rebuilding from Unraid template."
		else
			log "WARN: RECOVERY — cannot inspect $name, no saved recipe, and no usable template. Re-add it from its template (Apps -> Previous Apps)."
			_REC_N_MANUAL+=1
			return 1
		fi
	fi

	_recovery_ensure_unraid_labels "$name"
	log "RECOVERY: plan: $(_recovery_printable_cmd)"
	if [[ "${DOCKER_RECOVERY_DRYRUN:-false}" == "true" ]]; then
		log "RECOVERY: dry-run — not removing/recreating $name."
		return 0
	fi

	# Rename the existing (ghost) container aside as a rollback point instead of
	# deleting it outright. Previously we `docker rm`'d before recreating, so a
	# failed recreate (torn/partial recipe, missing image, port clash) left the
	# container GONE with no way back. With rename-aside, a failed recreate is
	# rolled back to the original ghost — never worse than "present but broken".
	# A container with no record at all (orphan-image case) has nothing to
	# rename, so we recreate directly.
	local backup_name=""
	if docker inspect "$name" >/dev/null 2>&1; then
		backup_name="${name}.ab-recovery-bak"
		# Docker names legally contain '.', so a real, suite-managed container
		# could carry the backup suffix. Never clobber one: if a template exists
		# for that name, uniquify ours so the rm -f below only ever targets a
		# leftover of ours, never the user's container.
		[[ -n "${_REC_TEMPLATE_OF[$backup_name]:-}" ]] && backup_name="${name}.ab-recovery-bak.$$"
		docker rm -f "$backup_name" >/dev/null 2>&1 || true   # clear any stale backup of ours
		if ! docker rename "$name" "$backup_name" >/dev/null 2>&1; then
			# Rename unavailable — fall back to the old remove path so the name frees.
			backup_name=""
			if ! docker rm "$name" >/dev/null 2>&1; then docker rm -f "$name" >/dev/null 2>&1; fi
			if docker inspect "$name" >/dev/null 2>&1; then
				log "ERROR: RECOVERY — could not rename or remove $name; skipping. Try manually: docker rm -f $name"
				_REC_N_ERROR+=1
				return 1
			fi
		fi
	fi

	if newid=$(docker "${_REC_RUN_ARGS[@]}" 2>&1); then
		log "RECOVERY: recovered (recreate): $name -> ${newid:0:12}"
		# Success — discard the saved-aside original.
		[[ -n "$backup_name" ]] && docker rm -f "$backup_name" >/dev/null 2>&1 || true
		_REC_N_RECREATE+=1
		return 0
	else
		log "ERROR: RECOVERY — recreate failed for $name: $newid"
		if [[ -n "$backup_name" ]]; then
			if docker rename "$backup_name" "$name" >/dev/null 2>&1; then
				log "RECOVERY: recreate failed; restored the original $name (still a ghost — needs manual repair)."
			else
				log "ERROR: RECOVERY — recreate AND rollback failed for $name; the original is preserved as '$backup_name'."
			fi
		fi
		_REC_N_ERROR+=1
		return 1
	fi
}

# Is this docker state one we treat as a broken "ghost" to recover? A non-running
# container in any other state (notably a clean "exited") is treated as
# intentionally stopped and left untouched. Used only by the "states" detect mode
# (and as the fallback when the autostart list can't be read).
_recovery_state_is_ghost() {
	local state="$1" g
	# Unquoted on purpose: split the space-separated state list into words.
	for g in ${DOCKER_RECOVERY_GHOST_STATES:-created dead restarting}; do
		[[ "$state" == "$g" ]] && return 0
	done
	return 1
}

# Load Unraid's "autostart-enabled" set into _REC_AUTOSTART_ON from the autostart
# list file (one managed container name per line; an optional wait value may
# follow on the line, so we take the first whitespace-delimited token). The file
# lives on the host, not inside a container, so it is readable even when a
# container's record is gone — which is how autostart detection catches missing
# (orphaned) containers too. Sets _REC_AUTOSTART_AVAILABLE=1 and returns 0 on a
# successful read; returns 1 if the file isn't readable.
_recovery_load_autostart() {
	_REC_AUTOSTART_ON=()
	_REC_AUTOSTART_AVAILABLE=0
	local asf="${DOCKER_AUTOSTART_FILE:-/var/lib/docker/unraid-autostart}"
	[[ -r "$asf" ]] || return 1
	local line n
	while IFS= read -r line; do
		line="${line#"${line%%[![:space:]]*}"}"   # strip leading whitespace
		[[ -z "$line" || "$line" == \#* ]] && continue
		n="${line%%[[:space:]]*}"                  # first token = container name
		[[ -n "$n" ]] && _REC_AUTOSTART_ON["$n"]=1
	done <"$asf"
	_REC_AUTOSTART_AVAILABLE=1
	return 0
}

# Is the template's image present on disk? A MISSING container whose image is
# still here was installed and has since vanished (an "orphaned image" in Unraid
# terms) — strong evidence it should be recovered. Reads <Repository> from the
# template and asks docker if that image exists. (For a container that still has
# a record, its image is referenced and so never looks orphaned — which is why
# this trigger is scoped to __none__ and can't start a deliberately-stopped one.)
_recovery_image_present() {
	local name="$1" tmpl="${_REC_TEMPLATE_OF[$name]:-}" repo
	[[ -n "$tmpl" && -f "$tmpl" ]] || return 1
	command -v docker >/dev/null 2>&1 || return 1
	repo=$(sed -n 's:.*<Repository>\(.*\)</Repository>.*:\1:p' "$tmpl" | head -n1 | tr -d ' \t\r')
	[[ -n "$repo" ]] || return 1
	docker image inspect "$repo" >/dev/null 2>&1
}

# Decide whether a non-running template-backed container (state may be __none__,
# i.e. no container record at all) should be recovered, and record why in
# _REC_CANDIDATE_REASON. Primary signal is DOCKER_RECOVERY_DETECT:
#   autostart — "should be running" == Unraid autostart enabled (catches
#       exited/created/dead AND missing), leaving autostart-off alone;
#   states    — fall back to the DOCKER_RECOVERY_GHOST_STATES allowlist.
# On TOP of that, when DOCKER_RECOVERY_USE_ORPHAN_IMAGES=true, a MISSING (__none__)
# container whose template image is still present is recovered regardless of
# autostart — the leftover image is treated as proof it was installed and is gone.
_recovery_is_candidate() {
	local name="$1" state="$2"
	_REC_CANDIDATE_REASON=""
	if [[ "${DOCKER_RECOVERY_DETECT:-autostart}" == "autostart" && "$_REC_AUTOSTART_AVAILABLE" == "1" ]]; then
		if [[ -n "${_REC_AUTOSTART_ON[$name]:-}" ]]; then _REC_CANDIDATE_REASON="autostart"; return 0; fi
	elif [[ "$state" != "__none__" ]] && _recovery_state_is_ghost "$state"; then
		_REC_CANDIDATE_REASON="ghost-state"; return 0
	fi
	# Orphaned/leftover-image trigger (missing container + image still present).
	# A missing container is only treated as a recoverable orphan when we have
	# POSITIVE evidence it was supposed to be running — otherwise we'd resurrect
	# an app the user deliberately removed (GUI "Remove Container" leaves the
	# template + image behind, i.e. exactly state=__none__ + image present).
	#
	# In autostart mode with a readable list this branch is intentionally inert:
	# an autostart-ON missing container is already caught above (reason=autostart),
	# and an autostart-OFF one is, by definition, not supposed to be running. So
	# orphan-image only fires in the fallback paths (states mode, or the autostart
	# list couldn't be read), and even then only when a saved recovery recipe
	# exists — proof the daemon managed this container while it was healthy.
	if [[ "${DOCKER_RECOVERY_USE_ORPHAN_IMAGES:-true}" == "true" && "$state" == "__none__" ]]; then
		# Fire ONLY in the degraded autostart fallback: detect mode is autostart
		# but the list couldn't be read this pass. Rationale:
		#   - autostart mode WITH a readable list: an autostart-ON missing
		#     container is already handled above (reason=autostart) and an
		#     autostart-OFF one is intentionally down — so orphan-image is inert.
		#   - explicit states mode: the operator opted into state-based recovery
		#     only; a record-less container has no state to match, so we must NOT
		#     resurrect it (that was the bug — it brought back user-removed apps).
		# Even in the fallback, require a saved recipe AND the image present as
		# evidence the daemon managed this container while it was healthy. (The
		# recipe is pruned when a removal is later observed — see
		# run_docker_recovery_task's uninstalled branch — so a deliberately
		# removed container can't be resurrected from a stale recipe.)
		if [[ "${DOCKER_RECOVERY_DETECT:-autostart}" == "autostart" && "$_REC_AUTOSTART_AVAILABLE" != "1" ]] \
			&& [[ -f "$DOCKER_RECOVERY_DIR/${name}.args" ]] \
			&& _recovery_image_present "$name"; then
			_REC_CANDIDATE_REASON="orphan-image"; return 0
		fi
	fi
	return 1
}

# Full recovery pass: refresh recipes for healthy containers, recover ghosts.
# Like run_docker_update_task this runs unconditionally when called — the
# ENABLE gate lives in the callers (startup pass + check_recovery_interval),
# so a standalone `--recover` works regardless of DOCKER_RECOVERY_ENABLE.
# Returns 1 if anything still needs a human (manual action or error).
run_docker_recovery_task() {
	set_status "Recovering Containers"
	local mode="recover"
	[[ "${DOCKER_RECOVERY_DRYRUN:-false}" == "true" ]] && mode="dry-run"
	[[ "${DOCKER_RECOVERY_NO_RECREATE:-false}" == "true" ]] && mode="${mode}+no-recreate"
	log "RECOVERY: ===== Container recovery start (mode: $mode) ====="

	if ! command -v docker >/dev/null 2>&1; then
		log "RECOVERY: docker not available — skipping."
		set_status "Idle"
		return 0
	fi
	if ! docker info >/dev/null 2>&1; then
		log "WARN: RECOVERY — cannot reach the Docker daemon; skipping this pass."
		set_status "Idle"
		return 0
	fi

	mkdir -p "$DOCKER_RECOVERY_DIR" 2>/dev/null

	# Reset per-pass state.
	_REC_TEMPLATE_OF=()
	_REC_STATE_OF=()
	_REC_AUTOSTART_ON=()
	_REC_AUTOSTART_AVAILABLE=0
	_REC_RUN_ARGS=()
	_REC_CANDIDATE_REASON=""
	_REC_N_OK=0; _REC_N_GHOST=0; _REC_N_SKIPPED=0; _REC_N_IMG=0; _REC_N_START=0; _REC_N_RECREATE=0; _REC_N_MANUAL=0; _REC_N_ERROR=0

	# Map Unraid user template name -> template file.
	local tdir="${DOCKER_TEMPLATE_DIR:-/boot/config/plugins/dockerMan/templates-user}"
	if [[ ! -d "$tdir" ]]; then
		log "RECOVERY: template dir not found ($tdir) — nothing to manage (non-Unraid host?)."
		set_status "Idle"
		return 0
	fi
	local f tname
	while IFS= read -r -d '' f; do
		tname=$(sed -n 's:.*<Name>\(.*\)</Name>.*:\1:p' "$f" | head -n1)
		[[ -n "$tname" ]] && _REC_TEMPLATE_OF["$tname"]="$f"
	done < <(find "$tdir" -maxdepth 1 -name '*.xml' -print0 2>/dev/null)

	if ((${#_REC_TEMPLATE_OF[@]} == 0)); then
		log "RECOVERY: no user templates found under $tdir; nothing to manage."
		set_status "Idle"
		return 0
	fi

	# Snapshot every container the daemon knows: name -> state.
	local cname cstate
	while IFS=$'\t' read -r cname cstate; do
		[[ -n "$cname" ]] && _REC_STATE_OF["$cname"]="$cstate"
	done < <(docker ps -a --format '{{.Names}}\t{{.State}}')

	# Load the "should be running" signal. In autostart mode this is Unraid's
	# autostart list; when it can't be read, fall back to the state allowlist.
	if [[ "${DOCKER_RECOVERY_DETECT:-autostart}" == "autostart" ]]; then
		if _recovery_load_autostart; then
			log "RECOVERY: autostart detection — ${#_REC_AUTOSTART_ON[@]} container(s) marked autostart in ${DOCKER_AUTOSTART_FILE:-/var/lib/docker/unraid-autostart}."
		else
			log "WARN: RECOVERY — autostart list not readable (${DOCKER_AUTOSTART_FILE:-/var/lib/docker/unraid-autostart}); falling back to state-based detection. Set DOCKER_AUTOSTART_FILE if your path differs."
		fi
	fi

	local name state
	local TNAMES=()
	mapfile -t TNAMES < <(printf '%s\n' "${!_REC_TEMPLATE_OF[@]}" | sort)
	for name in "${TNAMES[@]}"; do
		state="${_REC_STATE_OF[$name]:-__none__}"
		if [[ "$state" == "running" ]]; then
			_REC_N_OK+=1
			# Keep the recipe fresh while the container is healthy.
			_recovery_build_run_args "$name" && _recovery_save_args "$name"
		elif _recovery_is_candidate "$name" "$state"; then
			_REC_N_GHOST+=1
			[[ "$_REC_CANDIDATE_REASON" == "orphan-image" ]] && _REC_N_IMG+=1
			log "RECOVERY: $name needs recovery (state=$state, via $_REC_CANDIDATE_REASON) — attempting."
			_recovery_one "$name"
		elif [[ "$state" == "__none__" ]]; then
			# Template exists, no container, not a recovery candidate — the
			# container was uninstalled/removed (or is autostart-OFF and gone).
			# Drop any stale recovery recipe so a later mode switch (states mode
			# or an unreadable autostart list) can't resurrect it from a
			# months-old recipe. In the default autostart-readable mode a
			# removed non-autostart container reaches here, so its recipe is
			# cleaned up even though orphan-image is inert in that mode.
			[[ -f "$DOCKER_RECOVERY_DIR/${name}.args" ]] && rm -f "$DOCKER_RECOVERY_DIR/${name}.args"
		else
			# Exists, not running, not a candidate (autostart-off, or a non-ghost
			# state in states mode). Intentionally down — leave it EXACTLY as-is.
			_REC_N_SKIPPED+=1
			log "RECOVERY: leaving $name as-is (state=$state) — not a recovery candidate (intentionally stopped)."
		fi
	done

	log "RECOVERY: summary: ${_REC_N_OK} healthy, ${_REC_N_GHOST} to recover, ${_REC_N_SKIPPED} left stopped | recovered ${_REC_N_START} via start, ${_REC_N_RECREATE} via recreate | ${_REC_N_MANUAL} need manual action, ${_REC_N_ERROR} error(s)."
	((_REC_N_IMG > 0)) && log "RECOVERY: ${_REC_N_IMG} of those were missing containers flagged by a leftover/orphaned image (template + image present, no container)."
	log "RECOVERY: ===== Container recovery end ====="

	if ((_REC_N_START > 0 || _REC_N_RECREATE > 0)); then
		send_notify "normal" "Container Recovery" "Recovered ${_REC_N_START} via start, ${_REC_N_RECREATE} via recreate."
	fi
	if ((_REC_N_MANUAL > 0 || _REC_N_ERROR > 0)); then
		send_notify "alert" "Container Recovery" "${_REC_N_MANUAL} need manual action, ${_REC_N_ERROR} error(s). See $LOGFILE."
	fi

	atomic_write "$LAST_RUN_RECOVERY" "$(date +%Y%m%d)"
	set_status "Idle"
	((_REC_N_MANUAL + _REC_N_ERROR > 0)) && return 1
	return 0
}

# Interval gate for the monitor loop: run a recovery pass at most once per
# DOCKER_RECOVERY_INTERVAL seconds (0 = startup-only). Backgrounded (&) so it
# never blocks the daemon's poll cycle, mirroring the updater/cleanup schedulers.
check_recovery_interval() {
	[[ "${DOCKER_RECOVERY_ENABLE:-false}" != "true" ]] && return
	is_backup_running && return
	local interval="${DOCKER_RECOVERY_INTERVAL:-3600}"
	[[ "$interval" =~ ^[0-9]+$ ]] || interval=3600
	((interval == 0)) && return
	local now last=0
	now=$(date +%s)
	if [[ -f "$RECOVERY_LAST_PASS_EPOCH" ]]; then
		last=$(cat "$RECOVERY_LAST_PASS_EPOCH" 2>/dev/null || echo 0)
		[[ "$last" =~ ^[0-9]+$ ]] || last=0
	fi
	if ((now - last >= interval)); then
		# Mark the epoch up front (before the &) so a long pass can't re-fire.
		atomic_write "$RECOVERY_LAST_PASS_EPOCH" "$now"
		_bg_reap   # drop finished PIDs before tracking the new one
		run_docker_recovery_task &
		_BG_TASK_PIDS+=($!)   # tracked so the shutdown handler can wait on it
	fi
}

# ==============================================================================
# 6. SCHEDULER UTILS
# ==============================================================================

should_run_schedule() {
	local mode="$1" value="$2" time_target="$3" last_run_file="$4"
	local today_date
	today_date=$(date +%Y%m%d)

	if [[ -f "$last_run_file" && "$(cat "$last_run_file")" == "$today_date" ]]; then
		echo "false"
		return
	fi

	local current_hm target_hm
	current_hm=$(date +%H%M)
	target_hm=$(echo "$time_target" | tr -d ':')
	# Force base-10: stripping a single leading zero leaves "0MM" for the
	# 00:xx hour, and 08/09 are invalid octal digits in arithmetic context, so
	# `-lt` would error and fall through (firing the schedule early). Compare
	# the raw HHMM values with an explicit 10# radix; coerce a non-numeric
	# configured time to 0 so a typo'd SCHEDULER_TIME can't spew base errors.
	[[ "$current_hm" =~ ^[0-9]+$ ]] || current_hm=0
	[[ "$target_hm" =~ ^[0-9]+$ ]] || target_hm=0
	if (( 10#$current_hm < 10#$target_hm )); then echo "false"; return; fi

	# S6: Overdue recovery. If the daemon was down through the scheduled window
	# (e.g. host rebooted across a 02:00 weekly Saturday schedule and came up
	# Sunday), the normal day-matching check below would skip it until next
	# Saturday. Detect "much too long since last run" and fire now regardless.
	local days_since_last=99999
	if [[ -f "$last_run_file" ]]; then
		local last_date_str
		last_date_str=$(cat "$last_run_file" 2>/dev/null || echo "")
		if [[ "$last_date_str" =~ ^[0-9]{8}$ ]]; then
			local last_sec today_sec
			last_sec=$(date -d "${last_date_str:0:4}-${last_date_str:4:2}-${last_date_str:6:2}" +%s 2>/dev/null || echo 0)
			today_sec=$(date +%s)
			if [[ "$last_sec" -gt 0 ]]; then
				days_since_last=$(( (today_sec - last_sec) / 86400 ))
			fi
		fi
	fi
	local overdue="false"
	case "$mode" in
		daily)     [[ $days_since_last -gt 1   ]] && overdue="true" ;;
		weekly)    [[ $days_since_last -gt 7   ]] && overdue="true" ;;
		monthly)   [[ $days_since_last -gt 31  ]] && overdue="true" ;;
		quarterly) [[ $days_since_last -gt 93  ]] && overdue="true" ;;
		annually)  [[ $days_since_last -gt 366 ]] && overdue="true" ;;
	esac
	if [[ "$overdue" == "true" ]]; then
		echo "true"
		return
	fi

	local trigger="false"
	local current_mon
	current_mon=$(date +%m)
	local current_day
	current_day=$(date +%d)
	local current_day_clean="${current_day#0}"
	local value_clean="${value#0}"

	# Clamp a 29/30/31 day target to this month's real last day so an
	# end-of-month schedule still fires in Feb/Apr/Jun/Sep/Nov instead of being
	# skipped and then overdue-firing on the wrong day the following month.
	local last_dom eff_day
	last_dom=$(date -d "$(date +%Y-%m-01) +1 month -1 day" +%d 2>/dev/null)
	last_dom="${last_dom#0}"
	eff_day="$value_clean"
	if [[ "$eff_day" =~ ^[0-9]+$ && "$last_dom" =~ ^[0-9]+$ ]] && (( eff_day > last_dom )); then
		eff_day="$last_dom"
	fi

	case "$mode" in
	"annually")
		# VALUE is "DD" (January, legacy form) or "MM/DD" / "MM-DD" to choose
		# the month; the day is clamped to that month's real last day.
		local a_mon a_day a_last
		if [[ "$value" == *[/-]* ]]; then
			a_mon="${value%%[/-]*}"
			a_day="${value##*[/-]}"
		else
			a_mon="01"
			a_day="$value"
		fi
		[[ "$a_mon" =~ ^[0-9]+$ ]] && printf -v a_mon '%02d' "$((10#$a_mon))"
		a_day="${a_day#0}"
		a_last=$(date -d "$(date +%Y)-${a_mon}-01 +1 month -1 day" +%d 2>/dev/null)
		a_last="${a_last#0}"
		if [[ "$a_day" =~ ^[0-9]+$ && "$a_last" =~ ^[0-9]+$ ]] && (( a_day > a_last )); then a_day="$a_last"; fi
		if [[ "$current_mon" == "$a_mon" && "$current_day_clean" == "$a_day" ]]; then trigger="true"; fi
		;;
	"quarterly") if [[ "$current_mon" =~ ^(01|04|07|10)$ && "$current_day_clean" == "$eff_day" ]]; then trigger="true"; fi ;;
	"monthly") if [[ "$current_day_clean" == "$eff_day" ]]; then trigger="true"; fi ;;
	"weekly")
		local dow
		dow=$(date +%a)
		if [[ "${dow,,}" == "${value,,}" ]]; then trigger="true"; fi
		;;
	"daily") trigger="true" ;;
	esac
	echo "$trigger"
}

check_backup_scheduler() {
	[[ "${BACKUP_SCHEDULER_ENABLE:-false}" != "true" ]] && return
	is_backup_running && return
	if [[ "$(should_run_schedule "$BACKUP_SCHEDULER_MODE" "$BACKUP_SCHEDULER_VALUE" "$BACKUP_SCHEDULER_TIME" "$LAST_RUN_BACKUP")" == "true" ]]; then
		log "SCHEDULER: Firing Backup Job..."
		send_notify "normal" "Backup Scheduler" "Starting auto_backupper..."
		# S5: only mark the day as run if we actually launched the script.
		# (The script itself writes LAST_RUN_BACKUP on successful completion too.)
		if [[ -x "$MAIN_BACKUP_SCRIPT" || -f "$MAIN_BACKUP_SCRIPT" ]]; then
			# S1: pass config using --config=PATH form so the auto-backupper
			# actually honours it (both --config=VAL and --config VAL now work,
			# but equals form is safe against any remaining arg-parser quirks).
			nohup "$MAIN_BACKUP_SCRIPT" "--config=$CFG_TO_LOAD" >/dev/null 2>&1 &
			atomic_write "$LAST_RUN_BACKUP" "$(date +%Y%m%d)"
		else
			log "ERROR: Backup script not found or not executable at $MAIN_BACKUP_SCRIPT. Schedule NOT marked done; will retry next cycle."
			send_notify "alert" "Scheduler Error" "Backup script missing: $MAIN_BACKUP_SCRIPT"
		fi
	fi
}

check_cleanup_scheduler() {
	[[ "${CLEANUP_SCHEDULER_ENABLE:-false}" != "true" ]] && return
	is_backup_running && return
	if [[ "$(should_run_schedule "$CLEANUP_SCHEDULER_MODE" "$CLEANUP_SCHEDULER_VALUE" "$CLEANUP_SCHEDULER_TIME" "$LAST_RUN_CLEANUP")" == "true" ]]; then
		run_cleanup_task &
		atomic_write "$LAST_RUN_CLEANUP" "$(date +%Y%m%d)"
	fi
}

check_verify_scheduler() {
	if [[ "${VERIFY_SCHEDULER_ENABLE:-false}" != "true" ]]; then return 1; fi
	is_backup_running && return 1
	is_mover_running && return 1
	if [[ "$(should_run_schedule "$VERIFY_SCHEDULER_MODE" "$VERIFY_SCHEDULER_VALUE" "$VERIFY_SCHEDULER_TIME" "$LAST_RUN_VERIFY")" == "true" ]]; then
		log "SCHEDULER: Starting Scheduled Full Verification..."
		send_notify "warning" "Verification Started" "Scheduled deep scan active."
		perform_scan "$WATCH_DIR" "true"
		atomic_write "$LAST_RUN_VERIFY" "$(date +%Y%m%d)"
		send_notify "normal" "Verification Finished" "Deep scan complete."
		return 0
	fi
	return 1
}

check_manual_triggers() {
	# --- 1. Docker Update ---
	if [[ -f "$TRIGGER_UPDATE" ]]; then
		log "MANUAL: Trigger received for Docker Update."
		rm -f "$TRIGGER_UPDATE"
		run_docker_update_task
	fi

	# --- 2. Full Verify ---
	# Defer (don't consume the trigger) while a backup is running: perform_scan
	# would otherwise walk the live, in-progress backup tree and could checksum a
	# half-written archive. The scheduler paths already gate on is_backup_running;
	# the manual triggers used to bypass that. Leaving the trigger in place means
	# it fires automatically on the next cycle once the backup releases its lock
	# (the monitor loop already logs the paused/resumed transition, so no spam).
	if [[ -f "$TRIGGER_VERIFY" ]]; then
		if is_backup_running; then
			: # deferred until the backup finishes
		else
			log "MANUAL: Trigger received for Full Verification."
			rm -f "$TRIGGER_VERIFY"
			send_notify "warning" "Manual Verify" "Starting deep scan..."
			perform_scan "$WATCH_DIR" "true"
			send_notify "normal" "Manual Verify" "Scan complete."
		fi
	fi

	# --- 3. Quick Scan ---
	if [[ -f "$TRIGGER_SCAN" ]]; then
		if is_backup_running; then
			: # deferred until the backup finishes (see Full Verify note above)
		else
			log "MANUAL: Trigger received for Quick Scan."
			rm -f "$TRIGGER_SCAN"
			perform_scan "$WATCH_DIR" "false"
			log "MANUAL: Quick Scan Complete."
		fi
	fi

	# --- 4. Config Reload ---
	if [[ -f "$TRIGGER_CONFIG" ]]; then
		local new_cfg
		new_cfg=$(cat "$TRIGGER_CONFIG")
		rm -f "$TRIGGER_CONFIG"
		if [[ -n "$new_cfg" && -f "$new_cfg" ]]; then
			log "CONFIG: Switching config file to: $new_cfg"
			CFG_TO_LOAD="$new_cfg"
		elif [[ -n "$new_cfg" ]]; then
			log "ERROR: Requested config $new_cfg not found. Reloading current ($CFG_TO_LOAD)."
		fi
		# Actually RE-SOURCE the config. The handler previously only swapped the
		# CFG_TO_LOAD path variable and never re-read the file, so --reload was a
		# no-op for every tunable (MONITOR_INTERVAL, schedules, thresholds, …) —
		# they kept their boot values until a full restart. Syntax-check first so
		# a malformed cfg logs an error instead of injecting a partial/garbled state.
		if [[ -f "$CFG_TO_LOAD" ]]; then
			if bash -n "$CFG_TO_LOAD" 2>/dev/null; then
				# Source with set -u TEMPORARILY DISABLED. bash -n above catches
				# only syntax errors; a syntactically-valid cfg that references an
				# unset variable would, under the daemon's set -u, abort this very
				# shell (check_manual_triggers runs inline in the monitor loop, no
				# errexit/ERR net) and silently kill a long-running daemon on a
				# routine --reload. set +u around the source contains that fault;
				# the re-derive below also runs in the window since it reads
				# config-supplied vars. set -u is restored immediately after.
				set +u
				# shellcheck disable=SC1090
				source "$CFG_TO_LOAD"
				# Re-derive config-dependent vars so they track the reloaded values.
				CORRUPTION_REPORT="${WATCH_DIR}/${CHECKSUM_DIR}/${HOSTNAME_VAR}_corruption_report.txt"
				# The scheduler markers are anchored to WATCH_DIR, so re-derive
				# them too or a reloaded WATCH_DIR change would leave them under
				# the old tree (CORRUPTION_REPORT is re-derived for the same
				# reason). Keep these in sync with the boot-time block above.
				AB_STATE_DIR="${WATCH_DIR}/${CHECKSUM_DIR}/.watchtower_state"
				mkdir -p "$AB_STATE_DIR" 2>/dev/null || AB_STATE_DIR="/tmp"
				LAST_RUN_BACKUP="$AB_STATE_DIR/last_run_backup"
				LAST_RUN_CLEANUP="$AB_STATE_DIR/last_run_cleanup"
				LAST_RUN_VERIFY="$AB_STATE_DIR/last_run_verify"
				LAST_RUN_UPDATE="$AB_STATE_DIR/last_run_update"
				LAST_RUN_RECOVERY="$AB_STATE_DIR/last_run_recovery"
				RECOVERY_LAST_PASS_EPOCH="$AB_STATE_DIR/recovery_epoch"
				set -u
				log "CONFIG: Reloaded $CFG_TO_LOAD (note: a changed WATCHTOWER_LOGFILE needs a daemon restart — the log FD is fixed for the daemon's life)."
			else
				log "ERROR: $CFG_TO_LOAD has a syntax error (bash -n failed); NOT reloading. Keeping current config."
			fi
		else
			log "ERROR: Config $CFG_TO_LOAD not found on reload. Keeping current config."
		fi
	fi

	# --- 5. Cleanup ---
	if [[ -f "$TRIGGER_CLEANUP" ]]; then
		log "MANUAL: Trigger received for Cleanup."
		rm -f "$TRIGGER_CLEANUP"
		run_cleanup_task
	fi

	# --- 6. Force Cycle ---
	if [[ -f "$TRIGGER_FORCE" ]]; then
		log "MANUAL: Force Trigger received. Starting immediate cycle..."
		rm -f "$TRIGGER_FORCE"
	fi

	# --- 7. Container Recovery ---
	if [[ -f "$TRIGGER_RECOVERY" ]]; then
		log "MANUAL: Trigger received for Container Recovery."
		rm -f "$TRIGGER_RECOVERY"
		run_docker_recovery_task
		atomic_write "$RECOVERY_LAST_PASS_EPOCH" "$(date +%s)"
	fi
}

# ==============================================================================
# 7. CHECKSUM & CLEANUP LOGIC
# ==============================================================================

# Hostname-case drift detector. Mirror of the helper in auto-backupper.sh
# (suite policy is "no shared library", so this is intentional copy +
# adapt). Scans BACKUP_BASE for legacy artifacts that pre-date the
# UPPERCASE canonical hostname rule. Read-only — emits a WARN log line
# per drifted artifact with the exact migration command. The watchtower
# pays attention to the same artifacts the auto-backupper writes
# (systems/<HOST>/ tree and .checksums/<host>_corruption_report.txt),
# so both writers can surface the drift independently.
warn_hostname_case_drift() {
	local base="${WATCH_DIR:-}"
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
	local chk_dir="$base/${CHECKSUM_DIR:-.checksums}"
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

run_cleanup_task() {
	set_status "Cleaning Junk Files"
	log "CLEANUP: Starting junk file removal..."
	local base_path="${SHARES_BASE_FOLDER:-/mnt/user}"
	base_path="${base_path%/}"

	# 1. File System Cleanup (Apple metadata + stray .DS_Store only).
	# NOTE: .tmp was intentionally REMOVED from the directory list — it matches
	# legitimate hidden dirs used by git, IDEs, nodejs, firefox, rsync, etc.
	if [[ -d "$base_path" ]]; then
		find "$base_path" -maxdepth 6 -noleaf \( -type f \( -name ".DS_Store" -o -name "._.DS_Store" \) -o -type d \( -name ".AppleDB" -o -name ".AppleDesktop" -o -name ".AppleDouble" -o -name ".TemporaryItems" \) \) -exec rm -rf "{}" \; 2>/dev/null
	fi

	# 2. Optional, opt-in media-metadata cleanup.
	# This deletes *.nfo and *.txt in media/TV and media/Movies. These file types
	# are used as legitimate library metadata by Plex/Jellyfin/Kodi/Emby, so this
	# is OFF by default. Set CLEANUP_MEDIA_METADATA=true in the config ONLY if
	# your workflow genuinely needs these stripped (e.g. *arr failed-download leftovers).
	if [[ "${CLEANUP_MEDIA_METADATA:-false}" == "true" ]]; then
		log "CLEANUP: CLEANUP_MEDIA_METADATA=true — removing .nfo/.txt from media/TV and media/Movies"
		for d in "$base_path/media/TV" "$base_path/media/Movies"; do
			if [[ -d "$d" ]]; then
				find "$d" -maxdepth 4 -noleaf -type f \( -name "*.nfo" -o -name "*.txt" \) -exec rm -f "{}" \; 2>/dev/null
			fi
		done
	fi

	# 3. Docker Cleanup
	if command -v docker >/dev/null 2>&1; then
		set_status "Pruning Docker"
		log "CLEANUP: Pruning unused Docker data..."
		# Remove container cache, unused networks, and dangling images.
		# Does NOT remove volumes or stopped containers (data safety).
		# Group the redirect so ALL three prune calls are silenced (previously
		# only `docker builder prune` was redirected).
		{ docker image prune -f && docker network prune -f && docker builder prune -f; } >/dev/null 2>&1
	fi

	log "CLEANUP: Job Finished."
	set_status "Idle"
}

process_file() {
	local file="$1" base="$2" force_verify="${3:-false}"
	local relative="${file#"$base"/}"
	local chk_dir="$base/$CHECKSUM_DIR/$(dirname "$relative")"
	local name
	name="$(basename "$relative")"

	# Glob for any existing dated checksum sibling. The filename pattern
	# is <data_name>_<YYYYMMDD>.sha256 — the date suffix is the discovery
	# date, stamped once by whichever script first observed the file
	# (watchtower, auto-backupper's produce flow, or the legacy
	# back-fill generator). The suffix is the source-of-truth for the
	# file's age and is what pull-side retention filtering keys off.
	local existing_chk=""
	shopt -s nullglob
	local c
	for c in "${chk_dir}/${name}"_[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9].sha256; do
		# In normal steady-state there is at most one match. If
		# multiple exist (transient duplicate from a back-fill race),
		# either is fine for verification purposes — pick the first.
		existing_chk="$c"
		break
	done
	shopt -u nullglob

	if [[ -n "$existing_chk" ]]; then
		if [[ "${ENABLE_VERIFICATION:-false}" == "true" || "$force_verify" == "true" ]]; then
			local exp act
			exp=$(awk '{print $1}' "$existing_chk")
			# Wrap sha256sum in `timeout` so a stale FUSE / SMB mount
			# can't wedge the watchtower daemon indefinitely. 10 minutes
			# is generous for very large archives; matches the ceiling
			# used by auto-backupper.sh's verify_file. On timeout, $act
			# is empty and the corruption check is skipped (better to
			# miss a verification cycle than to deadlock).
			act=$(timeout 600 sha256sum "$file" 2>/dev/null | awk '{print $1}')
			if [[ -z "$act" ]]; then
				log "WARN: sha256sum timed out or failed for $file (skipping verify this pass)"
			elif [[ "$exp" != "$act" ]]; then
				log "CORRUPTION: $file"
				rotate_corruption_report_if_large
				echo "[$(date)] CORRUPTION: $file" >>"$CORRUPTION_REPORT"
				send_notify "alert" "Corruption Detected" "$file"
			fi
		fi
		return
	fi

	if ! file_is_stable "$file"; then return; fi

	# First sighting → stamp today's date as the discovery suffix.
	local today
	today="$(date +%Y%m%d)"
	local new_chk="${chk_dir}/${name}_${today}.sha256"
	log "NEW CHECKSUM: ${relative} (${today})"
	mkdir -p "$chk_dir"

	# Atomic write: temp + rename. Same `timeout` ceiling as the verify
	# path above — a hung filesystem read should fail this scan cycle,
	# not the entire daemon.
	local tmp="${new_chk}.tmp.$$"
	local hash
	hash=$(timeout 600 sha256sum "$file" 2>/dev/null | awk '{print $1}')
	if [[ -n "$hash" ]]; then
		printf '%s\n' "$hash" >"$tmp" && mv -f "$tmp" "$new_chk"
	else
		log "WARN: sha256sum timed out or failed for new file $file"
		rm -f "$tmp" 2>/dev/null || true
	fi
}

perform_scan() {
	local base="$1" verify_override="${2:-false}"
	[[ ! -d "$base" ]] && return

	if [[ "$verify_override" == "true" ]]; then
		set_status "Verifying ALL Files"
	else
		set_status "Scanning New Files"
	fi

	local max_jobs
	max_jobs=$(get_thread_count)

	# --- LOG OPTIMIZATION ---
	# Only log if thread count is > 1 AND differs from the last log entry.
	if [[ "$max_jobs" -gt 1 ]]; then
		if [[ "$max_jobs" != "$LAST_LOGGED_THREADS" ]]; then
			log "SCAN: Multi-threading enabled (Threads: $max_jobs)"
			LAST_LOGGED_THREADS="$max_jobs"
		fi
	fi
	# ------------------------

	while IFS= read -r -d '' file; do
		if [[ "$max_jobs" -gt 1 ]]; then
			while (($(jobs -r -p | wc -l) >= max_jobs)); do
				wait -n 2>/dev/null || sleep 0.1
			done
			(process_file "$file" "$base" "$verify_override") &
		else
			process_file "$file" "$base" "$verify_override"
		fi
	done < <(find "$base" \( -path "$base/$CHECKSUM_DIR" -o -name ".abpartial" \) -prune -o -type f -print0)

	if [[ "$max_jobs" -gt 1 ]]; then wait; fi
	set_status "Idle"
}

# ------------------------------------------------------------------------------
# --status one-shot snapshot
#
# Read-only report on the state of the watchtower daemon, the scheduler
# history (LAST_RUN_* timestamps), running processes (backup, mover), and
# any queued IPC triggers. Designed for `watchtower.sh --status` to be a
# quick "is the daemon healthy?" probe without tailing logs. Takes no
# lock and works whether or not the daemon is running.
# ------------------------------------------------------------------------------

_format_age_days() {
	# Input: YYYYMMDD (the format atomic_write uses for LAST_RUN_* files).
	# Output: a human-readable age like "2 days ago" or "today". Empty
	# input → "never".
	local d="$1"
	if [[ -z "$d" || ! "$d" =~ ^[0-9]{8}$ ]]; then
		echo "never"
		return
	fi
	local t1 t2
	t1=$(date -d "${d:0:4}-${d:4:2}-${d:6:2}" +%s 2>/dev/null) || { echo "$d (unparseable)"; return; }
	t2=$(date +%s)
	local days=$(( (t2 - t1) / 86400 ))
	if ((days <= 0)); then
		echo "${d:0:4}-${d:4:2}-${d:6:2} (today)"
	elif ((days == 1)); then
		echo "${d:0:4}-${d:4:2}-${d:6:2} (1 day ago)"
	else
		echo "${d:0:4}-${d:4:2}-${d:6:2} ($days days ago)"
	fi
}

_format_uptime_from_proc() {
	# Echo a human-readable uptime for a PID using /proc/<pid> mtime
	# as the process-start epoch. Empty on failure.
	local pid="$1"
	[[ -z "$pid" || ! -d "/proc/$pid" ]] && return
	local start now elapsed
	start=$(stat -c %Y "/proc/$pid" 2>/dev/null) || return
	now=$(date +%s)
	elapsed=$((now - start))
	local d=$((elapsed / 86400)) h=$(( (elapsed % 86400) / 3600 )) m=$(( (elapsed % 3600) / 60 ))
	if ((d > 0)); then printf "%dd %02dh %02dm" "$d" "$h" "$m"
	elif ((h > 0)); then printf "%dh %02dm" "$h" "$m"
	else printf "%dm" "$m"; fi
}

cmd_status() {
	local hr="================================================================"
	echo "$hr"
	echo "                       WATCHTOWER STATUS"
	echo "$hr"

	# Daemon presence — DAEMON_RUNNING and DAEMON_PID are populated by
	# the existing block earlier in section 8 (PID file + lockfile probe).
	local daemon_line
	if [[ "$DAEMON_RUNNING" == "true" ]]; then
		if [[ -n "$DAEMON_PID" ]]; then
			local up
			up=$(_format_uptime_from_proc "$DAEMON_PID")
			daemon_line="RUNNING (PID $DAEMON_PID${up:+, up $up})"
		else
			daemon_line="RUNNING (PID unknown — detected via lockfile)"
		fi
	else
		daemon_line="NOT RUNNING"
	fi
	printf "  %-22s %s\n" "Daemon:" "$daemon_line"

	if [[ "$DAEMON_RUNNING" == "true" && -f "$STATUS_FILE" ]]; then
		printf "  %-22s %s\n" "Current state:" "$(tr -d '\r\n' <"$STATUS_FILE" 2>/dev/null || echo unknown)"
	fi
	printf "  %-22s %s\n" "Config:" "$CFG_TO_LOAD"
	printf "  %-22s %s\n" "Host:" "$HOSTNAME_VAR"

	echo ""
	echo "Schedule history:"
	local b c v u r
	b=$(cat "$LAST_RUN_BACKUP"   2>/dev/null || true)
	c=$(cat "$LAST_RUN_CLEANUP"  2>/dev/null || true)
	v=$(cat "$LAST_RUN_VERIFY"   2>/dev/null || true)
	u=$(cat "$LAST_RUN_UPDATE"   2>/dev/null || true)
	r=$(cat "$LAST_RUN_RECOVERY" 2>/dev/null || true)
	printf "  %-22s %s\n" "Last backup:"   "$(_format_age_days "$b")"
	printf "  %-22s %s\n" "Last cleanup:"  "$(_format_age_days "$c")"
	printf "  %-22s %s\n" "Last verify:"   "$(_format_age_days "$v")"
	printf "  %-22s %s\n" "Last update:"   "$(_format_age_days "$u")"
	printf "  %-22s %s\n" "Last recovery:" "$(_format_age_days "$r")"

	echo ""
	echo "Live processes:"
	local backup_state mover_state cache_pct
	if is_backup_running; then backup_state="yes"; else backup_state="no"; fi
	if is_mover_running;  then mover_state="yes";  else mover_state="no";  fi
	cache_pct=$(get_cache_usage 2>/dev/null || echo "n/a")
	printf "  %-22s %s\n" "Backup in progress:" "$backup_state"
	printf "  %-22s %s\n" "Mover in progress:"  "$mover_state"
	if [[ "$cache_pct" != "n/a" ]]; then
		printf "  %-22s %s%%\n" "Cache usage:" "$cache_pct"
	else
		printf "  %-22s %s\n" "Cache usage:" "$cache_pct"
	fi

	echo ""
	echo "Pending IPC triggers:"
	local t
	for t in scan verify cleanup update config force recovery; do
		local var="TRIGGER_${t^^}"
		local path="${!var:-}"
		if [[ -n "$path" && -f "$path" ]]; then
			printf "  %-22s queued\n" "${t}:"
		else
			printf "  %-22s -\n" "${t}:"
		fi
	done

	echo ""
	echo "Logs:"
	printf "  %-22s %s\n" "Daemon log:" "$LOGFILE"
	printf "  %-22s %s\n" "Backup log:" "$BACKUP_LOGFILE"

	echo "$hr"

	# Non-zero exit if the daemon isn't running, so the command is usable
	# in cron / monitoring as "is watchtower alive?".
	[[ "$DAEMON_RUNNING" == "true" ]] || return 1
	return 0
}

# ------------------------------------------------------------------------------
# --ab-graph live full-terminal dashboard
#
# Visualises an in-progress auto-backupper or auto-restorer run as a TUI
# with a phase timeline, CPU/MEM/Disk sparklines, destination usage bar,
# and a live log tail. Pure read-only: nothing is written to disk, logs
# remain the system of record. Designed as an optional easter-egg —
# missing deps warn and exit, no daemon impact.
# ------------------------------------------------------------------------------

# Required binaries for the dashboard. Standard userland on every target
# we've documented (Unraid, Debian, Ubuntu, Arch, OMV), but checked
# explicitly so a stripped-down host surfaces a clear message instead of
# a half-rendered screen.
_ab_graph_check_deps() {
	local missing=()
	local b
	for b in tput ps tail df stat awk; do
		command -v "$b" >/dev/null 2>&1 || missing+=("$b")
	done
	if ((${#missing[@]} > 0)); then
		echo "ERROR: --ab-graph requires: ${missing[*]} (not found in PATH)" >&2
		echo "       This is an optional dashboard; the rest of the suite does not need these." >&2
		return 1
	fi
	return 0
}

# Worker detection. Echoes one of:
#   "backup <PID> <LOGFILE>"     PID may be "unknown" if the pidfile is missing
#   "restore <PID> <LOGFILE>"    PID may be "unknown" if the lockfile is empty
#   "idle"
#
# Detection is driven off the *lockfiles* held with flock — same source
# of truth that --status uses (`is_backup_running` checks the same
# lockfile). The earlier implementation used a /proc/<pid>/cmdline grep
# for "auto-backupper" / "auto-restorer", which broke on case-sensitivity
# (Unraid User Scripts wraps the script with a path like
# `/boot/config/plugins/user.scripts/scripts/Auto-Backupper/script` —
# capital A — and the pid file may also be stale or never-written.
# The lockfile probe is the same approach watchtower already uses for
# its own daemon detection upstream, and it's robust against both
# issues.
#
# The PID file / lockfile contents are consulted *only to display* a
# PID for the dashboard header; on miss we still report the worker as
# running and let the rest of the dashboard degrade gracefully (CPU/MEM
# show 0, uptime shows "unknown", but the phase timeline and log tail
# remain useful).
_ab_graph_detect_worker() {
	# auto-backupper: reuse is_backup_running (lockfile probe).
	if is_backup_running; then
		local pid=""
		if [[ -f "$BACKUP_PIDFILE" ]]; then
			pid=$(cat "$BACKUP_PIDFILE" 2>/dev/null || echo "")
			# Drop a clearly-stale PID (process is dead) so the header
			# doesn't lie. Keep it otherwise — we deliberately don't
			# re-check cmdline; the lockfile probe is authoritative.
			if [[ -n "$pid" ]]; then
				if ! [[ "$pid" =~ ^[0-9]+$ ]] || ! kill -0 "$pid" 2>/dev/null; then
					pid=""
				fi
			fi
		fi
		echo "backup ${pid:-unknown} $BACKUP_LOGFILE"
		return 0
	fi

	# auto-restorer: probe its lockfile the same way.
	local restorer_lock="/var/lock/auto_restorer.lock"
	local restorer_log="/var/log/auto_restorer.log"
	if [[ -f "$restorer_lock" ]]; then
		local probe_fd=""
		if exec {probe_fd}<"$restorer_lock" 2>/dev/null; then
			if flock -n -s "$probe_fd" 2>/dev/null; then
				# Got a shared lock — nobody holds exclusive → not running.
				flock -u "$probe_fd" 2>/dev/null || true
				exec {probe_fd}<&- 2>/dev/null || true
			else
				# Couldn't get shared — exclusive is held → restorer running.
				exec {probe_fd}<&- 2>/dev/null || true
				local pid
				pid=$(cat "$restorer_lock" 2>/dev/null || echo "")
				if [[ -n "$pid" ]]; then
					if ! [[ "$pid" =~ ^[0-9]+$ ]] || ! kill -0 "$pid" 2>/dev/null; then
						pid=""
					fi
				fi
				echo "restore ${pid:-unknown} $restorer_log"
				return 0
			fi
		fi
	fi
	echo "idle"
	return 0
}

# Bytes -> short human form. Local copy (not a shared helper).
_ab_graph_human_bytes() {
	awk -v b="$1" 'BEGIN {
		if      (b >= 1099511627776) printf "%.1fT", b/1099511627776
		else if (b >= 1073741824)    printf "%.1fG", b/1073741824
		else if (b >= 1048576)       printf "%.1fM", b/1048576
		else if (b >= 1024)          printf "%.1fK", b/1024
		else                         printf "%dB", b
	}'
}

# Sparkline renderer. Args: <max> <value...>; emits one block char per
# value scaled to 0..8 against max. Empty input → empty output.
# Uses the standard block-element glyphs (U+2581..U+2588) — these are
# TUI characters, not emojis; they render in every modern terminal.
_ab_graph_sparkline() {
	local max="$1"
	shift
	local glyphs=(' ' $'\xe2\x96\x81' $'\xe2\x96\x82' $'\xe2\x96\x83' $'\xe2\x96\x84' $'\xe2\x96\x85' $'\xe2\x96\x86' $'\xe2\x96\x87' $'\xe2\x96\x88')
	local out="" v idx
	for v in "$@"; do
		if awk -v m="$max" 'BEGIN { exit !(m > 0) }'; then
			idx=$(awk -v v="$v" -v m="$max" 'BEGIN {
				r = (v / m) * 8
				if (r < 0) r = 0
				if (r > 8) r = 8
				printf "%d", r + 0.5
			}')
		else
			idx=0
		fi
		out="${out}${glyphs[$idx]}"
	done
	printf '%s' "$out"
}

# Horizontal proportion bar. Args: <pct 0-100> <width chars>.
# Filled with '#' (ASCII so it lines up cleanly with the percentage).
_ab_graph_draw_bar() {
	local pct="$1" width="$2"
	local filled
	filled=$(awk -v p="$pct" -v w="$width" 'BEGIN {
		if (p < 0) p = 0
		if (p > 100) p = 100
		printf "%d", (p / 100.0) * w + 0.5
	}')
	local empty=$((width - filled))
	local i
	printf '['
	for ((i = 0; i < filled; i++)); do printf '#'; done
	for ((i = 0; i < empty;  i++)); do printf '.'; done
	printf ']'
}

# Phase tracker. Given the worker's log file, returns a sequence of
# "phase|duration_seconds|state" entries delimited by `;` for the
# *current run* (i.e. everything after the last `=== Starting` line).
# `state` is "done" for every phase except the most recent, which is
# "active". An empty result means no phase markers have been logged
# yet — typical at startup before pre-flight finishes.
_ab_graph_phase_history() {
	local logfile="$1" limit="${2:-8}"
	[[ -f "$logfile" && -r "$logfile" ]] || return 0

	# Scan back through the tail for the most recent "=== Starting"
	# marker. We cap at the last 5000 lines so a multi-GB log doesn't
	# get fully slurped each tick.
	local last_start_line tail_snapshot
	tail_snapshot=$(tail -n 5000 "$logfile" 2>/dev/null || true)
	[[ -z "$tail_snapshot" ]] && return 0

	# Trim everything up to and including the latest === Starting line.
	local trimmed
	trimmed=$(awk '
		/=== Starting/ { run_start = NR; lines = "" }
		run_start && NR >= run_start { lines = lines $0 ORS }
		END { printf "%s", lines }
	' <<<"$tail_snapshot")
	[[ -z "$trimmed" ]] && return 0

	# Extract Phase: lines with their ISO-8601 prefix; the script's
	# log() always emits "YYYY-MM-DDTHH:MM:SSZ <msg>" so awk can split
	# on the first space.
	#
	# For each Phase: line, record (ts_epoch, phase_text). Then compute
	# duration as the delta to the next phase (or "now" for the last).
	local now_epoch
	now_epoch=$(date -u +%s)
	# TZ=UTC is required because gawk's mktime() interprets the datespec
	# in the *local* time zone unless TZ tells it otherwise. The string
	# "UTC" tacked onto the datespec is silently ignored by gawk < 5.0
	# and is not the documented mechanism for any version — the only
	# portable approach is the env-var override below.
	TZ=UTC awk -v now="$now_epoch" -v lim="$limit" '
		/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z Phase:/ {
			ts = substr($1, 1, 19) "Z"
			# Convert ISO-8601 to epoch via mktime() — strip dashes/colons
			# and feed the components in mktime format "YYYY MM DD HH MM SS".
			y = substr($1, 1, 4); mo = substr($1, 6, 2); d = substr($1, 9, 2)
			h = substr($1, 12, 2); mi = substr($1, 15, 2); se = substr($1, 18, 2)
			ep = mktime(y " " mo " " d " " h " " mi " " se)
			# Phase text is everything after "Phase:" trimmed of leading space.
			text = $0
			sub(/^[^ ]+ Phase:[ \t]*/, "", text)
			# Truncate verbose phase text for the timeline cell.
			if (length(text) > 38) text = substr(text, 1, 35) "..."
			phases[++n] = text
			epochs[n] = ep
			sev[n] = "ok"
			cur = n
		}
		# Severity scanner: any log line that follows a "Phase:" marker is
		# attributed to that phase. Promote (fail beats warn beats ok); a
		# warning never overwrites a failure within the same phase.
		cur > 0 && /FATAL:|ERROR:/ { sev[cur] = "fail" }
		cur > 0 && /WARN:/ && sev[cur] != "fail" { sev[cur] = "warn" }
		END {
			if (n == 0) exit
			# Keep at most `lim` of the most-recent phase entries so a
			# very long run does not overflow the dashboard rows.
			first = n - lim + 1
			if (first < 1) first = 1
			out = ""
			for (i = first; i <= n; i++) {
				if (i < n) {
					dur = epochs[i+1] - epochs[i]
					state = "done"
				} else {
					dur = now - epochs[i]
					state = "active"
				}
				if (dur < 0) dur = 0
				if (out != "") out = out ";"
				out = out phases[i] "|" dur "|" state "|" sev[i]
			}
			print out
		}
	' <<<"$trimmed"
}

# Shares-progress checklist. Returns a `;`-delimited list of
# "share_name|state" entries, where state is one of:
#   done    — at least one archive for this share appears in the current
#             run's log AND another share has started since.
#   active  — the most recent "Archiving:" line points at this share.
#   pending — no archive has been logged for this share yet.
#
# Output is empty (caller should hide the block) when:
#   - the worker isn't in the Shares Backup phase, OR
#   - SHARES_TO_BACKUP isn't defined in the watchtower's env (the cfg
#     was sourced but the array is absent — typical for hosts whose
#     auto-backupper config doesn't enumerate shares).
#
# Args: <current_phase> <logfile>
_ab_graph_shares_progress() {
	local current_phase="$1" logfile="$2"

	# Only render during the shares-related phases. The auto-backupper
	# emits "Phase: Shares Backup" for the top-level sweep and
	# "Phase: Granular Backup for '<share>'" for domains / iscsi /
	# similar recursive shares. Either qualifies.
	case "$current_phase" in
		"Shares Backup"|"Granular Backup for "*) ;;
		*) return 0 ;;
	esac

	# Require the config to have populated SHARES_TO_BACKUP. The `:-`
	# default makes this safe under set -u even when the array is
	# completely unset.
	[[ -z "${SHARES_TO_BACKUP[*]:-}" ]] && return 0

	# Slice the log to just the current run, then keep only the
	# "Archiving:" lines.
	local archives_seen=""
	if [[ -f "$logfile" && -r "$logfile" ]]; then
		archives_seen=$(tail -n 5000 "$logfile" 2>/dev/null | awk '
			/=== Starting/ { run_start = NR; lines = "" }
			run_start && NR >= run_start { lines = lines $0 ORS }
			END { printf "%s", lines }
		' | grep "Archiving:" || true)
	fi

	# The most-recent Archiving: line tells us the share currently being
	# processed. Path shape:
	#   <BACKUP_BASE>/shares/<SHARE>/[<sub>/]<file>.tar.gz
	local current_share=""
	if [[ -n "$archives_seen" ]]; then
		current_share=$(tail -n 1 <<<"$archives_seen" \
			| grep -oE '/shares/[^/]+/' \
			| head -n 1 \
			| sed 's|^/shares/||;s|/$||' || true)
	fi

	# Build a share -> severity map for the current run. Walk the full
	# trimmed log (NOT just the Archiving: filter — we need every line so
	# WARN/ERROR/FATAL can be attributed). The "current share" rolls
	# forward to whatever appeared in the most recent Archiving: line,
	# and any severity tokens between two Archiving: lines belong to the
	# preceding share. Output is one "share<TAB>sev" row per share that
	# had at least one Archiving: line.
	local sev_map=""
	if [[ -f "$logfile" && -r "$logfile" ]]; then
		sev_map=$(tail -n 5000 "$logfile" 2>/dev/null | awk '
			/=== Starting/ { run_start = NR; cur = "" }
			!run_start { next }
			/Archiving:/ {
				if (match($0, /\/shares\/[^/]+\//)) {
					s = substr($0, RSTART, RLENGTH)
					sub(/^\/shares\//, "", s)
					sub(/\/$/, "", s)
					cur = s
					if (!(cur in sev)) sev[cur] = "ok"
				}
				next
			}
			cur != "" && /FATAL:|ERROR:/ { sev[cur] = "fail" }
			cur != "" && /WARN:/ && sev[cur] != "fail" { sev[cur] = "warn" }
			END { for (k in sev) printf "%s\t%s\n", k, sev[k] }
		' || true)
	fi
	declare -A sev_by_share=()
	if [[ -n "$sev_map" ]]; then
		local _k _v
		while IFS=$'\t' read -r _k _v; do
			[[ -z "$_k" ]] && continue
			sev_by_share["$_k"]="$_v"
		done <<<"$sev_map"
	fi

	# For each expected share, decide its state. A share appearing at
	# least once in archives_seen is "done" — unless it's the current
	# share, in which case it's "active". Anything we never saw is
	# "pending".
	local share state sev out=""
	for share in "${SHARES_TO_BACKUP[@]}"; do
		if [[ "$share" == "$current_share" ]]; then
			state="active"
		elif grep -q "/shares/${share}/" <<<"$archives_seen"; then
			state="done"
		else
			state="pending"
		fi
		sev="${sev_by_share[$share]:-ok}"
		[[ -n "$out" ]] && out="${out};"
		out="${out}${share}|${state}|${sev}"
	done
	echo "$out"
}

# Format seconds → HH:MM:SS (or MM:SS if < 1h).
_ab_graph_fmt_dur() {
	local s="${1:-0}"
	[[ "$s" =~ ^[0-9]+$ ]] || s=0
	local h=$((s / 3600)) m=$(((s % 3600) / 60)) sec=$((s % 60))
	if ((h > 0)); then
		printf "%02d:%02d:%02d" "$h" "$m" "$sec"
	else
		printf "%02d:%02d" "$m" "$sec"
	fi
}

# Read CPU% (lifetime average from ps; cheap and portable — top -bn1
# would be more accurate but adds a 1-second blocking sample per tick)
# and RSS in KB. Echoes "<cpu> <rss_kb>"; "0 0" on failure.
_ab_graph_proc_stats() {
	local pid="$1"
	[[ "$pid" =~ ^[0-9]+$ ]] || { echo "0 0"; return; }
	local out
	out=$(ps -o %cpu=,rss= -p "$pid" 2>/dev/null | awk '{printf "%s %s", $1+0, $2+0}')
	[[ -z "$out" ]] && out="0 0"
	echo "$out"
}

# Most recent "Archiving:" or "Extracting" line from the log, trimmed.
# Empty when no archive is currently active. Limits to 800 lines tail
# so this is cheap to call every tick.
_ab_graph_current_archive() {
	local logfile="$1"
	[[ -f "$logfile" && -r "$logfile" ]] || return 0
	tail -n 800 "$logfile" 2>/dev/null | awk '
		/Archiving:|Extracting / { line = $0 }
		END { if (line) print line }
	'
}

# Last N log lines, trimmed of the timestamp prefix to save horizontal
# space. Each line is echoed on its own.
_ab_graph_recent_log() {
	local logfile="$1" n="${2:-4}"
	[[ -f "$logfile" && -r "$logfile" ]] || return 0
	tail -n "$n" "$logfile" 2>/dev/null | awk '{
		# Drop the ISO-8601 timestamp prefix when present.
		if ($1 ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}T/) {
			ts = substr($1, 12, 8)   # HH:MM:SS portion
			$1 = ""
			sub(/^ /, "", $0)
			print ts "  " $0
		} else {
			print $0
		}
	}'
}

# Pick the busiest non-loopback interface based on cumulative RX+TX
# bytes in /proc/net/dev. Cumulative-since-boot is dominated by the
# interface carrying backup/restore traffic on a typical NAS, so this
# is stable enough to use once at startup. Echoes the name or empty if
# no candidate interface exists.
_ab_graph_pick_iface() {
	[[ -r /proc/net/dev ]] || return 0
	awk '
		NR > 2 {
			name = $1
			sub(/:$/, "", name)
			if (name == "lo" || name == "") next
			# /proc/net/dev columns:
			# iface: rx_bytes rx_pkts ... (col 2..) ... tx_bytes (col 10) ...
			# After stripping the colon-suffixed name, $2 is rx_bytes,
			# $10 is tx_bytes.
			total = $2 + $10
			if (total > best) { best = total; pick = name }
		}
		END { if (pick) print pick }
	' /proc/net/dev
}

# Current cumulative RX/TX bytes for an interface. Echoes "<rx> <tx>";
# "0 0" on missing interface so the rate calc just produces zero deltas.
_ab_graph_iface_bytes() {
	local iface="$1"
	[[ -z "$iface" || ! -r /proc/net/dev ]] && { echo "0 0"; return; }
	awk -v want="$iface" '
		NR > 2 {
			name = $1
			sub(/:$/, "", name)
			if (name == want) { printf "%s %s", $2, $10; found=1; exit }
		}
		END { if (!found) printf "0 0" }
	' /proc/net/dev
}

# Link speed (Mbps) for an interface, formatted as "1G", "10G", "100M",
# or "unknown". /sys/class/net/<iface>/speed returns -1 on devices that
# can't report it (down, virtual, etc.).
_ab_graph_iface_speed() {
	local iface="$1"
	local sys="/sys/class/net/${iface}/speed"
	[[ -r "$sys" ]] || { echo "unknown"; return; }
	local mbps
	mbps=$(cat "$sys" 2>/dev/null || echo -1)
	[[ "$mbps" =~ ^-?[0-9]+$ ]] || { echo "unknown"; return; }
	((mbps <= 0)) && { echo "unknown"; return; }
	if ((mbps >= 1000)); then
		# Whole-number Gbps when possible (1000 -> "1G", 25000 -> "25G").
		if ((mbps % 1000 == 0)); then
			printf "%dG" $((mbps / 1000))
		else
			awk -v m="$mbps" 'BEGIN { printf "%.1fG", m/1000 }'
		fi
	else
		printf "%dM" "$mbps"
	fi
}

# TSO offload counters from ethtool -S. Returns "<tx_tso_bytes>
# <tx_total_bytes> <counter_name>" or empty when ethtool is missing,
# the driver lacks counters, or no recognised TSO field is present.
# Counter names vary by driver — we probe the common variants:
#   tx_tso_bytes / tx_tcp_seg_good (bytes, preferred)
#   tx_tso_packets / tso_packets   (packet count, fallback)
# The total side uses tx_bytes / tx_packets respectively. Drivers that
# expose neither simply degrade to "n/a" in the dashboard.
_ab_graph_offload_stats() {
	local iface="$1"
	[[ -z "$iface" ]] && return 0
	command -v ethtool >/dev/null 2>&1 || return 0
	local raw
	raw=$(ethtool -S "$iface" 2>/dev/null) || return 0
	[[ -z "$raw" ]] && return 0

	# Prefer byte counters when present (more meaningful than packet
	# counts because TSO packets are larger than non-TSO).
	local tso_bytes tx_bytes
	tso_bytes=$(awk -F: '
		/^[[:space:]]*(tx_tso_bytes|tx_tcp_seg_good_bytes)[[:space:]]*:/ {
			gsub(/[[:space:]]/, "", $2); print $2; exit
		}' <<<"$raw")
	tx_bytes=$(awk -F: '
		/^[[:space:]]*tx_bytes[[:space:]]*:/ {
			gsub(/[[:space:]]/, "", $2); print $2; exit
		}' <<<"$raw")
	if [[ -n "$tso_bytes" && -n "$tx_bytes" && "$tso_bytes" =~ ^[0-9]+$ && "$tx_bytes" =~ ^[0-9]+$ ]]; then
		echo "$tso_bytes $tx_bytes tx_tso_bytes"
		return 0
	fi

	# Packet-count fallback.
	local tso_pkts tx_pkts
	tso_pkts=$(awk -F: '
		/^[[:space:]]*(tx_tso_packets|tso_packets|tx_tcp_seg_good)[[:space:]]*:/ {
			gsub(/[[:space:]]/, "", $2); print $2; exit
		}' <<<"$raw")
	tx_pkts=$(awk -F: '
		/^[[:space:]]*tx_packets[[:space:]]*:/ {
			gsub(/[[:space:]]/, "", $2); print $2; exit
		}' <<<"$raw")
	if [[ -n "$tso_pkts" && -n "$tx_pkts" && "$tso_pkts" =~ ^[0-9]+$ && "$tx_pkts" =~ ^[0-9]+$ ]]; then
		echo "$tso_pkts $tx_pkts tx_tso_packets"
		return 0
	fi
	return 0
}

# df data for BACKUP_BASE. Echoes "<used_bytes> <total_bytes> <pct>".
_ab_graph_df() {
	local path="${BACKUP_BASE:-/}"
	[[ -d "$path" ]] || { echo "0 0 0"; return; }
	df -B1 --output=used,size,pcent "$path" 2>/dev/null | awk 'NR==2 {
		gsub(/%/, "", $3)
		printf "%s %s %s", $1, $2, $3+0
	}'
}

cmd_ab_graph() {
	if ! _ab_graph_check_deps; then
		return 1
	fi

	local detection worker pid logfile
	detection=$(_ab_graph_detect_worker)
	worker=$(awk '{print $1}' <<<"$detection")

	if [[ "$worker" == "idle" ]]; then
		echo "WARN: Neither auto-backupper nor auto-restorer is currently running."
		echo "      The --ab-graph dashboard is only useful during an active run."
		echo "      Showing one-shot --status snapshot instead:"
		echo ""
		cmd_status
		# Match --status exit semantics (0 if daemon up, 1 otherwise) so a
		# user piping `--ab-graph; do_something` keeps consistent behaviour.
		return $?
	fi

	pid=$(awk '{print $2}' <<<"$detection")
	logfile=$(awk '{print $3}' <<<"$detection")

	# Refresh interval — config-driven, default 1s. Validate strictly:
	# anything non-numeric or <1 reverts to 1 with a one-line notice
	# before the dashboard takes over the screen.
	local refresh="${WATCHTOWER_GRAPH_REFRESH:-1}"
	if ! [[ "$refresh" =~ ^[0-9]+$ ]] || ((refresh < 1)); then
		echo "WARN: WATCHTOWER_GRAPH_REFRESH='$refresh' is not a positive integer; using 1."
		sleep 1
		refresh=1
	fi

	# Relax strict-mode for the rendering loop. The outer script runs under
	# `set -Eeuo pipefail` which is correct for the daemon path; the
	# dashboard samples flaky shell pipelines (ps, df, tail on a rotating
	# log) and a single transient failure must not crash the UI.
	set +e
	trap - ERR

	# Cursor + terminal restore on exit. SIGINT (Ctrl-C) lands here too.
	local _civis_set=0
	if tput civis 2>/dev/null; then _civis_set=1; fi
	_ab_graph_restore() {
		[[ "$_civis_set" == "1" ]] && tput cnorm 2>/dev/null || true
		clear 2>/dev/null || true
	}
	trap '_ab_graph_restore; exit 0' INT TERM
	trap '_ab_graph_restore' EXIT

	# Sample windows. 60 samples × refresh seconds = 60s of history when
	# refresh=1, 5 minutes when refresh=5, etc. Plenty for visual cues.
	local hist_window=60
	local -a cpu_hist=() mem_hist=() write_hist=() rx_hist=() tx_hist=()
	local prev_avail=""

	# Heartbeat spinner frames for the active phase/share. The horizontal
	# stroke is U+2500 (BOX DRAWINGS LIGHT HORIZONTAL) — visually matches
	# the width of \, |, /. Array form is required because the multi-byte
	# stroke would be sliced by bash's byte-indexed ${var:i:1}. Tick
	# advances once per refresh, so the apparent rate scales with
	# WATCHTOWER_GRAPH_REFRESH.
	local -a spin_frames=('─' '\' '|' '/')
	local spin_tick=0
	# Network sample state. iface is picked once at startup (sticky) so
	# the dashboard doesn't flip between adapters when traffic shifts.
	local iface iface_speed=""
	iface=$(_ab_graph_pick_iface)
	[[ -n "$iface" ]] && iface_speed=$(_ab_graph_iface_speed "$iface")
	local prev_rx="" prev_tx=""
	# Offload deltas — we report the offload ratio over each interval,
	# not lifetime, so the value reflects the work the NIC is doing
	# right now during the active backup/restore.
	local prev_tso="" prev_tx_total="" offload_counter=""

	while true; do
		# Re-detect each tick so the screen blanks out cleanly once the
		# worker exits (instead of hanging on a dead PID forever).
		detection=$(_ab_graph_detect_worker)
		worker=$(awk '{print $1}' <<<"$detection")
		if [[ "$worker" == "idle" ]]; then
			# Disarm the EXIT trap first: it also runs _ab_graph_restore (which
			# clears the screen) and would wipe the snapshot printed below when
			# this function returns and the dispatcher exits.
			trap - EXIT
			_ab_graph_restore
			echo ""
			echo "Worker exited; --ab-graph stopping. Final snapshot:"
			echo ""
			cmd_status
			return 0
		fi
		pid=$(awk '{print $2}' <<<"$detection")
		logfile=$(awk '{print $3}' <<<"$detection")

		# Sample process + disk metrics.
		local proc_line cpu mem_kb avail_bytes df_used df_total df_pct write_bps
		proc_line=$(_ab_graph_proc_stats "$pid")
		cpu=$(awk '{print $1}' <<<"$proc_line")
		mem_kb=$(awk '{print $2}' <<<"$proc_line")
		local df_line
		df_line=$(_ab_graph_df)
		df_used=$(awk '{print $1}' <<<"$df_line")
		df_total=$(awk '{print $2}' <<<"$df_line")
		df_pct=$(awk '{print $3}' <<<"$df_line")
		# Write rate via avail-bytes delta. Negative deltas mean backup is
		# writing; positive means rotation/cleanup is freeing. We graph
		# absolute writes (delta < 0 → bytes_written = -delta / refresh).
		avail_bytes=$(awk -v u="$df_used" -v t="$df_total" 'BEGIN {print t - u}')
		write_bps=0
		if [[ -n "$prev_avail" && "$avail_bytes" =~ ^-?[0-9]+$ && "$prev_avail" =~ ^-?[0-9]+$ ]]; then
			# bytes consumed since last tick = prev_avail - avail
			local delta=$((prev_avail - avail_bytes))
			((delta < 0)) && delta=0
			write_bps=$((delta / refresh))
		fi
		prev_avail="$avail_bytes"

		# Network: cumulative counter deltas from /proc/net/dev. Skipped
		# if no interface was detected at startup; the network block
		# below still renders a one-line "n/a" so the user knows why.
		local rx_bps=0 tx_bps=0 cur_rx="" cur_tx=""
		if [[ -n "$iface" ]]; then
			local iface_line
			iface_line=$(_ab_graph_iface_bytes "$iface")
			cur_rx=$(awk '{print $1}' <<<"$iface_line")
			cur_tx=$(awk '{print $2}' <<<"$iface_line")
			if [[ -n "$prev_rx" && "$cur_rx" =~ ^[0-9]+$ && "$prev_rx" =~ ^[0-9]+$ ]]; then
				local d=$((cur_rx - prev_rx))
				((d < 0)) && d=0   # counter wrap on 32-bit kernels
				rx_bps=$((d / refresh))
			fi
			if [[ -n "$prev_tx" && "$cur_tx" =~ ^[0-9]+$ && "$prev_tx" =~ ^[0-9]+$ ]]; then
				local d=$((cur_tx - prev_tx))
				((d < 0)) && d=0
				tx_bps=$((d / refresh))
			fi
			prev_rx="$cur_rx"
			prev_tx="$cur_tx"
		fi

		# Push to ring buffers.
		cpu_hist+=("$cpu")
		mem_hist+=("$mem_kb")
		write_hist+=("$write_bps")
		rx_hist+=("$rx_bps")
		tx_hist+=("$tx_bps")
		((${#cpu_hist[@]}   > hist_window)) && cpu_hist=("${cpu_hist[@]:1}")
		((${#mem_hist[@]}   > hist_window)) && mem_hist=("${mem_hist[@]:1}")
		((${#write_hist[@]} > hist_window)) && write_hist=("${write_hist[@]:1}")
		((${#rx_hist[@]}    > hist_window)) && rx_hist=("${rx_hist[@]:1}")
		((${#tx_hist[@]}    > hist_window)) && tx_hist=("${tx_hist[@]:1}")

		# Max for sparkline normalisation. mem max = process current
		# RSS ceiling so the line scales sensibly even on tiny RSS;
		# write/rx/tx use simple max of the visible history.
		local cpu_max=100 mem_max=0 write_max=0 rx_max=0 tx_max=0 v
		for v in "${mem_hist[@]}"; do (( v > mem_max )) && mem_max=$v; done
		for v in "${write_hist[@]}"; do (( v > write_max )) && write_max=$v; done
		for v in "${rx_hist[@]}"; do (( v > rx_max )) && rx_max=$v; done
		for v in "${tx_hist[@]}"; do (( v > tx_max )) && tx_max=$v; done
		((mem_max == 0)) && mem_max=1
		((write_max == 0)) && write_max=1
		((rx_max == 0)) && rx_max=1
		((tx_max == 0)) && tx_max=1

		# Offload ratio: delta of TSO counter vs delta of total TX over
		# the current interval. The row is rendered ONLY when the
		# system actually exposes usable counters — on hosts without
		# ethtool, or with NICs whose driver doesn't surface TSO stats,
		# the offload row is hidden entirely (no "n/a" clutter). Set
		# offload_available=true only when we got a parseable line from
		# _ab_graph_offload_stats; the render block below keys off that.
		local offload_label="" offload_available=false
		if [[ -n "$iface" ]]; then
			local off_line
			off_line=$(_ab_graph_offload_stats "$iface")
			if [[ -n "$off_line" ]]; then
				offload_available=true
				local cur_tso cur_total cur_name
				cur_tso=$(awk '{print $1}' <<<"$off_line")
				cur_total=$(awk '{print $2}' <<<"$off_line")
				cur_name=$(awk '{print $3}' <<<"$off_line")
				offload_counter="$cur_name"
				if [[ -n "$prev_tso" && -n "$prev_tx_total" \
					&& "$cur_tso" =~ ^[0-9]+$ && "$cur_total" =~ ^[0-9]+$ ]]; then
					local d_tso=$((cur_tso - prev_tso))
					local d_total=$((cur_total - prev_tx_total))
					((d_tso < 0)) && d_tso=0
					((d_total < 0)) && d_total=0
					if ((d_total > 0)); then
						local offload_pct
						offload_pct=$(awk -v t="$d_tso" -v tot="$d_total" 'BEGIN {
							r = (t / tot) * 100
							if (r < 0) r = 0
							if (r > 100) r = 100
							printf "%d", r + 0.5
						}')
						offload_label="${offload_pct}% (${offload_counter})"
					else
						offload_label="idle (${offload_counter})"
					fi
				else
					offload_label="warming up (${offload_counter})"
				fi
				prev_tso="$cur_tso"
				prev_tx_total="$cur_total"
			fi
		fi

		# Render.
		local cols
		cols=$(tput cols 2>/dev/null || echo 80)
		((cols < 60)) && cols=60

		tput home 2>/dev/null
		# Helper to print a line padded/truncated to width so any stale
		# trailing chars from a previous, longer line are wiped.
		local _row="" _w
		_emit() {
			_row="$1"
			# Strip ANSI for length, but here we use no colour codes so
			# raw byte length is fine.
			_w=${#_row}
			if ((_w > cols)); then
				_row="${_row:0:cols}"
				_w=$cols
			fi
			# Pad with spaces to cols, then newline. Avoids printf %-N
			# which counts bytes (UTF-8 sparkline chars are 3 bytes each
			# and would mis-pad).
			printf '%s' "$_row"
			local _spaces=$((cols - _w))
			while ((_spaces-- > 0)); do printf ' '; done
			printf '\n'
		}

		# Title bar.
		local now_hms
		now_hms=$(date +%H:%M:%S)
		_emit "=== AB-GRAPH ===  worker=${worker}  PID=${pid}  refresh=${refresh}s  ${now_hms}"

		# Worker line + config.
		local uptime
		uptime=$(_format_uptime_from_proc "$pid")
		[[ -z "$uptime" ]] && uptime="unknown"
		_emit "  Up: ${uptime}    Host: ${HOSTNAME_VAR}    Config: ${CFG_TO_LOAD}"
		_emit ""

		# Advance the heartbeat frame once per refresh. Computed before the
		# phase/share blocks so both render with the same frame this tick.
		local spin_char="${spin_frames[$((spin_tick % 4))]}"
		spin_tick=$((spin_tick + 1))

		# Phase timeline (up to 6 most recent).
		_emit "PHASES (current run):"
		local phases_csv phase rec active_phase=""
		phases_csv=$(_ab_graph_phase_history "$logfile" 6)
		if [[ -z "$phases_csv" ]]; then
			_emit "  (no Phase: markers yet — worker may be in pre-flight or just-started)"
		else
			local IFS_SAVE="$IFS"
			IFS=';'
			# shellcheck disable=SC2206
			local entries=($phases_csv)
			IFS="$IFS_SAVE"
			for rec in "${entries[@]}"; do
				local p_text p_dur p_state p_sev marker
				p_text="${rec%%|*}"; rec="${rec#*|}"
				p_dur="${rec%%|*}"; rec="${rec#*|}"
				p_state="${rec%%|*}"; rec="${rec#*|}"
				p_sev="${rec}"
				if [[ "$p_state" == "active" ]]; then
					marker="[${spin_char}]"
					active_phase="$p_text"
				else
					case "$p_sev" in
						fail) marker="[x]" ;;
						warn) marker="[!]" ;;
						*)    marker="[✓]" ;;
					esac
				fi
				_emit "  ${marker} $(printf '%-38s' "$p_text")  $(_ab_graph_fmt_dur "$p_dur") ${p_state}"
			done
		fi
		_emit ""

		# Shares progress sub-block. Only renders during the shares
		# phase — the helper returns empty for every other phase, and
		# the block stays hidden so non-shares phases keep the
		# dashboard compact. Cap visible rows at 10 so a host with a
		# long SHARES_TO_BACKUP list can't overflow other blocks.
		local shares_csv
		shares_csv=$(_ab_graph_shares_progress "$active_phase" "$logfile")
		if [[ -n "$shares_csv" ]]; then
			IFS_SAVE="$IFS"
			IFS=';'
			# shellcheck disable=SC2206
			local share_entries=($shares_csv)
			IFS="$IFS_SAVE"
			local total=${#share_entries[@]}
			# Records are now "name|state|sev" — middle field is state.
			# Use a parameter-expansion peel rather than ${rec##*|} so we
			# read state (not sev) on the count pass.
			local done_count=0 sh_name sh_state sh_sev sh_rest sh_marker
			for rec in "${share_entries[@]}"; do
				sh_rest="${rec#*|}"
				sh_state="${sh_rest%%|*}"
				[[ "$sh_state" == "done" ]] && done_count=$((done_count + 1))
			done
			_emit "SHARES (${done_count}/${total} done):"
			local shown=0 limit=10 pending_skipped=0
			for rec in "${share_entries[@]}"; do
				sh_name="${rec%%|*}"
				sh_rest="${rec#*|}"
				sh_state="${sh_rest%%|*}"
				sh_sev="${sh_rest#*|}"
				if ((shown >= limit && sh_state == "pending")); then
					pending_skipped=$((pending_skipped + 1))
					continue
				fi
				case "$sh_state" in
					active)  sh_marker="[${spin_char}]" ;;
					pending) sh_marker="[ ]" ;;
					done)
						case "$sh_sev" in
							fail) sh_marker="[x]" ;;
							warn) sh_marker="[!]" ;;
							*)    sh_marker="[✓]" ;;
						esac
						;;
				esac
				_emit "  ${sh_marker} ${sh_name}"
				shown=$((shown + 1))
			done
			if ((pending_skipped > 0)); then
				_emit "  ... and ${pending_skipped} more pending"
			fi
			_emit ""
		fi

		# Current archive line.
		local current_arc
		current_arc=$(_ab_graph_current_archive "$logfile")
		if [[ -n "$current_arc" ]]; then
			# Drop the ISO timestamp prefix for compactness; keep the rest.
			_emit "CURRENT: ${current_arc#* }"
		else
			_emit "CURRENT: (no active archive yet)"
		fi
		_emit ""

		# Metrics block.
		local cpu_spark mem_spark write_spark mem_h write_h
		cpu_spark=$(_ab_graph_sparkline "$cpu_max" "${cpu_hist[@]}")
		mem_spark=$(_ab_graph_sparkline "$mem_max" "${mem_hist[@]}")
		write_spark=$(_ab_graph_sparkline "$write_max" "${write_hist[@]}")
		mem_h=$(_ab_graph_human_bytes $((mem_kb * 1024)))
		write_h=$(_ab_graph_human_bytes "$write_bps")
		_emit "PROCESS:"
		_emit "  CPU    ${cpu_spark}  ${cpu}%"
		_emit "  MEM    ${mem_spark}  ${mem_h}"
		_emit "  WRITE  ${write_spark}  ${write_h}/s"
		_emit ""

		# Network block. Renders even when iface is empty so the user
		# sees why ("n/a (no active interface)").
		local rx_spark="" tx_spark="" rx_h="0B" tx_h="0B"
		if [[ -n "$iface" ]]; then
			rx_spark=$(_ab_graph_sparkline "$rx_max" "${rx_hist[@]}")
			tx_spark=$(_ab_graph_sparkline "$tx_max" "${tx_hist[@]}")
			rx_h=$(_ab_graph_human_bytes "$rx_bps")
			tx_h=$(_ab_graph_human_bytes "$tx_bps")
		fi
		if [[ -n "$iface" ]]; then
			_emit "NETWORK (${iface}, link ${iface_speed:-unknown}):"
			_emit "  RX     ${rx_spark}  ${rx_h}/s"
			_emit "  TX     ${tx_spark}  ${tx_h}/s"
			# Hide offload entirely on hardware/configs that don't
			# expose TSO counters — keeps the UI clean on consumer
			# NICs and hosts without ethtool.
			[[ "$offload_available" == "true" ]] && _emit "  Offload (TX): ${offload_label}"
		else
			_emit "NETWORK: (no usable interface detected)"
		fi
		_emit ""

		# Destination disk bar.
		local bar_w=$((cols - 30))
		((bar_w < 10)) && bar_w=10
		local bar
		bar=$(_ab_graph_draw_bar "$df_pct" "$bar_w")
		local used_h total_h
		used_h=$(_ab_graph_human_bytes "$df_used")
		total_h=$(_ab_graph_human_bytes "$df_total")
		_emit "DEST: ${BACKUP_BASE:-/} — ${df_pct}% (${used_h} / ${total_h})"
		_emit "  ${bar}"
		_emit ""

		# Recent log tail.
		_emit "RECENT LOG:"
		local log_line
		while IFS= read -r log_line; do
			_emit "  ${log_line}"
		done < <(_ab_graph_recent_log "$logfile" 4)

		_emit ""
		_emit "[q] quit                                                 refresh ${refresh}s"

		# Clear any old rows below where we just rendered.
		tput ed 2>/dev/null || true

		# Block for refresh seconds OR until user keypress. `read -t` only
		# blocks on a real terminal; with stdin not a TTY (a pipe, redirect, or
		# </dev/null) it returns instantly, which would busy-spin this loop at
		# full CPU — so pace with a plain sleep when stdin isn't interactive.
		local key
		if [[ -t 0 ]]; then
			if read -r -t "$refresh" -n 1 -s key; then
				if [[ "$key" == "q" || "$key" == "Q" ]]; then
					break
				fi
			fi
		else
			sleep "$refresh"
		fi
	done

	# Trap will restore cursor and clear screen on the way out.
	return 0
}

# ------------------------------------------------------------------------------
# --hub command center
#
# Persistent menu-driven TUI that overseers the entire suite. Header shows
# live state; single-key shortcuts trigger watchtower IPC actions, kick
# off auto-backupper runs, or open read-only restorer views. Sub-views
# (live graph, live logs, status) are run as child processes so their
# own SIGINT / cursor traps don't disturb the hub itself.
# ------------------------------------------------------------------------------

# Re-detect daemon state. Lighter twin of the daemon-detection block at
# the top of section 8 — the hub needs fresh state every header tick
# because the daemon could start/stop externally during a session.
_hub_redetect_daemon() {
	DAEMON_RUNNING=false
	DAEMON_PID=""
	if [[ -f "$PID_FILE" ]]; then
		local p
		p=$(cat "$PID_FILE" 2>/dev/null)
		if [[ "$p" =~ ^[0-9]+$ ]] && kill -0 "$p" 2>/dev/null; then
			if [[ -r "/proc/$p/cmdline" ]] && tr '\0' ' ' <"/proc/$p/cmdline" 2>/dev/null | grep -qi 'watchtower'; then
				DAEMON_RUNNING=true
				DAEMON_PID="$p"
			fi
		fi
	fi
	# Lockfile fallback: same flock-probe pattern the top-level detector uses.
	if [[ "$DAEMON_RUNNING" == "false" && -e "$WATCHTOWER_LOCK" ]]; then
		local fd=""
		if exec {fd}<"$WATCHTOWER_LOCK" 2>/dev/null; then
			if flock -n -s "$fd" 2>/dev/null; then
				flock -u "$fd" 2>/dev/null || true
			else
				DAEMON_RUNNING=true
			fi
			exec {fd}<&- 2>/dev/null || true
		fi
	fi
}

# Resolve auto-restorer.sh. Honours MAIN_RESTORER_SCRIPT from the config
# when set; otherwise probes the usual install locations relative to
# MAIN_BACKUP_SCRIPT. Echoes the path; non-zero exit when none found.
_hub_find_restorer() {
	if [[ -n "${MAIN_RESTORER_SCRIPT:-}" ]]; then
		[[ -r "$MAIN_RESTORER_SCRIPT" ]] && { echo "$MAIN_RESTORER_SCRIPT"; return 0; }
		return 1
	fi
	[[ -n "${MAIN_BACKUP_SCRIPT:-}" ]] || return 1
	local bp gp
	bp=$(dirname "$MAIN_BACKUP_SCRIPT")
	gp=$(dirname "$bp")
	local c
	for c in \
		"${gp}/Auto-Restorer/script" \
		"${gp}/auto-restorer/script" \
		"${gp}/Auto-Restorer/auto-restorer.sh" \
		"${bp}/auto-restorer.sh" \
		"${gp}/auto-restorer.sh" \
		"/usr/local/bin/auto-restorer.sh" \
		"/usr/local/sbin/auto-restorer.sh"; do
		[[ -r "$c" ]] && { echo "$c"; return 0; }
	done
	return 1
}

# Cursor / screen lifecycle helpers — paired so any sub-view that
# manages its own terminal can leave a clean slate before/after.
_hub_term_init() {
	tput civis 2>/dev/null || true
	clear 2>/dev/null || true
}
_hub_term_restore() {
	tput cnorm 2>/dev/null || true
	clear 2>/dev/null || true
}

# Flag toggled while a sub-view holds the screen. The hub's INT trap
# checks it so Ctrl+C inside a sub-view returns to the hub instead of
# killing the whole session. Without this, Ctrl+C during `tail -F` (in
# the logs sub-view) would tear down the hub on the same signal.
_HUB_IN_SUBVIEW=0
_hub_int_handler() {
	if ((_HUB_IN_SUBVIEW == 1)); then
		# A sub-view is in charge of the screen — let its own trap run.
		return 0
	fi
	_hub_term_restore
	exit 0
}

# Bottom-of-screen ephemeral notice. Auto-clears on the next render
# tick (1-2 seconds later) so the user sees it without blocking.
_hub_notice() {
	local lines
	lines=$(tput lines 2>/dev/null || echo 24)
	tput cup $((lines - 2)) 0 2>/dev/null
	tput el 2>/dev/null
	printf "  >> %s" "$1"
	sleep 2
}

# Bottom-of-screen [y/N] confirmation. Returns 0 on y/Y, 1 otherwise.
_hub_confirm() {
	local lines
	lines=$(tput lines 2>/dev/null || echo 24)
	tput cup $((lines - 2)) 0 2>/dev/null
	tput el 2>/dev/null
	printf "  ?? %s [y/N]: " "$1"
	tput cnorm 2>/dev/null
	local ans=""
	read -n 1 -r ans
	tput civis 2>/dev/null
	[[ "$ans" == "y" || "$ans" == "Y" ]]
}

# Bottom-of-screen free-text prompt. Echoes the entered value on stdout.
_hub_prompt() {
	local lines
	lines=$(tput lines 2>/dev/null || echo 24)
	# Every tput here must reach the terminal (fd2), not stdout: this function
	# returns the typed value via `$(_hub_prompt ...)`, so escape bytes on
	# stdout would corrupt the captured path and defeat the empty-input cancel
	# check. Order `>&2 2>/dev/null` keeps fd1 on the terminal (a copy of fd2
	# taken before fd2 is silenced) while still suppressing tput's own errors.
	tput cup $((lines - 2)) 0 >&2 2>/dev/null
	tput el >&2 2>/dev/null
	printf "  %s: " "$1" >&2
	tput cnorm >&2 2>/dev/null
	local input=""
	read -r input
	tput civis >&2 2>/dev/null
	printf '%s' "$input"
}

# "Press any key" pause used after sub-commands that print and exit.
_hub_pause() {
	echo ""
	echo "Press any key to return to hub..."
	read -n 1 -s -r
}

# Start the watchtower daemon by re-execing this script with --monitor
# via nohup so it survives the hub session. Brief settle delay so the
# daemon has time to write its PID file before the next header tick
# would otherwise still show "NOT RUNNING".
_hub_daemon_start_inner() {
	if [[ "$DAEMON_RUNNING" == "true" ]]; then
		_hub_notice "Daemon is already running (PID ${DAEMON_PID:-unknown})."
		return 1
	fi
	# nohup + & + redirect to /dev/null detaches the child fully. The
	# daemon's own EXIT trap manages PID file cleanup; nothing for us
	# to do beyond launching.
	# Pass the active config to the re-exec'd daemon. Without it the daemon
	# falls back to DEFAULT_CONFIG_FILE, so a hub launched against a custom
	# --config would silently spawn a daemon monitoring the WRONG WATCH_DIR /
	# schedules / thresholds. Every other launch site already passes it.
	nohup bash "$0" "--config=$CFG_TO_LOAD" --monitor >/dev/null 2>&1 &
	local launched_pid=$!
	# Disown so the hub doesn't track it as a job (otherwise quitting
	# the hub could trigger SIGHUP-style cleanup attempts on the daemon).
	disown "$launched_pid" 2>/dev/null || true
	# Wait briefly for the daemon to write its PID file. 2 seconds is
	# generous for an empty config-load path; a fully-loaded daemon
	# might need a touch more, which the next header redraw catches.
	sleep 2
	_hub_redetect_daemon
	if [[ "$DAEMON_RUNNING" == "true" ]]; then
		_hub_notice "Daemon started (PID $DAEMON_PID)."
	else
		_hub_notice "Daemon spawn issued (child PID $launched_pid); state will refresh shortly."
	fi
	return 0
}

# Stop the watchtower daemon. SIGTERM first, give the daemon's EXIT trap up to
# DAEMON_SHUTDOWN_GRACE + 5 seconds (default 35) to clean up — it removes PID +
# STATUS files and shepherds any in-flight docker update/recovery to a safe
# point — then escalate to SIGKILL if needed.
_hub_daemon_stop_inner() {
	if [[ "$DAEMON_RUNNING" != "true" ]]; then
		_hub_notice "Daemon is not running."
		return 1
	fi
	local pid="$DAEMON_PID"
	if [[ -z "$pid" ]]; then
		# Daemon was detected via the lockfile-fallback path (PID file
		# missing or unreadable). We can't signal it cleanly. Tell the
		# user rather than guessing — they can kill manually if needed.
		_hub_notice "Daemon detected via lockfile (PID unknown). Cannot signal — kill manually."
		return 1
	fi
	kill -TERM "$pid" 2>/dev/null || true
	# Wait at least as long as the daemon's own graceful-shutdown grace before
	# escalating to SIGKILL. A hardcoded 5s would SIGKILL it mid docker
	# update/recovery, orphaning a container the 30s grace exists to protect.
	local _grace="${DAEMON_SHUTDOWN_GRACE:-30}"
	[[ "$_grace" =~ ^[0-9]+$ ]] || _grace=30
	local _budget=$((_grace + 5))
	local waited=0
	while kill -0 "$pid" 2>/dev/null && ((waited < _budget)); do
		sleep 1
		waited=$((waited + 1))
	done
	if kill -0 "$pid" 2>/dev/null; then
		kill -KILL "$pid" 2>/dev/null || true
		_hub_notice "Daemon SIGKILLed (didn't exit cleanly after ${_budget}s)."
	else
		_hub_notice "Daemon stopped (PID $pid)."
	fi
	_hub_redetect_daemon
	return 0
}

# Context-aware toggle. When the daemon is running, prompts to stop it;
# when stopped, prompts to start it. The action confirms once before
# firing so a misclick doesn't tear down a running daemon.
_hub_toggle_daemon() {
	if [[ "$DAEMON_RUNNING" == "true" ]]; then
		if ! _hub_confirm "Stop the watchtower daemon (PID ${DAEMON_PID:-unknown})?"; then return; fi
		_hub_daemon_stop_inner
	else
		if ! _hub_confirm "Start the watchtower daemon?"; then return; fi
		_hub_daemon_start_inner
	fi
}

# Restart: stop (if running) then start. Single confirmation covers
# both phases so the operator isn't bothered twice for one operation.
# The 1-second sleep between stop and start lets the kernel release the
# flock and the daemon's EXIT trap remove the PID file before the new
# instance tries to write it.
_hub_restart_daemon() {
	if ! _hub_confirm "Restart the watchtower daemon?"; then return; fi
	if [[ "$DAEMON_RUNNING" == "true" ]]; then
		_hub_daemon_stop_inner
		sleep 1
	fi
	_hub_daemon_start_inner
}

# Trigger one of the daemon-IPC actions: drop the trigger file the
# daemon polls for, and send SIGUSR1 to wake it up immediately. The
# daemon clears the trigger file when it processes the action.
_hub_signal_action() {
	local action="$1" label="$2"
	local trigger_file=""
	case "$action" in
		update)   trigger_file="$TRIGGER_UPDATE" ;;
		scan)     trigger_file="$TRIGGER_SCAN" ;;
		verify)   trigger_file="$TRIGGER_VERIFY" ;;
		cleanup)  trigger_file="$TRIGGER_CLEANUP" ;;
		recovery) trigger_file="$TRIGGER_RECOVERY" ;;
		reload)   trigger_file="$TRIGGER_CONFIG" ;;
		*) _hub_notice "Unknown action: $action"; return ;;
	esac
	if ! _hub_confirm "Trigger ${label}?"; then return; fi
	if [[ "$DAEMON_RUNNING" != "true" ]]; then
		_hub_notice "Daemon not running — cannot trigger $label."
		return
	fi
	# For --reload, write the active config so the daemon knows what to load.
	if [[ "$action" == "reload" ]]; then
		echo "$CFG_TO_LOAD" >"$trigger_file"
	else
		touch "$trigger_file"
	fi
	[[ -n "$DAEMON_PID" ]] && kill -SIGUSR1 "$DAEMON_PID" 2>/dev/null || true
	_hub_notice "Signal sent — $label queued."
}

# Start an auto-backupper run. Optional mode argument: empty = use
# the cfg-default MODE; or one of produce / pull / both.
_hub_start_backup() {
	local mode_arg="${1:-}"
	if is_backup_running; then
		_hub_notice "Backup already running."
		return
	fi
	local label="backup (cfg default)"
	[[ -n "$mode_arg" ]] && label="backup --mode $mode_arg"
	if ! _hub_confirm "Start $label?"; then return; fi
	if [[ ! -f "$MAIN_BACKUP_SCRIPT" ]]; then
		_hub_notice "ERROR: backup script not found at $MAIN_BACKUP_SCRIPT"
		return
	fi
	# nohup + & detaches the child so the hub can keep rendering.
	# stdout/stderr go to /dev/null since the worker writes its own log.
	if [[ -n "$mode_arg" ]]; then
		nohup "$MAIN_BACKUP_SCRIPT" "--config=$CFG_TO_LOAD" --mode "$mode_arg" >/dev/null 2>&1 &
	else
		nohup "$MAIN_BACKUP_SCRIPT" "--config=$CFG_TO_LOAD" >/dev/null 2>&1 &
	fi
	_hub_notice "Started $label in background (PID $!)."
}

# Stop a running backup. Re-execs --stop-backup as a child so we inherit
# the existing escalating-signals logic without duplicating it here.
_hub_stop_backup() {
	if ! is_backup_running; then
		_hub_notice "No backup running."
		return
	fi
	if ! _hub_confirm "Stop running backup?"; then return; fi
	_HUB_IN_SUBVIEW=1
	_hub_term_restore
	# Pass the active config so the child's is_backup_running / BACKUP_PIDFILE
	# target the same lock/pidfile the hub is driving (a custom-lockfile config
	# would otherwise make the default-config child a no-op).
	bash "$0" "--config=$CFG_TO_LOAD" --stop-backup
	_hub_pause
	_HUB_IN_SUBVIEW=0
	_hub_term_init
}

# Generic "run a watchtower sub-view as a child" wrapper. Used for
# --ab-graph and --logs so their own SIGINT / cursor traps live in the
# child process and don't pollute the hub.
_hub_run_watchtower_subview() {
	local flag="$1"
	_HUB_IN_SUBVIEW=1
	_hub_term_restore
	bash "$0" "$flag"
	# When the child exits (q for --ab-graph; Ctrl+C for --logs), pause
	# briefly so any final output remains readable before re-rendering.
	_HUB_IN_SUBVIEW=0
	_hub_term_init
}

# Show one-shot status snapshot in-process (no subshell needed — it just
# prints and returns).
_hub_run_status() {
	_HUB_IN_SUBVIEW=1
	_hub_term_restore
	cmd_status
	_hub_pause
	_HUB_IN_SUBVIEW=0
	_hub_term_init
}

# Run an auto-restorer subcommand as a child. Returns gracefully when
# the restorer isn't found / configured.
_hub_run_restorer() {
	local restorer
	if ! restorer=$(_hub_find_restorer); then
		_hub_notice "Restorer not found. Set MAIN_RESTORER_SCRIPT in $CFG_TO_LOAD."
		return
	fi
	_HUB_IN_SUBVIEW=1
	_hub_term_restore
	bash "$restorer" "$@"
	_hub_pause
	_HUB_IN_SUBVIEW=0
	_hub_term_init
}

_hub_restorer_inspect() {
	local archive
	archive=$(_hub_prompt "Archive path to inspect (empty to cancel)")
	[[ -z "$archive" ]] && return
	_hub_run_restorer --inspect "$archive"
}

_hub_restorer_verify_one() {
	local archive
	archive=$(_hub_prompt "Archive path to verify (empty to cancel)")
	[[ -z "$archive" ]] && return
	_hub_run_restorer --verify "$archive"
}

# Logs sub-prompt: bottom-of-screen mini-menu that lets the user pick
# which log to tail. "all" uses the existing --logs auto-switcher;
# single-file picks use `tail -F` wrapped in a subshell so Ctrl+C
# returns to the hub instead of killing it.
_hub_logs_picker() {
	local lines
	lines=$(tput lines 2>/dev/null || echo 24)
	tput cup $((lines - 3)) 0 2>/dev/null
	tput el 2>/dev/null
	echo "  Logs: [a]ll-auto  [w]atchtower  [b]ackupper  [r]estorer  [p]ihole/warphole  [Esc] back"
	tput cup $((lines - 2)) 0 2>/dev/null
	tput el 2>/dev/null
	printf "  Pick: "
	tput cnorm 2>/dev/null
	local ans=""
	read -n 1 -s -r ans
	tput civis 2>/dev/null

	local picked=""
	case "$ans" in
		a|A) _hub_run_watchtower_subview "--logs"; return ;;
		w|W) picked="${WATCHTOWER_LOGFILE:-/var/log/auto_backupper_watchtower.log}" ;;
		b|B) picked="${BACKUP_LOGFILE:-/var/log/auto_backupper.log}" ;;
		r|R) picked="/var/log/auto_restorer.log" ;;
		p|P) picked="/var/log/warphole.log" ;;
		*) return ;;
	esac
	if [[ ! -r "$picked" ]]; then
		_hub_notice "Log not readable: $picked"
		return
	fi
	_HUB_IN_SUBVIEW=1
	_hub_term_restore
	echo "Tailing $picked. Press Ctrl+C to return to the hub."
	echo ""
	# Subshell with its own SIGINT trap so Ctrl+C exits the tail without
	# unwinding the hub.
	( trap 'exit 0' INT; tail -F "$picked" ) || true
	_HUB_IN_SUBVIEW=0
	_hub_term_init
}

# Compose the live-state portion of the menu. Values are intentionally
# tolerant of missing data (no daemon, no log files, etc.) — the hub
# is meant to be runnable on a fresh install where nothing has run yet.
_hub_render_header() {
	local cols
	cols=$(tput cols 2>/dev/null || echo 80)
	((cols < 60)) && cols=60

	local now_hms
	now_hms=$(date +%H:%M:%S)

	local daemon_line
	if [[ "$DAEMON_RUNNING" == "true" ]]; then
		if [[ -n "$DAEMON_PID" ]]; then
			local up
			up=$(_format_uptime_from_proc "$DAEMON_PID")
			[[ -z "$up" ]] && up="unknown"
			daemon_line="RUNNING (PID $DAEMON_PID, up $up)"
		else
			daemon_line="RUNNING (PID unknown — detected via lockfile)"
		fi
	else
		daemon_line="NOT RUNNING"
	fi

	local backup_state mover_state cache_pct
	if is_backup_running; then backup_state="in progress"; else backup_state="idle"; fi
	if is_mover_running;  then mover_state="running";       else mover_state="idle"; fi
	cache_pct=$(get_cache_usage 2>/dev/null || echo "n/a")

	# Schedule history (same data as cmd_status).
	local b c v u r
	b=$(cat "$LAST_RUN_BACKUP"   2>/dev/null || true)
	c=$(cat "$LAST_RUN_CLEANUP"  2>/dev/null || true)
	v=$(cat "$LAST_RUN_VERIFY"   2>/dev/null || true)
	u=$(cat "$LAST_RUN_UPDATE"   2>/dev/null || true)
	r=$(cat "$LAST_RUN_RECOVERY" 2>/dev/null || true)

	# Pending triggers — readable list of any queued action files.
	local pending=()
	[[ -f "$TRIGGER_UPDATE"  ]] && pending+=("update")
	[[ -f "$TRIGGER_SCAN"    ]] && pending+=("scan")
	[[ -f "$TRIGGER_VERIFY"  ]] && pending+=("verify")
	[[ -f "$TRIGGER_CLEANUP"  ]] && pending+=("cleanup")
	[[ -f "$TRIGGER_RECOVERY" ]] && pending+=("recovery")
	[[ -f "$TRIGGER_CONFIG"   ]] && pending+=("reload")
	[[ -f "$TRIGGER_FORCE"    ]] && pending+=("force")
	local pending_str="(none)"
	((${#pending[@]} > 0)) && pending_str="${pending[*]}"

	echo "=============== WATCHTOWER COMMAND CENTER  ${now_hms}  ==============="
	printf "  Host: %s   Config: %s\n" "$HOSTNAME_VAR" "$CFG_TO_LOAD"
	printf "  Daemon: %s\n" "$daemon_line"
	printf "  Backup: %-12s Mover: %-10s Cache: %s%%\n" "$backup_state" "$mover_state" "$cache_pct"
	printf "  Last:   backup %-15s cleanup %-15s verify %-15s update %-15s recovery %s\n" \
		"$(_format_age_days "$b")" "$(_format_age_days "$c")" \
		"$(_format_age_days "$v")" "$(_format_age_days "$u")" "$(_format_age_days "$r")"
	printf "  Pending: %s\n" "$pending_str"
}

_hub_render_menu() {
	# The daemon toggle's label is context-aware so the user sees what
	# the action will actually do at this moment.
	local toggle_label
	if [[ "$DAEMON_RUNNING" == "true" ]]; then
		toggle_label="Daemon: STOP    (running)"
	else
		toggle_label="Daemon: START   (stopped)"
	fi

	echo ""
	echo "  WATCHTOWER ACTIONS                  VIEWS"
	echo "    [c]  Cleanup now                    [g]  Live Graph"
	echo "    [u]  Docker Update                  [l]  Live Logs (picker)"
	echo "    [k]  Checksum Scan                  [t]  Status Snapshot"
	echo "    [v]  Full Verify Scan"
	echo "    [G]  Container Recovery"
	echo "    [R]  Reload daemon config"
	echo "    [d]  ${toggle_label}"
	echo "    [D]  Daemon: RESTART"
	echo ""
	echo "  AUTO-BACKUPPER                      AUTO-RESTORER"
	echo "    [s]  Start backup (cfg default)     [L]  List archives"
	echo "    [p]  Start --mode produce           [A]  Verify ALL archives"
	echo "    [P]  Start --mode pull              [C]  Corruption report"
	echo "    [B]  Start --mode both              [I]  Inspect (prompts)"
	echo "    [x]  Stop running backup            [V]  Verify single (prompts)"
	echo ""
	echo "    [q]  Quit"
	echo ""
	echo "  Header refreshes every 3s. Keys are case-sensitive."
	echo "==============================================================="
}

cmd_hub() {
	# Same dep set as the live graph (which the hub may launch as a sub-view).
	# A missing tool here means no hub — there is no degraded fallback.
	if ! _ab_graph_check_deps; then
		return 1
	fi

	_hub_term_init
	trap '_hub_int_handler' INT TERM
	# EXIT trap always restores the cursor + clears, regardless of how
	# we leave (normal `q`, Ctrl+C while at the menu, an error).
	trap '_hub_term_restore' EXIT

	# Relax strict mode for the menu loop. Same reasoning as cmd_ab_graph:
	# a transient sample failure (df, ps, stat against a vanishing path)
	# must not crash the UI.
	set +e

	while true; do
		_hub_redetect_daemon
		clear 2>/dev/null || true
		_hub_render_header
		_hub_render_menu

		local key=""
		# 3-second header refresh tick. `read -t` returns non-zero on
		# timeout — that's how we get the periodic redraw.
		if read -t 3 -n 1 -s -r key; then
			case "$key" in
				# --- Watchtower IPC triggers ---
				c) _hub_signal_action cleanup "Cleanup" ;;
				u) _hub_signal_action update  "Docker Update" ;;
				k) _hub_signal_action scan    "Checksum Scan" ;;
				v) _hub_signal_action verify  "Full Verify Scan" ;;
				G) _hub_signal_action recovery "Container Recovery" ;;
				R) _hub_signal_action reload  "Config Reload" ;;
				# --- Watchtower daemon lifecycle ---
				d) _hub_toggle_daemon ;;
				D) _hub_restart_daemon ;;
				# --- Auto-backupper modes ---
				s) _hub_start_backup "" ;;
				p) _hub_start_backup produce ;;
				P) _hub_start_backup pull ;;
				B) _hub_start_backup both ;;
				x) _hub_stop_backup ;;
				# --- Auto-restorer commands ---
				L) _hub_run_restorer --list ;;
				A) _hub_run_restorer --verify-all ;;
				C) _hub_run_restorer --corruption-report ;;
				I) _hub_restorer_inspect ;;
				V) _hub_restorer_verify_one ;;
				# --- Views ---
				g) _hub_run_watchtower_subview "--ab-graph" ;;
				l) _hub_logs_picker ;;
				t) _hub_run_status ;;
				# --- Quit ---
				q|Q) break ;;
				*) ;;   # unknown key — ignore silently
			esac
		fi
		# timeout (no key) → fall through, top of loop redraws
	done

	# EXIT trap will restore cursor + clear.
	return 0
}

# ==============================================================================
# 8. EXECUTION
# ==============================================================================

# 1. Parse Arguments
MODE="--${STARTUP_MODE}"
for arg in "$@"; do
	case $arg in
	--monitor) MODE="--monitor" ;;
	--scan) MODE="--scan" ;;
	--cleanup) MODE="--cleanup" ;;
	--update) MODE="--update" ;;
	--recover) MODE="--recover" ;;
	--verify) MODE="--verify" ;;
	--force) MODE="--force" ;;
	--start-backup) MODE="--start-backup" ;;
	--stop-backup) MODE="--stop-backup" ;;
	--reload) MODE="--reload" ;;
	--logs | --log) MODE="--logs" ;;
	--status) MODE="--status" ;;
	--ab-graph) MODE="--ab-graph" ;;
	--hub | --center | --command-center) MODE="--hub" ;;
	--config=*) ;;
	--config | -c) ;;   # space form — value captured by the pre-scan loop above
	esac
done

# 2. Check for Existing Daemon
DAEMON_RUNNING=false
DAEMON_PID=""
if [[ -f "$PID_FILE" ]]; then
	PID_CHECK=$(cat "$PID_FILE" 2>/dev/null)
	if [[ -n "$PID_CHECK" ]] && [[ "$PID_CHECK" =~ ^[0-9]+$ ]] && kill -0 "$PID_CHECK" >/dev/null 2>&1; then
		# S11: `kill -0` succeeds for ANY live PID — if the Linux kernel recycled
		# the PID between the old daemon's death and our check, we'd happily
		# send SIGUSR1 to an unrelated process (which for most processes means
		# default action = terminate). Cross-check /proc to confirm it's us.
		PID_LOOKS_LIKE_WATCHTOWER=false
		if [[ -r "/proc/$PID_CHECK/cmdline" ]]; then
			if tr '\0' ' ' <"/proc/$PID_CHECK/cmdline" 2>/dev/null | grep -q 'watchtower'; then
				PID_LOOKS_LIKE_WATCHTOWER=true
			fi
		else
			# On systems without procfs cmdline readability, fall back to trusting
			# the PID file (documented risk).
			PID_LOOKS_LIKE_WATCHTOWER=true
		fi

		if [[ "$PID_LOOKS_LIKE_WATCHTOWER" == "true" ]]; then
			DAEMON_RUNNING=true
			DAEMON_PID="$PID_CHECK"
		else
			# Stale PID file pointing at a recycled PID. Clean it up.
			rm -f "$PID_FILE" 2>/dev/null || true
		fi
	elif [[ -n "$PID_CHECK" ]]; then
		# PID in file is dead — clean up the stale file.
		rm -f "$PID_FILE" 2>/dev/null || true
	fi
fi

# S12: Lockfile fallback detection. If the PID-file probe above came up empty
# but the watchtower lockfile is exclusively held, a daemon IS running — our
# PID file just got out of sync (wiped by /tmp cleaner, daemon started without
# writing it, /proc not readable, etc.). Previously we'd fall through to the
# flock acquisition and die with "Watchtower is already running (Lockfile held)",
# making --scan/--verify/--cleanup/--force impossible against a live daemon.
# smart_sleep polls trigger files every 3s, so we can queue work by just
# dropping the trigger file — no PID or signal required.
if [[ "$DAEMON_RUNNING" == "false" && -e "$WATCHTOWER_LOCK" ]]; then
	_probe_fd=""
	if exec {_probe_fd}<"$WATCHTOWER_LOCK" 2>/dev/null; then
		if flock -n -s "$_probe_fd" 2>/dev/null; then
			# We got a shared lock, so no exclusive holder — daemon is NOT running.
			flock -u "$_probe_fd" 2>/dev/null || true
		else
			# Exclusive lock held by someone else (the daemon).
			DAEMON_RUNNING=true
			# DAEMON_PID stays empty; callers below must tolerate that.
		fi
		exec {_probe_fd}<&- 2>/dev/null || true
	fi
	unset _probe_fd
fi

# 3. Handle IPC (Signal Daemon if running)
# S12: When the daemon was detected via the lockfile fallback, DAEMON_PID may
# be empty — in that case we skip the SIGUSR1 (smart_sleep polls triggers
# every 3s, so the work still fires promptly) and just drop the trigger file.
notify_daemon() {
	local label="$1"
	if [[ -n "$DAEMON_PID" ]]; then
		echo "Signal sent to Daemon (PID: $DAEMON_PID) to $label."
		kill -SIGUSR1 "$DAEMON_PID" 2>/dev/null || true
	else
		echo "Daemon detected via lockfile (PID unknown). Queued $label — will run within a few seconds."
	fi
}

case "$MODE" in
"--reload")
	if [[ "$DAEMON_RUNNING" == "true" ]]; then
		# Always queue a config path so the daemon's re-source fires — even for a
		# bare `--reload` (the documented form). Writing only on --config meant a
		# bare reload sent SIGUSR1 (which just interrupts the sleep, it does NOT
		# process triggers) and the file-gated re-source block never ran, so bare
		# --reload stayed a no-op. Default to the daemon's own active config path
		# (mirrors the hub's reload). The daemon re-reads the LIVE file contents.
		echo "${CLI_CONFIG:-$CFG_TO_LOAD}" >"$TRIGGER_CONFIG"
		echo "Queued config reload: ${CLI_CONFIG:-$CFG_TO_LOAD}"
		notify_daemon "RELOAD"
		exit 0
	else
		echo "Error: Daemon is not running. Cannot reload."
		exit 1
	fi
	;;
"--update")
	if [[ "$DAEMON_RUNNING" == "true" ]]; then
		touch "$TRIGGER_UPDATE"
		notify_daemon "perform UPDATE"
		exit 0
	fi
	;;
"--recover")
	if [[ "$DAEMON_RUNNING" == "true" ]]; then
		touch "$TRIGGER_RECOVERY"
		notify_daemon "perform RECOVERY"
		exit 0
	fi
	;;
"--scan")
	if [[ "$DAEMON_RUNNING" == "true" ]]; then
		touch "$TRIGGER_SCAN"
		notify_daemon "perform SCAN"
		exit 0
	fi
	;;
"--verify")
	if [[ "$DAEMON_RUNNING" == "true" ]]; then
		touch "$TRIGGER_VERIFY"
		notify_daemon "perform VERIFY"
		exit 0
	fi
	ENABLE_VERIFICATION=true
	;;
"--cleanup")
	if [[ "$DAEMON_RUNNING" == "true" ]]; then
		touch "$TRIGGER_CLEANUP"
		notify_daemon "perform CLEANUP"
		exit 0
	fi
	;;
"--force")
	if [[ "$DAEMON_RUNNING" == "true" ]]; then
		touch "$TRIGGER_FORCE"
		notify_daemon "FORCE cycle"
		exit 0
	else
		echo "Error: Daemon is not running. Cannot force cycle."
		exit 1
	fi
	;;
esac

# 4. Acquire Lock (If we are here, we are either starting Monitor OR running standalone because daemon is dead)
# --status, --ab-graph and --hub are read-only — skip the exclusive lock
# so they can run while the daemon is up. Same exception we already make
# for --logs and the manual start/stop signals.
if [[ "$MODE" != "--start-backup" && "$MODE" != "--stop-backup" && "$MODE" != "--logs" && "$MODE" != "--status" && "$MODE" != "--ab-graph" && "$MODE" != "--hub" ]]; then
	exec 200>"$WATCHTOWER_LOCK"
	if ! flock -n 200; then
		echo "Error: Watchtower is already running (Lockfile held)."
		exit 1
	fi
fi

# 5. Monitor Setup
if [[ "$MODE" == "--monitor" ]]; then
	echo $$ >"$PID_FILE"
	trap 'daemon_signal_handler' SIGUSR1
	# INT/TERM: graceful shutdown — wait (bounded) for an in-flight update/recovery
	# task so a stop signal can't orphan a container mid-recreate, then exit (which
	# fires the EXIT trap). EXIT alone handles PID/STATUS cleanup for any other path.
	trap '_daemon_shutdown; exit' INT TERM
	trap 'rm -f "$PID_FILE" "$STATUS_FILE" 2>/dev/null' EXIT
	set_status "Idle"
fi

# 6. Initialize Reports
if [[ ! -f "$CORRUPTION_REPORT" ]]; then
	mkdir -p "$(dirname "$CORRUPTION_REPORT")"
	touch "$CORRUPTION_REPORT"
fi

# Hostname-case drift detection. Only run for modes that actually write
# artifacts under WATCH_DIR — read-only modes (--status, --ab-graph,
# --hub, --logs, signal-only triggers) skip it to keep their output
# clean. The warning fires once per script invocation regardless of
# whether the daemon is the one running.
case "$MODE" in
	"--monitor"|"--scan"|"--verify"|"--cleanup"|"--update")
		warn_hostname_case_drift
		;;
esac

# 7. Run Mode
case "$MODE" in
"--status")
	# One-shot snapshot. Returns non-zero if the daemon isn't running so
	# the command is usable as a monitoring probe.
	cmd_status
	exit $?
	;;
"--ab-graph")
	# Live full-terminal dashboard for an in-progress worker. Falls
	# through to cmd_status when nothing is running (and inherits that
	# command's exit code so cron pipelines stay consistent).
	cmd_ab_graph
	exit $?
	;;
"--hub")
	# Houston-style overseer: persistent menu + single-key shortcuts to
	# every other watchtower/backupper/restorer entry point.
	cmd_hub
	exit $?
	;;
"--monitor")
	log "STARTUP: Monitor Mode Active. Interval: ${MONITOR_INTERVAL:-300}s"

	# Post-(re)boot ghost-container catch. The daemon normally starts at boot
	# (or Unraid array start), so this plays the role the standalone recovery
	# tool's "At Startup of Array" hook used to: repair containers whose
	# writable layer vanished across the reboot, before normal monitoring.
	if [[ "${DOCKER_RECOVERY_ENABLE:-false}" == "true" && "${DOCKER_RECOVERY_RUN_ON_STARTUP:-true}" == "true" ]]; then
		run_docker_recovery_task
		atomic_write "$RECOVERY_LAST_PASS_EPOCH" "$(date +%s)"
	fi

	# State tracking to prevent log flooding
	WAS_BACKUP_PAUSED="false"

	while true; do
		# 0. Check Manual Triggers (For natural loop cycles)
		check_manual_triggers

		# 1. Schedulers
		check_backup_scheduler
		check_cleanup_scheduler
		check_update_scheduler
		check_recovery_interval

		# 2. Deep Verify (Blocking)
		if check_verify_scheduler; then
			smart_sleep "${MONITOR_INTERVAL:-300}"
			continue
		fi

		# 3. Cache Monitor
		manage_cache_state

		# 4. Conflict Checks (Optimized Logging)
		if is_backup_running; then
			# If this is the FIRST time we see the backup running, log it.
			if [[ "$WAS_BACKUP_PAUSED" == "false" ]]; then
				log "STATUS: Backup detected. Monitoring paused."
				WAS_BACKUP_PAUSED="true"
			fi
			# Sleep and retry, but don't log again.
			smart_sleep "${MONITOR_INTERVAL:-300}"
			continue
		else
			# If the backup WAS running last time but isn't now, log the resume.
			if [[ "$WAS_BACKUP_PAUSED" == "true" ]]; then
				log "STATUS: Backup finished. Monitoring resumed."
				WAS_BACKUP_PAUSED="false"
			fi
		fi

		if is_mover_running; then
			# Mover keeps the loop silent (no log flood), just sleeps.
			smart_sleep "${MONITOR_INTERVAL:-300}"
			continue
		fi

		# 5. Incremental Scan (Silent logging unless threads change)
		perform_scan "$WATCH_DIR" "false"

		# FIX: Replaced end-of-loop sleep with smart_sleep
		smart_sleep "${MONITOR_INTERVAL:-300}"
	done
	;;

"--cleanup")
	log "STARTUP: Forced Cleanup Mode"
	run_cleanup_task
	;;

"--update")
	log "STARTUP: Forced Docker Update Mode (Standalone)"
	run_docker_update_task
	;;

"--recover")
	log "STARTUP: Forced Container Recovery Mode (Standalone)"
	# Honour standalone-only diagnostic flags. A running daemon, when signalled,
	# uses its DOCKER_RECOVERY_* config instead (these don't cross the IPC).
	for _rec_arg in "$@"; do
		case "$_rec_arg" in
		--dry-run) DOCKER_RECOVERY_DRYRUN=true ;;
		--no-recreate) DOCKER_RECOVERY_NO_RECREATE=true ;;
		esac
	done
	run_docker_recovery_task
	exit $?
	;;

"--start-backup")
	log "MANUAL: Received Start Backup command."
	if is_backup_running; then
		echo "Backup is already running."
		exit 1
	fi
	send_notify "normal" "Manual Trigger" "Starting auto_backupper..."
	if [[ -f "$MAIN_BACKUP_SCRIPT" ]]; then
		nohup "$MAIN_BACKUP_SCRIPT" "--config=$CFG_TO_LOAD" >/dev/null 2>&1 &
		echo "Backup started in background."
	else
		echo "ERROR: Backup script not found at $MAIN_BACKUP_SCRIPT"
		exit 1
	fi
	;;

"--stop-backup")
	log "MANUAL: Received Stop Backup command."
	if ! is_backup_running; then
		echo "No backup is currently running (based on lockfile)."
		exit 0
	fi

	# C3: Use the PID file written by auto-backupper at startup. This is the
	# only safe way to identify the backup process; `pgrep -f basename` used to
	# match editors, grep processes, etc. and kill them by accident.
	# C4: DO NOT delete the lockfile here. The flock is held on the open file
	# descriptor; when the kernel reaps the killed process, the lock is
	# released automatically. Removing the file just opens a race window where
	# a concurrent backup could start before the old one has finished dying.
	TARGET_PID=""
	if [[ -f "$BACKUP_PIDFILE" ]]; then
		TARGET_PID=$(cat "$BACKUP_PIDFILE" 2>/dev/null)
	fi

	if [[ -z "$TARGET_PID" ]] || ! [[ "$TARGET_PID" =~ ^[0-9]+$ ]]; then
		echo "Could not read PID from $BACKUP_PIDFILE."
		echo "The backup lockfile exists but the PID file is missing or malformed;"
		echo "this usually means the backup was killed previously. You may need to"
		echo "wait for the kernel to release the flock, or reboot."
		exit 1
	fi

	if ! kill -0 "$TARGET_PID" 2>/dev/null; then
		echo "PID $TARGET_PID is not running; stale PID file."
		rm -f "$BACKUP_PIDFILE" 2>/dev/null
		exit 0
	fi

	# Cross-check that the PID actually belongs to auto-backupper before killing.
	if [[ -r "/proc/$TARGET_PID/cmdline" ]]; then
		if ! tr '\0' ' ' <"/proc/$TARGET_PID/cmdline" 2>/dev/null | grep -q -E 'auto[_-]backupper'; then
			echo "PID $TARGET_PID does not look like auto-backupper (cmdline mismatch). Refusing to kill."
			echo "If this is wrong, remove $BACKUP_PIDFILE manually and retry."
			exit 1
		fi
	fi

	echo "Stopping backup process: PID $TARGET_PID"
	kill -TERM "$TARGET_PID" 2>/dev/null || true
	# Grace period — let traps fire (restart Docker, clean IPC, release flock).
	STOP_WAITED=0
	while kill -0 "$TARGET_PID" 2>/dev/null && [[ $STOP_WAITED -lt 15 ]]; do
		sleep 1
		STOP_WAITED=$((STOP_WAITED + 1))
	done
	if kill -0 "$TARGET_PID" 2>/dev/null; then
		# Re-check the cmdline before escalating. During the 15s grace the worker
		# may have exited and the kernel recycled its PID onto an unrelated
		# process; SIGKILLing that is the wrong-process-kill the initial cmdline
		# guard exists to prevent. (If /proc/cmdline is unreadable we trust the
		# PID, same as the SIGTERM path above.)
		if [[ -r "/proc/$TARGET_PID/cmdline" ]] && ! tr '\0' ' ' <"/proc/$TARGET_PID/cmdline" 2>/dev/null | grep -q -E 'auto[_-]backupper'; then
			echo "PID $TARGET_PID no longer looks like auto-backupper (exited and PID reused?). NOT sending SIGKILL."
			send_notify "warning" "Manual Stop" "Backup PID $TARGET_PID vanished/recycled before SIGKILL; not escalating."
		else
			echo "Process $TARGET_PID didn't exit after 15s — sending SIGKILL."
			kill -9 "$TARGET_PID" 2>/dev/null || true
			send_notify "alert" "Manual Stop" "Backup process SIGKILLed — Docker state may need manual recovery on next run."
		fi
	else
		send_notify "warning" "Manual Stop" "Backup process terminated cleanly by user."
	fi
	echo "Backup stopped."
	;;
"--logs")
	monitor_logs
	;;
*)
	# Standalone one-shot scan/verify (daemon not running). The IPC trigger path
	# (check_manual_triggers) gates on is_backup_running; this CLI path must too,
	# or `watchtower.sh --scan|--verify` while an independent backup (cron /
	# --start-backup) holds BACKUP_LOCKFILE would walk the live, in-progress tree
	# and could checksum a half-written archive. The watchtower flock is a
	# DIFFERENT lock, so it doesn't exclude a running backup.
	if is_backup_running; then
		log "WARN: A backup is in progress; refusing to scan the live tree. Retry when idle."
		echo "A backup is in progress; refusing to scan. Retry when the backup finishes." >&2
		exit 1
	fi
	log "STARTUP: One-Time Scan Mode (Verify: ${ENABLE_VERIFICATION:-false})"
	perform_scan "$WATCH_DIR" "${ENABLE_VERIFICATION:-false}"
	;;
esac