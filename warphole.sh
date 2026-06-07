#!/usr/bin/env bash
export PATH=/sbin:/opt/bin:/usr/local/bin:/usr/contrib/bin:/bin:/usr/bin:/usr/sbin:/usr/bin/X11

# ==============================================================================
# WARPHOLE (Enclave Edition)
# Combines Teleporter Backup, Health Monitor, and PADD-based Stats
# ==============================================================================
# Usage:
#   ./warphole.sh                : Runs DEFAULT_MODE (if configured)
#   ./warphole.sh --stats        : Launch Warp-Core Terminal Dashboard
#   ./warphole.sh --backup-now   : Run Teleporter backup & offload to backup server
#   ./warphole.sh --check        : Run Health check (Conditional Reboot repair)
# ==============================================================================

set -Eeuo pipefail

# ==============================================================================
# 1. CONFIGURATION
# ==============================================================================
# --- Identity ---
# `hostname -s` is inetutils-only and breaks on hosts that ship the
# GNU coreutils hostname (Debian/Ubuntu/Arch default). Pipe through cut
# to keep the short form portable across all supported targets.
#
# Normalised to UPPERCASE — see auto-backupper.sh's matching block for
# the full rationale. Short version: warphole writes a Pi-hole backup
# named `${HOSTNAME_VAR}_pihole_${CDATE}.zip` into the central NAS, and
# without a canonical case, a host whose returned casing drifts
# produces duplicate `<HOST>_pihole_*` and `<host>_pihole_*` siblings
# that auto-backupper's pull-side retention can't reconcile. Config can
# override (`HOSTNAME_VAR="my-host"` in the secrets file wins).
HOSTNAME_VAR="$(hostname | cut -d. -f1 | tr '[:lower:]' '[:upper:]')"
# WM17: HOSTNAME_LAB was a duplicate of HOSTNAME_VAR. Keep the name as an
# alias so the dashboard banner doesn't need a rewrite, but stop calling
# hostname twice.
HOSTNAME_LAB="$HOSTNAME_VAR"
# --- Default Behavior ---
# Options: "check", "backup", "stats", or "" (empty = require manual flags)
DEFAULT_MODE=""

CDATE=$(date +%Y%m%d)
LOGFILE="/var/log/warphole.log"
REPAIR_MARKER="/etc/pihole/gravity_repair_pending"

# --- Log Rotation & Verbosity Defaults ---
# Matches the auto-backupper.sh model so all suite scripts share the
# same knobs. See README's "Configuration Reference > General Settings".
LOG_MAX_SIZE="$((10 * 1024 * 1024))" # 10 MB
LOG_BACKUPS=5
LOG_VERBOSITY="info"

# --- Docker Settings ---
IS_DOCKER=true
DOCKER_CONTAINER_NAME="pihole-v6-unbound"

# --- Backup Settings (Warphole) ---
DESTINATION_TYPE="local" # "smb" or "local"
SMB_HOST="127.0.0.1"     # IP or Hostname of remote NAS
SMB_SHARE="backup"       # Share Name
SMB_SUBFOLDER="services/pihole/${HOSTNAME_VAR}"
# WC5: credentials MUST come from /etc/warphole/secrets.env (see below).
# Kept as empty placeholders here so a fresh clone doesn't have a working
# default password sitting in a publicly-readable script. If you absolutely
# must put credentials inline, put the file at mode 600 — but secrets.env
# is the supported path and the only path that receives permission warnings.
SMB_USER=""
SMB_PASS=""
MOUNT_POINT="/mnt/backups"
# LOCAL_EXPORT_PATH is derived *after* secrets.env is sourced, so that
# SMB_SHARE / SMB_SUBFOLDER overrides from the secrets file actually flow
# through. Leaving it unset here on purpose.

# WS4: Retention. Number of days to keep old backups.
# 0 = keep forever (legacy behavior). 90 is a reasonable default.
WARPHOLE_KEEP_DAYS=90

# --- Tailscale Settings ---
CHECK_TAILSCALE=false         # Set to true to enable Tailscale ping check
TAILSCALE_PING_IP="100.x.y.z" # A highly available Tailscale IP to ping (e.g., your NAS, another Pi, or exit node)

# --- API Settings (Tars & Warp-Core) ---
PI_URL="http://127.0.0.1/api"
# WC5: PI_PASSWORD also comes from secrets.env. Empty = no password set on the Pi-hole.
PI_PASSWORD=""
REFRESH_RATE=2 # Dashboard refresh rate in seconds

# --- Debug ---
# Set to "true" here, in secrets.env, or via WARPHOLE_DEBUG=true on the command
# line to enable phase-marker logging (DEBUG: ...) used to trace where the
# script terminates. Off by default to keep production logs quiet.
DEBUG_MODE="${WARPHOLE_DEBUG:-false}"

# --- Internal Paths ---
TEMP_DIR="/tmp/pihole_backup_staging"
GRAVITY_LOG="/tmp/gravity_update.log"
GRAVITY_PIDFILE="/tmp/warphole_gravity.pid"
LOCKFILE="/var/lock/warphole.lock"
LOCKFD=""

# --- Colors ---
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
NC='\033[0m' # No Color

# --- Runtime Flags (Do not edit) ---
KEEP_LOCAL=false
MANAGE_MOUNT=true
MODE=""
SID=""

# WC5: Load credentials from an external, mode-600 file. Keeps passwords
# out of the script body (which may be in git, readable by other users
# via `cat`, or copied to another box during a restore). The file is a
# plain bash fragment — any assignment here overrides the defaults above.
#
# Typical contents:
#   SMB_USER="warphole"
#   SMB_PASS="long-random-string"
#   PI_PASSWORD="another-long-random-string"
#   # Optionally override share/host if the defaults don't fit your setup:
#   # SMB_HOST="nas.lan"
#   # SMB_SHARE="backups"
#
# We warn (not fatal) on permission drift so the user notices if something
# relaxed the mode, but we still source the file — a world-readable file
# with real credentials is still better than hardcoded credentials in git.
SECRETS_FILE="${WARPHOLE_SECRETS_FILE:-/etc/warphole/secrets.env}"
if [[ -f "$SECRETS_FILE" ]]; then
	_secrets_perms=$(stat -c '%a' "$SECRETS_FILE" 2>/dev/null || echo "")
	_secrets_owner=$(stat -c '%U' "$SECRETS_FILE" 2>/dev/null || echo "")
	if [[ -n "$_secrets_perms" && "$_secrets_perms" != "600" && "$_secrets_perms" != "400" ]]; then
		echo "WARN: $SECRETS_FILE has permissions $_secrets_perms; recommend: chmod 600 $SECRETS_FILE" >&2
	fi
	if [[ -n "$_secrets_owner" && "$_secrets_owner" != "root" ]]; then
		echo "WARN: $SECRETS_FILE is owned by $_secrets_owner, not root." >&2
	fi
	# shellcheck disable=SC1090
	source "$SECRETS_FILE"
	unset _secrets_perms _secrets_owner
fi

# Now derive LOCAL_EXPORT_PATH from the final (possibly-overridden) values.
# Preserve an explicit LOCAL_EXPORT_PATH override from secrets.env if set.
LOCAL_EXPORT_PATH="${LOCAL_EXPORT_PATH:-/mnt/user/${SMB_SHARE}/${SMB_SUBFOLDER}}"

# ==============================================================================
# 2. UTILITIES & LOGGING
# ==============================================================================

# Root Check
if [[ $EUID -ne 0 ]]; then
	echo "CRITICAL: This script must be run as root." >&2
	exit 1
fi

# Logging Setup
touch "$LOGFILE" 2>/dev/null || true
# WS14: restrict log to root-only in case anything ever logs the auth response.
chmod 600 "$LOGFILE" 2>/dev/null || true
# WM1: Scan ALL arguments for --stats, not just $1. Previously
# `warphole.sh --keep-local --stats` would enable tee redirection because
# $1 was "--keep-local", spamming dashboard output into the logfile.
_stats_mode=false
[[ "$DEFAULT_MODE" == "stats" ]] && _stats_mode=true
for _arg in "$@"; do
	if [[ "$_arg" == "--stats" ]]; then
		_stats_mode=true
		break
	fi
done
if [[ "$_stats_mode" == "false" ]]; then
	exec > >(tee -a "$LOGFILE") 2>&1
fi
unset _stats_mode _arg

# Copytruncate log rotation — same pattern as auto-backupper.sh,
# watchtower.sh, and auto-restorer.sh. Critical here because
# warphole's logging path uses `exec > >(tee -a "$LOGFILE")` (held FD
# via the tee subprocess) — mv-based rotation would orphan it.
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
	# WD7: keep the live log and the rotated copy root-only (mode 600) to match the
	# WS14 setup hardening — the previous `chmod 644` here silently re-loosened the
	# logfile to world-readable on every rotation (the auth response can be logged).
	chmod 600 "$logfile" 2>/dev/null || true
	chmod 600 "${logfile}.1" 2>/dev/null || true
}

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

# Detect a warphole message's level from its prefix. Tuned to the
# script's actual log call conventions (audited via grep).
_log_level_for() {
	case "$1" in
		FATAL*|CRITICAL*|ERROR:*|ERROR\ *|WARN:*|WARN\ *|WARNING:*|"Auth Failed:"*) echo 2 ;;
		"==="*|ACTION:*|Action:*|RECOVERY:*|SUCCESS:*|VERIFIED:*|HEALTHY:*|Phase:*|Rotation:*|Cleanup:*) echo 3 ;;
		DEBUG:*) echo 99 ;;
		*) echo 4 ;;
	esac
}

log() {
	local lvl thresh
	lvl=$(_log_level_for "$1")
	thresh=$(_log_verbosity_threshold)
	((lvl <= thresh)) || { rotate_log_if_needed; return 0; }

	printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1"
	rotate_log_if_needed
}

# Debug-only logger — emits a "DEBUG: ..." line when DEBUG_MODE=true,
# silent otherwise. The line will then also be filtered by log()'s
# verbosity check: visible at LOG_VERBOSITY=debug, hidden otherwise.
# Use for phase markers and bisecting silent exits.
dlog() { [[ "$DEBUG_MODE" == "true" ]] && log "DEBUG: $1"; return 0; }

# WC1: Acquire exclusive lock for mutating operations (backup, check).
# Skip locking for stats (read-only against the API) to allow a dashboard
# to run while a scheduled backup is also running.
acquire_lock() {
	exec {LOCKFD}>"$LOCKFILE" || {
		echo "FATAL: Cannot open lockfile $LOCKFILE"
		exit 1
	}
	if ! flock -n "$LOCKFD"; then
		echo "Another warphole instance is running (lockfile held). Exiting."
		exit 0
	fi
}

# WS3: Detect in-progress gravity update via pidfile rather than
# `pgrep -f "pihole -g"`. The pgrep approach matches any command line
# containing that substring — e.g. `vim pihole-g-notes.txt`, grep
# invocations, or even the dashboard's own process list walk — causing
# false-positive "UPDATING" status in the UI.
is_gravity_running() {
	[[ -f "$GRAVITY_PIDFILE" ]] || return 1
	local pid
	pid=$(cat "$GRAVITY_PIDFILE" 2>/dev/null || echo "")
	if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
		return 0
	fi
	# Stale pidfile from a crashed prior run — clean up.
	rm -f "$GRAVITY_PIDFILE" 2>/dev/null || true
	return 1
}

# Cleanup Function
cleanup() {
	# Remove Temp Backup Files
	if [[ -d "$TEMP_DIR" && "$KEEP_LOCAL" == "false" ]]; then
		rm -rf "$TEMP_DIR"
	fi

	# Auto-Unmount
	if [[ "$DESTINATION_TYPE" == "smb" && "$MANAGE_MOUNT" == "true" ]]; then
		if mountpoint -q "$MOUNT_POINT"; then
			[[ "$MODE" != "stats" ]] && log "Cleanup: Unmounting share..."
			umount "$MOUNT_POINT" || umount -l "$MOUNT_POINT" || true
		fi
	fi

	# Clean Auth Session
	if [[ -n "${SID:-}" ]]; then
		# WM13: Best-effort logout. If the session is already expired
		# (e.g. dashboard ran longer than the session TTL), this will
		# return an error — swallow it silently. Short timeout so a
		# stuck API never delays shutdown.
		curl -s --max-time 5 -X DELETE "$PI_URL/auth" -H "X-FTL-SID: $SID" >/dev/null 2>&1 || true
	fi

	# Reset Terminal (if in stats mode)
	if [[ "$MODE" == "stats" ]]; then
		# WM5: guard against bad/unset TERM (cron, systemd, dumb terminals)
		# so we don't spam "tput: unknown terminal" errors on the way out.
		tput cnorm 2>/dev/null || true
		clear 2>/dev/null || true
	fi
}
trap 'cleanup' EXIT

# Dependencies Check
check_deps() {
	# WS8: base deps used in every mode
	local DEPS=(curl jq awk sha256sum)
	# WS8/WM8: add only the deps the current config actually needs, so
	# users on minimal setups don't fail a check for tools they'll never use.
	[[ "$IS_DOCKER" == "true" ]] && DEPS+=(docker)
	# WD6: on bare metal the backup uses pihole-FTL and the check uses `pihole -g`;
	# require them up front so a missing/renamed binary fails fast with a clear
	# message instead of a late silent abort inside run_backup / run_health_check.
	[[ "$IS_DOCKER" != "true" ]] && DEPS+=(pihole-FTL pihole)
	[[ "$DESTINATION_TYPE" == "smb" ]] && DEPS+=(mount.cifs findmnt)
	# WD8: ping is required for the Tailscale probe; systemctl is only needed to
	# restart tailscaled and is treated as a SOFT dep (guarded in
	# verify_tailscale_network), so a non-systemd host doesn't fail every mode here.
	[[ "$CHECK_TAILSCALE" == "true" ]] && DEPS+=(ping)
	# Stats mode uses free/seq/tput for the dashboard; cheap to always
	# require since these are present in every mainstream distro.
	DEPS+=(free seq)

	for cmd in "${DEPS[@]}"; do
		if ! command -v "$cmd" &>/dev/null; then
			echo "FATAL: Dependency '$cmd' is missing. Please install it."
			exit 1
		fi
	done
}

# API Authentication
#
# WD2: Build the auth body and call curl as SEPARATE commands rather than
# piping `jq | curl`. Under `set -Eeuo pipefail`, a curl failure (timeout,
# connection refused, FTL unhealthy because the gravity DB swap failed)
# inside a `$(jq | curl)` substitution propagates through pipefail and
# silently terminates the script — the original symptom we were chasing
# was the health check vanishing right after `pre-authenticate` with no
# error logged. Splitting the pipeline lets us capture curl's rc with
# `|| auth_rc=$?` and treat network failures as "no SID, continue" so
# the downstream /padd check (and its -2 [null] detection) still runs.
authenticate() {
	dlog "authenticate entered"
	if [[ -z "$PI_PASSWORD" ]]; then
		dlog "PI_PASSWORD empty, skipping auth"
		return 0
	fi

	local AUTH_BODY=""
	AUTH_BODY=$(jq -n --arg pw "$PI_PASSWORD" '{password: $pw}' 2>/dev/null) || {
		log "WARN: jq failed to build auth body (rc=$?). Skipping auth."
		return 0
	}

	local AUTH_RESPONSE="" auth_rc=0
	AUTH_RESPONSE=$(curl -s --max-time 10 -X POST "$PI_URL/auth" \
		-H "Content-Type: application/json" \
		-d "$AUTH_BODY") || auth_rc=$?
	dlog "curl auth rc=$auth_rc, response length=${#AUTH_RESPONSE}"

	if [[ $auth_rc -ne 0 || -z "$AUTH_RESPONSE" ]]; then
		log "WARN: auth curl failed (rc=$auth_rc) or returned empty. Continuing without SID."
		return 0
	fi

	SID=$(echo "$AUTH_RESPONSE" | jq -r '.session.sid // empty' 2>/dev/null || echo "")

	if [[ -z "$SID" ]]; then
		local MSG=""
		MSG=$(echo "$AUTH_RESPONSE" | jq -r '.session.message // empty' 2>/dev/null || echo "")
		if [[ "$MSG" != *"no password set"* ]]; then
			# Only fatal if not in stats mode
			if [[ "$MODE" != "stats" ]]; then
				log "Auth Failed: $MSG"
				exit 1
			fi
		fi
	fi
}

# SMB Mount Logic
mount_smb() {
	# WC5: Fail fast if credentials are missing. Without this, mount.cifs
	# returns a cryptic "mount error(13)" that's hard to diagnose; with it,
	# the user sees exactly what to set up.
	if [[ -z "$SMB_USER" || -z "$SMB_PASS" ]]; then
		log "FATAL: SMB_USER or SMB_PASS is empty."
		log "       Set them in ${SECRETS_FILE} (recommended, mode 600)"
		log "       or directly in the script body if you understand the tradeoff."
		exit 1
	fi

	if mountpoint -q "$MOUNT_POINT"; then
		log "INFO: Mount point $MOUNT_POINT is already active."
		# WM9: Verify it's actually mounted from the expected source.
		# If some OTHER filesystem is mounted at MOUNT_POINT (another
		# share, a disk, a stale mount from a different config), we'd
		# otherwise silently write backups into an unrelated location.
		local current_source expected
		current_source=$(findmnt -n -o SOURCE "$MOUNT_POINT" 2>/dev/null || true)
		expected="//$SMB_HOST/$SMB_SHARE"
		if [[ -n "$current_source" && "$current_source" != "$expected" ]]; then
			log "FATAL: $MOUNT_POINT is mounted, but from '$current_source' (expected '$expected')."
			log "       Refusing to write backup to an unrelated mount. Unmount it first."
			exit 1
		fi
		return
	fi

	mkdir -p "$MOUNT_POINT"
	log "ACTION: Mounting //$SMB_HOST/$SMB_SHARE..."

	# WC3: Use a temporary credentials file instead of passing the password
	# via `-o` options. Without this, the password appears in `ps` output
	# during the mount call. The file is created with mode 0600, used, and
	# shredded/removed immediately.
	local creds_file
	creds_file=$(mktemp /tmp/warphole_creds.XXXXXX) || {
		log "FATAL: Could not create temporary credentials file."
		exit 1
	}
	chmod 600 "$creds_file"
	printf 'username=%s\npassword=%s\n' "$SMB_USER" "$SMB_PASS" >"$creds_file"

	local mount_rc=0
	mount -t cifs "//$SMB_HOST/$SMB_SHARE" "$MOUNT_POINT" \
		-o "credentials=$creds_file,vers=3.0,iocharset=utf8" || mount_rc=$?

	# Scrub the credentials file immediately, regardless of mount result.
	if command -v shred >/dev/null 2>&1; then
		shred -u "$creds_file" 2>/dev/null || rm -f "$creds_file"
	else
		rm -f "$creds_file"
	fi

	if [[ $mount_rc -eq 0 ]]; then
		log "SUCCESS: Share mounted."
	else
		log "FATAL: Failed to mount SMB share (exit code $mount_rc)."
		exit 1
	fi
}

# WS16: Run `pihole -g` with output redirected to GRAVITY_LOG instead of
# letting it flow through the script's stdout (which goes through `tee -a`
# at the top of the file). On low-memory hosts — exactly the condition
# that produces a corrupt gravity DB in the first place — piping the
# firehose of pihole-g output through tee can trigger an OOM kill of the
# tee/bash process or a SIGPIPE that terminates the script silently
# mid-rebuild. We've seen the log truncate mid-blocklist with no FATAL,
# no exit line, just gone. Routing pihole-g to its own file breaks that
# chain: bash only writes a one-line summary and a short tail, the full
# output stays in $GRAVITY_LOG for review.
#
# Usage: run_gravity_rebuild <label>
# Returns the rc of pihole-g; callers decide whether to treat it as fatal.
run_gravity_rebuild() {
	local label="$1"
	local rc=0
	: >"$GRAVITY_LOG" 2>/dev/null || true
	if [[ "$IS_DOCKER" == "true" ]]; then
		docker exec "$DOCKER_CONTAINER_NAME" pihole -g >"$GRAVITY_LOG" 2>&1 || rc=$?
	else
		pihole -g >"$GRAVITY_LOG" 2>&1 || rc=$?
	fi
	log "Phase: $label — pihole -g exited rc=$rc (tail of $GRAVITY_LOG):"
	tail -n 3 "$GRAVITY_LOG" 2>/dev/null | sed 's/^/    /' || true
	return "$rc"
}

# WS7: Verify the pihole container is actually running before we try to
# docker exec against it. Without this, a stopped container produces a
# cryptic error from docker exec that's hard to diagnose.
ensure_pihole_running() {
	[[ "$IS_DOCKER" != "true" ]] && return 0
	if ! command -v docker >/dev/null 2>&1; then
		log "FATAL: Docker command not found."
		return 1
	fi
	local state
	state=$(docker inspect --format '{{.State.Running}}' "$DOCKER_CONTAINER_NAME" 2>/dev/null || echo "missing")
	if [[ "$state" != "true" ]]; then
		log "FATAL: Container '$DOCKER_CONTAINER_NAME' is not running (state: $state)."
		log "       Start it with: docker start $DOCKER_CONTAINER_NAME"
		return 1
	fi
	return 0
}

# ==============================================================================
# 3. WARPHOLE (BACKUP)
# ==============================================================================

run_backup() {
	log "=== Starting Pi-hole Backup (Docker: $IS_DOCKER | Dest: $DESTINATION_TYPE) ==="

	# --- 1. Prepare Destination ---
	local FINAL_DEST_DIR=""
	if [[ "$DESTINATION_TYPE" == "smb" ]]; then
		mount_smb
		FINAL_DEST_DIR="$MOUNT_POINT/$SMB_SUBFOLDER"
	else
		FINAL_DEST_DIR="$LOCAL_EXPORT_PATH"
		MANAGE_MOUNT=false
	fi
	# WM10: strip any trailing slash so "$FINAL_DEST_DIR/$TARGET_NAME"
	# doesn't produce "//name" — cosmetic but makes logs cleaner.
	FINAL_DEST_DIR="${FINAL_DEST_DIR%/}"

	if [[ ! -d "$FINAL_DEST_DIR" ]]; then
		mkdir -p "$FINAL_DEST_DIR" || {
			log "FATAL: Cannot create dest dir $FINAL_DEST_DIR"
			exit 1
		}
	fi

	if [[ ! -w "$FINAL_DEST_DIR" ]]; then
		log "FATAL: Destination $FINAL_DEST_DIR is not writable."
		exit 1
	fi

	# --- 2. Generate Backup ---
	mkdir -p "$TEMP_DIR"
	log "Phase: Generating Teleporter Archive..."

	if [[ "$IS_DOCKER" == "true" ]]; then
		# WS7: verify container is actually running before docker exec.
		ensure_pihole_running || exit 1

		log "Action: Running pihole-FTL inside container '$DOCKER_CONTAINER_NAME'..."

		# WS11: capture the generated filename directly from pihole-FTL's stdout
		# instead of guessing via `ls -t /tmp/*.zip | head -n1`. The previous
		# approach could pick up a stale zip from a crashed earlier run.
		# WS15: pihole-FTL v6 prints FTLCONF env var parsing messages to stdout
		# BEFORE the filename. Isolate the teleporter zip line; fall back to the
		# last line ending in .zip if the naming convention ever changes.
		local RAW_OUTPUT DOCKER_FILE
		RAW_OUTPUT=$(docker exec -w /tmp "$DOCKER_CONTAINER_NAME" pihole-FTL --teleporter 2>/dev/null)
		DOCKER_FILE=$(printf '%s\n' "$RAW_OUTPUT" | grep -oE '[^[:space:]]+_teleporter_[^[:space:]]+\.zip' | tail -n 1)
		if [[ -z "$DOCKER_FILE" ]]; then
			DOCKER_FILE=$(printf '%s\n' "$RAW_OUTPUT" | grep -oE '[^[:space:]]+\.zip' | tail -n 1)
		fi
		DOCKER_FILE=$(printf '%s' "$DOCKER_FILE" | tr -d '\r\n')
		DOCKER_FILE="${DOCKER_FILE## }"
		DOCKER_FILE="${DOCKER_FILE%% }"

		if [[ -z "$DOCKER_FILE" ]]; then
			log "FATAL: pihole-FTL --teleporter produced no filename (container may be unhealthy)."
			exit 1
		fi

		# If pihole-FTL printed just a basename, promote it to an absolute /tmp path.
		if [[ "$DOCKER_FILE" != /* ]]; then
			DOCKER_FILE="/tmp/$DOCKER_FILE"
		fi

		# Confirm the file actually exists inside the container.
		if ! docker exec "$DOCKER_CONTAINER_NAME" test -f "$DOCKER_FILE"; then
			log "FATAL: Teleporter reported '$DOCKER_FILE' but that path does not exist in the container."
			exit 1
		fi

		log "Action: Copying $DOCKER_FILE from container to host..."
		# WS12: if docker cp fails, still clean up the container-side zip so it
		# doesn't linger and confuse future runs. Use `rm -f` so a missing file
		# doesn't trip set -e on the cleanup path.
		if ! docker cp "$DOCKER_CONTAINER_NAME:$DOCKER_FILE" "$TEMP_DIR/"; then
			log "ERROR: docker cp failed — cleaning up container-side zip before exit"
			docker exec "$DOCKER_CONTAINER_NAME" rm -f "$DOCKER_FILE" 2>/dev/null || true
			exit 1
		fi
		docker exec "$DOCKER_CONTAINER_NAME" rm -f "$DOCKER_FILE" 2>/dev/null || true
	else
		# Bare Metal — WD5: guard so an FTL failure (binary missing/renamed, locked
		# DB, no space in TEMP_DIR) logs a FATAL instead of a silent `set -e` abort
		# with no log line. The Docker branch above was already guarded; this is its
		# bare-metal equivalent. Real pihole-FTL prints the zip path to stdout (which
		# we discard — `find` below locates the file); capture stderr for the log.
		local ftl_rc=0
		( cd "$TEMP_DIR" && pihole-FTL --teleporter ) >/dev/null 2>"$TEMP_DIR/.ftl_err" || ftl_rc=$?
		if [[ $ftl_rc -ne 0 ]]; then
			log "FATAL: pihole-FTL --teleporter failed (rc=$ftl_rc). FTL output: $(tr '\n' ' ' <"$TEMP_DIR/.ftl_err" 2>/dev/null)"
			rm -f "$TEMP_DIR/.ftl_err" 2>/dev/null || true
			exit 1
		fi
		rm -f "$TEMP_DIR/.ftl_err" 2>/dev/null || true
	fi

	# --- 3. Process & Offload ---
	local GEN_FILE
	GEN_FILE=$(find "$TEMP_DIR" -maxdepth 1 -type f -name "*.zip" -print -quit)

	if [[ -z "$GEN_FILE" ]]; then
		log "FATAL: Backup file not found in staging area."
		exit 1
	fi

	local TARGET_NAME="${HOSTNAME_VAR}_pihole_${CDATE}.zip"
	local TARGET_PATH="$FINAL_DEST_DIR/$TARGET_NAME"

	log "Phase: Finalizing..."
	log "Source: $GEN_FILE"
	log "Target: $TARGET_PATH"

	# WM2: Write to a temp name first, then atomically rename. On network
	# filesystems a mid-copy disconnect would otherwise leave a truncated
	# file at the final name; this guarantees observers see either the
	# previous file or the complete new one, never a partial write.
	local TARGET_TMP="${TARGET_PATH}.tmp"
	if cp "$GEN_FILE" "$TARGET_TMP" && mv "$TARGET_TMP" "$TARGET_PATH"; then
		log "SUCCESS: Backup saved to $TARGET_PATH"

		# --- 4. Verify Checksum ---
		local LOC_SUM REM_SUM
		LOC_SUM=$(sha256sum "$GEN_FILE" | awk '{print $1}')
		REM_SUM=$(sha256sum "$TARGET_PATH" | awk '{print $1}')

		if [[ "$LOC_SUM" == "$REM_SUM" ]]; then
			log "VERIFIED: Checksum matches ($LOC_SUM)"
		else
			log "ERROR: Checksum mismatch! ($LOC_SUM vs $REM_SUM)"
			exit 1
		fi

		# WM11: Additional zip-internal integrity check. For LOCAL destinations
		# the checksum compare above is nearly trivial (same fs) — this catches
		# the case where Teleporter produced a corrupt zip that got byte-for-byte
		# duplicated. For SMB destinations it's a second line of defense against
		# silent in-flight corruption that didn't hit the wire CRC.
		if command -v unzip >/dev/null 2>&1; then
			if ! unzip -tq "$TARGET_PATH" >/dev/null 2>&1; then
				log "ERROR: Destination zip failed integrity test (unzip -t)"
				rm -f "$TARGET_PATH" 2>/dev/null || true
				exit 1
			fi
			log "VERIFIED: Zip integrity OK (unzip -t)"
		fi

		# --- 4b. Persist dated checksum under .checksums/ ---
		# Warphole's output is pulled into auto-backupper's sync cycle on the
		# central NAS, and auto-backupper's pull-side retention reads each
		# file's discovery date from the "_<YYYYMMDD>.sha256" suffix in the
		# parallel .checksums/ tree. If we don't write one here, the file
		# arrives un-stamped and the pull will either fall back to mtime
		# (rsync-preserved, possibly wrong) or pull it regardless of age.
		# Writing it ourselves at creation time avoids the watchtower-scan
		# race entirely.
		#
		# Layout mirrors auto-backupper's:
		#   ${BACKUP_ROOT}/${SMB_SUBFOLDER}/<name>.zip
		#   ${BACKUP_ROOT}/.checksums/${SMB_SUBFOLDER}/<name>.zip_<CDATE>.sha256
		# where BACKUP_ROOT is the share root (the parent of SMB_SUBFOLDER).
		local BACKUP_ROOT
		if [[ "$DESTINATION_TYPE" == "smb" ]]; then
			BACKUP_ROOT="${MOUNT_POINT%/}"
		else
			BACKUP_ROOT="/mnt/user/${SMB_SHARE}"
		fi
		BACKUP_ROOT="${BACKUP_ROOT%/}"
		local CHK_SUBDIR="${BACKUP_ROOT}/.checksums/${SMB_SUBFOLDER}"
		local CHK_PATH="${CHK_SUBDIR}/${TARGET_NAME}_${CDATE}.sha256"

		if mkdir -p "$CHK_SUBDIR" 2>/dev/null; then
			# Sweep any stale dated sibling — same hygiene the main
			# auto-backupper write_checksum applies. Only one dated
			# checksum per data file in steady state.
			shopt -s nullglob
			local _stale
			for _stale in "${CHK_SUBDIR}/${TARGET_NAME}"_[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9].sha256; do
				rm -f "$_stale"
			done
			shopt -u nullglob

			# Atomic write: temp + rename. A torn checksum would be read
			# as a false-positive corruption by the next verify pass.
			local _tmp="${CHK_PATH}.tmp.$$"
			if printf '%s\n' "$REM_SUM" >"$_tmp"; then
				if mv -f "$_tmp" "$CHK_PATH"; then
					log "VERIFIED: Wrote dated checksum → ${CHK_PATH}"
				else
					log "WARN: Failed to rename checksum into place: $CHK_PATH"
					rm -f "$_tmp" 2>/dev/null || true
				fi
			else
				log "WARN: Failed to write checksum tempfile: $_tmp"
				rm -f "$_tmp" 2>/dev/null || true
			fi
		else
			log "WARN: Could not create checksum dir $CHK_SUBDIR — skipping dated checksum write"
		fi

		# WS4: Retention — delete backups older than WARPHOLE_KEEP_DAYS.
		# Only triggered when KEEP_DAYS > 0; 0 preserves legacy "keep forever".
		if [[ "${WARPHOLE_KEEP_DAYS:-0}" -gt 0 ]]; then
			log "Phase: Rotation (keeping last ${WARPHOLE_KEEP_DAYS} days)"
			local deleted=0
			while IFS= read -r -d '' old; do
				rm -f "$old" && deleted=$((deleted + 1))
				# Also drop the dated checksum sibling we wrote in 4b
				# so the .checksums/ tree doesn't leak orphans. (Auto-
				# backupper's rotation_phase would eventually catch
				# these on the central NAS, but the warphole host
				# itself has no such sweep.)
				local _old_name
				_old_name="$(basename "$old")"
				shopt -s nullglob
				local _old_chk
				for _old_chk in "${CHK_SUBDIR}/${_old_name}"_[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9].sha256; do
					rm -f "$_old_chk"
				done
				shopt -u nullglob
			done < <(find "$FINAL_DEST_DIR" -maxdepth 1 -type f \
				-name "${HOSTNAME_VAR}_pihole_*.zip" \
				-mtime +"$WARPHOLE_KEEP_DAYS" -print0 2>/dev/null)
			if [[ "$deleted" -gt 0 ]]; then
				log "Rotation: removed ${deleted} old backup(s)."
			fi
		fi
	else
		rm -f "$TARGET_TMP" 2>/dev/null || true
		log "FATAL: Failed to copy backup file."
		exit 1
	fi
}

# ==============================================================================
# 4. TARS (HEALTH CHECK)
# ==============================================================================

verify_tailscale_network() {
	if [[ "$CHECK_TAILSCALE" != "true" || -z "$TAILSCALE_PING_IP" ]]; then
		return
	fi

	log "Phase: Checking Tailscale Connectivity..."

	# WS5: Retry a few times before restarting. A single lost packet or
	# transient 5-second blip shouldn't trigger a service restart, because
	# `systemctl restart tailscaled` tears down all active connections.
	local attempts=0 max_attempts=3
	while [[ $attempts -lt $max_attempts ]]; do
		if ping -c 1 -W 5 "$TAILSCALE_PING_IP" &>/dev/null; then
			log "HEALTHY: Tailscale network is reachable ($TAILSCALE_PING_IP)."
			return
		fi
		attempts=$((attempts + 1))
		[[ $attempts -lt $max_attempts ]] && sleep 3
	done

	log "WARNING: Tailscale unreachable after ${max_attempts} attempts. Restarting tailscaled service..."
	# WD8: guard the restart so a host without systemctl (or without the unit) logs
	# a WARNING and continues instead of treating the missing binary as a hard error.
	if command -v systemctl >/dev/null 2>&1 && systemctl restart tailscaled; then
		log "SUCCESS: tailscaled service restarted."
		# Give tailscale time to re-authenticate and re-establish peering
		# (5s was too aggressive — peering can take 10-15s on first attempt).
		sleep 10
		if ping -c 1 -W 5 "$TAILSCALE_PING_IP" &>/dev/null; then
			log "RECOVERY: Tailscale connectivity restored."
		else
			log "ERROR: Restarted service, but Tailscale is still unreachable."
		fi
	else
		log "FATAL: Failed to restart tailscaled service."
	fi
}

run_health_check() {
	log "=== Starting Pi-hole Health Check ==="

	# --- 0. Network / Tailscale Check ---
	verify_tailscale_network
	dlog "post-tailscale (rc=$?)"

	# --- A. Post-Reboot Recovery Check ---
	if [[ -f "$REPAIR_MARKER" ]]; then
		log "RECOVERY: Found repair marker ($REPAIR_MARKER)."
		log "ACTION: System has rebooted. Attempting to pull Gravity now..."

		[[ "$IS_DOCKER" == "true" ]] && { ensure_pihole_running || exit 1; }
		if ! run_gravity_rebuild "post-reboot recovery"; then
			log "ERROR: Recovery gravity rebuild failed (see $GRAVITY_LOG). Leaving repair marker in place."
			exit 1
		fi

		rm -f "$REPAIR_MARKER"
		log "SUCCESS: Recovery gravity pull complete. Marker removed."
		return
	fi
	dlog "post-repair-marker check"

	# WS7: Verify container is up before using the API (which is almost
	# certainly proxied through the container).
	dlog "pre-ensure-pihole-running"
	ensure_pihole_running || exit 1
	dlog "post-ensure-pihole-running"

	# WD2: capture authenticate's rc explicitly so set -e can't make the
	# script vanish silently if anything inside the function returns
	# non-zero — see authenticate() for the full rationale.
	dlog "pre-authenticate"
	local _auth_rc=0
	authenticate || _auth_rc=$?
	dlog "post-authenticate (rc=$_auth_rc, SID is ${SID:+set}${SID:-empty})"

	# Stats Check - Using PADD endpoint as it is comprehensive
	local HEADER_ARG=()
	[[ -n "$SID" ]] && HEADER_ARG=(-H "X-FTL-SID: $SID")

	dlog "pre-curl /padd"
	local STATS_DATA padd_rc=0
	# WS10: --max-time prevents a hung API from hanging the health check
	# (the whole point of which is to detect a hung service).
	# WD3: capture curl's rc instead of letting a BARE assignment abort the whole
	# script under `set -e`. A connection-refused (FTL down, rc 7) or timeout
	# (rc 28) on this command substitution would otherwise kill run_health_check
	# silently — no FATAL, no exit line, the "vanishes right after pre-authenticate"
	# symptom. On failure STATS_DATA stays empty and the empty/invalid-JSON branch
	# below forces the rebuild path, which is the intended behavior.
	STATS_DATA=$(curl -s --max-time 10 -X GET "$PI_URL/padd" "${HEADER_ARG[@]}") || padd_rc=$?
	dlog "post-curl /padd (rc=$padd_rc, response length=${#STATS_DATA} bytes)"
	[[ $padd_rc -ne 0 ]] && log "WARN: /padd curl failed (rc=$padd_rc) — treating API as down."

	# WS9 (revised): empty/invalid JSON used to early-return here, which
	# swallowed the corrupt-DB recovery path — when the DB swap fails badly
	# enough that FTL returns a non-JSON error body (instead of a clean
	# gravity_size: -2), we still want to rebuild. Log the diagnostic and
	# fall through to the regex check below, which treats an empty value
	# as 0 and triggers a rebuild (matching pre-refactor behavior).
	local DOMAINS_COUNT RAW_GRAVITY
	if [[ -z "$STATS_DATA" ]] || ! echo "$STATS_DATA" | jq -e . >/dev/null 2>&1; then
		log "WARN: API returned empty/invalid JSON — treating as corrupt-DB and forcing rebuild."
		RAW_GRAVITY="<invalid>"
		DOMAINS_COUNT=0
	else
		# WS16: capture the raw value too so the diagnostic log can distinguish
		# null (DB unreachable) from -2 (corrupt swap) from a true 0.
		RAW_GRAVITY=$(echo "$STATS_DATA" | jq -r '.gravity_size')
		DOMAINS_COUNT=$(echo "$STATS_DATA" | jq -r '.gravity_size // 0')
	fi

	# WD4: Distinguish "API requires auth" from "gravity DB is empty/corrupt". If
	# this box has a Pi-hole password but PI_PASSWORD is empty/wrong, /padd returns
	# a 401 JSON error body ({"error":{"key":"unauthorized",...}}) with curl rc=0,
	# so the WD3 guard above does NOT catch it. Without this, that error body parses
	# to gravity_size=null//0 and we would destructively rebuild gravity — and on a
	# low-RAM bare-metal box, REBOOT — on EVERY check run. Surface it instead.
	if [[ "$RAW_GRAVITY" != "<invalid>" ]] && echo "$STATS_DATA" | jq -e '.error' >/dev/null 2>&1; then
		log "ERROR: /padd returned an API error: $(echo "$STATS_DATA" | jq -rc '.error' 2>/dev/null)."
		log "       Pi-hole requires authentication but PI_PASSWORD is empty/wrong. NOT rebuilding gravity."
		log "       Set PI_PASSWORD (ideally in ${SECRETS_FILE}, mode 600) to this box's API password."
		return 0
	fi

	# Validate Integer (Catches API returning "-2" for corrupt DBs)
	if ! [[ "$DOMAINS_COUNT" =~ ^[0-9]+$ ]]; then
		log "ERROR: Invalid API response (gravity_size=$RAW_GRAVITY). Forcing gravity update..."
		DOMAINS_COUNT=0
	fi

	if [[ "$DOMAINS_COUNT" -le 0 ]]; then
		log "CRITICAL: 0 domains blocked (gravity_size=$RAW_GRAVITY). Triggering gravity update..."

		# WS16: rebuild routes its (huge) output to $GRAVITY_LOG, not the
		# script's stdout — see run_gravity_rebuild for why.
		run_gravity_rebuild "initial" || true

		log "Phase: Verifying gravity rebuild via API..."
		sleep 3 # Give FTL a moment to swap databases and settle

		local NEW_STATS_DATA NEW_DOMAINS_COUNT
		# WS10: timeout on the re-check curl too.
		# WD3: same set -e guard as the initial /padd fetch — during a rebuild the
		# FTL API socket is briefly down, so this curl can return rc 7/28; without
		# `|| true` that bare assignment would abort the script mid-verification.
		NEW_STATS_DATA=$(curl -s --max-time 10 -X GET "$PI_URL/padd" "${HEADER_ARG[@]}") || true

		# WS9: same validity check for the verification call.
		if [[ -z "$NEW_STATS_DATA" ]] || ! echo "$NEW_STATS_DATA" | jq -e . >/dev/null 2>&1; then
			log "WARN: API unreachable during gravity verification. Assuming rebuild failed."
			NEW_DOMAINS_COUNT=0
		else
			NEW_DOMAINS_COUNT=$(echo "$NEW_STATS_DATA" | jq -r '.gravity_size // 0')
		fi

		# Validate the new count
		if ! [[ "$NEW_DOMAINS_COUNT" =~ ^[0-9]+$ ]]; then
			NEW_DOMAINS_COUNT=0
		fi

		local GRAVITY_SUCCESS=false
		if [[ "$NEW_DOMAINS_COUNT" -gt 0 ]]; then
			GRAVITY_SUCCESS=true
		fi

		if [[ "$GRAVITY_SUCCESS" == "true" ]]; then
			log "SUCCESS: Gravity rebuild successful ($NEW_DOMAINS_COUNT domains active)."
		else
			log "FATAL: Gravity rebuild FAILED or database is corrupt (Count: $NEW_DOMAINS_COUNT)."

			# --- Conditional Repair Logic ---
			local TOTAL_RAM_MB
			TOTAL_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')

			# WS2: Docker repair path. Previously, this branch only handled
			# low-RAM bare-metal via reboot — for Docker users (the majority)
			# it just logged a warning and exit 1. Now: restart the pihole
			# container to clear its state, wait for readiness, and retry
			# gravity once. If that still fails, surface the problem.
			if [[ "$IS_DOCKER" == "true" ]]; then
				log "ACTION: Restarting pihole container to clear its state..."
				if ! docker restart "$DOCKER_CONTAINER_NAME" >/dev/null 2>&1; then
					log "ERROR: docker restart failed. Manual intervention needed."
					exit 1
				fi

				# Wait for the container to be marked Running again (up to 60s).
				local waited=0
				while [[ $waited -lt 60 ]]; do
					if ensure_pihole_running 2>/dev/null; then break; fi
					sleep 2
					waited=$((waited + 2))
				done
				if ! ensure_pihole_running 2>/dev/null; then
					log "ERROR: Container did not return to Running state within 60s."
					exit 1
				fi
				# Give FTL itself a few extra seconds to open its API socket.
				sleep 5

				# WS16: same redirection as the initial rebuild — keeps
				# the post-restart firehose off the script's stdout.
				run_gravity_rebuild "post-restart retry" || true
				sleep 3

				# Re-authenticate (session SID does not survive FTL restart)
				# and re-verify via the API.
				SID=""
				authenticate
				local RETRY_HDR=()
				[[ -n "$SID" ]] && RETRY_HDR=(-H "X-FTL-SID: $SID")

				local RETRY_STATS RETRY_COUNT=0
				# WD3: set -e guard — FTL may still be reloading after the restart.
				RETRY_STATS=$(curl -s --max-time 10 -X GET "$PI_URL/padd" "${RETRY_HDR[@]}") || true
				if [[ -n "$RETRY_STATS" ]] && echo "$RETRY_STATS" | jq -e . >/dev/null 2>&1; then
					RETRY_COUNT=$(echo "$RETRY_STATS" | jq -r '.gravity_size // 0')
					[[ "$RETRY_COUNT" =~ ^[0-9]+$ ]] || RETRY_COUNT=0
				fi

				if [[ "$RETRY_COUNT" -gt 0 ]]; then
					log "RECOVERY: Container restart + gravity rebuild succeeded ($RETRY_COUNT domains active)."
				else
					log "FATAL: Container restart did not fix gravity (Count: $RETRY_COUNT). Manual intervention needed."
					exit 1
				fi
			elif [[ "$TOTAL_RAM_MB" -lt 1024 ]]; then
				log "ACTION: Low memory bare-metal system ($TOTAL_RAM_MB MB). Rebooting to clear RAM for gravity..."
				touch "$REPAIR_MARKER"
				/sbin/reboot || systemctl reboot || log "FATAL: Could not trigger reboot."
				exit 0
			else
				log "WARNING: Skipping repair (bare-metal with sufficient RAM — reboot heuristic doesn't apply)."
				exit 1
			fi
		fi
	else
		log "HEALTHY: Gravity looks good ($DOMAINS_COUNT domains)."
	fi
}

# ==============================================================================
# 5. WARP-CORE (STATS DASHBOARD)
# ==============================================================================

# Draw a horizontal line
draw_line() {
	printf "%b%*s%b\n" "${GRAY}" "${COLUMNS:-$(tput cols)}" '' "${NC}" | tr ' ' '-'
}

# Generate ASCII Bar
# Usage: draw_bar <percent> <width> <color_code>
draw_bar() {
	local pct=$1
	local width=$2
	local color=$3

	local filled
	# Use awk to calculate width and handle capping > 100% (No bc required)
	filled=$(awk -v p="$pct" -v w="$width" 'BEGIN { if(p>100) p=100; printf "%.0f", (p/100)*w }')

	local empty=$((width - filled))

	printf "%b[" "${color}"
	# SC2086: Double quote to prevent globbing
	printf "%0.s|" $(seq 1 "$filled" 2>/dev/null)
	printf "%0.s." $(seq 1 "$empty" 2>/dev/null)
	printf "]%b" "${NC}"
}

trigger_gravity_bg() {
	# WS3: use pidfile-based detection instead of fragile pgrep -f.
	if is_gravity_running; then return; fi
	# WC4: Drop `sudo` (script already enforces root at startup) and branch on
	# IS_DOCKER so the dashboard's "u" key actually triggers a rebuild when
	# pihole runs in a container — mirroring run_health_check's logic.
	local gpid
	if [[ "$IS_DOCKER" == "true" ]]; then
		nohup docker exec "$DOCKER_CONTAINER_NAME" pihole -g >"$GRAVITY_LOG" 2>&1 &
		gpid=$!
	else
		nohup pihole -g >"$GRAVITY_LOG" 2>&1 &
		gpid=$!
	fi
	# WS3: record the pid so subsequent status checks don't have to guess.
	echo "$gpid" >"$GRAVITY_PIDFILE" 2>/dev/null || true
}

run_stats() {
	# WS6: Relax strict mode for the dashboard. `set -Eeuo pipefail` at
	# the top of the script is correct for backup/check — they should
	# fail fast. But the stats dashboard runs `while true` over inherently
	# flaky network I/O (curl to the pihole API, jq against its output).
	# A single lost packet or a brief FTL reload should not kill the UI.
	set +e
	trap - ERR

	# WM3: Validate REFRESH_RATE is a positive integer — it's used as the
	# timeout arg to `read -t` inside the loop, and a non-numeric value
	# there would error out read, which (even with set +e) would leave
	# the dashboard non-interactive. Fall back to 2 with a visible notice.
	if ! [[ "$REFRESH_RATE" =~ ^[0-9]+$ ]] || [[ "$REFRESH_RATE" -lt 1 ]]; then
		echo "WARN: REFRESH_RATE='$REFRESH_RATE' is not a positive integer, defaulting to 2."
		REFRESH_RATE=2
		sleep 2
	fi

	# Setup Terminal
	tput civis 2>/dev/null || true
	authenticate

	# WM4: One-shot PADD schema drift check. If a future pihole upgrade
	# renames fields, the dashboard would silently show 0 for every metric.
	# This prints a warning BEFORE `clear` kicks in, so the user sees why
	# their dashboard looks wrong.
	local _HEADER_ARG=()
	[[ -n "$SID" ]] && _HEADER_ARG=(-H "X-FTL-SID: $SID")
	local _probe
	_probe=$(curl -s --max-time 5 -X GET "$PI_URL/padd" "${_HEADER_ARG[@]}")
	if [[ -n "$_probe" ]] && echo "$_probe" | jq -e . >/dev/null 2>&1; then
		local _missing=()
		local _f
		for _f in '.queries.total' '.gravity_size' '.system.cpu.load.raw' '.system.memory.ram.used' '.sensors.cpu_temp'; do
			if [[ "$(echo "$_probe" | jq -r "$_f // empty" 2>/dev/null)" == "" ]]; then
				_missing+=("$_f")
			fi
		done
		if [[ ${#_missing[@]} -gt 0 ]]; then
			echo ""
			echo "WARN: PADD schema drift detected — missing fields:"
			for _f in "${_missing[@]}"; do echo "        $_f"; done
			echo "      Dashboard will show 0 for those metrics. Starting in 3s..."
			sleep 3
		fi
	fi

	local PREV_QUERIES=0
	local FIRST_RUN=true
	local GRAVITY_STATUS=""
	local GRAVITY_MSG=""

	while true; do
		# --- 1. Fetch ALL Data from /padd ---
		local HEADER_ARG=()
		[ -n "$SID" ] && HEADER_ARG=(-H "X-FTL-SID: $SID")

		local JSON
		# WS10: short max-time keeps refresh snappy if the API hangs; a
		# transient empty response is preferable to a frozen dashboard.
		JSON=$(curl -s --max-time 3 -X GET "$PI_URL/padd" "${HEADER_ARG[@]}")

		# --- 2. Extract Data (One Pass Logic) ---

		# > Network & Blocking
		local TOTAL_QUERIES BLOCKED_COUNT PERCENT_BLOCKED DOMAINS_IN_GRAVITY CLIENTS
		TOTAL_QUERIES=$(echo "$JSON" | jq -r '.queries.total // 0')
		BLOCKED_COUNT=$(echo "$JSON" | jq -r '.queries.blocked // 0')
		PERCENT_BLOCKED=$(echo "$JSON" | jq -r '.queries.percent_blocked // 0')
		DOMAINS_IN_GRAVITY=$(echo "$JSON" | jq -r '.gravity_size // 0')
		CLIENTS=$(echo "$JSON" | jq -r '.active_clients // 0')

		# > Top Lists
		local TOP_BLOCKED RECENT_BLOCKED TOP_DOMAIN
		TOP_BLOCKED=$(echo "$JSON" | jq -r '.top_blocked // "None"')
		RECENT_BLOCKED=$(echo "$JSON" | jq -r '.recent_blocked // "Waiting..."')
		TOP_DOMAIN=$(echo "$JSON" | jq -r '.top_domain // "None"')

		# > System Stats (From API, not Shell)
		local LOAD_RAW MEM_USED_KB MEM_TOTAL_KB MEM_PCT CPU_TEMP
		# Schema: system.cpu.load.raw[0] is 1-min load
		LOAD_RAW=$(echo "$JSON" | jq -r '.system.cpu.load.raw[0] // 0')
		# Schema: system.memory.ram.used (KB)
		MEM_USED_KB=$(echo "$JSON" | jq -r '.system.memory.ram.used // 0')
		MEM_TOTAL_KB=$(echo "$JSON" | jq -r '.system.memory.ram.total // 0')
		MEM_PCT=$(echo "$JSON" | jq -r '.system.memory.ram["%used"] // 0')
		# Schema: sensors.cpu_temp
		CPU_TEMP=$(echo "$JSON" | jq -r '.sensors.cpu_temp // 0')

		# Convert Memory KB -> MB for display
		local MEM_USED_MB MEM_TOTAL_MB
		MEM_USED_MB=$((MEM_USED_KB / 1024))
		MEM_TOTAL_MB=$((MEM_TOTAL_KB / 1024))

		# --- 3. Calculate QPS ---
		local QPS=0
		if [ "$FIRST_RUN" = true ]; then
			FIRST_RUN=false
		else
			local DIFF=$((TOTAL_QUERIES - PREV_QUERIES))
			if [ $DIFF -lt 0 ]; then DIFF=0; fi
			QPS=$(awk -v d="$DIFF" -v r="$REFRESH_RATE" 'BEGIN {printf "%.1f", d/r}')
		fi
		PREV_QUERIES=$TOTAL_QUERIES

		# --- 4. Check Gravity Status ---
		# WS3: pidfile-based detection — avoids false positives from any
		# command line that happens to contain "pihole -g" (vim, grep, etc.)
		if is_gravity_running; then
			GRAVITY_STATUS="${YELLOW}⚡ UPDATING${NC}"
			local LAST_LOG
			LAST_LOG=$(tail -n 1 "$GRAVITY_LOG" 2>/dev/null | cut -c1-40)
			GRAVITY_MSG="Log: ${LAST_LOG}..."
		else
			GRAVITY_STATUS="${GREEN}✔ READY${NC}"
			GRAVITY_MSG="Recent: ${RECENT_BLOCKED}"
		fi

		# --- 5. Draw UI ---
		clear
		echo -e "${BLUE} __      __              ${CYAN}  _____                ${NC}"
		echo -e "${BLUE} \ \    / /_ _ _ _ _ __  ${CYAN} / ___/___ _ ___ ___   ${NC}"
		echo -e "${BLUE}  \ \/\/ / _\`| '_| '_ \ ${CYAN}| |___/ _ \| '__/ _ \  ${NC}  ${GREEN}${HOSTNAME_LAB}${NC}"
		echo -e "${BLUE}   \_/\_/\__,_|_| | .__/ ${CYAN} \____\___/|_|  \__\   ${NC}  $(date '+%H:%M:%S')"
		echo -e "${BLUE}                  |_|    ${CYAN}                       ${NC}"

		draw_line

		# Row 1: Core Stats
		printf " ${CYAN}%-20s${NC} | ${CYAN}%-20s${NC} | ${CYAN}%-20s${NC}\n" "QUERIES (QPS)" "BLOCKED" "BLOCK PERCENT"
		printf " ${GREEN}%-20s${NC} | ${RED}%-20s${NC} | ${YELLOW}%-20s${NC}\n" "$TOTAL_QUERIES ($QPS/s)" "$BLOCKED_COUNT" "${PERCENT_BLOCKED}%"
		# Bar Chart
		printf " %-20s | %-20s | %s\n" "" "" "$(draw_bar "${PERCENT_BLOCKED%.*}" 20 "$YELLOW")"

		echo ""

		# Row 2: System & Network
		# Create a single string for memory to ensure correct padding
		local MEM_STR="${MEM_USED_MB} / ${MEM_TOTAL_MB} MB"

		printf " ${CYAN}%-20s${NC} | ${CYAN}%-20s${NC} | ${CYAN}%-20s${NC}\n" "SYSTEM LOAD" "MEMORY USAGE" "HEALTH"
		printf " ${GREEN}%-20s${NC} | ${GREEN}%-20s${NC} | ${GRAY}Temp:${NC} %s°C  ${GRAY}Clients:${NC} %s\n" "$LOAD_RAW" "$MEM_STR" "$CPU_TEMP" "$CLIENTS"

		# Bar Chart (Width set to 18 so [18] = 20 chars total, matching header)
		printf " %-20s | %s | %-20s\n" "" "$(draw_bar "${MEM_PCT%.*}" 18 "$GREEN")" ""

		echo ""
		draw_line

		# Row 3: Insights
		echo -e " ${CYAN}DOMAINS IN GRAVITY:${NC}  $DOMAINS_IN_GRAVITY"
		echo -e " ${CYAN}TOP DOMAIN:${NC}          $TOP_DOMAIN"
		echo -e " ${CYAN}TOP BLOCKED:${NC}         ${RED}$TOP_BLOCKED${NC}"
		echo -e " ${CYAN}GRAVITY STATUS:${NC}      $GRAVITY_STATUS"
		echo -e " ${GRAY}$GRAVITY_MSG${NC}"

		draw_line
		echo -e " [${CYAN}u${NC}] Update Gravity   [${CYAN}q${NC}] Quit"

		# --- 6. Input Loop ---
		if read -r -t "$REFRESH_RATE" -n 1 key; then
			if [[ "$key" == "q" ]]; then break; fi
			if [[ "$key" == "u" ]]; then trigger_gravity_bg; fi
		fi
	done
}

# ==============================================================================
# 6. EXECUTION
# ==============================================================================

# WM6: Short-circuit --help / -h BEFORE check_deps runs. A user trying to
# learn what the script does shouldn't be blocked by a dependency check —
# and on minimal systems, `jq` / `mount.cifs` / etc. may legitimately be
# absent when the user just wants to read the help text. Move print_usage
# above check_deps and handle the flag inline here.
print_usage() {
	cat <<EOF
Usage: $0 [OPTIONS]

Primary modes:
  --backup-now    Run Pi-hole Teleporter backup and offload to destination
  --check         Run health check (gravity + optional Tailscale)
  --stats         Launch terminal dashboard
  --help, -h      Show this help

Advanced (debugging and testing backups):
  --mount-only    Mount SMB share only (holds the mount; skips unmount on exit)
  --unmount-only  Unmount SMB share only
  --keep-local    Keep temp staging files (debug)

Configure DEFAULT_MODE in the script to run without flags.
EOF
}

for _arg in "$@"; do
	if [[ "$_arg" == "--help" || "$_arg" == "-h" ]]; then
		print_usage
		exit 0
	fi
done
unset _arg

check_deps

# Handle Arguments & Default Mode
# Unraid User Scripts invokes the script with a single empty-string arg, so
# treat that the same as no args — otherwise the case below falls through to
# `*)` and prints "Unknown argument:" with nothing after the colon.
if [[ $# -eq 0 || ( $# -eq 1 && -z "${1:-}" ) ]]; then
	if [[ -n "$DEFAULT_MODE" ]]; then
		MODE="$DEFAULT_MODE"
	else
		print_usage
		exit 1
	fi
else
	while [[ $# -gt 0 ]]; do
		case $1 in
		--backup-now) MODE="backup" ;;
		--check) MODE="check" ;;
		--stats) MODE="stats" ;;
		--help | -h)
			print_usage
			exit 0
			;;
		--mount-only)
			# WC1: mounting mutates system state; take the lock so we don't
			# race a concurrent backup that's also trying to mount/unmount.
			acquire_lock
			mount_smb
			MANAGE_MOUNT=false
			exit 0
			;;
		--unmount-only)
			if mountpoint -q "$MOUNT_POINT"; then umount "$MOUNT_POINT"; fi
			exit 0
			;;
		--keep-local) KEEP_LOCAL=true ;;
		*)
			echo "Unknown argument: $1"
			echo ""
			print_usage
			exit 1
			;;
		esac
		shift
	done
fi

# Route Execution
# WC1: Acquire exclusive lock for mutating modes. Stats is read-only so
# it's allowed to run concurrently with a scheduled backup or health check.
case "$MODE" in
backup)
	acquire_lock
	run_backup
	;;
check)
	acquire_lock
	run_health_check
	;;
stats) run_stats ;;
*)
	echo "Invalid mode selected."
	exit 1
	;;
esac