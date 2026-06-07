#!/usr/bin/env python3
"""
WARPHOLE (Enclave Edition) — Python port
==============================================================================
Combines Teleporter Backup, Health Monitor, and PADD-based Stats for Pi-hole.

A faithful port of warphole.sh. Kept as a SEPARATE script from the bash
implementation (which remains the primary one on the repo's `bash` branch).
Where bash shells out to coreutils, this port prefers native Python
(hashlib for sha256, zipfile for integrity, /proc for memory, requests for
the API) but mirrors the bash behavior, safety checks, and log conventions.

USAGE:
    sudo python3 warphole.py [OPTIONS]

Primary modes:
    --backup-now    Run Pi-hole Teleporter backup and offload to destination
    --check         Run health check (gravity + optional Tailscale)
    --stats         Launch terminal dashboard
    --help, -h      Show this help

Advanced:
    --mount-only    Mount SMB share only (holds the mount; skips unmount on exit)
    --unmount-only  Unmount SMB share only
    --keep-local    Keep temp staging files (debug)

CONFIGURATION:
    Defaults live in CONFIG below. Override (and supply credentials) via an
    external secrets file — /etc/warphole/secrets.env by default, or
    $WARPHOLE_SECRETS_FILE — a plain `KEY="value"` fragment, mode 600.

DEPENDENCIES:
    Python 3.6+, packages: requests (check/stats), rich (stats).
    Binaries: docker (if IS_DOCKER) or pihole-FTL/pihole (bare metal);
    mount.cifs + findmnt (if SMB); ping (if CHECK_TAILSCALE).
"""

import os
import sys
import re
import glob
import time
import shutil
import socket
import hashlib
import zipfile
import tempfile
import datetime
import subprocess

# ==============================================================================
# 1. CONFIGURATION
# ==============================================================================
# `socket.gethostname()` short form, normalised to UPPERCASE — see
# warphole.sh's matching block for the full rationale. Short version: warphole
# writes `${HOSTNAME_VAR}_pihole_${CDATE}.zip` into the central NAS; without a
# canonical case, drifting host casing produces duplicate `<HOST>_pihole_*` and
# `<host>_pihole_*` siblings that auto-backupper's pull-side retention can't
# reconcile. Config (secrets.env) can override with HOSTNAME_VAR="my-host".
_DEFAULT_HOSTNAME = socket.gethostname().split(".")[0].upper()

CONFIG = {
    # --- Identity ---
    "HOSTNAME_VAR": _DEFAULT_HOSTNAME,
    # --- Default Behavior --- "check" | "backup" | "stats" | "" (require flags)
    "DEFAULT_MODE": "",
    "LOGFILE": "/var/log/warphole.log",
    "REPAIR_MARKER": "/etc/pihole/gravity_repair_pending",
    # --- Log Rotation & Verbosity ---
    "LOG_MAX_SIZE": 10 * 1024 * 1024,  # 10 MB
    "LOG_BACKUPS": 5,
    "LOG_VERBOSITY": "info",  # error | phase | info | debug
    # --- Docker ---
    "IS_DOCKER": True,
    "DOCKER_CONTAINER_NAME": "pihole-v6-unbound",
    # --- Backup ---
    "DESTINATION_TYPE": "local",  # "smb" or "local"
    "SMB_HOST": "127.0.0.1",
    "SMB_SHARE": "backup",
    "SMB_SUBFOLDER": f"services/pihole/{_DEFAULT_HOSTNAME}",
    # WC5: credentials MUST come from secrets.env. Empty placeholders here so a
    # fresh clone has no working default password sitting in the script body.
    "SMB_USER": "",
    "SMB_PASS": "",
    "MOUNT_POINT": "/mnt/backups",
    # LOCAL_EXPORT_PATH derived AFTER secrets are loaded (see load_secrets()).
    "LOCAL_EXPORT_PATH": "",
    # WS4: retention; 0 = keep forever.
    "WARPHOLE_KEEP_DAYS": 90,
    # --- Tailscale ---
    "CHECK_TAILSCALE": False,
    "TAILSCALE_PING_IP": "100.x.y.z",
    # --- API ---
    "PI_URL": "http://127.0.0.1/api",
    "PI_PASSWORD": "",
    "REFRESH_RATE": 2,
    # --- Debug --- env override honored at startup
    "DEBUG_MODE": os.environ.get("WARPHOLE_DEBUG", "false").lower() == "true",
    # --- Internal Paths ---
    "TEMP_DIR": "/tmp/pihole_backup_staging",
    "GRAVITY_LOG": "/tmp/gravity_update.log",
    "GRAVITY_PIDFILE": "/tmp/warphole_gravity.pid",
    "LOCKFILE": "/var/lock/warphole.lock",
}

CDATE = datetime.datetime.now().strftime("%Y%m%d")

# --- Runtime state (do not edit) ---
state = {
    "sid": "",
    "keep_local": False,
    "manage_mount": True,
    "mode": "",
    "lock_fd": None,
    "log_to_file": True,  # WM1: disabled for stats mode
}

# ==============================================================================
# 2. SECRETS LOADING
# ==============================================================================


def _coerce(key, raw):
    """Coerce a string value from secrets.env to the type of CONFIG[key]."""
    default = CONFIG.get(key)
    if isinstance(default, bool):
        return str(raw).strip().lower() == "true"
    if isinstance(default, int):
        try:
            return int(str(raw).strip())
        except ValueError:
            return default
    return raw


def _parse_value(raw):
    """Extract a bash-fragment RHS value, preserving '#' inside quotes."""
    raw = raw.strip()
    if raw and raw[0] in ("'", '"'):
        q = raw[0]
        end = raw.find(q, 1)
        if end != -1:
            return raw[1:end]
        return raw[1:]
    # Unquoted: strip a trailing ` # ...` inline comment, keep a bare '#'.
    return raw.split(" #", 1)[0].strip()


def load_secrets():
    """WC5: source an external mode-600 secrets fragment. Any KEY=value here
    overrides the defaults above. Warn (not fatal) on permission/owner drift."""
    path = os.environ.get("WARPHOLE_SECRETS_FILE", "/etc/warphole/secrets.env")
    if os.path.isfile(path):
        try:
            st = os.stat(path)
            perms = oct(st.st_mode & 0o777)[2:]
            if perms not in ("600", "400"):
                print(
                    f"WARN: {path} has permissions {perms}; recommend: chmod 600 {path}",
                    file=sys.stderr,
                )
            import pwd

            owner = pwd.getpwuid(st.st_uid).pw_name
            if owner != "root":
                print(f"WARN: {path} is owned by {owner}, not root.", file=sys.stderr)
        except Exception:
            pass

        try:
            with open(path, "r") as f:
                for line in f:
                    line = line.strip()
                    if not line or line.startswith("#") or "=" not in line:
                        continue
                    if line.startswith("export "):
                        line = line[len("export "):]
                    key, raw = line.split("=", 1)
                    key = key.strip()
                    if key in CONFIG:
                        CONFIG[key] = _coerce(key, _parse_value(raw))
        except OSError as e:
            print(f"WARN: could not read {path}: {e}", file=sys.stderr)

    # Derive LOCAL_EXPORT_PATH from the final (possibly-overridden) values.
    # Preserve an explicit LOCAL_EXPORT_PATH override from secrets.env.
    if not CONFIG.get("LOCAL_EXPORT_PATH"):
        CONFIG["LOCAL_EXPORT_PATH"] = (
            f"/mnt/user/{CONFIG['SMB_SHARE']}/{CONFIG['SMB_SUBFOLDER']}"
        )


# ==============================================================================
# 3. LOGGING
# ==============================================================================


def _log_verbosity_threshold():
    return {"error": 2, "phase": 3, "info": 4, "debug": 99}.get(
        CONFIG.get("LOG_VERBOSITY", "info"), 4
    )


def _log_level_for(msg):
    # error/warn tier
    if re.match(r"^(FATAL|CRITICAL|ERROR:|ERROR |WARN:|WARN |WARNING:|Auth Failed:)", msg):
        return 2
    # phase/action tier
    if re.match(
        r"^(===|ACTION:|Action:|RECOVERY:|SUCCESS:|VERIFIED:|HEALTHY:|Phase:|Rotation:|Cleanup:)",
        msg,
    ):
        return 3
    if msg.startswith("DEBUG:"):
        return 99
    return 4


def rotate_logs(logfile, max_size, backups):
    """Copytruncate rotation — matches the rest of the suite. Copy then
    truncate (not move) because callers may hold the file open."""
    if not os.path.isfile(logfile):
        return
    try:
        if os.path.getsize(logfile) < max_size:
            return
    except OSError:
        return

    last = f"{logfile}.{backups}"
    if os.path.isfile(last):
        try:
            os.remove(last)
        except OSError:
            pass
    for i in range(backups - 1, 0, -1):
        src, dst = f"{logfile}.{i}", f"{logfile}.{i + 1}"
        if os.path.isfile(src):
            try:
                os.replace(src, dst)
            except OSError:
                pass
    try:
        shutil.copy2(logfile, f"{logfile}.1")
        open(logfile, "w").close()
        # WD7: keep live + rotated copies root-only (auth response can be logged).
        os.chmod(logfile, 0o600)
        os.chmod(f"{logfile}.1", 0o600)
    except OSError:
        pass


def rotate_log_if_needed():
    rotate_logs(
        CONFIG["LOGFILE"], CONFIG.get("LOG_MAX_SIZE", 10485760), CONFIG.get("LOG_BACKUPS", 5)
    )


def log(msg):
    lvl = _log_level_for(msg)
    if lvl <= _log_verbosity_threshold():
        line = f"{datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')} {msg}"
        print(line, flush=True)
        if state["log_to_file"]:
            try:
                with open(CONFIG["LOGFILE"], "a") as f:
                    f.write(line + "\n")
            except OSError:
                pass
    rotate_log_if_needed()


def dlog(msg):
    """Debug-only logger; visible only at LOG_VERBOSITY=debug with DEBUG_MODE."""
    if CONFIG.get("DEBUG_MODE"):
        log("DEBUG: " + msg)


def setup_logging():
    try:
        open(CONFIG["LOGFILE"], "a").close()
        os.chmod(CONFIG["LOGFILE"], 0o600)  # WS14: root-only
    except OSError:
        pass


# ==============================================================================
# 4. LOCKING / GRAVITY / DEPS / API
# ==============================================================================


def acquire_lock():
    """WC1: exclusive flock for mutating modes. Skip for stats (read-only)."""
    import fcntl

    try:
        fd = open(CONFIG["LOCKFILE"], "w")
    except OSError:
        print(f"FATAL: Cannot open lockfile {CONFIG['LOCKFILE']}")
        sys.exit(1)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print("Another warphole instance is running (lockfile held). Exiting.")
        sys.exit(0)
    state["lock_fd"] = fd  # keep FD alive for process lifetime


def is_gravity_running():
    """WS3: pidfile-based detection (avoids pgrep -f false positives)."""
    pidfile = CONFIG["GRAVITY_PIDFILE"]
    if not os.path.isfile(pidfile):
        return False
    try:
        with open(pidfile) as f:
            pid = int(f.read().strip())
    except (OSError, ValueError):
        pid = 0
    if pid > 0:
        try:
            os.kill(pid, 0)
            return True
        except OSError:
            pass
    # Stale pidfile from a crashed prior run — clean up.
    try:
        os.remove(pidfile)
    except OSError:
        pass
    return False


def check_deps(need_rich):
    """WS8/WM8: only require what the current config/mode actually needs."""
    missing_pkgs = []
    try:
        import requests  # noqa: F401
    except ImportError:
        missing_pkgs.append("requests")
    if need_rich:
        try:
            import rich  # noqa: F401
        except ImportError:
            missing_pkgs.append("rich")

    if missing_pkgs:
        print(f"MISSING PYTHON DEPENDENCIES: {', '.join(missing_pkgs)}")
        try:
            choice = input("Install them now via pip? (y/n): ").strip().lower()
        except EOFError:
            choice = "n"
        if choice == "y":
            subprocess.check_call([sys.executable, "-m", "pip", "install", *missing_pkgs])
            print("Dependencies installed. Please re-run the script.")
            sys.exit(0)
        print("FATAL: Cannot continue without dependencies.")
        sys.exit(1)

    bins = []
    if CONFIG["IS_DOCKER"]:
        bins.append("docker")
    else:
        # WD6: bare metal uses pihole-FTL (backup) and pihole (check).
        bins += ["pihole-FTL", "pihole"]
    if CONFIG["DESTINATION_TYPE"] == "smb":
        bins += ["mount.cifs", "findmnt"]
    if CONFIG["CHECK_TAILSCALE"]:
        bins.append("ping")  # WD8: systemctl is a SOFT dep (guarded)
    for b in bins:
        if not shutil.which(b):
            print(f"FATAL: Dependency '{b}' is missing. Please install it.")
            sys.exit(1)


def authenticate():
    """WD2: tolerate API/network failures — empty SID, continue (stats/check
    degrade gracefully). Only fatal in non-stats mode on a real auth rejection."""
    import requests

    dlog("authenticate entered")
    if not CONFIG["PI_PASSWORD"]:
        dlog("PI_PASSWORD empty, skipping auth")
        return

    try:
        r = requests.post(
            f"{CONFIG['PI_URL']}/auth",
            json={"password": CONFIG["PI_PASSWORD"]},
            timeout=10,
        )
        data = r.json()
    except Exception as e:
        log(f"WARN: auth request failed ({e}). Continuing without SID.")
        return

    state["sid"] = (data.get("session") or {}).get("sid") or ""
    if not state["sid"]:
        msg = (data.get("session") or {}).get("message", "") or ""
        if "no password set" not in msg:
            if state["mode"] != "stats":
                log(f"Auth Failed: {msg}")
                sys.exit(1)


def api_get_padd(timeout=10):
    """GET /padd. Returns parsed JSON dict, or None on network/parse failure."""
    import requests

    headers = {"X-FTL-SID": state["sid"]} if state["sid"] else {}
    try:
        r = requests.get(f"{CONFIG['PI_URL']}/padd", headers=headers, timeout=timeout)
        return r.json()
    except Exception:
        return None


# ==============================================================================
# 5. SMB MOUNT
# ==============================================================================


def _safe_remove(path):
    try:
        os.remove(path)
    except OSError:
        pass


def mount_smb():
    # WC5: fail fast on missing credentials with an actionable message.
    if not CONFIG["SMB_USER"] or not CONFIG["SMB_PASS"]:
        secrets = os.environ.get("WARPHOLE_SECRETS_FILE", "/etc/warphole/secrets.env")
        log("FATAL: SMB_USER or SMB_PASS is empty.")
        log(f"       Set them in {secrets} (recommended, mode 600)")
        log("       or directly in the script body if you understand the tradeoff.")
        sys.exit(1)

    mp = CONFIG["MOUNT_POINT"]
    expected = f"//{CONFIG['SMB_HOST']}/{CONFIG['SMB_SHARE']}"

    if os.path.ismount(mp):
        log(f"INFO: Mount point {mp} is already active.")
        # WM9: verify it's mounted from the expected source.
        try:
            current = subprocess.check_output(
                ["findmnt", "-n", "-o", "SOURCE", mp], text=True
            ).strip()
        except Exception:
            current = ""
        if current and current != expected:
            log(f"FATAL: {mp} is mounted, but from '{current}' (expected '{expected}').")
            log("       Refusing to write backup to an unrelated mount. Unmount it first.")
            sys.exit(1)
        return

    os.makedirs(mp, exist_ok=True)
    log(f"ACTION: Mounting {expected}...")

    # WC3: pass credentials via a mode-0600 temp file, not -o options (which
    # would expose the password in `ps`). Shred/remove immediately after.
    fd, creds = tempfile.mkstemp(prefix="warphole_creds.")
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(f"username={CONFIG['SMB_USER']}\npassword={CONFIG['SMB_PASS']}\n")
    except OSError:
        log("FATAL: Could not create temporary credentials file.")
        _safe_remove(creds)
        sys.exit(1)

    rc = subprocess.run(
        ["mount", "-t", "cifs", expected, mp,
         "-o", f"credentials={creds},vers=3.0,iocharset=utf8"],
        capture_output=True, text=True,
    )

    # Scrub the credentials file regardless of mount result.
    if shutil.which("shred"):
        if subprocess.run(["shred", "-u", creds], capture_output=True).returncode != 0:
            _safe_remove(creds)
    else:
        _safe_remove(creds)

    if rc.returncode == 0:
        log("SUCCESS: Share mounted.")
    else:
        # Do NOT log rc.stderr at info level: mount.cifs error text can echo the
        # temporary credentials file path. Match bash (exit code only); surface
        # stderr under DEBUG_MODE for diagnosis.
        log(f"FATAL: Failed to mount SMB share (exit code {rc.returncode}).")
        dlog(f"mount.cifs stderr: {rc.stderr.strip()}")
        sys.exit(1)


# ==============================================================================
# 6. GRAVITY / CONTAINER HELPERS
# ==============================================================================


def run_gravity_rebuild(label):
    """WS16: route the firehose of `pihole -g` output to GRAVITY_LOG instead of
    the script's stdout (which can OOM/SIGPIPE on low-memory hosts). Returns rc."""
    glog = CONFIG["GRAVITY_LOG"]
    if CONFIG["IS_DOCKER"]:
        cmd = ["docker", "exec", CONFIG["DOCKER_CONTAINER_NAME"], "pihole", "-g"]
    else:
        cmd = ["pihole", "-g"]
    rc = 0
    try:
        with open(glog, "w") as out:
            rc = subprocess.run(cmd, stdout=out, stderr=subprocess.STDOUT).returncode
    except Exception as e:
        log(f"ERROR: failed to launch gravity rebuild: {e}")
        rc = 1
    log(f"Phase: {label} — pihole -g exited rc={rc} (tail of {glog}):")
    try:
        with open(glog) as f:
            for line in f.readlines()[-3:]:
                print("    " + line.rstrip())
    except OSError:
        pass
    return rc


def ensure_pihole_running():
    """WS7: confirm the container is Running before docker exec / API use."""
    if not CONFIG["IS_DOCKER"]:
        return True
    if not shutil.which("docker"):
        log("FATAL: Docker command not found.")
        return False
    try:
        state_str = subprocess.check_output(
            ["docker", "inspect", "--format", "{{.State.Running}}",
             CONFIG["DOCKER_CONTAINER_NAME"]],
            text=True, stderr=subprocess.DEVNULL,
        ).strip()
    except subprocess.CalledProcessError:
        state_str = "missing"
    if state_str != "true":
        log(f"FATAL: Container '{CONFIG['DOCKER_CONTAINER_NAME']}' is not running (state: {state_str}).")
        log(f"       Start it with: docker start {CONFIG['DOCKER_CONTAINER_NAME']}")
        return False
    return True


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def zip_integrity_ok(path):
    """WM11: native equivalent of `unzip -t`."""
    try:
        with zipfile.ZipFile(path) as z:
            return z.testzip() is None
    except Exception:
        return False


# ==============================================================================
# 7. BACKUP
# ==============================================================================


def run_backup():
    log(f"=== Starting Pi-hole Backup (Docker: {CONFIG['IS_DOCKER']} | Dest: {CONFIG['DESTINATION_TYPE']}) ===")

    # --- 1. Prepare destination ---
    if CONFIG["DESTINATION_TYPE"] == "smb":
        mount_smb()
        final_dest = f"{CONFIG['MOUNT_POINT']}/{CONFIG['SMB_SUBFOLDER']}"
    else:
        final_dest = CONFIG["LOCAL_EXPORT_PATH"]
        state["manage_mount"] = False
    final_dest = final_dest.rstrip("/")  # WM10

    if not os.path.isdir(final_dest):
        try:
            os.makedirs(final_dest, exist_ok=True)
        except OSError:
            log(f"FATAL: Cannot create dest dir {final_dest}")
            sys.exit(1)
    if not os.access(final_dest, os.W_OK):
        log(f"FATAL: Destination {final_dest} is not writable.")
        sys.exit(1)

    # --- 2. Generate backup ---
    os.makedirs(CONFIG["TEMP_DIR"], exist_ok=True)
    log("Phase: Generating Teleporter Archive...")

    if CONFIG["IS_DOCKER"]:
        if not ensure_pihole_running():
            sys.exit(1)
        name = CONFIG["DOCKER_CONTAINER_NAME"]
        log(f"Action: Running pihole-FTL inside container '{name}'...")

        # WS11/WS15: capture the generated filename from pihole-FTL stdout,
        # isolating the teleporter zip line (FTL v6 prints config noise first).
        raw = subprocess.run(
            ["docker", "exec", "-w", "/tmp", name, "pihole-FTL", "--teleporter"],
            capture_output=True, text=True, stderr=subprocess.DEVNULL,
        ).stdout
        matches = re.findall(r"\S+_teleporter_\S+\.zip", raw)
        if not matches:
            matches = re.findall(r"\S+\.zip", raw)
        docker_file = matches[-1].strip() if matches else ""

        if not docker_file:
            log("FATAL: pihole-FTL --teleporter produced no filename (container may be unhealthy).")
            sys.exit(1)
        if not docker_file.startswith("/"):
            docker_file = "/tmp/" + docker_file

        # Confirm the file actually exists inside the container.
        if subprocess.run(["docker", "exec", name, "test", "-f", docker_file]).returncode != 0:
            log(f"FATAL: Teleporter reported '{docker_file}' but that path does not exist in the container.")
            sys.exit(1)

        log(f"Action: Copying {docker_file} from container to host...")
        # WS12: clean up the container-side zip even if docker cp fails.
        if subprocess.run(["docker", "cp", f"{name}:{docker_file}", CONFIG["TEMP_DIR"] + "/"]).returncode != 0:
            log("ERROR: docker cp failed — cleaning up container-side zip before exit")
            subprocess.run(["docker", "exec", name, "rm", "-f", docker_file],
                           stderr=subprocess.DEVNULL)
            sys.exit(1)
        subprocess.run(["docker", "exec", name, "rm", "-f", docker_file], stderr=subprocess.DEVNULL)
    else:
        # WD5: guard FTL failure so it logs FATAL instead of a silent abort.
        err_path = os.path.join(CONFIG["TEMP_DIR"], ".ftl_err")
        try:
            with open(err_path, "w") as err:
                ftl_rc = subprocess.run(
                    ["pihole-FTL", "--teleporter"], cwd=CONFIG["TEMP_DIR"],
                    stdout=subprocess.DEVNULL, stderr=err,
                ).returncode
        except Exception as e:
            log(f"FATAL: pihole-FTL --teleporter failed to launch: {e}")
            sys.exit(1)
        if ftl_rc != 0:
            try:
                with open(err_path) as ef:
                    detail = ef.read().replace("\n", " ").strip()
            except OSError:
                detail = ""
            log(f"FATAL: pihole-FTL --teleporter failed (rc={ftl_rc}). FTL output: {detail}")
            _safe_remove(err_path)
            sys.exit(1)
        _safe_remove(err_path)

    # --- 3. Process & offload ---
    zips = sorted(glob.glob(os.path.join(CONFIG["TEMP_DIR"], "*.zip")))
    gen_file = zips[0] if zips else None
    if not gen_file:
        log("FATAL: Backup file not found in staging area.")
        sys.exit(1)

    target_name = f"{CONFIG['HOSTNAME_VAR']}_pihole_{CDATE}.zip"
    target_path = os.path.join(final_dest, target_name)

    log("Phase: Finalizing...")
    log(f"Source: {gen_file}")
    log(f"Target: {target_path}")

    # WM2: atomic write — copy to temp, then rename.
    target_tmp = target_path + ".tmp"
    try:
        shutil.copy2(gen_file, target_tmp)
        os.replace(target_tmp, target_path)
    except OSError:
        _safe_remove(target_tmp)
        log("FATAL: Failed to copy backup file.")
        sys.exit(1)

    log(f"SUCCESS: Backup saved to {target_path}")

    # --- 4. Verify checksum ---
    loc_sum = sha256_file(gen_file)
    rem_sum = sha256_file(target_path)
    if loc_sum == rem_sum:
        log(f"VERIFIED: Checksum matches ({loc_sum})")
    else:
        log(f"ERROR: Checksum mismatch! ({loc_sum} vs {rem_sum})")
        sys.exit(1)

    # WM11: zip-internal integrity check (native zipfile).
    if not zip_integrity_ok(target_path):
        log("ERROR: Destination zip failed integrity test (zipfile)")
        _safe_remove(target_path)
        sys.exit(1)
    log("VERIFIED: Zip integrity OK")

    # --- 4b. Persist dated checksum under .checksums/ ---
    # Mirrors auto-backupper's layout so the central NAS pull-side retention
    # can read this file's discovery date from the "_<YYYYMMDD>.sha256" suffix:
    #   <BACKUP_ROOT>/<SMB_SUBFOLDER>/<name>.zip
    #   <BACKUP_ROOT>/.checksums/<SMB_SUBFOLDER>/<name>.zip_<CDATE>.sha256
    if CONFIG["DESTINATION_TYPE"] == "smb":
        backup_root = CONFIG["MOUNT_POINT"].rstrip("/")
    else:
        backup_root = f"/mnt/user/{CONFIG['SMB_SHARE']}".rstrip("/")
    chk_subdir = f"{backup_root}/.checksums/{CONFIG['SMB_SUBFOLDER']}"
    chk_path = f"{chk_subdir}/{target_name}_{CDATE}.sha256"

    try:
        os.makedirs(chk_subdir, exist_ok=True)
    except OSError:
        log(f"WARN: Could not create checksum dir {chk_subdir} — skipping dated checksum write")
    else:
        # Sweep any stale dated sibling — one dated checksum per data file.
        for stale in glob.glob(os.path.join(chk_subdir, target_name + "_" + "[0-9]" * 8 + ".sha256")):
            _safe_remove(stale)
        # Atomic write: temp + rename.
        tmp = f"{chk_path}.tmp.{os.getpid()}"
        try:
            with open(tmp, "w") as f:
                f.write(rem_sum + "\n")
            os.replace(tmp, chk_path)
            log(f"VERIFIED: Wrote dated checksum → {chk_path}")
        except OSError:
            log(f"WARN: Failed to write checksum into place: {chk_path}")
            _safe_remove(tmp)

    # --- 4c. Retention (WS4) ---
    keep_days = CONFIG.get("WARPHOLE_KEEP_DAYS", 0)
    if keep_days and keep_days > 0:
        log(f"Phase: Rotation (keeping last {keep_days} days)")
        cutoff = time.time() - keep_days * 86400
        deleted = 0
        for old in glob.glob(os.path.join(final_dest, f"{CONFIG['HOSTNAME_VAR']}_pihole_*.zip")):
            try:
                if os.path.getmtime(old) >= cutoff:
                    continue
            except OSError:
                continue
            _safe_remove(old)
            deleted += 1
            old_name = os.path.basename(old)
            for old_chk in glob.glob(os.path.join(chk_subdir, old_name + "_" + "[0-9]" * 8 + ".sha256")):
                _safe_remove(old_chk)
        if deleted > 0:
            log(f"Rotation: removed {deleted} old backup(s).")


# ==============================================================================
# 8. HEALTH CHECK
# ==============================================================================


def total_ram_mb():
    try:
        with open("/proc/meminfo") as f:
            for line in f:
                if line.startswith("MemTotal:"):
                    return int(line.split()[1]) // 1024
    except OSError:
        pass
    return 0


def verify_tailscale_network():
    if not CONFIG["CHECK_TAILSCALE"] or not CONFIG["TAILSCALE_PING_IP"]:
        return
    ip = CONFIG["TAILSCALE_PING_IP"]
    log("Phase: Checking Tailscale Connectivity...")

    def ping_once():
        return subprocess.run(
            ["ping", "-c", "1", "-W", "5", ip],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        ).returncode == 0

    # WS5: retry before restarting (a restart tears down all connections).
    for attempt in range(3):
        if ping_once():
            log(f"HEALTHY: Tailscale network is reachable ({ip}).")
            return
        if attempt < 2:
            time.sleep(3)

    log("WARNING: Tailscale unreachable after 3 attempts. Restarting tailscaled service...")
    # WD8: guard the restart so a non-systemd host warns and continues.
    if shutil.which("systemctl") and subprocess.run(
        ["systemctl", "restart", "tailscaled"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    ).returncode == 0:
        log("SUCCESS: tailscaled service restarted.")
        time.sleep(10)  # peering can take 10-15s on first attempt
        if ping_once():
            log("RECOVERY: Tailscale connectivity restored.")
        else:
            log("ERROR: Restarted service, but Tailscale is still unreachable.")
    else:
        log("FATAL: Failed to restart tailscaled service.")


def _gravity_size(data):
    """Mirror bash: null/missing -> 0; negative (e.g. -2 corrupt) -> -1 (invalid)."""
    gv = data.get("gravity_size", 0)
    if isinstance(gv, bool):
        return 0
    try:
        n = int(gv)
    except (TypeError, ValueError):
        return 0
    return n if n >= 0 else -1


def run_health_check():
    log("=== Starting Pi-hole Health Check ===")

    # --- 0. Tailscale ---
    verify_tailscale_network()

    # --- A. Post-reboot recovery ---
    if os.path.isfile(CONFIG["REPAIR_MARKER"]):
        log(f"RECOVERY: Found repair marker ({CONFIG['REPAIR_MARKER']}).")
        log("ACTION: System has rebooted. Attempting to pull Gravity now...")
        if CONFIG["IS_DOCKER"] and not ensure_pihole_running():
            sys.exit(1)
        if run_gravity_rebuild("post-reboot recovery") != 0:
            log(f"ERROR: Recovery gravity rebuild failed (see {CONFIG['GRAVITY_LOG']}). Leaving repair marker in place.")
            sys.exit(1)
        _safe_remove(CONFIG["REPAIR_MARKER"])
        log("SUCCESS: Recovery gravity pull complete. Marker removed.")
        return

    # WS7: container up before API.
    if not ensure_pihole_running():
        sys.exit(1)

    dlog("pre-authenticate")
    authenticate()
    dlog(f"post-authenticate (SID is {'set' if state['sid'] else 'empty'})")

    dlog("pre-/padd")
    data = api_get_padd(timeout=10)
    if data is None:
        log("WARN: /padd request failed — treating API as down.")

    # WS9: empty/invalid -> force rebuild path.
    if not isinstance(data, dict):
        log("WARN: API returned empty/invalid JSON — treating as corrupt-DB and forcing rebuild.")
        raw_gravity = "<invalid>"
        domains = 0
    else:
        # WD4: distinguish a 401 error body from an empty/corrupt gravity DB.
        if "error" in data:
            err = data.get("error")
            log(f"ERROR: /padd returned an API error: {err}.")
            log("       Pi-hole requires authentication but PI_PASSWORD is empty/wrong. NOT rebuilding gravity.")
            secrets = os.environ.get("WARPHOLE_SECRETS_FILE", "/etc/warphole/secrets.env")
            log(f"       Set PI_PASSWORD (ideally in {secrets}, mode 600) to this box's API password.")
            return
        raw_gravity = data.get("gravity_size")
        n = _gravity_size(data)
        if n < 0:
            log(f"ERROR: Invalid API response (gravity_size={raw_gravity}). Forcing gravity update...")
            domains = 0
        else:
            domains = n

    if domains > 0:
        log(f"HEALTHY: Gravity looks good ({domains} domains).")
        return

    log(f"CRITICAL: 0 domains blocked (gravity_size={raw_gravity}). Triggering gravity update...")
    run_gravity_rebuild("initial")

    log("Phase: Verifying gravity rebuild via API...")
    time.sleep(3)  # let FTL swap databases and settle

    new_data = api_get_padd(timeout=10)
    if not isinstance(new_data, dict):
        log("WARN: API unreachable during gravity verification. Assuming rebuild failed.")
        new_count = 0
    else:
        new_count = max(_gravity_size(new_data), 0)

    if new_count > 0:
        log(f"SUCCESS: Gravity rebuild successful ({new_count} domains active).")
        return

    log(f"FATAL: Gravity rebuild FAILED or database is corrupt (Count: {new_count}).")

    # --- Conditional repair ---
    if CONFIG["IS_DOCKER"]:
        # WS2: restart container, wait for readiness, retry gravity once.
        name = CONFIG["DOCKER_CONTAINER_NAME"]
        log("ACTION: Restarting pihole container to clear its state...")
        if subprocess.run(["docker", "restart", name],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0:
            log("ERROR: docker restart failed. Manual intervention needed.")
            sys.exit(1)
        waited = 0
        while waited < 60:
            if ensure_pihole_running():
                break
            time.sleep(2)
            waited += 2
        if not ensure_pihole_running():
            log("ERROR: Container did not return to Running state within 60s.")
            sys.exit(1)
        time.sleep(5)  # give FTL time to open its API socket

        run_gravity_rebuild("post-restart retry")
        time.sleep(3)

        # Re-authenticate (SID does not survive FTL restart) and re-verify.
        state["sid"] = ""
        authenticate()
        retry_data = api_get_padd(timeout=10)
        retry_count = max(_gravity_size(retry_data), 0) if isinstance(retry_data, dict) else 0

        if retry_count > 0:
            log(f"RECOVERY: Container restart + gravity rebuild succeeded ({retry_count} domains active).")
        else:
            log(f"FATAL: Container restart did not fix gravity (Count: {retry_count}). Manual intervention needed.")
            sys.exit(1)
    else:
        ram = total_ram_mb()
        if ram < 1024:
            log(f"ACTION: Low memory bare-metal system ({ram} MB). Rebooting to clear RAM for gravity...")
            try:
                open(CONFIG["REPAIR_MARKER"], "w").close()
            except OSError:
                pass
            if subprocess.run(["/sbin/reboot"]).returncode != 0:
                if subprocess.run(["systemctl", "reboot"]).returncode != 0:
                    log("FATAL: Could not trigger reboot.")
            sys.exit(0)
        else:
            log("WARNING: Skipping repair (bare-metal with sufficient RAM — reboot heuristic doesn't apply).")
            sys.exit(1)


# ==============================================================================
# 9. STATS DASHBOARD (rich)
# ==============================================================================


def trigger_gravity_bg():
    """WS3: launch `pihole -g` detached, record pid for is_gravity_running()."""
    if is_gravity_running():
        return
    try:
        out = open(CONFIG["GRAVITY_LOG"], "w")
    except OSError:
        return
    if CONFIG["IS_DOCKER"]:
        cmd = ["docker", "exec", CONFIG["DOCKER_CONTAINER_NAME"], "pihole", "-g"]
    else:
        cmd = ["pihole", "-g"]
    try:
        p = subprocess.Popen(cmd, stdout=out, stderr=subprocess.STDOUT, start_new_session=True)
        with open(CONFIG["GRAVITY_PIDFILE"], "w") as f:
            f.write(str(p.pid))
    except Exception:
        pass
    finally:
        # The child holds its own dup of the fd; close the parent's copy so
        # repeated dashboard "u" presses don't leak a descriptor each time.
        out.close()


def _draw_bar(pct, width):
    try:
        p = float(pct)
    except (TypeError, ValueError):
        p = 0.0
    if p > 100:
        p = 100
    filled = int(round((p / 100) * width))
    filled = max(0, min(width, filled))
    return "[" + "|" * filled + "." * (width - filled) + "]"


def _g(data, path, default=0):
    """Safe nested lookup over a dict path like ['system','memory','ram','used']."""
    cur = data
    for k in path:
        if not isinstance(cur, dict) or k not in cur:
            return default
        cur = cur[k]
    return cur if cur is not None else default


def run_stats():
    from rich.live import Live
    from rich.panel import Panel
    from rich.text import Text
    from rich.table import Table
    from rich.console import Group

    # WM3: validate REFRESH_RATE (used as the keypress timeout).
    rr = CONFIG["REFRESH_RATE"]
    if not isinstance(rr, int) or rr < 1:
        print(f"WARN: REFRESH_RATE='{rr}' is not a positive integer, defaulting to 2.")
        CONFIG["REFRESH_RATE"] = 2
        time.sleep(2)
    refresh = CONFIG["REFRESH_RATE"]

    authenticate()

    # WM4: one-shot PADD schema drift check before the screen takes over.
    probe = api_get_padd(timeout=5)
    if isinstance(probe, dict):
        checks = {
            ".queries.total": ["queries", "total"],
            ".gravity_size": ["gravity_size"],
            ".system.cpu.load.raw": ["system", "cpu", "load", "raw"],
            ".system.memory.ram.used": ["system", "memory", "ram", "used"],
            ".sensors.cpu_temp": ["sensors", "cpu_temp"],
        }
        missing = [label for label, p in checks.items() if _g(probe, p, None) is None]
        if missing:
            print("\nWARN: PADD schema drift detected — missing fields:")
            for m in missing:
                print(f"        {m}")
            print("      Dashboard will show 0 for those metrics. Starting in 3s...")
            time.sleep(3)

    # Non-blocking single-key reader (q/u) doubling as the refresh delay.
    interactive = sys.stdin.isatty()
    old_term = None
    if interactive:
        try:
            import termios
            import tty

            fd = sys.stdin.fileno()
            old_term = termios.tcgetattr(fd)
            tty.setcbreak(fd)
        except Exception:
            interactive = False

    def read_key(timeout):
        if not interactive:
            time.sleep(timeout)
            return None
        import select

        dr, _, _ = select.select([sys.stdin], [], [], timeout)
        if dr:
            return sys.stdin.read(1)
        return None

    counters = {"prev_queries": 0, "first_run": True}

    def render(data):
        if not isinstance(data, dict):
            data = {}

        total = _g(data, ["queries", "total"], 0)
        blocked = _g(data, ["queries", "blocked"], 0)
        pct_blocked = _g(data, ["queries", "percent_blocked"], 0)
        gravity = _g(data, ["gravity_size"], 0)
        clients = _g(data, ["active_clients"], 0)
        top_blocked = _g(data, ["top_blocked"], "None")
        recent_blocked = _g(data, ["recent_blocked"], "Waiting...")
        top_domain = _g(data, ["top_domain"], "None")
        load_raw = _g(data, ["system", "cpu", "load", "raw"], [0])
        load = load_raw[0] if isinstance(load_raw, list) and load_raw else (load_raw or 0)
        mem_used_kb = _g(data, ["system", "memory", "ram", "used"], 0)
        mem_total_kb = _g(data, ["system", "memory", "ram", "total"], 0)
        mem_pct = _g(data, ["system", "memory", "ram", "%used"], 0)
        cpu_temp = _g(data, ["sensors", "cpu_temp"], 0)

        try:
            mem_used_mb = int(mem_used_kb) // 1024
            mem_total_mb = int(mem_total_kb) // 1024
        except (TypeError, ValueError):
            mem_used_mb = mem_total_mb = 0

        # QPS
        qps = 0.0
        if counters["first_run"]:
            counters["first_run"] = False
        else:
            diff = total - counters["prev_queries"]
            if diff < 0:
                diff = 0  # guard against API counter reset
            qps = round(diff / refresh, 1)
        counters["prev_queries"] = total

        # Gravity status
        if is_gravity_running():
            grav_status = Text("⚡ UPDATING", style="yellow")
            try:
                with open(CONFIG["GRAVITY_LOG"]) as f:
                    tail = (f.readlines() or [""])[-1].strip()[:40]
            except OSError:
                tail = ""
            grav_msg = f"Log: {tail}..."
        else:
            grav_status = Text("✔ READY", style="green")
            grav_msg = f"Recent: {recent_blocked}"

        header = Panel(
            Text(f"WARPHOLE [Python] — {CONFIG['HOSTNAME_VAR']}   {datetime.datetime.now().strftime('%H:%M:%S')}",
                 style="bold blue"),
            border_style="blue",
        )

        core = Table.grid(expand=True, padding=(0, 2))
        core.add_column(justify="left")
        core.add_column(justify="left")
        core.add_column(justify="left")
        core.add_row(
            Text("QUERIES (QPS)", style="cyan"),
            Text("BLOCKED", style="cyan"),
            Text("BLOCK PERCENT", style="cyan"),
        )
        core.add_row(
            Text(f"{total} ({qps}/s)", style="green"),
            Text(str(blocked), style="red"),
            Text(f"{pct_blocked}%", style="yellow"),
        )
        core.add_row("", "", Text(_draw_bar(str(pct_blocked).split(".")[0], 20), style="yellow"))

        sys_tbl = Table.grid(expand=True, padding=(0, 2))
        sys_tbl.add_column(justify="left")
        sys_tbl.add_column(justify="left")
        sys_tbl.add_column(justify="left")
        sys_tbl.add_row(
            Text("SYSTEM LOAD", style="cyan"),
            Text("MEMORY USAGE", style="cyan"),
            Text("HEALTH", style="cyan"),
        )
        sys_tbl.add_row(
            Text(str(load), style="green"),
            Text(f"{mem_used_mb} / {mem_total_mb} MB", style="green"),
            Text(f"Temp: {cpu_temp}°C  Clients: {clients}", style="grey50"),
        )
        sys_tbl.add_row("", Text(_draw_bar(str(mem_pct).split(".")[0], 18), style="green"), "")

        insights = Text()
        insights.append("DOMAINS IN GRAVITY:  ", style="cyan")
        insights.append(f"{gravity}\n")
        insights.append("TOP DOMAIN:          ", style="cyan")
        insights.append(f"{top_domain}\n")
        insights.append("TOP BLOCKED:         ", style="cyan")
        insights.append(f"{top_blocked}\n", style="red")
        insights.append("GRAVITY STATUS:      ", style="cyan")
        insights.append_text(grav_status)
        insights.append(f"\n{grav_msg}", style="grey50")

        footer = Text(" [u] Update Gravity   [q] Quit", style="cyan")

        return Group(
            header,
            Panel(core, title="Core Stats", border_style="grey50"),
            Panel(sys_tbl, title="System", border_style="grey50"),
            Panel(insights, title="Insights", border_style="grey50"),
            footer,
        )

    try:
        with Live(auto_refresh=False, screen=True) as live:
            while True:
                try:
                    data = api_get_padd(timeout=3)
                    live.update(render(data), refresh=True)
                    key = read_key(refresh)
                    if key == "q":
                        break
                    if key == "u":
                        trigger_gravity_bg()
                except KeyboardInterrupt:
                    break
                except Exception:
                    # Flaky network/parse — keep the dashboard alive (WS6).
                    time.sleep(refresh)
    finally:
        # Ensure the cursor is visible again even on an unclean exit — mirrors
        # bash's `tput cnorm` in cleanup() (rich usually restores it, but this
        # is a cheap belt-and-suspenders for Ctrl+C / exception paths).
        try:
            sys.stdout.write("\033[?25h")
            sys.stdout.flush()
        except Exception:
            pass
        if old_term is not None:
            try:
                import termios

                termios.tcsetattr(sys.stdin.fileno(), termios.TCSADRAIN, old_term)
            except Exception:
                pass


# ==============================================================================
# 10. CLEANUP & EXECUTION
# ==============================================================================


def cleanup():
    # Remove temp staging files.
    if os.path.isdir(CONFIG["TEMP_DIR"]) and not state["keep_local"]:
        shutil.rmtree(CONFIG["TEMP_DIR"], ignore_errors=True)

    # Auto-unmount (only if we manage the mount).
    if CONFIG["DESTINATION_TYPE"] == "smb" and state["manage_mount"]:
        if os.path.ismount(CONFIG["MOUNT_POINT"]):
            if state["mode"] != "stats":
                log("Cleanup: Unmounting share...")
            if subprocess.run(["umount", CONFIG["MOUNT_POINT"]],
                              stderr=subprocess.DEVNULL).returncode != 0:
                subprocess.run(["umount", "-l", CONFIG["MOUNT_POINT"]],
                               stderr=subprocess.DEVNULL)

    # WM13: best-effort logout with a short timeout; swallow errors.
    if state["sid"]:
        try:
            import requests

            requests.delete(
                f"{CONFIG['PI_URL']}/auth",
                headers={"X-FTL-SID": state["sid"]},
                timeout=5,
            )
        except Exception:
            pass


def print_usage():
    prog = os.path.basename(sys.argv[0])
    print(f"""Usage: {prog} [OPTIONS]

Primary modes:
  --backup-now    Run Pi-hole Teleporter backup and offload to destination
  --check         Run health check (gravity + optional Tailscale)
  --stats         Launch terminal dashboard
  --help, -h      Show this help

Advanced (debugging and testing backups):
  --mount-only    Mount SMB share only (holds the mount; skips unmount on exit)
  --unmount-only  Unmount SMB share only
  --keep-local    Keep temp staging files (debug)

Configure DEFAULT_MODE in the script (or secrets.env) to run without flags.""")


def main():
    # Root check.
    if os.geteuid() != 0:
        print("CRITICAL: This script must be run as root.", file=sys.stderr)
        sys.exit(1)

    load_secrets()

    # WM6: short-circuit --help / -h BEFORE the dependency check.
    args = [a for a in sys.argv[1:] if a != ""]
    if any(a in ("--help", "-h") for a in args):
        print_usage()
        sys.exit(0)

    # WM1: determine stats-ness from ALL args; disables file logging.
    stats_mode = CONFIG["DEFAULT_MODE"] == "stats" or "--stats" in args
    state["log_to_file"] = not stats_mode
    if not stats_mode:
        setup_logging()

    check_deps(need_rich=stats_mode)

    import atexit

    atexit.register(cleanup)

    # Determine mode (and handle the mount/unmount short-circuits in order).
    if not args:
        if CONFIG["DEFAULT_MODE"]:
            state["mode"] = CONFIG["DEFAULT_MODE"]
        else:
            print_usage()
            sys.exit(1)
    else:
        for a in args:
            if a == "--backup-now":
                state["mode"] = "backup"
            elif a == "--check":
                state["mode"] = "check"
            elif a == "--stats":
                state["mode"] = "stats"
            elif a == "--mount-only":
                acquire_lock()  # WC1: mounting mutates system state
                mount_smb()
                state["manage_mount"] = False  # hold the mount
                sys.exit(0)
            elif a == "--unmount-only":
                if os.path.ismount(CONFIG["MOUNT_POINT"]):
                    subprocess.run(["umount", CONFIG["MOUNT_POINT"]])
                sys.exit(0)
            elif a == "--keep-local":
                state["keep_local"] = True
            else:
                print(f"Unknown argument: {a}")
                print()
                print_usage()
                sys.exit(1)

    # Route execution. WC1: lock for mutating modes; stats runs read-only.
    if state["mode"] == "backup":
        acquire_lock()
        run_backup()
    elif state["mode"] == "check":
        acquire_lock()
        run_health_check()
    elif state["mode"] == "stats":
        run_stats()
    else:
        print("Invalid mode selected.")
        sys.exit(1)


if __name__ == "__main__":
    main()
