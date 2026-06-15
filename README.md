* * * * *

Auto-Backupper
==============

**A Unified, Fault-Tolerant Backup & Maintenance Suite for Unraid, OMV, and Linux**

This is the **Python port** of Auto-Backupper, a faithful reimplementation of the original
Bash suite (which lives on the [`main`](../../tree/main) branch and remains the primary,
production-grade implementation). This port trades the Bash suite's breadth for a
leaner, dependency-light codebase that is easier to read, extend, and run anywhere Python 3.7+
is available.

> **Looking for the full suite?** The Bash branch (`main`) is the reference implementation and
> ships the Houston-style Watchtower dashboards (`--status`, `--ab-graph`, `--hub`) that this
> port does not (yet) replicate. Conversely, this branch ships **one tool the Bash suite has
> no equivalent for**: `auto-backupper-client.py`, the cross-platform desktop backup client.
> See [Differences from the Bash suite](#differences-from-the-bash-suite).

* * * * *

🚀 Key Features
---------------

- **OS Agnostic:** Auto-detects **Unraid**, **OpenMediaVault (OMV)**, or standard **Linux** and
  adjusts Docker / mover / notification strategy accordingly.
- **Zero-Downtime Logic:** Hot-dumps databases via `docker exec`, stops the Docker service or
  individual containers only when a cold system backup requires it, and guarantees restart even
  on failure (handled in `cleanup()` / `atexit`).
- **Atomic Verification:** Generates a SHA256 checksum alongside every archive under
  `.checksums/` and verifies it after creation *and* after remote pulls. Verification is
  threaded via `ThreadPoolExecutor`.
- **Self-Healing:** State-based recovery (`/tmp/enclave/ab_state`) plus an `flock`-based lock
  (`/var/lock/auto_backupper.lock`) ensure a single instance and a clean restart if a run is
  interrupted.
- **Watchtower Daemon:** A companion daemon (`watchtower.py`) that schedules backups/cleanups/
  verifies/updates, monitors cache fullness (invoking Unraid's Mover), auto-updates Docker
  containers, and performs incremental + deep bitrot scans.
- **Shared Config:** Reads the **same** Bash-style `auto_backupper.cfg` used by the `main`
  branch, so a host can switch between the Bash and Python implementations without rewriting
  configuration.

* * * * *

📦 Components
------------

| Script              | Purpose                                                              |
|---------------------|----------------------------------------------------------------------|
| `auto-backupper.py` | Produce local backups (system, shares, DB dumps) and/or pull remotes |
| `watchtower.py`     | Scheduling daemon, integrity scanner, cache monitor, Docker updater  |
| `warphole.py`       | Pi-hole sidecar: Teleporter backup, gravity health-check, live stats |
| `auto-restorer.py`  | Disaster recovery: list/inspect/verify/restore, corruption report    |
| `legacy-checksum-generatator.py` | Back-fill dated checksums for existing archives         |
| `auto-backupper-client.py` | **Cross-platform desktop client** (Windows/macOS/Linux): produces FamilyBackups user + system archives, delivers them to the server, restores locally |
| `auto_backupper.cfg`| Shared server configuration (Bash-syntax `KEY=val` / `KEY=(arrays)`) |
| `auto_backupper_client.cfg` | Desktop-client configuration (same Bash-syntax parser)       |

* * * * *

🔧 Requirements
---------------

- **Python 3.7+**
- **Run as root** for the server-side tools (`auto-backupper.py`, `watchtower.py`,
  `auto-restorer.py`, `warphole.py`, `legacy-checksum-generatator.py` hard-require `uid 0`).
  The desktop client (`auto-backupper-client.py`) does **not** require admin/root — it degrades
  to the current user's data with warnings when unprivileged.
- **System binaries:**
  - `auto-backupper.py` / `watchtower.py`: `rsync`, `tar`, `sha256sum` (pre-flight enforced);
    `pigz` (optional, for multi-threaded compression), `docker` (optional).
  - `warphole.py`: `curl`, `jq`, `awk`, `uptime`, and `docker` (when `IS_DOCKER` is true).
  - `auto-backupper-client.py`: stdlib only for core work; `ssh`/`scp` or `rsync` only for the
    `rsync_ssh` destination; on Windows, `diskshadow`/`vssadmin` + `reg`/`winget`/`powershell`
    are used opportunistically for VSS and system inventory.
- **Python packages (warphole only):** `requests` and `rich`. `warphole.py` checks for these on
  startup and offers to `pip install` them interactively.

* * * * *

⚙️ Configuration
----------------

All scripts default to reading `/boot/config/auto_backupper.cfg` (override with `--config`).
The parser understands the Bash-native config format, so the file is shared verbatim with the
`main` branch:

```ini
MODE="both"                 # produce | pull | both
CPU_THREADS="all"           # "all" | "1" (single) | "4" (cap)
DRY_RUN="true"              # set "false" for real execution
BACKUP_BASE="/mnt/user/backup"
DOCKER_MODE="unraid_service" # auto | unraid_service | container | disabled
ROTATE_DAYS=90              # 0 = keep forever

SHARES_TO_BACKUP=( "codebase" "domains" "iscsi" "FamilyBackups" )
REMOTE_PULL_SOURCES=( "/mnt/remotes/DBACKUPS" )
```

> ⚠️ **`DRY_RUN` defaults to `true`.** Nothing is written until you set `DRY_RUN="false"` in the
> config. The `--dry-run` flag can force dry-run on, but it cannot turn it off — that must be
> done in the config file.

Database backups (MySQL/MariaDB, PostgreSQL, MongoDB, Redis) are toggled per-engine in the
config and dumped through `docker exec` against the named container. Leave the per-engine
`*_DATABASES` list empty to auto-discover and dump all non-system databases.

* * * * *

▶️ Usage
--------

### auto-backupper.py — backups & pulls

```bash
sudo python3 auto-backupper.py [OPTIONS]
```

| Flag                  | Description                                             |
|-----------------------|---------------------------------------------------------|
| `-c, --config FILE`   | Path to config (default `/boot/config/auto_backupper.cfg`) |
| `-m, --mode MODE`     | `produce` \| `pull` \| `both`                           |
| `--dry-run`           | Force simulation (no writes)                            |
| `--no-docker`         | Disable Docker management (`DOCKER_MODE=disabled`)      |
| `--skip-preflight`    | Skip binary / writability checks                        |

**Flow:** DB dumps → cold system backup (stops Docker if needed, then restarts) → hot shares
backup (with granular handling for `domains`, `iscsi`, and `FamilyBackups`) → threaded local
verification → mtime-based rotation. In `pull`/`both` mode it rsyncs each `REMOTE_PULL_SOURCES`
entry, verifies the pulled files, and re-pulls anything that fails its checksum.

### watchtower.py — daemon & maintenance

```bash
sudo python3 watchtower.py --monitor      # run the scheduling daemon
sudo python3 watchtower.py --scan         # one-shot incremental checksum scan
sudo python3 watchtower.py --scan --verify # deep bitrot verify of every file
sudo python3 watchtower.py --cleanup      # remove junk (.DS_Store, .nfo, temp dirs)
sudo python3 watchtower.py --update       # update Docker containers
sudo python3 watchtower.py --start-backup # force-start a backup run
sudo python3 watchtower.py --stop-backup  # stop a running backup
sudo python3 watchtower.py --reload       # signal the daemon to reload config
```

The daemon writes a PID file (`/var/run/ab_watchtower.pid`) and listens on `SIGUSR1`; the
`--update`, `--verify`, and `--reload` commands signal a running daemon via trigger files rather
than spawning a second instance. Schedulers support `daily`, `weekly`, `monthly`, `quarterly`,
and `annually` cadences.

> The default `MAIN_BACKUP_SCRIPT` points at `auto-backupper.sh`. For an all-Python deployment,
> set `MAIN_BACKUP_SCRIPT` in the config (or `cfg.MAIN_BACKUP_SCRIPT`) to your `auto-backupper.py`
> path.

### warphole.py — Pi-hole sidecar

```bash
sudo python3 warphole.py --backup-now [--keep-local]  # Teleporter export + checksum verify
sudo python3 warphole.py --check                      # gravity health-check / self-repair
sudo python3 warphole.py --stats                       # live Rich TUI dashboard
```

`warphole.py` backs up Pi-hole via the FTL Teleporter (Docker or native), to either a local path
or an SMB share, verifying the copy by SHA256. `--check` detects a zero-domain gravity table and
repairs it (`pihole -g`), with a low-RAM reboot-recovery path guarded by a repair marker. Set
`PI_PASSWORD` in `CONFIG` for authenticated API access; leaving it empty skips auth (stats/check
degrade gracefully).

### auto-backupper-client.py — cross-platform desktop client

Runs on family/client **Windows, macOS, and Linux** PCs to replace the legacy Windows 7 backup
feature. It produces two archives per machine — a **USER-data** archive and a **SYSTEM-state**
archive — in the suite's exact `FamilyBackups/<member>/{users,systems}/` layout (`./`-rooted
`tar.gz` + dated `.checksums/`), then delivers them to one or more destinations. The output drops
straight into the server's `BACKUP_BASE`, where `watchtower`/`auto-restorer` treat it as a
first-class backup. It uses stdlib `tarfile` + `hashlib` (no `tar`/`sha256sum`/`rsync` needed for
the core work) and **does not require admin/root** — it degrades to the current user's profile
with warnings when unprivileged.

```bash
python3 auto-backupper-client.py --backup both          # users + system, deliver to all dests
python3 auto-backupper-client.py --backup users --dry-run
python3 auto-backupper-client.py --list                 # list reachable archives
python3 auto-backupper-client.py --verify ARCHIVE | --verify-all
python3 auto-backupper-client.py --restore ARCHIVE --target PATH [--only ./users/docs]
python3 auto-backupper-client.py --install-schedule     # Task Scheduler / launchd / systemd-timer
```

| Capability | Behavior |
|------------|----------|
| Destinations | `local` (external drive), `share` (SMB/NFS mount), `rsync_ssh` (push over Tailscale/VPN). Configure 1+ in `auto_backupper_client.cfg`; delivery is atomic (data → rename → checksum). |
| Windows locked files | VSS shadow copy when elevated (captures `NTUSER.DAT`, browser/Outlook); otherwise skip-and-warn. |
| System scope | Config/state to rebuild onto a fresh OS (registry export + program inventory on Windows; app/Homebrew/`defaults` + `/etc` on macOS/Linux) — **not** a bootable image. Marked `SYSTEM_INCOMPLETE` in the manifest when captured unprivileged. |
| Scheduling | Native OS scheduler (`--install-schedule`); not a daemon. |
| Retention | The **server** owns retention; the client keeps only `LOCAL_KEEP` local copies. |

> **Deployment prerequisite (server side):** the client pushes *finished* archives into
> `BACKUP_BASE/shares/FamilyBackups/<member>/…`, the same path the server's own FamilyBackups
> producer writes. For each client-managed member, ensure no raw
> `SHARES_BASE_FOLDER/FamilyBackups/<member>/` tree exists (the server loop skips absent dirs),
> **or** remove `"FamilyBackups"` from the server's `SHARES_TO_BACKUP`, so the server never
> re-tars/overwrites a client-pushed archive.

* * * * *

🗂️ Paths & Artifacts
---------------------

| Path                                    | Purpose                                  |
|-----------------------------------------|------------------------------------------|
| `/var/lock/auto_backupper.lock`         | Backup single-instance lock              |
| `/tmp/enclave/ab_state`                 | Crash-recovery state (e.g. Docker stopped)|
| `/var/log/auto_backupper.log`           | JSON rotating log (10 MB × 5)            |
| `/var/log/auto_backupper_watchtower.log`| Watchtower log                           |
| `<BACKUP_BASE>/.checksums/…sha256`      | Per-archive SHA256 checksums             |

* * * * *

🔀 Differences from the Bash suite
----------------------------------

The Python edition is a faithful *functional* port, not a 1:1 feature clone. Remaining gaps vs.
the `main` (Bash) branch:

- **No Watchtower dashboards** — the Bash `--status`, `--ab-graph`, and `--hub` command centers
  are not ported.
- **No sparse-aware `tar -S`** flag in the archive command.

(`auto-restorer.py`, `legacy-checksum-generatator.py`, embedded `MANIFEST.txt`, and the portable
`_<YYYYMMDD>` discovery-date checksum suffix — once listed here as gaps — are now implemented on
this branch.)

**Parity inversion (Python-only):** `auto-backupper-client.py` is the one component that exists
**only on this branch** — the Bash suite has no `auto-backupper-client.sh`. It is the
cross-platform desktop client; its on-disk output format is pinned by the same FamilyBackups
contract `auto-backupper.py`'s `create_archive(dest, sub_full, ["."])` produces, so any future
Bash equivalent must match it. (When updating the Bash branch's `PARITY-GAPS.md`, record this
reversed gap there too.)

When in doubt, the Bash branch (`main`) is authoritative for the *shared* tooling.

* * * * *

📄 License
----------

See [LICENSE](LICENSE).
