#!/bin/bash
# ==============================================================================
# AUTO-BACKUPPER LEGACY CHECKSUM GENERATOR
# ==============================================================================
# Usage: ./generate_legacy_checksums.sh [BACKUP_PATH] [--force]
#
# 1. Acquires the main Auto-Backupper lock to pause external "Watchtowers".
# 2. Recursively scans for archives (.tar.gz, .tgz, .sql.gz, .archive.gz, …).
# 3. For each archive, in priority order:
#       a. Dated `<name>_<YYYYMMDD>.sha256` already exists:
#            - If its date suffix matches the filename's embedded `_<DATE>`
#              (or no embedded date is present): skip (idempotent).
#            - If the suffix DIFFERS from the embedded date: REALIGN — rename
#              the checksum so its suffix matches the filename's embedded
#              date. Typical cause: watchtower's first-sighting stamps "today"
#              regardless of whether the file's name carries a date, so an
#              externally-uploaded `foo_20240101.tar.gz` could end up with a
#              `foo_20240101.tar.gz_20251015.sha256` sibling. Realign keeps
#              the original hash (no recompute, no lost integrity statement).
#       b. Legacy un-dated checksum exists (`<name>.sha256` in either the
#          .checksums/ mirror tree or next to the data file) → PROMOTE it
#          to the dated form by renaming. Crucially, this preserves the
#          historical hash — recomputing instead would happily generate a
#          "valid" hash of bit-rotted bytes and erase the corruption
#          evidence. Renaming keeps the original integrity statement.
#       c. No checksum exists → GENERATE one (sha256sum + atomic write).
# 4. With --force, all existing checksums for a file (dated + legacy) are
#    wiped first and step c always runs.
# ==============================================================================

set -Eeuo pipefail

# --- Configuration ---
CHECKSUM_DIR=".checksums"
LOCKFILE="/var/lock/auto_backupper.lock"
FORCE_REGEN=false

# --- Argument Parsing ---
# Separate the optional --force flag from the optional path positional so the
# two may appear in any order; the first non-flag argument is the path.
TARGET_DIR=""
for arg in "$@"; do
  if [[ "$arg" == "--force" ]]; then
    FORCE_REGEN=true
  elif [[ -z "$TARGET_DIR" ]]; then
    TARGET_DIR="$arg"
  fi
done
TARGET_DIR="${TARGET_DIR:-/mnt/user/archive}"

# --- Root Check ---
if [[ $EUID -ne 0 ]]; then
   echo "CRITICAL: This script must be run as root to acquire the system lock." >&2
   exit 1
fi

# ==============================================================================
# 1. LOCKING MECHANISM (mirrors auto-backupper's lock convention)
# ==============================================================================
# We use File Descriptor 9, just like the main script.
LOCKFD=9
exec {LOCKFD}>"${LOCKFILE}" || { echo "FATAL: Cannot open lockfile."; exit 1; }

echo "Attempting to acquire lock: $LOCKFILE..."
if ! flock -n "${LOCKFD}"; then
  echo "ERROR: Auto-Backupper (or another instance) is already running."
  echo "       Lock held by PID: $(fuser "$LOCKFILE" 2>/dev/null)"
  exit 1
fi

# Cleanup Trap: Ensure lock is released on exit (success or failure)
cleanup() {
  echo "Releasing lock and cleaning up..."
  flock -u "${LOCKFD}" || true
}
trap cleanup EXIT

echo "LOCK ACQUIRED. Watchtowers should now stand down."

# ==============================================================================
# 2. CHECKSUM LOGIC
# ==============================================================================

if [[ ! -d "$TARGET_DIR" ]]; then
  echo "CRITICAL: Target directory does not exist: $TARGET_DIR"
  exit 1
fi
# Strip ALL trailing slashes (tab-completion adds one; a double slash defeats a
# single-strip). Without this, the get_chk_dir prefix-strip sees a leftover
# slash, fails to strip, and writes every checksum under the full absolute path
# — orphaning it from the suite's verify/retention, which then silently never
# finds it. Guard the root so `/` doesn't collapse to "" (which would make
# `find ""` abort the whole run under set -e).
while [[ "$TARGET_DIR" == */ ]]; do TARGET_DIR="${TARGET_DIR%/}"; done
[[ -z "$TARGET_DIR" ]] && TARGET_DIR="/"

get_chk_dir() {
  # $1 = Full File Path, $2 = Base Directory → echo checksum subdir
  # $2 is QUOTED in the strip pattern: without quotes a base path containing
  # glob metacharacters ([ ] * ?) is treated as a pattern and fails to strip,
  # leaving rel as the full absolute path and orphaning the checksum. Mirrors
  # auto-backupper.sh's checksum_write_path (${file#"$base"/}). The caller also
  # normalises the trailing slash off TARGET_DIR so the prefix matches cleanly.
  local rel="${1#"$2"/}"
  echo "$2/${CHECKSUM_DIR}/$(dirname "$rel")"
}

# Validate that an 8-digit string is a plausible calendar date (YYYYMMDD).
# The "last 8-digit group wins" rule is correct for suite-produced names
# (terminal _<CDATE> before the extension) but mis-fires on legacy/external
# names containing non-date 8-digit runs — a 1920x1080 resolution (19201080),
# an account/serial number, a trailing version. A bogus date becomes the
# checksum's suffix, which auto-backupper rotation uses as the retention
# source of truth -> a fresh backup stamped year 1920 is evicted on the next
# pass. Validating here (and gating REALIGN on it) prevents that data loss.
_valid_date() {
  local d="$1"
  [[ "$d" =~ ^[0-9]{8}$ ]] || return 1
  local y="${d:0:4}" m="${d:4:2}" day="${d:6:2}"
  ((10#$y >= 1990 && 10#$y <= 2100)) || return 1
  ((10#$m >= 1 && 10#$m <= 12)) || return 1
  ((10#$day >= 1 && 10#$day <= 31)) || return 1
  # Final authority: reject impossible calendar dates (Feb 30, Apr 31, …).
  date -d "${y}-${m}-${day}" >/dev/null 2>&1 || return 1
  return 0
}

# Echo the discovery date embedded in a filename: the LAST _<8digits> group
# that is a VALID calendar date (so a trailing serial can't beat the real
# leading date, and a non-date run is ignored). Empty if none is valid.
_embedded_date() {
  local name="$1" tok best=""
  # Tokenise on non-digit runs (tr replaces every non-digit with a space) and
  # consider only tokens that are EXACTLY 8 digits. This rejects a 9+-digit run
  # (serial/version/timestamp) whose leading 8 happen to look like a date —
  # `grep -oE '_[0-9]{8}'` would have matched that prefix. Keep the LAST valid
  # calendar date (suite convention: terminal _<CDATE> before the extension).
  for tok in $(echo "$name" | tr -c '0-9' ' '); do
    [[ "$tok" =~ ^[0-9]{8}$ ]] || continue
    if _valid_date "$tok"; then best="$tok"; fi
  done
  printf '%s' "$best"
}

generate_checksum() {
  local file="$1"
  local base="$2"
  local chk_dir
  chk_dir="$(get_chk_dir "$file" "$base")"
  local name
  name="$(basename "$file")"

  # Legacy (un-dated) checksum candidates we might be able to promote
  # instead of recomputing. Two layouts seen in the wild:
  #   1. In the .checksums/ mirror tree (drop-in older sibling of the
  #      dated form we want to produce).
  #   2. Right next to the data file (very old / externally-generated).
  local legacy_chk_in_dir="${chk_dir}/${name}.sha256"
  local legacy_chk_next_to_file="${file}.sha256"

  if [[ "$FORCE_REGEN" == "true" ]]; then
    # --force sweeps every checksum variant (dated AND legacy) so the
    # regen reflects the date we're about to compute. Use cases: the
    # embedded date in the filename changed (file rename), mtime
    # shifted since the last back-fill, or you want a fresh hash to
    # prove the file's current bytes still match.
    shopt -s nullglob
    local stale
    for stale in "${chk_dir}/${name}"_[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9].sha256; do
      rm -f "$stale"
    done
    shopt -u nullglob
    [[ -f "$legacy_chk_in_dir" ]] && rm -f "$legacy_chk_in_dir"
    [[ -f "$legacy_chk_next_to_file" ]] && rm -f "$legacy_chk_next_to_file"
  else
    # Examine any existing dated sibling(s). Two outcomes:
    #   - Date suffix already matches what we'd compute (or the
    #     filename has no embedded date to compare against) → silent
    #     skip (idempotent back-fill).
    #   - Date suffix differs from the filename's embedded date →
    #     REALIGN: rename the checksum file so its suffix matches the
    #     embedded date. Keeps the historical hash intact; corrects the
    #     name only. Typical cause: watchtower's first-sighting stamps
    #     "today" regardless of the filename's embedded date.
    shopt -s nullglob
    local _existing _existing_count=0 _first_existing=""
    for _existing in "${chk_dir}/${name}"_[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9].sha256; do
      _existing_count=$((_existing_count + 1))
      [[ -z "$_first_existing" ]] && _first_existing="$_existing"
    done
    shopt -u nullglob

    if ((_existing_count > 1)); then
      # Multiple dated siblings — unusual, possibly from interleaved
      # back-fills or a manual edit gone wrong. Don't try to merge or
      # pick a winner; flag it so the operator can run `--force` to
      # reset, or clean up manually.
      echo "[SKIP-MULTI] $name has ${_existing_count} dated siblings — use --force to clean"
      return
    fi

    if ((_existing_count == 1)); then
      # Extract the date suffix from the existing checksum's filename.
      local _existing_date
      _existing_date=$(basename "$_first_existing" \
        | grep -oE '_[0-9]{8}\.sha256$' \
        | grep -oE '[0-9]{8}' || echo "")

      # Compute what the suffix SHOULD be from the data file's name.
      # Only embedded dates count as a "should be" signal — mtime is a
      # fallback for files with no embedded date, but using mtime to
      # rewrite an existing first-sighting stamp would lose meaningful
      # history (the existing stamp is when this host first saw it).
      # Only a VALID embedded calendar date counts as a realign target. A
      # non-date 8-digit run (resolution/serial) must NOT re-date an existing,
      # correct first-sighting stamp to a bogus year (that would force the
      # backup's early eviction). If no valid embedded date, _want_date stays
      # empty and we leave the existing stamp alone.
      local _want_date
      _want_date="$(_embedded_date "$name")"

      if [[ -z "$_want_date" || "$_existing_date" == "$_want_date" ]]; then
        # Either no embedded date to align to, or already aligned.
        return
      fi

      # Date mismatch — REALIGN. Bail if the target name already exists
      # with a different date (both `_A.sha256` and `_B.sha256` present
      # for the same data file is an operator-level problem).
      local _target_chk="${chk_dir}/${name}_${_want_date}.sha256"
      if [[ -f "$_target_chk" ]]; then
        echo "[CONFLICT] $name: both _${_existing_date}.sha256 and _${_want_date}.sha256 exist — leaving alone"
        return
      fi

      if mv -f "$_first_existing" "$_target_chk"; then
        echo "[REALIGN ${_existing_date}→${_want_date}] $name (aligned suffix to embedded date)"
      else
        echo "[FAIL-REALIGN] $name (could not rename $_first_existing → $_target_chk)"
      fi
      return
    fi
    # _existing_count == 0 → fall through to PROMOTE / GEN below.
  fi

  # Derive the discovery date. Source-of-truth order:
  #   1. The "_<YYYYMMDD>" suffix already embedded in the filename by
  #      auto-backupper's produce flow (e.g. codebase_20250517.tar.gz).
  #      If multiple 8-digit groups appear, the LAST is taken — that
  #      matches the produce-flow convention where CDATE is appended
  #      as the terminal suffix before the extension.
  #   2. mtime, formatted YYYYMMDD. Safe fallback for externally-
  #      uploaded files with arbitrary naming schemes.
  local discovery_date="" date_source=""
  discovery_date="$(_embedded_date "$name")"
  if [[ -n "$discovery_date" ]]; then
    date_source="embedded"
  else
    # No VALID embedded date — fall back to mtime. (A non-date 8-digit run in
    # the name is intentionally ignored rather than stamped as a bogus date.)
    discovery_date="$(date -r "$file" +%Y%m%d 2>/dev/null || true)"
    date_source="mtime"
  fi
  if [[ -z "$discovery_date" ]]; then
    echo "[SKIP-NO-DATE] $name (no embedded date, no mtime)"
    return
  fi

  mkdir -p "$chk_dir"
  local chk_path="${chk_dir}/${name}_${discovery_date}.sha256"

  # ---- Promotion path ----
  # If a legacy un-dated checksum exists for this file, rename it
  # rather than recomputing. This preserves the *historical* hash —
  # the value that was vouched for when the original .sha256 was
  # written. That matters: if the data file silently bit-rotted in
  # the intervening months/years, a recompute today would produce a
  # "valid" hash of the rotten bytes and the next verify pass would
  # never catch it. Keeping the original hash means the FIRST verify
  # after promotion sees a real mismatch and surfaces the corruption.
  #
  # A minimum validity check (file is non-empty and contains a
  # sha256-shaped hex string) guards against promoting a torn / empty
  # legacy file — those fall through to fresh generation instead.
  if [[ "$FORCE_REGEN" != "true" ]]; then
    local legacy_source="" legacy_origin=""
    if [[ -f "$legacy_chk_in_dir" ]]; then
      legacy_source="$legacy_chk_in_dir"
      legacy_origin="in-dir"
    elif [[ -f "$legacy_chk_next_to_file" ]]; then
      legacy_source="$legacy_chk_next_to_file"
      legacy_origin="next-to-file"
    fi

    if [[ -n "$legacy_source" ]]; then
      # Anchor the hex check: a line that is EXACTLY 64 hex chars, optionally
      # followed by whitespace + filename (standard sha256sum output). The old
      # unanchored '[a-fA-F0-9]{64}' matched any 64-hex substring, so a sha512
      # digest (128 hex), a prose line, or a 64-hex filename token would be
      # PROMOTED as a sha256 that can never match -> permanent false-corruption.
      if [[ -s "$legacy_source" ]] && grep -qE '^[a-fA-F0-9]{64}([[:space:]]|$)' "$legacy_source"; then
        # Promote by extracting the bare 64-hex digest and writing it in the
        # normalized form the suite expects. We must NOT rename a standard
        # `<hash>  <filename>` sha256sum file verbatim: auto-backupper's
        # verify_file does `tr -d ' \t\r\n'` over the WHOLE file, so the trailing
        # filename would fuse onto the hash and never match (false-corruption).
        # Extracting the first field preserves the HISTORICAL hash value (no
        # recompute -> bit-rot still caught) while matching write_checksum's
        # on-disk format (which uses `awk '{print $1}'`).
        local _legacy_hash
        _legacy_hash="$(grep -oE '^[a-fA-F0-9]{64}' "$legacy_source" | head -1 || true)"
        local _ptmp="${chk_path}.tmp.$$"
        if [[ -n "$_legacy_hash" ]] && printf '%s\n' "$_legacy_hash" >"$_ptmp" && mv -f "$_ptmp" "$chk_path"; then
          rm -f "$legacy_source"
          echo "[PROMOTE ${legacy_origin} ${date_source} ${discovery_date}] $name (preserved historical hash)"
          return
        else
          rm -f "$_ptmp" 2>/dev/null || true
          echo "[FAIL-PROMOTE] $name (could not normalize/write $legacy_source → $chk_path)"
          return
        fi
      else
        echo "[INVALID-LEGACY] $name: $legacy_source missing usable sha256 — falling through to GEN"
        # Fall through to fresh generation below.
      fi
    fi
  fi

  # ---- Fresh generation ----
  # Print format: [STATUS] Filename (date source date)
  echo -n "[GEN ${date_source} ${discovery_date}] $name... "

  # Atomic write: temp + rename. Same rationale as auto-backupper.sh's
  # write_checksum — a torn checksum would surface as a false-positive
  # corruption alert on the next verify.
  local tmp="${chk_path}.tmp.$$"
  if sha256sum "$file" | awk '{print $1}' > "$tmp"; then
    mv -f "$tmp" "$chk_path"
    echo "Done."
  else
    rm -f "$tmp"
    echo "FAILED!"
  fi
}

# ==============================================================================
# 3. EXECUTION LOOP
# ==============================================================================

echo "Scanning $TARGET_DIR for legacy archives..."

# Scan for all supported archive types used in your main script
find "$TARGET_DIR" \
  -type d -name "${CHECKSUM_DIR}" -prune -o \
  -type f \( -name "*.tar.gz" -o -name "*.tgz" -o -name "*.sql.gz" -o -name "*.archive.gz" -o -name "*.json" -o -name "*.zip" -o -name "*.7z" \) \
  ! -name "*.sha256" ! -name "*.sha256.tmp.*" ! -name "*_corruption_report.txt" \
  ! -name "*.part" ! -name "*.partial" ! -name "*.tmp" ! -name "*.tmp.*" \
  -print0 | while IFS= read -r -d '' file; do
    generate_checksum "$file" "$TARGET_DIR"
done

echo "========================================================"
echo " Operation Complete."
echo " Lock will be released upon exit."
echo "========================================================"
