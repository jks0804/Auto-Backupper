#!/usr/bin/env python3
"""
##
# ________  ___  ___  _________  ________                 ________  ________  ________  ___  __    ___  ___  ________  ________  _______   ________
#|\   __  \|\  \|\  \|\___   ___\\   __  \               |\   __  \|\   __  \|\   ____\|\  \|\  \ |\  \|\  \|\   __  \|\   __  \|\  ___ \ |\   __  \
#\ \  \|\  \ \  \\\  \|___ \  \_\ \  \|\  \  ____________\ \  \|\ /\ \  \|\  \ \  \___|\ \  \/  /|\ \  \\\  \ \  \|\  \ \  \|\  \ \   __/|\ \  \|\  \
# \ \   __  \ \  \\\  \   \ \  \ \ \  \\\  \|\____________\ \   __  \ \   __  \ \  \    \ \   ___  \ \  \\\  \ \   ____\ \   ____\ \  \_|/_\ \   _  _\
#  \ \  \ \  \ \  \\\  \   \ \  \ \ \  \\\  \|____________|\ \  \|\  \ \  \ \  \ \  \____\ \  \\ \  \ \  \\\  \ \  \___|\ \  \___|\ \  \_|\ \ \  \\  \|
#   \ \__\ \__\ \_______\   \ \__\ \ \_______\              \ \_______\ \__\ \__\ \_______\ \__\\ \__\ \_______\ \__\    \ \__\    \ \_______\ \__\\ _\
#    \|__|\|__|\|_______|    \|__|  \|_______|               \|_______|\|__|\|__|\|_______|\|__| \|__|\|_______|\|__|     \|__|     \|_______|\|__|\|__|
##

AUTO-BACKUPPER V8.6.4 [Enclave Edition]
------------------------------------------------------------------------------
A faithful port of the original Bash auto-backupper.
This script provides unified, fault-tolerant backup for Unraid, OMV, and Linux.

USAGE:
    sudo python3 auto-backupper.py [OPTIONS]

OPTIONS:
    --config FILE   Path to config file (default: /boot/config/auto_backupper.cfg)
    --mode MODE     produce | pull | both
    --dry-run       Simulate actions without writing
    --no-docker     Disable Docker management explicitly
    --debug         Enable debug logging

DEPENDENCIES:
    Requires: rsync, tar, pigz (optional), docker (optional)
    Python 3.6+
"""

import os
import sys
import json
import time
import signal
import socket
import logging
import argparse
import subprocess
import shutil
import fcntl
import tempfile
import atexit
import shlex
import re
from pathlib import Path
from datetime import datetime
from logging.handlers import RotatingFileHandler
from concurrent.futures import ThreadPoolExecutor, as_completed

# ==============================================================================
# 1. CONSTANTS, PATHS & DEFAULTS
# ==============================================================================

LOCKFILE = "/var/lock/auto_backupper.lock"
ENCLAVE_DIR = "/tmp/enclave"
STATE_FILE = f"{ENCLAVE_DIR}/ab_state"
LOGFILE = "/var/log/auto_backupper.log"

CHECKSUM_DIR = ".checksums"
HOSTNAME_VAR = socket.gethostname().split('.')[0]
CDATE = datetime.utcnow().strftime("%Y%m%d")

CONFIG = {
    "CPU_THREADS": "1",
    "MODE": "produce",
    "DRY_RUN": "true",
    "SKIP_PREFLIGHT": "false",
    "BACKUP_BASE": "/mnt/user/backup",
    "SHARES_BASE_FOLDER": "/mnt/user",
    "SYSTEM_APPDATA_PATH": "/mnt/cache/appdata",
    "SYSTEM_BOOT_PATH": "/boot",
    "OMV_DOCKER_BACKUP_PATH": "",
    "UNRAID_DOCKER_CFG": "/boot/config/docker.cfg",
    "DOCKER_IMG_PATH": "/mnt/cache/system/docker/docker.img",
    "DOCKER_IMG_SIZE": "80",
    "BACKUP_DOCKER_IMG": "true",
    "DOCKER_MODE": "auto",
    "DOCKER_STOP_TIMEOUT": "60",
    "ROTATE_DAYS": "90",
    "VERIFY_LOCAL_BACKUPS": "true",
    "VERIFY_PULLED_BACKUPS": "true",
    "BACKUP_SYSTEM": "true",
    "BACKUP_SHARES": "true",
    
    "BACKUP_MYSQL": "false",
    "MYSQL_CONTAINER_NAME": "mariadb",
    "MYSQL_HOST": "172.18.0.4",
    "MYSQL_USER": "root",
    "MYSQL_PASS": "YourMySQLPassword",
    "MYSQL_DATABASES": [],
    
    "BACKUP_POSTGRES": "false",
    "POSTGRES_CONTAINER_NAME": "postgres",
    "POSTGRES_HOST": "172.18.0.5",
    "POSTGRES_USER": "postgres",
    "POSTGRES_PASS": "YourPostgresPassword",
    "POSTGRES_DATABASES": [],
    
    "BACKUP_MONGO": "false",
    "MONGO_CONTAINER_NAME": "mongodb",
    "MONGO_USER": "root",
    "MONGO_PASS": "YourMongoPassword",
    "MONGO_AUTH_DB": "admin",
    "MONGO_DATABASES": [],
    
    "BACKUP_REDIS": "false",
    "REDIS_CONTAINER_NAME": "redis",
    "REDIS_PASS": "",
    
    "SHARES_TO_BACKUP": [
        "codebase", "assets", "domains", "iscsi", "isos", "liz", 
        "stroh", "sites", "mebula", "media/Games/saves/", "FamilyBackups"
    ],
    "SHARES_EXCLUDE": {
        "isos": ['--exclude', 'asset-mirror', '--exclude', '*-squash'],
        "iscsi": ['--exclude', '.fuse_hidden*']
    },
    
    "REMOTE_PULL_SOURCES": [
        "/mnt/remotes/DBACKUPS",
        "/mnt/remotes/KBACKUPS"
    ]
}

OS_TYPE = "linux"
DOCKER_CMD = "docker" if shutil.which("docker") else "true"
CREATED_ARCHIVES = []
LOCK_FD = None
CURRENT_ARCHIVE_FILE = None

# ==============================================================================
# 2. LOGGING & STATE ENGINE
# ==============================================================================

class JsonFormatter(logging.Formatter):
    def format(self, record):
        log_obj = {
            "timestamp": self.formatTime(record, self.datefmt),
            "level": record.levelname,
            "message": record.getMessage(),
            "module": record.module,
            "line": record.lineno
        }
        return json.dumps(log_obj)

os.makedirs(os.path.dirname(LOGFILE), exist_ok=True)
logger = logging.getLogger("AutoBackupper")
logger.setLevel(logging.INFO)

fh = RotatingFileHandler(LOGFILE, maxBytes=10*1024*1024, backupCount=5)
fh.setFormatter(JsonFormatter(datefmt="%Y-%m-%dT%H:%M:%SZ"))
logger.addHandler(fh)

ch = logging.StreamHandler(sys.stdout)
ch.setFormatter(logging.Formatter('%(asctime)s [%(levelname)s] %(message)s', datefmt="%Y-%m-%d %H:%M:%S"))
logger.addHandler(ch)

def init_state():
    os.makedirs(ENCLAVE_DIR, exist_ok=True)
    Path(STATE_FILE).touch(exist_ok=True)
    open(STATE_FILE, 'w').close()

def set_state(key, val):
    states = get_all_states()
    states[key] = str(val)
    with open(STATE_FILE, 'w') as f:
        for k, v in states.items():
            f.write(f"{k}={v}\n")

def get_state(key):
    return get_all_states().get(key, "")

def get_all_states():
    if not os.path.exists(STATE_FILE): return {}
    states = {}
    with open(STATE_FILE, 'r') as f:
        for line in f:
            if '=' in line:
                k, v = line.strip().split('=', 1)
                states[k] = v
    return states

# ==============================================================================
# 3. HELPER FUNCTIONS & SYSTEM ABSTRACTION
# ==============================================================================

def run_cmd(cmd, shell=False, check=False, cwd=None, capture_output=False, env=None, stdout=None):
    if CONFIG["DRY_RUN"] == "true":
        logger.info(f"[DRY RUN] Executing: {cmd}")
        return subprocess.CompletedProcess(args=cmd, returncode=0, stdout=b'', stderr=b'')
    
    try:
        if stdout is not None:
            return subprocess.run(cmd, shell=shell, check=check, cwd=cwd, stdout=stdout, env=env)
        return subprocess.run(
            cmd, shell=shell, check=check, cwd=cwd, 
            capture_output=capture_output, env=env, text=True
        )
    except subprocess.CalledProcessError as e:
        logger.error(f"Command failed with exit code {e.returncode}: {cmd}")
        raise

def parse_bash_config(filepath):
    if not os.path.exists(filepath): return
    with open(filepath, 'r') as f: content = f.read()
    
    for match in re.finditer(r'^([A-Za-z0-9_]+)=["\']?(.*?)["\']?$', content, re.MULTILINE):
        key, val = match.groups()
        if key in CONFIG and isinstance(CONFIG[key], str):
            CONFIG[key] = val
            
    for match in re.finditer(r'^([A-Za-z0-9_]+)=\((.*?)\)$', content, re.MULTILINE | re.DOTALL):
        key, val = match.groups()
        if key in CONFIG and isinstance(CONFIG[key], list):
            CONFIG[key] = shlex.split(val)

    if CONFIG.get("BACKUP_SQL") == "true":
        logger.warning("Deprecated config 'BACKUP_SQL' detected. Mapping to specific DB type.")
        if CONFIG.get("SQL_TYPE", "mysql") == "mysql": CONFIG["BACKUP_MYSQL"] = "true"
        elif CONFIG.get("SQL_TYPE") == "postgres": CONFIG["BACKUP_POSTGRES"] = "true"

def send_notify(level, title, message):
    logger.info(f"NOTIFY [{level}]: {title} - {message}")
    if CONFIG["DRY_RUN"] == "true": return

    try:
        if OS_TYPE == "unraid" and os.path.isfile("/usr/local/emhttp/webGui/scripts/notify"):
            run_cmd(["/usr/local/emhttp/webGui/scripts/notify", "-e", title, "-s", "Auto-Backupper", "-d", message, "-i", level])
        elif OS_TYPE == "omv" and shutil.which("omv-notify"):
            omv_lvl = "error" if level == "alert" else "warning" if level == "warning" else "info"
            run_cmd(["omv-notify", "-k", omv_lvl, "-t", title, "-m", message])
        elif shutil.which("notify-send"):
            run_cmd(["notify-send", "-u", level, title, message])
    except Exception as e:
        logger.error(f"Failed to send notification: {str(e)}")

def determine_os_and_docker():
    global OS_TYPE
    if os.path.isfile("/etc/unraid-version"):
        OS_TYPE = "unraid"
        if os.path.isfile(CONFIG["UNRAID_DOCKER_CFG"]):
            parse_bash_config(CONFIG["UNRAID_DOCKER_CFG"])
            if "DOCKER_IMAGE_FILE" in CONFIG: CONFIG["DOCKER_IMG_PATH"] = CONFIG["DOCKER_IMAGE_FILE"]
            if "DOCKER_IMAGE_SIZE" in CONFIG: CONFIG["DOCKER_IMG_SIZE"] = CONFIG["DOCKER_IMAGE_SIZE"]
    elif shutil.which("omv-notify"):
        OS_TYPE = "omv"

    if CONFIG["DOCKER_MODE"] == "auto":
        if OS_TYPE == "unraid": CONFIG["DOCKER_MODE"] = "unraid_service"
        elif DOCKER_CMD != "true": CONFIG["DOCKER_MODE"] = "container"
        else: CONFIG["DOCKER_MODE"] = "disabled"

def sys_docker_stop():
    mode = CONFIG["DOCKER_MODE"]
    if mode == "unraid_service":
        logger.info("ACTION: Stopping Unraid Docker Service...")
        run_cmd(["/etc/rc.d/rc.docker", "stop"])
        if CONFIG["DRY_RUN"] == "false" and os.path.ismount("/var/lib/docker"):
            run_cmd(["umount", "-l", "/var/lib/docker"], check=False)
        set_state("DOCKER_STOPPED", "true")
    elif mode == "container":
        logger.info("ACTION: Stopping running containers...")
        res = run_cmd([DOCKER_CMD, "ps", "--format", "{{.Names}}"], capture_output=True)
        if res.stdout:
            containers = [c for c in res.stdout.split('\n') if c]
            for c in containers:
                run_cmd([DOCKER_CMD, "stop", "-t", CONFIG["DOCKER_STOP_TIMEOUT"], c])
            with open(f"{ENCLAVE_DIR}/containers.list", "w") as f:
                f.write("\n".join(containers))
        set_state("DOCKER_STOPPED", "true")

def sys_docker_start():
    if get_state("DOCKER_STOPPED") != "true": return
    mode = CONFIG["DOCKER_MODE"]
    if mode == "unraid_service":
        logger.info("ACTION: Starting Unraid Docker Service...")
        img = CONFIG["DOCKER_IMG_PATH"]
        if CONFIG["DRY_RUN"] == "false" and os.path.isfile(img) and not os.path.ismount("/var/lib/docker"):
            os.makedirs("/var/lib/docker", exist_ok=True)
            if shutil.which("/usr/local/sbin/mount_image"):
                run_cmd(["/usr/local/sbin/mount_image", img, "/var/lib/docker", CONFIG["DOCKER_IMG_SIZE"]])
            else:
                run_cmd(["mount", "-o", "loop", img, "/var/lib/docker"])
        run_cmd(["/etc/rc.d/rc.docker", "start"])
        set_state("DOCKER_STOPPED", "false")
    elif mode == "container":
        logger.info("ACTION: Restarting containers...")
        list_file = f"{ENCLAVE_DIR}/containers.list"
        if os.path.isfile(list_file):
            with open(list_file, "r") as f:
                for c in f.read().splitlines():
                    if c: run_cmd([DOCKER_CMD, "start", c])
            os.remove(list_file)
        set_state("DOCKER_STOPPED", "false")

def get_tar_cmd():
    threads = CONFIG["CPU_THREADS"]
    if shutil.which("pigz"):
        flag = f"-p {threads}" if threads != "all" and threads.isdigit() else ""
        return f"pigz {flag} --best".strip()
    return "gzip"

def checksum_path(file_path, base_path):
    rel = os.path.relpath(file_path, base_path)
    return Path(base_path) / CHECKSUM_DIR / f"{rel}.sha256"

def create_archive(archive_path, base_dir, targets, exclusions=None):
    global CURRENT_ARCHIVE_FILE
    ensure_dir(os.path.dirname(archive_path))
    CURRENT_ARCHIVE_FILE = archive_path
    
    logger.info(f"Archiving: {archive_path}")
    cmd = ["tar", f"--use-compress-program={get_tar_cmd()}", "-cvf", archive_path, "-C", base_dir]
    if exclusions: cmd.extend(exclusions)
    cmd.extend(targets)
    
    try:
        run_cmd(cmd, check=True)
        if CONFIG["DRY_RUN"] == "false":
            chk_file = checksum_path(archive_path, CONFIG["BACKUP_BASE"])
            chk_file.parent.mkdir(parents=True, exist_ok=True)
            res = run_cmd(["sha256sum", archive_path], capture_output=True, check=True)
            with open(chk_file, 'w') as f:
                f.write(f"{res.stdout.split()[0]}\n")
        CREATED_ARCHIVES.append(archive_path)
    except subprocess.CalledProcessError:
        logger.error(f"Archive failed: {archive_path}")
        send_notify("alert", "Backup Failed", archive_path)
        if os.path.isfile(archive_path): os.remove(archive_path)
        raise
    finally:
        CURRENT_ARCHIVE_FILE = None

def safe_rsync(src, dest):
    opts = [
        "rsync", "--archive", "--compress", "--human-readable", "--omit-dir-times",
        "--update", f"--partial-dir=.abpartial", f"--include={CHECKSUM_DIR}", "--exclude=.abpartial"
    ]
    res = run_cmd(opts + [src, dest], check=False)
    if res.returncode in (0, 24):
        if res.returncode == 24: logger.warning(f"Partial transfer syncing {src}. Continuing.")
        return True
    logger.error(f"rsync failed with code {res.returncode} for {src}")
    return False

def verify_file(file_path, base_path):
    if not os.path.isfile(file_path): return False
    chk_file = checksum_path(file_path, base_path)
    if chk_file.is_file():
        with open(chk_file, 'r') as f: expected = f.read().strip()
        act_res = run_cmd(["sha256sum", file_path], capture_output=True, check=True)
        return expected == act_res.stdout.split()[0]
    return True

def ensure_dir(path):
    if CONFIG["DRY_RUN"] == "false": os.makedirs(path, exist_ok=True)

# ==============================================================================
# 4. WORKFLOWS
# ==============================================================================

def produce_flow():
    logger.info("=== Starting PRODUCE Flow ===")
    send_notify("normal", "Backup Started", "Mode: Produce")
    base = CONFIG["BACKUP_BASE"]

    # 1. DATABASE DUMPS
    if DOCKER_CMD != "true" and CONFIG["DRY_RUN"] == "false":
        db_path_base = f"{base}/services"
        
        # MySQL / MariaDB
        if CONFIG["BACKUP_MYSQL"] == "true" and CONFIG["MYSQL_CONTAINER_NAME"]:
            logger.info("Phase: MySQL Backup")
            mysql_path = f"{db_path_base}/mysql"
            ensure_dir(mysql_path)
            res = run_cmd([DOCKER_CMD, "ps", "-q", "-f", f"name=^/{CONFIG['MYSQL_CONTAINER_NAME']}$"], capture_output=True)
            if res.stdout.strip():
                dbs = CONFIG.get("MYSQL_DATABASES", [])
                if not dbs:
                    db_cmd = [DOCKER_CMD, "exec", CONFIG["MYSQL_CONTAINER_NAME"], "mysql", 
                              "-h", CONFIG["MYSQL_HOST"], "-u", CONFIG["MYSQL_USER"], 
                              f"-p{CONFIG['MYSQL_PASS']}", "-e", "show databases", "-s", "--skip-column-names"]
                    db_res = run_cmd(db_cmd, capture_output=True, check=False)
                    if db_res.returncode == 0:
                        exclude = {'information_schema', 'mysql', 'performance_schema', 'sys'}
                        dbs = [db for db in db_res.stdout.splitlines() if db and db not in exclude]
                
                for db in dbs:
                    logger.info(f"Dumping MySQL: {db}...")
                    with tempfile.TemporaryDirectory() as tmp_dir:
                        dump_file = f"{db}.sql"
                        full_dump_path = os.path.join(tmp_dir, dump_file)
                        final_archive = f"{mysql_path}/mysql_{db}_{CDATE}.tar.gz"
                        dump_cmd = [DOCKER_CMD, "exec", CONFIG["MYSQL_CONTAINER_NAME"], "mysqldump",
                                    "-h", CONFIG["MYSQL_HOST"], "-u", CONFIG["MYSQL_USER"], 
                                    f"-p{CONFIG['MYSQL_PASS']}", "--routines", "--triggers", "--databases", db]
                        with open(full_dump_path, "w") as out_f:
                            run_cmd(dump_cmd, stdout=out_f, check=True)
                        create_archive(final_archive, tmp_dir, [dump_file])
            else:
                logger.warning(f"MySQL Container {CONFIG['MYSQL_CONTAINER_NAME']} not running.")

        # PostgreSQL
        if CONFIG["BACKUP_POSTGRES"] == "true" and CONFIG["POSTGRES_CONTAINER_NAME"]:
            logger.info("Phase: PostgreSQL Backup")
            pg_path = f"{db_path_base}/postgres"
            ensure_dir(pg_path)
            res = run_cmd([DOCKER_CMD, "ps", "-q", "-f", f"name=^/{CONFIG['POSTGRES_CONTAINER_NAME']}$"], capture_output=True)
            if res.stdout.strip():
                dbs = CONFIG.get("POSTGRES_DATABASES", [])
                env = os.environ.copy()
                env["PGPASSWORD"] = CONFIG["POSTGRES_PASS"]
                if not dbs:
                    db_cmd = [DOCKER_CMD, "exec", "-e", "PGPASSWORD", CONFIG["POSTGRES_CONTAINER_NAME"], 
                              "psql", "-h", CONFIG["POSTGRES_HOST"], "-U", CONFIG["POSTGRES_USER"], 
                              "-t", "-c", "SELECT datname FROM pg_database WHERE datistemplate = false;"]
                    db_res = run_cmd(db_cmd, capture_output=True, check=False, env=env)
                    if db_res.returncode == 0:
                        dbs = [db.strip() for db in db_res.stdout.splitlines() if db.strip()]

                for db in dbs:
                    logger.info(f"Dumping Postgres: {db}...")
                    with tempfile.TemporaryDirectory() as tmp_dir:
                        dump_file = f"{db}.sql"
                        full_dump_path = os.path.join(tmp_dir, dump_file)
                        final_archive = f"{pg_path}/postgres_{db}_{CDATE}.tar.gz"
                        dump_cmd = [DOCKER_CMD, "exec", "-e", "PGPASSWORD", CONFIG["POSTGRES_CONTAINER_NAME"],
                                    "pg_dump", "-h", CONFIG["POSTGRES_HOST"], "-U", CONFIG["POSTGRES_USER"], "-d", db]
                        with open(full_dump_path, "w") as out_f:
                            run_cmd(dump_cmd, stdout=out_f, check=True, env=env)
                        create_archive(final_archive, tmp_dir, [dump_file])
            else:
                logger.warning(f"Postgres Container {CONFIG['POSTGRES_CONTAINER_NAME']} not running.")

        # Mongo
        if CONFIG.get("BACKUP_MONGO") == "true" and CONFIG.get("MONGO_CONTAINER_NAME"):
            logger.info("Phase: Mongo Backup")
            mongo_path = f"{db_path_base}/mongo"
            ensure_dir(mongo_path)
            res = run_cmd([DOCKER_CMD, "ps", "-q", "-f", f"name=^/{CONFIG['MONGO_CONTAINER_NAME']}$"], capture_output=True)
            if res.stdout.strip():
                mdbs = CONFIG.get("MONGO_DATABASES", []) or ["ALL"]
                for mdb in mdbs:
                    with tempfile.TemporaryDirectory() as tmp_dir:
                        dump_file = f"{mdb}.archive.gz"
                        full_dump_path = os.path.join(tmp_dir, dump_file)
                        final_archive = f"{mongo_path}/mongo_{mdb}_{CDATE}.tar.gz"
                        cmd_args = [DOCKER_CMD, "exec", CONFIG["MONGO_CONTAINER_NAME"], "mongodump", 
                                    "--username", CONFIG["MONGO_USER"], "--password", CONFIG["MONGO_PASS"], 
                                    "--authenticationDatabase", CONFIG["MONGO_AUTH_DB"], "--archive", "--gzip"]
                        if mdb != "ALL": cmd_args.extend(["--db", mdb])
                        with open(full_dump_path, "w") as out_f:
                            run_cmd(cmd_args, stdout=out_f, check=True)
                        create_archive(final_archive, tmp_dir, [dump_file])
            else:
                logger.warning(f"Mongo Container {CONFIG['MONGO_CONTAINER_NAME']} not running.")

        # Redis
        if CONFIG.get("BACKUP_REDIS") == "true" and CONFIG.get("REDIS_CONTAINER_NAME"):
            logger.info("Phase: Redis Backup")
            redis_path = f"{db_path_base}/redis"
            ensure_dir(redis_path)
            res = run_cmd([DOCKER_CMD, "ps", "-q", "-f", f"name=^/{CONFIG['REDIS_CONTAINER_NAME']}$"], capture_output=True)
            if res.stdout.strip():
                with tempfile.TemporaryDirectory() as tmp_dir:
                    dump_file = "dump.rdb"
                    final_archive = f"{redis_path}/redis_{CDATE}.tar.gz"
                    cmd_args = [DOCKER_CMD, "exec", CONFIG["REDIS_CONTAINER_NAME"], "redis-cli"]
                    if CONFIG.get("REDIS_PASS"): cmd_args.extend(["-a", CONFIG["REDIS_PASS"]])
                    cmd_args.extend(["--rdb", "-"])
                    with open(os.path.join(tmp_dir, dump_file), "w") as out_f:
                        run_cmd(cmd_args, stdout=out_f, check=True)
                    create_archive(final_archive, tmp_dir, [dump_file])
            else:
                logger.warning(f"Redis Container {CONFIG['REDIS_CONTAINER_NAME']} not running.")

    # 2. SYSTEM BACKUP
    need_docker_stop = (CONFIG["DOCKER_MODE"] != "disabled") and (CONFIG["BACKUP_SYSTEM"] == "true")
    if need_docker_stop: sys_docker_stop()

    if CONFIG["BACKUP_SYSTEM"] == "true":
        logger.info("Phase: System Backup")
        targets = []
        if os.path.isdir(CONFIG["SYSTEM_APPDATA_PATH"]): targets.append(CONFIG["SYSTEM_APPDATA_PATH"])
        if os.path.isdir(CONFIG["SYSTEM_BOOT_PATH"]): targets.append(CONFIG["SYSTEM_BOOT_PATH"])
        if CONFIG["DOCKER_MODE"] == "unraid_service" and CONFIG["BACKUP_DOCKER_IMG"] == "true":
            targets.append(CONFIG["DOCKER_IMG_PATH"])
        
        if targets:
            sys_path = f"{base}/systems/{HOSTNAME_VAR}/{HOSTNAME_VAR}_{CDATE}.tar.gz"
            create_archive(sys_path, "/", targets)

    if need_docker_stop: sys_docker_start()

    # 3. SHARES BACKUP (Hot)
    if CONFIG["BACKUP_SHARES"] == "true":
        logger.info("Phase: Shares Backup")
        share_base = CONFIG["SHARES_BASE_FOLDER"]
        
        for share in CONFIG["SHARES_TO_BACKUP"]:
            src = f"{share_base}/{share}"
            if not os.path.isdir(src): continue
            
            if share in ["domains", "iscsi"]:
                logger.info(f"Phase: Granular Backup for '{share}'")
                for item in os.listdir(src):
                    sub_path = os.path.join(src, item)
                    if os.path.isdir(sub_path):
                        dest_dir = f"{base}/shares/{share}/{item}"
                        archive_name = f"{item}_{CDATE}.tar.gz"
                        ex_arr = CONFIG["SHARES_EXCLUDE"].get(share, [])
                        create_archive(f"{dest_dir}/{archive_name}", src, [item], exclusions=ex_arr)
                continue
                
            if share == "FamilyBackups":
                logger.info("Phase: Granular Backup for 'FamilyBackups'")
                for m_name in os.listdir(src):
                    m_path = os.path.join(src, m_name)
                    if os.path.isdir(m_path):
                        for sub in ["users", "systems"]:
                            sub_full_path = os.path.join(m_path, sub)
                            if os.path.isdir(sub_full_path):
                                archive_dest = f"{base}/shares/FamilyBackups/{m_name}/{sub}/{m_name}_{sub}_{CDATE}.tar.gz"
                                create_archive(archive_dest, sub_full_path, ["."])
                continue

            ex_arr = CONFIG["SHARES_EXCLUDE"].get(share, [])
            clean_name = os.path.basename(share)
            dest = f"{base}/shares/{share}/{clean_name}_{CDATE}.tar.gz"
            create_archive(dest, share_base, [share], exclusions=ex_arr)

    # 4. VERIFICATION
    if CONFIG["VERIFY_LOCAL_BACKUPS"] == "true" and CREATED_ARCHIVES:
        threads = int(CONFIG["CPU_THREADS"]) if CONFIG["CPU_THREADS"].isdigit() else os.cpu_count() or 1
        logger.info(f"Phase: Local Verification (Threads: {threads})")
        
        failed_verifications = []
        with ThreadPoolExecutor(max_workers=threads) as executor:
            future_to_archive = {executor.submit(verify_file, arch, base): arch for arch in CREATED_ARCHIVES}
            for future in as_completed(future_to_archive):
                arch = future_to_archive[future]
                if not future.result(): failed_verifications.append(arch)
        
        if failed_verifications:
            for f in failed_verifications:
                logger.error(f"Verification failed for: {f}")
                send_notify("alert", "Verify Failed", f)
        else:
            logger.info("Verification Successful (No Exceptions)")

    # 5. ROTATION
    if int(CONFIG["ROTATE_DAYS"]) > 0:
        logger.info(f"Phase: Rotation (> {CONFIG['ROTATE_DAYS']} days)")
        if CONFIG["DRY_RUN"] == "false":
            cutoff = time.time() - (int(CONFIG["ROTATE_DAYS"]) * 86400)
            for root, dirs, files in os.walk(base):
                if CHECKSUM_DIR in root: continue
                for f in files:
                    filepath = os.path.join(root, f)
                    if os.path.getmtime(filepath) < cutoff:
                        os.remove(filepath)
                        logger.info(f"Rotated old backup: {filepath}")

    send_notify("normal", "Backup Complete", "Local produce finished.")

def pull_flow():
    logger.info("=== Starting PULL Flow ===")
    if not CONFIG["REMOTE_PULL_SOURCES"]: return
    
    base = CONFIG["BACKUP_BASE"]
    ensure_dir(base)
    threads = int(CONFIG["CPU_THREADS"]) if CONFIG["CPU_THREADS"].isdigit() else os.cpu_count() or 1

    for remote in CONFIG["REMOTE_PULL_SOURCES"]:
        if not os.path.isdir(remote): continue
        logger.info(f"Syncing from detected source: {remote}")
        
        folders_to_sync = []
        folders = [f for f in os.listdir(remote) if os.path.isdir(os.path.join(remote, f)) and not f.startswith('.')]
        for folder in folders:
            if folder in ('sys', 'dev', 'run', 'proc', 'tmp'): continue
            src_path = f"{remote}/{folder}/"
            dest_path = f"{base}/{folder}/"
            ensure_dir(dest_path)
            safe_rsync(src_path, dest_path)
            folders_to_sync.append(folder)
            
        chk_src = f"{remote}/{CHECKSUM_DIR}/"
        if os.path.isdir(chk_src): safe_rsync(chk_src, f"{base}/{CHECKSUM_DIR}/")

        if CONFIG["VERIFY_PULLED_BACKUPS"] == "true" and folders_to_sync:
            logger.info(f"Verifying Pull (Threads: {threads})...")
            verify_paths = []
            for folder in folders_to_sync:
                folder_path = os.path.join(remote, folder)
                for root, _, files in os.walk(folder_path):
                    for file in files:
                        full_rem_path = os.path.join(root, file)
                        rel_path = os.path.relpath(full_rem_path, remote)
                        verify_paths.append(rel_path)

            failed_pulls = []
            with ThreadPoolExecutor(max_workers=threads) as executor:
                future_to_rel = {executor.submit(verify_file, os.path.join(base, rel), base): rel for rel in verify_paths}
                for future in as_completed(future_to_rel):
                    rel = future_to_rel[future]
                    if not future.result(): failed_pulls.append(rel)

            if failed_pulls:
                for rel in failed_pulls:
                    loc_f = os.path.join(base, rel)
                    rem_f = os.path.join(remote, rel)
                    logger.warning(f"Corruption detected: {loc_f}. Re-pulling...")
                    if not safe_rsync(rem_f, loc_f): logger.error(f"ERROR: Failed to re-pull {rem_f}")
            else:
                logger.info("Pull Verification Successful.")

    send_notify("normal", "Pull Complete", "Remote sync finished.")

# ==============================================================================
# 5. LIFECYCLE & MAIN
# ==============================================================================

def cleanup():
    if CURRENT_ARCHIVE_FILE and os.path.isfile(CURRENT_ARCHIVE_FILE): os.remove(CURRENT_ARCHIVE_FILE)
    if get_state("DOCKER_STOPPED") == "true": sys_docker_start()
    init_state() 
    if LOCK_FD:
        fcntl.flock(LOCK_FD, fcntl.LOCK_UN)
        LOCK_FD.close()

def signal_handler(sig, frame):
    logger.warning("Interrupt detected. Stopping...")
    sys.exit(130)

def main():
    global LOCK_FD
    if os.geteuid() != 0:
        print("CRITICAL: This script must be run as root.", file=sys.stderr)
        sys.exit(1)

    parser = argparse.ArgumentParser(description="Auto-Backupper Enterprise")
    parser.add_argument("-c", "--config", help="Path to config file")
    parser.add_argument("-m", "--mode", choices=["produce", "pull", "both"])
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--no-docker", action="store_true")
    parser.add_argument("--skip-preflight", action="store_true")
    args = parser.parse_args()

    parse_bash_config(args.config or "/boot/config/auto_backupper.cfg")
    if args.mode: CONFIG["MODE"] = args.mode
    if args.dry_run: CONFIG["DRY_RUN"] = "true"
    if args.no_docker: CONFIG["DOCKER_MODE"] = "disabled"
    if args.skip_preflight: CONFIG["SKIP_PREFLIGHT"] = "true"

    determine_os_and_docker()

    try:
        LOCK_FD = open(LOCKFILE, 'w')
        fcntl.flock(LOCK_FD, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except IOError:
        print(f"{datetime.now()} - Instance already running. Exiting.")
        sys.exit(0)

    atexit.register(cleanup)
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    init_state()
    if CONFIG["SKIP_PREFLIGHT"] != "true":
        logger.info("--- PRE-FLIGHT CHECKS ---")
        errors = [f"Missing binary: {b}" for b in ["rsync", "tar", "sha256sum"] if not shutil.which(b)]
        if not os.access(ENCLAVE_DIR, os.W_OK) and CONFIG["DRY_RUN"] != "true": errors.append(f"Enclave {ENCLAVE_DIR} not writable")
        if errors:
            logger.critical(f"Pre-flight checks failed: {' | '.join(errors)}")
            sys.exit(1)

    logger.info(f"Startup [OS:{OS_TYPE} | Mode:{CONFIG['MODE']} | Docker:{CONFIG['DOCKER_MODE']}]")
    
    if CONFIG["MODE"] in ["produce", "both"]: produce_flow()
    if CONFIG["MODE"] in ["pull", "both"]: pull_flow()
    
    logger.info("Job Finished.")

if __name__ == "__main__":
    main()