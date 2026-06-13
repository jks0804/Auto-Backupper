#!/usr/bin/env python3
# ==============================================================================
# AUTO-RESTORER
# Companion restore tool for the Auto-Backupper suite
# ==============================================================================
# A faithful port of auto-restorer.sh (the primary version lives on the repo's
# `bash` branch). Reads the same auto_backupper.cfg and the dated-checksum
# index that auto-backupper / watchtower / legacy-checksum produce.
#
# USAGE:
#   auto-restorer.py --list [PATTERN]       List archives (optional glob)
#   auto-restorer.py --inspect ARCHIVE      Show tar contents
#   auto-restorer.py --verify  ARCHIVE      Checksum verify one archive
#   auto-restorer.py --verify-all           Checksum verify every archive
#   auto-restorer.py --corruption-report [--host HOST]
#   auto-restorer.py --restore ARCHIVE --target PATH [--only P] [--stop-docker]
#                    [--force] [--no-verify]
#   auto-restorer.py --prune-checksums --older-than DURATION [--commit] [--force]
#
# GLOBAL: -c/--config FILE, --dry-run, -h/--help
# ==============================================================================

import os
import re
import sys
import glob
import fnmatch
import shutil
import socket
import tempfile
import datetime
import subprocess

# ==============================================================================
# 1. CONSTANTS & DEFAULTS
# ==============================================================================
DEFAULT_CONFIG_FILE = "/boot/config/auto_backupper.cfg"
LOGFILE = "/var/log/auto_restorer.log"
LOCKFILE = "/var/lock/auto_restorer.lock"
CHECKSUM_DIR = ".checksums"
UNRAID_CONTAINERS_LIST = "/tmp/auto_restorer_containers.list"

LOG_MAX_SIZE = 10 * 1024 * 1024
LOG_BACKUPS = 5
LOG_VERBOSITY = "info"

# Config-overridable.
BACKUP_BASE = "/mnt/user/backup"
DOCKER_STOP_TIMEOUT = 60

# Runtime flags (set by argument parsing).
DRY_RUN = False
MODE = ""
ARCHIVE = ""
TARGET = ""
STOP_DOCKER = False
FORCE = False
VERIFY_BEFORE_RESTORE = True
LIST_PATTERN = "*"
PRUNE_OLDER_THAN = ""
PRUNE_COMMIT = False
HOST_OVERRIDE = ""
ONLY_PATHS = []

DOCKER_WAS_STOPPED = False
_lock_fd = None
_worker_lock_fd = None  # held for the restore's lifetime to block the backup worker

# Aggregated watchtower corruption report (path -> count) + loaded path.
CORRUPTION_COUNTS = {}
CORRUPTION_REPORT_LOADED = ""

# ==============================================================================
# 2. LOGGING
# ==============================================================================


def _log_verbosity_threshold():
    return {"error": 2, "phase": 3, "info": 4, "debug": 99}.get(LOG_VERBOSITY, 4)


def _log_level_for(msg):
    if re.match(r"^(FATAL|CRITICAL|ERROR:|ERROR |WARN:|WARN )", msg):
        return 2
    if re.match(r"^(===|RESTORE SUCCEEDED:|RECOVERY:|Verifying:|Inspecting:|Phase:|Summary:)", msg):
        return 3
    if msg.startswith("DEBUG:"):
        return 99
    return 4


def rotate_logs():
    # Copytruncate, suite-standard.
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


# ==============================================================================
# 3. CONFIG LOADING
# ==============================================================================


def _unquote(s):
    s = s.strip()
    if len(s) >= 2 and s[0] == s[-1] and s[0] in ("'", '"'):
        return s[1:-1]
    return s


def load_config(path):
    # The restorer only consumes BACKUP_BASE and DOCKER_STOP_TIMEOUT from the cfg.
    global BACKUP_BASE, DOCKER_STOP_TIMEOUT
    if not os.path.isfile(path):
        return
    scalar = re.compile(
        r'^[ \t]*([A-Za-z_][A-Za-z0-9_]*)='
        r'''("(?:[^"\\]|\\.)*"|'[^']*'|[^\s#(]*)[ \t]*(?:#.*)?$''',
        re.M,
    )
    try:
        content = open(path).read()
    except OSError:
        return
    for m in scalar.finditer(content):
        key, raw = m.group(1), _unquote(m.group(2))
        if key == "BACKUP_BASE":
            BACKUP_BASE = raw
        elif key == "DOCKER_STOP_TIMEOUT":
            try:
                DOCKER_STOP_TIMEOUT = int(raw)
            except ValueError:
                pass


# ==============================================================================
# 4. UTILITIES
# ==============================================================================


def parse_duration_to_cutoff(text):
    # "5y" / "12m" / "365d" -> YYYYMMDD of (today - duration). None on bad input.
    m = re.match(r"^([0-9]+)([dmy])$", text)
    if not m:
        return None
    n, unit = int(m.group(1)), m.group(2)
    days = {"d": n, "m": n * 30, "y": n * 365}[unit]
    return (datetime.datetime.now() - datetime.timedelta(days=days)).strftime("%Y%m%d")


def human_size(b):
    b = float(b)
    if b >= 1099511627776:
        return f"{b / 1099511627776:.1f}T"
    if b >= 1073741824:
        return f"{b / 1073741824:.1f}G"
    if b >= 1048576:
        return f"{b / 1048576:.1f}M"
    if b >= 1024:
        return f"{b / 1024:.1f}K"
    return f"{int(b)}B"


# Returns (code, path): 0 found (path), 1 NO_BASE, 2 NO_CHECKSUM. Newest dated
# sibling wins (YYYYMMDD sorts chronologically as a string).
def checksum_find_path(file_path):
    if not file_path.startswith(BACKUP_BASE.rstrip("/") + "/"):
        return (1, None)
    base = BACKUP_BASE.rstrip("/")
    rel = file_path[len(base) + 1:]
    chk_dir = os.path.join(base, CHECKSUM_DIR, os.path.dirname(rel))
    name = os.path.basename(rel)
    matches = glob.glob(os.path.join(chk_dir, name + "_" + "[0-9]" * 8 + ".sha256"))
    if not matches:
        return (2, None)
    return (0, sorted(matches)[-1])


def _sha256(path, timeout=600):
    try:
        r = subprocess.run(["sha256sum", path], capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return None
    if r.returncode != 0 or not r.stdout.strip():
        return None
    return r.stdout.split()[0]


# Returns a status token mirroring bash: OK / NO_CHECKSUM / MISMATCH /
# HASH_ERROR / NO_BASE.
def verify_archive(archive):
    code, chk = checksum_find_path(archive)
    if code == 1:
        return "NO_BASE"
    if code == 2:
        return "NO_CHECKSUM"
    try:
        with open(chk) as f:
            expected = "".join(f.read().split())  # strip all whitespace
    except OSError:
        expected = ""
    actual = _sha256(archive, 600)
    if actual is None:
        return "HASH_ERROR"
    return "OK" if expected == actual else "MISMATCH"


def _host():
    # --host overrides; otherwise the uppercased short hostname (the casing the
    # suite's writers use). --host values are NOT recased.
    return HOST_OVERRIDE or socket.gethostname().split(".")[0].upper()


def corruption_report_path():
    return os.path.join(BACKUP_BASE, CHECKSUM_DIR, f"{_host()}_corruption_report.txt")


def list_other_host_reports():
    d = os.path.join(BACKUP_BASE, CHECKSUM_DIR)
    if not os.path.isdir(d):
        return []
    return [os.path.basename(f)[: -len("_corruption_report.txt")]
            for f in glob.glob(os.path.join(d, "*_corruption_report.txt"))]


def load_corruption_report():
    global CORRUPTION_COUNTS, CORRUPTION_REPORT_LOADED
    CORRUPTION_COUNTS = {}
    CORRUPTION_REPORT_LOADED = ""
    path = corruption_report_path()
    if not os.path.isfile(path):
        return
    CORRUPTION_REPORT_LOADED = path
    try:
        with open(path) as f:
            for line in f:
                m = re.search(r"\] CORRUPTION: (.+)$", line.rstrip("\n"))
                if m:
                    fp = m.group(1)
                    CORRUPTION_COUNTS[fp] = CORRUPTION_COUNTS.get(fp, 0) + 1
    except OSError:
        pass


def hist_corrupt_count(path):
    return CORRUPTION_COUNTS.get(path, 0)


def detect_os():
    if os.path.isfile("/etc/unraid-version"):
        return "unraid"
    if shutil.which("omv-notify"):
        return "omv"
    return "linux"


def tar_decompress_flag(name):
    # Returns the tar flag ("" for plain .tar), or None on an unknown extension.
    if name.endswith((".tar.gz", ".tgz")):
        return "-z"
    if name.endswith((".tar.bz2", ".tbz2")):
        return "-j"
    if name.endswith((".tar.xz", ".txz")):
        return "-J"
    if name.endswith(".tar.zst"):
        return "--zstd"
    if name.endswith(".tar"):
        return ""
    log(f"ERROR: Unrecognised archive extension: {name}")
    return None


def _tar_list(archive, dflag, members=None):
    # `tar -tf` returning a list of entry names; best-effort (ignores errors).
    cmd = ["tar"] + ([dflag] if dflag else []) + ["-tf", archive]
    if members:
        cmd += members
    try:
        out = subprocess.run(cmd, capture_output=True, text=True).stdout
    except OSError:
        return []
    return out.splitlines()


# ==============================================================================
# 5. DOCKER MANAGEMENT (restore-side)
# ==============================================================================


def docker_stop_for_restore():
    if DRY_RUN:
        log("[DRY] Would stop Docker for restore")
        return
    os_type = detect_os()
    if os_type == "unraid":
        if os.access("/etc/rc.d/rc.docker", os.X_OK):
            log("Stopping Unraid Docker service...")
            subprocess.run(["/etc/rc.d/rc.docker", "stop"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            elapsed = 0
            while True:
                st = subprocess.run(["/etc/rc.d/rc.docker", "status"], capture_output=True, text=True).stdout
                if "running" not in st:
                    break
                import time

                time.sleep(3)
                elapsed += 3
                if elapsed >= DOCKER_STOP_TIMEOUT:
                    log(f"WARN: Docker service stop timed out at {DOCKER_STOP_TIMEOUT}s; forcing.")
                    subprocess.run(["/etc/rc.d/rc.docker", "force_stop"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    break
        else:
            log("WARN: /etc/rc.d/rc.docker not found on Unraid (skipping stop)")
    else:
        if shutil.which("docker"):
            log("Recording running containers, then stopping them...")
            names = subprocess.run(["docker", "ps", "--format", "{{.Names}}"], capture_output=True, text=True).stdout
            try:
                with open(UNRAID_CONTAINERS_LIST, "w") as f:
                    f.write(names)
            except OSError:
                names = ""
            running = [n for n in names.split() if n]
            if running:
                subprocess.run(["docker", "stop", "--time", str(DOCKER_STOP_TIMEOUT)] + running,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        else:
            log("INFO: docker command not present — nothing to stop")


def docker_start_after_restore():
    if DRY_RUN:
        log("[DRY] Would restart Docker after restore")
        return
    os_type = detect_os()
    if os_type == "unraid":
        if os.access("/etc/rc.d/rc.docker", os.X_OK):
            log("Restarting Unraid Docker service...")
            subprocess.run(["/etc/rc.d/rc.docker", "start"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    else:
        if os.path.isfile(UNRAID_CONTAINERS_LIST) and os.path.getsize(UNRAID_CONTAINERS_LIST) > 0 and shutil.which("docker"):
            log("Restarting previously-recorded containers...")
            try:
                with open(UNRAID_CONTAINERS_LIST) as f:
                    for c in f.read().split():
                        if subprocess.run(["docker", "start", c], stdout=subprocess.DEVNULL,
                                          stderr=subprocess.DEVNULL).returncode != 0:
                            log(f"  WARN: could not start {c}")
            except OSError:
                pass
            try:
                os.remove(UNRAID_CONTAINERS_LIST)
            except OSError:
                pass
        else:
            log("INFO: No container list to restart (either nothing was stopped or the list is missing)")


def on_exit():
    # Safety net: if we exit mid-restore with Docker stopped, bring it back.
    if DOCKER_WAS_STOPPED:
        log("RECOVERY: Exit detected while Docker was stopped; attempting restart...")
        try:
            docker_start_after_restore()
        except Exception:
            pass


# ==============================================================================
# 6. COMMANDS
# ==============================================================================


def _find_archives():
    base = BACKUP_BASE.rstrip("/")
    chk_root = os.path.join(base, CHECKSUM_DIR)
    out = []
    for root, dirs, files in os.walk(base):
        if root == chk_root or root.startswith(chk_root + os.sep):
            dirs[:] = []
            continue
        if CHECKSUM_DIR in dirs:
            dirs.remove(CHECKSUM_DIR)
        for fn in files:
            if fn.endswith((".tar.gz", ".tgz", ".tar")):
                out.append(os.path.join(root, fn))
    return sorted(out)


def cmd_list():
    base = BACKUP_BASE.rstrip("/")
    if not os.path.isdir(base):
        log(f"ERROR: BACKUP_BASE not found: {base}")
        return 1
    load_corruption_report()
    log(f"Listing archives in {base} (pattern: {LIST_PATTERN})")

    archives = [f for f in _find_archives() if fnmatch.fnmatch(os.path.basename(f), LIST_PATTERN)]
    if not archives:
        print(f"No archives found matching '{LIST_PATTERN}' under {base}.")
        return 0

    cats = {"systems": [], "shares": [], "services": [], "other": []}
    for f in archives:
        rel = f[len(base) + 1:]
        top = rel.split("/", 1)[0]
        cats[top if top in cats else "other"].append(f)

    def _print_category(title, strip_prefix, items):
        if not items:
            return
        print(f"\n=== {title} ===")
        for f in items:
            try:
                size_h = human_size(os.path.getsize(f))
            except OSError:
                size_h = "0B"
            try:
                date_h = datetime.datetime.fromtimestamp(os.path.getmtime(f)).strftime("%Y-%m-%d %H:%M")
            except OSError:
                date_h = "    unknown    "
            code, _ = checksum_find_path(f)
            chk_status = "[chk]" if code == 0 else "[NO CHK]"
            hc = hist_corrupt_count(f)
            hist_marker = " [HIST-CORRUPT]" if hc == 1 else (f" [HIST-CORRUPT×{hc}]" if hc > 1 else "")
            rel = f[len(base) + 1:]
            if strip_prefix and rel.startswith(strip_prefix):
                rel = rel[len(strip_prefix):]
            print(f"  {rel:<58} {size_h:>8}  {date_h}  {chk_status}{hist_marker}")

    _print_category("SYSTEMS", "systems/", cats["systems"])
    _print_category("SHARES", "shares/", cats["shares"])
    _print_category("SERVICES", "services/", cats["services"])
    _print_category("OTHER", "", cats["other"])
    print(f"\nTotal: {len(archives)} archive(s) in {base}")
    return 0


def cmd_inspect():
    archive = ARCHIVE
    if not os.path.isfile(archive):
        log(f"ERROR: Archive not found: {archive}")
        return 1
    dflag = tar_decompress_flag(archive)
    if dflag is None:
        return 1
    log(f"Inspecting: {archive}")
    print()
    entries = _tar_list(archive, dflag)
    # tar -tvf for the verbose listing (perms/owner/size/date), first 100.
    cmd = ["tar"] + ([dflag] if dflag else []) + ["-tvf", archive]
    try:
        verbose = subprocess.run(cmd, capture_output=True, text=True).stdout.splitlines()
    except OSError:
        verbose = []
    for line in verbose[:100]:
        print(line)
    print()
    print(f"Total entries: {len(entries)} (first 100 shown)")
    return 0


def cmd_verify():
    archive = ARCHIVE
    if not os.path.isfile(archive):
        log(f"ERROR: Archive not found: {archive}")
        return 1
    load_corruption_report()
    log(f"Verifying: {archive}")
    status = verify_archive(archive)
    hc = hist_corrupt_count(archive)
    chronic = f" (chronic — {hc} prior event(s))" if hc > 0 else ""
    if status == "OK":
        if hc > 0:
            log(f"  OK: {archive} [HIST-CLEARED — {hc} prior event(s), now clean]")
        else:
            log(f"  OK: {archive}")
        return 0
    if status == "NO_CHECKSUM":
        log(f"  WARN: No checksum file for {archive} (watchtower may not have scanned yet)")
        return 3
    if status == "MISMATCH":
        log(f"  FAIL: Checksum mismatch for {archive}{chronic}")
        return 1
    if status == "HASH_ERROR":
        log(f"  FAIL: Could not hash {archive} (timeout or I/O error){chronic}")
        return 4
    if status == "NO_BASE":
        log(f"  WARN: {archive} is not under BACKUP_BASE; no checksum resolvable")
        return 2
    return 0


def cmd_verify_all():
    base = BACKUP_BASE.rstrip("/")
    if not os.path.isdir(base):
        log(f"ERROR: BACKUP_BASE not found: {base}")
        return 1
    load_corruption_report()
    log(f"Verifying every archive under {base}...")
    ok = missing = failed = cleared = chronic = total = 0
    for f in _find_archives():
        total += 1
        status = verify_archive(f)
        hc = hist_corrupt_count(f)
        rel = f[len(base) + 1:]
        if status == "OK":
            ok += 1
            if hc > 0:
                cleared += 1
                log(f"  [HIST-CLEARED] {rel}  ({hc} prior event(s))")
        elif status == "NO_CHECKSUM":
            missing += 1
            log(f"  [NO CHK] {rel}")
        elif status in ("MISMATCH", "HASH_ERROR"):
            failed += 1
            if hc > 0:
                chronic += 1
                log(f"  [FAIL]   {rel}  ({status}, chronic — {hc} prior event(s))")
            else:
                log(f"  [FAIL]   {rel}  ({status})")
    print()
    log(f"Summary: {total} total, {ok} verified, {failed} failed, {missing} without checksum")
    if cleared > 0 or chronic > 0:
        log(f"         History: {cleared} cleared (stale report entries), {chronic} chronic (current+past failure)")
    return 1 if failed > 0 else 0


def confirm(prompt):
    if FORCE:
        return True
    try:
        ans = input(f"{prompt} [y/N]: ")
    except EOFError:
        return False
    return ans in ("y", "Y")


def cmd_restore():
    archive, target = ARCHIVE, TARGET
    if not archive:
        log("ERROR: --restore requires an archive path")
        return 1
    if not os.path.isfile(archive):
        log(f"ERROR: Archive not found: {archive}")
        return 1
    if not target:
        log("ERROR: --target is required for --restore (see 'Archive target hints' in --help)")
        return 1

    load_corruption_report()
    hist_count = hist_corrupt_count(archive)
    dflag = tar_decompress_flag(archive)
    if dflag is None:
        return 1

    # Pre-restore checksum.
    if VERIFY_BEFORE_RESTORE:
        log("Pre-restore verification...")
        status = verify_archive(archive)
        if status == "OK":
            log("  Archive checksum OK.")
        elif status in ("NO_CHECKSUM", "NO_BASE"):
            log("  WARN: No checksum recorded for this archive." if status == "NO_CHECKSUM"
                else "  WARN: Archive is outside BACKUP_BASE; cannot verify.")
            if not confirm("Proceed without verification?"):
                log("Aborted by user.")
                return 1
        elif status == "MISMATCH":
            log("FATAL: Archive checksum does NOT match recorded value.")
            log("       Refusing to restore corrupt data. Override with --no-verify if")
            log("       you've audited the file and believe the checksum is stale.")
            return 1
        elif status == "HASH_ERROR":
            log("FATAL: Could not hash archive (timeout or I/O error). Retry later.")
            return 1
        else:
            log(f"FATAL: Unknown verification status: {status}")
            return 1
    else:
        log("WARN: --no-verify supplied; skipping pre-restore checksum.")

    # Target existence.
    if not os.path.isdir(target):
        log(f"Target directory does not exist: {target}")
        if not DRY_RUN:
            if confirm("Create it?"):
                try:
                    os.makedirs(target, exist_ok=True)
                except OSError:
                    log(f"FATAL: Could not create {target}")
                    return 1
            else:
                log("Aborted.")
                return 1

    # Restore plan.
    if hist_count > 0:
        print()
        print(f"!! NOTE: This archive was flagged as corrupt {hist_count} time(s) in the past.")
        print("!!       The current SHA matches, so the restore will proceed, but consider")
        print("!!       spot-checking the extracted data and investigating the underlying")
        print("!!       storage (see --corruption-report for the full picture).")
    print()
    print("================ RESTORE PLAN ================")
    print(f"  Archive:      {archive}")
    print(f"  Target:       {target}")
    print(f"  Stop Docker:  {str(STOP_DOCKER).lower()}")
    print(f"  Dry run:      {str(DRY_RUN).lower()}")
    print(f"  Force:        {str(FORCE).lower()}")
    if ONLY_PATHS:
        print(f"  Only paths:   ({len(ONLY_PATHS)}) — partial extraction")
        for p in ONLY_PATHS:
            print(f"                  {p}")
    if hist_count > 0:
        print(f"  History:      {hist_count} prior corruption event(s) for this archive")
    print()
    if ONLY_PATHS:
        print("  First 10 entries matching --only filter:")
        for line in _tar_list(archive, dflag, ONLY_PATHS)[:10]:
            print(f"    {line}")
    else:
        print("  First 10 entries in the archive:")
        for line in _tar_list(archive, dflag)[:10]:
            print(f"    {line}")
    print("==============================================")
    print()

    if target == "/":
        print("!! Target is / — this will overwrite whatever paths are in the archive.")
        print("!! Commonly this is appdata + boot + docker.img; make sure you know what's")
        print("!! in the archive and that Docker is stopped (use --stop-docker).")
        print()

    if not confirm("Proceed with restore?"):
        log("Aborted by user.")
        return 1

    global DOCKER_WAS_STOPPED
    if STOP_DOCKER:
        docker_stop_for_restore()
        DOCKER_WAS_STOPPED = True

    if ONLY_PATHS:
        log(f"Extracting {len(ONLY_PATHS)} path(s) from {archive} into {target} ...")
    else:
        log(f"Extracting {archive} into {target} ...")

    extract_rc = 0
    if DRY_RUN:
        suffix = f" {' '.join(ONLY_PATHS)}" if ONLY_PATHS else ""
        log(f"[DRY] tar -x{' ' + dflag if dflag else ''} -f {archive} -C {target}{suffix}")
    else:
        # -p preserves perms, --same-owner preserves UID/GID (matters for
        # appdata). --only paths go at the end as tar's MEMBERS selection.
        cmd = ["tar"] + ([dflag] if dflag else []) + ["-xpf", archive, "-C", target, "--same-owner"]
        if ONLY_PATHS:
            cmd += ONLY_PATHS
        try:
            extract_rc = subprocess.run(cmd).returncode
        except OSError as e:
            # e.g. tar binary missing — surface it instead of an unhandled trace.
            log(f"ERROR: Could not run tar: {e}")
            extract_rc = 1

    if extract_rc != 0:
        log(f"ERROR: Extraction failed with code {extract_rc}")
        if STOP_DOCKER:
            docker_start_after_restore()
            DOCKER_WAS_STOPPED = False
        return 1
    log("Extraction complete.")

    if STOP_DOCKER:
        docker_start_after_restore()
        DOCKER_WAS_STOPPED = False

    log(f"RESTORE SUCCEEDED: {archive} -> {target}")
    return 0


def cmd_corruption_report():
    base = BACKUP_BASE.rstrip("/")
    if not os.path.isdir(base):
        log(f"ERROR: BACKUP_BASE not found: {base}")
        return 1
    load_corruption_report()
    host = _host()
    report_path = corruption_report_path()

    if not CORRUPTION_REPORT_LOADED:
        log(f"No corruption report found for host '{host}' at {report_path}")
        others = list_other_host_reports()
        if others:
            print(f"\nAvailable host reports under {base}/{CHECKSUM_DIR}:")
            for h in others:
                print(f"  {h}")
            print("\nRe-run with --host HOSTNAME to read another host's report.")
        return 0

    total_paths = len(CORRUPTION_COUNTS)
    log(f"Corruption report: {report_path}")
    log(f"Unique paths flagged: {total_paths}")
    if total_paths == 0:
        print("(report file is present but contains no CORRUPTION lines)")
        return 0

    print()
    print(f"  {'STATUS':<6}  {'COUNT':<7}  PATH")
    print(f"  {'------':<6}  {'-------':<7}  ----")
    n_bad = n_ok = n_gone = n_unknown = 0
    for p in sorted(CORRUPTION_COUNTS):
        count = CORRUPTION_COUNTS[p]
        if not os.path.exists(p):
            status = "-"
            n_gone += 1
        else:
            vs = verify_archive(p)
            if vs == "OK":
                status = "OK"
                n_ok += 1
            elif vs in ("MISMATCH", "HASH_ERROR"):
                status = "BAD"
                n_bad += 1
            else:
                status = "?"
                n_unknown += 1
        print(f"  {status:<6}  {count:<7}  {p}")
    print()
    log(f"Summary: {n_bad} BAD (active), {n_ok} OK (stale), {n_gone} no longer present, {n_unknown} unknown")
    return 1 if n_bad > 0 else 0


def cmd_prune_checksums():
    base = BACKUP_BASE.rstrip("/")
    if not PRUNE_OLDER_THAN:
        log("ERROR: --prune-checksums requires --older-than DURATION (e.g. 5y, 12m, 90d)")
        return 1
    cutoff = parse_duration_to_cutoff(PRUNE_OLDER_THAN)
    if not cutoff:
        log(f"ERROR: Invalid --older-than format: '{PRUNE_OLDER_THAN}' — use Nd / Nm / Ny (e.g. 90d, 6m, 5y)")
        return 1
    chk_root = os.path.join(base, CHECKSUM_DIR)
    if not os.path.isdir(chk_root):
        log(f"No .checksums/ tree at {chk_root} — nothing to prune.")
        return 0

    action_word = "COMMIT" if PRUNE_COMMIT else "DRY-RUN"
    log(f"Scanning {chk_root} for orphan checksums older than {PRUNE_OLDER_THAN}")
    log(f"Mode: {action_word} | Cutoff: discovery date < {cutoff}")

    candidates = []
    for root, _, files in os.walk(chk_root):
        for fn in files:
            m = re.search(r"_([0-9]{8})\.sha256$", fn)
            if not m:
                continue
            date_suffix = m.group(1)
            # int() is base-10 (YYYYMMDD never triggers octal); == bash's 10# compare.
            if int(date_suffix) >= int(cutoff):
                continue
            chk = os.path.join(root, fn)
            rel_with_suffix = os.path.relpath(chk, chk_root)
            data_rel = rel_with_suffix[: -len(f"_{date_suffix}.sha256")]
            # Orphan only: never delete a checksum whose data file is present.
            if os.path.isfile(os.path.join(base, data_rel)):
                continue
            candidates.append(chk)

    log(f"Found {len(candidates)} orphan checksum(s) older than {PRUNE_OLDER_THAN}")
    if not candidates:
        return 0

    fd, list_file = tempfile.mkstemp(prefix="auto_restorer_prune.")
    with os.fdopen(fd, "w") as f:
        f.write("\n".join(candidates) + "\n")

    preview_limit = 20
    print(f"\nSample of candidates (up to {preview_limit}):")
    for c in candidates[:preview_limit]:
        print(f"  {c}")
    if len(candidates) > preview_limit:
        print(f"  ... and {len(candidates) - preview_limit} more")
    print()

    if not PRUNE_COMMIT:
        log("DRY-RUN: pass --commit to actually delete the listed files.")
        log(f"         Full list preserved at: {list_file}")
        return 0

    if not confirm(f"Delete {len(candidates)} orphan checksum file(s)?"):
        log(f"Aborted by user. Full list preserved at: {list_file}")
        return 1

    deleted = 0
    skipped = 0
    for chk in candidates:
        # Re-check data-file presence at DELETE time, not just at scan time. The
        # scan->confirm window can be long and prune holds no lock, so watchtower
        # could re-stamp or a pull re-create the data file since the scan;
        # deleting its checksum then strands a present-but-unverifiable backup.
        # Re-derive the dated reading and also honour the legacy un-dated reading
        # (a "<name>_<8digits>.sha256" whose data is "<name>_<8digits>").
        m = re.search(r"_([0-9]{8})\.sha256$", os.path.basename(chk))
        if m:
            ds = m.group(1)
            rel_with_suffix = os.path.relpath(chk, chk_root)
            data_rel = rel_with_suffix[: -len(f"_{ds}.sha256")]
            legacy_rel = rel_with_suffix[: -len(".sha256")]
            if (os.path.isfile(os.path.join(base, data_rel))
                    or os.path.isfile(os.path.join(base, legacy_rel))):
                log(f"SKIP (data file present, keeping checksum): {chk}")
                skipped += 1
                continue
        try:
            os.remove(chk)
            deleted += 1
        except OSError:
            pass
    log(f"Deleted {deleted}/{len(candidates)} orphan checksum(s).")
    if skipped:
        log(f"Skipped {skipped} whose data file reappeared since the scan (kept their checksum).")
    try:
        os.remove(list_file)
    except OSError:
        pass
    # Tidy now-empty subdirs under .checksums/ (never the root).
    for root, dirs, files in os.walk(chk_root, topdown=False):
        if root == chk_root:
            continue
        try:
            if not os.listdir(root):
                os.rmdir(root)
        except OSError:
            pass
    return 0


# ==============================================================================
# 7. ARGUMENT PARSING & EXECUTION
# ==============================================================================


def usage():
    print(f"""auto-restorer.py — Companion restore tool for the Auto-Backupper suite

Usage: {os.path.basename(sys.argv[0])} COMMAND [OPTIONS]

Commands:
  --list [PATTERN]          List archives (optional glob matched against basename)
  --inspect ARCHIVE         Show tar contents of an archive
  --verify ARCHIVE          Verify one archive against its recorded checksum
  --verify-all              Verify every archive under BACKUP_BASE
  --corruption-report       Show watchtower's per-host corruption log
    --host HOSTNAME           Read another host's report (default: local short hostname)
  --restore ARCHIVE         Extract an archive (requires --target)
    --target PATH             Extraction destination
    --only PATH               Extract only PATH from the archive (repeatable)
    --stop-docker             Stop Docker before extraction, restart after
    --force                   Skip confirmation prompts; create target if missing
    --no-verify               Skip pre-restore checksum check (NOT recommended)
  --prune-checksums         Bulk-delete orphan entries from .checksums/
    --older-than DURATION     Required. Grammar: Nd / Nm / Ny (e.g. 5y, 12m, 365d)
    --commit                  Default is dry-run preview; pass --commit to delete

Global options:
  -c, --config FILE         Config file (default: {DEFAULT_CONFIG_FILE})
  --dry-run                 Show planned actions without modifying anything
  -h, --help                Show this help

Archive target hints (match how auto-backupper built the archive):
  shares/SHARE/*.tar.gz         → --target $SHARES_BASE_FOLDER  (usually /mnt/user)
  shares/SHARE/SUB/*.tar.gz     → --target $SHARES_BASE_FOLDER/SHARE
  systems/HOST/*.tar.gz         → --target /   (re-extracts appdata, boot, docker.img)
  services/mysql|mongo|redis/   → --target /tmp/restore  (then import with db tools)""")


def parse_args(argv):
    global MODE, ARCHIVE, TARGET, STOP_DOCKER, FORCE, VERIFY_BEFORE_RESTORE
    global LIST_PATTERN, PRUNE_OLDER_THAN, PRUNE_COMMIT, HOST_OVERRIDE, DRY_RUN

    ONLY_PATHS.clear()  # fresh per invocation (re-entrancy)
    i = 0
    n = len(argv)

    def need(flag):
        # Reject a missing OR flag-shaped next token. None of the value flags
        # (paths/durations/hostnames) legitimately starts with '-', so a
        # forgotten value like `--target --stop-docker` must error, not silently
        # swallow the following flag as the value.
        nxt = argv[i + 1] if i + 1 < n else None
        if nxt is None or nxt.startswith("-"):
            shown = nxt if nxt is not None else "<none>"
            print(f"ERROR: {flag} requires a value (got '{shown}')", file=sys.stderr)
            sys.exit(1)
        return nxt

    while i < n:
        a = argv[i]
        if a == "--list":
            MODE = "list"
            nxt = argv[i + 1] if i + 1 < n else ""
            if nxt and not nxt.startswith("-"):
                LIST_PATTERN = nxt
                i += 1
        elif a == "--inspect":
            MODE = "inspect"
            ARCHIVE = need("--inspect"); i += 1
        elif a == "--verify":
            MODE = "verify"
            ARCHIVE = need("--verify"); i += 1
        elif a == "--verify-all":
            MODE = "verify-all"
        elif a == "--corruption-report":
            MODE = "corruption-report"
        elif a == "--host":
            HOST_OVERRIDE = need("--host"); i += 1
        elif a == "--restore":
            MODE = "restore"
            ARCHIVE = need("--restore"); i += 1
        elif a == "--target":
            TARGET = need("--target"); i += 1
        elif a == "--only":
            ONLY_PATHS.append(need("--only")); i += 1
        elif a == "--stop-docker":
            STOP_DOCKER = True
        elif a == "--force":
            FORCE = True
        elif a == "--no-verify":
            VERIFY_BEFORE_RESTORE = False
        elif a == "--dry-run":
            DRY_RUN = True
        elif a == "--prune-checksums":
            MODE = "prune-checksums"
        elif a == "--older-than":
            PRUNE_OLDER_THAN = need("--older-than"); i += 1
        elif a == "--commit":
            PRUNE_COMMIT = True
        elif a.startswith("--config="):
            pass  # captured pre-scan
        elif a in ("--config", "-c"):
            i += 1  # consume value
        elif a in ("-h", "--help"):
            usage()
            sys.exit(0)
        else:
            print(f"ERROR: Unknown argument: {a}", file=sys.stderr)
            print(f"Try {sys.argv[0]} --help", file=sys.stderr)
            sys.exit(1)
        i += 1


def main():
    global BACKUP_BASE, _lock_fd, _worker_lock_fd

    if os.geteuid() != 0:
        print("CRITICAL: auto-restorer must be run as root.", file=sys.stderr)
        sys.exit(1)

    try:
        os.makedirs(os.path.dirname(LOGFILE), exist_ok=True)
        open(LOGFILE, "a").close()
    except OSError:
        pass

    argv = sys.argv[1:]
    # Pre-scan for --config so config values are available before parsing.
    cli_config = ""
    prev = ""
    for a in argv:
        if a.startswith("--config="):
            cli_config = a.split("=", 1)[1]
        elif prev in ("--config", "-c"):
            cli_config = a
        prev = a
    load_config(cli_config or DEFAULT_CONFIG_FILE)
    BACKUP_BASE = BACKUP_BASE.rstrip("/")

    if not argv:
        usage()
        sys.exit(1)
    parse_args(argv)
    if not MODE:
        usage()
        sys.exit(1)

    import atexit
    atexit.register(on_exit)

    # Lock only for the mutating restore; read-only modes run concurrently.
    if MODE == "restore":
        import fcntl

        # Serialize against the backup worker first: it holds
        # /var/lock/auto_backupper.lock for its whole run, including the
        # rotation phase that os.remove()s aged archives. Probe it
        # non-blockingly and refuse if active so a restore never reads an
        # archive rotation is deleting (an operator restore is not covered by
        # the cross-host "schedules never overlap" guarantee). Non-blocking,
        # not a wait: the worker unlinks its lockfile while still holding it, so
        # a waiter could win a stale inode while a fresh worker runs
        # unserialized. Open "a+" so we never truncate the worker's file, and
        # keep the FD for the restore's lifetime so a backup can't start.
        _worker_lock_fd = open("/var/lock/auto_backupper.lock", "a+")
        try:
            fcntl.flock(_worker_lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            print("ERROR: auto-backupper worker is active (holds its lock); refusing restore to avoid racing rotation. Retry once the backup finishes, or stop it first.", file=sys.stderr)
            sys.exit(1)

        # Open without truncating ("a+") so the previous PID stays readable
        # until we hold the lock; only then truncate + write our PID. Avoids the
        # empty-file window an observer (watchtower --ab-graph) could otherwise
        # catch between open and write.
        _lock_fd = open(LOCKFILE, "a+")
        try:
            fcntl.flock(_lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            print("ERROR: Another auto-restorer restore is already running (lockfile held).", file=sys.stderr)
            sys.exit(1)
        try:
            _lock_fd.seek(0)
            _lock_fd.truncate(0)
            _lock_fd.write(str(os.getpid()))
            _lock_fd.flush()
        except OSError:
            pass

    dispatch = {
        "list": cmd_list, "inspect": cmd_inspect, "verify": cmd_verify,
        "verify-all": cmd_verify_all, "corruption-report": cmd_corruption_report,
        "restore": cmd_restore, "prune-checksums": cmd_prune_checksums,
    }
    handler = dispatch.get(MODE)
    if not handler:
        print(f"ERROR: Unknown mode: {MODE}", file=sys.stderr)
        sys.exit(1)
    sys.exit(handler() or 0)


if __name__ == "__main__":
    main()
