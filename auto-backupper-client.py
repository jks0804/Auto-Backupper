#!/usr/bin/env python3
# ==============================================================================
# AUTO-BACKUPPER-CLIENT
# ==============================================================================
# Cross-platform desktop backup client for the Auto-Backupper suite.
#
# Runs on family/client Windows, macOS, and Linux PCs to replace the legacy
# Windows 7 backup feature. It produces TWO archives per machine -- a USER-data
# archive and a SYSTEM-state archive -- in the suite's exact FamilyBackups
# layout (./-rooted tar.gz + dated .checksums), then delivers them to one or
# more destinations (local/external drive, a mounted SMB/NFS share, or a push
# to the central server over rsync-over-SSH, typically across Tailscale/VPN).
# It can also restore archives locally. The output drops directly into the
# server's BACKUP_BASE/shares/FamilyBackups/<member>/{users,systems}/ tree, so
# the server's watchtower/auto-restorer treat it as a first-class backup.
#
# Unlike the server tools it does NOT shell out to tar/sha256sum/rsync for the
# core work (those are absent on Windows/macOS) -- it uses stdlib tarfile +
# hashlib while preserving the on-disk format byte-for-byte. It does NOT require
# root/admin: it degrades to the current user's profile with warnings when not
# elevated.
#
# USAGE:
#     python3 auto-backupper-client.py --backup [users|system|both]
#     python3 auto-backupper-client.py --restore ARCHIVE --target PATH [--only ./p]
#     python3 auto-backupper-client.py --list [PATTERN] | --verify ARCHIVE | --verify-all
#     python3 auto-backupper-client.py --inspect ARCHIVE
#     python3 auto-backupper-client.py --install-schedule | --uninstall-schedule
#
# OPTIONS:
#     -c, --config FILE   Config file (platform default if omitted)
#     --member NAME       Override the FamilyBackups <member> directory name
#     --dest NAME         Restrict delivery to named dest(s) from cfg (repeatable)
#     --target PATH       Restore destination
#     --only PATH         Partial restore member (repeatable; leading ./ honored)
#     --dry-run           Simulate; no writes or deliveries
#     --no-verify         Skip pre-restore checksum (discouraged)
#     --force             Skip confirmation prompts
#     --debug             Verbose logging
#     -h, --help          Show this help
#
# DEPENDENCIES:
#     Python 3.7+ (stdlib only for core logic). External binaries used only when
#     present: ssh/scp or rsync (for the rsync_ssh destination); on Windows
#     diskshadow/vssadmin + reg/winget/powershell (for VSS + system inventory).
# ==============================================================================

import os
import re
import sys
import glob
import shlex
import fnmatch
import shutil
import socket
import signal
import hashlib
import tarfile
import platform
import tempfile
import datetime
import subprocess

# ==============================================================================
# 1. BOOTSTRAP: PATHS & IDENTITY
# ==============================================================================
CHECKSUM_DIR = ".checksums"
TAR_EXT = ".tar.gz"
# Short hostname upper-cased -- the canonical casing the suite's writers use.
# A case-variant <member> dir would create unreconcilable parallel trees on a
# case-sensitive server, so the default never lowercases (config MEMBER_NAME=
# overrides). See warn on case drift in the server's warn_hostname_case_drift().
_DEFAULT_MEMBER = socket.gethostname().split(".")[0].upper()
CDATE = datetime.datetime.now().strftime("%Y%m%d")   # LOCAL date, matches the suite

LOG_MAX_SIZE = 10 * 1024 * 1024  # 10 MB
LOG_BACKUPS = 5

# verify_file()/archive return tokens (mirror the suite).
VERIFY_OK = "OK"
VERIFY_NO_FILE = "NO_FILE"
VERIFY_NO_CHECKSUM = "NO_CHECKSUM"
VERIFY_MISMATCH = "MISMATCH"
VERIFY_HASH_ERROR = "HASH_ERROR"

# Resolved per-OS at startup by resolve_paths(); placeholders here.
OS_TYPE = "linux"
LOGFILE = ""
LOCKFILE = ""
STATE_DIR = ""
DEFAULT_CONFIG_FILE = ""

# Runtime globals.
_LOCK_FD = None
_LOCK_HELD = False
CURRENT_ARCHIVE_FILE = None
MEMBER = _DEFAULT_MEMBER
# VSS bookkeeping (Windows). Persisted to the state dir so an orphaned snapshot
# from a SIGKILLed run is reaped on the next start.
_VSS_DRIVE = ""
_VSS_ID = ""

# CLI state.
MODE = ""
BACKUP_SCOPE = "both"            # users | system | both
RESTORE_ARCHIVE = ""
RESTORE_TARGET = ""
ONLY_PATHS = []
LIST_PATTERN = "*"
DEST_FILTER = []                 # names from --dest
NO_VERIFY = False
FORCE = False
# CLI flags that must win over the config file (which is loaded after argv).
_CLI_OVERRIDES = {}

# ==============================================================================
# 2. DEFAULT CONFIGURATION (bash-syntax cfg overrides; int-ish values are
#    strings, like the server cfg, and converted with _cfg_int).
# ==============================================================================
CONFIG = {
    "MEMBER_NAME": "",               # empty => _DEFAULT_MEMBER (UPPERCASE short hostname)
    "DRY_RUN": "false",
    "LOG_VERBOSITY": "info",         # error | phase | info | debug
    "CHECKSUM_DIR": ".checksums",

    # --- What to back up ---
    "BACKUP_USERS": "true",
    "BACKUP_SYSTEM": "true",
    "INCLUDE_ALL_USERS": "false",    # true needs admin/root
    "USERS_INCLUDE": [],             # empty => auto-detect
    "USER_INCLUDE_FOLDERS": [],      # empty => per-OS defaults
    "EXCLUDES": [],                  # appended to per-OS default excludes
    "SYSTEM_EXTRA_PATHS": [],

    # --- Windows locked-file strategy ---
    "USE_VSS": "true",
    "PRESERVE_POSIX_META": "true",   # macOS/Linux keep real uid/gid/mode

    # --- Destinations (index-aligned arrays; deliver to each) ---
    "DEST_NAMES": [],
    "DEST_TYPES": [],                # local | share | rsync_ssh
    "DEST_PATHS": [],               # server BACKUP_BASE for local/share
    "RSYNC_SSH_TARGET": "",          # user@host:/mnt/user/backup
    "RSYNC_SSH_IDENTITY": "",
    "RSYNC_SSH_PORT": "22",

    # --- Server tree (for restore pull / --list of remote archives) ---
    "SERVER_BACKUP_BASE": "",

    # --- Staging / retention ---
    "STAGING_DIR": "",
    "LOCAL_KEEP": "2",               # local/share copies to retain (0 = keep all)
    "ROTATE_DAYS": "0",              # 0 = server owns retention

    # --- Verify ---
    "VERIFY_AFTER_CREATE": "true",
    "VERIFY_BEFORE_RESTORE": "true",

    # --- Schedule (consumed by --install-schedule) ---
    "SCHEDULE_CADENCE": "daily",     # daily | weekly
    "SCHEDULE_TIME": "02:30",
    "SCHEDULE_DAY": "Sunday",
    "SCHEDULE_WAKE": "true",

    # --- Notifications ---
    "NOTIFY_WEBHOOK_URL": "",
    "NOTIFY_WEBHOOK_FORMAT": "",     # discord | slack | ntfy | generic
}


def is_dry():
    return CONFIG["DRY_RUN"] == "true"


def _cfg_int(key, default):
    try:
        return int(str(CONFIG.get(key, default)).strip())
    except (ValueError, TypeError):
        return default


def resolve_paths():
    # Per-OS default log/lock/state/config locations. Falls back to a writable
    # dir (with a warning) when the system location is not writable.
    global OS_TYPE, LOGFILE, LOCKFILE, STATE_DIR, DEFAULT_CONFIG_FILE
    if sys.platform == "win32":
        OS_TYPE = "windows"
        base = os.path.join(os.environ.get("ProgramData", r"C:\ProgramData"), "auto-backupper")
        LOGFILE = os.path.join(base, "auto-backupper-client.log")
        LOCKFILE = os.path.join(base, "auto-backupper-client.lock")
        STATE_DIR = os.path.join(base, "state")
        DEFAULT_CONFIG_FILE = os.path.join(base, "auto_backupper_client.cfg")
    elif sys.platform == "darwin":
        OS_TYPE = "macos"
        base = "/Library/Application Support/auto-backupper"
        LOGFILE = "/var/log/auto-backupper-client.log"
        LOCKFILE = os.path.join(base, "auto-backupper-client.lock")
        STATE_DIR = os.path.join(base, "state")
        DEFAULT_CONFIG_FILE = os.path.join(base, "auto_backupper_client.cfg")
    else:
        OS_TYPE = "linux"
        LOGFILE = "/var/log/auto-backupper-client.log"
        LOCKFILE = "/var/lock/auto-backupper-client.lock"
        STATE_DIR = "/var/lib/auto-backupper"
        DEFAULT_CONFIG_FILE = "/etc/auto-backupper/auto_backupper_client.cfg"


def _ensure_writable(path):
    # Return path if its parent dir is creatable/writable, else a temp fallback.
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        return path
    except OSError:
        fb = os.path.join(tempfile.gettempdir(), os.path.basename(path))
        return fb


# ==============================================================================
# 3. LOGGING (copytruncate rotation + verbosity tiers; UTC timestamps)
# ==============================================================================


def _log_verbosity_threshold():
    return {"error": 2, "phase": 3, "info": 4, "debug": 99}.get(
        CONFIG.get("LOG_VERBOSITY", "info"), 4
    )


def _log_level_for(msg):
    if re.match(r"^(FATAL|CRITICAL|ERROR:|ERROR |WARN:|WARN )", msg) or re.match(r"^\s+(WARN:|ERROR:)", msg):
        return 2
    if re.match(r"^(===|Phase:|Archiving:|ACTION:|RECOVERY:|SUCCESS:|NOTIFY|Delivering:)", msg):
        return 3
    return 4


def rotate_logs():
    if not LOGFILE or not os.path.isfile(LOGFILE):
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
        if LOGFILE:
            try:
                with open(LOGFILE, "a") as f:
                    f.write(line + "\n")
            except OSError:
                pass
    rotate_logs()


def setup_logging():
    global LOGFILE
    LOGFILE = _ensure_writable(LOGFILE)
    try:
        rotate_logs()
        open(LOGFILE, "a").close()
    except OSError:
        pass


# ==============================================================================
# 4. CONFIG LOADING (bash-syntax cfg parser -- ported verbatim from the suite)
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
        if key in CONFIG and isinstance(CONFIG[key], str):
            CONFIG[key] = _unquote(raw)

    for m in re.finditer(r"^[ \t]*([A-Za-z_][A-Za-z0-9_]*)=\((.*?)\)", content, re.M | re.S):
        key, body = m.group(1), m.group(2)
        if key in CONFIG and isinstance(CONFIG[key], list):
            try:
                CONFIG[key] = shlex.split(body, comments=True)
            except ValueError:
                pass


# ==============================================================================
# 5. NOTIFICATIONS (log always; best-effort OS-native + optional webhook)
# ==============================================================================


def _native_notify(level, title, message):
    try:
        if OS_TYPE == "linux" and shutil.which("notify-send"):
            subprocess.run(["notify-send", "-u", "normal", title, message],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        elif OS_TYPE == "macos" and shutil.which("osascript"):
            subprocess.run(["osascript", "-e",
                            f'display notification "{message}" with title "{title}"'],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        # Windows: a toast needs PowerShell + assemblies; skip to keep it quiet.
    except Exception:
        pass


def _webhook_notify(level, title, message):
    url = CONFIG.get("NOTIFY_WEBHOOK_URL", "")
    if not url:
        return
    import json
    import urllib.request
    host = MEMBER
    fmt = CONFIG.get("NOTIFY_WEBHOOK_FORMAT", "")
    if not fmt:
        if "discord" in url:
            fmt = "discord"
        elif "slack" in url:
            fmt = "slack"
        else:
            fmt = "generic"
    prefix = {"alert": "[ALERT]", "warning": "[WARN]", "normal": "[OK]"}.get(level, "[INFO]")
    if fmt == "discord":
        payload = {"username": f"Auto-Backupper-Client@{host}", "content": f"{prefix} **{title}**\n{message}"}
    elif fmt == "slack":
        payload = {"text": f"*{prefix} {title}*\n{message}\n_host: {host}_"}
    else:
        payload = {"host": host, "level": level, "title": title, "message": message,
                   "timestamp": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")}
    try:
        req = urllib.request.Request(url, data=json.dumps(payload).encode(),
                                     headers={"Content-Type": "application/json"})
        urllib.request.urlopen(req, timeout=10).read()
    except Exception:
        pass


def send_notify(level, title, message):
    if level in ("alert", "warning", "normal"):
        log(f"NOTIFY [{level}]: {title} - {message}")
    if is_dry():
        return
    _native_notify(level, title, message)
    _webhook_notify(level, title, message)


# ==============================================================================
# 6. PRIVILEGE DETECTION
# ==============================================================================


def is_privileged():
    # Admin on Windows, root on POSIX. Needed for all-users + VSS + some system
    # state; the client warns (never aborts) when not privileged.
    if OS_TYPE == "windows":
        try:
            import ctypes
            return bool(ctypes.windll.shell32.IsUserAnAdmin())
        except Exception:
            return False
    try:
        return os.geteuid() == 0
    except AttributeError:
        return False


# ==============================================================================
# 7. CHECKSUM + FORMAT LAYER (portable: tarfile + hashlib, byte-compatible with
#    the suite's tar -C base . / dated .checksums contract)
# ==============================================================================


def _rel_to_base(file_path, base):
    base = base.rstrip(os.sep).rstrip("/")
    norm = file_path
    if norm.startswith(base + os.sep) or norm.startswith(base + "/"):
        return norm[len(base) + 1:].replace(os.sep, "/")
    return os.path.basename(file_path)


def checksum_dir_for(file_path, base):
    rel = _rel_to_base(file_path, base)
    return os.path.join(base, CHECKSUM_DIR, os.path.dirname(rel).replace("/", os.sep))


def checksum_find_path(file_path, base):
    chk_dir = checksum_dir_for(file_path, base)
    name = os.path.basename(_rel_to_base(file_path, base))
    matches = glob.glob(os.path.join(chk_dir, name + "_" + "[0-9]" * 8 + ".sha256"))
    if not matches:
        return None
    return sorted(matches)[-1]


def sha256_of(path):
    # Streaming hashlib -- identical lowercase 64-hex to sha256sum's first column.
    try:
        h = hashlib.sha256()
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(1024 * 1024), b""):
                h.update(chunk)
        return h.hexdigest()
    except OSError:
        return None


def write_checksum(file_path, base):
    # Sweep stale dated siblings, then write one dated checksum atomically.
    # Written in binary so Windows text-mode never turns the trailing \n into
    # \r\n (the server writes a single \n).
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
        with open(tmp, "wb") as f:
            f.write((digest + "\n").encode("ascii"))
        os.replace(tmp, chk)
        return True
    except OSError:
        try:
            os.remove(tmp)
        except OSError:
            pass
        return False


def verify_file(file_path, base):
    if not os.path.isfile(file_path):
        return VERIFY_NO_FILE
    chk = checksum_find_path(file_path, base)
    if not chk:
        return VERIFY_NO_CHECKSUM
    try:
        with open(chk) as f:
            expected = "".join(f.read().split())
    except OSError:
        return VERIFY_NO_CHECKSUM
    actual = sha256_of(file_path)
    if actual is None:
        return VERIFY_HASH_ERROR
    return VERIFY_OK if expected == actual else VERIFY_MISMATCH


def write_manifest(out_path, archive_name, base_dir, source_paths, status="", notes=None):
    try:
        with open(out_path, "w", newline="") as f:
            f.write("# Auto-Backupper archive manifest\n")
            f.write(f"archive: {archive_name}\n")
            f.write(f"created_at: {datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')}\n")
            f.write(f"host: {MEMBER}\n")
            f.write(f"host_long: {platform.node()}\n")
            f.write(f"os: {OS_TYPE}\n")
            f.write(f"kernel: {' '.join(platform.uname()[:3])}\n")
            f.write(f"base_dir: {base_dir}\n")
            if status:
                f.write(f"status: {status}\n")
            f.write("source_paths:\n")
            for p in source_paths:
                f.write(f"  - {p}\n")
            if notes:
                f.write("notes:\n")
                for n in notes:
                    f.write(f"  - {n}\n")
            f.write("tools:\n")
            f.write("  compress: tarfile gzip\n")
            f.write(f"  python: {sys.version.split()[0]}\n")
        return True
    except OSError:
        return False


# Windows cloud-placeholder attribute bits (OneDrive/iCloud "online-only").
_FILE_ATTR_RECALL_ON_OPEN = 0x00040000
_FILE_ATTR_RECALL_ON_DATA_ACCESS = 0x00400000


def _is_cloud_placeholder(path):
    if OS_TYPE != "windows":
        return False
    try:
        attrs = os.stat(path, follow_symlinks=False).st_file_attributes
    except (OSError, AttributeError):
        return False
    return bool(attrs & (_FILE_ATTR_RECALL_ON_OPEN | _FILE_ATTR_RECALL_ON_DATA_ACCESS))


def _excluded(arcname, excludes):
    name = arcname[2:] if arcname.startswith("./") else arcname
    for pat in excludes:
        # A "X/*" pattern also excludes the directory X itself (not just its
        # contents), so an excluded cache dir doesn't leave an empty entry.
        cands = (pat, pat[:-2]) if pat.endswith("/*") else (pat,)
        for p in cands:
            if fnmatch.fnmatch(arcname, p) or fnmatch.fnmatch(name, p) or fnmatch.fnmatch("/" + name, p):
                return True
    return False


def _tar_filter(ti):
    # Normalize ownership/metadata so a Windows-authored archive restores
    # predictably under the Linux server's `tar -xpf --same-owner`, and skip
    # special files. On macOS/Linux keep real uid/gid/mode when configured.
    if ti.ischr() or ti.isblk() or ti.isfifo():
        return None
    if OS_TYPE == "windows" or CONFIG.get("PRESERVE_POSIX_META") != "true":
        ti.uid, ti.gid = 0, 0
        ti.uname, ti.gname = "", ""
        if ti.isdir():
            ti.mode = 0o755
        elif not ti.issym():
            ti.mode = 0o755 if (ti.mode & 0o111) else 0o644
    ti.name = ti.name.replace("\\", "/")
    return ti


def _iter_member_paths(src_root, arc_prefix, excludes):
    # Yield (abspath, arcname) for src_root mapped under arc_prefix, rooted with
    # a leading './' to match `tar -C base .`. Symlinks are stored as links (not
    # followed); reparse points / cloud placeholders are skipped.
    src_root = os.path.abspath(src_root)
    yield src_root, arc_prefix
    for root, dirs, files in os.walk(src_root, followlinks=False):
        # Prune symlinked/junction dirs (store the link, don't descend -> no loops)
        pruned = []
        for d in list(dirs):
            full = os.path.join(root, d)
            arc = arc_prefix + "/" + os.path.relpath(full, src_root).replace(os.sep, "/")
            if _excluded(arc, excludes):
                dirs.remove(d)
                continue
            if os.path.islink(full):
                pruned.append((full, arc))
                dirs.remove(d)
        for full, arc in pruned:
            yield full, arc
        for d in dirs:
            full = os.path.join(root, d)
            arc = arc_prefix + "/" + os.path.relpath(full, src_root).replace(os.sep, "/")
            yield full, arc
        for fn in files:
            full = os.path.join(root, fn)
            arc = arc_prefix + "/" + os.path.relpath(full, src_root).replace(os.sep, "/")
            if _excluded(arc, excludes):
                continue
            if _is_cloud_placeholder(full):
                log(f"  WARN: skipped cloud placeholder (online-only): {full}")
                continue
            yield full, arc


def create_archive(archive, sources, manifest_meta=None, excludes=None):
    # sources: list of (src_abspath, arc_prefix) -- arc_prefix is './' or './x'.
    # Builds <archive>.abpartial then atomically renames; embeds the MANIFEST as
    # the last member; writes a dated checksum against the STAGING base. Returns
    # True on success. Unreadable/locked files are logged and skipped.
    global CURRENT_ARCHIVE_FILE
    excludes = excludes or []
    os.makedirs(os.path.dirname(archive), exist_ok=True)
    CURRENT_ARCHIVE_FILE = archive
    log(f"Archiving: {archive}")
    if is_dry():
        for s, p in sources:
            log(f"[DRY]   add {s} as {p}")
        CURRENT_ARCHIVE_FILE = None
        return True

    skipped = 0
    partial = archive + ".abpartial"
    manifest_dir = ""
    try:
        tf = tarfile.open(partial, "w:gz", format=tarfile.GNU_FORMAT, compresslevel=6)
    except OSError as e:
        log(f"ERROR: Could not open archive for write: {e}")
        CURRENT_ARCHIVE_FILE = None
        return False
    try:
        for src_root, arc_prefix in sources:
            if not os.path.exists(src_root):
                continue
            for full, arc in _iter_member_paths(src_root, arc_prefix, excludes):
                try:
                    tf.add(full, arcname=arc, recursive=False, filter=_tar_filter)
                except (PermissionError, OSError) as e:
                    skipped += 1
                    log(f"  WARN: skipped unreadable {full}: {e}")
        # Manifest last (matches the server's interleaved -C append).
        try:
            manifest_dir = tempfile.mkdtemp(prefix="abclient_manifest.")
            mpath = os.path.join(manifest_dir, "MANIFEST.txt")
            meta = manifest_meta or {}
            if write_manifest(mpath, os.path.basename(archive),
                              meta.get("base_dir", ""), meta.get("source_paths", []),
                              meta.get("status", ""), meta.get("notes")):
                tf.add(mpath, arcname=".auto-backupper/MANIFEST.txt", recursive=False)
        except OSError:
            pass
    finally:
        tf.close()
        if manifest_dir:
            shutil.rmtree(manifest_dir, ignore_errors=True)

    try:
        os.replace(partial, archive)
    except OSError as e:
        log(f"ERROR: Archive finalize failed: {e}")
        try:
            os.remove(partial)
        except OSError:
            pass
        CURRENT_ARCHIVE_FILE = None
        return False

    if skipped:
        log(f"  {skipped} file(s) skipped (unreadable/locked).")
    write_checksum(archive, STAGING_BASE)
    CURRENT_ARCHIVE_FILE = None
    return True


# ==============================================================================
# 8. COLLECTION LAYER (per-OS user data + system state; Windows VSS)
# ==============================================================================


def _default_user_folders():
    if OS_TYPE == "windows":
        return ["Documents", "Desktop", "Pictures", "Downloads", "Music", "Videos",
                "Favorites", "AppData/Roaming"]
    if OS_TYPE == "macos":
        return ["Documents", "Desktop", "Pictures", "Movies", "Music", "Downloads",
                "Library/Preferences", "Library/Application Support"]
    return []   # Linux: empty => whole home minus excludes


def _default_excludes():
    common = ["*.tmp", "*/Cache/*", "*/Caches/*", "*/.cache/*", "*/Code Cache/*",
              "*/GPUCache/*", "Thumbs.db", "*/.DS_Store"]
    if OS_TYPE == "windows":
        common += ["*/AppData/Local/Temp/*", "*/AppData/LocalLow/*"]
    elif OS_TYPE == "macos":
        common += ["*/Library/Caches/*", "*.app", "*/Library/Application Support/MobileSync/*"]
    else:
        common += ["*/.local/share/Trash/*", "*/.thumbnails/*",
                   "*/.mozilla/firefox/*/cache2/*", "*/.config/*/Cache/*"]
    return common


def detect_homes():
    # Returns [(user_label, home_path)]. Honors USERS_INCLUDE; else auto-detects.
    include = CONFIG["USERS_INCLUDE"]
    all_users = CONFIG["INCLUDE_ALL_USERS"] == "true"
    homes = []
    if include:
        for u in include:
            if os.path.isdir(u):                       # an explicit home path
                homes.append((os.path.basename(u.rstrip("/\\")), u))
            else:                                       # a username
                p = _home_for_user(u)
                if p and os.path.isdir(p):
                    homes.append((u, p))
        return homes

    if OS_TYPE == "windows":
        users_root = os.path.join(os.environ.get("SystemDrive", "C:") + os.sep, "Users")
        skip = {"Default", "Default User", "Public", "All Users", "DefaultAppPool",
                "WDAGUtilityAccount", "defaultuser0"}
        if all_users and os.path.isdir(users_root):
            for name in os.listdir(users_root):
                p = os.path.join(users_root, name)
                if name not in skip and os.path.isdir(p):
                    homes.append((name, p))
        else:
            up = os.environ.get("USERPROFILE")
            if up:
                homes.append((os.path.basename(up), up))
    else:
        if all_users and is_privileged():
            roots = "/Users" if OS_TYPE == "macos" else "/home"
            mac_skip = {"Shared", "Guest"}
            if os.path.isdir(roots):
                for name in os.listdir(roots):
                    p = os.path.join(roots, name)
                    if os.path.isdir(p) and not (OS_TYPE == "macos" and name in mac_skip):
                        homes.append((name, p))
        if not homes:
            h = os.path.expanduser("~")
            homes.append((os.path.basename(h), h))
    return homes


def _home_for_user(user):
    if OS_TYPE == "windows":
        return os.path.join(os.environ.get("SystemDrive", "C:") + os.sep, "Users", user)
    if OS_TYPE == "macos":
        return os.path.join("/Users", user)
    return os.path.join("/home", user)


def collect_user_sources(snapshot_root=None):
    # Build the (src, arcname) source list for the USER archive directly from
    # the live filesystem (no bulk staging). When a VSS snapshot is exposed
    # (Windows), read from it but keep the real path in the arcname.
    folders = CONFIG["USER_INCLUDE_FOLDERS"] or _default_user_folders()
    sources = []
    for label, home in detect_homes():
        read_home = home
        if snapshot_root and OS_TYPE == "windows" and len(home) > 2 and home[1] == ":":
            read_home = snapshot_root + home[2:]        # C:\Users\x -> <snap>\Users\x
        if not folders:                                  # whole home (Linux default)
            if os.path.isdir(read_home):
                sources.append((read_home, "./" + label))
        else:
            for f in folders:
                p = os.path.join(read_home, f.replace("/", os.sep))
                if os.path.exists(p):
                    sources.append((p, "./" + label + "/" + f.replace("\\", "/")))
    return sources


def _cap(stage, relpath, cmd, shell_input=None):
    # Run cmd, capture stdout to stage/relpath. Tolerant: logs+continues.
    dest = os.path.join(stage, relpath)
    try:
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=300, input=shell_input)
        with open(dest, "w", newline="") as f:
            f.write(r.stdout or "")
            if r.stderr:
                f.write("\n# stderr:\n" + r.stderr)
        return r.returncode == 0
    except Exception as e:
        log(f"  WARN: system collector failed ({' '.join(cmd[:2])}...): {e}")
        return False


def collect_system_stage(stage):
    # Populate a staging dir with system config/state. Returns (ok, notes,
    # incomplete) where incomplete=True means a degraded (non-elevated) capture.
    notes = []
    incomplete = False
    os.makedirs(stage, exist_ok=True)
    if OS_TYPE == "windows":
        incomplete = _collect_system_windows(stage, notes)
    elif OS_TYPE == "macos":
        _collect_system_macos(stage, notes)
    else:
        incomplete = _collect_system_linux(stage, notes)
    for extra in CONFIG["SYSTEM_EXTRA_PATHS"]:
        if os.path.exists(extra):
            dst = os.path.join(stage, "extra", os.path.basename(extra.rstrip("/\\")))
            try:
                if os.path.isdir(extra):
                    shutil.copytree(extra, dst, symlinks=True, ignore_errors=True)
                else:
                    os.makedirs(os.path.dirname(dst), exist_ok=True)
                    shutil.copy2(extra, dst)
            except OSError as e:
                log(f"  WARN: could not copy extra path {extra}: {e}")
    return True, notes, incomplete


def _collect_system_windows(stage, notes):
    incomplete = False
    reg = os.path.join(stage, "registry")
    os.makedirs(reg, exist_ok=True)
    for hive in ("SOFTWARE", "SYSTEM"):
        _run_quiet(["reg", "save", f"HKLM\\{hive}", os.path.join(reg, f"{hive}.hiv"), "/y"])
    if is_privileged():
        for hive in ("SAM", "SECURITY"):
            _run_quiet(["reg", "save", f"HKLM\\{hive}", os.path.join(reg, f"{hive}.hiv"), "/y"])
    else:
        incomplete = True
        notes.append("registry SAM/SECURITY hives skipped (not elevated)")
        log("  WARN: not elevated -- SAM/SECURITY hives skipped; system archive is INCOMPLETE.")
    # Installed programs + system info (PowerShell CIM preferred over deprecated wmic).
    ps = "powershell"
    _cap(stage, "installed/get-package.csv",
         [ps, "-NoProfile", "-Command", "Get-Package | Select-Object Name,Version,ProviderName | ConvertTo-Csv -NoTypeInformation"])
    if shutil.which("winget"):
        _run_quiet(["winget", "export", "-o", os.path.join(stage, "installed", "winget.json"),
                    "--accept-source-agreements"])
    _cap(stage, "info/computerinfo.json",
         [ps, "-NoProfile", "-Command", "Get-ComputerInfo | Select-Object WindowsProductName,OsVersion,OsBuildNumber,OsArchitecture | ConvertTo-Json"])
    _cap(stage, "info/services.csv", [ps, "-NoProfile", "-Command", "Get-Service | Select-Object Name,Status,StartType | ConvertTo-Csv -NoTypeInformation"])
    _cap(stage, "network/ipconfig.txt", ["ipconfig", "/all"])
    return incomplete


def _collect_system_macos(stage, notes):
    _cap(stage, "info/sw_vers.txt", ["sw_vers"])
    _cap(stage, "installed/applications.txt", ["ls", "-1", "/Applications"])
    if shutil.which("brew"):
        _cap(stage, "installed/brew_leaves.txt", ["brew", "leaves"])
        _run_quiet(["brew", "bundle", "dump", f"--file={os.path.join(stage, 'installed', 'Brewfile')}", "--force"])
    for etc in ("/etc/hosts", "/etc/shells", "/etc/ssh/sshd_config"):
        if os.path.isfile(etc):
            try:
                d = os.path.join(stage, "etc", etc.lstrip("/"))
                os.makedirs(os.path.dirname(d), exist_ok=True)
                shutil.copy2(etc, d)
            except OSError:
                pass
    # Full Disk Access probe (cannot be auto-granted).
    probe = os.path.expanduser("~/Library/Safari/Bookmarks.plist")
    if os.path.exists(probe):
        try:
            open(probe, "rb").close()
        except PermissionError:
            notes.append("Full Disk Access not granted (Mail/Messages/Safari not captured)")
            send_notify("warning", "Full Disk Access required",
                        "Grant Full Disk Access to your terminal/Python in System Settings to back up Mail/Safari/Messages.")


def _collect_system_linux(stage, notes):
    incomplete = False
    # /etc (skip shadow files unless root).
    etc_dst = os.path.join(stage, "etc")
    try:
        def _ign(d, names):
            if not is_privileged():
                return [n for n in names if n.startswith(("shadow", "gshadow"))]
            return []
        shutil.copytree("/etc", etc_dst, symlinks=True, ignore=_ign, ignore_dangling_symlinks=True)
    except (OSError, shutil.Error) as e:
        log(f"  WARN: /etc copy partial: {e}")
    if not is_privileged():
        incomplete = True
        notes.append("/etc shadow files skipped (not root)")
    for tool, args, out in (
        ("dpkg", ["dpkg", "--get-selections"], "pkgs.dpkg"),
        ("rpm", ["rpm", "-qa"], "pkgs.rpm"),
        ("pacman", ["pacman", "-Qqe"], "pkgs.pacman"),
        ("flatpak", ["flatpak", "list", "--app", "--columns=application"], "pkgs.flatpak"),
        ("snap", ["snap", "list"], "pkgs.snap"),
    ):
        if shutil.which(tool):
            _cap(stage, os.path.join("packages", out), args)
    if shutil.which("systemctl"):
        _cap(stage, "services/systemd-enabled.txt", ["systemctl", "list-unit-files", "--state=enabled", "--no-pager"])
    if shutil.which("ip"):
        _cap(stage, "network/ip-addr.txt", ["ip", "addr"])
    return incomplete


def _run_quiet(cmd):
    try:
        subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=300)
        return True
    except Exception:
        return False


# --- Windows VSS (locked files) ---


def vss_create():
    # Returns the exposed snapshot root (e.g. 'Z:') or None. Best-effort; the
    # caller falls back to a live copy with skip+warn.
    global _VSS_DRIVE, _VSS_ID
    if OS_TYPE != "windows" or CONFIG["USE_VSS"] != "true":
        return None
    if not is_privileged():
        log("  WARN: not elevated -- VSS unavailable; locked files (NTUSER.DAT, browser/Outlook) will be skipped.")
        return None
    drive = _free_drive_letter()
    if not drive:
        return None
    script = (f"SET CONTEXT VOLATILE\n"
              f"BEGIN BACKUP\n"
              f"ADD VOLUME C: ALIAS sysvol\n"
              f"CREATE\n"
              f"EXPOSE %sysvol% {drive}\n"
              f"END BACKUP\n")
    sf = os.path.join(tempfile.gettempdir(), "abclient_vss.dsh")
    try:
        with open(sf, "w") as f:
            f.write(script)
        r = subprocess.run(["diskshadow", "/s", sf], capture_output=True, text=True, timeout=300)
        out = (r.stdout or "") + (r.stderr or "")
        m = re.search(r"(\{[0-9a-fA-F-]{36}\})", out)
        _VSS_ID = m.group(1) if m else ""
        _VSS_DRIVE = drive
        _save_vss_state()
        if os.path.isdir(drive + os.sep):
            log(f"  VSS snapshot exposed at {drive}")
            return drive
        log("  WARN: VSS create did not expose a drive; falling back to live copy.")
    except Exception as e:
        log(f"  WARN: VSS create failed: {e}; falling back to live copy.")
    finally:
        try:
            os.remove(sf)
        except OSError:
            pass
    return None


def vss_cleanup():
    global _VSS_DRIVE, _VSS_ID
    if OS_TYPE != "windows" or not (_VSS_DRIVE or _VSS_ID):
        return
    script = "SET CONTEXT VOLATILE\n"
    if _VSS_DRIVE:
        script += f"UNEXPOSE {_VSS_DRIVE}\n"
    if _VSS_ID:
        script += f"DELETE SHADOWS ID {_VSS_ID}\n"
    sf = os.path.join(tempfile.gettempdir(), "abclient_vss_del.dsh")
    try:
        with open(sf, "w") as f:
            f.write(script)
        subprocess.run(["diskshadow", "/s", sf], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=120)
    except Exception:
        pass
    finally:
        try:
            os.remove(sf)
        except OSError:
            pass
    _VSS_DRIVE, _VSS_ID = "", ""
    _save_vss_state()


def _vss_state_file():
    return os.path.join(STATE_DIR, "vss_shadow")


def _save_vss_state():
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        with open(_vss_state_file(), "w") as f:
            f.write(f"{_VSS_DRIVE}\n{_VSS_ID}\n")
    except OSError:
        pass


def vss_reap_orphan():
    # On startup, delete any snapshot orphaned by a prior SIGKILL.
    global _VSS_DRIVE, _VSS_ID
    sf = _vss_state_file()
    if OS_TYPE != "windows" or not os.path.isfile(sf):
        return
    try:
        parts = open(sf).read().splitlines()
        _VSS_DRIVE = parts[0] if len(parts) > 0 else ""
        _VSS_ID = parts[1] if len(parts) > 1 else ""
    except OSError:
        return
    if _VSS_DRIVE or _VSS_ID:
        log("RECOVERY: reaping orphaned VSS snapshot from a prior run.")
        vss_cleanup()


def _free_drive_letter():
    import string
    for c in "ZYXWVUT":
        if not os.path.exists(c + ":" + os.sep):
            return c + ":"
    return None


# ==============================================================================
# 9. STAGING + PRODUCE
# ==============================================================================

STAGING_BASE = ""        # resolved at backup time; the .checksums base
PRODUCED = []            # [{archive, archive_rel, checksum, checksum_rel, sub}]


def _member_paths(sub):
    # (archive_path, archive_rel) for a sub ("users"|"systems") under STAGING.
    name = f"{MEMBER}_{sub}_{CDATE}{TAR_EXT}"
    rel = "/".join(["shares", "FamilyBackups", MEMBER, sub, name])
    return os.path.join(STAGING_BASE, rel.replace("/", os.sep)), rel


def produce_backup():
    global STAGING_BASE, PRODUCED
    PRODUCED = []
    STAGING_BASE = CONFIG["STAGING_DIR"] or os.path.join(tempfile.gettempdir(), "auto-backupper-staging")
    if not is_dry():
        shutil.rmtree(STAGING_BASE, ignore_errors=True)
        os.makedirs(STAGING_BASE, exist_ok=True)
    excludes = _default_excludes() + CONFIG["EXCLUDES"]
    log(f"=== Backup: member={MEMBER} scope={BACKUP_SCOPE} os={OS_TYPE} staging={STAGING_BASE} ===")

    do_users = BACKUP_SCOPE in ("users", "both") and CONFIG["BACKUP_USERS"] == "true"
    do_system = BACKUP_SCOPE in ("system", "both") and CONFIG["BACKUP_SYSTEM"] == "true"
    snapshot = None
    try:
        if do_system or (do_users and OS_TYPE == "windows"):
            snapshot = vss_create()

        if do_users:
            log("Phase: USER data archive")
            sources = collect_user_sources(snapshot)
            if not sources:
                log("  WARN: no user sources resolved; skipping users archive.")
            else:
                archive, rel = _member_paths("users")
                meta = {"base_dir": f"FamilyBackups/{MEMBER}/users",
                        "source_paths": [s for s, _ in sources]}
                if create_archive(archive, sources, meta, excludes):
                    _record(archive, rel, "users")

        if do_system:
            log("Phase: SYSTEM state archive")
            stage = os.path.join(tempfile.mkdtemp(prefix="abclient_sys."), "system")
            try:
                if is_dry():
                    log("[DRY]   collect system state")
                    notes, incomplete = [], False
                else:
                    _, notes, incomplete = collect_system_stage(stage)
                archive, rel = _member_paths("systems")
                meta = {"base_dir": f"FamilyBackups/{MEMBER}/systems",
                        "source_paths": ["(generated system state)"],
                        "status": "SYSTEM_INCOMPLETE" if incomplete else "",
                        "notes": notes}
                if create_archive(archive, [(stage, ".")], meta, excludes):
                    _record(archive, rel, "systems")
                    if incomplete:
                        send_notify("warning", "System backup incomplete",
                                    f"{MEMBER}: system archive is degraded ({'; '.join(notes)}). Run elevated for a complete capture.")
            finally:
                shutil.rmtree(os.path.dirname(stage), ignore_errors=True)
    finally:
        vss_cleanup()

    return bool(PRODUCED) or is_dry()


def _record(archive, archive_rel, sub):
    chk_rel = "/".join([CHECKSUM_DIR] + archive_rel.split("/")[:-1] + [os.path.basename(archive) + f"_{CDATE}.sha256"])
    chk = os.path.join(STAGING_BASE, chk_rel.replace("/", os.sep))
    PRODUCED.append({"archive": archive, "archive_rel": archive_rel,
                     "checksum": chk, "checksum_rel": chk_rel, "sub": sub})


# ==============================================================================
# 10. DELIVERY LAYER (local | share | rsync_ssh; data before checksum)
# ==============================================================================


def _destinations():
    names = CONFIG["DEST_NAMES"]
    types = CONFIG["DEST_TYPES"]
    paths = CONFIG["DEST_PATHS"]
    out = []
    for i, name in enumerate(names):
        dtype = types[i] if i < len(types) else "local"
        dpath = paths[i] if i < len(paths) else ""
        if DEST_FILTER and name not in DEST_FILTER:
            continue
        out.append({"name": name, "type": dtype, "path": dpath})
    return out


def deliver_all():
    dests = _destinations()
    if not dests:
        log("WARN: no destinations configured; archives remain in staging only.")
        return True
    ok_all = True
    for dest in dests:
        log(f"Delivering: -> {dest['name']} ({dest['type']})")
        try:
            if dest["type"] in ("local", "share"):
                ok = _deliver_fs(dest)
            elif dest["type"] == "rsync_ssh":
                ok = _deliver_ssh(dest)
            else:
                log(f"  ERROR: unknown dest type '{dest['type']}'")
                ok = False
        except Exception as e:
            log(f"  ERROR: delivery to {dest['name']} failed: {e}")
            ok = False
        ok_all = ok_all and ok
        if ok and not is_dry():
            _prune_local(dest)
    return ok_all


def _deliver_fs(dest):
    base = dest["path"].rstrip("/\\")
    if not base:
        log("  ERROR: destination path is empty.")
        return False
    if is_dry():
        for item in PRODUCED:
            log(f"[DRY]   copy {item['archive_rel']} -> {base}")
        return True
    if not os.path.isdir(base):
        try:
            os.makedirs(base, exist_ok=True)
        except OSError as e:
            log(f"  ERROR: cannot create destination {base}: {e}")
            return False
    ok = True
    for item in PRODUCED:
        # Data first (.abpartial -> rename), then the checksum.
        if not _copy_atomic(item["archive"], os.path.join(base, item["archive_rel"].replace("/", os.sep))):
            ok = False
            continue
        if CONFIG["VERIFY_AFTER_CREATE"] == "true":
            dst_arch = os.path.join(base, item["archive_rel"].replace("/", os.sep))
            if not _verify_delivered(item, dst_arch):
                _remove_quiet(dst_arch)
                ok = False
                continue
        _copy_atomic(item["checksum"], os.path.join(base, item["checksum_rel"].replace("/", os.sep)))
    return ok


def _verify_delivered(item, dst_arch):
    expected = None
    try:
        with open(item["checksum"]) as f:
            expected = "".join(f.read().split())
    except OSError:
        pass
    actual = sha256_of(dst_arch)
    if expected and actual == expected:
        return True
    log(f"  ERROR: post-delivery checksum mismatch for {item['archive_rel']}")
    return False


def _copy_atomic(src, dst):
    try:
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        tmp = dst + ".abpartial"
        shutil.copy2(src, tmp)
        os.replace(tmp, dst)
        return True
    except OSError as e:
        try:
            shutil.move(src, dst)
            return True
        except (OSError, shutil.Error):
            log(f"  ERROR: copy failed {src} -> {dst}: {e}")
            return False


def _deliver_ssh(dest):
    target = CONFIG["RSYNC_SSH_TARGET"]
    if not target:
        log("  ERROR: RSYNC_SSH_TARGET not set.")
        return False
    if is_dry():
        log(f"[DRY]   push staging -> {target}")
        return True
    identity = CONFIG["RSYNC_SSH_IDENTITY"]
    port = CONFIG["RSYNC_SSH_PORT"]
    ssh = f"ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -p {port}"
    if identity:
        ssh += f" -i {shlex.quote(identity)}"
    if shutil.which("rsync"):
        opts = ["rsync", "-a", "--compress", "--human-readable", "--omit-dir-times",
                "--partial-dir=.abpartial", "--timeout=60", "-e", ssh]
        # Data subtree first, then checksums -- so the server never sees a
        # checksum before its archive.
        for sub in ("shares", CHECKSUM_DIR):
            srcdir = os.path.join(STAGING_BASE, sub)
            if not os.path.isdir(srcdir):
                continue
            r = subprocess.run(opts + [srcdir + "/", f"{target}/{sub}/"])
            if r.returncode not in (0, 24):
                log(f"  ERROR: rsync of {sub}/ failed (code {r.returncode}).")
                return False
        return True
    if shutil.which("scp"):
        return _deliver_scp(target, ssh, port, identity)
    log("  ERROR: neither rsync nor scp available for rsync_ssh delivery (install OpenSSH).")
    return False


def _deliver_scp(target, ssh, port, identity):
    # Fallback for Windows without rsync: scp each file to a temp name, then
    # `ssh mv` for an atomic rename on the server. target is user@host:/base.
    try:
        userhost, rbase = target.split(":", 1)
    except ValueError:
        log("  ERROR: RSYNC_SSH_TARGET must be user@host:/path")
        return False
    scp_base = ["scp", "-P", port, "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new"]
    ssh_base = ["ssh", "-p", port, "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new"]
    if identity:
        scp_base += ["-i", identity]
        ssh_base += ["-i", identity]
    ok = True
    for item in PRODUCED:
        for key, rel in (("archive", item["archive_rel"]), ("checksum", item["checksum_rel"])):
            rpath = rbase.rstrip("/") + "/" + rel
            rdir = rpath.rsplit("/", 1)[0]
            subprocess.run(ssh_base + [userhost, f"mkdir -p {shlex.quote(rdir)}"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            rtmp = rpath + ".abpartial"
            if subprocess.run(scp_base + [item[key], f"{userhost}:{rtmp}"]).returncode != 0:
                log(f"  ERROR: scp failed for {rel}")
                ok = False
                break
            subprocess.run(ssh_base + [userhost, f"mv -f {shlex.quote(rtmp)} {shlex.quote(rpath)}"])
    return ok


def _prune_local(dest):
    # Keep only the newest LOCAL_KEEP data archives per sub at a local/share dest
    # (checksums are retained as the suite's historical index).
    keep = _cfg_int("LOCAL_KEEP", 2)
    if keep <= 0 or dest["type"] not in ("local", "share"):
        return
    base = dest["path"].rstrip("/\\")
    for sub in ("users", "systems"):
        d = os.path.join(base, "shares", "FamilyBackups", MEMBER, sub)
        if not os.path.isdir(d):
            continue
        arcs = sorted(glob.glob(os.path.join(d, f"{MEMBER}_{sub}_" + "[0-9]" * 8 + TAR_EXT)))
        for old in arcs[:-keep]:
            _remove_quiet(old)
            log(f"  Pruned old local copy: {os.path.basename(old)}")


def _remove_quiet(path):
    try:
        os.remove(path)
    except OSError:
        pass


# ==============================================================================
# 11. PRE-FLIGHT
# ==============================================================================


def preflight():
    log("Phase: Pre-flight checks")
    dests = _destinations()
    if not dests and MODE == "backup":
        log("WARN: no destinations configured.")
    for dest in dests:
        if dest["type"] in ("local", "share"):
            base = dest["path"].rstrip("/\\")
            parent = base if os.path.isdir(base) else os.path.dirname(base) or "."
            if not is_dry() and os.path.isdir(parent) and not os.access(parent, os.W_OK):
                log(f"WARN: destination '{base}' may not be writable.")
        elif dest["type"] == "rsync_ssh":
            if not CONFIG["RSYNC_SSH_TARGET"]:
                log("WARN: rsync_ssh destination has no RSYNC_SSH_TARGET.")
    # Free space at staging (best-effort).
    stg = CONFIG["STAGING_DIR"] or tempfile.gettempdir()
    try:
        free = shutil.disk_usage(stg).free
        log(f"  Staging free space: {_human(free)} at {stg}")
    except OSError:
        pass
    if not is_privileged():
        log("WARN: not elevated -- all-users data, VSS, and full system state are limited. "
            "Run as admin/root for a complete whole-machine backup.")
    return True


def _human(b):
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if b < 1024 or unit == "TB":
            return f"{b:.1f}{unit}"
        b /= 1024.0


# ==============================================================================
# 12. SCHEDULER INSTALL / UNINSTALL (native per OS)
# ==============================================================================

_TASK_NAME = "AutoBackupperClient"


def _schedule_command():
    py = sys.executable
    if OS_TYPE == "windows":
        cand = os.path.join(os.path.dirname(py), "pythonw.exe")
        if os.path.isfile(cand):
            py = cand
    script = os.path.abspath(sys.argv[0])
    cfg = CONFIG.get("_LOADED_CONFIG", DEFAULT_CONFIG_FILE)
    return py, script, cfg


def install_schedule():
    cadence = CONFIG["SCHEDULE_CADENCE"]
    tm = CONFIG["SCHEDULE_TIME"]
    py, script, cfg = _schedule_command()
    log(f"Installing {cadence} schedule at {tm} ({OS_TYPE}).")
    if OS_TYPE == "windows":
        return _install_windows(py, script, cfg, cadence, tm)
    if OS_TYPE == "macos":
        return _install_macos(py, script, cfg, tm)
    return _install_linux(py, script, cfg, tm)


def uninstall_schedule():
    log(f"Uninstalling schedule ({OS_TYPE}).")
    if OS_TYPE == "windows":
        return _run_quiet(["schtasks", "/delete", "/tn", _TASK_NAME, "/f"])
    if OS_TYPE == "macos":
        plist = "/Library/LaunchDaemons/com.auto-backupper.client.plist"
        _run_quiet(["launchctl", "bootout", "system", plist])
        _remove_quiet(plist)
        return True
    _run_quiet(["systemctl", "disable", "--now", "auto-backupper-client.timer"])
    for u in ("auto-backupper-client.timer", "auto-backupper-client.service"):
        _remove_quiet(os.path.join("/etc/systemd/system", u))
    _run_quiet(["systemctl", "daemon-reload"])
    return True


def _install_windows(py, script, cfg, cadence, tm):
    hh, mm = (tm.split(":") + ["00"])[:2]
    sched = "DAILY" if cadence == "daily" else "WEEKLY"
    args = f'"{script}" --backup both --config "{cfg}"'
    xml = f"""<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>Auto-Backupper desktop client</Description></RegistrationInfo>
  <Triggers><CalendarTrigger><StartBoundary>2026-01-01T{hh}:{mm}:00</StartBoundary>
    <ScheduleByDay><DaysInterval>1</DaysInterval></ScheduleByDay></CalendarTrigger></Triggers>
  <Principals><Principal id="Author"><UserId>S-1-5-18</UserId><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
  <Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <WakeToRun>{'true' if CONFIG['SCHEDULE_WAKE'] == 'true' else 'false'}</WakeToRun>
    <StartWhenAvailable>true</StartWhenAvailable><ExecutionTimeLimit>PT4H</ExecutionTimeLimit></Settings>
  <Actions Context="Author"><Exec><Command>{py}</Command><Arguments>{args}</Arguments></Exec></Actions>
</Task>"""
    xf = os.path.join(tempfile.gettempdir(), "abclient_task.xml")
    try:
        with open(xf, "w", encoding="utf-16") as f:
            f.write(xml)
        rc = subprocess.run(["schtasks", "/create", "/tn", _TASK_NAME, "/xml", xf, "/f"]).returncode
        return rc == 0
    except Exception as e:
        log(f"ERROR: schtasks install failed: {e}")
        return False
    finally:
        _remove_quiet(xf)


def _install_macos(py, script, cfg, tm):
    hh, mm = (tm.split(":") + ["00"])[:2]
    plist = "/Library/LaunchDaemons/com.auto-backupper.client.plist"
    body = f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.auto-backupper.client</string>
  <key>ProgramArguments</key><array>
    <string>{py}</string><string>{script}</string>
    <string>--backup</string><string>both</string>
    <string>--config</string><string>{cfg}</string></array>
  <key>StartCalendarInterval</key><dict><key>Hour</key><integer>{int(hh)}</integer><key>Minute</key><integer>{int(mm)}</integer></dict>
  <key>StandardOutPath</key><string>/var/log/auto-backupper-client.log</string>
  <key>StandardErrorPath</key><string>/var/log/auto-backupper-client.log</string>
  <key>RunAtLoad</key><false/>
</dict></plist>"""
    try:
        with open(plist, "w") as f:
            f.write(body)
        _run_quiet(["launchctl", "bootout", "system", plist])
        rc = subprocess.run(["launchctl", "bootstrap", "system", plist]).returncode
        log("NOTE: launchd does not catch up missed runs; an asleep Mac runs at the next scheduled time.")
        return rc == 0
    except OSError as e:
        log(f"ERROR: launchd install failed (need sudo?): {e}")
        return False


def _install_linux(py, script, cfg, tm):
    hh, mm = (tm.split(":") + ["00"])[:2]
    if not shutil.which("systemctl"):
        return _install_cron(py, script, cfg, hh, mm)
    svc = ("[Unit]\nDescription=Auto-Backupper desktop client\n\n"
           "[Service]\nType=oneshot\n"
           f"ExecStart={py} {script} --backup both --config {cfg}\n")
    timer = ("[Unit]\nDescription=Run Auto-Backupper client\n\n"
             f"[Timer]\nOnCalendar=*-*-* {hh}:{mm}:00\nPersistent=true\n"
             f"{'WakeSystem=true' if CONFIG['SCHEDULE_WAKE'] == 'true' else ''}\n\n"
             "[Install]\nWantedBy=timers.target\n")
    try:
        with open("/etc/systemd/system/auto-backupper-client.service", "w") as f:
            f.write(svc)
        with open("/etc/systemd/system/auto-backupper-client.timer", "w") as f:
            f.write(timer)
        _run_quiet(["systemctl", "daemon-reload"])
        rc = subprocess.run(["systemctl", "enable", "--now", "auto-backupper-client.timer"]).returncode
        return rc == 0
    except OSError as e:
        log(f"ERROR: systemd install failed (need sudo?): {e}")
        return False


def _install_cron(py, script, cfg, hh, mm):
    line = f"{int(mm)} {int(hh)} * * * {py} {script} --backup both --config {cfg}\n"
    try:
        existing = subprocess.run(["crontab", "-l"], capture_output=True, text=True).stdout
    except OSError:
        existing = ""
    existing = "\n".join(l for l in existing.splitlines() if "auto-backupper-client" not in l)
    new = (existing + "\n" + line).strip() + "\n"
    try:
        p = subprocess.run(["crontab", "-"], input=new, text=True)
        return p.returncode == 0
    except OSError as e:
        log(f"ERROR: cron install failed: {e}")
        return False


# ==============================================================================
# 13. RESTORE / LIST / VERIFY / INSPECT (portable, stdlib tarfile)
# ==============================================================================


def _restore_search_roots():
    roots = []
    if CONFIG["SERVER_BACKUP_BASE"]:
        roots.append(CONFIG["SERVER_BACKUP_BASE"].rstrip("/\\"))
    for dest in _destinations():
        if dest["type"] in ("local", "share") and dest["path"]:
            roots.append(dest["path"].rstrip("/\\"))
    if CONFIG["STAGING_DIR"]:
        roots.append(CONFIG["STAGING_DIR"].rstrip("/\\"))
    stg = os.path.join(tempfile.gettempdir(), "auto-backupper-staging")
    if os.path.isdir(stg):
        roots.append(stg)
    seen, out = set(), []
    for r in roots:
        if r and r not in seen and os.path.isdir(r):
            seen.add(r)
            out.append(r)
    return out


def _find_archives(base):
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
    roots = _restore_search_roots()
    if not roots:
        print("No reachable backup roots (set SERVER_BACKUP_BASE, a local/share dest, or STAGING_DIR).")
        return 0
    total = 0
    for base in roots:
        archives = [f for f in _find_archives(base)
                    if fnmatch.fnmatch(os.path.basename(f), LIST_PATTERN)]
        if not archives:
            continue
        print(f"\n=== {base} ===")
        for f in archives:
            try:
                size = _human(os.path.getsize(f))
            except OSError:
                size = "0B"
            chk = "[chk]" if checksum_find_path(f, base) else "[NO CHK]"
            print(f"  {f[len(base) + 1:]:<64} {size:>9}  {chk}")
            total += 1
    print(f"\nTotal: {total} archive(s).")
    return 0


def cmd_inspect():
    if not os.path.isfile(RESTORE_ARCHIVE):
        log(f"ERROR: archive not found: {RESTORE_ARCHIVE}")
        return 1
    try:
        with tarfile.open(RESTORE_ARCHIVE, "r:*") as tf:
            names = tf.getnames()
    except (OSError, tarfile.TarError) as e:
        log(f"ERROR: cannot read archive: {e}")
        return 1
    for n in names[:100]:
        print(n)
    print(f"\nTotal entries: {len(names)} (first 100 shown)")
    return 0


def _verify_with_base(archive):
    # Find the BACKUP_BASE this archive lives under so checksum_find_path works.
    for base in _restore_search_roots() + [os.path.dirname(archive)]:
        base = base.rstrip("/\\")
        if archive.startswith(base + os.sep) or archive.startswith(base + "/"):
            if checksum_find_path(archive, base):
                return verify_file(archive, base)
    return VERIFY_NO_CHECKSUM


def cmd_verify(archive):
    if not os.path.isfile(archive):
        log(f"ERROR: archive not found: {archive}")
        return 1
    status = _verify_with_base(archive)
    log(f"VERIFY {status}: {archive}")
    return 0 if status in (VERIFY_OK, VERIFY_NO_CHECKSUM) else 1


def cmd_verify_all():
    rc = 0
    for base in _restore_search_roots():
        for f in _find_archives(base):
            status = verify_file(f, base) if checksum_find_path(f, base) else VERIFY_NO_CHECKSUM
            log(f"  {status}: {f}")
            if status == VERIFY_MISMATCH:
                rc = 1
    return rc


def _confirm(prompt):
    if FORCE:
        return True
    try:
        return input(f"{prompt} [y/N] ").strip().lower() in ("y", "yes")
    except EOFError:
        return False


def _safe_extract_members(tf, members, target):
    # Path-traversal guard: never extract outside target.
    target_abs = os.path.abspath(target)
    safe = []
    for m in members:
        dest = os.path.abspath(os.path.join(target, m.name))
        if dest == target_abs or dest.startswith(target_abs + os.sep):
            safe.append(m)
        else:
            log(f"  WARN: skipping unsafe member outside target: {m.name}")
    tf.extractall(target, members=safe)


def cmd_restore():
    archive, target = RESTORE_ARCHIVE, RESTORE_TARGET
    if not archive or not os.path.isfile(archive):
        log(f"ERROR: archive not found: {archive}")
        return 1
    if not target:
        log("ERROR: --target is required for --restore")
        return 1

    if CONFIG["VERIFY_BEFORE_RESTORE"] == "true" and not NO_VERIFY:
        status = _verify_with_base(archive)
        if status == VERIFY_OK:
            log("  Pre-restore checksum OK.")
        elif status == VERIFY_NO_CHECKSUM:
            log("  WARN: no checksum recorded for this archive.")
            if not _confirm("Proceed without verification?"):
                return 1
        elif status == VERIFY_MISMATCH:
            log("FATAL: archive checksum does NOT match. Refusing to restore corrupt data (override: --no-verify).")
            return 1
        else:
            log(f"FATAL: could not verify archive ({status}).")
            return 1

    # Surface a degraded system archive before restoring.
    try:
        with tarfile.open(archive, "r:*") as tf:
            mi = tf.getmember(".auto-backupper/MANIFEST.txt")
            man = tf.extractfile(mi).read().decode("utf-8", "replace")
            if "SYSTEM_INCOMPLETE" in man:
                log("  NOTE: this SYSTEM archive is marked INCOMPLETE (captured without elevation).")
    except (KeyError, OSError, tarfile.TarError):
        pass

    if not os.path.isdir(target):
        if not is_dry() and _confirm(f"Target {target} does not exist. Create it?"):
            os.makedirs(target, exist_ok=True)
        elif not is_dry():
            return 1

    print("\n================ RESTORE PLAN ================")
    print(f"  Archive: {archive}")
    print(f"  Target:  {target}")
    if ONLY_PATHS:
        print(f"  Only:    {', '.join(ONLY_PATHS)}")
    print("==============================================\n")
    if not _confirm("Proceed with restore?"):
        return 1

    if is_dry():
        log(f"[DRY] extract {archive} -> {target} only={ONLY_PATHS}")
        return 0
    try:
        with tarfile.open(archive, "r:*") as tf:
            if ONLY_PATHS:
                wanted = []
                norm = [p[2:] if p.startswith("./") else p.lstrip("/") for p in ONLY_PATHS]
                for m in tf.getmembers():
                    mn = m.name[2:] if m.name.startswith("./") else m.name
                    if any(mn == w or mn.startswith(w.rstrip("/") + "/") for w in norm):
                        wanted.append(m)
                if not wanted:
                    log("ERROR: --only matched no members (use --inspect to see names).")
                    return 1
                _safe_extract_members(tf, wanted, target)
            else:
                _safe_extract_members(tf, tf.getmembers(), target)
    except (OSError, tarfile.TarError) as e:
        log(f"ERROR: extraction failed: {e}")
        return 1
    if OS_TYPE == "windows":
        log("NOTE: POSIX owners/permissions/ACLs are not restored on Windows.")
    log(f"RESTORE SUCCEEDED: {archive} -> {target}")
    return 0


# ==============================================================================
# 14. LIFECYCLE & MAIN
# ==============================================================================


def acquire_lock():
    global _LOCK_FD, _LOCK_HELD
    try:
        os.makedirs(os.path.dirname(LOCKFILE), exist_ok=True)
        _LOCK_FD = open(LOCKFILE, "a+")
    except OSError:
        return True   # cannot create a lock -- don't block the backup
    try:
        _LOCK_FD.seek(0)
        if OS_TYPE == "windows":
            import msvcrt
            msvcrt.locking(_LOCK_FD.fileno(), msvcrt.LK_NBLCK, 1)
        else:
            import fcntl
            fcntl.flock(_LOCK_FD, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return False
    _LOCK_HELD = True
    if OS_TYPE != "windows":
        try:
            _LOCK_FD.seek(0)
            _LOCK_FD.truncate()
            _LOCK_FD.write(str(os.getpid()))
            _LOCK_FD.flush()
        except OSError:
            pass
    return True


def cleanup():
    if CURRENT_ARCHIVE_FILE and os.path.isfile(CURRENT_ARCHIVE_FILE + ".abpartial"):
        _remove_quiet(CURRENT_ARCHIVE_FILE + ".abpartial")
    vss_cleanup()
    if _LOCK_HELD and _LOCK_FD is not None:
        try:
            if OS_TYPE == "windows":
                import msvcrt
                _LOCK_FD.seek(0)
                msvcrt.locking(_LOCK_FD.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                import fcntl
                fcntl.flock(_LOCK_FD, fcntl.LOCK_UN)
            _LOCK_FD.close()
        except OSError:
            pass
        _remove_quiet(LOCKFILE)


def interrupt_handler(signum, frame):
    log("WARN: interrupt detected. Cleaning up...")
    cleanup()
    sys.exit(130)


def parse_args(argv):
    global MODE, BACKUP_SCOPE, RESTORE_ARCHIVE, RESTORE_TARGET, LIST_PATTERN
    global NO_VERIFY, FORCE, MEMBER
    cfg = None
    i, n = 0, len(argv)

    def need(flag):
        nxt = argv[i + 1] if i + 1 < n else None
        if nxt is None or nxt.startswith("-"):
            print(f"ERROR: {flag} requires a value (got '{nxt if nxt is not None else '<none>'}')", file=sys.stderr)
            sys.exit(1)
        return nxt

    while i < n:
        a = argv[i]
        if a in ("-h", "--help"):
            _usage()
            sys.exit(0)
        elif a == "--backup":
            MODE = "backup"
            nxt = argv[i + 1] if i + 1 < n else ""
            if nxt in ("users", "system", "both"):
                BACKUP_SCOPE = nxt
                i += 1
        elif a == "--restore":
            MODE = "restore"
            RESTORE_ARCHIVE = need("--restore"); i += 1
        elif a == "--target":
            RESTORE_TARGET = need("--target"); i += 1
        elif a == "--only":
            ONLY_PATHS.append(need("--only")); i += 1
        elif a == "--list":
            MODE = "list"
            nxt = argv[i + 1] if i + 1 < n else ""
            if nxt and not nxt.startswith("-"):
                LIST_PATTERN = nxt
                i += 1
        elif a == "--verify":
            MODE = "verify"
            RESTORE_ARCHIVE = need("--verify"); i += 1
        elif a == "--verify-all":
            MODE = "verify-all"
        elif a == "--inspect":
            MODE = "inspect"
            RESTORE_ARCHIVE = need("--inspect"); i += 1
        elif a == "--install-schedule":
            MODE = "install-schedule"
        elif a == "--uninstall-schedule":
            MODE = "uninstall-schedule"
        elif a == "--member":
            MEMBER = need("--member"); i += 1
        elif a == "--dest":
            DEST_FILTER.append(need("--dest")); i += 1
        elif a in ("-c", "--config"):
            cfg = need("-c/--config"); i += 1
        elif a.startswith("--config="):
            cfg = a[len("--config="):]
        elif a == "--dry-run":
            CONFIG["DRY_RUN"] = "true"
            _CLI_OVERRIDES["DRY_RUN"] = "true"
        elif a == "--no-verify":
            NO_VERIFY = True
        elif a == "--force":
            FORCE = True
        elif a == "--debug":
            CONFIG["LOG_VERBOSITY"] = "debug"
            _CLI_OVERRIDES["LOG_VERBOSITY"] = "debug"
        else:
            print(f"ERROR: unknown argument: {a}", file=sys.stderr)
            sys.exit(1)
        i += 1
    return cfg


def _usage():
    print(f"""Usage: {os.path.basename(sys.argv[0])} MODE [OPTIONS]
Modes:
  --backup [users|system|both]   Produce + deliver archives (default: both)
  --restore ARCHIVE --target P   Restore an archive (use --only ./path for partial)
  --list [PATTERN]               List reachable archives
  --verify ARCHIVE | --verify-all
  --inspect ARCHIVE              List archive members
  --install-schedule | --uninstall-schedule
Options:
  -c, --config FILE   Config file (default: per-OS location)
  --member NAME       Override the FamilyBackups <member> dir
  --dest NAME         Restrict delivery to named dest(s) (repeatable)
  --target PATH       Restore destination
  --only PATH         Partial-restore member (repeatable; leading ./ honored)
  --dry-run --no-verify --force --debug -h/--help""")


def main():
    global MEMBER
    resolve_paths()
    cfg = parse_args(sys.argv[1:])
    setup_logging()

    cfg_to_load = cfg or DEFAULT_CONFIG_FILE
    if os.path.isfile(cfg_to_load):
        log(f"INFO: loading configuration from {cfg_to_load}")
        parse_bash_config(cfg_to_load)
        CONFIG["_LOADED_CONFIG"] = cfg_to_load
    else:
        log(f"INFO: no config file at {cfg_to_load}; using defaults.")
        CONFIG["_LOADED_CONFIG"] = cfg_to_load
    # CLI flags win over the config file (which we just loaded over them).
    CONFIG.update(_CLI_OVERRIDES)

    global CHECKSUM_DIR
    CHECKSUM_DIR = CONFIG.get("CHECKSUM_DIR", CHECKSUM_DIR) or ".checksums"
    if MEMBER == _DEFAULT_MEMBER and CONFIG["MEMBER_NAME"]:
        MEMBER = CONFIG["MEMBER_NAME"]

    signal.signal(signal.SIGINT, interrupt_handler)
    signal.signal(signal.SIGTERM, interrupt_handler)
    import atexit
    atexit.register(cleanup)

    if not MODE:
        _usage()
        sys.exit(1)

    if MODE == "list":
        sys.exit(cmd_list())
    if MODE == "inspect":
        sys.exit(cmd_inspect())
    if MODE == "verify":
        sys.exit(cmd_verify(RESTORE_ARCHIVE))
    if MODE == "verify-all":
        sys.exit(cmd_verify_all())
    if MODE == "restore":
        sys.exit(cmd_restore())
    if MODE == "install-schedule":
        sys.exit(0 if install_schedule() else 1)
    if MODE == "uninstall-schedule":
        sys.exit(0 if uninstall_schedule() else 1)

    # MODE == backup
    vss_reap_orphan()
    if not acquire_lock():
        log("Another instance is running. Exiting.")
        sys.exit(0)
    preflight()
    if not produce_backup():
        log("ERROR: nothing was produced.")
        send_notify("alert", "Backup failed", f"{MEMBER}: produce stage created no archives.")
        sys.exit(1)
    ok = deliver_all()
    if ok:
        log("SUCCESS: backup complete.")
        send_notify("normal", "Backup complete", f"{MEMBER}: {len(PRODUCED)} archive(s) delivered.")
        sys.exit(0)
    log("ERROR: one or more deliveries failed.")
    send_notify("alert", "Backup delivery failed", f"{MEMBER}: see log {LOGFILE}.")
    sys.exit(1)


if __name__ == "__main__":
    main()
