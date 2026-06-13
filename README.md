* * * * *

Auto-Backupper
==================

**A Unified, Fault-Tolerant Backup & Maintenance Suite for Unraid, OMV, and Linux**

Auto-Backupper is a production-grade bash suite designed to automate backups, synchronize data remotely, manage Docker container updates, and monitor file integrity. It abstracts OS-specific logic (Unraid services, Standard Docker, Systemd) to provide a "write once, run anywhere" backup strategy.

* * * * *

🚀 Key Features
---------------

-   **OS Agnostic:** Auto-detects **Unraid**, **OpenMediaVault (OMV)**, or standard **Linux** and adjusts strategies accordingly.

-   **Zero-Downtime Logic:** Smartly handles Docker states---snapshots databases "hot", stops containers only when necessary, and guarantees restart even on failure.

-   **Atomic Verification:** Generates SHA256 checksums for every backup artifact and verifies them during creation *and* after remote pulls. Each checksum carries a `_<YYYYMMDD>` discovery-date suffix so file age is portable across hosts and immune to rsync's mtime preservation — pull-side retention can correctly skip stale files regardless of when each remote rotates.

-   **Self-Healing:** State-based recovery (`/tmp/ab_state`) ensures system stability if a script is interrupted or crashes.

-   **Watchtower Daemon:** A companion daemon that handles scheduling, cache monitoring (invoking "Mover" when full), auto-updates for Docker containers, and silent corruption detection. Ships with `--status` for a one-shot scheduler snapshot, `--ab-graph` for a live full-terminal dashboard during in-progress backups or restores (phase timeline, CPU/MEM/disk/network sparklines, optional TSO offload %), and `--hub` — a Houston-style command center with single-key shortcuts to every entry point across the suite.

-   **Disaster Recovery:** Companion `auto-restorer.sh` tool lists, inspects, verifies, and restores any archive in the backup set, cross-references watchtower's per-host corruption report to distinguish stale entries from chronic problems, refuses to restore corrupt data by default, and exposes a dry-run-by-default `--prune-checksums` command for operator-controlled trimming of the long-lived checksum index.

-   **Sparse-Aware Archives:** Uses `tar -S` so large sparse files (Docker image, VM disks) skip their holes during both archive creation and space estimation.

-   **Embedded Manifest:** Every tar archive carries a `.auto-backupper/MANIFEST.txt` at the root with the archive name, ISO timestamp, host, OS, kernel, source paths, and tool versions used at creation. Readable without extraction (`tar -xOf <archive> .auto-backupper/MANIFEST.txt`) so a restorer can confirm what's inside before touching anything.

-   **Partial Runs:** `auto-backupper.sh --only=db,systems,shares` restricts the produce flow to specific phases (great for first-time validation, CI smoke tests, or re-running just the one segment that failed). `auto-restorer.sh --restore --only PATH` extracts only matching paths from an archive — for the common "I just need one file back" case.

-   **Pre-Flight Space Check:** Estimates whether the backup will fit before touching anything, aborting early with a clear message rather than hours into a doomed run.

-   **Argv-Safe Credentials:** Database and SMB passwords never appear in `ps` / `/proc/<pid>/cmdline`.

-   **Notifications:** OS-native (Unraid web banner, OMV, `notify-send`) plus an optional remote webhook with auto-detection for Discord / Slack / ntfy / generic JSON endpoints. Fires alongside the local notifier so you can keep both.

-   **Log Rotation:** Built-in log management to prevent disk fill-up.

* * * * *

📂 File Structure
-----------------

| **File** | **Description** |
| --- | --- |
| `auto-backupper.sh` | **The Core Worker.** Performs the actual backup (produce) and sync (pull) operations. |
| `auto-restorer.sh` | **The Restore Tool.** Lists, inspects, verifies, and restores archives produced by the worker. Also exposes operator-driven `--prune-checksums` for trimming the distributed checksum index. |
| `watchtower.sh` | **The Scheduler/Daemon.** Runs in the background to trigger backups, updates, and maintenance tasks based on schedules. |
| `warphole.sh` | **The Pi-hole Sidecar.** Teleporter-based Pi-hole backup that writes dated checksums into the same `.checksums/` tree so its output flows into the main sync cycle as a first-class backup. |
| `legacy-checksum-generatator.sh` | **The Back-Fill Generator.** One-shot tool that adds dated `.sha256` companions to pre-existing archives so legacy trees can join the dated-checksum scheme without re-creating any backups. |
| `auto_backupper.cfg` | **The Brain.** Central configuration file loaded by all scripts. Defines paths, schedules, and retention policies. |

* * * * *

⚙️ Installation & Setup
-----------------------

1.  **Placement:**

    Place the scripts in a persistent location (e.g., `/usr/local/bin/` or `/boot/scripts/`).

    ```
    chmod +x auto-backupper.sh auto-restorer.sh watchtower.sh
    ```

2.  **Configuration:**

    Copy the configuration file to `/boot/config/` (Unraid default) or `/etc/` (Linux default).

    -   *Note: You can override the config path using the `--config` flag; all three scripts read the same file.*

    -   **Edit `auto_backupper.cfg`** to match your disk UUIDs, remote paths, and container names.

3.  **Permissions:**

    Ensure the user running the script (usually root) has read/write access to source and destination paths. If the config file contains database passwords, restrict it: `chmod 600 auto_backupper.cfg`.

* * * * *

🖥️ Usage: Auto-Backupper (The Worker)
--------------------------------------

This script is usually triggered by `watchtower.sh`, but can be run manually for ad-hoc backups.

```
# Standard Run (Production Mode)
./auto-backupper.sh --mode produce

# Sync Only (Pull from remote)
./auto-backupper.sh --mode pull

# Run Both (Produce then Pull)
./auto-backupper.sh --mode both

# Partial run — restrict produce to specific phases (skips rotation).
# Valid values: db (alias: services), systems, shares.
./auto-backupper.sh --mode produce --only=db,shares

# Dry Run (Simulate actions without touching files)
./auto-backupper.sh --dry-run
```

### Partial Runs (`--only`)

`--only=PHASES` filters which production blocks of `produce_flow` actually fire. Valid phase names:

| Value | What runs | What's skipped |
| --- | --- | --- |
| `db` (alias: `services`) | SQL / Mongo / Redis dumps | systems, shares, rotation |
| `systems` | Appdata + boot + docker.img tar (with Docker stop/start if configured) | db, shares, rotation |
| `shares` | The `SHARES_TO_BACKUP` loop (including domains/iscsi/FamilyBackups recursive variants) | db, systems, rotation |

Combine with commas — `--only=db,shares` runs databases and shares but not systems. Whitespace and a trailing comma are tolerated. **Rotation is always skipped on a partial run**: the rotation phase walks the full BACKUP_BASE and evicts by age, which would happily delete old shares backups during a `--only=db` run. Wait for the next full run for retention to catch up. Affects produce mode only; `--mode pull` is unaffected.

### Core Logic Flows

1.  **Produce Flow:**

    -   **Pre-flight Space Check:** Sums `du -sb` on every source path and compares against `df` on `BACKUP_BASE`. Aborts early with a clear message if the estimate can't fit.

    -   **Hot Database Dump:** Dumps SQL/Mongo/Redis to local archives while containers run. Credentials are never passed on argv (MySQL uses `MYSQL_PWD`, Redis uses `REDISCLI_AUTH`, Mongo uses a mode-600 `--config` YAML file that's copied into the container and scrubbed on exit).

    -   **System Backup:** Stops Docker (if configured), archives AppData/System paths with `tar -S` for sparse efficiency, then *immediately* restarts Docker to minimize downtime.

    -   **Shares Backup:** Archives specified shares while the system is live.

    -   **Manifest Stamping:** Every tar archive gets a `.auto-backupper/MANIFEST.txt` written at its root before the archive seals. The manifest is a small plain-text record of the archive's provenance (host, ISO timestamp, OS, kernel, source paths, tar/compress tool versions, bash version) so a future restore can audit what's inside without extracting. Readable on demand with `tar -xOf <archive> .auto-backupper/MANIFEST.txt`. The write is best-effort: a `mktemp` failure silently falls back to an un-manifested tar rather than failing the backup.

    -   **Verify & Rotate:** Checks integrity of new files and deletes old *data* files based on `ROTATE_DAYS`. Eviction is driven off each file's dated checksum suffix (the *discovery date*, set once at first sighting), with file mtime as a fallback for anything watchtower hasn't stamped yet. **Checksums are deliberately retained** — `.checksums/` is the suite's distributed historical index (see below), so a file aging out of local storage leaves its checksum behind as evidence the backup existed. Bulk orphan-checksum cleanup is an explicit operator action via `auto-restorer.sh --prune-checksums`, not an automatic side effect of rotation.

2.  **Pull Flow:**

    -   Syncs data from remote sources defined in `REMOTE_PULL_SOURCES`.

    -   Pulls the remote's `.checksums/` *first* (additively merged into the local index), reads each file's `_<YYYYMMDD>` discovery-date suffix, and builds a per-folder `--exclude-from` list so *data* files older than the local `ROTATE_DAYS` are skipped at the wire. This is independent of when each remote runs its own rotation: even if a peer hasn't pruned its old backups yet (or has a longer retention than we do), stale data won't follow us home — while the corresponding checksums still land in our `.checksums/` index.

    -   Verifies checksums of pulled files. If corruption is detected, it re-pulls the specific file.

    -   Runs the rotation phase at the end (in `pull` and `both` modes), enforcing data retention against the freshly-merged tree.

* * * * *

🧯 Usage: Auto-Restorer
-----------------------

Read-only exploration and one-shot restores against the backup set produced by the worker. Shares the same config file and `.checksums/` layout.

```
# List every archive, grouped by systems/shares/services
./auto-restorer.sh --list

# Filter by glob (matched against the basename)
./auto-restorer.sh --list 'codebase*'

# Show the tar contents of one archive (first 100 entries)
./auto-restorer.sh --inspect /mnt/user/backup/shares/codebase/codebase_20260118.tar.gz

# Verify a single archive's checksum
./auto-restorer.sh --verify /mnt/user/backup/shares/codebase/codebase_20260118.tar.gz

# Verify every archive in BACKUP_BASE (exit 1 if any fail)
./auto-restorer.sh --verify-all

# Show watchtower's historical corruption log for this host, aggregated by path
./auto-restorer.sh --corruption-report

# Read a different host's report (useful when restoring backups onto a replacement box)
./auto-restorer.sh --corruption-report --host srv01

# Restore an archive. Explicit --target is required.
./auto-restorer.sh --restore /mnt/user/backup/shares/codebase/codebase_20260118.tar.gz \
                   --target /mnt/user

# Restore a full system archive (appdata + boot + docker.img) — stops Docker,
# extracts, restarts Docker
./auto-restorer.sh --restore /mnt/user/backup/systems/host/host_20260118.tar.gz \
                   --target / --stop-docker

# Dry-run (show planned actions, touch nothing)
./auto-restorer.sh --restore ARCHIVE --target PATH --dry-run

# Skip confirmations and create the target if missing
./auto-restorer.sh --restore ARCHIVE --target PATH --force

# Partial restore — extract only specific paths from the archive (repeatable).
# Useful when you just need one file or subtree back rather than the whole archive.
./auto-restorer.sh --restore /mnt/user/backup/systems/host/host_20260118.tar.gz \
                   --target /tmp/restore \
                   --only mnt/cache/appdata/plex \
                   --only boot/config/syslinux.cfg

# Preview which orphan checksums would be deleted if pruned (dry-run is default)
./auto-restorer.sh --prune-checksums --older-than 5y

# Actually delete them (prompts for confirmation)
./auto-restorer.sh --prune-checksums --older-than 5y --commit

# Same, but skip the confirmation prompt
./auto-restorer.sh --prune-checksums --older-than 5y --commit --force
```

### Partial Restore (`--only PATH`)

When you only need a subset of an archive (a single file, one subtree, a specific config), pass `--only PATH` one or more times to `--restore`. Each value is forwarded verbatim to tar's MEMBERS selection, so it must match the member name **as stored in the archive** — which depends on how that archive was built:

-   **`shares/` archives** store members under the share name: `--only myshare/data.txt`.
-   **`systems/` archives** are tarred with `-C /`, so members are root-relative *without* the leading slash — use `--only mnt/cache/appdata/plex` (not `appdata/plex`) and `--only boot/config/syslinux.cfg`.
-   **`shares/FamilyBackups/` archives** are tarred from the member directory with a `.` root, so every member carries a leading `./` — use `--only ./users/docs` (not `users/docs`).
-   Multiple `--only` flags combine — all matched paths are extracted in one tar pass.

When unsure of the exact prefix, run `--inspect ARCHIVE` first to list the members, then copy them into `--only`.

The restore plan shows the partial list in a `Only paths:` row and the preview reflects the filter (first 10 entries matching `--only`, not first 10 of the whole archive). **Pre-restore checksum still verifies the entire archive** because the bytes on disk haven't changed — partial extraction is safe against the same integrity guarantee as a full restore. If `--only` names a path that doesn't exist in the archive, tar exits non-zero and the restorer surfaces a clear `Extraction failed` log line.

### Restore Target Hints

Pick `--target` to match how the archive was built:

| **Source layout** | **Correct --target** |
| --- | --- |
| `shares/SHARE/*.tar.gz` | `$SHARES_BASE_FOLDER` (usually `/mnt/user`) |
| `shares/SHARE/SUB/*.tar.gz` | `$SHARES_BASE_FOLDER/SHARE` |
| `shares/FamilyBackups/...` | `PATH/TO/member/sub` |
| `systems/HOST/*.tar.gz` | `/` (re-extracts appdata, boot, docker.img — **use `--stop-docker`**) |
| `services/mysql\|mongo\|redis/*.tar.gz` | `/tmp/restore` (then import with mysql/mongorestore/etc.) |

### Pruning the Checksum Index

The `.checksums/` tree is the suite's distributed historical record (see [Checksum Layout & Discovery Dates](#-checksum-layout--discovery-dates) for the full model). Because checksums are deliberately retained when data ages out, the index grows monotonically as backups rotate across the fleet — generally harmless (entries are ~65 bytes), but eventually worth trimming.

`--prune-checksums` is the **only** operation in the suite that deletes from `.checksums/`. Use it sparingly and on much longer thresholds than `ROTATE_DAYS`:

```
./auto-restorer.sh --prune-checksums --older-than DURATION [--commit] [--force]
```

| **Flag** | **Required?** | **Meaning** |
| --- | --- | --- |
| `--older-than DURATION` | Yes | Strict grammar: `Nd` / `Nm` / `Ny` (days/months/years). E.g. `5y`, `12m`, `90d`. Anything else is rejected with a clear error. |
| `--commit` | No (default off) | Without it, the command is dry-run preview — it lists candidates but deletes nothing. Pass `--commit` to actually delete. |
| `--force` | No | Skip the confirmation prompt that `--commit` shows by default. |

**Safety invariants:**

-   **Only orphans are candidates.** A checksum is considered for deletion only if its corresponding data file is missing locally. Checksums whose data is still on disk are never touched — deleting them would leave a present-but-unverifiable backup until watchtower re-stamps it.
-   **Dry-run is the default.** Without `--commit` the command writes a candidate list to `/tmp/auto_restorer_prune.XXXXXX` (preserved for inspection) and prints a sample preview to stdout. Nothing is deleted.
-   **Confirmation by default on commit.** Even with `--commit`, you get a "Delete N orphan checksum file(s)? [y/N]" prompt unless you also pass `--force`.
-   **Strict suffix matching.** Only files whose name ends in exactly `_<8 digits>.sha256` are considered. Legacy un-dated `.sha256` files (e.g. left by old back-fills that didn't yet adopt the dated scheme) are untouched.

**Threshold guidance:** pick a duration *much* longer than your `ROTATE_DAYS`. If your fleet's longest-retention peer keeps backups for 1 year, then any checksum that's "orphaned" locally because the data file aged out within the last year is probably still held somewhere — your local checksum will re-merge on the next pull as soon as it's needed. Use `5y` or `10y` as a conservative starting point; lower it only if storage genuinely becomes a problem.

### Corruption-Report Integration

Watchtower writes a per-host append-only log to `$WATCH_DIR/$CHECKSUM_DIR/<hostname>_corruption_report.txt` every time a SHA verification fails. Because the log is never pruned, an entry means *"flagged at some point in the past,"* not *"currently corrupt."*

Auto-Restorer cross-references this log at every touchpoint, so you can tell stale entries from chronic problems at a glance:

| **Marker / term** | **Meaning** |
| --- | --- |
| `[HIST-CORRUPT]` (in `--list`) | File appears in the report at least once, SHA not yet rechecked |
| `[HIST-CORRUPT×N]` | Flagged N times — chronic problem indicator |
| `[HIST-CLEARED]` (in `--verify-all`) | File is in the report but SHA matches now (stale entry) |
| `chronic` (in a FAIL line) | File is currently failing AND has been flagged before |
| `BAD` (in `--corruption-report`) | Path still exists, SHA currently fails — active corruption |
| `OK` (in `--corruption-report`) | Path still exists, SHA matches — report entry is stale |
| `-` / `no` | Path was in the report but no longer exists (rotated away or deleted) |

**Hostname handling.** The restorer uses the canonical UPPERCASE short hostname by default (see the [Hostname Casing Convention](#-hostname-casing-convention) section for why), matching what watchtower writes. If you're running a restore on a replacement machine with a different hostname — or if you have a legacy report file from before the casing standardisation — use `--host ORIGINAL_HOSTNAME` to point at a specific name. `--host` values are passed verbatim (no case normalisation) so you can read mixed-case legacy reports literally. When the default report is missing, the tool lists any other hosts' reports it finds in `.checksums/` so you know which names are available.

**Restore safety.** The SHA compare remains authoritative — a currently-clean archive will always restore successfully. Historical events show up as a `History:` row in the restore plan and a `NOTE:` above it, so you have the chance to cancel (or to spot-check the restored data after extraction) if a file has been problematic in the past.

### Safety Behaviour

-   **Pre-restore verification is on by default.** A checksum mismatch aborts the restore with a clear message; override only with `--no-verify` if you've manually audited the archive.

-   **Confirmation prompts** unless `--force` is supplied. Restoring to `/` always shows an extra warning regardless of `--force`.

-   **Docker auto-recovery:** if the script exits while Docker is stopped (crash, Ctrl-C, error), an `EXIT` trap attempts to restart it — mirroring the worker's own recovery logic.

-   **Lockfile:** `--restore` takes an exclusive lock (`/var/lock/auto_restorer.lock`). Read-only commands (`--list`, `--verify`, `--inspect`) run without a lock so they can be used during a scheduled backup.

* * * * *

📡 Usage: Watchtower (The Daemon)
---------------------------------

This script acts as the "Cron" and "Health Monitor" of the suite. It is designed to run continuously.

```
# Start as a Daemon (Recommended for startup scripts)
./watchtower.sh --monitor &

# Live log monitor (auto-switches between backup and daemon logs)
./watchtower.sh --logs

# Manual Trigger: Docker Auto-Update
./watchtower.sh --update

# Reload Config (Without restarting the daemon)
./watchtower.sh --reload

# One-Time Checksum Scan
./watchtower.sh --scan

# Manual Trigger: File Integrity Scan
./watchtower.sh --scan --verify

# One-Time Junk Cleanup
./watchtower.sh --cleanup

# Force Start Backup
./watchtower.sh --start-backup

# Force Stop Backup
./watchtower.sh --stop-backup

# Manually define config location
./watchtower.sh --config /path/to/cfg

# One-shot daemon + scheduler snapshot (read-only; no lock; non-zero exit if daemon down)
./watchtower.sh --status

# Live full-terminal dashboard for an in-progress backup/restore
./watchtower.sh --ab-graph

# Houston-style command center — single-key shortcuts to every entry point
./watchtower.sh --hub
```

### Running under systemd

On INT/TERM the daemon waits up to `DAEMON_SHUTDOWN_GRACE` seconds (default 30) for an in-flight Docker **update** or **recovery** pass to reach a safe point, so a stop signal can't orphan a container between `docker rm` and recreate. That graceful wait only helps when the signal targets the daemon process itself. systemd's default `KillMode=control-group` signals the daemon's child tasks **directly** too, which the daemon cannot intercept — so if you schedule Docker updates/recovery and run watchtower as a systemd unit, set:

```
[Service]
KillMode=mixed
TimeoutStopSec=60   # >= DAEMON_SHUTDOWN_GRACE
```

`KillMode=mixed` sends the stop signal only to the main daemon (letting its handler shepherd the children), and `TimeoutStopSec` must be at least `DAEMON_SHUTDOWN_GRACE` so systemd doesn't SIGKILL mid-recreate.

### Live Dashboard (`--ab-graph`)

`--ab-graph` opens a read-only TUI that visualises a currently-running `auto-backupper.sh` or `auto-restorer.sh`. It's purely on-screen: nothing is written to disk and the underlying logs remain the system of record.

```
=== AB-GRAPH ===  worker=backup  PID=12345  refresh=1s  04:32:18
  Up: 03m 12s    Host: ashway    Config: /boot/config/auto_backupper.cfg

PHASES (current run):
  [x] Pre-flight Checks                       00:12 done
  [x] SQL Backup                              00:45 done
  [x] Mongo Backup                            01:08 done
  [>] Shares Backup                           01:07 active

SHARES (2/5 done):
  [x] appdata
  [x] codebase
  [>] media
  [ ] photos
  [ ] domains

CURRENT: Archiving: /mnt/user/backup/shares/codebase/codebase_20260519.tar.gz

PROCESS:
  CPU    ▂▃▃▄▅▆▆▇█▇▆▆▆▆▆▆▆▆  78%
  MEM    ▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂  1.2G
  WRITE  ▁▂▃▄▆█▇▆▅▆▇█▇▅▄▆▇█  142M/s

NETWORK (eth0, link 10G):
  RX     ▁▂▄▆█▇▆▅▄▃▂▁▁▁▁▁▁▁  142M/s
  TX     ▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁  12K/s
  Offload (TX): 87% (tx_tso_bytes)

DEST: /mnt/user/backup — 37% (1.8T / 5.0T)
  [#############..............................]

RECENT LOG:
  04:32:14  Archiving: /mnt/user/backup/shares/codebase/...
  04:32:14  VERIFIED: Checksum matches
  04:32:15  Phase: Shares Backup
  04:32:18  Archiving: /mnt/user/backup/shares/notes/...

[q] quit                                                 refresh 1s
```

**Behaviour**

-   **Worker detection** is driven off lockfiles (the same source `--status` uses), so the dashboard correctly reflects an active worker even when the PID file is missing or stale.
-   **Idle path:** if neither worker is running, the command prints a warning, falls through to `--status` output, and returns to the prompt — it never enters the loop or holds the terminal.
-   **Dependency gate:** `--ab-graph` requires `tput`, `ps`, `tail`, `df`, `stat`, `awk`. If anything is missing, it warns and exits before drawing — the rest of the suite has no such dependency. This is an opt-in flag.
-   **Quit** with `q` / `Q` / Ctrl-C; cursor + screen are restored on the way out.
-   **No persistence:** the dashboard records nothing. All historical data lives in the regular log files (`/var/log/auto_backupper.log`, `/var/log/auto_restorer.log`, etc.).

**Polling interval** is configurable via `WATCHTOWER_GRAPH_REFRESH` in `auto_backupper.cfg` (default `1` second; positive integer). Lower = snappier sparklines and faster `q` response, but more CPU per redraw. `2`–`3` is comfortable on slow hosts.

**Hardware-offload row.** When `ethtool` is installed and the active NIC's driver exposes TSO counters (Intel `ixgbe`/`i40e`/`ice`, Mellanox `mlx5`, etc.), an `Offload (TX): N%` row is rendered showing the per-interval ratio of bytes segmented by the NIC vs the kernel. On hosts where `ethtool` is absent or the driver doesn't expose counters (most consumer Realtek/Broadcom NICs, virtual interfaces), the row is hidden entirely — no `n/a` clutter. The TSO ratio is most meaningful during TX-heavy work (pushing backups to a remote NAS); a RX-heavy pull will show a small denominator and isn't an accurate signal of how hard the NIC is working — the RX sparkline is the better indicator there.

**Shares progress block.** During the `Shares Backup` phase (or one of the per-share `Granular Backup for '<name>'` phases), a SHARES checklist appears between PHASES and CURRENT. Each entry in your config's `SHARES_TO_BACKUP` array gets one row: `[x]` for shares already archived this run, `[>]` for the share currently being processed, `[ ]` for shares still pending. The header line shows the done/total count. The block is hidden entirely during every other phase. Detection runs off `Archiving:` log lines scoped to the current run, so a previous run's traffic can't contaminate the state. Long share lists are capped at 10 visible rows with a "... and N more pending" overflow line so the rest of the dashboard stays on-screen.

### Command Center (`--hub`)

`--hub` (aliases: `--center`, `--command-center`) opens a Houston-style overseer TUI for the whole suite. The header refreshes every 3 seconds with live state (daemon, backup, mover, cache, last-run timestamps, pending IPC triggers). Single-key shortcuts dispatch to every other entry point in the suite.

```
=============== WATCHTOWER COMMAND CENTER  04:32:18  ===============
  Host: ASHWAT   Config: /boot/config/auto_backupper.cfg
  Daemon: RUNNING (PID 1234, up 2d 3h 12m)
  Backup: idle         Mover: idle      Cache: 42%
  Last:   backup 2 days ago  cleanup 3 days ago  verify never  update 3 days ago
  Pending: (none)

  WATCHTOWER ACTIONS                  VIEWS
    [c]  Cleanup now                    [g]  Live Graph
    [u]  Docker Update                  [l]  Live Logs (picker)
    [k]  Checksum Scan                  [t]  Status Snapshot
    [v]  Full Verify Scan
    [R]  Reload daemon config
    [d]  Daemon: STOP    (running)
    [D]  Daemon: RESTART

  AUTO-BACKUPPER                      AUTO-RESTORER
    [s]  Start backup (cfg default)     [L]  List archives
    [p]  Start --mode produce           [A]  Verify ALL archives
    [P]  Start --mode pull              [C]  Corruption report
    [B]  Start --mode both              [I]  Inspect (prompts)
    [x]  Stop running backup            [V]  Verify single (prompts)

    [q]  Quit
====================================================================
```

**Key conventions:** lowercase letters trigger watchtower-owned actions or default sub-tool behaviour; uppercase letters distinguish "alt" modes (`p`=produce, `P`=pull) or sub-tool reads (`v`=verify scan via watchtower, `V`=verify a single archive via the restorer).

**Action behaviour:**

-   **Watchtower triggers (`c`, `u`, `k`, `v`, `R`)** drop the matching `/tmp/ab_watchtower_trigger_*` file and send `SIGUSR1` to the daemon. Identical IPC the existing standalone subcommands use — the daemon polls these files every 3 seconds. Triggers when the daemon isn't running produce a friendly "daemon not running" notice; no errors.
-   **Daemon lifecycle (`d`, `D`).** `d` is a context-aware toggle: starts the daemon when stopped, stops it when running. The label on the menu updates to show which action `d` will take ("Daemon: START (stopped)" vs "Daemon: STOP (running)"). `D` always restarts (stops if running, sleeps 1 s for the kernel to release the flock, then starts). Both prompt for confirmation once. Start re-execs `watchtower.sh --monitor` via `nohup` + `disown` so the daemon survives the hub session. Stop SIGTERMs the daemon and escalates to SIGKILL only if it doesn't exit cleanly within `DAEMON_SHUTDOWN_GRACE` + 5 seconds (default 35) — long enough for the daemon's own graceful shutdown to finish an in-flight Docker update/recovery rather than orphaning a container (the daemon's EXIT trap removes the PID/STATUS files first).
-   **Backup mode keys (`s`, `p`, `P`, `B`)** invoke `MAIN_BACKUP_SCRIPT` via `nohup … &` with the chosen `--mode`, so the worker runs detached and the hub keeps rendering. `s` uses the cfg-default `MODE`.
-   **`x` Stop backup** re-execs `watchtower.sh --stop-backup` as a child, inheriting that mode's escalating-signals logic without duplicating it.
-   **Restorer keys (`L`, `A`, `C`, `I`, `V`)** re-exec `MAIN_RESTORER_SCRIPT` with the appropriate flag, paginate output, then "press any key to return". `I` and `V` first prompt for an archive path at the bottom of the screen.
-   **`g` Live Graph** and **`l` Live Logs** re-exec `watchtower.sh --ab-graph` / `--logs` as child processes so their own SIGINT and cursor traps don't disturb the hub. `l` first asks which log to tail — all (auto-switching), watchtower, backupper, restorer, or warphole.
-   **`t` Status Snapshot** runs `cmd_status` in-process, then waits for a keypress.

**Restorer discovery.** The hub looks for `auto-restorer.sh` in this order:
1.  `MAIN_RESTORER_SCRIPT` from the config (when set).
2.  Sibling install next to `MAIN_BACKUP_SCRIPT`: `…/Auto-Restorer/script`, `…/auto-restorer.sh`.
3.  Common system paths: `/usr/local/bin/auto-restorer.sh`, `/usr/local/sbin/auto-restorer.sh`.

If none of these resolve, pressing a restorer key produces a friendly "set `MAIN_RESTORER_SCRIPT` in your cfg" notice — the rest of the hub remains usable.

**Safety conventions:**

-   Destructive-ish actions (Start backup, Stop backup, Cleanup, Update, Reload) prompt for `[y/N]` at the bottom of the screen before firing. Read-only views (Graph, Logs, Status, List, Verify, Corruption report) do not.
-   The hub takes **no lock** — it's read-only against IPC state and delegates every mutation through existing tested code paths.
-   Ctrl+C inside a sub-view returns to the hub (via a flag-based parent-side SIGINT handler that no-ops while a sub-view holds the screen). Ctrl+C at the menu itself restores the cursor and exits.

**Restore (`--restore ARCHIVE --target PATH`) is deliberately NOT a hub shortcut.** Too many required flags, too irreversible. Run that directly against `auto-restorer.sh` so the full safety surface (target hints, history banner, dry-run, force, no-verify) stays visible.

### Daemon Responsibilities

-   **Schedulers:** Checks `auto_backupper.cfg` for Backup, Cleanup, and Update schedules.

-   **Cache Monitor:** Watches cache drive usage. If it exceeds `CACHE_THRESHOLD`, it triggers the OS-specific Mover (Unraid/Internal).

-   **Docker Updater:** Checks for new images. If found, pulls and restarts containers (supports Unraid API and Docker Compose).

-   **Integrity Sentinel:** Quietly calculates checksums for new static files in the background.

* * * * *

📝 Configuration Reference (`auto_backupper.cfg`)
-------------------------------------------------

### 1. General Settings

-   `MODE`: Default operation mode (`produce`, `pull`, or `both`).

-   `CPU_THREADS`: Controls compression intensity (`all` or specific number).

-   `DRY_RUN`: Set to `true` to test configuration safely.

-   `LOG_VERBOSITY` *(default `info`)*: How much detail the suite's scripts write to their logs. **All four runtime scripts honor this**: `auto-backupper.sh`, `watchtower.sh`, `auto-restorer.sh`, and `warphole.sh`. Four levels, most-restrictive first:

    | Value | What's logged | What's suppressed |
    | --- | --- | --- |
    | `error` | ERROR / FATAL / CRITICAL / WARN lines | Everything else |
    | `phase` | Phase markers, archive announcements, ACTION lines, scheduler events, errors | Per-file output, INFO chatter |
    | `info` *(default)* | All script-level logging, phase markers, archives, per-file checksum events, errors | `tar -v` per-file lines (auto-backupper), `rsync --progress` per-file lines, DEBUG tags |
    | `debug` | Everything — every file archived, every byte rsynced, all chatter, all DEBUG-tagged lines | Nothing |

    On hosts with big shares (think tens of thousands of files), a single archive at `debug` can produce 100+ MB of `tar -v` output. At the default `info` level, the same run logs a few KB. Pick `debug` only when actively diagnosing.

    Per-script level mappings differ slightly to reflect each script's prefix conventions (e.g. watchtower's `NEW CHECKSUM:` lines are info-tier, the restorer's `RESTORE SUCCEEDED:` is phase-tier). The model is identical; the prefix tables are tuned.

-   `LOG_MAX_SIZE` *(default `10 * 1024 * 1024` = 10 MB)*: Rotation threshold, honored by all four runtime scripts. Once the log reaches this size — even mid-run — it gets rotated. Rotation uses `cp + truncate` (not `mv`) so any held-open file descriptor (auto-backupper's `tee` redirect, warphole's `tee` redirect) keeps writing to the right inode.

-   `LOG_BACKUPS` *(default `5`)*: How many rotated archive copies each script retains (`.log.1` through `.log.N`).

### 2. Docker Strategy

-   `DOCKER_MODE`:

    -   `unraid_service`: Uses `/etc/rc.d/rc.docker`.

    -   `container`: Stops/Starts specific containers found running.

    -   `disabled`: Ignores Docker (risk of database inconsistency).

    -   `auto`: Attempts to guess the best method.

### 3. Database Settings

Set `BACKUP_SQL`, `BACKUP_MONGO`, or `BACKUP_REDIS` to `true`.

-   *Security Note:* Ensure `auto_backupper.cfg` is `chmod 600` if it contains passwords.

-   *Argv-safe:* database passwords are passed through environment variables (`MYSQL_PWD`, `REDISCLI_AUTH`) or short-lived mode-600 credential files (Mongo), never on the command line. This keeps credentials out of `ps`, `/proc/<pid>/cmdline`, and anything that scrapes them (container monitoring sidecars, audit logs, etc.).

### 4. Retention & Pre-Flight

-   `ROTATE_DAYS`: Days to keep local backups (0 = forever).

-   `VERIFY_LOCAL_BACKUPS` / `VERIFY_PULLED_BACKUPS`: Checksum-verify the files touched this run.

-   `PREFLIGHT_SPACE_CHECK` *(default `true`)*: Estimate source size before starting and abort if `BACKUP_BASE` can't fit it. Set `false` on destinations with unreliable `df` reporting.

-   `PREFLIGHT_COMPRESSION_RATIO` *(default `0.4`)*: Expected on-disk size as a fraction of uncompressed source. `0.4` is deliberately pessimistic (matches media/db-heavy datasets); lower it (e.g. `0.2`) if your shares are mostly text and the check is too conservative.

-   `PREFLIGHT_MARGIN_BYTES` *(default `1073741824` = 1 GiB)*: Extra headroom beyond the ratio-adjusted estimate — covers rotation overlap and metadata.

### 5. Schedules (Watchtower)

Format options: `daily`, `weekly`, `monthly`, `quarterly`, `annually`.

-   `BACKUP_SCHEDULER_ENABLE`: Toggles the main backup job.

-   `UPDATE_SCHEDULER_ENABLE`: Toggles Docker auto-updates.

-   `VERIFY_SCHEDULER_ENABLE`: Toggles deep file verification (High I/O).

-   `CLEANUP_SCHEDULER_ENABLE`: Toggles junk-file cleanup (Apple metadata, optional media `.nfo`/`.txt`).

### 6. Notifications

The suite ships with two notification paths and they always fire together when both are configured: an OS-native channel (Unraid web banner, OMV, `notify-send`), and an optional remote webhook for chat/phone.

-   `NOTIFY_WEBHOOK_URL` *(default empty = disabled)*: When set, every `send_notify` call from `auto-backupper.sh` and `watchtower.sh` also POSTs to this URL. Failures are silent and bounded by `curl --max-time` so a hung endpoint can't stall a backup or wedge the daemon's poll loop. Off by default — the suite is fully functional without it.

-   `NOTIFY_WEBHOOK_FORMAT` *(default auto-detected)*: Payload shape for the webhook. Auto-detection picks `discord` for URLs containing `discord.com` / `discordapp.com`, `slack` for `slack.com` / `slack-edge.com`, and `generic` for everything else. Explicit values:

    | Value | Payload |
    | --- | --- |
    | `discord` | `{"username":"...", "content":"[LEVEL] **title**\nmessage"}` |
    | `slack`   | `{"text":"*[LEVEL] title*\nmessage\n_host: HOSTNAME_"}` |
    | `ntfy`    | Plain body + `Title`, `Priority`, `Tags` headers (ntfy.sh convention). Must be set explicitly — URL host varies for self-hosted instances. |
    | `generic` | `{"host","level","title","message","timestamp"}` JSON, suitable for custom collectors / Apprise / etc. |

### 7. Dashboard & Tooling

-   `MAIN_BACKUP_SCRIPT`: Absolute path to `auto-backupper.sh`. Used by watchtower's schedulers and by the `--hub` command center.

-   `MAIN_RESTORER_SCRIPT` *(optional, auto-detected when empty)*: Absolute path to `auto-restorer.sh`. The hub uses this for its `[L]`/`[A]`/`[C]`/`[I]`/`[V]` shortcuts. When empty, the hub probes `…/Auto-Restorer/script`, `…/auto-restorer.sh`, `/usr/local/bin/auto-restorer.sh`, `/usr/local/sbin/auto-restorer.sh`. Set explicitly only when your layout differs from these conventions.

-   `WATCHTOWER_GRAPH_REFRESH` *(default `1`)*: Polling interval (seconds) for the `--ab-graph` live dashboard. Lower = snappier sparklines and faster `q` response, but more CPU per redraw. `2`–`3` is comfortable on slow hosts. Must be a positive integer; non-numeric or `<1` falls back to `1` with a notice.

-   `CORRUPTION_REPORT_MAX_SIZE` *(default `1048576` = 1 MiB)*: Watchtower rotates the per-host corruption report when it exceeds this size (same N-backup scheme as the daemon log). Without this, a host with chronic disk-flake corruption would accumulate an unbounded report file.

* * * * *

🆎 Hostname Casing Convention
-----------------------------

Every hostname-derived path or filename in the suite is **UPPERCASE**:

-   `BACKUP_BASE/systems/<HOST>/...`
-   `BACKUP_BASE/systems/<HOST>/<HOST>_<YYYYMMDD>.tar.gz`
-   `BACKUP_BASE/.checksums/<HOST>_corruption_report.txt`
-   `BACKUP_BASE/services/pihole/<HOST>/<HOST>_pihole_<YYYYMMDD>.zip` (warphole output)

The canonical form is set once at the top of each script via:

```
HOSTNAME_VAR="$(hostname | cut -d. -f1 | tr '[:lower:]' '[:upper:]')"
```

**Why normalise.** The OS-returned hostname casing drifts across environments — Unraid hands back uppercase, Debian usually lowercase, some init systems flip it at boot. Without normalisation, a host whose returned casing changes between runs produces parallel artifact trees (`systems/DAEDALUS/` and `systems/daedalus/`) that retention can't reconcile.

**Override.** Set `HOSTNAME_VAR="my-host"` in `auto_backupper.cfg` to opt out (e.g. you have an established lowercase tree and don't want to migrate). The config is sourced after the script's default, so any value you set wins.

**Migration.** When `auto-backupper.sh` or `watchtower.sh` starts a write-mode run, it scans `BACKUP_BASE/systems/` and `.checksums/` for case-variants of the canonical name. Any drifted artifact gets a WARN log line with the exact `mv` / `cat` command to consolidate:

```
WARN: Found case-variant hostname directory: /mnt/user/backup/systems/daedalus/
      Suite now uses UPPERCASE canonical: /mnt/user/backup/systems/DAEDALUS/
      Migrate: mkdir -p '/mnt/user/backup/systems/DAEDALUS' && mv '/mnt/user/backup/systems/daedalus/'* '/mnt/user/backup/systems/DAEDALUS/' && rmdir '/mnt/user/backup/systems/daedalus'
      Or set HOSTNAME_VAR="daedalus" in /boot/config/auto_backupper.cfg to keep current behaviour.
```

No auto-migration: rewriting a populated backup tree without operator review is unsafe. Read the warning, decide whether to consolidate or override, then proceed.

* * * * *

📜 Embedded Manifest
--------------------

Every tar archive produced by `auto-backupper.sh` carries a small plain-text manifest at `.auto-backupper/MANIFEST.txt`. It captures everything needed to audit an archive's provenance without extracting it:

```
$ tar -xOf /mnt/user/backup/systems/DAEDALUS/DAEDALUS_20260519.tar.gz \
      .auto-backupper/MANIFEST.txt
# Auto-Backupper archive manifest
archive: DAEDALUS_20260519.tar.gz
created_at: 2026-05-19T04:32:18Z
host: DAEDALUS
host_long: daedalus.lan
os: unraid
kernel: Linux 6.6.20-Unraid x86_64
base_dir: /
source_paths:
  - /mnt/cache/appdata
  - /boot
  - /mnt/disks/docker.img
tools:
  tar: tar (GNU tar) 1.35
  compress: pigz -p 12
  bash: 5.2.21(1)-release
```

**Why it's at `.auto-backupper/MANIFEST.txt` (not the archive root).** Restoring to a populated tree would otherwise drop a bare `MANIFEST.txt` into your share. A hidden subdirectory is discoverable but unobtrusive — and `tar -xOf … .auto-backupper/MANIFEST.txt` reads it without writing anything to disk.

**Best-effort write.** The manifest is bonus, not required. A `mktemp` failure (full `/tmp`, etc.) silently falls back to an un-manifested archive — the backup itself still succeeds.

**Not produced by warphole.** The Pi-hole Teleporter zip is generated by `pihole-FTL` and we don't repack it. Warphole instead writes a dated SHA-256 checksum next to the zip so it joins the same `.checksums/` discovery-date index as everything else.

* * * * *

🗓️ Checksum Layout & Discovery Dates
-------------------------------------

Every backup artifact in the suite has a companion `.sha256` under `BACKUP_BASE/.checksums/` whose filename embeds a *discovery date* — the date the file was first observed by whichever script stamped it. That date is the source of truth for retention.

### Filename convention

For a data file `<relpath>/<name>` under `BACKUP_BASE`, the checksum lives at:

```
BACKUP_BASE/.checksums/<relpath>/<name>_<YYYYMMDD>.sha256
```

The full data filename is preserved (extensions included) and `_<YYYYMMDD>.sha256` is appended. Files we produce with a `_<CDATE>` already in their name therefore carry the date twice in the checksum filename (e.g. `codebase_20260118.tar.gz_20260118.sha256`) — that redundancy is intentional, so the suffix is always present and parsing is single-path everywhere.

### Where the date comes from

| **Origin** | **Date source** |
| --- | --- |
| `auto-backupper.sh` produce flow | `$CDATE` of the run that created the archive — stamped immediately after `tar` finalizes. |
| `warphole.sh` Pi-hole backup | `$CDATE` of the run — stamped immediately after the destination zip lands and `unzip -t` passes. |
| `watchtower.sh` first sighting | Today's date when watchtower first sees a stable, unstamped file (covers externally-uploaded backups whose filenames don't carry a date). |
| `legacy-checksum-generatator.sh` back-fill | Embedded `_<YYYYMMDD>` in the filename if present (last 8-digit group wins, matching our produce-flow convention), otherwise mtime as `YYYYMMDD`. |

### Why a portable date

`rsync --archive` preserves the source's mtime, so a file pulled today still looks "old" by mtime if the remote wrote it months ago. That breaks mtime-driven retention in any multi-host topology — each peer's pull would either evict perfectly fresh files or, more dangerously, accept stale files the peer was about to rotate. The dated suffix solves it: every host reads age from the same place, regardless of when the file was transmitted.

### `.checksums/` is a distributed historical index

Every server's `.checksums/` accumulates the union of every checksum that ever existed across the fleet — the tree is meant to be append-mostly. A checksum is evidence that a file existed at a given date with a given hash. Even after every server has aged out a particular data file, the checksum stays as historical record (and as the means by which any peer can re-verify the file later if it's ever recovered from backup tapes or a long-retention archive node). At ~65 bytes per entry, the index grows slowly relative to backup-data sizes.

### How retention uses it

-   **Pull-side filter** (`auto-backupper.sh`'s `pull_flow`): the remote's `.checksums/` is rsynced first (additively — checksums always merge), suffix dates are parsed, and any *data* file older than `ROTATE_DAYS` is added to a per-folder `--exclude-from` so it's skipped at the wire. The matching checksum still lands in the local `.checksums/` index.
-   **Rotation phase** (`auto-backupper.sh`'s `rotation_phase`): walks data files, takes each one's newest dated suffix (or mtime as fallback), and evicts the data file if older than `ROTATE_DAYS`. The checksum is preserved.
-   **Bulk index trim** (`auto-restorer.sh --prune-checksums --older-than DURATION`): the only operation that deletes from `.checksums/`. Off by default, run on demand, and defaults to dry-run output until you pass `--commit`. Recommended threshold is *much* larger than `ROTATE_DAYS` (years rather than days) so the index has time to round-trip through any indefinite-retention peer in the fleet before being trimmed.

### Atomic writes

Every checksum write goes through `temp + mv -f`. A torn checksum (process killed between the hash being computed and the redirect flushing) would otherwise read as a false-positive corruption on the next verify. Stale dated siblings are also swept before each new write, so steady-state always holds at most one dated checksum per data file.

### Migrating a legacy tree

Run `./legacy-checksum-generatator.sh /path/to/backups` once to bring any pre-existing tree up to the dated-suffix scheme. For every archive it walks, the script picks the lowest-impact action available:

| Found | Action | Log tag |
| --- | --- | --- |
| Dated `<name>_<YYYYMMDD>.sha256` with suffix matching the filename's embedded date (or no embedded date in the filename) | Skip — already canonical | (silent) |
| Dated `<name>_<DATE>.sha256` whose suffix DIFFERS from the filename's embedded date | **Rename** the checksum so its suffix matches the embedded date. Hash is preserved — no recompute, so the original integrity statement carries forward. Typical cause: watchtower's first-sighting stamps "today", which can disagree with a date already in the filename. | `[REALIGN old→new]` |
| Two or more dated siblings for the same file | Don't pick a winner — flag for operator review | `[SKIP-MULTI]` |
| Both source and target dated names already exist with different dates | Don't pick a winner | `[CONFLICT]` |
| Un-dated `<name>.sha256` in `.checksums/<relpath>/` | **Promote** to dated form (rename in place). Hash preserved. | `[PROMOTE in-dir <date_source> <date>]` |
| Un-dated `<name>.sha256` next to the data file | **Promote** to dated form (moved into `.checksums/`). Hash preserved. | `[PROMOTE next-to-file <date_source> <date>]` |
| Legacy file present but empty / contains no sha256-shaped hex | Falls through to fresh generation | `[INVALID-LEGACY]` then `[GEN ...]` |
| No checksum exists at all | Compute a new SHA-256 (atomic temp + rename) | `[GEN <date_source> <date>]` |

Both `REALIGN` and `PROMOTE` deliberately keep the historical hash rather than recomputing — a fresh hash today would mask any silent bit-rot that happened between when the original checksum was taken and now. Renaming preserves the first verify-pass's ability to flag corruption.

`--force` short-circuits the whole tree: it sweeps every dated and un-dated variant for each file, then re-runs the `GEN` path. Use sparingly — you're throwing away the historical integrity statements that REALIGN and PROMOTE protect.

The script's date-source label (`embedded` from the filename's `_<YYYYMMDD>` suffix, or `mtime` fallback) shows up in every `GEN` log line so scan-lag and misnamed files are visible up front. Subsequent watchtower scans are no-ops on anything already stamped.

* * * * *

🛡️ Recovery & Safety
---------------------

-   **Idempotency:** The scripts use lockfiles (`/var/lock/`) to prevent overlapping runs. The worker, daemon, and restorer all take separate locks so read-only restorer commands can run during a scheduled backup.

-   **State Recovery:** If the worker crashes while Docker is stopped, the next run (or trap handler) detects the `DOCKER_STOPPED=true` state in `/tmp/enclave/ab_state` and forces a restart. The restorer carries its own Docker trap for the same reason.

-   **Pre-flight abort:** Space, writability, binary availability, and remote-mount checks all run before a single byte is written. An abort here leaves the system untouched.

-   **Refuse-on-corrupt restore:** `auto-restorer.sh --restore` hashes the archive before extracting and refuses a mismatch unless `--no-verify` is explicitly passed.

-   **Atomic PIDs:** The worker writes `/var/run/auto_backupper.pid` on startup so `watchtower --stop-backup` can identify the process reliably (no `pgrep -f` false matches against editors, `grep` processes, etc.). Watchtower cross-checks `/proc/<pid>/cmdline` before sending signals.

-   **Corruption Reports:** Watchtower logs corruption events to `.checksums/HOSTNAME_corruption_report.txt`.

* * * * *

⚠️ Requirements
---------------

-   **Bash** 4.0+

-   **Root Privileges** (Required for Docker management and file access)

-   **Dependencies:** `tar`, `rsync`, `curl`, `sha256sum`, `awk`, `find`, `du`, `df`.

    -   *Optional but Recommended:* `pigz` (for multi-threaded compression), `shred` (used to securely wipe temporary credential files).

    -   *For Mongo backup:* `mongodb-database-tools` 100.0+ inside the Mongo container (for `mongodump --config`, released Aug 2020 — present in every supported Mongo image).

* * * * *

📜 License
----------

GPLv3 - Copyright (C) 2025 Jon Stroh

* * * * *