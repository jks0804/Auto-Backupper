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
> ships extra tooling — `auto-restorer.sh`, the `legacy-checksum-generatator.sh`, and the
> Houston-style Watchtower dashboards (`--status`, `--ab-graph`, `--hub`) — that this port does
> not (yet) replicate. See [Differences from the Bash suite](#differences-from-the-bash-suite).

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
| `auto_backupper.cfg`| Shared configuration (Bash-syntax `KEY=val` / `KEY=(arrays)`)        |

* * * * *

🔧 Requirements
---------------

- **Python 3.7+**
- **Run as root** (all three scripts hard-require `uid 0`).
- **System binaries:**
  - `auto-backupper.py` / `watchtower.py`: `rsync`, `tar`, `sha256sum` (pre-flight enforced);
    `pigz` (optional, for multi-threaded compression), `docker` (optional).
  - `warphole.py`: `curl`, `jq`, `awk`, `uptime`, and `docker` (when `IS_DOCKER` is true).
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

The Python edition is a faithful *functional* port, not a 1:1 feature clone. Known gaps vs. the
`main` (Bash) branch:

- **No `auto-restorer`** — disaster-recovery / restore tooling is Bash-only for now.
- **No `legacy-checksum-generatator`** equivalent.
- **No Watchtower dashboards** — the Bash `--status`, `--ab-graph`, and `--hub` command centers
  are not ported.
- **No embedded `MANIFEST.txt`** inside archives.
- **No discovery-date checksum suffix** — checksums are plain SHA256 files without the Bash
  suite's portable `_<YYYYMMDD>` age suffix, so pull-side retention relies on local mtime.
- **No sparse-aware `tar -S`** flag in the archive command.

When in doubt, the Bash branch (`main`) is authoritative.

* * * * *

📄 License
----------

See [LICENSE](LICENSE).
