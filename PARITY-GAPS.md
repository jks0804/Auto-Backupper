

# ===== warphole =====

BASH: Warphole (Enclave Edition) is a comprehensive Pi-hole management suite combining Teleporter backup, health monitoring with conditional repair, and a real-time stats dashboard. It supports both Docker and bare-metal Pi-hole, SMB and local backup destinations, Tailscale network verification, backup retention policies, and extensive safety features including locking, atomic writes, checksum verification, and low-RAM reboot recovery. The script includes sophisticated logging with rotation, API error handling, and a terminal UI dashboard.

PYTHON: Python port exists at warphole.py (430 lines). It implements basic versions of backup, health check, and stats modes with argparse CLI, requests-based API calls, and rich-based terminal UI. The port omits logging infrastructure, file locking, security hardening, backup retention, docker state verification, comprehensive error handling, Tailscale support, and many edge-case safety checks that are present in bash.

VERIFIED GAPS: 51 (high=16 med=16 low=19); false-positives dropped: 6

CLI flags python lacks/partial:
  - --mount-only (no): Mount SMB share only (holds the mount; skips unmount on exit)
  - --unmount-only (no): Unmount SMB share only

GAPS:
  [HIGH] Atomic backup write via temp file + rename (status=missing, effort=small) [analysis]
      bash: run_backup() writes to TARGET_TMP first, then atomically renames to TARGET_PATH. Guarantees observers see either old file or complete new one, never partial. Lines 629-634.
      py:   Python uses shutil.copy2() directly to final destination; no temp file intermediate; vulnerable to mid-copy failures leaving truncated files on network FS.
      loc:  lines 629-634 (cp && mv pattern)
  [HIGH] Container restart with readiness wait and FTL socket wait (status=missing, effort=medium) [analysis]
      bash: run_health_check() on Docker gravity rebuild failure: docker restart, loop up to 60s checking if container running, extra 5s wait for FTL API socket, then retry gravity. Lines 934-957.
      py:   Python run_health_check() has no restart logic for Docker; just exits on rebuild failure.
      loc:  lines 934-957 (Docker repair path)
  [HIGH] Dated checksums written to .checksums/ subdirectory tree (status=missing, effort=medium) [analysis]
      bash: run_backup() writes ${TARGET_NAME}_${CDATE}.sha256 to .checksums/${SMB_SUBFOLDER}/ after backup; sweeps stale dated siblings via nullglob pattern; uses atomic temp+rename for checksum file. auto-backupper's pull-side reads discovery date from this suffix. Lines 663-714.
      py:   Python calculates SHA256 for verification only; does not write dated checksums to .checksums/ tree; upstream auto-backupper cannot infer backup age.
      loc:  lines 663-714 (entire dated checksum block)
  [HIGH] Exclusive flock-based locking for mutating operations (status=missing, effort=medium) [analysis]
      bash: acquire_lock() opens LOCKFILE (/var/lock/warphole.lock) and acquires exclusive flock (non-blocking). Returns 0 if acquired, exits with message if held by another process. Allows concurrent stats (read-only). Lines 261-273.
      py:   No locking mechanism; backup and check modes can run concurrently, risking state corruption.
      loc:  lines 261-273, acquire_lock(); lines 1298-1306 (route execution with lock)
  [HIGH] Interactive stats dashboard with u=update gravity, q=quit (status=missing, effort=medium) [analysis]
      bash: run_stats() main loop uses read -r -t REFRESH_RATE -n 1 key to check for keypresses; u triggers background gravity via trigger_gravity_bg(); q breaks loop. Lines 1204-1207.
      py:   Python stats mode has no keyboard input handling; only exits on KeyboardInterrupt (Ctrl+C).
      loc:  lines 1204-1207 (input handling block)
  [HIGH] Log file rotation with copytruncate strategy (status=missing, effort=medium) [analysis]
      bash: rotate_logs() and rotate_log_if_needed() implement copytruncate rotation (copy then truncate, not move-based) with configurable LOG_MAX_SIZE and LOG_BACKUPS, detecting via stat command with platform-specific branches (Darwin -f%z vs Linux -c%s). Rotation preserves tee FD. Lines 184-220.
      py:   Python log() appends to file without rotation. No rotation mechanism, no max-size checks, no log backup cycling.
      loc:  lines 184-220, rotate_logs() and rotate_log_if_needed()
  [HIGH] Pidfile-based gravity update detection (avoids pgrep -f false positives) (status=missing, effort=medium) [analysis]
      bash: is_gravity_running() checks if GRAVITY_PIDFILE (/tmp/warphole_gravity.pid) exists and if pid is alive; trigger_gravity_bg() records background gravity pid; nohup pihole -g in background, writes pid to file. Lines 280-290, 1025-1041.
      py:   No pidfile tracking; no is_gravity_running() function; no background gravity trigger; stats dashboard cannot detect in-progress gravity updates.
      loc:  lines 280-290 (is_gravity_running), 96 (GRAVITY_PIDFILE), 1025-1041 (trigger_gravity_bg)
  [HIGH] Redirect pihole -g output to GRAVITY_LOG instead of script stdout (status=missing, effort=small) [analysis]
      bash: run_gravity_rebuild() routes full pihole -g output to $GRAVITY_LOG file, not script stdout; logs only one-line summary + 3-line tail. Avoids OOM/SIGPIPE from tee on low-memory hosts. Lines 480-492.
      py:   Python subprocess.run(['pihole', '-g']) streams output to stdout; not routed to GRAVITY_LOG; vulnerable to OOM on low-RAM hosts.
      loc:  lines 480-492 (run_gravity_rebuild function), 467-477 (explanation comment)
  [HIGH] Restrict log file to root-only (mode 600) (status=missing, effort=small) [analysis]
      bash: Lines 163, 213-214: chmod 600 on logfile and backups to prevent world-readable secrets.
      py:   Python log() does not set file permissions; logfile may be world-readable.
      loc:  lines 163, 213-214
  [HIGH] SMB credentials via temp file (mode 0600) to avoid ps leakage (status=divergent, effort=small) [analysis]
      bash: mount_smb() creates temporary credentials file with mktemp, sets mode 0600, writes user/pass, passes to mount.cifs, then shreds/removes file (or falls back to rm if shred unavailable). Prevents password visibility in ps output. Lines 436-457.
      py:   Python passes SMB_USER and SMB_PASS directly as -o mount options (line 145), exposing password in ps output during mount call.
      loc:  lines 436-457 (mktemp/shred credentials workflow)
  [HIGH] Secrets file sourcing with permission warnings (status=missing, effort=?) [verify-missed]
      bash: SECRETS_FILE loading at bash lines 132-144 sources external /etc/warphole/secrets.env with configurable path via WARPHOLE_SECRETS_FILE env var, warns on permission drift (mode != 600/400), and allows all config overrides via that file. Python has no equivalent.
      py:   (missed by analyzer)
      loc:  lines 132-144, SECRETS_FILE sourcing block
  [HIGH] Source secrets.env to override defaults (e.g., SMB_HOST, SMB_SHARE, PI_PASSWORD) (status=missing, effort=medium) [analysis]
      bash: Lines 131-144: Source SECRETS_FILE if it exists; any assignment there overrides config above it.
      py:   Python CONFIG is static dict; no secrets.env sourcing; credentials must be edited in script or via hardcoded placeholder dict.
      loc:  lines 131-144 (SECRETS_FILE sourcing block)
  [HIGH] Time-based backup retention (WARPHOLE_KEEP_DAYS) (status=missing, effort=medium) [analysis]
      bash: run_backup() if WARPHOLE_KEEP_DAYS > 0: find files older than N days and delete them; also sweeps stale dated checksums for each deleted file via nullglob pattern. Lines 716-742.
      py:   No WARPHOLE_KEEP_DAYS config variable; no find/mtime logic; backups accumulate indefinitely.
      loc:  lines 716-742 (rotation_phase block), 75 (WARPHOLE_KEEP_DAYS default)
  [HIGH] Verify gravity rebuild success by re-checking API (status=partial, effort=large) [analysis]
      bash: run_health_check() after rebuilding: sleep 3, re-fetch /padd, verify gravity_size > 0; if still 0: on Docker restart container + retry, on bare-metal low-RAM reboot. Lines 892-990.
      py:   Python calls pihole -g but does not re-verify via API. Does not have the docker restart logic or the retry flow.
      loc:  lines 892-990 (verification and conditional repair block)
  [HIGH] Verify post-gravity-rebuild with sleep and re-check (status=partial, effort=?) [verify-missed]
      bash: run_health_check() at bash lines 893-957 sleeps 3s after rebuild, re-fetches /padd to verify gravity_size > 0, with conditional repair (docker restart or bare-metal reboot). Python run_health_check() just runs pihole -g and continues.
      py:   (missed by analyzer)
      loc:  lines 893-957, gravity rebuild verification and repair block
  [HIGH] Warnings for lax permissions on secrets.env (status=missing, effort=medium) [analysis]
      bash: On startup: stat secrets.env for permissions and owner; warn if mode != 600/400 or owner != root; source the file anyway. Lines 132-144.
      py:   No secrets.env file support; no permission checks; credentials hardcoded in CONFIG dict with placeholder values.
      loc:  lines 132-144 (SECRETS_FILE loading block)
  [MEDIUM] Clean up container-side file even if docker cp fails (status=missing, effort=small) [analysis]
      bash: Lines 588-595: if docker cp fails, still clean up the container-side zip before exiting (rm -f so missing doesn't trip set -e).
      py:   Python backup uses check=True, which will raise exception; no explicit cleanup of container file on failure.
      loc:  lines 588-595 (WS12 docker cp cleanup)
  [MEDIUM] Display in-progress gravity status via pidfile + tail of GRAVITY_LOG (status=missing, effort=small) [analysis]
      bash: run_stats() checks is_gravity_running(); if true, displays YELLOW '⚡ UPDATING' and last 40 chars of GRAVITY_LOG tail; else displays GREEN '✔ READY'. Lines 1149-1160.
      py:   Python stats does not display gravity status; no pidfile check; no GRAVITY_LOG tail.
      loc:  lines 1149-1160 (gravity status display block)
  [MEDIUM] Distinguish 401 unauthorized from corrupt gravity DB (status=missing, effort=small) [analysis]
      bash: run_health_check() checks if response has .error key; if it does and gravity_size is not '<invalid>', assumes 401 and logs that PI_PASSWORD is wrong instead of rebuilding. Lines 872-877.
      py:   Python just treats empty/invalid JSON as 'gravity_size=0' and rebuilds; does not check for .error key or distinguish auth failure.
      loc:  lines 872-877 (error distinction block)
  [MEDIUM] Fast-fail check for empty SMB credentials (status=missing, effort=small) [analysis]
      bash: mount_smb() checks if SMB_USER or SMB_PASS is empty; logs FATAL message directing user to set them in secrets.env; exits cleanly instead of letting mount.cifs return cryptic 'mount error(13)'. Lines 406-414.
      py:   No credential validation; mount attempt will fail with uninformative error.
      loc:  lines 406-414 (credentials validation block)
  [MEDIUM] Full terminal TUI with colored ASCII art, bars, and live updates (status=partial, effort=medium) [analysis]
      bash: run_stats() uses tput, seq, draw_line(), draw_bar(); renders logo, metrics table, bar charts in color; refreshes every REFRESH_RATE seconds. Lines 1043-1209.
      py:   Python uses rich.Live for TUI but lacks ASCII art logo, bar charts, gravity status display, and interactive key handling (u/q).
      loc:  lines 1000-1209 (run_stats and drawing functions)
  [MEDIUM] HOSTNAME_VAR uppercased to avoid backup name case drift (status=missing, effort=small) [analysis]
      bash: Lines 32: hostname | cut -d. -f1 | tr '[:lower:]' '[:upper:]' ensures canonical casing (rationale: pulls can reconcile duplicates like HOST_pihole_ and host_pihole_). Config can override in secrets.env.
      py:   Line 18: socket.gethostname().split('.')[0] — no uppercasing. HOSTNAME_VAR may have lowercase/mixed case, causing case-drift duplicates in backup names.
      loc:  lines 32-36 (HOSTNAME_VAR normalization block)
  [MEDIUM] Pre-check docker container state before exec (status=missing, effort=?) [verify-missed]
      bash: ensure_pihole_running() at bash lines 497-511 uses 'docker inspect --format {{.State.Running}}' to verify container before docker exec. Python subprocess.run(['docker', 'exec', ...]) has no pre-check.
      py:   (missed by analyzer)
      loc:  lines 497-511, ensure_pihole_running function
  [MEDIUM] Proper cleanup order: temp files, mounts, auth session, terminal reset (status=divergent, effort=small) [analysis]
      bash: cleanup() at lines 293-323 follows order: remove temp files, unmount share (with umount -l fallback), DELETE /auth session (with 5s timeout), reset terminal. Exit trap ensures runs.
      py:   Python cleanup() order at 156-170 is different (temp, umount, auth); no timeout on auth delete; no terminal reset.
      loc:  lines 293-323 (cleanup function)
  [MEDIUM] Robust pihole-FTL --teleporter filename extraction with fallbacks (status=divergent, effort=small) [analysis]
      bash: run_backup() parses FTL output for _teleporter_.zip pattern, falls back to any .zip, strips whitespace/carriage returns, confirms file exists in container before docker cp. Lines 555-585.
      py:   Python uses `ls -t /tmp/*.zip | head -n1` approach (line 214-219); does not match the robust parsing or confirm file exists. Vulnerable to stale zips from crashed runs.
      loc:  lines 555-585 (DOCKER_FILE extraction block)
  [MEDIUM] Strict error handling with set -Eeuo pipefail and trap EXIT (status=missing, effort=small) [analysis]
      bash: Lines 15: set -Eeuo pipefail ensures script fails fast on error, pipe failures, or unset vars. trap 'cleanup' EXIT (line 324) ensures cleanup runs even on error. Relaxed to set +e in stats mode (line 1049) for flaky network I/O.
      py:   Python has no equivalent strict error mode; uses try/except in limited places; no guarantee cleanup runs on exception.
      loc:  lines 15, 324, 1049-1050
  [MEDIUM] Tailscale connectivity verification with retry and service restart (status=missing, effort=medium) [analysis]
      bash: verify_tailscale_network() if CHECK_TAILSCALE=true: ping TAILSCALE_PING_IP up to 3 times with 3s between retries; on failure: systemctl restart tailscaled (guarded, non-fatal), 10s wait, re-ping, log recovery/error. Lines 754-790.
      py:   No tailscale verification; no CHECK_TAILSCALE config; no ping retry logic; no systemctl integration.
      loc:  lines 754-790 (verify_tailscale_network function), 78-79 (config), 341 (deps)
  [MEDIUM] Unzip integrity check with auto-cleanup (status=missing, effort=?) [verify-missed]
      bash: run_backup() at bash lines 654-661 runs 'unzip -tq' on backup after writing and deletes corrupted file if check fails. Provides defense-in-depth against corrupt ZIPs written to disk.
      py:   (missed by analyzer)
      loc:  lines 654-661, unzip -tq verification block
  [MEDIUM] Verbosity-based log filtering (error/phase/info/debug levels) (status=missing, effort=small) [analysis]
      bash: _log_verbosity_threshold() returns numeric thresholds (2=error, 3=phase, 4=info, 99=debug); _log_level_for() detects message prefix to classify level (FATAL/CRITICAL/ERROR/WARN, ACTION/SUCCESS/VERIFIED, DEBUG:, etc.); log() only prints if message level <= threshold. Lines 224-253.
      py:   Python log() function prints all messages unconditionally; no LOG_VERBOSITY config variable; no level detection or filtering.
      loc:  lines 224-253, _log_verbosity_threshold() and _log_level_for()
  [MEDIUM] Verify Docker container is running before docker exec (status=missing, effort=small) [analysis]
      bash: ensure_pihole_running() uses docker inspect --format to check container state; exits with FATAL if not running. Called before docker exec and API calls. Lines 497-511.
      py:   Python docker exec commands have no pre-check; will produce cryptic 'container not running' errors if container stopped.
      loc:  lines 497-511 (ensure_pihole_running function), 551, 804, 819 (usage)
  [MEDIUM] Verify mount source matches expected share after mounting (status=missing, effort=small) [analysis]
      bash: mount_smb() if mount point already mounted: uses findmnt to get SOURCE and verifies it matches //$SMB_HOST/$SMB_SHARE; fails if different (e.g., another share was mounted there). Lines 418-429.
      py:   Python checks only os.path.ismount(); does not verify the mount source matches expected share.
      loc:  lines 418-429 (findmnt verification block)
  [MEDIUM] ZIP file integrity verification via unzip -t (status=missing, effort=small) [analysis]
      bash: run_backup() runs unzip -tq on TARGET_PATH to verify internal structure; logs error and deletes corrupted file if check fails. Lines 654-661.
      py:   No ZIP integrity check; corrupted archives are not detected post-backup.
      loc:  lines 654-661 (unzip -tq verification block)
  [LOW] ASCII bar chart rendering with percentage-based fill (status=missing, effort=small) [analysis]
      bash: draw_bar() uses awk to calculate filled width; renders with | for filled, . for empty, handles > 100% capping. Lines 1007-1023.
      py:   Python stats does not render bar charts; only text values.
      loc:  lines 1007-1023 (draw_bar function)
  [LOW] Add dependencies only for the current config (WS8/WM8) (status=partial, effort=small) [analysis]
      bash: check_deps() builds DEPS array conditionally: add docker if IS_DOCKER=true, add pihole-FTL/pihole if not docker, add mount.cifs if SMB, etc. Lines 328-344.
      py:   Python check_dependencies() has some conditional logic (docker) but not comprehensive.
      loc:  lines 328-344 (conditional DEPS building)
  [LOW] Allow DEBUG_MODE to be set via WARPHOLE_DEBUG env var (status=missing, effort=small) [analysis]
      bash: Lines 91: DEBUG_MODE="${WARPHOLE_DEBUG:-false}" — can be set at startup.
      py:   No environment variable override; DEBUG_MODE hardcoded to false (not in Python anyway).
      loc:  lines 91
  [LOW] Allow LOCAL_EXPORT_PATH override from secrets.env (status=missing, effort=small) [analysis]
      bash: Lines 146-148: Derive LOCAL_EXPORT_PATH after secrets.env is sourced, so if secrets.env sets it explicitly, that wins.
      py:   Python calculates LOCAL_EXPORT_PATH statically at startup; no override mechanism.
      loc:  lines 146-148
  [LOW] Best-effort auth logout with 5-second timeout (status=divergent, effort=small) [analysis]
      bash: cleanup() tries curl -X DELETE /auth with --max-time 5; if fails (session expired), swallows error. Lines 308-313.
      py:   Python requests.delete() has no timeout or error handling.
      loc:  lines 308-313 (WM13 logout block)
  [LOW] Bypass log tee redirection for stats mode (WM1) (status=missing, effort=small) [analysis]
      bash: Lines 164-178: Scan ALL args for --stats; only enable tee redirection if NOT stats mode. Prevents dashboard output from being logged.
      py:   Python log() always writes to file; stats output may be logged.
      loc:  lines 164-178 (tee bypass check)
  [LOW] Convert KB to MB for memory display (status=missing, effort=small) [analysis]
      bash: Lines 1134-1136: Convert MEM_USED_KB and MEM_TOTAL_KB to MB for readable display.
      py:   Python stats does not show memory in MB; relies on API % value only.
      loc:  lines 1134-1136
  [LOW] Debug-mode logger for phase markers and diagnostic output (status=missing, effort=small) [analysis]
      bash: dlog() emits DEBUG: prefix when DEBUG_MODE=true (configurable via WARPHOLE_DEBUG env var or config), filtered by log() verbosity check. Used for bisecting silent exits. Lines 259, 88-91.
      py:   No dlog() function; no DEBUG_MODE config; no debug-level logging capability.
      loc:  lines 259, 88-91 (DEBUG_MODE definition), plus 366, 382, 797 etc. (usage)
  [LOW] Draw horizontal line for UI layout (status=missing, effort=small) [analysis]
      bash: draw_line() uses tput cols (or $COLUMNS) to fill line with dashes. Lines 1001-1003.
      py:   Python UI uses rich Panels which have their own separator style.
      loc:  lines 1001-1003 (draw_line function)
  [LOW] Explicit --mount-only and --unmount-only modes for manual control (status=missing, effort=small) [analysis]
      bash: Lines 1270-1280: --mount-only acquires lock, calls mount_smb, sets MANAGE_MOUNT=false, exits 0. --unmount-only unmounts if mounted, exits 0.
      py:   Python has no --mount-only or --unmount-only modes; mount is only triggered during backup.
      loc:  lines 1270-1280 (mount-only/unmount-only handling)
  [LOW] Fallback for systems without stat command (use wc -c) (status=missing, effort=small) [analysis]
      bash: Lines 192-199: Try stat with platform-specific flags (Darwin vs Linux); fall back to wc -c if stat not available.
      py:   Python uses os.path.getsize() which doesn't need fallback.
      loc:  lines 192-199
  [LOW] Guard against negative QPS (when query count resets) (status=missing, effort=small) [analysis]
      bash: Lines 1143-1144: if DIFF < 0 set DIFF=0 to handle API counter resets.
      py:   Python QPS calculation (line 344) does not guard against negative diff.
      loc:  lines 1143-1144
  [LOW] Handle Unraid empty-string arg same as no args (treat as DEFAULT_MODE) (status=missing, effort=small) [analysis]
      bash: Lines 1253: `if [[ $# -eq 0 || ( $# -eq 1 && -z "${1:-}" ) ]]` — Unraid User Scripts invokes with single empty string; treat it the same as no args.
      py:   argparse does not encounter empty string args; behavior is probably correct but not explicitly handled.
      loc:  lines 1253 (empty string handling comment)
  [LOW] One-shot PADD schema drift detection at startup (status=missing, effort=small) [analysis]
      bash: run_stats() before entering main loop: curls /padd, checks if jq can extract required fields (.queries.total, .gravity_size, .system.cpu.load.raw, etc.); if any missing, prints warning. Lines 1066-1089.
      py:   Python has no schema probe; would silently show 0 for missing fields if PADD schema changes.
      loc:  lines 1066-1089 (schema drift check)
  [LOW] Print help before dependency check (WM6) (status=divergent, effort=small) [analysis]
      bash: Lines 1239-1244: Loop through args looking for --help/-h BEFORE check_deps; print usage and exit 0 immediately. Allows users to see help without jq/mount.cifs installed.
      py:   Python check_dependencies() runs before argparse (line 395); user cannot see --help without requests/rich installed.
      loc:  lines 1239-1244 (help before deps)
  [LOW] Read -r -d '' from find output to handle filenames with newlines (status=missing, effort=small) [analysis]
      bash: Lines 721-738: read -r -d '' from find -print0 output for backup rotation to safely handle spaces/newlines in filenames.
      py:   Python backup rotation doesn't exist; if it did, os.scandir() would be safer than glob.
      loc:  lines 721-738 (read from find -print0 loop)
  [LOW] Terminal state restoration on exit (cursor visible, clear screen) (status=missing, effort=small) [analysis]
      bash: cleanup() if MODE=stats: tput cnorm (show cursor), clear. Lines 317-322.
      py:   Python cleanup does not restore terminal state; cursor may remain invisible after exit.
      loc:  lines 317-322 (terminal reset block)
  [LOW] Unset temporary helper variables to keep environment clean (status=missing, effort=small) [analysis]
      bash: Lines 143, 178, 245, 1245: unset temporary vars like _secrets_perms, _arg, etc.
      py:   Python doesn't have this concern; scopes are handled differently.
      loc:  lines 143, 178, 245, 1245
  [LOW] Validate REFRESH_RATE is a positive integer before use in read -t (status=missing, effort=small) [analysis]
      bash: Lines 1056-1060: Check REFRESH_RATE regex; if not numeric or < 1, warn and set to 2.
      py:   Python does not validate REFRESH_RATE before use in time.sleep().
      loc:  lines 1056-1060 (REFRESH_RATE validation)

PYTHON REGRESSIONS (py actively wrong vs bash):
  - SMB credentials passed as -o mount options (line 145) exposes password in ps output, violating WC3 security hardening from bash (should use temp credentials file with mode 0600).
  - docker_ls=$(... ls -t /tmp/*.zip | head -n1) approach (lines 214-219) is fragile and can pick up stale zips, whereas bash uses pihole-FTL output parsing with fallbacks.
  - No explicit guards for curl failures in run_health_check() (lines 282, 290); bare except at line 284 swallows all exceptions instead of distinguishing network errors from logic errors.
  - run_stats() has no terminal state restoration on exit; cursor may remain invisible (bash: tput cnorm at lines 320).
  - Backup rotation does not exist; backups accumulate indefinitely (bash: find with mtime at lines 736-738, configurable via WARPHOLE_KEEP_DAYS at line 75).

PYTHON EXTRAS (do not drop):
  - Python uses requests library for HTTP (modern, cleaner than curl+jq pipelines).
  - Python uses rich library for TUI rendering (more sophisticated than bash ASCII art, though less customizable).
  - Python dependency check offers interactive pip install prompt (lines 69-78) vs bash failing hard.


# ===== watchtower =====

BASH: The Bash watchtower.sh is a comprehensive daemon monitoring system with 3075 lines providing continuous backup scheduling, checksum scanning, Docker updates, cache management, and a full command-center TUI. Core features include: daemon process with smart 3-second-interval trigger polling (smart_sleep), IPC via trigger files + SIGUSR1, multi-mode operation (monitor/scan/cleanup/update/stop-backup/reload/logs), three distinct TUI dashboards (--status snapshot, --ab-graph live activity graph, --hub command center with menus), atomic file writes, log rotation, hostname case normalization, Unraid/OMV/Linux OS detection, webhook notifications, and deep checksum verification with corruption reporting.

PYTHON: The Python port at 774 lines implements core daemon functionality with --monitor continuous loop, --scan, --cleanup, --update, --verify, --start-backup, --stop-backup, and --reload modes. It includes basic scheduling, signal handlers (SIGUSR1 for reload), trigger file checking, Docker updates, cache monitoring, and multithreaded checksum scanning. However, it lacks the three interactive TUI modes (--status, --ab-graph, --hub/--logs), has reduced feature parity on many OS-specific behaviors, missing advanced scheduler logic (overdue recovery), and lacks notification webhook support.

VERIFIED GAPS: 50 (high=6 med=17 low=27); false-positives dropped: 9

CLI flags python lacks/partial:
  - --logs / --log (no): Smart auto-switching log monitor that follows active process
  - --status (no): One-shot read-only daemon status snapshot (exit 0 if running)
  - --ab-graph (no): Live full-terminal TUI dashboard showing activity sparklines and progress
  - --hub / --center / --command-center (no): Persistent interactive command center menu with live header and single-key shortcuts
  - --force (no): Wake daemon immediately (trigger FORCE, polling IPC)
  - --config / -c PATH (partial): Manually specify config file location (supports both --config=PATH and --config PATH)

GAPS:
  [HIGH] --ab-graph live full-terminal TUI dashboard during backup/restore (status=missing, effort=large) [analysis]
      bash: cmd_ab_graph() (lines 1745-2164) renders live 60s-window sparklines for CPU/MEM/write, phase timeline with severity markers, shares progress checklist, network stats (RX/TX with TSO offload ratio), destination disk bar, recent log tail, process uptime. Detects active backup/restore via lockfile probe, auto-detects network interface, reads ethtool offload counters, formats durations, shows spinner during active phases. Returns gracefully to --status if no worker running. Interactive refresh interval via WATCHTOWER_GRAPH_REFRESH. Graceful exit on Ctrl+C.
      py:   No --ab-graph implementation or any interactive dashboard functionality
      loc:  lines 1745-2164, worker detection 1274-1320, helpers 1322-1905, arg parsing 2735
  [HIGH] --hub (aliases --center, --command-center) persistent menu-driven TUI command center (status=missing, effort=large) [analysis]
      bash: cmd_hub() (lines 2650-2714) displays live header every 3s showing daemon state, backup/mover/cache status, schedule history. Main menu with single-key shortcuts: [c]leanup, [u]pdate, [k]san, [v]erify, [R]eload, [d]aemon toggle, [D]restart, [s]tart backup, [p/P/B]roduction modes, [x]stop, [L]ist archives (restorer), [A]ll verify, [C]orruption, [I]nspect, [V]erify one. Spawns sub-views for --ab-graph, --logs, --status, restorer commands. Manages cursor/screen via tput, uses INT trap to catch Ctrl+C in sub-views without killing hub.
      py:   No TUI menu, no interactive key handling, no menu rendering
      loc:  lines 2650-2714, helpers 2179-2557, arg parsing 2736
  [HIGH] --status one-shot read-only daemon snapshot (status=missing, effort=medium) [analysis]
      bash: cmd_status() displays formatted daemon state, schedule history, running processes, pending triggers, config, hostname, log locations. Returns exit code 1 if daemon not running (usable as monitoring probe). Lines 1145-1222.
      py:   Python has no --status flag or cmd_status implementation
      loc:  lines 1145-1222, arg parsing 2734
  [HIGH] Dated checksum filenames (<name>_YYYYMMDD.sha256) (status=missing, effort=medium) [analysis]
      bash: process_file() (lines 989-1058) looks for <name>_[0-9]{8}.sha256 glob (line 1005) to find existing checksums. The date suffix is the discovery date, source-of-truth for file age used by pull-side retention. Stores hash in temp file then renames atomically. Sophisticated for multi-writer scenarios.
      py:   Python path construction at line 317 uses rel_path + '.sha256' with no date suffix. No glob lookup for existing dated variants. Breaks retention filtering logic that keys off date.
      loc:  lines 989-1058, especially 1005-1042
  [HIGH] Optional .nfo/.txt cleanup in media folders (CLEANUP_MEDIA_METADATA config) (status=missing, effort=small) [analysis]
      bash: run_cleanup_task() (lines 965-972) optionally deletes .nfo and .txt in media/TV and media/Movies if CLEANUP_MEDIA_METADATA=true. OFF by default with explanation that these are legitimate Plex/Jellyfin metadata.
      py:   Python cleanup (lines 531-537) tries to delete all .nfo/.txt without a config override, unconditionally. Breaks media library metadata.
      loc:  lines 960-972
  [HIGH] _ab_graph_phase_history() TUI phase timeline with severity markers (status=missing, effort=large) [analysis]
      bash: Lines 1382-1460: parses log for 'Phase:' markers after 'Starting', extracts ISO timestamps, computes duration deltas, tracks ERROR/WARN/OK severity per phase. Keeps last 6 phases. Uses TZ=UTC and awk mktime() for timestamp conversion.
      py:   No phase parsing or timeline rendering.
      loc:  lines 1382-1460
  [MEDIUM] --logs smart auto-switching log monitor (status=missing, effort=medium) [analysis]
      bash: monitor_logs() (lines 454-510) dynamically switches between watchtower and auto-backupper logs based on is_backup_running(). Displays context name and source file. Maintains live tail with tail -F across context switches. Shows 15 lines of history per context. Renders rainbow spinner with unicode box-drawing chars during sleep between refreshes. Responsive to live state changes.
      py:   No --logs flag or logging monitor implemented
      loc:  lines 454-510, arg parsing 2733
  [MEDIUM] --stop-backup escalating signal strategy (TERM then KILL after 15s) (status=partial, effort=medium) [analysis]
      bash: cmd_stop_backup (lines 3009-3067) reads BACKUP_PIDFILE written by auto-backupper, cross-checks /proc cmdline to confirm it's actually auto-backupper (anti-PID-reuse safety C3/C4), sends SIGTERM, waits 15s, escalates to SIGKILL. Logs each phase. Explicit safety against killing wrong process.
      py:   Python stop_backup (lines 722-741) uses pgrep -f 'auto_backupper' without confirming against pidfile. Less safe, could match unrelated processes. No escalating signals, just SIGTERM. Tries to remove lockfile which bash explicitly avoids (C4 rationale).
      loc:  lines 3009-3067, C3/C4 rationale at 3016-3022
  [MEDIUM] Cleanup trigger via IPC + scheduler integration (status=partial, effort=small) [analysis]
      bash: check_cleanup_scheduler() (lines 819-826) and check_manual_triggers() (882-886) handle cleanup scheduling and IPC. Cleanup runs asynchronously (&) to avoid blocking daemon.
      py:   Python cleanup runs synchronously in main_loop (line 604), blocking other schedulers. No IPC trigger support.
      loc:  lines 819-826, 882-886
  [MEDIUM] Docker update trigger via IPC + scheduler integration (status=partial, effort=small) [analysis]
      bash: check_update_scheduler() (lines 715-722) and check_manual_triggers() (844-849) handle updates. Updates run asynchronously (&) to avoid blocking.
      py:   Python update runs synchronously (line 615), blocking other schedulers. Trigger support via SIGUSR1 handler exists but integrated into signal handler, not main loop.
      loc:  lines 715-722, 844-849
  [MEDIUM] File stability check (size unchanged after 1s) (status=partial, effort=small) [analysis]
      bash: file_is_stable() (lines 516-534) double-checks file size with 1s sleep between probes. Returns false if file is actively being written. Prevents checksumming partial files. Uses timeout 2s for stat.
      py:   Python task_verify_file() (lines 351-356) sleeps 0.5s between getsize checks instead of 1s. Does not use timeout wrapper, could hang on FUSE/SMB mounts. Less robust.
      loc:  lines 516-534
  [MEDIUM] Hub integrates auto-restorer commands (--list, --verify-all, --inspect, --verify) (status=missing, effort=large) [analysis]
      bash: Lines 2206-2230, 2489-2515: probe for restorer script via config or relative paths, integrate with hub keybindings [L/A/C/I/V]. Graceful failure if restorer not found.
      py:   No restorer integration in Python.
      loc:  lines 2206-2230, 2489-2515
  [MEDIUM] Remote webhook notifications (Discord/Slack/ntfy/generic JSON) (status=missing, effort=medium) [analysis]
      bash: strategy_notify_webhook() (lines 330-391) sends notifications to NOTIFY_WEBHOOK_URL if set. Auto-detects format (discord/slack) from URL hostname, or uses NOTIFY_WEBHOOK_FORMAT override. Supports ntfy with header-based priorities. Escapes JSON via _json_escape(). Silently fails with curl --max-time 10s. send_notify() (lines 393-407) routes to both webhook and OS-native (Unraid notify script, notify-send).
      py:   Python notify() function only supports Unraid /usr/local/emhttp and notify-send. No webhook, no JSON escaping, no format detection, no ntfy support
      loc:  lines 314-391, 393-407, called throughout
  [MEDIUM] S12 lockfile fallback detection when PID file is missing/unreadable (status=missing, effort=medium) [analysis]
      bash: If PID file detection fails but lockfile is held exclusively (flock probe, lines 2784-2798), daemon IS running — no PID but work can be queued via trigger files since smart_sleep polls every 3s. Allows --scan/--verify/--cleanup/--force to work even with missing PID file.
      py:   Python has no lockfile fallback probe. If PID file is missing, would assume daemon not running and try to lock. Would fail with 'already running' if lockfile held but PID unreadable.
      loc:  lines 2784-2798, rationale at 2776-2783
  [MEDIUM] Scheduler overdue recovery (S6 in should_run_schedule) (status=missing, effort=small) [analysis]
      bash: Bash tracks days_since_last_run and checks if it exceeds schedule interval (1 day overdue for daily, 7 for weekly, etc.). If daemon was down across a scheduled window (reboot), it fires immediately rather than waiting until next scheduled time. Lines 746-774.
      py:   Python should_run_schedule() has no overdue recovery logic. Only checks if already run today, then time-of-day. Would silently skip if daemon was down at scheduled time.
      loc:  lines 746-774
  [MEDIUM] TRIGGER_CLEANUP IPC file and signal handling (status=missing, effort=small) [analysis]
      bash: Bash supports touch $TRIGGER_CLEANUP followed by SIGUSR1 to queue a cleanup task. Checked in check_manual_triggers() (line 882-886) and removed after execution. Daemon wakes within 3s via smart_sleep.
      py:   Python has no TRIGGER_CLEANUP file support or corresponding command-line flag
      loc:  lines 62, 65, 882-886, arg parsing near --cleanup
  [MEDIUM] Trigger file cleanup after manual trigger processing (status=partial, effort=?) [verify-missed]
      bash: Bash check_manual_triggers() at lines 844-892 explicitly removes each trigger file after processing (rm -f). Smart_sleep() polling depends on file absence to not re-trigger.
      py:   (missed by analyzer)
      loc:  lines 847, 854, 863, 878, 884, 891
  [MEDIUM] _ab_graph_shares_progress() checkelist of shares during backup (status=missing, effort=large) [analysis]
      bash: Lines 1476-1569: renders share checklist during 'Shares Backup' or 'Granular Backup' phases. Tracks done/active/pending states and per-share severity (ok/warn/fail) from log Archiving: lines. Requires SHARES_TO_BACKUP array from config.
      py:   No share checklist rendering.
      loc:  lines 1476-1569
  [MEDIUM] _ab_graph_sparkline() block-element sparklines (U+2581..U+2588) (status=missing, effort=medium) [analysis]
      bash: Lines 1337-1356: renders 60-sample window of CPU/MEM/write/RX/TX as block characters scaled to max. Pure Unicode text, renders in all modern terminals.
      py:   No sparkline rendering.
      loc:  lines 1337-1356
  [MEDIUM] _hub_toggle_daemon() context-aware start/stop via single key (status=missing, effort=medium) [analysis]
      bash: Lines 2368-2376: checks daemon state, prompts 'Stop' if running or 'Start' if stopped. Single confirmation covers the action.
      py:   No interactive daemon control.
      loc:  lines 2368-2376
  [MEDIUM] _json_escape() for webhook payload safety (status=missing, effort=small) [analysis]
      bash: Lines 314-321: escapes backslash, quotes, newlines, tabs. Duplicated from auto-backupper.sh per suite policy (no shared library). Used by webhook formatter.
      py:   Python notify() has no JSON escaping. Webhook support missing entirely.
      loc:  lines 314-321
  [MEDIUM] sha256sum timeout protection (600s / 10 min) (status=missing, effort=small) [analysis]
      bash: process_file() and verification path (lines 1024, 1051) wrap sha256sum in 'timeout 600' to prevent hung filesystems from deadlocking daemon. Comment at 1019-1022 explains rationale. Matches auto-backupper.sh ceiling.
      py:   Python computes SHA256 with no timeout. Could hang indefinitely on stale mounts.
      loc:  lines 1018-1057
  [MEDIUM] smart_sleep() responsive trigger polling (3s bursts) (status=partial, effort=small) [analysis]
      bash: smart_sleep() (lines 285-300) implements responsive loop that checks all 6 trigger files every 3 seconds instead of blocking on sleep. Immediately returns when any trigger is detected. Used throughout daemon loop to achieve sub-second responsiveness without polling overhead.
      py:   Python main_loop has no smart_sleep equivalent; uses simple time.sleep(cfg.MONITOR_INTERVAL) with no trigger polling. Triggers checked only at signal handler (SIGUSR1), missing the responsive 3s polling behavior. Reload handler checks triggers but doesn't integrate into main sleep cycle.
      loc:  lines 285-300, called throughout --monitor section
  [LOW] Array startup check (Unraid + OMV + generic) (status=missing, effort=small) [analysis]
      bash: is_array_started() (lines 565-570) checks OS_TYPE and uses appropriate method: Unraid state file + mdcmd check, OMV array path, generic mountpoint check.
      py:   Python has no is_array_started() function. Cache monitor assumes array is always available.
      loc:  lines 565-570, called at 608
  [LOW] Atomic writes for schedule markers and checksums (status=partial, effort=small) [analysis]
      bash: atomic_write() (lines 273-280) writes to temp file then renames atomically, preventing torn writes when /tmp full or process killed. Used for LAST_RUN_* markers (lines 811, 824, 836, 720). Also used in process_file() at lines 1053 for new checksums.
      py:   Python writes LAST_RUN_* files directly (e.g., lines 595, 606, 617, 632) with no temp file. Checksum writes at line 370 are direct. Risk of torn writes, but less critical in Python's GIL context.
      loc:  lines 273-280, called at 811, 824, 836, 720, 1053
  [LOW] Corruption report file creation and appending (status=partial, effort=?) [verify-missed]
      bash: Bash process_file() appends corruption findings to CORRUPTION_REPORT file at line 1030. Report path is derived from HOSTNAME_VAR and CHECKSUM_DIR (line 131).
      py:   (missed by analyzer)
      loc:  lines 1028-1031
  [LOW] Corruption report file rotation (status=missing, effort=small) [analysis]
      bash: rotate_corruption_report_if_large() (lines 203-217) rotates corruption_report.txt when it exceeds CORRUPTION_REPORT_MAX_SIZE (default 1 MiB). Uses same N-backups scheme as daemon log. Called from process_file() right before appending new corruption entries.
      py:   Python writes corruption reports but never rotates them. File grows unbounded.
      loc:  lines 203-217, called at line 1029
  [LOW] Docker Compose config file detection from labels (status=missing, effort=small) [analysis]
      bash: Inspects container label 'com.docker.compose.project.config_files' (line 658), falls back to WorkingDir (line 662) for docker-compose.yml. Ensures correct compose file is used for updates.
      py:   Python run_docker_update_task() has no compose file detection. Would fail on multi-compose setups.
      loc:  lines 656-673
  [LOW] Docker Compose v2 vs v1 (legacy) fallback (status=missing, effort=small) [analysis]
      bash: update_container_compose() (lines 642-674) tries 'docker compose' (v2 plugin) first, falls back to 'docker-compose' binary (v1 deprecated). Logs warning and returns 1 if neither available.
      py:   Python has no Compose detection. Would fail silently on systems with only docker-compose v1.
      loc:  lines 642-674
  [LOW] Docker cleanup via prune commands (image/network/builder) (status=missing, effort=small) [analysis]
      bash: run_cleanup_task() (lines 975-983) runs docker image/network/builder prune if docker available. Grouped redirect suppresses output.
      py:   Python cleanup does not include Docker pruning.
      loc:  lines 975-983
  [LOW] Four-tier log verbosity (error/phase/info/debug) (status=partial, effort=small) [analysis]
      bash: LOG_VERBOSITY config var (default 'info') with _log_verbosity_threshold() (lines 220-228) and _log_level_for() (lines 236-243) route messages through numeric tiers. Allows filtering at runtime; config-driven. Lines 76-81 document levels.
      py:   Python uses Python's logging.INFO only; no LOG_VERBOSITY config support, no tier routing, no phase/debug selective logging
      loc:  lines 76-81, 220-228, 236-243, 247-258
  [LOW] Hostname case normalization drift warnings (status=missing, effort=small) [analysis]
      bash: warn_hostname_case_drift() (lines 907-945) scans for legacy lowercase/mixed-case hostname artifacts in systems/ and .checksums/ dirs, emits WARN logs with migration commands. Normalizes to UPPERCASE. Runs only on artifact-writing modes (--monitor, --scan, --verify, --cleanup, --update) per lines 2900-2904.
      py:   Python has no hostname drift detection or normalization warnings
      loc:  lines 907-945, mode guard 2900-2904
  [LOW] Hostname normalization to UPPERCASE on startup (status=partial, effort=small) [analysis]
      bash: Line 49: hostname piped through cut and tr to normalize to UPPERCASE. Rationale at lines 38-48 explains suite policy for consistent artifact paths. Config can override via HOSTNAME_VAR in auto_backupper.cfg.
      py:   Python line 65 uses os.uname().nodename which returns as-is without case normalization. Differs from bash behavior, creating inconsistent artifacts.
      loc:  lines 38-49
  [LOW] Intelligent conflict logging (WAS_BACKUP_PAUSED state tracking) (status=missing, effort=small) [analysis]
      bash: Main loop (lines 2952-2967) tracks WAS_BACKUP_PAUSED to log 'Backup detected' only once when backup starts, and 'Backup finished' only once when it stops. Prevents log flooding on repeated checks.
      py:   Python logs nothing about backup state changes. Would log repeatedly if backup runs, or miss state transitions entirely if using simple if check.
      loc:  lines 2931, 2952-2967
  [LOW] LOG_VERBOSITY configuration support (status=missing, effort=?) [verify-missed]
      bash: Bash supports LOG_VERBOSITY config (default 'info') at line 81 with _log_verbosity_threshold() (lines 220-228) filtering all log messages through numeric tiers (error/phase/info/debug). Allows runtime filtering by verbosity.
      py:   (missed by analyzer)
      loc:  lines 76-81, 220-243
  [LOW] Mover process detection (pgrep -f) (status=missing, effort=small) [analysis]
      bash: is_mover_running() (lines 548-552) checks both /usr/local/sbin/mover and generic pgrep '\bmover\b'. Used in cache and verify scheduler logic.
      py:   Python has no is_mover_running() function or mover detection logic. Cache monitor doesn't check if mover is running.
      loc:  lines 548-552, called at 609, 831
  [LOW] Mover running keeps loop silent (no scan until mover stops) (status=partial, effort=small) [analysis]
      bash: Main loop checks is_mover_running() (lines 2969-2973) and sleeps without scanning. Prevents concurrent array writes during mover activity.
      py:   Python never checks is_mover_running(). Scan runs regardless of mover state, risking concurrent writes.
      loc:  lines 2969-2973
  [LOW] Multi-threading logging optimization (LAST_LOGGED_THREADS) (status=missing, effort=small) [analysis]
      bash: perform_scan() (lines 1074-1081) only logs thread count when > 1 AND differs from last logged. Prevents log spam on every scan.
      py:   Python logs thread count on every scan (line 393). Would spam logs if run multiple times per daemon session.
      loc:  lines 70, 1074-1081
  [LOW] Notification routing priority: Unraid notify script > notify-send (status=partial, effort=small) [analysis]
      bash: send_notify() (lines 393-407) checks Unraid first (lines 400-402), falls back to notify-send. Allows Unraid users to keep on-box banners while also supporting webhook pushes.
      py:   Python notify() (lines 234-253) checks Unraid but doesn't continue to notify-send on failure. Only checks notify-send if Unraid unavailable. Asymmetric.
      loc:  lines 393-407
  [LOW] OpenMediaVault detection via omv-notify command (status=partial, effort=small) [analysis]
      bash: Checks for omv-notify binary (line 308) to set OS_TYPE='omv'. Comment at 304-305 explains rationale vs omv-firstaid.
      py:   Python checks omv-firstaid (line 226) instead of omv-notify. Bash rationale says suite uses omv-notify for consistency, so Python has wrong probe.
      loc:  lines 304-308
  [LOW] PID file staleness detection and cleanup (status=partial, effort=small) [analysis]
      bash: Daemon startup (lines 2745-2774) validates PID file: checks kill -0, cross-references /proc cmdline, cleans up stale file if process is dead or recycled. Prevents lockup from ghost PID files.
      py:   Python checks if PID responds to signal (line 678) but doesn't clean up stale file or cross-check /proc. Could get stuck with stale PID.
      loc:  lines 2745-2774
  [LOW] TRIGGER_FORCE immediate cycle kick (status=missing, effort=small) [analysis]
      bash: touch $TRIGGER_FORCE + SIGUSR1 wakes daemon immediately (line 888-892). No-op trigger that just breaks sleep. Useful for forcing a scan without waiting for scheduler.
      py:   No --force mode or TRIGGER_FORCE support
      loc:  lines 61, 66, 888-892, arg parsing 2729
  [LOW] Unraid parity check detection (status=missing, effort=small) [analysis]
      bash: is_parity_running() (lines 554-563) checks Unraid's /var/local/emhttp/var.ini for mdResync=1 and pgrep 'mdcmd check'. Used in RUN_MOVER_DURING_PARITY cache logic (line 621).
      py:   Python has no parity check detection. Cache monitor cannot skip mover when parity runs.
      loc:  lines 554-563, called at 621
  [LOW] WATCHTOWER_GRAPH_REFRESH configurable dashboard refresh (seconds) (status=missing, effort=small) [analysis]
      bash: Lines 1771-1776: validates WATCHTOWER_GRAPH_REFRESH as positive integer, defaults to 1s. Affects spinner speed and sample window size proportionally.
      py:   No configuration option for refresh rate.
      loc:  lines 1771-1776
  [LOW] _ab_graph_check_deps() validates required binaries (status=missing, effort=small) [analysis]
      bash: Lines 1239-1251: checks for tput ps tail df stat awk; exits with clear message if missing instead of half-rendering.
      py:   No dependency check. Would fail silently on stripped systems.
      loc:  lines 1239-1251
  [LOW] _ab_graph_offload_stats() TSO offload ratio via ethtool (status=missing, effort=medium) [analysis]
      bash: Lines 1694-1733: reads ethtool -S counters (tx_tso_bytes / tx_packets variants), computes offload % over interval. Shows in dashboard only when data available (no clutter on unsupported NICs).
      py:   No ethtool integration or offload stats.
      loc:  lines 1694-1733
  [LOW] _ab_graph_pick_iface() auto-detect busiest non-loopback NIC (status=missing, effort=small) [analysis]
      bash: Lines 1630-1646: scans /proc/net/dev, picks interface with highest cumulative RX+TX bytes. Used at startup, sticky throughout session.
      py:   No interface detection.
      loc:  lines 1630-1646
  [LOW] _format_age_days() human-readable schedule age output (status=missing, effort=small) [analysis]
      bash: Lines 1108-1128: formats YYYYMMDD date as 'today', 'N days ago', etc. Used in --status and --hub header displays.
      py:   No age formatting helper in Python. --status not implemented.
      loc:  lines 1108-1128
  [LOW] _format_uptime_from_proc() process uptime from /proc stat (status=missing, effort=small) [analysis]
      bash: Lines 1130-1143: reads /proc/PID mtime as process start epoch, computes and formats uptime as 'Nd HHh MMm' or 'HHh MMm' or 'MMm'. Used in --status and --hub displays.
      py:   No uptime formatting. --status/--ab-graph not implemented.
      loc:  lines 1130-1143
  [LOW] rainbow_sleep() Unicode spinner with color cycling (status=missing, effort=medium) [analysis]
      bash: Lines 418-452: renders spinner with 4 frames (U+2500 \ | /) and 7 ANSI color codes. Used by --logs monitor during sleep intervals. Hide/show cursor.
      py:   No spinner or animation in Python. --logs not implemented.
      loc:  lines 418-452, used at 508

PYTHON REGRESSIONS (py actively wrong vs bash):
  - cleanup() deletes .nfo/.txt unconditionally (line 536-537), breaking Plex/Jellyfin metadata. Bash has CLEANUP_MEDIA_METADATA opt-in config (line 965). Python should check config before deletion.
  - stop_backup() uses pgrep -f 'auto_backupper' which could match unrelated processes (grep itself, editors). Bash uses BACKUP_PIDFILE + /proc/cmdline cross-check (lines 3024-3048) for safety. Python could kill wrong process.
  - stop_backup() tries to remove BACKUP_LOCKFILE (line 737), violating bash C4 rationale (lines 3019-3022): flock is held on open FD; removing file opens race window where concurrent backup could start before old one finishes dying.
  - notify() checks notify-send only if Unraid unavailable (line 252). Bash send_notify() continues to notify-send after Unraid (line 404). Python prevents dual notification when both available.

PYTHON EXTRAS (do not drop):
  - Python uses subprocess.Popen(..., start_new_session=True) for daemon/backup detachment which is more modern than bash nohup & disown pattern.
  - Python's ThreadPoolExecutor (lines 394-400) uses concurrent.futures which is more Pythonic than bash's job control, though semantically equivalent.
  - Python Config class (lines 61-153) provides structured config loading vs bash's source + variable scanning.
  - Python has try/except wrappers around critical operations (e.g., lines 351-356, 411-466, 479-486) providing resilience that bash achieves through command substitution with error suppression.


# ===== auto-backupper =====

BASH: The bash auto-backupper.sh is a comprehensive 2282-line enterprise backup system for Unraid, OMV, and Linux. It produces local backups via tarballs (with database dumps via Docker containers), pulls remote backups via rsync, verifies files via SHA256 checksums with parallel workers, and rotates old files by retention date. Features include: Docker lifecycle management (stop before system backups, restart after), configurable multi-database support (MySQL/PostgreSQL/MongoDB/Redis), granular share backup with hierarchical folder strategies, dry-run simulation, multi-threaded verification/rotation via xargs, lock-based mutual exclusion, state recovery after crashes, and webhook notifications (Discord/Slack/ntfy/generic JSON). Verbosity control reduces log bloat from tar/rsync at info/phase/error levels, and checksums carry YYYYMMDD date suffixes for portable retention. The pull flow detects backup root nesting, builds per-folder exclusion lists from stale checksums, and re-pulls corrupted files in batches.

PYTHON: The python auto-backupper.py is a 689-line partial port that implements produce and pull workflows with basic database dumps (MySQL/PostgreSQL/Mongo/Redis), system/shares backup, local/pulled file verification via SHA256, and rotation by mtime. It uses Python's logging with JSON output, subprocess for external commands, fcntl for file locking, and ThreadPoolExecutor for parallel verification. JSON logger always outputs structured logs; does NOT implement: webhook notifications (Discord/Slack/ntfy), granular share strategies (FamilyBackups hierarchies, domains/iscsi subfolder recursion), state recovery, hostname case-drift warnings, OS-specific strategies (Unraid/OMV), Docker image mounting (Unraid-specific), per-folder retention exclusion lists during pull, batch re-pulling of corrupted files, dated-suffix checksum management, session manifest, rotation via dated checksums (uses mtime only), manifest embedding in archives, sparse file detection, log rotation, --only phase filtering, preflight space checks, or production dry-run overrides.

VERIFIED GAPS: 54 (high=6 med=22 low=26); false-positives dropped: 16

CLI flags python lacks/partial:
  - --only PHASES (no): Restrict produce flow to comma-separated phases: db (alias: services) | systems | shares. Skips rotation. Affects --mode produce/both only.
  - --debug (no): Enable debug logging (set -x in bash)
  - -h, --help (no): Show usage information

GAPS:
  [HIGH] Dated-suffix checksum management (_{YYYYMMDD}.sha256 files) (status=missing, effort=medium) [analysis]
      bash: checksum_write_path() (1155-1158), checksum_find_path() (1167-1183), checksum_date_from_path() (1189-1197), write_checksum() (1199-1232): all manage checksums with _YYYYMMDD suffix. write_checksum drops stale siblings before writing new one (atomic rename). verify_file reads newest dated checksum via regex sort. rotation_date_for() (1457-1484) extracts date from suffix.
      py:   checksum_path() (line 306) builds path without date suffix (returns .checksums/{rel}.sha256). verify_file() (line 349) does not extract/compare dated checksums, just reads existence. Python archives carry no dated suffix on checksums.
      loc:  lines 1155-1232, 1457-1484
  [HIGH] Mongo credential file security (mode 600, scrub, shred fallback) (status=missing, effort=medium) [analysis]
      bash: produce_flow lines 1669-1733: creates temp creds file mode 600, docker cp into container, chmod 600 inside, use it, rm from container, shred or rm from host. Protects against ps/procfs leaks.
      py:   produce_flow() passes --password on docker exec command line (line 453), which leaks to ps
      loc:  lines 1669-1733
  [HIGH] Per-folder retention exclusion lists (BUILD FOLDER_EXCLUDES during pull) (status=missing, effort=large) [analysis]
      bash: pull_flow lines 2039-2078: walks remote's .checksums/, extracts dated suffixes, builds per-folder exclusion lists, passes --exclude-from to per-folder rsync (lines 2088-2092). Skips stale files at wire.
      py:   pull_flow() does not read remote .checksums to build exclusion lists; blindly syncs all folders
      loc:  lines 2039-2098
  [HIGH] Rotation via dated-suffix checksums (portable across hosts) (status=partial, effort=large) [analysis]
      bash: rotation_phase() (lines 1504-1560): computes cutoff_date via `date -d`, calls rotation_date_for() to extract from suffix (primary) or mtime (fallback), compares YYYYMMDD numerically, deletes DATA only (retains checksums as historical index)
      py:   produce_flow rotation (lines 555-565) uses mtime-only (os.path.getmtime + cutoff timestamp). No dated-suffix extraction or fallback. Deletes both data AND checksum dir walks together.
      loc:  lines 1504-1560
  [HIGH] Stale mount timeout protection in verify workflow (status=missing, effort=?) [verify-missed]
      bash: verify_file() (line 1263) wraps sha256sum in timeout 600s to prevent indefinite hangs on stale NFS/SMB mounts
      py:   (missed by analyzer)
      loc:  line 1263
  [HIGH] Unraid Docker image mounting (mount_image / losetup strategies) (status=partial, effort=medium) [analysis]
      bash: strategy_docker_unraid_mount() (lines 606-635): tries /usr/local/sbin/mount_image, then losetup with -P flag, then losetup without -P, then mount -o loop. Handles partition detection (${LOOP}p1). strategy_docker_unraid_unmount() (lines 637-656) reverses with umount + losetup -d cleanup.
      py:   sys_docker_start() (line 275) has basic mount attempt via /usr/local/sbin/mount_image or mount -o loop, but missing losetup fallback chain and partition detection
      loc:  lines 606-656 (mount/unmount strategies)
  [MEDIUM] --only phase filtering (--only=db,systems,shares) with rotation skip (status=missing, effort=small) [analysis]
      bash: Argument parsing (lines 396-456), _phase_enabled() gate (lines 461-468). produce_flow checks phase at each section (1579, 1781, 1810). Rotation skipped if --only set (1943-1946).
      py:   argparse has --skip-preflight but no --only. No phase filtering logic.
      loc:  lines 396-468, 1943-1946
  [MEDIUM] Batch re-pull of corrupted files via --files-from (status=missing, effort=small) [analysis]
      bash: pull_flow lines 2187-2217: collects failed file paths from IPC_ERRORS, writes to temp file, calls rsync --files-from once with all at-once (not per-file). Timeout=60 for stale mount detection.
      py:   pull_flow verification (lines 605-619) re-pulls file-by-file via safe_rsync(); no batch collection or --files-from
      loc:  lines 2187-2217
  [MEDIUM] Crash recovery: restart Docker if previous run left it stopped (status=missing, effort=small) [analysis]
      bash: init_state() (lines 205-228): checks STATE_FILE for DOCKER_STOPPED=true, calls sys_docker_start before truncating state
      py:   init_state() (line 161) just clears state; no recovery logic
      loc:  lines 210-220
  [MEDIUM] Docker stop timeout polling with status check (status=missing, effort=?) [verify-missed]
      bash: strategy_docker_unraid_stop() (lines 658-679) explicitly polls /etc/rc.d/rc.docker status in 5-second intervals until service is down, up to DOCKER_STOP_TIMEOUT limit
      py:   (missed by analyzer)
      loc:  lines 658-679
  [MEDIUM] Docker stop timeout with polling (rc.docker status check) (status=missing, effort=small) [analysis]
      bash: strategy_docker_unraid_stop() (lines 658-679): polls /etc/rc.d/rc.docker status in 5-second loops up to DOCKER_STOP_TIMEOUT, then force_stop if needed. Elapsed tracking.
      py:   sys_docker_stop() does not poll status; immediately calls docker stop without timeout handling
      loc:  lines 658-679
  [MEDIUM] Dry-run via function override (rsync/tar/rm/mkdir/mount/umount) (status=missing, effort=small) [analysis]
      bash: Lines 1128-1140: when DRY_RUN=true, redefines rsync, tar, rm, mkdir, find, docker, mysqldump, pg_dump, losetup, mount, umount as log-only wrappers
      py:   run_cmd() (line 190) checks DRY_RUN flag and returns early, but some external commands (mount, umount, losetup) not wrapped
      loc:  lines 1128-1140
  [MEDIUM] Error trap with emergency Docker restart (status=missing, effort=small) [analysis]
      bash: err_trap() (lines 814-824): logs exit code/line/command, sends alert notification, checks DOCKER_STOPPED and attempts restart, exits with code
      py:   No error trap equivalent; Python exceptions not caught with cleanup
      loc:  lines 814-824
  [MEDIUM] FamilyBackups special 3-tier hierarchy (member/users-systems subfolders) (status=partial, effort=small) [analysis]
      bash: produce_flow (lines 1824-1839): for 'FamilyBackups', finds {member_name} dirs, then for each finds 'users' and 'systems' subdirs, archives each as {member}_{users|systems}_{CDATE}.tar.gz under shares/FamilyBackups/{member}/{users|systems}/
      py:   produce_flow() (lines 518-528) has similar logic but: (1) archive creation uses Path('.') as target which may be incorrect, (2) dest_dir structure looks correct but untested
      loc:  lines 1824-1839
  [MEDIUM] Granular recursive backup for 'domains' and 'iscsi' shares (status=partial, effort=small) [analysis]
      bash: backup_recursive_folder() (lines 1373-1395) and produce_flow logic (lines 1815-1821): for 'domains' and 'iscsi' shares, finds immediate subdirs and archives each as a separate tarball named {subfolder}_{CDATE}.tar.gz under shares/{share}/{folder}/
      py:   produce_flow() (lines 507-516) has partial logic: iterates subdirs and creates per-item archives, but missing: (1) shares_exclude handling during recursion, (2) correct dest_dir construction (should be {base}/shares/{share}/{item}), (3) exclusion array passing
      loc:  lines 1373-1395, 1815-1821
  [MEDIUM] Interrupt trap with current archive cleanup (status=partial, effort=small) [analysis]
      bash: interrupt_trap() (lines 826-835): logs, deletes CURRENT_ARCHIVE_FILE if it exists, restarts Docker if stopped, exits 130
      py:   signal_handler() (line 635) logs and exits 130, but does not delete CURRENT_ARCHIVE_FILE or restart Docker
      loc:  lines 826-835
  [MEDIUM] Log verbosity control (error/phase/info/debug) with per-level thresholds (status=missing, effort=medium) [analysis]
      bash: _log_verbosity_threshold() (lines 170-178) and _log_level_for() (lines 184-190) detect message level from prefix (FATAL/ERROR/WARN → 2, ===Phase → 3, INFO → 4, else → 4). log() (lines 192-202) emits only if level <= threshold. TAR_VERBOSE_FLAG and RSYNC_OPTS adjusted conditionally.
      py:   Python logger set to INFO level (line 151); no prefix-based level detection or verbosity-gated output. tar/rsync always at same verbosity.
      loc:  lines 170-202, 870-881
  [MEDIUM] MySQL password via MYSQL_PWD env var (not argv) (status=missing, effort=small) [analysis]
      bash: produce_flow lines 1631-1635: passes MYSQL_PWD via docker exec -e. Comments explain argv leakage (S8).
      py:   produce_flow() passes -p{pass} on mysqldump command line (line 399)
      loc:  lines 1631-1635
  [MEDIUM] OS-specific notification strategies (Unraid/OMV/generic) (status=partial, effort=small) [analysis]
      bash: strategy_notify_unraid (line 485), strategy_notify_omv (line 492), strategy_notify_generic (line 500). sys_notify bound at runtime to one or more depending on OS_TYPE. Bash detects OS via /etc/unraid-version, omv-notify availability.
      py:   send_notify() (line 225) has basic branches for OS_TYPE unraid/omv/generic but webhook path is missing entirely
      loc:  lines 485-505, 732-762 (OS detection and strategy binding)
  [MEDIUM] Preflight checks (binary availability, writability, remote mounts) (status=partial, effort=small) [analysis]
      bash: preflight_checks() (lines 970-1009): checks BACKUP_BASE writability, required binaries (tar/rsync/find), remote mounts exist, space (gated by PREFLIGHT_SPACE_CHECK). Issues FATAL early.
      py:   main() (lines 673-679) has basic checks for rsync/tar/sha256sum and enclave writability but missing BACKUP_BASE writability, remote mount checks, and space check
      loc:  lines 970-1009
  [MEDIUM] Preflight free space estimation with compression ratio (status=missing, effort=medium) [analysis]
      bash: preflight_free_space_check() (lines 1016-1125): measures source size via du -sb (timeout 120s), destination free via df -PB1, calculates required bytes as (source * ratio + margin), aborts if insufficient. Ratio/margin tunable via config. Issues soft warning if free < uncompressed.
      py:   No space check exists. --skip-preflight flag exists but is no-op.
      loc:  lines 1016-1125
  [MEDIUM] Pull marker (ctime) to identify session-only files (status=missing, effort=small) [analysis]
      bash: pull_flow creates pull_marker (line 2020), sleeps 1s (line 2024), rsync writes files, find -cnewer $pull_marker lists only rsync-written files (line 2135). Separates session from old.
      py:   pull_flow() (line 569) has no marker or ctime tracking; cannot distinguish old vs new files
      loc:  lines 2019-2024, 2135
  [MEDIUM] Recovery of Docker state from previous crash via STATE_FILE before cleanup (status=missing, effort=?) [verify-missed]
      bash: init_state() (lines 205-228) explicitly checks DOCKER_STOPPED=true flag in state file BEFORE clearing it, calls sys_docker_start to recover
      py:   (missed by analyzer)
      loc:  lines 210-220
  [MEDIUM] Redis password via REDISCLI_AUTH env var (not argv) (status=missing, effort=small) [analysis]
      bash: produce_flow lines 1753-1756: passes REDISCLI_AUTH via docker exec -e, not --password on argv. Comments explain /proc/*/environ vs argv exposure.
      py:   produce_flow() passes password as -a {pass} on command line (line 472)
      loc:  lines 1753-1756
  [MEDIUM] Session manifest (SESSION_MANIFEST) for selective verification (status=missing, effort=small) [analysis]
      bash: Declared at line 48. create_archive() (line 1362) appends archive paths on success. Produce_flow reads it (line 1898+) to verify ONLY files created this session (fast). Alternative mode verifies entire BACKUP_BASE tree.
      py:   CREATED_ARCHIVES list (line 130) tracks locally but no session manifest file. produce_flow verification (lines 536-552) builds verification list on-the-fly but cannot distinguish old vs new archives.
      loc:  lines 48, 1362, 1894-1915
  [MEDIUM] Sparse file detection during tar (--sparse / -S flag) (status=missing, effort=small) [analysis]
      bash: tar command at lines 1348, 1352: includes -S flag to detect holes and encode efficiently. Critical for docker.img (60GB of holes → 5min vs 30min). Sparseness restored on extract.
      py:   create_archive() (line 316) tar command does not include -S flag
      loc:  lines 1348, 1352
  [MEDIUM] Verification timeout (sha256sum timeout 600s) for stale mounts (status=missing, effort=small) [analysis]
      bash: verify_file() (line 1263): wraps sha256sum in timeout 600 so hung filesystem doesn't block script. Returns exit code 5 on timeout.
      py:   verify_file() (line 354) calls sha256sum without timeout
      loc:  line 1263
  [MEDIUM] Webhook notifications (Discord/Slack/ntfy/generic JSON) (status=missing, effort=medium) [analysis]
      bash: strategy_notify_webhook() (lines 538-603) auto-detects format from URL, JSON-escapes values, and POSTs to endpoint with level-specific prefixes and headers. Multiple formats supported (discord, slack, ntfy, generic). Failure silent/non-fatal.
      py:   send_notify() only logs to console/OS-native; no webhook support exists
      loc:  lines 538-603, 758-762 (sys_notify binding)
  [LOW] Alias 'services' → 'db' in --only parsing (status=missing, effort=small) [analysis]
      bash: Lines 435: --only=services normalized to 'db' for consistent gate names
      py:   No --only flag exists
      loc:  lines 435
  [LOW] Atomic state file updates (temp+mv, not append) (status=divergent, effort=small) [analysis]
      bash: set_state() (lines 230-249): builds full state in temp file, mv -f to swap in place. Prevents torn writes during SIGKILL.
      py:   set_state() (line 166) rebuilds full dict in memory and writes directly without temp+mv atomicity
      loc:  lines 230-249
  [LOW] BACKUP_PIDFILE in /var/run for watchtower integration (status=missing, effort=small) [analysis]
      bash: Line 34: /var/run/auto_backupper.pid survives /tmp clearing, read by watchtower --stop-backup
      py:   No PID file mechanism
      loc:  line 34
  [LOW] Checksum file atomic write (temp + mv, not direct) (status=missing, effort=small) [analysis]
      bash: write_checksum() (lines 1219-1231): writes to temp, mv -f to final. Prevents partial/zero-byte checksums from torn writes.
      py:   create_archive() (lines 325-327) writes checksum directly without temp+mv
      loc:  lines 1219-1231
  [LOW] Compression ratio and safety margin tuning for preflight space check (status=missing, effort=?) [verify-missed]
      bash: preflight_free_space_check() (lines 1016-1125) supports tunable PREFLIGHT_COMPRESSION_RATIO and PREFLIGHT_MARGIN_BYTES config vars
      py:   (missed by analyzer)
      loc:  lines 1094-1095
  [LOW] Config environment variable fallbacks (e.g., SQL_PASS from env) (status=missing, effort=small) [analysis]
      bash: Lines 306: SQL_PASS="${SQL_PASS:-YourMySQLPassword}" pulls from environment if set
      py:   CONFIG defaults (line 92) are hardcoded; no env var fallback
      loc:  line 306
  [LOW] Config value environment variable fallback pattern (status=missing, effort=?) [verify-missed]
      bash: Throughout config defaults (e.g. line 306: SQL_PASS="${SQL_PASS:-default}"), bash supports environment override via parameter expansion syntax
      py:   (missed by analyzer)
      loc:  line 306
  [LOW] Dynamic folder discovery (find mindepth=1 maxdepth=1 not -name .* ) (status=partial, effort=small) [analysis]
      bash: pull_flow lines 1988-2006: uses find to enumerate top-level non-hidden dirs
      py:   pull_flow (line 582) uses os.listdir and filters startswith('.'), which is equivalent but less robust (doesn't error on permission issues)
      loc:  lines 1988-2006
  [LOW] Enclave IPC queue directory (/var/opt/enclave/queue) for error files (status=missing, effort=small) [analysis]
      bash: Lines 37-48: ENCLAVE_DIR, IPC_BASE, IPC_ERRORS, SESSION_MANIFEST all under /var/opt/enclave/queue for atomic cleanup on exit
      py:   No IPC queue; errors tracked in memory only
      loc:  lines 37-48
  [LOW] Hostname case-drift detection and migration warnings (status=missing, effort=small) [analysis]
      bash: warn_hostname_case_drift() (lines 930-968): scans BACKUP_BASE for systems/{HOST}/ dirs with case variants, and .checksums/*_corruption_report.txt files with different casing. Logs WARN with exact mv/cat commands for operator review (no auto-migration).
      py:   No case-drift checking exists
      loc:  lines 930-968
  [LOW] Hostname normalization to UPPERCASE (canonical form) (status=missing, effort=small) [analysis]
      bash: Lines 66: HOSTNAME_VAR normalized via hostname | cut | tr '[:lower:]' '[:upper:]'. Configurable via config file override.
      py:   HOSTNAME_VAR (line 63) set from socket.gethostname().split('.')[0] without case normalization
      loc:  line 66
  [LOW] Last run timestamp file for watchtower scheduler (status=missing, effort=small) [analysis]
      bash: main() (lines 2273-2278): writes /tmp/auto_backupper_last_run_backup with YYYYMMDD on success, atomic temp+mv
      py:   main() does not write last run timestamp
      loc:  lines 2273-2278
  [LOW] Log rotation with copytruncate semantics (status=missing, effort=small) [analysis]
      bash: rotate_logs() (lines 108-141) and rotate_log_if_needed() (lines 152-155): uses cp+truncate (not rename) because script holds open FD. Per-line rotation check (line 201). Shifts old logs .1, .2, etc.
      py:   Uses Python RotatingFileHandler (line 153) which handles rotation internally but does not track per-line or provide copytruncate semantics awareness
      loc:  lines 108-155
  [LOW] Manifest embedding inside archives (.auto-backupper/MANIFEST.txt) (status=missing, effort=small) [analysis]
      bash: _write_manifest() (lines 1280-1304): creates .auto-backupper/MANIFEST.txt with archive name, creation time, host, kernel, source paths, tool versions. create_archive() (lines 1322-1355) builds temp dir with manifest, adds via -C switch before tar exits.
      py:   create_archive() (line 310) does not generate or embed manifests
      loc:  lines 1280-1355
  [LOW] PATH override for system compatibility (status=missing, effort=small) [analysis]
      bash: Line 2: exports comprehensive PATH to find binaries across Unraid/OMV/Linux
      py:   No PATH override; relies on system default
      loc:  line 2
  [LOW] PID file for watchtower --stop-backup integration (status=missing, effort=small) [analysis]
      bash: BACKUP_PIDFILE at line 34. Written at line 858. cleanup() removes at line 804. Used by watchtower to reliably identify process.
      py:   No PID file written or managed
      loc:  lines 34, 858, 804
  [LOW] Per-file verification worker start/done logging with elapsed time (status=missing, effort=?) [verify-missed]
      bash: verify_worker_pull() (lines 1428-1441) logs 'verify-start', then 'verify-FAIL' or 'verify-done' with elapsed seconds, enabling diagnosis of hanging files
      py:   (missed by analyzer)
      loc:  lines 1432, 1437, 1439
  [LOW] Pull folder name validation (reject paths with /) (status=missing, effort=small) [analysis]
      bash: pull_flow line 1997: validates folder_name != */* to prevent path injection. basename returns / for / input (caught here).
      py:   pull_flow() does not validate folder names
      loc:  line 1997
  [LOW] Pull folder safety filter (reject system folders) (status=partial, effort=small) [analysis]
      bash: pull_flow lines 2001-2003: skips folders named srv/mnt/proc/sys/dev/run/tmp/var/boot/etc/usr/bin/sbin/lib/lib64/opt/root to prevent accidental restore of system dirs
      py:   pull_flow (line 584) filters sys/dev/run/proc/tmp only; missing: srv/mnt/var/boot/etc/usr/bin/sbin/lib/lib64/opt/root
      loc:  lines 2001-2003
  [LOW] Pull nested backup root detection (find .checksums, redirect active_source) (status=missing, effort=small) [analysis]
      bash: pull_flow lines 1967-1982: if remote doesn't have .checksums at top, find recursively (maxdepth 5), use parent dir as active_source. Handles non-standard layouts.
      py:   pull_flow() assumes remote is backup root directly; no nested detection
      loc:  lines 1972-1982
  [LOW] SQL binary name auto-resolution (mariadb-* vs mysql-*) (status=missing, effort=small) [analysis]
      bash: produce_flow lines 1602-1608: detects mariadb-dump presence inside container, uses mariadb-* binaries if available (10.5+ standard), falls back to mysql-* for older/Oracle MySQL
      py:   produce_flow() hardcodes 'mysql' and 'mysqldump'; no container-side binary detection
      loc:  lines 1602-1608
  [LOW] Verification detailed return codes (0=ok, 2=nofile, 4=mismatch, 5=timeout) (status=partial, effort=small) [analysis]
      bash: verify_file() (lines 1234-1270): returns 2 if file missing, 4 if mismatch, 5 if timeout, 0 if ok. Callers check return value.
      py:   verify_file() returns bool (True/False) only; no granular codes for diagnostics
      loc:  lines 1234-1270
  [LOW] Verify worker per-file logging (start/done/fail with timing) (status=missing, effort=small) [analysis]
      bash: verify_worker_pull() (lines 1428-1441): logs verify-start, verify-FAIL (elapsed), verify-done (elapsed). Aids diagnosing hangs.
      py:   pull_flow verification (lines 605-610) logs warning on failure but no start/done/timing per file
      loc:  lines 1428-1441
  [LOW] _find_loop_for_file: find loop device for image file (status=missing, effort=small) [analysis]
      bash: Lines 477-482: uses losetup -j to find loop device for image file
      py:   No equivalent function; Docker unmounting doesn't use losetup search
      loc:  lines 477-482
  [LOW] rsync --progress gated by verbosity (not on info/phase/error) (status=missing, effort=small) [analysis]
      bash: Lines 869-872: RSYNC_OPTS built conditionally; --progress added only if LOG_VERBOSITY=debug
      py:   safe_rsync() (lines 337-347) always uses same rsync options; no verbosity gating
      loc:  lines 869-872
  [LOW] tar -v gated by verbosity (only at debug) (status=missing, effort=small) [analysis]
      bash: Lines 878-881: TAR_VERBOSE_FLAG empty at info/phase/error, 'v' at debug
      py:   create_archive() (line 316) always uses -v in tar command
      loc:  lines 878-881

PYTHON REGRESSIONS (py actively wrong vs bash):
  - Python verify_file() (lines 354) calls sha256sum without timeout, unlike bash's 600s timeout wrapper that protects against stale mount hangs. Can block indefinitely.
  - Python produce_flow() passes MongoDB password on docker exec command line (line 453: --password flag), exposing it to ps and /proc/*/cmdline queries. Bash (lines 1669-1733) uses secure config file + chmod 600.
  - Python produce_flow() passes Redis password as -a flag on redis-cli command line (line 472). Bash (lines 1753-1756) uses REDISCLI_AUTH environment variable instead.
  - Python produce_flow() passes MySQL password as -p{pass} on mysqldump command line (line 399). Bash (lines 1631-1635) uses MYSQL_PWD environment variable.
  - Python rotation (lines 555-565) deletes both data AND checksum dir tree equally, losing historical checksums. Bash (line 1542) deletes data only, retains checksums as permanent distributed index.

PYTHON EXTRAS (do not drop):
  - Python adds Postgres support with separate config (BACKUP_POSTGRES) distinct from MySQL, while bash conflates both under SQL_TYPE. Postgres is more cleanly separated.
  - Python uses ThreadPoolExecutor for parallel verification (lines 541-552, 606-610), a more Pythonic concurrent approach than bash's xargs/wait -n loop.
  - Python JSON logger (JsonFormatter, lines 138-147) outputs structured logs to file, vs bash's text log with tee. Structured logs aid machine parsing.


# ===== auto-restorer =====

BASH: auto-restorer.sh is a comprehensive disaster-recovery companion tool for the Auto-Backupper suite. It provides seven major operational modes: listing archives with corruption history annotations, inspecting tar contents, verifying archives against checksums with corruption detection, restoring archives with Docker lifecycle management, querying corruption reports with cross-host support, and pruning stale checksums. It includes robust logging with rotation, multi-OS support (Unraid/OMV/Linux), atomic locking for restore operations, confirmation prompts, dry-run mode, and graceful Docker recovery on abnormal exit.

PYTHON: no python port exists

VERIFIED GAPS: 58 (high=20 med=23 low=15); false-positives dropped: 0

CLI flags python lacks/partial:
  - --list [PATTERN] (no): List all archives under BACKUP_BASE, optionally filtered by glob pattern against basename
  - --inspect ARCHIVE (no): Display tar contents (verbose listing, first 100 entries, total count)
  - --verify ARCHIVE (no): Verify single archive checksum against recorded value
  - --verify-all (no): Verify every archive under BACKUP_BASE, aggregate statistics
  - --restore ARCHIVE (no): Extract archive to target with full lifecycle management
  - --target PATH (no): Specify extraction destination (required with --restore)
  - --only PATH (no): Extract only specific path(s) from archive (repeatable, partial extraction)
  - --stop-docker (no): Stop Docker before extraction, restart after (OS-aware: Unraid/OMV/Linux)
  - --force (no): Skip confirmation prompts, auto-create target directory
  - --no-verify (no): Skip pre-restore checksum verification (not recommended)
  - --corruption-report (no): Show watchtower's corruption log aggregated by path with current SHA status
  - --host HOSTNAME (no): Read another host's corruption report (for cross-machine restore)
  - --prune-checksums (no): Bulk-delete orphan checksum entries (distributed index cleanup)
  - --older-than DURATION (no): Specify retention threshold for prune-checksums (Nd/Nm/Ny format, e.g., 5y)
  - --commit (no): Actually delete candidates in prune-checksums (default is dry-run preview)
  - --dry-run (no): Show planned actions without modifying anything (global, affects restore and prune)
  - -c, --config FILE (no): Specify config file path (default /boot/config/auto_backupper.cfg)
  - -h, --help (no): Display usage with examples and archive target hints

GAPS:
  [HIGH] --corruption-report cross-reference with watchtower logs (status=missing, effort=large) [analysis]
      bash: Displays per-host append-only corruption log aggregated by path with current SHA status (BAD=active corruption, OK=stale entry, -=gone, ?=unknown); loads historical counts; supports --host HOSTNAME override for cross-machine restore on replacement hardware; lists available host reports if requested host missing; read-only, no lock needed; line 1158-1250
      py:   no python port exists
      loc:  cmd_corruption_report() lines 1158-1250
  [HIGH] --inspect ARCHIVE shows tar contents (status=missing, effort=small) [analysis]
      bash: Displays tar file listing with verbose output (perms, owner, size, date) up to 100 entries; counts total entries in archive; gracefully handles corrupt archives with || true guards; auto-detects compression from extension; line 781-812
      py:   no python port exists
      loc:  cmd_inspect() lines 781-812
  [HIGH] --list command with optional glob pattern (status=missing, effort=medium) [analysis]
      bash: Lists all archives under BACKUP_BASE, filtered by optional glob pattern against basename; categorizes by top-level directory (systems/shares/services/other); annotates with file size, modification date, checksum presence [chk]/[NO CHK], and corruption history [HIST-CORRUPT×N]; line 695-777
      py:   no python port exists
      loc:  cmd_list() lines 695-777
  [HIGH] --prune-checksums bulk-delete orphan checksum entries (status=missing, effort=large) [analysis]
      bash: Deletes stale checksum files from .checksums/ tree only when their data file is missing (data file present = never delete); requires --older-than DURATION in strict Nd/Nm/Ny format; defaults to dry-run preview; --commit required for actual deletion with confirmation (skipped with --force); preserves full candidate list for out-of-band inspection; cleans empty subdirectories afterward; line 1269-1361
      py:   no python port exists
      loc:  cmd_prune_checksums() lines 1269-1361
  [HIGH] --restore ARCHIVE --target PATH with options (status=missing, effort=large) [analysis]
      bash: Extracts archive to target directory with comprehensive pre/post checks: pre-restore verification (skippable with --no-verify), target directory creation (with confirmation), Docker stop/restart (--stop-docker), partial extraction (--only PATH), confirmation prompts (bypassed with --force), detailed plan display before execution, dry-run mode (--dry-run), and graceful Docker recovery on exit; returns 0 on success, 1 on user abort or extraction failure; line 923-1140
      py:   no python port exists
      loc:  cmd_restore() lines 923-1140
  [HIGH] --stop-docker lifecycle management (status=missing, effort=large) [analysis]
      bash: Stops Docker before extraction and automatically restarts after; on Unraid uses /etc/rc.d/rc.docker with status polling (timeout 60s default); on other Linux records running containers via docker ps, stops them with timeout, and restarts them individually; includes graceful recovery via trap on abnormal exit; line 596-687
      py:   no python port exists
      loc:  docker_stop_for_restore() lines 596-643; docker_start_after_restore() lines 645-674; on_exit() trap lines 681-687
  [HIGH] --verify ARCHIVE checksum verification (status=missing, effort=small) [analysis]
      bash: Verifies single archive SHA256 against recorded checksum file; loads corruption history and annotates with [HIST-CLEARED] if previously flagged but now clean; distinct return codes for each failure mode (NO_CHECKSUM=3, MISMATCH=1, HASH_ERROR=4, NO_BASE=2, OK=0); line 816-850
      py:   no python port exists
      loc:  cmd_verify() lines 816-850
  [HIGH] --verify-all checks every archive (status=missing, effort=medium) [analysis]
      bash: Scans all tar archives under BACKUP_BASE, verifies each against recorded checksum, aggregates statistics (ok/failed/missing/cleared/chronic), annotates prior-corruption events with [HIST-CLEARED] and [FAIL] with chronic flag; returns 1 if any actually failed (missing checksums don't count as failure); line 854-910
      py:   no python port exists
      loc:  cmd_verify_all() lines 854-910
  [HIGH] 10-minute timeout on sha256sum to catch frozen disks (status=missing, effort=small) [analysis]
      bash: Uses timeout 600 on sha256sum command; mirrored from auto-backupper; prevents wedging on stale FUSE mounts or frozen storage; returns HASH_ERROR if timeout; line 457
      py:   no python port exists
      loc:  verify_archive() line 457
  [HIGH] Atomic mutex for restore operations (status=missing, effort=small) [analysis]
      bash: Only restore mode acquires lock at /var/lock/auto_restorer.lock via flock -n; write PID into lockfile for external attribution; FD stays open via exec 200> so lock held for script lifetime; list/inspect/verify/corruption-report are read-only and don't lock; line 1367-1383
      py:   no python port exists
      loc:  Execution section lines 1367-1383; LOCKFILE constant line 43
  [HIGH] Enforce root privilege requirement (status=missing, effort=small) [analysis]
      bash: Checks $EUID -ne 0 at startup; exits with code 1 and error message if not root; line 87-90
      py:   no python port exists
      loc:  Root check lines 87-90
  [HIGH] Error handling via set -Eeuo pipefail (status=missing, effort=small) [analysis]
      bash: Enables -e (exit on error), -u (undefined var error), -o pipefail (error in any pipe stage), -E (ERR trap inheritance); line 35
      py:   no python port exists
      loc:  set -Eeuo pipefail line 35
  [HIGH] Graceful Docker recovery on abnormal exit (status=missing, effort=small) [analysis]
      bash: Trap on EXIT checks DOCKER_WAS_STOPPED flag; if true, attempts docker restart via docker_start_after_restore; prevents leaving Docker stopped if script crashes mid-restore; line 679-687
      py:   no python port exists
      loc:  on_exit() function lines 681-687; trap registration line 687; DOCKER_WAS_STOPPED flag line 679
  [HIGH] Handle extraction failure and Docker recovery (status=missing, effort=small) [analysis]
      bash: Captures tar exit code; if non-zero, logs ERROR, still attempts Docker restart if stopped, returns 1; if success, restarts Docker and logs RESTORE SUCCEEDED; line 1119-1139
      py:   no python port exists
      loc:  cmd_restore() lines 1119-1139
  [HIGH] Load and aggregate watchtower corruption log (status=missing, effort=medium) [analysis]
      bash: Loads per-host append-only log at $BACKUP_BASE/.checksums/<hostname>_corruption_report.txt; parses [<date>] CORRUPTION: <path> format; aggregates into associative array CORRUPTION_COUNTS[path]=count for O(1) lookups; safe to call multiple times; missing report is not an error (empty map); line 488-552
      py:   no python port exists
      loc:  load_corruption_report() lines 528-545; hist_corrupt_count() lines 550-552; CORRUPTION_COUNTS array line 488
  [HIGH] Locate dated checksum file with glob fallback (status=missing, effort=small) [analysis]
      bash: Resolves <archive>.sha256 with _<YYYYMMDD> discovery-date suffix; uses nullglob to find all siblings; returns newest discovery date if multiples exist (lexicographic sort); returns 0=found, 1=file not under BACKUP_BASE (NO_BASE), 2=under base but no checksum (NO_CHECKSUM); line 395-422
      py:   no python port exists
      loc:  checksum_find_path() lines 395-422
  [HIGH] OS family detection (Unraid/OMV/Linux) (status=missing, effort=small) [analysis]
      bash: Checks /etc/unraid-version (Unraid), omv-notify command (OMV), else generic Linux; used to pick Docker management strategy; line 556-564
      py:   no python port exists
      loc:  detect_os() lines 556-564
  [HIGH] Only delete checksums whose data file is missing (status=missing, effort=small) [analysis]
      bash: Core safety invariant: before deleting checksum, checks if ${BACKUP_BASE}/${data_rel} exists; skips deletion if data present; protects against leaving present-but-unverifiable backups until watchtower re-stamps; line 1312-1314
      py:   no python port exists
      loc:  cmd_prune_checksums() lines 1312-1314
  [HIGH] Structured logging with timestamp, verbosity levels, and rotation (status=missing, effort=medium) [analysis]
      bash: Logs to both stdout and /var/log/auto_restorer.log; ISO 8601 UTC timestamps for each entry; verbosity levels (error=2, phase=3, info=4, debug=99); uses copytruncate rotation when size exceeds 10MB; keeps 5 backups; log level detection from message prefix (FATAL/CRITICAL/ERROR/WARN/===//PHASE:/DEBUG:); per-line buffering via echo >> (no held FD); line 42-170
      py:   no python port exists
      loc:  rotate_logs() lines 100-127; rotate_log_if_needed() lines 132-135; _log_verbosity_threshold() lines 139-147; _log_level_for() lines 151-158; log() lines 160-170; LOGFILE/LOG_MAX_SIZE/LOG_BACKUPS constants lines 42-50
  [HIGH] Verify single archive with distinct return codes per failure mode (status=missing, effort=small) [analysis]
      bash: Returns specific exit codes: 0=OK, 1=MISMATCH, 2=NO_BASE, 3=NO_CHECKSUM, 4=HASH_ERROR; echoes status token on stdout; mirrors auto-backupper's 10-minute timeout on sha256sum to catch stale FUSE/frozen disk; stripping whitespace from checksum file; line 433-468
      py:   no python port exists
      loc:  verify_archive() lines 433-468
  [MEDIUM] --commit enables actual deletion in prune-checksums (status=missing, effort=small) [analysis]
      bash: Without --commit, prune-checksums is a dry-run preview (list_file preserved); with --commit, prompts for confirmation (skipped if --force), deletes candidates, and cleans temp file; line 74, 329, 1336-1360
      py:   no python port exists
      loc:  PRUNE_COMMIT="false" line 74; --commit flag line 329; usage in cmd_prune_checksums lines 1336-1360
  [MEDIUM] --dry-run global flag (status=missing, effort=small) [analysis]
      bash: Applicable to --restore and --prune-checksums; shows planned actions without modifying anything; logs [DRY] prefix for planned operations; in restore shows tar command that would be run; in prune shows candidates but doesn't delete; line 62, 322, 597-599, 646-648, 1090-1095, 1336-1340
      py:   no python port exists
      loc:  DRY_RUN="false" line 62; --dry-run flag line 322; usage throughout cmd_restore and cmd_prune_checksums
  [MEDIUM] --force skips confirmation prompts and auto-creates target (status=missing, effort=small) [analysis]
      bash: Disables confirmation() prompts everywhere; automatically creates missing target directory; used in list prune, restore, and prune-checksums commands; line 67, 321, 914-921, 997-1006, 1343-1346
      py:   no python port exists
      loc:  FORCE="false" line 67; --force arg line 321; confirm() function lines 914-921; usage in cmd_restore lines 997-1006; usage in cmd_prune_checksums lines 1343-1346
  [MEDIUM] --host HOSTNAME read another machine's corruption report (status=missing, effort=small) [analysis]
      bash: Allows operator to specify alternate hostname for reading cross-host reports; applies to --corruption-report; defaults to local short hostname uppercased; --host values are NOT uppercased to support legacy case-sensitive reports; line 78, 298-301, 504-507
      py:   no python port exists
      loc:  HOST_OVERRIDE="" line 78; --host arg parsing lines 298-301; corruption_report_path() lines 504-507
  [MEDIUM] --no-verify skips pre-restore checksum verification (status=missing, effort=small) [analysis]
      bash: Bypasses the pre-restore checksum check entirely (only affects restore, not list/verify operations); logs WARN and proceeds directly to extraction; reduces safety but acceptable for operator override; line 68, 321, 952-991
      py:   no python port exists
      loc:  VERIFY_BEFORE_RESTORE="true" line 68; --no-verify flag line 321; usage in cmd_restore lines 952-991
  [MEDIUM] --older-than DURATION for prune-checksums (status=missing, effort=small) [analysis]
      bash: Parses duration string (e.g., 5y, 12m, 365d) into cutoff date via parse_duration_to_cutoff(); strict regex validation of Nd/Nm/Ny grammar; approximate month (30d) and year (365d); mandatory with --prune-checksums; line 73, 325-327, 357-372, 1275-1280
      py:   no python port exists
      loc:  PRUNE_OLDER_THAN="" line 73; --older-than parsing lines 325-327; parse_duration_to_cutoff() lines 357-372; usage in cmd_prune_checksums lines 1275-1280
  [MEDIUM] --restore --only PATH (repeatable) partial extraction (status=missing, effort=small) [analysis]
      bash: Allows specifying multiple --only arguments to extract only specific paths from archive; passes verbatim to tar as positional MEMBERS arguments; preview shows first 10 matching entries; line 84, 314-317, 1029-1049, 1084-1116
      py:   no python port exists
      loc:  ONLY_PATHS=() line 84; argument parsing lines 314-317; cmd_restore usage lines 1029-1049, 1084-1116
  [MEDIUM] -c, --config FILE global option (status=missing, effort=small) [analysis]
      bash: Specifies config file path (default /boot/config/auto_backupper.cfg); supports both --config=PATH and --config PATH forms; parsed early in arg loop before other args so config-defined values are available; if file missing, gracefully continues with hardcoded defaults; line 41, 179-194, 331
      py:   no python port exists
      loc:  DEFAULT_CONFIG_FILE line 41; config parsing loop lines 179-194; arg handler lines 331
  [MEDIUM] Auto-detect tar compression from extension (status=missing, effort=small) [analysis]
      bash: Maps .tar.gz/.tgz -> -z, .tar.bz2/.tbz2 -> -j, .tar.xz/.txz -> -J, .tar.zst -> --zstd, .tar -> empty; returns appropriate short flag for tar; line 569-581
      py:   no python port exists
      loc:  tar_decompress_flag() lines 569-581
  [MEDIUM] Command dispatch via MODE variable and case statement (status=missing, effort=small) [analysis]
      bash: Central case statement dispatches to cmd_* functions based on MODE; ensures only one command is executed per invocation; line 1385-1396
      py:   no python port exists
      loc:  Execution dispatch lines 1385-1396
  [MEDIUM] Complete argument parsing with early --config extraction (status=missing, effort=small) [analysis]
      bash: Two-pass approach: first pass extracts --config early, sources file, then full arg loop handles all modes and flags; case statement dispatch on MODE; error on unknown args; supports both --flag=value and --flag value forms; line 179-345
      py:   no python port exists
      loc:  Argument parsing lines 173-345
  [MEDIUM] Detailed pre-restore operation plan display (status=missing, effort=small) [analysis]
      bash: Shows archive, target, flags (stop-docker, dry-run, force), partial extraction info, history markers, first 10 archive entries; warns if target is /; warns if file has prior corruption history; all before confirmation; line 1009-1071
      py:   no python port exists
      loc:  cmd_restore() lines 1009-1071
  [MEDIUM] Detect chronic/recurring corruption (status=missing, effort=small) [analysis]
      bash: Loads history, if prior events exist tags failures with '(chronic — N prior event(s))'; on OK output shows '[HIST-CLEARED — N prior event(s), now clean]'; line 829-849
      py:   no python port exists
      loc:  cmd_verify() lines 829-849
  [MEDIUM] Extract discovery date from checksum filename (status=missing, effort=small) [analysis]
      bash: Regex matches _<8 digits>.sha256$ suffix; extracts YYYYMMDD; compares numerically (with 10# base prefix for octal safety); line 1301-1307
      py:   no python port exists
      loc:  cmd_prune_checksums() lines 1301-1307
  [MEDIUM] Generic Linux Docker container stop/restart (status=missing, effort=medium) [analysis]
      bash: Records running containers via docker ps --format; stops all with timeout flag matching DOCKER_STOP_TIMEOUT; restarts each individually (logging warnings on failure); uses xargs -r to avoid invoking docker with no args; cleans container list file on restart; line 625-641, 662-671
      py:   no python port exists
      loc:  docker_stop_for_restore() lines 625-641; docker_start_after_restore() lines 662-671
  [MEDIUM] Interactive confirmation with --force bypass (status=missing, effort=small) [analysis]
      bash: confirm() function prompts for y/Y, returns 0 on yes, 1 on no; bypassed entirely if --force=true (returns 0); used for target creation, restore proceed, and prune deletion; line 914-921
      py:   no python port exists
      loc:  confirm() function lines 914-921
  [MEDIUM] Map file status to corruption report column (status=missing, effort=small) [analysis]
      bash: Three-part status: (1) file exists check, (2) checksum verification, (3) mapping to BAD/OK/-/? tokens; BAD=currently fails, OK=passes now, -=file gone, ?=unknown; line 1214-1240
      py:   no python port exists
      loc:  cmd_corruption_report() lines 1214-1240
  [MEDIUM] Normalize hostname for report cross-reference (status=missing, effort=small) [analysis]
      bash: Uses hostname | cut -d. -f1 | tr to uppercase; consistent with auto-backupper, watchtower, warphole; short hostname only (strip domain); --host values NOT uppercased; line 505, 1168
      py:   no python port exists
      loc:  corruption_report_path() line 505; cmd_corruption_report() line 1168
  [MEDIUM] Parse duration string to cutoff date (status=missing, effort=small) [analysis]
      bash: Converts 'Nd', 'Nm', 'Ny' (e.g., 5y, 12m, 365d) to YYYYMMDD cutoff via date -d; strict regex validation; approximate month (30d) and year (365d); returns 1 on invalid format; line 357-372
      py:   no python port exists
      loc:  parse_duration_to_cutoff() lines 357-372
  [MEDIUM] Partial extraction via --only with tar positional args (status=missing, effort=small) [analysis]
      bash: ONLY_PATHS array holds user-supplied paths; passed to tar as positional MEMBERS selection at end of argv; pre-restore verification still checks entire archive; preview shows first 10 matching entries via tar with user paths supplied; line 84, 314-317, 1040-1049, 1084-1116
      py:   no python port exists
      loc:  cmd_restore() lines 1084-1116, 1040-1049
  [MEDIUM] Preserve file permissions and ownership on extract (status=missing, effort=small) [analysis]
      bash: Uses tar -p (preserve permissions) and --same-owner (preserve UID/GID); important for appdata where container UIDs must match; both are explicit (not relying on root defaults); line 1097-1116
      py:   no python port exists
      loc:  cmd_restore() lines 1097-1116
  [MEDIUM] Unraid-specific Docker stop/start via rc.d (status=missing, effort=medium) [analysis]
      bash: Calls /etc/rc.d/rc.docker stop with status polling and 60s timeout; falls back to force_stop if polling times out; logs warnings if rc.d not found; on restart: calls rc.d start if found; line 606-623, 656-659
      py:   no python port exists
      loc:  docker_stop_for_restore() lines 606-623; docker_start_after_restore() lines 656-659
  [MEDIUM] Write candidate list to temp file for inspection (status=missing, effort=small) [analysis]
      bash: Creates temp file via mktemp; writes qualified candidates (orphan, older than cutoff) one per line; preserves on dry-run for operator review; deletes after commit; enables out-of-band audit; line 1293-1338
      py:   no python port exists
      loc:  cmd_prune_checksums() lines 1293-1338
  [LOW] -h, --help display usage (status=missing, effort=small) [analysis]
      bash: Shows detailed usage with examples, archive target hints, and all command descriptions; comprehensive documentation of each mode and flag; line 199-265, 332
      py:   no python port exists
      loc:  usage() lines 199-265; -h/--help handler line 332
  [LOW] Annotate files with corruption history in listing (status=missing, effort=small) [analysis]
      bash: Loads corruption report once at start of list; annotates each file with [HIST-CORRUPT] if flagged once, [HIST-CORRUPT×N] if multiple times; line 703, 756-762
      py:   no python port exists
      loc:  cmd_list() lines 703, 756-762
  [LOW] Archive categorization by layout (systems/shares/services/other) (status=missing, effort=small) [analysis]
      bash: Categorizes archives into systems/, shares/, services/, or other based on top-level directory; prints separate sections with category-specific path stripping; sorts archives alphabetically within category (via find -print0 | sort -z); line 725-773
      py:   no python port exists
      loc:  cmd_list() lines 725-773
  [LOW] Comprehensive verification statistics aggregation (status=missing, effort=small) [analysis]
      bash: Tracks ok/failed/missing/cleared/chronic counts; outputs summary line with totals; outputs history line if any cleared or chronic detected; example 'Summary: 150 total, 148 verified, 2 failed, 0 without checksum'; line 866-904
      py:   no python port exists
      loc:  cmd_verify_all() lines 866-904
  [LOW] Create missing target directory with confirmation (status=missing, effort=small) [analysis]
      bash: Detects if target doesn't exist; prompts for creation (skipped in dry-run and with --force); uses mkdir -p; returns 1 if user declines or creation fails; line 994-1007
      py:   no python port exists
      loc:  cmd_restore() lines 994-1007
  [LOW] Custom PATH environment variable (status=missing, effort=small) [analysis]
      bash: Overrides PATH at line 2 to include /sbin, /opt/bin, standard locations; ensures critical tools (Docker, rc.d) are found; line 2
      py:   no python port exists
      loc:  PATH override line 2
  [LOW] Format bytes as human-readable with units (status=missing, effort=small) [analysis]
      bash: Uses awk to convert bytes to B/K/M/G/T with single decimal place; thresholds at 1024-byte boundaries; line 375-384
      py:   no python port exists
      loc:  human_size() lines 375-384
  [LOW] Graceful tar preview on corrupt archives (status=missing, effort=small) [analysis]
      bash: Uses || true guards so corrupt archive tar errors don't abort; shows whatever is readable; line 802-808
      py:   no python port exists
      loc:  cmd_inspect() lines 802-808
  [LOW] List available host reports when requested report missing (status=missing, effort=small) [analysis]
      bash: When --host report not found, lists all *_corruption_report.txt files in .checksums/ so operator knows what's available; helpful for replacement hardware restore; line 1177-1189
      py:   no python port exists
      loc:  cmd_corruption_report() lines 1177-1189
  [LOW] Portable file size detection (stat vs wc) (status=missing, effort=small) [analysis]
      bash: Tries stat -c%s (Linux), stat -f%z (macOS), falls back to wc -c; handles stat not found gracefully; line 108-116
      py:   no python port exists
      loc:  rotate_logs() lines 108-116
  [LOW] Prevent log rotation in subshells (status=missing, effort=small) [analysis]
      bash: rotate_log_if_needed checks if BASHPID == $$ (main process); skips rotation in subshells to avoid concurrent writes; line 133
      py:   no python port exists
      loc:  rotate_log_if_needed() line 133
  [LOW] Remove empty subdirectories after pruning (status=missing, effort=small) [analysis]
      bash: After deleting checksums, uses find with -mindepth 1 -type d -empty -delete to clean now-empty subdirs under .checksums/ (never removes root); line 1359
      py:   no python port exists
      loc:  cmd_prune_checksums() line 1359
  [LOW] Show sample of prune candidates before commit (status=missing, effort=small) [analysis]
      bash: Displays first 20 candidates; if more exist, shows '... and N more'; helps operator understand scope before deletion; line 1327-1334
      py:   no python port exists
      loc:  cmd_prune_checksums() lines 1327-1334
  [LOW] Sort corruption report paths alphabetically (status=missing, effort=small) [analysis]
      bash: Loads CORRUPTION_COUNTS map; extracts keys; sorts alphabetically; iterates sorted array; ensures stable output across runs; line 1208-1212, 1216
      py:   no python port exists
      loc:  cmd_corruption_report() lines 1208-1212, 1216
  [LOW] Use nullglob to avoid literal glob patterns (status=missing, effort=small) [analysis]
      bash: Enables shopt -s nullglob before globbing operations; disables shopt -u nullglob after; prevents literal pattern names when no matches; used in checksum_find_path and list_other_host_reports; line 409-413, 515-521
      py:   no python port exists
      loc:  checksum_find_path() lines 409-413; list_other_host_reports() lines 515-521


# ===== legacy-checksum-generatator =====

BASH: A legacy checksum backfill tool for the Auto-Backupper system. It recursively scans for archives (.tar.gz, .tgz, .sql.gz, .archive.gz, .json, .zip, .7z, and others) and generates SHA256 checksums in a dated format. The script implements three main workflows: idempotent skipping of existing dated checksums that match embedded file dates, realignment of misaligned checksum suffixes to match embedded dates, promotion of legacy un-dated checksums to dated form (preserving historical hashes), and generation of new checksums when none exist. Critically, it acquires the main Auto-Backupper lock file to pause external watchtowers, enforces root-only execution, supports a --force flag to wipe and regenerate all checksums for a file, and uses atomic writes (temp file + rename) to prevent checksum corruption.

PYTHON: No python port exists.

VERIFIED GAPS: 28 (high=19 med=7 low=2); false-positives dropped: 0

CLI flags python lacks/partial:
  - [BACKUP_PATH] (no): Positional argument specifying target directory to scan for archives (defaults to /mnt/user/archive)
  - --force (no): Wipe all existing checksums (dated and legacy) and force regeneration of fresh checksums for all files

GAPS:
  [HIGH] --force flag to wipe and regenerate all checksums (status=missing, effort=small) [analysis]
      bash: Lines 40-44: loop through all args, set FORCE_REGEN=true if '--force' found; lines 106-119: if FORCE_REGEN==true, delete all dated siblings matching pattern and all legacy checksums before generating fresh ones
      py:   No python port exists.
      loc:  lines 40-44, 106-119
  [HIGH] Atomic write of checksums via temp file and rename (status=missing, effort=small) [analysis]
      bash: Lines 253-267: generate temp filename with pattern chk_path.tmp.$$; use sha256sum | awk to extract hash; write hash to temp; rename temp to final location; if write fails, delete temp and report error
      py:   No python port exists.
      loc:  lines 253-267
  [HIGH] Cleanup trap to release lock on exit (success or failure) (status=missing, effort=small) [analysis]
      bash: Lines 67-71: trap cleanup function on EXIT; cleanup() calls flock -u to unlock and suppress errors with || true
      py:   No python port exists.
      loc:  lines 67-71
  [HIGH] Conditional mv return code checking for rename operations (status=missing, effort=?) [verify-missed]
      bash: Lines 178, 239: if mv -f <source> <dest> check return code; calls to mv fail gracefully with error messages if return code is non-zero
      py:   (missed by analyzer)
      loc:  lines 178, 239, 262
  [HIGH] Detection of multiple dated checksum siblings (error condition) (status=missing, effort=small) [analysis]
      bash: Lines 131-145: count dated siblings via glob; if count > 1, log [SKIP-MULTI] and return without action; operator must use --force to clean up
      py:   No python port exists.
      loc:  lines 131-145
  [HIGH] Discovery date derivation: embedded date takes priority, mtime as fallback (status=missing, effort=medium) [analysis]
      bash: Lines 188-209: extract last embedded _YYYYMMDD from filename via grep -oE; if no embedded date, use date -r file +%Y%m%d (mtime); if neither available, log [SKIP-NO-DATE] and return
      py:   No python port exists.
      loc:  lines 188-209
  [HIGH] Exclusive lock acquisition via flock on system lock file (status=missing, effort=small) [analysis]
      bash: Lines 56-65: opens /var/lock/auto_backupper.lock on FD 9, attempts non-blocking flock; if fails, reports PID holding lock via fuser and exits 1; uses file descriptor 9 per Auto-Backupper V7.3.5 convention
      py:   No python port exists.
      loc:  lines 56-65
  [HIGH] Extract first field (hash) from sha256sum output via awk (status=missing, effort=small) [analysis]
      bash: Line 261: sha256sum file | awk '{print $1}' extracts the hash value (first column) from sha256sum output
      py:   No python port exists.
      loc:  line 261
  [HIGH] Extract last embedded _YYYYMMDD from filename (status=missing, effort=small) [analysis]
      bash: Lines 161, 198: use grep -oE '_[0-9]{8}' | tail -1 to extract last 8-digit date group preceded by underscore; falls back to empty string if not found (|| true suppresses error)
      py:   No python port exists.
      loc:  lines 161, 198
  [HIGH] Idempotent skip when dated checksum matches embedded date (status=missing, effort=medium) [analysis]
      bash: Lines 130-167: glob for existing dated checksums _YYYYMMDD.sha256; extract date suffix from filename; extract last embedded _YYYYMMDD from data filename; if date_suffix == embedded_date (or no embedded date exists), return early without action
      py:   No python port exists.
      loc:  lines 130-167
  [HIGH] Mirror tree checksum directory calculation (status=missing, effort=small) [analysis]
      bash: Lines 84-88: get_chk_dir() function computes the mirrored .checksums subdir relative to TARGET_DIR/CHECKSUM_DIR; preserves directory hierarchy from source tree
      py:   No python port exists.
      loc:  lines 84-88
  [HIGH] Positional BACKUP_PATH argument (default /mnt/user/archive) (status=missing, effort=small) [analysis]
      bash: Line 34: TARGET_DIR="${1:-/mnt/user/archive}"; accepts first positional arg or defaults to /mnt/user/archive
      py:   No python port exists.
      loc:  line 34
  [HIGH] Promotion of legacy un-dated checksums to dated form (status=missing, effort=medium) [analysis]
      bash: Lines 227-251: check for legacy checksums in two locations (in mirror .checksums/ tree or next to data file); validate legacy file is non-empty and contains sha256-shaped hex (64 hex chars); if valid, rename to dated form instead of recomputing (preserves historical hash); if invalid, skip and fall through to generation; if FORCE_REGEN, skip this entire section
      py:   No python port exists.
      loc:  lines 227-251
  [HIGH] Realignment: rename mismatched checksum suffix to match embedded date (status=missing, effort=medium) [analysis]
      bash: Lines 169-183: if existing dated checksum's suffix differs from embedded date in filename, check for conflict (both dates present), then mv old checksum to new name with correct date suffix; logs [REALIGN] message; preserves original hash content (no recompute)
      py:   No python port exists.
      loc:  lines 169-183
  [HIGH] Recursive scan for multiple archive type extensions (status=missing, effort=medium) [analysis]
      bash: Lines 277-283: find -type f with -name patterns for .tar.gz, .tgz, .sql.gz, .archive.gz, .json, .zip, .7z, and *.*; prunes .checksums directory; excludes .sha256, .sha256.tmp.*, and _corruption_report.txt files; uses -print0 and IFS read for safe filename handling
      py:   No python port exists.
      loc:  lines 277-283
  [HIGH] Regex validation of sha256 hex string: [a-fA-F0-9]{64} (status=missing, effort=small) [analysis]
      bash: Line 238: grep -qE '[a-fA-F0-9]{64}' to validate legacy checksum file contains a valid 64-char hex string
      py:   No python port exists.
      loc:  line 238
  [HIGH] Root-only execution enforcement (status=missing, effort=small) [analysis]
      bash: Lines 47-50: checks EUID -ne 0 and exits with error if not root; error message sent to stderr
      py:   No python port exists.
      loc:  lines 47-50
  [HIGH] Safe filename handling in find pipeline with null delimiter and IFS (status=missing, effort=?) [verify-missed]
      bash: Lines 281-282: find ... -print0 piped to while IFS= read -r -d '' handles filenames with spaces/newlines/special chars safely
      py:   (missed by analyzer)
      loc:  lines 281-282
  [HIGH] Validation that target directory exists (status=missing, effort=small) [analysis]
      bash: Lines 79-82: if target dir does not exist, print CRITICAL error and exit 1
      py:   No python port exists.
      loc:  lines 79-82
  [MEDIUM] Checksum directory creation via mkdir -p before write (status=missing, effort=?) [verify-missed]
      bash: Line 211: mkdir -p "$chk_dir" creates directory structure before writing checksum file
      py:   (missed by analyzer)
      loc:  line 211
  [MEDIUM] Critical errors sent to stderr (>&2) (status=missing, effort=small) [analysis]
      bash: Lines 48, 61: CRITICAL messages printed to stderr via >&2 operator; includes lock and root check errors
      py:   No python port exists.
      loc:  lines 48, 61
  [MEDIUM] Non-empty file validation before regex check (status=missing, effort=?) [verify-missed]
      bash: Line 238: [[ -s "$legacy_source" ]] checks file is non-empty before attempting regex validation; guards against empty legacy files
      py:   (missed by analyzer)
      loc:  line 238
  [MEDIUM] Nullglob shell option for safe glob handling when no matches (status=missing, effort=small) [analysis]
      bash: Lines 112, 130, 136: set nullglob before glob-based loops to prevent literal pattern string when no matches; unset afterward
      py:   No python port exists.
      loc:  lines 112, 130, 136
  [MEDIUM] Shell strict mode: set -Eeuo pipefail (status=missing, effort=small) [analysis]
      bash: Line 31: -E enables errtrap (inherit ERR trap); -e exits on any command error; -u errors on undefined variables; -o pipefail fails pipeline if any command fails
      py:   No python port exists; Python does not have direct equivalent to shell strict mode, but sys.exit() on exceptions and proper error propagation should provide similar safety.
      loc:  line 31
  [MEDIUM] Standardized status message format: [STATUS] filename (context) (status=missing, effort=small) [analysis]
      bash: Lines 143, 174, 179, 207, 240, 243, 247, 255, 263: various status messages formatted as [STATUS] or [STATUS context] followed by filename and optional context; used for skip, conflict, realign, fail, promote, skip-no-date, gen, and completion messages
      py:   No python port exists.
      loc:  lines 143, 174, 179, 207, 240, 243, 247, 255, 263
  [MEDIUM] Use $$ (current PID) in temporary filename (status=missing, effort=small) [analysis]
      bash: Line 260: tmp="${chk_path}.tmp.$$" uses bash's $$ to ensure unique temp filenames per process
      py:   No python port exists.
      loc:  line 260
  [LOW] Final summary message with lock release notification (status=missing, effort=small) [analysis]
      bash: Lines 285-288: print formatted final message indicating operation complete and that lock will be released upon exit
      py:   No python port exists.
      loc:  lines 285-288
  [LOW] Report PID of process holding lock via fuser (status=missing, effort=medium) [analysis]
      bash: Line 62: $(fuser "$LOCKFILE" 2>/dev/null) attempts to show PID of process holding the lock; stderr suppressed if fuser not available or lock not held
      py:   No python port exists.
      loc:  line 62


# ===== auto-backupper-client (PARITY INVERSION) =====

NOTE: This component inverts the usual direction of this report. It originated on
the PYTHON branch (auto-backupper-client.py) and was ported TO bash second, so
here the PYTHON edition is the broader reference and bash is the follower.

PYTHON (auto-backupper-client.py, python branch): the cross-platform desktop
backup client. Runs on Windows, macOS, and Linux. Produces FamilyBackups USER +
SYSTEM archives via stdlib tarfile/hashlib (no tar/sha256sum/rsync dependency),
delivers to local / SMB-NFS / rsync-SSH, restores locally, installs a native
scheduler (Task Scheduler / launchd / systemd-timer / cron), and on Windows uses
a VSS shadow copy for locked files (NTUSER.DAT, browser/Outlook) with skip+warn
fallback, plus registry/winget/PowerShell system inventory.

BASH (auto-backupper-client.sh, this branch): the Linux/macOS counterpart. Same
FamilyBackups contract and output format (verified: the suite's auto-restorer
verifies bash-client archives OK). Uses native tar + sha256sum/shasum + cp/rsync.

VERIFIED GAPS (bash vs python): the inherent platform gap is WINDOWS. Bash does
not run natively on Windows, so the bash client deliberately omits:
  - Windows support entirely (VSS shadow copy, registry export via reg.exe,
    winget/PowerShell inventory, Task Scheduler install). Use the .py client there.
This is by design, not a TODO: the .py client remains the Windows/universal one.

Feature parity ON Linux/macOS is COMPLETE: --backup users|system|both, all three
destinations, local restore (full + --only), --verify/--verify-all/--list/
--inspect, --install-schedule (systemd-timer+cron / launchd), --dry-run,
SYSTEM_INCOMPLETE manifest marking, server-owned retention + LOCAL_KEEP.

Minor intentional divergences from the .py client (platform-driven, not gaps):
  - macOS: shasum -a 256 when sha256sum absent; bsdtar (no GNU -S sparse flag);
    mkdir-based lock instead of flock; Full-Disk-Access probe+warn.
  - Linux/macOS only have a best-effort open-file copy (no VSS equivalent).