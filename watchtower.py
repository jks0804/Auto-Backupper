#!/usr/bin/env python3
"""
AUTO-BACKUPPER WATCHTOWER V8.6 (Python Edition)
------------------------------------------------------------------------------
A daemon to monitor, schedule, and protect backup integrity.

USAGE:
    ./watchtower.py --monitor                # Continuous Daemon
    ./watchtower.py --scan                   # One-Time Checksum Scan
    ./watchtower.py --scan --verify          # Verify ALL files
    ./watchtower.py --cleanup                # One-Time Junk Cleanup
    ./watchtower.py --update                 # Update Docker Containers
    ./watchtower.py --start-backup           # Force Start Backup
    ./watchtower.py --stop-backup            # Force Stop Backup
    ./watchtower.py --reload                 # Signal the daemon to reload config
"""

import os
import sys
import time
import signal
import logging
import argparse
import subprocess
import fcntl
import hashlib
import shutil
import re
from datetime import datetime
from concurrent.futures import ThreadPoolExecutor, as_completed

# ==============================================================================
# 1. CONSTANTS & DEFAULTS
# ==============================================================================

# Internal Defaults (Overridden by Config)
DEFAULT_CONFIG_FILE = "/boot/config/auto_backupper.cfg"
WATCHTOWER_LOGFILE = "/var/log/auto_backupper_watchtower.log"
BACKUP_LOCKFILE = "/var/lock/auto_backupper.lock"
WATCHTOWER_LOCK = "/var/lock/ab_watchtower.lock"
PID_FILE = "/var/run/ab_watchtower.pid"
CHECKSUM_DIR = ".checksums"

# Triggers (IPC)
TRIGGER_UPDATE = "/tmp/ab_watchtower_trigger_update"
TRIGGER_SCAN = "/tmp/ab_watchtower_trigger_scan"
TRIGGER_VERIFY = "/tmp/ab_watchtower_trigger_verify"
TRIGGER_CONFIG = "/tmp/ab_watchtower_trigger_config"

# State Files
LAST_RUN_BACKUP = "/tmp/auto_backupper_last_run_backup"
LAST_RUN_CLEANUP = "/tmp/auto_backupper_last_run_cleanup"
LAST_RUN_VERIFY = "/tmp/auto_backupper_last_run_verify"
LAST_RUN_UPDATE = "/tmp/auto_backupper_last_run_update"

# ==============================================================================
# 2. CONFIGURATION PARSER
# ==============================================================================


class Config:
    def __init__(self):
        # Defaults matching Bash script
        self.STARTUP_MODE = "monitor"
        self.HOSTNAME_VAR = os.uname().nodename
        self.WATCH_DIR = "/mnt/user/backup"
        self.MAIN_BACKUP_SCRIPT = (
            "/usr/local/bin/auto-backupper.sh"  # Or .py if you prefer
        )
        self.MONITOR_INTERVAL = 300

        # Logging
        self.LOG_MAX_SIZE = 10 * 1024 * 1024
        self.LOG_BACKUPS = 5

        # Threading
        self.CPU_THREADS = "1"

        # Scheduler Defaults
        self.BACKUP_SCHEDULER_ENABLE = False
        self.BACKUP_SCHEDULER_MODE = "monthly"
        self.BACKUP_SCHEDULER_VALUE = "16"
        self.BACKUP_SCHEDULER_TIME = "02:00"

        self.CLEANUP_SCHEDULER_ENABLE = False
        self.CLEANUP_SCHEDULER_MODE = "daily"
        self.CLEANUP_SCHEDULER_VALUE = "Sun"
        self.CLEANUP_SCHEDULER_TIME = "04:00"

        self.VERIFY_SCHEDULER_ENABLE = False
        self.VERIFY_SCHEDULER_MODE = "monthly"
        self.VERIFY_SCHEDULER_VALUE = "28"
        self.VERIFY_SCHEDULER_TIME = "03:00"

        self.UPDATE_SCHEDULER_ENABLE = False
        self.UPDATE_SCHEDULER_MODE = "weekly"
        self.UPDATE_SCHEDULER_VALUE = "Sat"
        self.UPDATE_SCHEDULER_TIME = "05:00"
        self.DOCKER_UPDATE_EXCLUDE = "mariadb"

        # Cache Monitor
        self.ENABLE_CACHE_MONITOR = False
        self.CACHE_DIR = "/mnt/cache"
        self.MOVER_TYPE = "unraid"
        self.ARRAY_BASE_PATH = "/mnt/user"
        self.CACHE_THRESHOLD = 73
        self.CACHE_CRITICAL = 90
        self.FORCE_MOVER_ON_CRITICAL = False
        self.RUN_MOVER_DURING_PARITY = False

    def load_from_file(self, filepath):
        if not os.path.exists(filepath):
            return

        def clean_val(v):
            return v.strip().strip('"').strip("'")

        with open(filepath, "r") as f:
            lines = f.readlines()

        for line in lines:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" not in line:
                continue

            # Extract Key=Value
            key, val = line.split("=", 1)
            key = key.strip()
            val = val.split("#")[0].strip()  # remove inline comments
            val = clean_val(val)

            # Convert Types
            if val.lower() == "true":
                val = True
            elif val.lower() == "false":
                val = False
            elif key in [
                "MONITOR_INTERVAL",
                "CACHE_THRESHOLD",
                "CACHE_CRITICAL",
                "LOG_MAX_SIZE",
                "LOG_BACKUPS",
            ]:
                try:
                    val = int(val)
                except:
                    pass

            # Map to self
            if hasattr(self, key):
                setattr(self, key, val)


cfg = Config()

# ==============================================================================
# 3. UTILS
# ==============================================================================


def setup_logging():
    # Manual Rotation Logic to match Bash
    if os.path.exists(WATCHTOWER_LOGFILE):
        try:
            if os.path.getsize(WATCHTOWER_LOGFILE) >= cfg.LOG_MAX_SIZE:
                for i in range(cfg.LOG_BACKUPS - 1, 0, -1):
                    src = f"{WATCHTOWER_LOGFILE}.{i}"
                    dst = f"{WATCHTOWER_LOGFILE}.{i+1}"
                    if os.path.exists(src):
                        shutil.move(src, dst)
                shutil.move(WATCHTOWER_LOGFILE, f"{WATCHTOWER_LOGFILE}.1")
                with open(WATCHTOWER_LOGFILE, "w") as f:
                    f.write("")
        except Exception:
            pass

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [WATCHTOWER] %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
        handlers=[
            logging.FileHandler(WATCHTOWER_LOGFILE),
            logging.StreamHandler(sys.stdout),
        ],
    )
    logging.Formatter.converter = time.gmtime


def log(msg, level="info"):
    if level == "info":
        logging.info(msg)
    elif level == "warn":
        logging.warning(msg)
    elif level == "error":
        logging.error(msg)


def run_cmd(cmd, shell=False):
    try:
        subprocess.run(
            cmd,
            shell=shell,
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        return True
    except subprocess.CalledProcessError:
        return False


def get_thread_count():
    if str(cfg.CPU_THREADS).lower() == "all":
        return os.cpu_count() or 1
    if str(cfg.CPU_THREADS).isdigit() and int(cfg.CPU_THREADS) > 0:
        return int(cfg.CPU_THREADS)
    return 1


# Detect OS
OS_TYPE = "linux"
if os.path.exists("/etc/unraid-version"):
    OS_TYPE = "unraid"
elif shutil.which("omv-firstaid"):
    OS_TYPE = "omv"


def notify(level, title, message):
    log(f"NOTIFY [{level}]: {title} - {message}")

    # Unraid
    if OS_TYPE == "unraid" and os.path.exists(
        "/usr/local/emhttp/webGui/scripts/notify"
    ):
        subprocess.run(
            [
                "/usr/local/emhttp/webGui/scripts/notify",
                "-e",
                title,
                "-s",
                "WATCHTOWER",
                "-d",
                message,
                "-i",
                level,
            ]
        )
        return
    # Generic
    if shutil.which("notify-send"):
        subprocess.run(["notify-send", "-u", level, title, message])


def is_backup_running():
    if os.path.exists(BACKUP_LOCKFILE):
        try:
            # Check if lock is actually held
            with open(BACKUP_LOCKFILE, "r") as f:
                fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
                fcntl.flock(f, fcntl.LOCK_UN)
            return False  # We got the lock, so it's not running
        except IOError:
            return True  # Failed to get lock, so it IS running
    return False


# ==============================================================================
# 4. SCHEDULER LOGIC
# ==============================================================================


def should_run_schedule(mode, value, time_target, last_run_file):
    today_str = datetime.now().strftime("%Y%m%d")

    # Check Last Run
    if os.path.exists(last_run_file):
        with open(last_run_file, "r") as f:
            if f.read().strip() == today_str:
                return False

    # Check Time
    now = datetime.now()
    target_h, target_m = map(int, time_target.split(":"))
    if now.hour < target_h or (now.hour == target_h and now.minute < target_m):
        return False

    trigger = False

    if mode == "daily":
        trigger = True
    elif mode == "weekly":
        # %a gives 'Sun', 'Mon'
        if now.strftime("%a").lower() == str(value).lower():
            trigger = True
    elif mode == "monthly":
        if str(now.day) == str(value):
            trigger = True
    elif mode == "quarterly":
        if now.month in [1, 4, 7, 10] and str(now.day) == str(value):
            trigger = True
    elif mode == "annually":
        if now.month == 1 and str(now.day) == str(value):
            trigger = True

    return trigger


# ==============================================================================
# 5. CORE TASKS (Scan, Update, Cache)
# ==============================================================================


def task_verify_file(filepath, base_root, force_verify=False):
    rel_path = os.path.relpath(filepath, base_root)
    chk_path = os.path.join(base_root, CHECKSUM_DIR, rel_path + ".sha256")

    # 1. Existing Checksum -> Verify
    if os.path.exists(chk_path):
        if force_verify:
            try:
                with open(chk_path, "r") as f:
                    expected = f.read().strip().split()[0]

                sha = hashlib.sha256()
                with open(filepath, "rb") as f:
                    while True:
                        data = f.read(1024 * 1024)
                        if not data:
                            break
                        sha.update(data)

                if sha.hexdigest() != expected:
                    log(f"CORRUPTION: {filepath}", "error")
                    notify("alert", "Corruption Detected", filepath)

                    report_path = os.path.join(
                        base_root,
                        CHECKSUM_DIR,
                        f"{cfg.HOSTNAME_VAR}_corruption_report.txt",
                    )
                    with open(report_path, "a") as rf:
                        rf.write(f"[{datetime.now()}] CORRUPTION: {filepath}\n")
            except Exception as e:
                log(f"Error reading {filepath}: {e}", "error")
        return

    # 2. No Checksum -> Create
    # Basic stability check (file size didn't change in 1 sec)
    try:
        s1 = os.path.getsize(filepath)
        time.sleep(0.5)
        s2 = os.path.getsize(filepath)
        if s1 != s2:
            return  # File is being written

        log(f"NEW CHECKSUM: {rel_path}")
        os.makedirs(os.path.dirname(chk_path), exist_ok=True)

        sha = hashlib.sha256()
        with open(filepath, "rb") as f:
            while True:
                data = f.read(1024 * 1024)
                if not data:
                    break
                sha.update(data)

        with open(chk_path, "w") as f:
            f.write(sha.hexdigest())

    except FileNotFoundError:
        pass  # File vanished


def perform_scan(base_dir, force_verify=False):
    if not os.path.isdir(base_dir):
        return

    files_to_process = []
    for root, dirs, files in os.walk(base_dir):
        # Prune
        if CHECKSUM_DIR in dirs:
            dirs.remove(CHECKSUM_DIR)
        if ".abpartial" in dirs:
            dirs.remove(".abpartial")

        for f in files:
            files_to_process.append(os.path.join(root, f))

    workers = get_thread_count()
    if workers > 1:
        log(f"SCAN: Processing {len(files_to_process)} files with {workers} threads...")
        with ThreadPoolExecutor(max_workers=workers) as executor:
            futures = [
                executor.submit(task_verify_file, f, base_dir, force_verify)
                for f in files_to_process
            ]
            for _ in as_completed(futures):
                pass
    else:
        # Single threaded fallback
        for f in files_to_process:
            task_verify_file(f, base_dir, force_verify)


def run_docker_update_task():
    log("UPDATER: Starting Container Check...")
    if not shutil.which("docker"):
        return

    # Get running containers
    res = subprocess.run(
        ["docker", "ps", "--format", "{{.Names}}"], capture_output=True, text=True
    )
    containers = res.stdout.strip().splitlines()

    exclude_list = cfg.DOCKER_UPDATE_EXCLUDE.split()

    for container in containers:
        if container in exclude_list:
            continue

        try:
            # Inspect Image Name and Current ID
            img_name = subprocess.check_output(
                ["docker", "inspect", "--format={{.Config.Image}}", container],
                text=True,
            ).strip()
            curr_id = subprocess.check_output(
                ["docker", "inspect", "--format={{.Image}}", container], text=True
            ).strip()

            # Pull New
            subprocess.run(
                ["docker", "pull", img_name],
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )

            # Check New ID
            new_id = subprocess.check_output(
                ["docker", "inspect", "--format={{.Id}}", img_name], text=True
            ).strip()

            if curr_id != new_id:
                log(f"UPDATER: Update found for {container}. Applying...")
                notify("normal", "Auto-Updater", f"Updating {container}...")

                if OS_TYPE == "unraid":
                    subprocess.run(
                        [
                            "/usr/local/emhttp/plugins/dynamix.docker.manager/scripts/update_container",
                            container,
                        ]
                    )
                else:
                    # Generic restart warning (Script doesn't assume docker-compose location effectively in Python yet)
                    notify(
                        "warning",
                        "Update Ready",
                        f"New image for {container}. Restart manually.",
                    )

        except Exception as e:
            log(f"UPDATER WARN: {container} check failed: {e}", "warn")

    log("UPDATER: Job Finished.")


def manage_cache_state():
    if not cfg.ENABLE_CACHE_MONITOR:
        return
    if is_backup_running():
        return

    # Cache Usage
    try:
        res = subprocess.check_output(
            ["df", "-P", cfg.CACHE_DIR], text=True
        ).splitlines()
        # Parse percentage from 2nd line, 5th column
        usage = int(res[1].split()[4].replace("%", ""))
    except:
        return

    should_move = False

    if usage >= cfg.CACHE_CRITICAL:
        notify("alert", "Cache Critical", f"Cache is at {usage}%")
        if not cfg.FORCE_MOVER_ON_CRITICAL and is_backup_running():
            return
        should_move = True
    elif usage >= cfg.CACHE_THRESHOLD:
        log(f"Cache at {usage}% (Threshold {cfg.CACHE_THRESHOLD}%).")
        should_move = True

    if should_move:
        log(f"ACTION: Triggering Mover ({cfg.MOVER_TYPE})...")
        if cfg.MOVER_TYPE == "unraid" and os.path.exists("/usr/local/sbin/mover"):
            subprocess.Popen(["/usr/local/sbin/mover", "start"])
        elif cfg.MOVER_TYPE == "internal":
            # Basic internal mover (Move files from cache to array)
            # NOTE: Robust python implementation is complex; stick to unraid binary if available
            pass


def run_cleanup_task():
    log("CLEANUP: Removing junk files...")
    base = cfg.ARRAY_BASE_PATH

    # 1. Delete .DS_Store, .tmp, etc.
    junk_names = [".DS_Store", "._.DS_Store"]
    junk_dirs = [".AppleDB", ".AppleDesktop", ".TemporaryItems", ".tmp"]

    for root, dirs, files in os.walk(base):
        # Limit depth roughly (manual walk control)
        if root.count(os.sep) - base.count(os.sep) > 6:
            continue

        for d in dirs:
            if d in junk_dirs:
                shutil.rmtree(os.path.join(root, d), ignore_errors=True)

        for f in files:
            if f in junk_names:
                os.remove(os.path.join(root, f))

    # 2. NFO cleanup in media folders
    for media_type in ["media/TV", "media/Movies"]:
        target = os.path.join(base, media_type)
        if os.path.isdir(target):
            for root, _, files in os.walk(target):
                for f in files:
                    if f.endswith(".nfo") or f.endswith(".txt"):
                        os.remove(os.path.join(root, f))

    log("CLEANUP: Job Finished.")


# ==============================================================================
# 6. SIGNAL HANDLERS & DAEMON LOOP
# ==============================================================================


def reload_handler(signum, frame):
    log("EVENT: Signal received. Reloading config...")

    # Check for config override trigger
    cfg_path = args.config
    if os.path.exists(TRIGGER_CONFIG):
        with open(TRIGGER_CONFIG, "r") as f:
            new_path = f.read().strip()
            if os.path.exists(new_path):
                cfg_path = new_path
        os.remove(TRIGGER_CONFIG)

    cfg.load_from_file(cfg_path)

    # Check Manual Triggers
    if os.path.exists(TRIGGER_UPDATE):
        os.remove(TRIGGER_UPDATE)
        run_docker_update_task()
    if os.path.exists(TRIGGER_SCAN):
        os.remove(TRIGGER_SCAN)
        perform_scan(cfg.WATCH_DIR, force_verify=False)
    if os.path.exists(TRIGGER_VERIFY):
        os.remove(TRIGGER_VERIFY)
        perform_scan(cfg.WATCH_DIR, force_verify=True)

    log("EVENT: Reload complete.")


def main_loop():
    log(f"STARTUP: Monitor Mode Active. Interval: {cfg.MONITOR_INTERVAL}s")

    while True:
        try:
            # 1. Schedulers
            if cfg.BACKUP_SCHEDULER_ENABLE and not is_backup_running():
                if should_run_schedule(
                    cfg.BACKUP_SCHEDULER_MODE,
                    cfg.BACKUP_SCHEDULER_VALUE,
                    cfg.BACKUP_SCHEDULER_TIME,
                    LAST_RUN_BACKUP,
                ):
                    log("SCHEDULER: Firing Backup Job...")
                    notify("normal", "Backup Scheduler", "Starting auto_backupper...")
                    subprocess.Popen(
                        [cfg.MAIN_BACKUP_SCRIPT, "--config", args.config],
                        start_new_session=True,
                    )
                    with open(LAST_RUN_BACKUP, "w") as f:
                        f.write(datetime.now().strftime("%Y%m%d"))

            if cfg.CLEANUP_SCHEDULER_ENABLE and not is_backup_running():
                if should_run_schedule(
                    cfg.CLEANUP_SCHEDULER_MODE,
                    cfg.CLEANUP_SCHEDULER_VALUE,
                    cfg.CLEANUP_SCHEDULER_TIME,
                    LAST_RUN_CLEANUP,
                ):
                    run_cleanup_task()
                    with open(LAST_RUN_CLEANUP, "w") as f:
                        f.write(datetime.now().strftime("%Y%m%d"))

            if cfg.UPDATE_SCHEDULER_ENABLE and not is_backup_running():
                if should_run_schedule(
                    cfg.UPDATE_SCHEDULER_MODE,
                    cfg.UPDATE_SCHEDULER_VALUE,
                    cfg.UPDATE_SCHEDULER_TIME,
                    LAST_RUN_UPDATE,
                ):
                    run_docker_update_task()
                    with open(LAST_RUN_UPDATE, "w") as f:
                        f.write(datetime.now().strftime("%Y%m%d"))

            if cfg.VERIFY_SCHEDULER_ENABLE and not is_backup_running():
                if should_run_schedule(
                    cfg.VERIFY_SCHEDULER_MODE,
                    cfg.VERIFY_SCHEDULER_VALUE,
                    cfg.VERIFY_SCHEDULER_TIME,
                    LAST_RUN_VERIFY,
                ):
                    notify(
                        "warning", "Verification Started", "Scheduled deep scan active."
                    )
                    perform_scan(cfg.WATCH_DIR, force_verify=True)
                    notify("normal", "Verification Finished", "Deep scan complete.")
                    with open(LAST_RUN_VERIFY, "w") as f:
                        f.write(datetime.now().strftime("%Y%m%d"))
                    # Skip rest of loop and sleep to allow cooling off
                    time.sleep(cfg.MONITOR_INTERVAL)
                    continue

            # 2. Cache
            manage_cache_state()

            # 3. Incremental Scan
            if not is_backup_running():
                perform_scan(cfg.WATCH_DIR, force_verify=False)

            time.sleep(cfg.MONITOR_INTERVAL)

        except Exception as e:
            log(f"CRITICAL LOOP ERROR: {e}", "error")
            time.sleep(60)


# ==============================================================================
# 7. MAIN ENTRY
# ==============================================================================

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--monitor", action="store_true")
    parser.add_argument("--scan", action="store_true")
    parser.add_argument("--cleanup", action="store_true")
    parser.add_argument("--update", action="store_true")
    parser.add_argument("--verify", action="store_true")
    parser.add_argument("--start-backup", action="store_true")
    parser.add_argument("--stop-backup", action="store_true")
    parser.add_argument("--reload", action="store_true")
    parser.add_argument("--config", default=DEFAULT_CONFIG_FILE)
    args = parser.parse_args()

    # Load Config
    cfg.load_from_file(args.config)
    setup_logging()

    # Check for Existing Daemon
    daemon_pid = None
    if os.path.exists(PID_FILE):
        try:
            with open(PID_FILE, "r") as f:
                pid = int(f.read().strip())
                os.kill(pid, 0)  # Check if running
                daemon_pid = pid
        except (OSError, ValueError):
            pass  # Stale PID file

    # 1. Handle Signals to Daemon
    if args.reload:
        if daemon_pid:
            # Write config path trigger in case it changed
            with open(TRIGGER_CONFIG, "w") as f:
                f.write(args.config)
            os.kill(daemon_pid, signal.SIGUSR1)
            print("Signal sent to reload config.")
        else:
            print("Daemon not running.")
        sys.exit(0)

    if args.update and daemon_pid:
        with open(TRIGGER_UPDATE, "w") as f:
            f.write("1")
        os.kill(daemon_pid, signal.SIGUSR1)
        print("Signal sent to trigger Update.")
        sys.exit(0)

    if args.verify and daemon_pid:
        with open(TRIGGER_VERIFY, "w") as f:
            f.write("1")
        os.kill(daemon_pid, signal.SIGUSR1)
        print("Signal sent to trigger Verify.")
        sys.exit(0)

    # 2. Handle Manual Backup Commands
    if args.start_backup:
        if is_backup_running():
            print("Backup already running.")
        else:
            notify("normal", "Manual Trigger", "Starting auto_backupper...")
            subprocess.Popen(
                [cfg.MAIN_BACKUP_SCRIPT, "--config", args.config],
                start_new_session=True,
            )
            print("Backup started in background.")
        sys.exit(0)

    if args.stop_backup:
        if not is_backup_running():
            print("No lockfile found.")
        else:
            # Python equivalent of pgrep -f auto_backupper
            try:
                # We assume pgrep is available, cleaner than iterating /proc in python
                pids = (
                    subprocess.check_output(["pgrep", "-f", "auto_backupper"])
                    .decode()
                    .split()
                )
                for pid in pids:
                    os.kill(int(pid), signal.SIGTERM)
                if os.path.exists(BACKUP_LOCKFILE):
                    os.remove(BACKUP_LOCKFILE)
                print(f"Stopped processes: {pids}")
            except Exception as e:
                print(f"Error stopping backup: {e}")
        sys.exit(0)

    # 3. Lock for Watchtower (Single Instance)
    try:
        lock_fd = open(WATCHTOWER_LOCK, "w")
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except IOError:
        print("Watchtower already running.")
        sys.exit(1)

    # 4. Run Modes
    if args.monitor:
        with open(PID_FILE, "w") as f:
            f.write(str(os.getpid()))
        signal.signal(signal.SIGUSR1, reload_handler)
        signal.signal(signal.SIGTERM, lambda s, f: sys.exit(0))
        try:
            main_loop()
        finally:
            if os.path.exists(PID_FILE):
                os.remove(PID_FILE)

    elif args.scan:
        log(f"STARTUP: One-Time Scan (Verify: {args.verify})")
        perform_scan(cfg.WATCH_DIR, force_verify=args.verify)

    elif args.cleanup:
        log("STARTUP: Forced Cleanup")
        run_cleanup_task()

    elif args.update:
        # Standalone update (if daemon wasn't running)
        run_docker_update_task()
