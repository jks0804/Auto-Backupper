#!/usr/bin/env python3
# ==============================================================================
# AUTO-BACKUPPER LEGACY CHECKSUM GENERATOR
# ==============================================================================
# Usage: sudo python3 legacy-checksum-generatator.py [BACKUP_PATH] [--force]
#
# A faithful port of legacy-checksum-generatator.sh (the primary version lives
# on the repo's `bash` branch). Back-fills dated `<name>_<YYYYMMDD>.sha256`
# checksums for existing archives so they join the suite's dated-checksum
# index.
#
# 1. Acquires the main Auto-Backupper lock so external watchtowers stand down.
# 2. Recursively scans for archives (.tar.gz, .tgz, .sql.gz, .archive.gz, ...).
# 3. For each archive, in priority order:
#      a. A dated `<name>_<YYYYMMDD>.sha256` already exists:
#           - suffix matches the filename's embedded `_<DATE>` (or there is no
#             embedded date): skip (idempotent).
#           - suffix DIFFERS from the embedded date: REALIGN — rename so the
#             suffix matches the embedded date, keeping the original hash.
#      b. A legacy un-dated checksum exists (`<name>.sha256` in the .checksums/
#         mirror or next to the data file): PROMOTE it to the dated form by
#         renaming — preserves the historical hash so a later verify still
#         catches bit-rot instead of re-blessing rotten bytes.
#      c. No checksum exists: GENERATE one (sha256sum + atomic write).
# 4. With --force, every existing checksum for a file (dated + legacy) is wiped
#    first and step (c) always runs.
# ==============================================================================

import os
import re
import sys
import glob
import fnmatch
import shutil
import subprocess

# --- Configuration ---
CHECKSUM_DIR = ".checksums"
LOCKFILE = "/var/lock/auto_backupper.lock"

# Archive name patterns the scan accepts. The bash uses `-name "*.*"` as a
# catch-all, so in practice any file with a dot (that isn't a checksum / temp /
# corruption-report file) qualifies.
_EXCLUDE_PATTERNS = ("*.sha256", "*.sha256.tmp.*", "*_corruption_report.txt")

_DATED_GLOB = "_" + "[0-9]" * 8 + ".sha256"  # <name>_YYYYMMDD.sha256
_lock_fd = None


def get_chk_dir(file_path, base):
    # Mirror the data tree under base/.checksums/.
    base = base.rstrip("/")
    rel = file_path[len(base) + 1:] if file_path.startswith(base + "/") else os.path.basename(file_path)
    return os.path.join(base, CHECKSUM_DIR, os.path.dirname(rel))


def last_embedded_date(name):
    # Last `_YYYYMMDD` group in the filename, matching the produce-flow
    # convention of appending CDATE as the terminal suffix. None if absent.
    m = re.findall(r"_(\d{8})", name)
    return m[-1] if m else None


def mtime_date(file_path):
    try:
        import datetime

        return datetime.datetime.fromtimestamp(os.path.getmtime(file_path)).strftime("%Y%m%d")
    except OSError:
        return ""


def has_sha256_hex(path):
    # Non-empty and contains a 64-hex-char run — guards against promoting a
    # torn / empty legacy checksum. Read bytes so a binary/garbled file can't
    # raise UnicodeDecodeError (bash grep tolerates it).
    try:
        if os.path.getsize(path) == 0:
            return False
        with open(path, "rb") as f:
            return re.search(rb"[a-fA-F0-9]{64}", f.read()) is not None
    except OSError:
        return False


def _safe_remove(path):
    try:
        os.remove(path)
    except OSError:
        pass


def _move(src, dst):
    # Like bash `mv -f`: rename, falling back to copy+delete across filesystems
    # (os.replace raises EXDEV when .checksums is a separate mount).
    try:
        os.replace(src, dst)
        return True
    except OSError:
        try:
            shutil.move(src, dst)
            return True
        except (OSError, shutil.Error):
            return False


def generate_checksum(file_path, base, force):
    chk_dir = get_chk_dir(file_path, base)
    name = os.path.basename(file_path)
    legacy_in_dir = os.path.join(chk_dir, f"{name}.sha256")
    legacy_next_to_file = f"{file_path}.sha256"

    if force:
        # Sweep every checksum variant (dated + both legacy layouts) so the
        # regen reflects the date we are about to compute.
        for stale in glob.glob(os.path.join(chk_dir, name + _DATED_GLOB)):
            _safe_remove(stale)
        _safe_remove(legacy_in_dir)
        _safe_remove(legacy_next_to_file)
    else:
        existing = glob.glob(os.path.join(chk_dir, name + _DATED_GLOB))
        if len(existing) > 1:
            # Multiple dated siblings — don't guess a winner; flag for --force.
            print(f"[SKIP-MULTI] {name} has {len(existing)} dated siblings — use --force to clean")
            return
        if len(existing) == 1:
            first = existing[0]
            existing_date = ""
            m = re.search(r"_(\d{8})\.sha256$", os.path.basename(first))
            if m:
                existing_date = m.group(1)
            # Only an embedded date is a "should-be" signal; mtime must not
            # rewrite an existing first-sighting stamp (that loses history).
            want_date = last_embedded_date(name) or ""
            if not want_date or existing_date == want_date:
                return
            target = os.path.join(chk_dir, f"{name}_{want_date}.sha256")
            if os.path.isfile(target):
                print(f"[CONFLICT] {name}: both _{existing_date}.sha256 and _{want_date}.sha256 exist — leaving alone")
                return
            if _move(first, target):
                print(f"[REALIGN {existing_date}→{want_date}] {name} (aligned suffix to embedded date)")
            else:
                print(f"[FAIL-REALIGN] {name} (could not rename {first} → {target})")
            return
        # No dated sibling → fall through to PROMOTE / GEN.

    # Discovery date: embedded `_YYYYMMDD` in the name, else mtime.
    embedded = last_embedded_date(name)
    if embedded:
        discovery_date, date_source = embedded, "embedded"
    else:
        discovery_date, date_source = mtime_date(file_path), "mtime"
    if not discovery_date:
        print(f"[SKIP-NO-DATE] {name} (no embedded date, no mtime)")
        return

    os.makedirs(chk_dir, exist_ok=True)
    chk_path = os.path.join(chk_dir, f"{name}_{discovery_date}.sha256")

    # Promotion: rename a valid legacy un-dated checksum instead of recomputing,
    # so the historical hash (and any bit-rot it would expose) is preserved.
    if not force:
        legacy_source, legacy_origin = "", ""
        if os.path.isfile(legacy_in_dir):
            legacy_source, legacy_origin = legacy_in_dir, "in-dir"
        elif os.path.isfile(legacy_next_to_file):
            legacy_source, legacy_origin = legacy_next_to_file, "next-to-file"
        if legacy_source:
            if has_sha256_hex(legacy_source):
                if _move(legacy_source, chk_path):
                    print(f"[PROMOTE {legacy_origin} {date_source} {discovery_date}] {name} (preserved historical hash)")
                else:
                    print(f"[FAIL-PROMOTE] {name} (could not rename {legacy_source} → {chk_path})")
                return
            print(f"[INVALID-LEGACY] {name}: {legacy_source} missing usable sha256 — falling through to GEN")

    # Fresh generation (atomic temp + rename so a torn write can't read as a
    # false-positive corruption later).
    print(f"[GEN {date_source} {discovery_date}] {name}... ", end="", flush=True)
    digest = _sha256(file_path)
    if digest is None:
        print("FAILED!")
        return
    tmp = f"{chk_path}.tmp.{os.getpid()}"
    try:
        with open(tmp, "w") as f:
            f.write(digest + "\n")
        os.replace(tmp, chk_path)
        print("Done.")
    except OSError:
        _safe_remove(tmp)
        print("FAILED!")


def _sha256(path):
    try:
        r = subprocess.run(["sha256sum", path], capture_output=True, text=True)
    except OSError:
        return None
    if r.returncode != 0 or not r.stdout.strip():
        return None
    return r.stdout.split()[0]


def find_archives(base):
    base = base.rstrip("/")
    chk_root = os.path.join(base, CHECKSUM_DIR)
    out = []
    for root, dirs, files in os.walk(base):
        if root == chk_root or root.startswith(chk_root + os.sep):
            dirs[:] = []
            continue
        if CHECKSUM_DIR in dirs:
            dirs.remove(CHECKSUM_DIR)
        for fn in files:
            if "." not in fn:
                continue  # bash `-name "*.*"` requires a dot
            if any(fnmatch.fnmatch(fn, pat) for pat in _EXCLUDE_PATTERNS):
                continue
            out.append(os.path.join(root, fn))
    return sorted(out)


def acquire_lock():
    global _lock_fd
    import fcntl

    try:
        _lock_fd = open(LOCKFILE, "w")
    except OSError:
        print("FATAL: Cannot open lockfile.")
        sys.exit(1)
    print(f"Attempting to acquire lock: {LOCKFILE}...")
    try:
        fcntl.flock(_lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print("ERROR: Auto-Backupper (or another instance) is already running.")
        holder = ""
        if shutil.which("fuser"):
            holder = subprocess.run(["fuser", LOCKFILE], capture_output=True, text=True).stdout.strip()
        print(f"       Lock held by PID: {holder}")
        sys.exit(1)


def release_lock():
    global _lock_fd
    if _lock_fd is not None:
        import fcntl

        print("Releasing lock and cleaning up...")
        try:
            fcntl.flock(_lock_fd, fcntl.LOCK_UN)
            _lock_fd.close()
        except OSError:
            pass
        _lock_fd = None


def main():
    args = sys.argv[1:]
    force = "--force" in args
    positionals = [a for a in args if not a.startswith("--")]
    target_dir = positionals[0] if positionals else "/mnt/user/archive"

    if os.geteuid() != 0:
        print("CRITICAL: This script must be run as root to acquire the system lock.", file=sys.stderr)
        sys.exit(1)

    acquire_lock()
    import atexit

    atexit.register(release_lock)
    print("LOCK ACQUIRED. Watchtowers should now stand down.")

    if not os.path.isdir(target_dir):
        print(f"CRITICAL: Target directory does not exist: {target_dir}")
        sys.exit(1)

    print(f"Scanning {target_dir} for legacy archives...")
    for file_path in find_archives(target_dir):
        generate_checksum(file_path, target_dir, force)

    print("========================================================")
    print(" Operation Complete.")
    print(" Lock will be released upon exit.")
    print("========================================================")


if __name__ == "__main__":
    main()
