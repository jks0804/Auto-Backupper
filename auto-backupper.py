#!/usr/bin/env python3
# ==============================================================================
# AUTO-BACKUPPER [Enterprise Edition] — Python port
# ==============================================================================
# A unified, fault-tolerant backup solution for Unraid, OMV, and Linux.
#
# A faithful port of auto-backupper.sh, kept as a SEPARATE script from the bash
# implementation (the primary one, on the repo's `bash` branch). Reads the same
# bash-syntax auto_backupper.cfg. Native Python is used where it is clearer
# (threaded verification, pathlib), but behavior, layout, and the dated-checksum
# contract match the bash reference.
#
# USAGE:
#     sudo python3 auto-backupper.py [OPTIONS]
#
# OPTIONS:
#     -c, --config FILE   Path to config file (default /boot/config/auto_backupper.cfg)
#     -m, --mode MODE     produce | pull | both
#     --only PHASES       Restrict produce to a comma list: db (alias services) | systems | shares
#     --dry-run           Simulate actions (no writes)
#     --no-docker         Disable Docker management
#     --debug             Verbose logging (tar -v, rsync --progress)
#     -h, --help          Show this help
#
# DEPENDENCIES:
#     Python 3.6+; binaries: tar, rsync, find, sha256sum; pigz, docker (optional).
# ==============================================================================

import os
import re
import sys
import json
import time
import glob
import shlex
import fcntl
import shutil
import socket
import signal
import tempfile
import datetime
import subprocess
from concurrent.futures import ThreadPoolExecutor
from concurrent.futures import TimeoutError as FuturesTimeout

# ==============================================================================
# 1. BOOTSTRAP: PATHS & IDENTITY
# ==============================================================================
DEFAULT_CONFIG_FILE = "/boot/config/auto_backupper.cfg"
LOGFILE = "/var/log/auto_backupper.log"
LOCKFILE = "/var/lock/auto_backupper.lock"
# PID file read by watchtower --stop-backup for reliable process identification.
BACKUP_PIDFILE = "/var/run/auto_backupper.pid"

ENCLAVE_DIR = "/tmp/enclave"
STATE_FILE = f"{ENCLAVE_DIR}/ab_state"
RUNNING_CONTAINERS_LIST = f"{ENCLAVE_DIR}/containers.list"
IPC_BASE = f"{ENCLAVE_DIR}/queue"
IPC_ERRORS = f"{IPC_BASE}/errors"
# List of absolute paths created by THIS run; verification reads it so we hash
# only what we produced. Lives under IPC_BASE so cleanup wipes it on exit.
SESSION_MANIFEST = f"{IPC_BASE}/session_manifest"

CHECKSUM_DIR = ".checksums"
TAR_EXT = ".tar.gz"
# Short hostname upper-cased for a canonical artifact path; without it a host
# whose returned casing drifts produces parallel systems/<HOST>/ trees that
# retention can't reconcile. Config (HOSTNAME_VAR=) overrides.
_DEFAULT_HOSTNAME = socket.gethostname().split(".")[0].upper()
CDATE = datetime.datetime.now().strftime("%Y%m%d")

LOG_MAX_SIZE = 10 * 1024 * 1024  # 10 MB
LOG_BACKUPS = 5

# verify_file() return codes (mirror the bash exit codes).
VERIFY_OK = 0
VERIFY_NO_FILE = 2
VERIFY_MISMATCH = 4
VERIFY_TIMEOUT = 5

# Runtime globals.
OS_TYPE = "linux"
DOCKER_CMD = "docker" if shutil.which("docker") else None
CURRENT_ARCHIVE_FILE = None
LOCK_FD = None
LOCK_HELD = False
ONLY_PHASES = []

# ==============================================================================
# 2. DEFAULT CONFIGURATION (matches auto-backupper.sh; cfg overrides)
# ==============================================================================
CONFIG = {
    "HOSTNAME_VAR": _DEFAULT_HOSTNAME,
    "CPU_THREADS": "1",          # "all" | "1" | "4" ...
    "MODE": "produce",           # produce | pull | both
    "DRY_RUN": "true",           # "false" for real execution
    "LOG_VERBOSITY": "info",     # error | phase | info | debug

    # --- Paths ---
    "BACKUP_BASE": "/mnt/user/backup",
    "SHARES_BASE_FOLDER": "/mnt/user",
    "SYSTEM_APPDATA_PATH": "/mnt/cache/appdata",
    "SYSTEM_BOOT_PATH": "/boot",
    "OMV_DOCKER_BACKUP_PATH": "",

    # --- Unraid specifics ---
    "UNRAID_DOCKER_CFG": "/boot/config/docker.cfg",
    "DOCKER_IMG_PATH": "/mnt/cache/system/docker/docker.img",
    "DOCKER_IMG_SIZE": "80",
    "BACKUP_DOCKER_IMG": "true",

    # --- Docker strategy ---
    "DOCKER_MODE": "auto",       # auto | unraid_service | container | disabled
    "DOCKER_STOP_TIMEOUT": "60",

    # --- Retention & integrity ---
    "ROTATE_DAYS": "90",
    "VERIFY_LOCAL_BACKUPS": "true",
    "VERIFY_ALL_LOCAL_BACKUPS": "false",
    "VERIFY_PULLED_BACKUPS": "true",
    "VERIFY_ALL_PULLED_BACKUPS": "false",
    "BACKUP_SYSTEM": "true",
    "BACKUP_SHARES": "true",

    # --- Preflight space check ---
    "PREFLIGHT_SPACE_CHECK": "true",
    "PREFLIGHT_COMPRESSION_RATIO": "0.4",
    "PREFLIGHT_MARGIN_BYTES": str(1073741824),

    # --- Databases (shared SQL toggle + type, like bash) ---
    "BACKUP_SQL": "false",
    "SQL_TYPE": "mysql",         # mysql | postgres
    "SQL_CONTAINER_NAME": "mariadb",
    "SQL_HOST": "172.18.0.4",
    "SQL_USER": "root",
    "SQL_PASS": os.environ.get("SQL_PASS", "YourMySQLPassword"),
    "SQL_DATABASES": [],         # empty = ALL

    "BACKUP_MONGO": "false",
    "MONGO_CONTAINER_NAME": "mongodb",
    "MONGO_USER": "root",
    "MONGO_PASS": os.environ.get("MONGO_PASS", "YourMongoPassword"),
    "MONGO_AUTH_DB": "admin",
    "MONGO_DATABASES": [],

    "BACKUP_REDIS": "false",
    "REDIS_CONTAINER_NAME": "redis",
    "REDIS_PASS": os.environ.get("REDIS_PASS", ""),

    # --- Notifications ---
    "NOTIFY_WEBHOOK_URL": "",
    "NOTIFY_WEBHOOK_FORMAT": "",  # discord | slack | ntfy | generic (auto if empty)

    # --- Shares ---
    "SHARES_TO_BACKUP": [
        "codebase", "assets", "domains", "iscsi", "isos", "liz",
        "stroh", "sites", "mebula", "media/Games/saves/", "FamilyBackups",
    ],
    "SHARES_EXCLUDE": {
        "isos": ["--exclude", "asset-mirror", "--exclude", "*-squash"],
        "iscsi": ["--exclude", ".fuse_hidden*"],
    },

    # --- Remotes ---
    "REMOTE_PULL_SOURCES": [
        "/mnt/remotes/DBACKUPS",
        "/mnt/remotes/KBACKUPS",
    ],
}


def is_dry():
    return CONFIG["DRY_RUN"] == "true"


def hostname_var():
    return CONFIG["HOSTNAME_VAR"]


# ==============================================================================
# 3. LOGGING (copytruncate rotation + verbosity tiers)
# ==============================================================================


def _log_verbosity_threshold():
    return {"error": 2, "phase": 3, "info": 4, "debug": 99}.get(
        CONFIG.get("LOG_VERBOSITY", "info"), 4
    )


def _log_level_for(msg):
    if re.match(r"^(FATAL|CRITICAL|ERROR:|ERROR |WARN:|WARN )", msg) or re.match(r"^\s+(WARN:|ERROR:)", msg):
        return 2
    if re.match(r"^(===|Phase:|Archiving:|ACTION:|RECOVERY:|SUCCESS:|NOTIFY)", msg):
        return 3
    return 4


def rotate_logs():
    # Copytruncate: copy then truncate (not move) so the held-open log FD keeps
    # writing to the same inode after rotation.
    if not os.path.isfile(LOGFILE):
        return
    try:
        if os.path.getsize(LOGFILE) < LOG_MAX_SIZE:
            return
    except OSError:
        return
    last = f"{LOGFILE}.{LOG_BACKUPS}"
    if os.path.isfile(last):
        try:
            os.remove(last)
        except OSError:
            pass
    for i in range(LOG_BACKUPS - 1, 0, -1):
        src, dst = f"{LOGFILE}.{i}", f"{LOGFILE}.{i + 1}"
        if os.path.isfile(src):
            try:
                os.replace(src, dst)
            except OSError:
                pass
    try:
        shutil.copy2(LOGFILE, f"{LOGFILE}.1")
        open(LOGFILE, "w").close()
    except OSError:
        pass


def log(msg):
    if _log_level_for(msg) <= _log_verbosity_threshold():
        line = f"{datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')} {msg}"
        print(line, flush=True)
        try:
            with open(LOGFILE, "a") as f:
                f.write(line + "\n")
        except OSError:
            pass
    rotate_logs()


def setup_logging():
    try:
        os.makedirs(os.path.dirname(LOGFILE), exist_ok=True)
        rotate_logs()
        open(LOGFILE, "a").close()
    except OSError:
        pass


# ==============================================================================
# 4. STATE ENGINE
# ==============================================================================


def init_state():
    os.makedirs(ENCLAVE_DIR, exist_ok=True)
    # Crash recovery: a SIGKILLed prior run may have left Docker stopped. The
    # state file and container list survive in /tmp — restart Docker BEFORE
    # truncating the state.
    if os.path.isfile(STATE_FILE):
        try:
            with open(STATE_FILE) as f:
                stale = "DOCKER_STOPPED=true" in f.read().splitlines()
        except OSError:
            stale = False
        if stale:
            log("RECOVERY: Previous run left Docker stopped. Attempting restart before proceeding...")
            try:
                sys_docker_start()
                log("RECOVERY: Docker restart succeeded.")
            except Exception:
                log("WARN: Recovery restart failed. Manual intervention may be required.")
    open(STATE_FILE, "w").close()
    shutil.rmtree(IPC_BASE, ignore_errors=True)
    os.makedirs(IPC_ERRORS, exist_ok=True)
    open(SESSION_MANIFEST, "w").close()


def set_state(key, val):
    # Atomic update: build the full body in a temp file, then one rename. A torn
    # write here would drop the key we are setting and break crash recovery.
    states = get_all_states()
    states[key] = str(val)
    tmp = f"{STATE_FILE}.tmp.{os.getpid()}"
    with open(tmp, "w") as f:
        for k, v in states.items():
            f.write(f"{k}={v}\n")
    os.replace(tmp, STATE_FILE)


def get_state(key):
    return get_all_states().get(key, "")


def get_all_states():
    states = {}
    if os.path.isfile(STATE_FILE):
        try:
            with open(STATE_FILE) as f:
                for line in f:
                    if "=" in line:
                        k, v = line.strip().split("=", 1)
                        states[k] = v
        except OSError:
            pass
    return states


# ==============================================================================
# 5. CONFIG LOADING (bash-syntax cfg parser)
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

    # Scalars: KEY="val" | KEY='val' | KEY=val (trailing # comment tolerated).
    scalar = re.compile(
        r'^[ \t]*([A-Za-z_][A-Za-z0-9_]*)='
        r'''("(?:[^"\\]|\\.)*"|'[^']*'|[^\s#(]*)[ \t]*(?:#.*)?$''',
        re.M,
    )
    for m in scalar.finditer(content):
        key, raw = m.group(1), m.group(2)
        if key in CONFIG and isinstance(CONFIG[key], str):
            CONFIG[key] = _unquote(raw)

    # Arrays: KEY=( ... ) possibly spanning lines, inline # comments allowed.
    for m in re.finditer(r"^[ \t]*([A-Za-z_][A-Za-z0-9_]*)=\((.*?)\)", content, re.M | re.S):
        key, body = m.group(1), m.group(2)
        if key in CONFIG and isinstance(CONFIG[key], list):
            try:
                CONFIG[key] = shlex.split(body, comments=True)
            except ValueError:
                pass

    # Associative SHARES_EXCLUDE["key"]='--exclude "x" ...'
    assoc = re.compile(
        r'''^[ \t]*SHARES_EXCLUDE\[(?:"([^"]+)"|'([^']+)'|([^\]]+))\]='''
        r'''("(?:[^"\\]|\\.)*"|'[^']*'|\S+)''',
        re.M,
    )
    for m in assoc.finditer(content):
        k = m.group(1) or m.group(2) or m.group(3)
        try:
            CONFIG["SHARES_EXCLUDE"][k] = shlex.split(_unquote(m.group(4)))
        except ValueError:
            CONFIG["SHARES_EXCLUDE"][k] = []


# ==============================================================================
# 6. NOTIFICATIONS
# ==============================================================================


def _json_escape(s):
    return (
        s.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\n", "\\n")
        .replace("\t", "\\t")
    )


def strategy_notify_webhook(level, title, message):
    # Fires in addition to the OS-native notifier. No-op unless a URL is set.
    url = CONFIG.get("NOTIFY_WEBHOOK_URL", "")
    if not url or not shutil.which("curl"):
        return
    fmt = CONFIG.get("NOTIFY_WEBHOOK_FORMAT", "")
    if not fmt:
        if "discord.com" in url or "discordapp.com" in url:
            fmt = "discord"
        elif "slack.com" in url or "slack-edge.com" in url:
            fmt = "slack"
        else:
            fmt = "generic"
    prefix = {"alert": "[ALERT]", "warning": "[WARN]", "normal": "[OK]"}.get(level, "[INFO]")
    host = hostname_var()
    et, em = _json_escape(title), _json_escape(message)

    if fmt == "ntfy":
        ntfy_pri = {"alert": "high", "warning": "default", "normal": "low"}.get(level, "default")
        subprocess.run(
            ["curl", "-fsS", "--max-time", "10",
             "-H", f"Title: {title}", "-H", f"Priority: {ntfy_pri}",
             "-H", f"Tags: backup,{level},{host}", "-d", message, url],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        return
    if fmt == "discord":
        body = f'{{"username":"Auto-Backupper@{host}","content":"{prefix} **{et}**\\n{em}"}}'
    elif fmt == "slack":
        body = f'{{"text":"*{prefix} {et}*\\n{em}\\n_host: {host}_"}}'
    elif fmt == "generic":
        ts = datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
        body = f'{{"host":"{host}","level":"{level}","title":"{et}","message":"{em}","timestamp":"{ts}"}}'
    else:
        return
    subprocess.run(
        ["curl", "-fsS", "--max-time", "10", "-H", "Content-Type: application/json", "-d", body, url],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )


def sys_notify(level, title, message):
    # OS-native notifier, then the webhook (additive).
    try:
        if OS_TYPE == "unraid" and os.access("/usr/local/emhttp/webGui/scripts/notify", os.X_OK):
            subprocess.run(
                ["/usr/local/emhttp/webGui/scripts/notify", "-e", title,
                 "-s", "Auto-Backupper", "-d", message, "-i", level],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
        elif OS_TYPE == "omv" and shutil.which("omv-notify"):
            omv_lvl = "error" if level == "alert" else "warning" if level == "warning" else "info"
            subprocess.run(["omv-notify", "-k", omv_lvl, "-t", title, "-m", message],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        elif shutil.which("notify-send"):
            subprocess.run(["notify-send", "-u", level, title, message],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception as e:
        log(f"WARN: OS notification failed: {e}")
    strategy_notify_webhook(level, title, message)


def send_notify(level, title, message):
    if level in ("alert", "normal"):
        log(f"NOTIFY [{level}]: {title} - {message}")
    if is_dry():
        return
    sys_notify(level, title, message)


# ==============================================================================
# 7. OS DETECTION & DOCKER STRATEGIES
# ==============================================================================


def determine_os_and_docker():
    global OS_TYPE
    if os.path.isfile("/etc/unraid-version"):
        OS_TYPE = "unraid"
        cfg = CONFIG["UNRAID_DOCKER_CFG"]
        if os.path.isfile(cfg):
            # docker.cfg uses DOCKER_IMAGE_FILE / DOCKER_IMAGE_SIZE.
            try:
                for line in open(cfg):
                    m = re.match(r'^\s*(DOCKER_IMAGE_FILE|DOCKER_IMAGE_SIZE)=(.*)$', line)
                    if m:
                        val = _unquote(m.group(2).split("#")[0])
                        if m.group(1) == "DOCKER_IMAGE_FILE" and val:
                            CONFIG["DOCKER_IMG_PATH"] = val
                        elif m.group(1) == "DOCKER_IMAGE_SIZE" and val:
                            CONFIG["DOCKER_IMG_SIZE"] = val
            except OSError:
                pass
    elif shutil.which("omv-notify"):
        OS_TYPE = "omv"

    if CONFIG["DOCKER_MODE"] == "auto":
        if OS_TYPE == "unraid":
            CONFIG["DOCKER_MODE"] = "unraid_service"
        elif DOCKER_CMD:
            CONFIG["DOCKER_MODE"] = "container"
        else:
            CONFIG["DOCKER_MODE"] = "disabled"


def _find_loop_for_file(img):
    if not shutil.which("losetup"):
        return ""
    try:
        out = subprocess.run(["losetup", "-j", img], capture_output=True, text=True).stdout
        first = out.splitlines()[0] if out.splitlines() else ""
        return first.split(":")[0] if first else ""
    except Exception:
        return ""


def docker_unraid_mount():
    # Mount docker.img at /var/lib/docker, trying mount_image, then losetup
    # (with and without -P partition scan), then a plain loop mount.
    if is_dry():
        log("[DRY] Unraid mount docker.img")
        return True
    img, size = CONFIG["DOCKER_IMG_PATH"], CONFIG["DOCKER_IMG_SIZE"]
    if not os.path.isfile(img):
        return False
    if os.path.ismount("/var/lib/docker"):
        return True
    log(f"ACTION: Mounting Unraid Docker Image ({img})...")
    os.makedirs("/var/lib/docker", exist_ok=True)

    if shutil.which("/usr/local/sbin/mount_image"):
        if subprocess.run(["/usr/local/sbin/mount_image", img, "/var/lib/docker", size],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
            return True
    if shutil.which("losetup"):
        loop = ""
        for args in (["losetup", "-f", "--show", "-P", img], ["losetup", "-f", "--show", img]):
            r = subprocess.run(args, capture_output=True, text=True)
            if r.returncode == 0 and r.stdout.strip():
                loop = r.stdout.strip()
                break
        if loop:
            if os.path.exists(f"{loop}p1") and subprocess.run(
                ["mount", f"{loop}p1", "/var/lib/docker"], stderr=subprocess.DEVNULL).returncode == 0:
                return True
            if subprocess.run(["mount", loop, "/var/lib/docker"], stderr=subprocess.DEVNULL).returncode == 0:
                return True
            subprocess.run(["losetup", "-d", loop], stderr=subprocess.DEVNULL)
    if subprocess.run(["mount", "-o", "loop", img, "/var/lib/docker"], stderr=subprocess.DEVNULL).returncode == 0:
        return True
    return False


def docker_unraid_unmount():
    if is_dry():
        log("[DRY] Unraid unmount docker.img")
        return
    img = CONFIG["DOCKER_IMG_PATH"]
    if not os.path.isfile(img):
        return
    loop = _find_loop_for_file(img)
    if os.path.ismount("/var/lib/docker"):
        if subprocess.run(["umount", "/var/lib/docker"], stderr=subprocess.DEVNULL).returncode != 0:
            subprocess.run(["umount", "-l", "/var/lib/docker"], stderr=subprocess.DEVNULL)
    if loop:
        subprocess.run(["losetup", "-d", loop], stderr=subprocess.DEVNULL)


def sys_docker_stop():
    mode = CONFIG["DOCKER_MODE"]
    if mode == "unraid_service":
        if is_dry():
            log("[DRY] Stop Unraid Docker Svc")
            set_state("DOCKER_STOPPED", "true")
            return
        log("ACTION: Stopping Unraid Docker Service...")
        subprocess.run(["/etc/rc.d/rc.docker", "stop"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        # Poll status until down, up to DOCKER_STOP_TIMEOUT, then force.
        timeout = int(CONFIG["DOCKER_STOP_TIMEOUT"])
        elapsed = 0
        while True:
            st = subprocess.run(["/etc/rc.d/rc.docker", "status"], capture_output=True, text=True).stdout
            if "running" not in st:
                break
            time.sleep(5)
            elapsed += 5
            if elapsed >= timeout:
                log("WARN: Docker stop timed out. Forcing.")
                subprocess.run(["/etc/rc.d/rc.docker", "force_stop"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                break
        docker_unraid_unmount()
        set_state("DOCKER_STOPPED", "true")
    elif mode == "container":
        if not DOCKER_CMD:
            return
        r = subprocess.run([DOCKER_CMD, "ps", "--format", "{{.Names}}"], capture_output=True, text=True)
        containers = [c for c in r.stdout.splitlines() if c]
        if not containers:
            return
        with open(RUNNING_CONTAINERS_LIST, "w") as f:
            f.write("\n".join(containers) + "\n")
        set_state("DOCKER_STOPPED", "true")
        if is_dry():
            log("[DRY] Stop Containers")
            return
        log("ACTION: Stopping running containers...")
        for c in containers:
            if subprocess.run([DOCKER_CMD, "stop", "-t", CONFIG["DOCKER_STOP_TIMEOUT"], c],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0:
                subprocess.run([DOCKER_CMD, "kill", c], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def sys_docker_start():
    if CONFIG["DOCKER_MODE"] == "disabled":
        return
    if get_state("DOCKER_STOPPED") != "true":
        return
    mode = CONFIG["DOCKER_MODE"]
    if mode == "unraid_service":
        if is_dry():
            log("[DRY] Start Unraid Docker Svc")
            set_state("DOCKER_STOPPED", "false")
            return
        log("ACTION: Starting Unraid Docker Service...")
        if not docker_unraid_mount():
            log("ERROR: Failed to mount docker image")
        subprocess.run(["/etc/rc.d/rc.docker", "start"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(5)
        set_state("DOCKER_STOPPED", "false")
    elif mode == "container":
        if is_dry():
            log("[DRY] Start Containers")
            set_state("DOCKER_STOPPED", "false")
            return
        if os.path.isfile(RUNNING_CONTAINERS_LIST):
            log("ACTION: Restarting containers...")
            with open(RUNNING_CONTAINERS_LIST) as f:
                for c in f.read().splitlines():
                    if c and DOCKER_CMD:
                        subprocess.run([DOCKER_CMD, "start", c], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                os.remove(RUNNING_CONTAINERS_LIST)
            except OSError:
                pass
        set_state("DOCKER_STOPPED", "false")


# ==============================================================================
# 8. TOOLS & HELPERS
# ==============================================================================


def get_thread_count():
    t = CONFIG["CPU_THREADS"]
    if t == "all":
        return os.cpu_count() or 1
    if str(t).isdigit() and int(t) > 0:
        return int(t)
    return 1


def tar_compress_cmd():
    if shutil.which("pigz"):
        t = CONFIG["CPU_THREADS"]
        flag = f"-p {t} " if t != "all" and str(t).isdigit() else ""
        return f"pigz {flag}--best".strip()
    return "gzip"


def rsync_base_opts():
    opts = ["--archive", "--compress", "--human-readable", "--omit-dir-times", "--update",
            "--partial-dir=.abpartial", f"--include={CHECKSUM_DIR}", "--exclude=.abpartial", "--timeout=60"]
    if CONFIG.get("LOG_VERBOSITY") == "debug":
        opts.append("--progress")
    return opts


def ensure_dir(path):
    if not is_dry():
        os.makedirs(path, exist_ok=True)


def safe_rsync(args):
    # args: list after "rsync". Returns True on success (or rsync code 24).
    if is_dry():
        log(f"[DRY] rsync {' '.join(args)}")
        return True
    r = subprocess.run(["rsync"] + args)
    if r.returncode == 0:
        return True
    if r.returncode == 24:
        log("WARN: RSync partial transfer (Code 24 - files vanished). Continuing.")
        return True
    log(f"ERROR: RSync failed with fatal code {r.returncode}.")
    return False


# --- Checksum helpers (dated _YYYYMMDD.sha256 contract) ---


def _rel_to_base(file_path, base):
    base = base.rstrip("/")
    if file_path.startswith(base + "/"):
        return file_path[len(base) + 1:]
    return os.path.basename(file_path)


def checksum_dir_for(file_path, base):
    rel = _rel_to_base(file_path, base)
    return os.path.join(base, CHECKSUM_DIR, os.path.dirname(rel))


def checksum_find_path(file_path, base):
    # Newest dated checksum sibling for a data file, or None. YYYYMMDD sorts
    # chronologically as a string, so lexical sort + last wins.
    chk_dir = checksum_dir_for(file_path, base)
    name = os.path.basename(_rel_to_base(file_path, base))
    matches = glob.glob(os.path.join(chk_dir, name + "_" + "[0-9]" * 8 + ".sha256"))
    if not matches:
        return None
    return sorted(matches)[-1]


def checksum_date_from_path(chk_path):
    m = re.search(r"_([0-9]{8})\.sha256$", os.path.basename(chk_path))
    return m.group(1) if m else None


def sha256_of(path, timeout=600):
    # sha256sum via subprocess so a hung filesystem read times out instead of
    # blocking forever. Returns the hex digest, or None on timeout/failure.
    try:
        r = subprocess.run(["sha256sum", path], capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return None
    if r.returncode != 0 or not r.stdout.strip():
        return None
    return r.stdout.split()[0]


def write_checksum(file_path, base):
    # Sweep stale dated siblings, then write one dated checksum atomically.
    if is_dry():
        return True
    chk_dir = checksum_dir_for(file_path, base)
    name = os.path.basename(_rel_to_base(file_path, base))
    os.makedirs(chk_dir, exist_ok=True)
    for old in glob.glob(os.path.join(chk_dir, name + "_" + "[0-9]" * 8 + ".sha256")):
        try:
            os.remove(old)
        except OSError:
            pass
    digest = sha256_of(file_path)
    if digest is None:
        return False
    chk = os.path.join(chk_dir, f"{name}_{CDATE}.sha256")
    tmp = f"{chk}.tmp.{os.getpid()}"
    try:
        with open(tmp, "w") as f:
            f.write(digest + "\n")
        os.replace(tmp, chk)
        return True
    except OSError:
        try:
            os.remove(tmp)
        except OSError:
            pass
        return False


def verify_file(file_path, base):
    # Return codes mirror bash: 0 ok, 2 no file, 4 mismatch, 5 timeout.
    # A missing dated checksum passes (watchtower stamps it on its next scan).
    if not os.path.isfile(file_path):
        return VERIFY_NO_FILE
    chk = checksum_find_path(file_path, base)
    if not chk:
        return VERIFY_OK
    try:
        with open(chk) as f:
            expected = f.read().strip()
    except OSError:
        return VERIFY_OK
    actual = sha256_of(file_path, timeout=600)
    if actual is None:
        log(f"WARN: sha256sum timed out or failed for {file_path}")
        return VERIFY_TIMEOUT
    return VERIFY_OK if expected == actual else VERIFY_MISMATCH


def write_manifest(out_path, archive_name, base, members):
    try:
        fqdn = socket.getfqdn() or "unknown"
        with open(out_path, "w") as f:
            f.write("# Auto-Backupper archive manifest\n")
            f.write(f"archive: {archive_name}\n")
            f.write(f"created_at: {datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')}\n")
            f.write(f"host: {hostname_var()}\n")
            f.write(f"host_long: {fqdn}\n")
            f.write(f"os: {OS_TYPE}\n")
            f.write(f"kernel: {' '.join(os.uname()[:3]) if hasattr(os, 'uname') else 'unknown'}\n")
            f.write(f"base_dir: {base}\n")
            f.write("source_paths:\n")
            for p in members:
                f.write(f"  - {p}\n")
            f.write("tools:\n")
            f.write(f"  compress: {tar_compress_cmd()}\n")
            f.write(f"  python: {sys.version.split()[0]}\n")
        return True
    except OSError:
        return False


def create_archive(archive, base, members, exclusions=None):
    # tar -S (sparse) the members under base, embed a MANIFEST, write a dated
    # checksum, and record the archive in the session manifest. Returns True.
    global CURRENT_ARCHIVE_FILE
    exclusions = exclusions or []
    ensure_dir(os.path.dirname(archive))
    CURRENT_ARCHIVE_FILE = archive
    log(f"Archiving: {archive}")

    if is_dry():
        log(f"[DRY] tar -S -cf {archive} -C {base} {' '.join(exclusions + members)}")
        CREATED_ARCHIVES.append(archive)
        CURRENT_ARCHIVE_FILE = None
        return True

    # Build a MANIFEST in a temp dir and append it via an interleaved -C. Bonus,
    # not required: any failure falls back to an un-manifested archive.
    manifest_dir = ""
    try:
        manifest_dir = tempfile.mkdtemp(prefix="ab_manifest.")
        os.makedirs(os.path.join(manifest_dir, ".auto-backupper"), exist_ok=True)
        if not write_manifest(os.path.join(manifest_dir, ".auto-backupper", "MANIFEST.txt"),
                              os.path.basename(archive), base, members):
            shutil.rmtree(manifest_dir, ignore_errors=True)
            manifest_dir = ""
    except OSError:
        manifest_dir = ""

    flags = "-cvf" if CONFIG.get("LOG_VERBOSITY") == "debug" else "-cf"
    cmd = ["tar", "-S", f"--use-compress-program={tar_compress_cmd()}", flags, archive, "-C", base]
    cmd += exclusions + members
    if manifest_dir and os.path.isfile(os.path.join(manifest_dir, ".auto-backupper", "MANIFEST.txt")):
        cmd += ["-C", manifest_dir, ".auto-backupper/MANIFEST.txt"]

    rc = subprocess.run(cmd).returncode
    if manifest_dir:
        shutil.rmtree(manifest_dir, ignore_errors=True)

    if rc == 0:
        write_checksum(archive, CONFIG["BACKUP_BASE"])
        try:
            with open(SESSION_MANIFEST, "a") as f:
                f.write(archive + "\n")
        except OSError:
            pass
        CREATED_ARCHIVES.append(archive)
        CURRENT_ARCHIVE_FILE = None
        return True

    log(f"ERROR: Archive failed: {archive}")
    send_notify("alert", "Backup Failed", archive)
    try:
        os.remove(archive)
    except OSError:
        pass
    CURRENT_ARCHIVE_FILE = None
    return False


CREATED_ARCHIVES = []


def backup_recursive_folder(share_name):
    # domains / iscsi: archive each immediate subfolder separately.
    parent = os.path.join(CONFIG["SHARES_BASE_FOLDER"], share_name)
    if not os.path.isdir(parent):
        log(f"WARN: Share '{share_name}' not found.")
        return
    log(f"Phase: Granular Backup for '{share_name}'")
    excl = CONFIG["SHARES_EXCLUDE"].get(share_name, [])
    for entry in sorted(os.listdir(parent)):
        sub = os.path.join(parent, entry)
        if not os.path.isdir(sub):
            continue
        dest_dir = os.path.join(CONFIG["BACKUP_BASE"], "shares", share_name, entry)
        archive = os.path.join(dest_dir, f"{entry}_{CDATE}{TAR_EXT}")
        create_archive(archive, parent, [entry], exclusions=excl)


# --- Rotation ---


def rotation_date_for(file_path, base):
    # Source of truth: newest dated checksum suffix; mtime as fallback.
    chk_dir = checksum_dir_for(file_path, base)
    name = os.path.basename(_rel_to_base(file_path, base))
    best = None
    for c in glob.glob(os.path.join(chk_dir, name + "_" + "[0-9]" * 8 + ".sha256")):
        d = checksum_date_from_path(c)
        if d and (best is None or int(d) > int(best)):
            best = d
    if best:
        return best
    try:
        return datetime.datetime.fromtimestamp(os.path.getmtime(file_path)).strftime("%Y%m%d")
    except OSError:
        return None


def rotation_phase():
    days = int(CONFIG.get("ROTATE_DAYS", "0") or 0)
    if days <= 0:
        return
    cutoff = (datetime.datetime.now() - datetime.timedelta(days=days)).strftime("%Y%m%d")
    log(f"Phase: Rotation (retention {days}d, cutoff YYYYMMDD < {cutoff})")
    base = CONFIG["BACKUP_BASE"]
    chk_root = os.path.join(base, CHECKSUM_DIR)
    rotate_count = mtime_fallback = 0

    for root, dirs, files in os.walk(base):
        if root == chk_root or root.startswith(chk_root + os.sep):
            dirs[:] = []
            continue
        if CHECKSUM_DIR in dirs:
            dirs.remove(CHECKSUM_DIR)
        for fn in files:
            fp = os.path.join(root, fn)
            d = rotation_date_for(fp, base)
            if not d or int(d) >= int(cutoff):
                continue
            rotate_count += 1
            has_dated = checksum_find_path(fp, base) is not None
            if not has_dated:
                mtime_fallback += 1
            if is_dry():
                log(f"[DRY-ROTATE] {_rel_to_base(fp, base)} (date={d}, source={'suffix' if has_dated else 'mtime'})")
                continue
            # Delete the data file only; its checksum is retained as a
            # distributed historical index (pruned out-of-band by auto-restorer).
            try:
                os.remove(fp)
            except OSError:
                pass

    if mtime_fallback:
        log(f"INFO: Rotation used mtime fallback for {mtime_fallback} un-stamped file(s)")
    if is_dry():
        log(f"Rotation [DRY]: {rotate_count} file(s) would be removed")
        return
    if rotate_count:
        log(f"Rotation: {rotate_count} data file(s) removed (checksums retained as historical index)")
    # Remove now-empty data subdirs (never BACKUP_BASE itself).
    for root, dirs, files in os.walk(base, topdown=False):
        if root == base or root == chk_root or root.startswith(chk_root + os.sep):
            continue
        try:
            if not os.listdir(root):
                os.rmdir(root)
        except OSError:
            pass


# --- Hostname case-drift warning ---


def warn_hostname_case_drift():
    base = CONFIG["BACKUP_BASE"]
    if not os.path.isdir(base):
        return
    canonical = hostname_var()
    sysd = os.path.join(base, "systems")
    if os.path.isdir(sysd):
        for entry in os.listdir(sysd):
            if os.path.isdir(os.path.join(sysd, entry)) and entry.upper() == canonical.upper() and entry != canonical:
                log(f"WARN: Found case-variant hostname directory: {sysd}/{entry}/")
                log(f"      Suite uses UPPERCASE canonical: {sysd}/{canonical}/")
                log(f'      Or set HOSTNAME_VAR="{entry}" in the config to keep current behaviour.')
    chk_dir = os.path.join(base, CHECKSUM_DIR)
    if os.path.isdir(chk_dir):
        for f in glob.glob(os.path.join(chk_dir, "*_corruption_report.txt")):
            host_part = os.path.basename(f)[: -len("_corruption_report.txt")]
            if host_part.upper() == canonical.upper() and host_part != canonical:
                log(f"WARN: Found case-variant corruption report: {f}")
                log(f"      Suite uses UPPERCASE canonical: {chk_dir}/{canonical}_corruption_report.txt")


# --- Preflight ---


def preflight_checks():
    log("Phase: Pre-flight Checks")
    base = CONFIG["BACKUP_BASE"]
    if not is_dry() and not os.access(base, os.W_OK):
        log(f"FATAL: Backup destination '{base}' is not writable or does not exist.")
        return False
    for cmd in ("tar", "rsync", "find", "sha256sum"):
        if not shutil.which(cmd):
            log(f"FATAL: Required command '{cmd}' not found.")
            return False
    if CONFIG["MODE"] in ("pull", "both"):
        for remote in CONFIG["REMOTE_PULL_SOURCES"]:
            if not os.path.isdir(remote):
                log(f"WARN: Remote mount '{remote}' is missing.")
    if CONFIG.get("PREFLIGHT_SPACE_CHECK", "true") == "true" and CONFIG["MODE"] != "pull":
        if not preflight_free_space_check():
            return False
    log("Pre-flight checks passed.")
    return True


def _du_bytes(path):
    try:
        r = subprocess.run(["du", "-sb", path], capture_output=True, text=True, timeout=120)
        if r.returncode == 0 and r.stdout.split():
            return int(r.stdout.split()[0])
    except Exception:
        pass
    return None


def preflight_free_space_check():
    log("Pre-flight: Estimating space requirements (this may take a moment on large shares)...")
    sources = []
    if CONFIG["BACKUP_SYSTEM"] == "true" and not CONFIG["OMV_DOCKER_BACKUP_PATH"]:
        for p in (CONFIG["SYSTEM_APPDATA_PATH"], CONFIG["SYSTEM_BOOT_PATH"]):
            if os.path.isdir(p):
                sources.append(p)
    if CONFIG["OMV_DOCKER_BACKUP_PATH"] and os.path.isdir(CONFIG["OMV_DOCKER_BACKUP_PATH"]):
        sources.append(CONFIG["OMV_DOCKER_BACKUP_PATH"])
    if CONFIG["DOCKER_MODE"] == "unraid_service" and CONFIG["BACKUP_DOCKER_IMG"] == "true":
        if os.path.isfile(CONFIG["DOCKER_IMG_PATH"]):
            sources.append(CONFIG["DOCKER_IMG_PATH"])
    if CONFIG["BACKUP_SHARES"] == "true":
        for share in CONFIG["SHARES_TO_BACKUP"]:
            src = os.path.join(CONFIG["SHARES_BASE_FOLDER"], share)
            if os.path.isdir(src):
                sources.append(src)

    if not sources:
        log("  No measurable sources. Pre-flight: Space check skipped.")
        return True

    total = 0
    for src in sources:
        size = _du_bytes(src)
        if size is None:
            log(f"  WARN: Could not measure '{src}' (timeout or error). Estimate may be low.")
        else:
            total += size

    free = 0
    try:
        st = os.statvfs(CONFIG["BACKUP_BASE"])
        free = st.f_bavail * st.f_frsize
    except OSError:
        pass

    ratio = float(CONFIG.get("PREFLIGHT_COMPRESSION_RATIO", "0.4"))
    margin = int(CONFIG.get("PREFLIGHT_MARGIN_BYTES", str(1073741824)))
    required = int(total * ratio + margin)
    g = 1073741824
    log(f"  Source total (uncompressed): {total / g:.1f} GiB across {len(sources)} path(s)")
    log(f"  Destination free:            {free / g:.1f} GiB on {CONFIG['BACKUP_BASE']}")

    if free < required:
        log(f"FATAL: Estimated {required / g:.1f} GiB required, only {free / g:.1f} GiB free on {CONFIG['BACKUP_BASE']}")
        log("       Free up space, trim SHARES_TO_BACKUP, lower ROTATE_DAYS, or set PREFLIGHT_SPACE_CHECK=false.")
        send_notify("alert", "Backup Aborted", f"Insufficient space: {free / g:.1f} GiB free, {required / g:.1f} GiB needed")
        return False
    if free < total:
        log(f"  WARN: Free space ({free / g:.1f} GiB) < uncompressed source total ({total / g:.1f} GiB). Margin is thin.")
    log(f"Pre-flight: Space check passed (need ~{required / g:.1f} GiB, have {free / g:.1f} GiB).")
    return True


# ==============================================================================
# 9. PHASE FILTER
# ==============================================================================


def phase_enabled(name):
    return not ONLY_PHASES or name in ONLY_PHASES


# ==============================================================================
# 10. PRODUCE FLOW
# ==============================================================================


def _container_running(name):
    if not DOCKER_CMD or not name:
        return False
    r = subprocess.run([DOCKER_CMD, "ps", "-q", "-f", f"name=^/{name}$"], capture_output=True, text=True)
    return bool(r.stdout.strip())


def _dump_sql():
    base = CONFIG["BACKUP_BASE"]
    sql_type = CONFIG["SQL_TYPE"]
    container = CONFIG["SQL_CONTAINER_NAME"]
    if not container:
        log("ERROR: BACKUP_SQL=true but SQL_CONTAINER_NAME is empty. Host-based SQL backup is not implemented.")
        send_notify("alert", "SQL Backup Misconfigured", "Set SQL_CONTAINER_NAME or disable BACKUP_SQL.")
        return
    out_path = os.path.join(base, "services", sql_type)
    ensure_dir(out_path)
    log("Phase: SQL Backup")
    if not _container_running(container):
        log(f"WARN: SQL Container {container} not running.")
        return

    # Prefer mariadb-* binaries when present (MariaDB 10.5+ renamed mysql-*).
    cli_bin, dump_bin = "mysql", "mysqldump"
    if sql_type == "mysql":
        if subprocess.run([DOCKER_CMD, "exec", container, "sh", "-c", "command -v mariadb-dump"],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
            cli_bin, dump_bin = "mariadb", "mariadb-dump"
        log(f"SQL: using '{cli_bin}' / '{dump_bin}' inside {container}")

    dbs = list(CONFIG["SQL_DATABASES"])
    if not dbs:
        if sql_type == "mysql":
            r = subprocess.run(
                [DOCKER_CMD, "exec", "-e", f"MYSQL_PWD={CONFIG['SQL_PASS']}", container, cli_bin,
                 "-h", CONFIG["SQL_HOST"], "-u", CONFIG["SQL_USER"], "-e", "show databases", "-s", "--skip-column-names"],
                capture_output=True, text=True)
            sysdbs = {"information_schema", "mysql", "performance_schema", "sys"}
            dbs = [d for d in r.stdout.splitlines() if d and d not in sysdbs]
        else:
            r = subprocess.run(
                [DOCKER_CMD, "exec", "-e", f"PGPASSWORD={CONFIG['SQL_PASS']}", container, "psql",
                 "-h", CONFIG["SQL_HOST"], "-U", CONFIG["SQL_USER"], "-t", "-c",
                 "SELECT datname FROM pg_database WHERE datistemplate = false;"],
                capture_output=True, text=True)
            dbs = [d.strip() for d in r.stdout.splitlines() if d.strip()]

    for db in dbs:
        if not db:
            continue
        log(f"Dumping {db}...")
        with tempfile.TemporaryDirectory() as tmp:
            dump_file = f"{db}.sql"
            final = os.path.join(out_path, f"{sql_type}_{db}_{CDATE}{TAR_EXT}")
            if sql_type == "mysql":
                # Password via MYSQL_PWD env so it never appears in ps / cmdline.
                cmd = [DOCKER_CMD, "exec", "-e", f"MYSQL_PWD={CONFIG['SQL_PASS']}", container, dump_bin,
                       "-h", CONFIG["SQL_HOST"], "-u", CONFIG["SQL_USER"], "--routines", "--triggers", "--databases", db]
            else:
                # Password via PGPASSWORD env so it never appears on pg_dump's argv.
                cmd = [DOCKER_CMD, "exec", "-e", f"PGPASSWORD={CONFIG['SQL_PASS']}", container, "pg_dump",
                       "-h", CONFIG["SQL_HOST"], "-U", CONFIG["SQL_USER"], "-d", db]
            with open(os.path.join(tmp, dump_file), "w") as out:
                ok = subprocess.run(cmd, stdout=out, stderr=subprocess.DEVNULL).returncode == 0
            if ok:
                create_archive(final, tmp, [dump_file])
            else:
                log(f"ERROR: SQL Dump failed for {db}")


def _dump_mongo():
    base = CONFIG["BACKUP_BASE"]
    container = CONFIG["MONGO_CONTAINER_NAME"]
    out_path = os.path.join(base, "services", "mongo")
    ensure_dir(out_path)
    log("Phase: Mongo Backup")
    if not _container_running(container):
        log(f"WARN: Mongo Container {container} not running.")
        return

    # Pass credentials via a mode-600 YAML config copied into the container,
    # then scrub both copies — keeps the password out of ps / cmdline.
    host_creds = None
    container_creds = f"/tmp/ab_mongo_creds_{os.getpid()}.yml"
    try:
        fd, host_creds = tempfile.mkstemp(suffix=".yml")
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w") as f:
            # json.dumps produces a valid double-quoted scalar (JSON strings are
            # valid YAML), so a quote/backslash in the password can't break the file.
            f.write(f"username: {json.dumps(CONFIG['MONGO_USER'])}\n")
            f.write(f"password: {json.dumps(CONFIG['MONGO_PASS'])}\n")
            f.write(f"authenticationDatabase: {json.dumps(CONFIG['MONGO_AUTH_DB'])}\n")
        if subprocess.run([DOCKER_CMD, "cp", host_creds, f"{container}:{container_creds}"],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0:
            log(f"ERROR: Failed to copy mongo credentials into container {container}")
            return
        subprocess.run([DOCKER_CMD, "exec", container, "chmod", "600", container_creds],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

        mdbs = list(CONFIG["MONGO_DATABASES"]) or ["ALL"]
        for mdb in mdbs:
            with tempfile.TemporaryDirectory() as tmp:
                dump_file = f"{mdb}.archive.gz"
                final = os.path.join(out_path, f"mongo_{mdb}_{CDATE}{TAR_EXT}")
                cmd = [DOCKER_CMD, "exec", container, "mongodump", "--config", container_creds, "--archive", "--gzip"]
                if mdb != "ALL":
                    cmd += ["--db", mdb]
                with open(os.path.join(tmp, dump_file), "w") as out:
                    ok = subprocess.run(cmd, stdout=out, stderr=subprocess.DEVNULL).returncode == 0
                if ok:
                    create_archive(final, tmp, [dump_file])
                else:
                    log(f"ERROR: Mongo dump failed for {mdb}")
        subprocess.run([DOCKER_CMD, "exec", container, "rm", "-f", container_creds],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    finally:
        if host_creds and os.path.isfile(host_creds):
            if shutil.which("shred"):
                if subprocess.run(["shred", "-u", host_creds], stderr=subprocess.DEVNULL).returncode != 0:
                    try:
                        os.remove(host_creds)
                    except OSError:
                        pass
            else:
                try:
                    os.remove(host_creds)
                except OSError:
                    pass


def _dump_redis():
    base = CONFIG["BACKUP_BASE"]
    container = CONFIG["REDIS_CONTAINER_NAME"]
    out_path = os.path.join(base, "services", "redis")
    ensure_dir(out_path)
    log("Phase: Redis Backup")
    if not _container_running(container):
        log(f"WARN: Redis Container {container} not running.")
        return
    with tempfile.TemporaryDirectory() as tmp:
        dump_file = "dump.rdb"
        final = os.path.join(out_path, f"redis_{CDATE}{TAR_EXT}")
        # Password via REDISCLI_AUTH env so it stays off argv.
        cmd = [DOCKER_CMD, "exec"]
        if CONFIG["REDIS_PASS"]:
            cmd += ["-e", f"REDISCLI_AUTH={CONFIG['REDIS_PASS']}"]
        cmd += [container, "redis-cli", "--rdb", "-"]
        with open(os.path.join(tmp, dump_file), "w") as out:
            ok = subprocess.run(cmd, stdout=out, stderr=subprocess.DEVNULL).returncode == 0
        if ok:
            create_archive(final, tmp, [dump_file])
        else:
            log("ERROR: Redis dump failed")


def produce_flow():
    log("=== Starting PRODUCE Flow ===")
    if ONLY_PHASES:
        log(f"Phase filter (--only): {' '.join(ONLY_PHASES)} — rotation skipped")
    send_notify("normal", "Backup Started", "Mode: Produce")
    ensure_dir(CONFIG["BACKUP_BASE"])

    # 1. DATABASE DUMPS
    if not phase_enabled("db"):
        log("Skipping database phase (--only does not include 'db')")
    elif not DOCKER_CMD:
        log("INFO: Docker not detected. Skipping Database Dumps.")
    elif is_dry():
        log("[DRY] Skipping database dumps in dry-run.")
    else:
        if CONFIG["BACKUP_SQL"] == "true":
            _dump_sql()
        if CONFIG["BACKUP_MONGO"] == "true":
            _dump_mongo()
        if CONFIG["BACKUP_REDIS"] == "true":
            _dump_redis()

    # 2. SYSTEM / OMV BACKUP
    use_omv = bool(CONFIG["OMV_DOCKER_BACKUP_PATH"]) and os.path.isdir(CONFIG["OMV_DOCKER_BACKUP_PATH"])
    need_docker_stop = (
        CONFIG["DOCKER_MODE"] != "disabled"
        and phase_enabled("systems")
        and (CONFIG["BACKUP_SYSTEM"] == "true" or use_omv)
    )
    if need_docker_stop:
        sys_docker_stop()

    base = CONFIG["BACKUP_BASE"]
    host = hostname_var()
    if not phase_enabled("systems"):
        log("Skipping systems phase (--only does not include 'systems')")
    elif use_omv:
        log("Phase: Cloning OMV Backups")
        dest = os.path.join(base, "systems", host, "omv_docker_clones")
        ensure_dir(dest)
        if not safe_rsync(rsync_base_opts() + [CONFIG["OMV_DOCKER_BACKUP_PATH"].rstrip("/") + "/", dest + "/"]):
            log("WARN: OMV Docker Clone safe_rsync reported errors. Continuing...")
    elif CONFIG["BACKUP_SYSTEM"] == "true":
        log("Phase: System Backup")
        targets = []
        if os.path.isdir(CONFIG["SYSTEM_APPDATA_PATH"]):
            targets.append(CONFIG["SYSTEM_APPDATA_PATH"])
        if os.path.isdir(CONFIG["SYSTEM_BOOT_PATH"]):
            targets.append(CONFIG["SYSTEM_BOOT_PATH"])
        if CONFIG["DOCKER_MODE"] == "unraid_service" and CONFIG["BACKUP_DOCKER_IMG"] == "true":
            if os.path.isfile(CONFIG["DOCKER_IMG_PATH"]):
                log(f"Including Docker Image: {CONFIG['DOCKER_IMG_PATH']}")
                targets.append(CONFIG["DOCKER_IMG_PATH"])
            else:
                log(f"WARN: Docker image file not found: {CONFIG['DOCKER_IMG_PATH']}")
        if targets:
            sys_path = os.path.join(base, "systems", host, f"{host}_{CDATE}{TAR_EXT}")
            # tar members are paths relative to "/" (leading slash stripped by tar).
            create_archive(sys_path, "/", [t.lstrip("/") for t in targets])

    if need_docker_stop:
        sys_docker_start()

    # 3. SHARES BACKUP (hot)
    if not phase_enabled("shares"):
        log("Skipping shares phase (--only does not include 'shares')")
    elif CONFIG["BACKUP_SHARES"] == "true":
        log("Phase: Shares Backup")
        share_base = CONFIG["SHARES_BASE_FOLDER"]
        for share in CONFIG["SHARES_TO_BACKUP"]:
            if share in ("domains", "iscsi"):
                backup_recursive_folder(share)
                continue
            if share == "FamilyBackups":
                fam_root = os.path.join(share_base, "FamilyBackups")
                if os.path.isdir(fam_root):
                    log("Phase: Granular Backup for 'FamilyBackups'")
                    for m_name in sorted(os.listdir(fam_root)):
                        m_path = os.path.join(fam_root, m_name)
                        if not os.path.isdir(m_path):
                            continue
                        for sub in ("users", "systems"):
                            sub_full = os.path.join(m_path, sub)
                            if os.path.isdir(sub_full):
                                dest = os.path.join(base, "shares", "FamilyBackups", m_name, sub,
                                                    f"{m_name}_{sub}_{CDATE}{TAR_EXT}")
                                create_archive(dest, sub_full, ["."])
                continue

            src = os.path.join(share_base, share)
            if not os.path.isdir(src):
                continue
            excl = CONFIG["SHARES_EXCLUDE"].get(share, [])
            clean = os.path.basename(share.rstrip("/"))
            dest = os.path.join(base, "shares", share, f"{clean}_{CDATE}{TAR_EXT}")
            create_archive(dest, share_base, [share], exclusions=excl)

    # 4. VERIFY
    if CONFIG["VERIFY_LOCAL_BACKUPS"] == "true" or CONFIG.get("VERIFY_ALL_LOCAL_BACKUPS") == "true":
        _verify_local()

    # 5. ROTATE (skipped on partial --only runs)
    if ONLY_PHASES:
        log("Skipping rotation: --only is set (partial run)")
    else:
        rotation_phase()
    send_notify("normal", "Backup Complete", "Local produce finished.")


def _verify_local():
    base = CONFIG["BACKUP_BASE"]
    threads = get_thread_count()
    full = CONFIG.get("VERIFY_ALL_LOCAL_BACKUPS") == "true"
    if full:
        files = []
        chk_root = os.path.join(base, CHECKSUM_DIR)
        for root, dirs, fs in os.walk(base):
            if root == chk_root or root.startswith(chk_root + os.sep):
                dirs[:] = []
                continue
            if CHECKSUM_DIR in dirs:
                dirs.remove(CHECKSUM_DIR)
            files += [os.path.join(root, fn) for fn in fs]
        log(f"Phase: Local Verification [FULL TREE] (Threads: {threads})")
    else:
        files = [a for a in CREATED_ARCHIVES if os.path.isfile(a)]
        log(f"Phase: Local Verification [SESSION ONLY — {len(files)} file(s)] (Threads: {threads})")
    if not files:
        return
    failed = _verify_many(files, base, threads)
    if failed:
        for f in failed:
            log(f"ERROR: Verification failed for {f}")
            send_notify("alert", "Verify Failed", f)
    else:
        log("Verification Successful (No IPC Error Exceptions)")


def _verify_many(files, base, threads):
    failed = []
    with ThreadPoolExecutor(max_workers=threads) as ex:
        futures = {ex.submit(verify_file, f, base): f for f in files}
        for fut in futures:
            f = futures[fut]
            try:
                # Timeout above sha256_of's 600s ceiling so a wedged stat() on a
                # dead mount can't block the whole run; treat a hang as a failure.
                if fut.result(timeout=900) not in (VERIFY_OK,):
                    failed.append(f)
            except FuturesTimeout:
                log(f"ERROR: Verification timed out for {f}")
                failed.append(f)
            except Exception:
                failed.append(f)
    return failed


# ==============================================================================
# 11. PULL FLOW
# ==============================================================================

_SYSTEM_FOLDERS = {
    "srv", "mnt", "proc", "sys", "dev", "run", "tmp", "var", "boot",
    "etc", "usr", "bin", "sbin", "lib", "lib64", "opt", "root",
}


def pull_flow():
    log("=== Starting PULL Flow ===")
    remotes = CONFIG["REMOTE_PULL_SOURCES"]
    if not remotes:
        return
    base = CONFIG["BACKUP_BASE"]
    threads = get_thread_count()
    ensure_dir(base)

    for remote_root in remotes:
        if not os.path.isdir(remote_root):
            log(f"ERROR: Remote path not found: {remote_root}. Skipping.")
            continue

        # Detect the active backup root via the .checksums sentinel; if it's not
        # at the top, search up to 5 levels deep and use its parent.
        active = remote_root
        if not os.path.isdir(os.path.join(remote_root, CHECKSUM_DIR)):
            found = None
            for depth_root, dirs, _ in os.walk(remote_root):
                if depth_root[len(remote_root):].count(os.sep) >= 5:
                    dirs[:] = []
                    continue
                if CHECKSUM_DIR in dirs:
                    found = os.path.join(depth_root, CHECKSUM_DIR)
                    break
            if found:
                active = os.path.dirname(found)
                log(f"REDIRECT: Found nested backup root at: {active}")
        log(f"Syncing from detected source: {active}")

        # Folder discovery with name validation + system-folder safety filter.
        folders = []
        try:
            entries = sorted(os.listdir(active))
        except OSError:
            entries = []
        for name in entries:
            if name.startswith("."):
                continue
            if not os.path.isdir(os.path.join(active, name)):
                continue
            if not name or "/" in name:
                log(f"WARN: Skipping unexpected directory entry (name='{name}')")
                continue
            if name in _SYSTEM_FOLDERS:
                log(f"WARN: Safety Filter - Ignoring system folder: {name}")
                continue
            folders.append(name)
        if not folders:
            log(f"WARN: No valid folders found in {active}.")
            continue

        # Marker for session-scoped verify (files rsync writes get a newer ctime).
        os.makedirs(IPC_BASE, exist_ok=True)
        pull_marker = os.path.join(IPC_BASE, "pull_start_marker")
        if not is_dry():
            open(pull_marker, "w").close()
            time.sleep(1)
        marker_ctime = os.stat(pull_marker).st_ctime if os.path.isfile(pull_marker) else 0

        # Checksums first — needed to build the retention exclude lists.
        if os.path.isdir(os.path.join(active, CHECKSUM_DIR)):
            log("Pulling checksums first (for retention filter)")
            safe_rsync(rsync_base_opts() + [os.path.join(active, CHECKSUM_DIR) + "/",
                                            os.path.join(base, CHECKSUM_DIR) + "/"])

        # Per-folder exclude lists from the REMOTE's dated checksums older than cutoff.
        folder_excludes = {}
        days = int(CONFIG.get("ROTATE_DAYS", "0") or 0)
        remote_chk = os.path.join(active, CHECKSUM_DIR)
        if days > 0 and os.path.isdir(remote_chk):
            cutoff = (datetime.datetime.now() - datetime.timedelta(days=days)).strftime("%Y%m%d")
            log(f"Pull retention cutoff: YYYYMMDD < {cutoff}")
            excl_count = 0
            for root, _, fs in os.walk(remote_chk):
                for fn in fs:
                    if not re.search(r"_[0-9]{8}\.sha256$", fn):
                        continue
                    chk = os.path.join(root, fn)
                    date_suffix = checksum_date_from_path(chk)
                    if not date_suffix or int(date_suffix) >= int(cutoff):
                        continue
                    rel_with_suffix = os.path.relpath(chk, remote_chk)
                    data_rel = rel_with_suffix[: -len(f"_{date_suffix}.sha256")]
                    if "/" not in data_rel:
                        continue
                    top, sub_rel = data_rel.split("/", 1)
                    folder_excludes.setdefault(top, []).append("/" + sub_rel)
                    excl_count += 1
            log(f"Pull retention: {excl_count} stale file(s) will be skipped")

        # Data sync with per-folder exclude-from.
        for folder in folders:
            src = os.path.join(active, folder)
            dest = os.path.join(base, folder)
            log(f"Pulling folder: {folder}")
            ensure_dir(dest)
            extra = []
            excl_file = None
            if folder_excludes.get(folder):
                os.makedirs(IPC_BASE, exist_ok=True)
                fd, excl_file = tempfile.mkstemp(prefix=f"pull_exclude_{folder.replace('/', '_')}_", dir=IPC_BASE)
                with os.fdopen(fd, "w") as f:
                    f.write("\n".join(folder_excludes[folder]) + "\n")
                extra = [f"--exclude-from={excl_file}"]
            if not safe_rsync(rsync_base_opts() + extra + [src + "/", dest + "/"]):
                log(f"WARN: safe_rsync reported issues with {folder}")
            if excl_file:
                try:
                    os.remove(excl_file)
                except OSError:
                    pass

        # Verification (session-scoped via marker ctime, or full tree).
        if CONFIG["VERIFY_PULLED_BACKUPS"] == "true":
            _verify_pull(folders, base, active, threads, marker_ctime)

    rotation_phase()
    send_notify("normal", "Pull Complete", "Remote sync finished.")


def _verify_pull(folders, base, active, threads, marker_ctime):
    full = CONFIG.get("VERIFY_ALL_PULLED_BACKUPS") == "true"
    log(f"Verifying Pull [{'FULL TREE' if full else 'SESSION ONLY'}] (Threads: {threads})...")
    rel_files = []
    for folder in folders:
        fdir = os.path.join(base, folder)
        if not os.path.isdir(fdir):
            continue
        for root, _, fs in os.walk(fdir):
            for fn in fs:
                fp = os.path.join(root, fn)
                if not full:
                    try:
                        if os.stat(fp).st_ctime <= marker_ctime:
                            continue
                    except OSError:
                        continue
                rel_files.append(os.path.relpath(fp, base))

    log(f"Pull verify scope: {len(rel_files)} file(s).")
    if not rel_files:
        log("Pull Verification: nothing transferred this run, skipping.")
        return

    failed = []
    with ThreadPoolExecutor(max_workers=threads) as ex:
        futures = {ex.submit(verify_file, os.path.join(base, rel), base): rel for rel in rel_files}
        for fut in futures:
            rel = futures[fut]
            try:
                # See _verify_many: bound the wait so a stalled mount can't hang.
                if fut.result(timeout=900) not in (VERIFY_OK,):
                    failed.append(rel)
            except FuturesTimeout:
                log(f"ERROR: Pull verification timed out for {rel}")
                failed.append(rel)
            except Exception:
                failed.append(rel)

    if not failed:
        log("Pull Verification Successful.")
        return

    log(f"Corruption detected: {len(failed)} file(s). Batch re-pulling from {active}...")
    fd, repull = tempfile.mkstemp(prefix="repull_")
    with os.fdopen(fd, "w") as f:
        f.write("\n".join(failed) + "\n")
    ok = safe_rsync([
        "--archive", "--compress", "--human-readable", "--omit-dir-times",
        "--partial-dir=.abpartial", "--exclude=.abpartial", "--timeout=60",
        f"--files-from={repull}", active.rstrip("/") + "/", base.rstrip("/") + "/",
    ])
    try:
        os.remove(repull)
    except OSError:
        pass
    if ok:
        log(f"Batch re-pull finished ({len(failed)} file(s)).")
    else:
        log("ERROR: Batch re-pull reported errors.")


# ==============================================================================
# 12. LIFECYCLE & MAIN
# ==============================================================================


def cleanup():
    if not LOCK_HELD:
        return
    for p in (RUNNING_CONTAINERS_LIST, BACKUP_PIDFILE):
        try:
            os.remove(p)
        except OSError:
            pass
    shutil.rmtree(IPC_BASE, ignore_errors=True)
    try:
        os.remove(LOCKFILE)
    except OSError:
        pass
    if LOCK_FD is not None:
        try:
            fcntl.flock(LOCK_FD, fcntl.LOCK_UN)
            LOCK_FD.close()
        except OSError:
            pass


def interrupt_handler(signum, frame):
    log("WARN: Interrupt detected. Stopping...")
    if CURRENT_ARCHIVE_FILE and os.path.isfile(CURRENT_ARCHIVE_FILE):
        try:
            os.remove(CURRENT_ARCHIVE_FILE)
        except OSError:
            pass
    if get_state("DOCKER_STOPPED") == "true":
        try:
            sys_docker_start()
        except Exception:
            pass
    sys.exit(130)


def parse_args(argv):
    global ONLY_PHASES
    ONLY_PHASES = []
    cfg = None
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in ("-h", "--help"):
            _usage()
            sys.exit(0)
        elif a == "--dry-run":
            CONFIG["DRY_RUN"] = "true"
        elif a in ("-m", "--mode"):
            i += 1
            CONFIG["MODE"] = argv[i] if i < len(argv) else CONFIG["MODE"]
        elif a == "--only":
            i += 1
            if i >= len(argv):
                print("ERROR: --only requires a comma-separated phase list (db,systems,shares)", file=sys.stderr)
                sys.exit(1)
            ONLY_PHASES = _normalize_only(argv[i])
        elif a.startswith("--only="):
            ONLY_PHASES = _normalize_only(a[len("--only="):])
        elif a in ("-c", "--config"):
            i += 1
            cfg = argv[i] if i < len(argv) else None
        elif a.startswith("--config="):
            cfg = a[len("--config="):]
        elif a == "--debug":
            CONFIG["LOG_VERBOSITY"] = "debug"
        elif a == "--no-docker":
            CONFIG["DOCKER_MODE"] = "disabled"
        else:
            print(f"Unknown argument: {a}", file=sys.stderr)
            sys.exit(1)
        i += 1
    return cfg


def _normalize_only(raw):
    out = []
    for tok in raw.split(","):
        p = tok.strip()
        if not p:
            continue
        if p in ("db", "services"):
            out.append("db")
        elif p in ("systems", "shares"):
            out.append(p)
        else:
            print(f"ERROR: --only: unknown phase '{p}' (allowed: db, services, systems, shares)", file=sys.stderr)
            sys.exit(1)
    return out


def _usage():
    print(f"""Usage: {os.path.basename(sys.argv[0])} [OPTIONS]
  -c, --config FILE   Path to config file
  -m, --mode MODE     produce | pull | both
  --only PHASES       Restrict produce to a comma list: db (alias services) | systems | shares
  --dry-run           Simulate actions
  --no-docker         Disable Docker management
  --debug             Verbose logging
  -h, --help          Show this help""")


def _redact(s):
    # Mask credential tokens that could surface in a subprocess argv captured by
    # an exception (TimeoutExpired/CalledProcessError include the full command).
    return re.sub(r"(MYSQL_PWD|PGPASSWORD|REDISCLI_AUTH)=\S+", r"\1=***", s)


def main():
    global LOCK_FD, LOCK_HELD
    if os.geteuid() != 0:
        print("CRITICAL: This script must be run as root.", file=sys.stderr)
        sys.exit(1)

    cli_cfg = parse_args(sys.argv[1:])
    setup_logging()

    cfg_to_load = cli_cfg or DEFAULT_CONFIG_FILE
    if os.path.isfile(cfg_to_load):
        log(f"INFO: Loading configuration from {cfg_to_load}")
        parse_bash_config(cfg_to_load)
    else:
        log(f"INFO: No config file found at {cfg_to_load}. Using internal defaults.")
    CONFIG["BACKUP_BASE"] = CONFIG["BACKUP_BASE"].rstrip("/")

    determine_os_and_docker()

    # Lock for single-instance. Install handlers first so a signal can't strand
    # the lockfile; cleanup() is a no-op until LOCK_HELD is set.
    signal.signal(signal.SIGINT, interrupt_handler)
    signal.signal(signal.SIGTERM, interrupt_handler)
    import atexit
    atexit.register(cleanup)

    try:
        LOCK_FD = open(LOCKFILE, "w")
        fcntl.flock(LOCK_FD, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        log("Instance already running. Exiting.")
        sys.exit(0)
    LOCK_HELD = True

    os.makedirs(os.path.dirname(BACKUP_PIDFILE), exist_ok=True)
    try:
        with open(BACKUP_PIDFILE, "w") as f:
            f.write(str(os.getpid()))
    except OSError:
        pass

    init_state()
    log(f"Startup [OS:{OS_TYPE} | Mode:{CONFIG['MODE']} | Docker:{CONFIG['DOCKER_MODE']}]")
    warn_hostname_case_drift()

    if not preflight_checks():
        log("FATAL: Pre-flight checks failed. Aborting.")
        send_notify("alert", "Backup Aborted", "Pre-flight checks failed.")
        sys.exit(1)

    try:
        mode = CONFIG["MODE"]
        if mode in ("produce", "both"):
            produce_flow()
        if mode in ("pull", "both"):
            pull_flow()
        if mode not in ("produce", "pull", "both"):
            log("Invalid MODE")
            sys.exit(1)
    except SystemExit:
        raise
    except BaseException as e:
        # Emergency: surface the failure and restart Docker if we left it stopped.
        # Redact in case the exception text carries a password-bearing argv.
        msg = _redact(f"{type(e).__name__}: {e}")
        log(f"FATAL: {msg}")
        send_notify("alert", "Backup Critical Failure", msg)
        if get_state("DOCKER_STOPPED") == "true":
            log("EMERGENCY: State indicates Docker is stopped. Attempting restart...")
            try:
                sys_docker_start()
            except Exception:
                pass
        raise

    # Record successful completion for the watchtower scheduler (atomic write).
    try:
        tmp = f"/tmp/auto_backupper_last_run_backup.tmp.{os.getpid()}"
        with open(tmp, "w") as f:
            f.write(datetime.datetime.now().strftime("%Y%m%d"))
        os.replace(tmp, "/tmp/auto_backupper_last_run_backup")
    except OSError:
        pass
    log("Job Finished.")


if __name__ == "__main__":
    main()
