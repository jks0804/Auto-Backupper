#!/usr/bin/env python3
# ==============================================================================
# AUTO-BACKUPPER WATCHTOWER
# ==============================================================================
# Daemon that monitors, schedules, and protects backup integrity for the
# Auto-Backupper suite. A faithful port of watchtower.sh (the primary
# implementation on the repo's `bash` branch); reads the same auto_backupper.cfg.
#
# USAGE:
#   watchtower.py --monitor          Continuous daemon
#   watchtower.py --status           One-shot daemon + scheduler snapshot
#   watchtower.py --scan             One-time checksum scan (or signal daemon)
#   watchtower.py --scan --verify    Verify ALL files (or signal daemon)
#   watchtower.py --verify           Signal daemon to deep-verify
#   watchtower.py --cleanup          One-time junk cleanup (or signal daemon)
#   watchtower.py --update           Update Docker containers (or signal daemon)
#   watchtower.py --force            Wake the daemon immediately
#   watchtower.py --start-backup     Force-start a backup
#   watchtower.py --stop-backup      Force-stop a running backup
#   watchtower.py --reload [--config PATH]   Signal the daemon to reload config
#   watchtower.py --config PATH      Manually define config location
#
# The interactive dashboards (--logs, --ab-graph, --hub) are ported separately;
# until then they point at the bash watchtower.
# ==============================================================================

import os
import re
import sys
import time
import glob
import signal
import shutil
import socket
import datetime
import threading
import subprocess
from concurrent.futures import ThreadPoolExecutor, as_completed

# ==============================================================================
# 1. PATHS & CONSTANTS
# ==============================================================================
DEFAULT_CONFIG_FILE = "/boot/config/auto_backupper.cfg"
WATCHTOWER_LOGFILE = "/var/log/auto_backupper_watchtower.log"
BACKUP_LOGFILE = "/var/log/auto_backupper.log"
BACKUP_LOCKFILE = "/var/lock/auto_backupper.lock"
WATCHTOWER_LOCK = "/var/lock/ab_watchtower.lock"
PID_FILE = "/var/run/ab_watchtower.pid"
# PID file auto-backupper writes at startup; used by --stop-backup.
BACKUP_PIDFILE = "/var/run/auto_backupper.pid"

# IPC trigger files (presence = queued work; polled by smart_sleep).
TRIGGER_UPDATE = "/tmp/ab_watchtower_trigger_update"
TRIGGER_SCAN = "/tmp/ab_watchtower_trigger_scan"
TRIGGER_VERIFY = "/tmp/ab_watchtower_trigger_verify"
TRIGGER_CONFIG = "/tmp/ab_watchtower_trigger_config"
TRIGGER_CLEANUP = "/tmp/ab_watchtower_trigger_cleanup"
TRIGGER_FORCE = "/tmp/ab_watchtower_trigger_force"
STATUS_FILE = "/tmp/ab_watchtower.status"
ALL_TRIGGERS = (TRIGGER_SCAN, TRIGGER_UPDATE, TRIGGER_VERIFY, TRIGGER_CONFIG, TRIGGER_CLEANUP, TRIGGER_FORCE)

LAST_RUN_BACKUP = "/tmp/auto_backupper_last_run_backup"
LAST_RUN_CLEANUP = "/tmp/auto_backupper_last_run_cleanup"
LAST_RUN_VERIFY = "/tmp/auto_backupper_last_run_verify"
LAST_RUN_UPDATE = "/tmp/auto_backupper_last_run_update"

_DEFAULT_HOSTNAME = socket.gethostname().split(".")[0].upper()

OS_TYPE = "linux"
LOGFILE = WATCHTOWER_LOGFILE  # the daemon logs here
CORRUPTION_REPORT = ""        # derived after config load
LAST_LOGGED_THREADS = -1      # prevents thread-count log flooding
_corruption_lock = threading.Lock()
_sigusr1 = False              # set by the daemon SIGUSR1 handler

# ==============================================================================
# 2. CONFIGURATION DEFAULTS (matches watchtower.sh; cfg overrides)
# ==============================================================================
CONFIG = {
    "STARTUP_MODE": "monitor",
    "HOSTNAME_VAR": _DEFAULT_HOSTNAME,
    "WATCH_DIR": "/mnt/user/backup",
    "CHECKSUM_DIR": ".checksums",
    "SHARES_BASE_FOLDER": "/mnt/user",
    "MAIN_BACKUP_SCRIPT": "/usr/local/bin/auto_backupper.sh",
    "MONITOR_INTERVAL": "300",
    "CPU_THREADS": "1",
    "LOG_VERBOSITY": "info",
    "LOG_MAX_SIZE": str(10 * 1024 * 1024),
    "LOG_BACKUPS": "5",
    "CORRUPTION_REPORT_MAX_SIZE": str(1048576),

    # Global verify toggle: when true, every scan also verifies existing files.
    "ENABLE_VERIFICATION": "false",

    # --- Docker updater ---
    "UPDATE_SCHEDULER_ENABLE": "false",
    "DOCKER_UPDATE_EXCLUDE": "mariadb",

    # --- Cache monitor ---
    "ENABLE_CACHE_MONITOR": "false",
    "CACHE_DIR": "/mnt/cache",
    "ARRAY_BASE_PATH": "/mnt/user",
    "MOVER_TYPE": "unraid",
    "CACHE_THRESHOLD": "75",
    "CACHE_CRITICAL": "90",
    "FORCE_MOVER_ON_CRITICAL": "false",
    "RUN_MOVER_DURING_PARITY": "false",

    # --- Cleanup ---
    "CLEANUP_MEDIA_METADATA": "false",

    # --- Schedulers (enable + mode/value/time) ---
    "BACKUP_SCHEDULER_ENABLE": "false",
    "BACKUP_SCHEDULER_MODE": "monthly",
    "BACKUP_SCHEDULER_VALUE": "16",
    "BACKUP_SCHEDULER_TIME": "02:00",
    "CLEANUP_SCHEDULER_ENABLE": "false",
    "CLEANUP_SCHEDULER_MODE": "daily",
    "CLEANUP_SCHEDULER_VALUE": "Sun",
    "CLEANUP_SCHEDULER_TIME": "04:00",
    "VERIFY_SCHEDULER_ENABLE": "false",
    "VERIFY_SCHEDULER_MODE": "monthly",
    "VERIFY_SCHEDULER_VALUE": "28",
    "VERIFY_SCHEDULER_TIME": "03:00",
    "UPDATE_SCHEDULER_MODE": "weekly",
    "UPDATE_SCHEDULER_VALUE": "Sat",
    "UPDATE_SCHEDULER_TIME": "05:00",

    # --- Notifications ---
    "NOTIFY_WEBHOOK_URL": "",
    "NOTIFY_WEBHOOK_FORMAT": "",
}

# Set by --verify when the daemon isn't running (standalone full verify).
CLI_CONFIG = ""
CFG_TO_LOAD = DEFAULT_CONFIG_FILE


def cfg(key):
    return CONFIG.get(key, "")


def cfg_true(key):
    return CONFIG.get(key, "false") == "true"


def cfg_int(key, default=0):
    try:
        return int(str(CONFIG.get(key, default)))
    except (TypeError, ValueError):
        return default


# ==============================================================================
# 3. CONFIG LOADING (bash-syntax cfg parser, scalars only)
# ==============================================================================


def _unquote(s):
    s = s.strip()
    if len(s) >= 2 and s[0] == s[-1] and s[0] in ("'", '"'):
        return s[1:-1]
    return s


def parse_bash_config(filepath):
    if not os.path.isfile(filepath):
        return
    try:
        content = open(filepath).read()
    except OSError:
        return
    scalar = re.compile(
        r'^[ \t]*([A-Za-z_][A-Za-z0-9_]*)='
        r'''("(?:[^"\\]|\\.)*"|'[^']*'|[^\s#(]*)[ \t]*(?:#.*)?$''',
        re.M,
    )
    for m in scalar.finditer(content):
        key, raw = m.group(1), m.group(2)
        if key in CONFIG:
            CONFIG[key] = _unquote(raw)


# ==============================================================================
# 4. LOGGING
# ==============================================================================


def _log_verbosity_threshold():
    return {"error": 2, "phase": 3, "info": 4, "debug": 99}.get(cfg("LOG_VERBOSITY") or "info", 4)


def _log_level_for(msg):
    if re.match(r"^(FATAL|CRITICAL|ERROR:|ERROR |WARN:|WARN |CORRUPTION:|UPDATER WARN:|UPDATER ERROR:)", msg):
        return 2
    if re.match(r"^(===|ACTION:|STARTUP:|STATUS:|MANUAL:|RECOVERY:|CLEANUP:|SCHEDULER:|CONFIG:|NOTIFY|EVENT:|RELOAD:|LOGS:|UPDATER:|SCAN:)", msg):
        return 3
    if msg.startswith("DEBUG:"):
        return 99
    return 4


def _rotate_file(path, max_size, backups):
    if not os.path.isfile(path):
        return
    try:
        if os.path.getsize(path) < max_size:
            return
    except OSError:
        return
    last = f"{path}.{backups}"
    if os.path.isfile(last):
        try:
            os.remove(last)
        except OSError:
            pass
    for i in range(backups - 1, 0, -1):
        src, dst = f"{path}.{i}", f"{path}.{i + 1}"
        if os.path.isfile(src):
            try:
                os.replace(src, dst)
            except OSError:
                pass


def rotate_logs():
    # Copytruncate: copy then truncate so any held FD keeps the same inode.
    if not os.path.isfile(LOGFILE):
        return
    try:
        if os.path.getsize(LOGFILE) < cfg_int("LOG_MAX_SIZE", 10485760):
            return
    except OSError:
        return
    _rotate_file(LOGFILE, cfg_int("LOG_MAX_SIZE", 10485760), cfg_int("LOG_BACKUPS", 5))
    try:
        shutil.copy2(LOGFILE, f"{LOGFILE}.1")
        open(LOGFILE, "w").close()
    except OSError:
        pass


def rotate_corruption_report_if_large():
    if not CORRUPTION_REPORT or not os.path.isfile(CORRUPTION_REPORT):
        return
    try:
        if os.path.getsize(CORRUPTION_REPORT) < cfg_int("CORRUPTION_REPORT_MAX_SIZE", 1048576):
            return
    except OSError:
        return
    backups = cfg_int("LOG_BACKUPS", 5)
    _rotate_file(CORRUPTION_REPORT, cfg_int("CORRUPTION_REPORT_MAX_SIZE", 1048576), backups)
    try:
        os.replace(CORRUPTION_REPORT, f"{CORRUPTION_REPORT}.1")
        open(CORRUPTION_REPORT, "w").close()
    except OSError:
        pass


def log(msg):
    if _log_level_for(msg) <= _log_verbosity_threshold():
        line = f"{datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')} [WATCHTOWER] {msg}"
        print(line, flush=True)
        try:
            with open(LOGFILE, "a") as f:
                f.write(line + "\n")
        except OSError:
            pass
    rotate_logs()


def set_status(text):
    try:
        with open(STATUS_FILE, "w") as f:
            f.write(text)
    except OSError:
        pass


def atomic_write(target, content):
    # LAST_RUN_* markers: temp + rename so a torn write can't leave an empty
    # file that the scheduler reads as "overdue" or fails to parse.
    tmp = f"{target}.tmp.{os.getpid()}"
    try:
        with open(tmp, "w") as f:
            f.write(content + "\n")
        os.replace(tmp, target)
    except OSError:
        try:
            os.remove(tmp)
        except OSError:
            pass


# ==============================================================================
# 5. NOTIFICATIONS
# ==============================================================================


def _json_escape(s):
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\t", "\\t")


def strategy_notify_webhook(level, title, message):
    url = cfg("NOTIFY_WEBHOOK_URL")
    if not url or not shutil.which("curl"):
        return
    fmt = cfg("NOTIFY_WEBHOOK_FORMAT")
    if not fmt:
        if "discord.com" in url or "discordapp.com" in url:
            fmt = "discord"
        elif "slack.com" in url or "slack-edge.com" in url:
            fmt = "slack"
        else:
            fmt = "generic"
    prefix = {"alert": "[ALERT]", "warning": "[WARN]", "normal": "[OK]"}.get(level, "[INFO]")
    host = cfg("HOSTNAME_VAR")
    et, em = _json_escape(title), _json_escape(message)
    if fmt == "ntfy":
        pri = {"alert": "high", "warning": "default", "normal": "low"}.get(level, "default")
        subprocess.run(["curl", "-fsS", "--max-time", "10", "-H", f"Title: {title}",
                        "-H", f"Priority: {pri}", "-H", f"Tags: watchtower,{level},{host}",
                        "-d", message, url], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return
    if fmt == "discord":
        body = f'{{"username":"Watchtower@{host}","content":"{prefix} **{et}**\\n{em}"}}'
    elif fmt == "slack":
        body = f'{{"text":"*{prefix} {et}*\\n{em}\\n_host: {host}_"}}'
    elif fmt == "generic":
        ts = datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
        body = f'{{"host":"{host}","level":"{level}","title":"{et}","message":"{em}","timestamp":"{ts}","source":"watchtower"}}'
    else:
        return
    subprocess.run(["curl", "-fsS", "--max-time", "10", "-H", "Content-Type: application/json", "-d", body, url],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def send_notify(level, title, message):
    log(f"NOTIFY [{level}]: {title} - {message}")
    # Webhook fires alongside the OS-native notifier (no-op when URL is empty).
    strategy_notify_webhook(level, title, message)
    if OS_TYPE == "unraid" and os.access("/usr/local/emhttp/webGui/scripts/notify", os.X_OK):
        subprocess.run(["/usr/local/emhttp/webGui/scripts/notify", "-e", title, "-s", "WATCHTOWER",
                        "-d", message, "-i", level], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return
    if shutil.which("notify-send"):
        subprocess.run(["notify-send", "-u", level, title, message],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


# ==============================================================================
# 6. CORE TOOLS
# ==============================================================================


def get_thread_count():
    t = cfg("CPU_THREADS") or "1"
    if t.lower() == "all":
        return os.cpu_count() or 1
    if t.isdigit() and int(t) > 0:
        return int(t)
    return 1


def smart_sleep(duration):
    # Wake every 3s to check for trigger files (and the SIGUSR1 flag) so queued
    # work fires within a few seconds instead of waiting the full interval.
    global _sigusr1
    wake = time.time() + duration
    while time.time() < wake:
        if _sigusr1:
            _sigusr1 = False
            return
        if any(os.path.isfile(t) for t in ALL_TRIGGERS):
            return
        time.sleep(3)


def _pgrep(pattern):
    return subprocess.run(["pgrep", "-f", pattern], stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL).returncode == 0


def file_is_stable(path):
    # Size unchanged across a 1s window => not actively being written.
    try:
        s1 = os.path.getsize(path)
        time.sleep(1)
        s2 = os.path.getsize(path)
    except OSError:
        return False
    return s1 == s2


def is_backup_running():
    # A held exclusive flock on the backup lockfile means a backup is running.
    if not os.path.isfile(BACKUP_LOCKFILE):
        return False
    import fcntl

    try:
        fd = open(BACKUP_LOCKFILE, "r")
    except OSError:
        return False
    try:
        fcntl.flock(fd, fcntl.LOCK_SH | fcntl.LOCK_NB)
        fcntl.flock(fd, fcntl.LOCK_UN)
        return False
    except OSError:
        return True
    finally:
        fd.close()


def is_mover_running():
    return _pgrep("/usr/local/sbin/mover") or _pgrep(r"\bmover\b")


def is_parity_running():
    ini = "/var/local/emhttp/var.ini"
    if os.path.isfile(ini):
        try:
            for line in open(ini):
                if line.startswith("mdResync"):
                    val = line.split("=", 1)[1].strip().strip('"').lower()
                    if val in ("1", "true", "yes", "on"):
                        return True
        except OSError:
            pass
    return _pgrep("mdcmd.*check")


def is_array_started():
    if OS_TYPE != "unraid":
        return os.path.isdir(cfg("ARRAY_BASE_PATH"))
    try:
        if os.path.isfile("/var/local/emhttp/state"):
            with open("/var/local/emhttp/state") as f:
                if any(l.strip() == "started" for l in f):
                    return True
    except OSError:
        pass
    return os.path.ismount("/mnt/user")


# ==============================================================================
# 7. CACHE MANAGER
# ==============================================================================


def get_cache_usage():
    try:
        out = subprocess.run(["df", "-P", cfg("CACHE_DIR")], capture_output=True, text=True).stdout
        line = out.splitlines()[1]
        return int(line.split()[4].rstrip("%"))
    except Exception:
        return 0


def trigger_mover():
    log(f"ACTION: Triggering Mover ({cfg('MOVER_TYPE')})...")
    if cfg("MOVER_TYPE") == "internal":
        cache, array = cfg("CACHE_DIR"), cfg("ARRAY_BASE_PATH")
        for root, _, files in os.walk(cache):
            for fn in files:
                if fn == ".abpartial":
                    continue
                src = os.path.join(root, fn)
                if file_is_stable(src):
                    rel = os.path.relpath(src, cache)
                    dest = os.path.join(array, rel)
                    os.makedirs(os.path.dirname(dest), exist_ok=True)
                    subprocess.run(["rsync", "-a", "--remove-source-files", src, dest])
        subprocess.run(["find", cache, "-type", "d", "-empty", "-delete"])
        return
    mover = "/usr/local/sbin/mover" if os.access("/usr/local/sbin/mover", os.X_OK) else shutil.which("mover")
    if mover and os.access(mover, os.X_OK):
        subprocess.Popen([mover, "start"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    else:
        log("ERROR: Mover binary not found.")


def manage_cache_state():
    if not cfg_true("ENABLE_CACHE_MONITOR"):
        return
    if not is_array_started():
        return
    if is_mover_running():
        return
    usage = get_cache_usage()
    if usage >= cfg_int("CACHE_CRITICAL", 90):
        send_notify("alert", "Cache Critical", f"Cache is at {usage}%")
        if is_backup_running() and not cfg_true("FORCE_MOVER_ON_CRITICAL"):
            return
        trigger_mover()
        return
    if usage >= cfg_int("CACHE_THRESHOLD", 75):
        if is_backup_running():
            return
        if is_parity_running() and not cfg_true("RUN_MOVER_DURING_PARITY"):
            return
        log(f"Cache at {usage}% (Threshold {cfg('CACHE_THRESHOLD')}%). Triggering Mover.")
        trigger_mover()


# ==============================================================================
# 8. DOCKER AUTO-UPDATER
# ==============================================================================


def update_container_unraid(container):
    if subprocess.run(["/usr/local/emhttp/plugins/dynamix.docker.manager/scripts/update_container", container],
                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
        log(f"UPDATER: [Unraid] Successfully updated {container}.")
        return True
    log(f"UPDATER ERROR: [Unraid] Failed to update {container}.")
    return False


def update_container_compose(container):
    # Prefer the v2 "docker compose" plugin; fall back to legacy docker-compose.
    if subprocess.run(["docker", "compose", "version"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
        compose = ["docker", "compose"]
    elif shutil.which("docker-compose"):
        compose = ["docker-compose"]
    else:
        log(f"UPDATER WARN: No 'docker compose' or 'docker-compose' available. Cannot update {container} via compose.")
        return False

    compose_file = _docker_inspect(container, '{{ index .Config.Labels "com.docker.compose.project.config_files" }}')
    if not compose_file:
        work_dir = _docker_inspect(container, "{{ .Config.WorkingDir }}")
        cand = os.path.join(work_dir, "docker-compose.yml") if work_dir else ""
        if cand and os.path.isfile(cand):
            compose_file = cand
    if compose_file and os.path.isfile(compose_file):
        log(f"UPDATER: [Compose] Updating {container} via {compose_file} using '{' '.join(compose)}'...")
        pull = subprocess.run(compose + ["-f", compose_file, "pull", container]).returncode == 0
        if pull and subprocess.run(compose + ["-f", compose_file, "up", "-d", container]).returncode == 0:
            log("UPDATER: [Compose] Success.")
            return True
    return False


def _docker_inspect(name, fmt):
    try:
        return subprocess.run(["docker", "inspect", f"--format={fmt}", name],
                              capture_output=True, text=True).stdout.strip()
    except Exception:
        return ""


def run_docker_update_task():
    set_status("Checking Containers")
    log("UPDATER: Starting Container Check...")
    if not shutil.which("docker"):
        log("UPDATER: docker not available. Skipping.")
        set_status("Idle")
        return
    exclude = set(cfg("DOCKER_UPDATE_EXCLUDE").split())
    names = subprocess.run(["docker", "ps", "--format", "{{.Names}}"], capture_output=True, text=True).stdout.split()
    for container in names:
        if container in exclude:
            continue
        image_name = _docker_inspect(container, "{{.Config.Image}}")
        current_id = _docker_inspect(container, "{{.Image}}")
        if subprocess.run(["docker", "pull", image_name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0:
            log(f"UPDATER WARN: Failed to pull {image_name}")
            continue
        new_id = _docker_inspect(image_name, "{{.Id}}")
        if current_id != new_id:
            set_status(f"Updating {container}")
            log(f"UPDATER: Update found for {container}. Applying...")
            send_notify("normal", "Auto-Updater", f"Updating {container}...")
            if OS_TYPE == "unraid":
                update_container_unraid(container)
            elif not update_container_compose(container):
                log(f"UPDATER: [Manual] New image downloaded for {container}. Restart manually.")
                send_notify("warning", "Update Ready", f"New image for {container}. Restart manually.")
    log("UPDATER: Job Finished.")
    set_status("Idle")


# ==============================================================================
# 9. SCHEDULER UTILS
# ==============================================================================


def should_run_schedule(mode, value, time_target, last_run_file):
    today = datetime.datetime.now().strftime("%Y%m%d")
    if os.path.isfile(last_run_file):
        try:
            if open(last_run_file).read().strip() == today:
                return False
        except OSError:
            pass

    now = datetime.datetime.now()
    try:
        th, tm = (int(x) for x in time_target.split(":"))
    except (ValueError, AttributeError):
        th, tm = 0, 0
    if (now.hour, now.minute) < (th, tm):
        return False

    # Overdue recovery: if the daemon was down across a scheduled window, fire
    # now rather than waiting for the next matching day.
    days_since = 99999
    if os.path.isfile(last_run_file):
        try:
            last = open(last_run_file).read().strip()
            if re.match(r"^\d{8}$", last):
                last_dt = datetime.datetime.strptime(last, "%Y%m%d")
                days_since = (now.date() - last_dt.date()).days
        except (OSError, ValueError):
            pass
    overdue_limit = {"daily": 1, "weekly": 7, "monthly": 31, "quarterly": 93, "annually": 366}.get(mode)
    if overdue_limit is not None and days_since > overdue_limit:
        return True

    val_clean = str(value).lstrip("0") or "0"
    day_clean = str(now.day)
    if mode == "annually":
        return now.month == 1 and day_clean == val_clean
    if mode == "quarterly":
        return now.month in (1, 4, 7, 10) and day_clean == val_clean
    if mode == "monthly":
        return day_clean == val_clean
    if mode == "weekly":
        return now.strftime("%a").lower() == str(value).lower()
    if mode == "daily":
        return True
    return False


def check_backup_scheduler():
    if not cfg_true("BACKUP_SCHEDULER_ENABLE") or is_backup_running():
        return
    if should_run_schedule(cfg("BACKUP_SCHEDULER_MODE"), cfg("BACKUP_SCHEDULER_VALUE"),
                           cfg("BACKUP_SCHEDULER_TIME"), LAST_RUN_BACKUP):
        log("SCHEDULER: Firing Backup Job...")
        send_notify("normal", "Backup Scheduler", "Starting auto_backupper...")
        script = cfg("MAIN_BACKUP_SCRIPT")
        if os.path.isfile(script):
            subprocess.Popen([script, f"--config={CFG_TO_LOAD}"], stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, start_new_session=True)
            atomic_write(LAST_RUN_BACKUP, datetime.datetime.now().strftime("%Y%m%d"))
        else:
            log(f"ERROR: Backup script not found at {script}. Schedule NOT marked done; will retry next cycle.")
            send_notify("alert", "Scheduler Error", f"Backup script missing: {script}")


def check_cleanup_scheduler():
    if not cfg_true("CLEANUP_SCHEDULER_ENABLE") or is_backup_running():
        return
    if should_run_schedule(cfg("CLEANUP_SCHEDULER_MODE"), cfg("CLEANUP_SCHEDULER_VALUE"),
                           cfg("CLEANUP_SCHEDULER_TIME"), LAST_RUN_CLEANUP):
        threading.Thread(target=run_cleanup_task, daemon=True).start()
        atomic_write(LAST_RUN_CLEANUP, datetime.datetime.now().strftime("%Y%m%d"))


def check_update_scheduler():
    if not cfg_true("UPDATE_SCHEDULER_ENABLE") or is_backup_running():
        return
    if should_run_schedule(cfg("UPDATE_SCHEDULER_MODE"), cfg("UPDATE_SCHEDULER_VALUE"),
                           cfg("UPDATE_SCHEDULER_TIME"), LAST_RUN_UPDATE):
        threading.Thread(target=run_docker_update_task, daemon=True).start()
        atomic_write(LAST_RUN_UPDATE, datetime.datetime.now().strftime("%Y%m%d"))


def check_verify_scheduler():
    # Returns True if it ran (so the monitor loop sleeps and skips the rest).
    if not cfg_true("VERIFY_SCHEDULER_ENABLE") or is_backup_running() or is_mover_running():
        return False
    if should_run_schedule(cfg("VERIFY_SCHEDULER_MODE"), cfg("VERIFY_SCHEDULER_VALUE"),
                           cfg("VERIFY_SCHEDULER_TIME"), LAST_RUN_VERIFY):
        log("SCHEDULER: Starting Scheduled Full Verification...")
        send_notify("warning", "Verification Started", "Scheduled deep scan active.")
        perform_scan(cfg("WATCH_DIR"), True)
        atomic_write(LAST_RUN_VERIFY, datetime.datetime.now().strftime("%Y%m%d"))
        send_notify("normal", "Verification Finished", "Deep scan complete.")
        return True
    return False


def check_manual_triggers():
    global CFG_TO_LOAD
    if os.path.isfile(TRIGGER_UPDATE):
        log("MANUAL: Trigger received for Docker Update.")
        _safe_remove(TRIGGER_UPDATE)
        run_docker_update_task()
    if os.path.isfile(TRIGGER_VERIFY):
        log("MANUAL: Trigger received for Full Verification.")
        _safe_remove(TRIGGER_VERIFY)
        send_notify("warning", "Manual Verify", "Starting deep scan...")
        perform_scan(cfg("WATCH_DIR"), True)
        send_notify("normal", "Manual Verify", "Scan complete.")
    if os.path.isfile(TRIGGER_SCAN):
        log("MANUAL: Trigger received for Quick Scan.")
        _safe_remove(TRIGGER_SCAN)
        perform_scan(cfg("WATCH_DIR"), False)
        log("MANUAL: Quick Scan Complete.")
    if os.path.isfile(TRIGGER_CONFIG):
        try:
            new_cfg = open(TRIGGER_CONFIG).read().strip()
        except OSError:
            new_cfg = ""
        if new_cfg and os.path.isfile(new_cfg):
            log(f"CONFIG: Switching config file to: {new_cfg}")
            CFG_TO_LOAD = new_cfg
            parse_bash_config(new_cfg)
        else:
            log(f"ERROR: Requested config {new_cfg} not found. Keeping previous.")
        _safe_remove(TRIGGER_CONFIG)
    if os.path.isfile(TRIGGER_CLEANUP):
        log("MANUAL: Trigger received for Cleanup.")
        _safe_remove(TRIGGER_CLEANUP)
        run_cleanup_task()
    if os.path.isfile(TRIGGER_FORCE):
        log("MANUAL: Force Trigger received. Starting immediate cycle...")
        _safe_remove(TRIGGER_FORCE)


def _safe_remove(path):
    try:
        os.remove(path)
    except OSError:
        pass


# ==============================================================================
# 10. CHECKSUM & CLEANUP LOGIC
# ==============================================================================


def warn_hostname_case_drift():
    base = cfg("WATCH_DIR")
    if not os.path.isdir(base):
        return
    canonical = cfg("HOSTNAME_VAR")
    sysd = os.path.join(base, "systems")
    if os.path.isdir(sysd):
        for entry in os.listdir(sysd):
            if os.path.isdir(os.path.join(sysd, entry)) and entry.upper() == canonical.upper() and entry != canonical:
                log(f"WARN: Found case-variant hostname directory: {sysd}/{entry}/")
                log(f"      Suite uses UPPERCASE canonical: {sysd}/{canonical}/")
                log(f'      Or set HOSTNAME_VAR="{entry}" in {CFG_TO_LOAD} to keep current behaviour.')
    chk_dir = os.path.join(base, cfg("CHECKSUM_DIR"))
    if os.path.isdir(chk_dir):
        for f in glob.glob(os.path.join(chk_dir, "*_corruption_report.txt")):
            host_part = os.path.basename(f)[: -len("_corruption_report.txt")]
            if host_part.upper() == canonical.upper() and host_part != canonical:
                log(f"WARN: Found case-variant corruption report: {f}")
                log(f"      Suite uses UPPERCASE canonical: {chk_dir}/{canonical}_corruption_report.txt")


def run_cleanup_task():
    set_status("Cleaning Junk Files")
    log("CLEANUP: Starting junk file removal...")
    base_path = (cfg("SHARES_BASE_FOLDER") or "/mnt/user").rstrip("/")

    # Apple metadata + stray .DS_Store only. (.tmp was deliberately NOT included
    # — it matches legitimate hidden dirs used by git, IDEs, nodejs, etc.)
    if os.path.isdir(base_path):
        junk_files = {".DS_Store", "._.DS_Store"}
        junk_dirs = {".AppleDB", ".AppleDesktop", ".AppleDouble", ".TemporaryItems"}
        base_depth = base_path.rstrip("/").count(os.sep)
        for root, dirs, files in os.walk(base_path):
            # Match bash `find -maxdepth 6`: entries up to 6 levels below base.
            # A dir k levels down holds files at find-depth k+1, so stop at k>5.
            if root.count(os.sep) - base_depth > 5:
                dirs[:] = []
                continue
            for d in list(dirs):
                if d in junk_dirs:
                    shutil.rmtree(os.path.join(root, d), ignore_errors=True)
                    dirs.remove(d)
            for fn in files:
                if fn in junk_files:
                    _safe_remove(os.path.join(root, fn))

    # Optional, opt-in media-metadata cleanup. .nfo/.txt are legitimate
    # Plex/Jellyfin/Kodi metadata, so this is OFF unless explicitly enabled.
    if cfg_true("CLEANUP_MEDIA_METADATA"):
        log("CLEANUP: CLEANUP_MEDIA_METADATA=true — removing .nfo/.txt from media/TV and media/Movies")
        for d in (os.path.join(base_path, "media/TV"), os.path.join(base_path, "media/Movies")):
            if os.path.isdir(d):
                for root, dirs, files in os.walk(d):
                    # Match bash `find -maxdepth 4`: files up to 4 levels below d.
                    depth = 0 if root == d else os.path.relpath(root, d).count(os.sep) + 1
                    if depth + 1 <= 4:
                        for fn in files:
                            if fn.endswith(".nfo") or fn.endswith(".txt"):
                                _safe_remove(os.path.join(root, fn))
                    if depth + 1 >= 4:
                        dirs[:] = []

    if shutil.which("docker"):
        set_status("Pruning Docker")
        log("CLEANUP: Pruning unused Docker data...")
        for args in (["image", "prune", "-f"], ["network", "prune", "-f"], ["builder", "prune", "-f"]):
            subprocess.run(["docker"] + args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    log("CLEANUP: Job Finished.")
    set_status("Idle")


def _sha256_timeout(path, timeout=600):
    try:
        r = subprocess.run(["sha256sum", path], capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return None
    if r.returncode != 0 or not r.stdout.strip():
        return None
    return r.stdout.split()[0]


def process_file(file, base, force_verify=False):
    relative = os.path.relpath(file, base)
    chk_dir = os.path.join(base, cfg("CHECKSUM_DIR"), os.path.dirname(relative))
    name = os.path.basename(relative)

    # Existing dated checksum sibling (<name>_<YYYYMMDD>.sha256)?
    existing = None
    for c in glob.glob(os.path.join(chk_dir, name + "_" + "[0-9]" * 8 + ".sha256")):
        existing = c
        break

    if existing:
        if cfg_true("ENABLE_VERIFICATION") or force_verify:
            try:
                content = open(existing).read().strip()
            except OSError:
                content = ""
            expected = content.split()[0] if content else ""
            actual = _sha256_timeout(file)
            if actual is None:
                log(f"WARN: sha256sum timed out or failed for {file} (skipping verify this pass)")
            elif expected and expected != actual:
                log(f"CORRUPTION: {file}")
                with _corruption_lock:
                    rotate_corruption_report_if_large()
                    try:
                        with open(CORRUPTION_REPORT, "a") as rf:
                            rf.write(f"[{datetime.datetime.now()}] CORRUPTION: {file}\n")
                    except OSError:
                        pass
                send_notify("alert", "Corruption Detected", file)
        return

    if not file_is_stable(file):
        return

    # First sighting → stamp today's date as the discovery suffix.
    today = datetime.datetime.now().strftime("%Y%m%d")
    new_chk = os.path.join(chk_dir, f"{name}_{today}.sha256")
    log(f"NEW CHECKSUM: {relative} ({today})")
    os.makedirs(chk_dir, exist_ok=True)
    digest = _sha256_timeout(file)
    if digest is None:
        log(f"WARN: sha256sum timed out or failed for new file {file}")
        return
    tmp = f"{new_chk}.tmp.{os.getpid()}.{threading.get_ident()}"
    try:
        with open(tmp, "w") as f:
            f.write(digest + "\n")
        os.replace(tmp, new_chk)
    except OSError:
        _safe_remove(tmp)


def perform_scan(base, verify_override=False):
    global LAST_LOGGED_THREADS
    if not os.path.isdir(base):
        return
    set_status("Verifying ALL Files" if verify_override else "Scanning New Files")
    max_jobs = get_thread_count()
    if max_jobs > 1 and max_jobs != LAST_LOGGED_THREADS:
        log(f"SCAN: Multi-threading enabled (Threads: {max_jobs})")
        LAST_LOGGED_THREADS = max_jobs

    chk_root = os.path.join(base, cfg("CHECKSUM_DIR"))
    files = []
    for root, dirs, fs in os.walk(base):
        if root == chk_root or root.startswith(chk_root + os.sep):
            dirs[:] = []
            continue
        if cfg("CHECKSUM_DIR") in dirs:
            dirs.remove(cfg("CHECKSUM_DIR"))
        if ".abpartial" in dirs:
            dirs.remove(".abpartial")
        files += [os.path.join(root, fn) for fn in fs]

    if max_jobs > 1:
        with ThreadPoolExecutor(max_workers=max_jobs) as ex:
            futures = {ex.submit(process_file, f, base, verify_override): f for f in files}
            # Collect results so a worker exception surfaces in the log instead
            # of being silently swallowed; one bad file doesn't abort the scan.
            for fut in as_completed(futures):
                try:
                    fut.result()
                except Exception as e:
                    log(f"WARN: scan worker failed for {futures[fut]}: {e}")
    else:
        for f in files:
            try:
                process_file(f, base, verify_override)
            except Exception as e:
                log(f"WARN: scan failed for {f}: {e}")
    set_status("Idle")


# ==============================================================================
# 11. --status SNAPSHOT
# ==============================================================================


def _format_age_days(d):
    if not d or not re.match(r"^\d{8}$", d):
        return "never"
    try:
        t1 = datetime.datetime.strptime(d, "%Y%m%d").date()
    except ValueError:
        return f"{d} (unparseable)"
    days = (datetime.datetime.now().date() - t1).days
    iso = f"{d[0:4]}-{d[4:6]}-{d[6:8]}"
    if days <= 0:
        return f"{iso} (today)"
    if days == 1:
        return f"{iso} (1 day ago)"
    return f"{iso} ({days} days ago)"


def _format_uptime_from_proc(pid):
    if not pid or not os.path.isdir(f"/proc/{pid}"):
        return ""
    try:
        start = os.stat(f"/proc/{pid}").st_mtime
    except OSError:
        return ""
    elapsed = int(time.time() - start)
    d, h, m = elapsed // 86400, (elapsed % 86400) // 3600, (elapsed % 3600) // 60
    if d > 0:
        return f"{d}d {h:02d}h {m:02d}m"
    if h > 0:
        return f"{h}h {m:02d}m"
    return f"{m}m"


def cmd_status(daemon_running, daemon_pid):
    hr = "================================================================"
    print(hr)
    print("                       WATCHTOWER STATUS")
    print(hr)
    if daemon_running:
        if daemon_pid:
            up = _format_uptime_from_proc(daemon_pid)
            line = f"RUNNING (PID {daemon_pid}{', up ' + up if up else ''})"
        else:
            line = "RUNNING (PID unknown — detected via lockfile)"
    else:
        line = "NOT RUNNING"
    print(f"  {'Daemon:':<22} {line}")
    if daemon_running and os.path.isfile(STATUS_FILE):
        try:
            print(f"  {'Current state:':<22} {open(STATUS_FILE).read().strip() or 'unknown'}")
        except OSError:
            pass
    print(f"  {'Config:':<22} {CFG_TO_LOAD}")
    print(f"  {'Host:':<22} {cfg('HOSTNAME_VAR')}")

    print("\nSchedule history:")
    def _read(p):
        try:
            return open(p).read().strip()
        except OSError:
            return ""
    print(f"  {'Last backup:':<22} {_format_age_days(_read(LAST_RUN_BACKUP))}")
    print(f"  {'Last cleanup:':<22} {_format_age_days(_read(LAST_RUN_CLEANUP))}")
    print(f"  {'Last verify:':<22} {_format_age_days(_read(LAST_RUN_VERIFY))}")
    print(f"  {'Last update:':<22} {_format_age_days(_read(LAST_RUN_UPDATE))}")

    print("\nLive processes:")
    print(f"  {'Backup in progress:':<22} {'yes' if is_backup_running() else 'no'}")
    print(f"  {'Mover in progress:':<22} {'yes' if is_mover_running() else 'no'}")
    cache_pct = get_cache_usage()
    print(f"  {'Cache usage:':<22} {cache_pct}%")

    print("\nPending IPC triggers:")
    for label, path in (("scan", TRIGGER_SCAN), ("verify", TRIGGER_VERIFY), ("cleanup", TRIGGER_CLEANUP),
                        ("update", TRIGGER_UPDATE), ("config", TRIGGER_CONFIG), ("force", TRIGGER_FORCE)):
        print(f"  {label + ':':<22} {'queued' if os.path.isfile(path) else '-'}")

    print("\nLogs:")
    print(f"  {'Daemon log:':<22} {LOGFILE}")
    print(f"  {'Backup log:':<22} {BACKUP_LOGFILE}")
    print(hr)
    return 0 if daemon_running else 1


# ==============================================================================
# 12. EXECUTION
# ==============================================================================


def _detect_daemon():
    # Returns (running, pid). PID file with /proc cmdline cross-check, then a
    # lockfile fallback probe (daemon up but PID file out of sync).
    running, pid = False, ""
    if os.path.isfile(PID_FILE):
        try:
            p = open(PID_FILE).read().strip()
        except OSError:
            p = ""
        if p.isdigit() and _pid_alive(int(p)):
            looks = True
            cmdline_path = f"/proc/{p}/cmdline"
            if os.access(cmdline_path, os.R_OK):
                try:
                    looks = "watchtower" in open(cmdline_path).read().replace("\0", " ")
                except OSError:
                    looks = True
            if looks:
                running, pid = True, p
            else:
                _safe_remove(PID_FILE)
        elif p:
            _safe_remove(PID_FILE)

    if not running and os.path.exists(WATCHTOWER_LOCK):
        import fcntl

        try:
            fd = open(WATCHTOWER_LOCK, "r")
            try:
                fcntl.flock(fd, fcntl.LOCK_SH | fcntl.LOCK_NB)
                fcntl.flock(fd, fcntl.LOCK_UN)
            except OSError:
                running = True  # exclusive holder = the daemon
            fd.close()
        except OSError:
            pass
    return running, pid


def _pid_alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def _daemon_signal_handler(signum, frame):
    global _sigusr1
    _sigusr1 = True
    log("EVENT: Signal received. Interrupting sleep cycle...")


def _parse_mode(argv):
    global CLI_CONFIG, CFG_TO_LOAD
    mode = f"--{cfg('STARTUP_MODE')}"
    prev = ""
    for a in argv:
        if a.startswith("--config="):
            CLI_CONFIG = a.split("=", 1)[1]
        elif prev in ("--config", "-c"):
            CLI_CONFIG = a
        prev = a
    aliases = {"--log": "--logs", "--center": "--hub", "--command-center": "--hub"}
    known = {"--monitor", "--scan", "--cleanup", "--update", "--verify", "--force",
             "--start-backup", "--stop-backup", "--reload", "--logs", "--status", "--ab-graph", "--hub"}
    verify_flag = False
    for a in argv:
        a = aliases.get(a, a)
        if a == "--verify" and "--scan" in argv:
            verify_flag = True
            continue
        if a in known:
            mode = a
    if CLI_CONFIG:
        CFG_TO_LOAD = CLI_CONFIG
    return mode, verify_flag


def notify_daemon(label, daemon_pid):
    if daemon_pid:
        print(f"Signal sent to Daemon (PID: {daemon_pid}) to {label}.")
        try:
            os.kill(int(daemon_pid), signal.SIGUSR1)
        except OSError:
            pass
    else:
        print(f"Daemon detected via lockfile (PID unknown). Queued {label} — will run within a few seconds.")


def monitor_loop():
    log(f"STARTUP: Monitor Mode Active. Interval: {cfg('MONITOR_INTERVAL')}s")
    interval = cfg_int("MONITOR_INTERVAL", 300)
    was_paused = False
    while True:
        check_manual_triggers()
        check_backup_scheduler()
        check_cleanup_scheduler()
        check_update_scheduler()
        if check_verify_scheduler():
            smart_sleep(interval)
            continue
        manage_cache_state()
        if is_backup_running():
            if not was_paused:
                log("STATUS: Backup detected. Monitoring paused.")
                was_paused = True
            smart_sleep(interval)
            continue
        elif was_paused:
            log("STATUS: Backup finished. Monitoring resumed.")
            was_paused = False
        if is_mover_running():
            smart_sleep(interval)
            continue
        perform_scan(cfg("WATCH_DIR"), False)
        smart_sleep(interval)


def _require_rich():
    # rich is imported lazily by the TUI commands so the daemon never needs it.
    try:
        import rich  # noqa: F401
        return True
    except ImportError:
        print("This view needs the 'rich' package:  pip install rich", file=sys.stderr)
        return False


def _logs_pick_target():
    # Follow the auto-backupper log while a backup runs, else the watchtower log.
    if is_backup_running():
        return BACKUP_LOGFILE, "AUTO-BACKUPPER (Active)"
    status = ""
    try:
        status = open(STATUS_FILE).read().strip()
    except OSError:
        pass
    return WATCHTOWER_LOGFILE, f"WATCHTOWER ({status or 'Idle'})"


def _read_tail(path, count):
    # Last `count` lines + the file's current size (the follow offset).
    try:
        with open(path, errors="replace") as f:
            tail = f.readlines()[-count:]
        return [ln.rstrip("\n") for ln in tail], os.path.getsize(path)
    except OSError:
        return [], 0


def _read_since(path, offset):
    # New content since `offset`; resets to 0 on copytruncate (file shrank).
    try:
        size = os.path.getsize(path)
    except OSError:
        return [], offset
    if size < offset:
        offset = 0
    if size == offset:
        return [], offset
    try:
        with open(path, errors="replace") as f:
            f.seek(offset)
            data = f.read()
            offset = f.tell()
    except OSError:
        return [], offset
    return data.splitlines(), offset


def cmd_logs():
    # Live log monitor that auto-switches between the watchtower and backup logs.
    from collections import deque

    interactive = sys.stdout.isatty()
    if not interactive:
        # Dep-free plain follow for non-TTY (pipes / cron capture).
        current = None
        offset = 0
        try:
            while True:
                target, ctx = _logs_pick_target()
                if target != current:
                    current = target
                    print(f">>> CONTEXT: {ctx}  SOURCE: {target}", flush=True)
                    tail, offset = _read_tail(target, 15)
                    for ln in tail:
                        print(ln, flush=True)
                else:
                    new, offset = _read_since(target, offset)
                    for ln in new:
                        print(ln, flush=True)
                time.sleep(1)
        except KeyboardInterrupt:
            return 0

    if not _require_rich():
        return 1
    from rich.live import Live
    from rich.panel import Panel
    from rich.text import Text
    from rich.console import Group

    spin = ["—", "\\", "|", "/"]
    colors = ["red", "yellow", "green", "cyan", "blue", "magenta"]
    lines = deque(maxlen=300)
    current = None
    offset = 0
    frame = 0
    try:
        with Live(auto_refresh=False, screen=True) as live:
            while True:
                target, ctx = _logs_pick_target()
                if target != current:
                    current = target
                    lines.clear()
                    lines.append(f">>> CONTEXT SWITCH → {ctx}   ({target})")
                    tail, offset = _read_tail(target, 15)
                    lines.extend(tail)
                else:
                    new, offset = _read_since(target, offset)
                    lines.extend(new)
                frame = (frame + 1) % len(spin)
                color = colors[frame % len(colors)]
                header = Panel(
                    Text(f"[{spin[frame]}] WATCHTOWER LIVE LOG — {ctx}   "
                         f"{datetime.datetime.now().strftime('%H:%M:%S')}", style=f"bold {color}"),
                    border_style=color,
                )
                # Show the tail that fits a typical screen; deque keeps history bounded.
                body = Text("\n".join(list(lines)[-40:]))
                live.update(Group(header, Panel(body, title="[q]/Ctrl+C to quit", border_style="grey50")),
                            refresh=True)
                time.sleep(1)
    except KeyboardInterrupt:
        pass
    log("LOGS: Monitor exited.")
    return 0


def _tui_stub(mode):
    print(f"{mode}: the interactive dashboard is not yet ported to Python.")
    print("Use the bash watchtower for it:  ./watchtower.sh " + mode)
    return 0


def main():
    global OS_TYPE, CORRUPTION_REPORT, CFG_TO_LOAD, CLI_CONFIG

    argv = sys.argv[1:]

    # Pre-scan for --config so config is loaded before mode handling.
    prev = ""
    for a in argv:
        if a.startswith("--config="):
            CLI_CONFIG = a.split("=", 1)[1]
        elif prev in ("--config", "-c"):
            CLI_CONFIG = a
        prev = a
    CFG_TO_LOAD = CLI_CONFIG or DEFAULT_CONFIG_FILE
    if os.path.isfile(CFG_TO_LOAD):
        parse_bash_config(CFG_TO_LOAD)
    elif "--reload" not in argv:
        print(f"[WARN] Config file not found at {CFG_TO_LOAD}. Using internal defaults.")

    if os.path.isfile("/etc/unraid-version"):
        OS_TYPE = "unraid"
    if shutil.which("omv-notify"):
        OS_TYPE = "omv"

    CORRUPTION_REPORT = os.path.join(cfg("WATCH_DIR"), cfg("CHECKSUM_DIR"), f"{cfg('HOSTNAME_VAR')}_corruption_report.txt")

    mode, verify_flag = _parse_mode(argv)
    daemon_running, daemon_pid = _detect_daemon()

    # IPC: signal a running daemon and exit, instead of running standalone.
    if mode == "--reload":
        if daemon_running:
            if CLI_CONFIG:
                atomic_write(TRIGGER_CONFIG, CLI_CONFIG)
                print(f"Queued config change to: {CLI_CONFIG}")
            notify_daemon("RELOAD", daemon_pid)
            sys.exit(0)
        print("Error: Daemon is not running. Cannot reload.")
        sys.exit(1)
    if mode in ("--update", "--scan", "--verify", "--cleanup", "--force"):
        trigger = {"--update": TRIGGER_UPDATE, "--scan": TRIGGER_SCAN, "--verify": TRIGGER_VERIFY,
                   "--cleanup": TRIGGER_CLEANUP, "--force": TRIGGER_FORCE}[mode]
        if daemon_running:
            open(trigger, "w").close()
            notify_daemon({"--update": "perform UPDATE", "--scan": "perform SCAN",
                           "--verify": "perform VERIFY", "--cleanup": "perform CLEANUP",
                           "--force": "FORCE cycle"}[mode], daemon_pid)
            sys.exit(0)
        if mode == "--force":
            print("Error: Daemon is not running. Cannot force cycle.")
            sys.exit(1)
        if mode == "--verify":
            CONFIG["ENABLE_VERIFICATION"] = "true"

    # Acquire the single-instance lock for non-read-only / non-signal modes.
    readonly = mode in ("--start-backup", "--stop-backup", "--logs", "--status", "--ab-graph", "--hub")
    if not readonly:
        import fcntl

        # Held for the process lifetime: main()'s frame stays alive while
        # monitor_loop() runs, so the daemon keeps the lock; one-time modes
        # release it at process exit.
        lock_fd = open(WATCHTOWER_LOCK, "w")
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            print("Error: Watchtower is already running (Lockfile held).")
            sys.exit(1)

    if mode == "--monitor":
        with open(PID_FILE, "w") as f:
            f.write(str(os.getpid()))
        signal.signal(signal.SIGUSR1, _daemon_signal_handler)
        import atexit
        atexit.register(lambda: (_safe_remove(PID_FILE), _safe_remove(STATUS_FILE)))
        signal.signal(signal.SIGTERM, lambda s, fr: sys.exit(0))
        signal.signal(signal.SIGINT, lambda s, fr: sys.exit(0))
        set_status("Idle")

    # Initialize the corruption report.
    if CORRUPTION_REPORT and not os.path.isfile(CORRUPTION_REPORT):
        try:
            os.makedirs(os.path.dirname(CORRUPTION_REPORT), exist_ok=True)
            open(CORRUPTION_REPORT, "a").close()
        except OSError:
            pass

    if mode in ("--monitor", "--scan", "--verify", "--cleanup", "--update"):
        warn_hostname_case_drift()

    # Mode dispatch.
    if mode == "--status":
        sys.exit(cmd_status(daemon_running, daemon_pid))
    if mode == "--logs":
        sys.exit(cmd_logs())
    if mode in ("--ab-graph", "--hub"):
        sys.exit(_tui_stub(mode))
    if mode == "--monitor":
        monitor_loop()
    elif mode == "--cleanup":
        log("STARTUP: Forced Cleanup Mode")
        run_cleanup_task()
    elif mode == "--update":
        log("STARTUP: Forced Docker Update Mode (Standalone)")
        run_docker_update_task()
    elif mode == "--start-backup":
        _start_backup()
    elif mode == "--stop-backup":
        _stop_backup()
    else:
        verify = verify_flag or cfg_true("ENABLE_VERIFICATION")
        log(f"STARTUP: One-Time Scan Mode (Verify: {verify})")
        perform_scan(cfg("WATCH_DIR"), verify)


def _start_backup():
    log("MANUAL: Received Start Backup command.")
    if is_backup_running():
        print("Backup is already running.")
        sys.exit(1)
    send_notify("normal", "Manual Trigger", "Starting auto_backupper...")
    script = cfg("MAIN_BACKUP_SCRIPT")
    if os.path.isfile(script):
        subprocess.Popen([script, f"--config={CFG_TO_LOAD}"], stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, start_new_session=True)
        print("Backup started in background.")
    else:
        print(f"ERROR: Backup script not found at {script}")
        sys.exit(1)


def _stop_backup():
    log("MANUAL: Received Stop Backup command.")
    if not is_backup_running():
        print("No backup is currently running (based on lockfile).")
        sys.exit(0)
    # Identify via the PID file auto-backupper wrote; cross-check /proc cmdline
    # before killing. Do NOT delete the lockfile — the flock releases when the
    # kernel reaps the process; removing it opens a concurrent-start race.
    target = ""
    if os.path.isfile(BACKUP_PIDFILE):
        try:
            target = open(BACKUP_PIDFILE).read().strip()
        except OSError:
            target = ""
    if not target.isdigit():
        print(f"Could not read PID from {BACKUP_PIDFILE}.")
        print("The lockfile exists but the PID file is missing/malformed; the backup")
        print("was likely killed previously. Wait for the kernel to release the flock.")
        sys.exit(1)
    tpid = int(target)
    if not _pid_alive(tpid):
        print(f"PID {tpid} is not running; stale PID file.")
        _safe_remove(BACKUP_PIDFILE)
        sys.exit(0)
    cmdline_path = f"/proc/{tpid}/cmdline"
    if os.access(cmdline_path, os.R_OK):
        try:
            cmdline = open(cmdline_path).read().replace("\0", " ")
        except OSError:
            cmdline = ""
        if not re.search(r"auto[_-]backupper", cmdline):
            print(f"PID {tpid} does not look like auto-backupper (cmdline mismatch). Refusing to kill.")
            print(f"If this is wrong, remove {BACKUP_PIDFILE} manually and retry.")
            sys.exit(1)
    print(f"Stopping backup process: PID {tpid}")
    try:
        os.kill(tpid, signal.SIGTERM)
    except OSError:
        pass
    waited = 0
    while _pid_alive(tpid) and waited < 15:
        time.sleep(1)
        waited += 1
    if _pid_alive(tpid):
        print(f"Process {tpid} didn't exit after 15s — sending SIGKILL.")
        try:
            os.kill(tpid, signal.SIGKILL)
        except OSError:
            pass
        send_notify("alert", "Manual Stop", "Backup process SIGKILLed — Docker state may need manual recovery on next run.")
    else:
        send_notify("warning", "Manual Stop", "Backup process terminated cleanly by user.")
    print("Backup stopped.")


if __name__ == "__main__":
    main()
