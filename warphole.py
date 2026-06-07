#!/usr/bin/env python3
import os
import sys
import subprocess
import shutil
import time
import json
import socket
import datetime
import hashlib
from typing import Optional

# ==============================================================================
# 1. CONFIGURATION (Faithfully mirrored from .sh)
# ==============================================================================
CONFIG = {
    "DEFAULT_MODE": "",  # "check", "backup", "stats", or ""
    "HOSTNAME_VAR": socket.gethostname().split(".")[0],
    "LOGFILE": "/var/log/warphole.log",
    "REPAIR_MARKER": "/etc/pihole/gravity_repair_pending",
    "IS_DOCKER": True,
    "DOCKER_CONTAINER_NAME": "pihole-v6-unbound",
    "DESTINATION_TYPE": "local",  # "smb" or "local"
    "SMB_HOST": "127.0.0.1",
    "SMB_SHARE": "backup",
    "SMB_SUBFOLDER": f"services/pihole/{socket.gethostname().split('.')[0]}",
    "SMB_USER": "UserName",
    "SMB_PASS": "YourPasswordHere!",
    "MOUNT_POINT": "/mnt/backups",
    "PI_URL": "http://127.0.0.1/api",
    "PI_PASSWORD": "",
    "REFRESH_RATE": 2,
    "TEMP_DIR": "/tmp/pihole_backup_staging",
    "GRAVITY_LOG": "/tmp/gravity_update.log",
}

# Calculated Path
CONFIG[
    "LOCAL_EXPORT_PATH"
] = f"/mnt/user/{CONFIG['SMB_SHARE']}/{CONFIG['SMB_SUBFOLDER']}"

# Global Runtime State
state = {
    "sid": None,
    "keep_local": False,
    "manage_mount": True,
    "mode": "",
}

# ==============================================================================
# 2. DEPENDENCY & ENVIRONMENT CHECK
# ==============================================================================


def check_dependencies():
    """Checks for required Python packages and system binaries."""
    missing_packages = []
    try:
        import requests
    except ImportError:
        missing_packages.append("requests")
    try:
        import rich
    except ImportError:
        missing_packages.append("rich")

    if missing_packages:
        print(f"MISSING DEPENDENCIES: {', '.join(missing_packages)}")
        choice = input("Would you like to install them now via pip? (y/n): ").lower()
        if choice == "y":
            subprocess.check_call(
                [sys.executable, "-m", "pip", "install", *missing_packages]
            )
            print("Dependencies installed. Please restart the script.")
            sys.exit(0)
        else:
            print("FATAL: Cannot continue without dependencies.")
            sys.exit(1)

    # Check system binaries
    binaries = ["curl", "jq", "awk", "uptime"]
    if CONFIG["IS_DOCKER"]:
        binaries.append("docker")

    for bin in binaries:
        if not shutil.which(bin):
            print(f"FATAL: System binary '{bin}' is missing.")
            sys.exit(1)


def log(message):
    timestamp = datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
    formatted_msg = f"{timestamp} {message}"
    print(formatted_msg)
    try:
        with open(CONFIG["LOGFILE"], "a") as f:
            f.write(formatted_msg + "\n")
    except PermissionError:
        pass


# ==============================================================================
# 3. UTILITIES
# ==============================================================================


def authenticate():
    import requests

    if CONFIG["PI_PASSWORD"]:
        try:
            r = requests.post(
                f"{CONFIG['PI_URL']}/auth",
                json={"password": CONFIG["PI_PASSWORD"]},
                timeout=5,
            )
            data = r.json()
            state["sid"] = data.get("session", {}).get("sid")
            if not state["sid"] and state["mode"] != "stats":
                log(
                    f"Auth Failed: {data.get('session', {}).get('message', 'Unknown error')}"
                )
                sys.exit(1)
        except Exception as e:
            if state["mode"] != "stats":
                log(f"API connection failed: {e}")
                sys.exit(1)


def mount_smb():
    if os.path.ismount(CONFIG["MOUNT_POINT"]):
        log(f"INFO: Mount point {CONFIG['MOUNT_POINT']} is already active.")
        return

    os.makedirs(CONFIG["MOUNT_POINT"], exist_ok=True)
    log(f"ACTION: Mounting //{CONFIG['SMB_HOST']}/{CONFIG['SMB_SHARE']}...")

    cmd = [
        "mount",
        "-t",
        "cifs",
        f"//{CONFIG['SMB_HOST']}/{CONFIG['SMB_SHARE']}",
        CONFIG["MOUNT_POINT"],
        "-o",
        f"username={CONFIG['SMB_USER']},password={CONFIG['SMB_PASS']},vers=3.0,iocharset=utf8",
    ]

    result = subprocess.run(cmd, capture_output=True)
    if result.returncode == 0:
        log("SUCCESS: Share mounted.")
    else:
        log(f"FATAL: Failed to mount SMB share: {result.stderr.decode()}")
        sys.exit(1)


def cleanup():
    if os.path.exists(CONFIG["TEMP_DIR"]) and not state["keep_local"]:
        shutil.rmtree(CONFIG["TEMP_DIR"])

    if CONFIG["DESTINATION_TYPE"] == "smb" and state["manage_mount"]:
        if os.path.ismount(CONFIG["MOUNT_POINT"]):
            if state["mode"] != "stats":
                log("Cleanup: Unmounting share...")
            subprocess.run(["umount", "-l", CONFIG["MOUNT_POINT"]])

    if state["sid"]:
        import requests

        requests.delete(f"{CONFIG['PI_URL']}/auth", headers={"X-FTL-SID": state["sid"]})


# ==============================================================================
# 4. CORE MODES (BACKUP / CHECK / STATS)
# ==============================================================================


def run_backup():
    log(f"=== Starting Pi-hole Backup (Docker: {CONFIG['IS_DOCKER']}) ===")

    final_dest = (
        CONFIG["MOUNT_POINT"] + "/" + CONFIG["SMB_SUBFOLDER"]
        if CONFIG["DESTINATION_TYPE"] == "smb"
        else CONFIG["LOCAL_EXPORT_PATH"]
    )
    if CONFIG["DESTINATION_TYPE"] == "smb":
        mount_smb()
    else:
        state["manage_mount"] = False

    os.makedirs(final_dest, exist_ok=True)
    os.makedirs(CONFIG["TEMP_DIR"], exist_ok=True)

    log("Phase: Generating Teleporter Archive...")
    if CONFIG["IS_DOCKER"]:
        subprocess.run(
            [
                "docker",
                "exec",
                "-w",
                "/tmp",
                CONFIG["DOCKER_CONTAINER_NAME"],
                "pihole-FTL",
                "--teleporter",
            ],
            check=True,
        )
        docker_ls = (
            subprocess.check_output(
                [
                    "docker",
                    "exec",
                    CONFIG["DOCKER_CONTAINER_NAME"],
                    "sh",
                    "-c",
                    "ls -t /tmp/*.zip | head -n1",
                ]
            )
            .decode()
            .strip()
        )
        subprocess.run(
            [
                "docker",
                "cp",
                f"{CONFIG['DOCKER_CONTAINER_NAME']}:{docker_ls}",
                CONFIG["TEMP_DIR"] + "/",
            ],
            check=True,
        )
        subprocess.run(
            ["docker", "exec", CONFIG["DOCKER_CONTAINER_NAME"], "rm", docker_ls]
        )
    else:
        subprocess.run(
            ["pihole-FTL", "--teleporter"], cwd=CONFIG["TEMP_DIR"], check=True
        )

    # Find file
    zips = [f for f in os.listdir(CONFIG["TEMP_DIR"]) if f.endswith(".zip")]
    if not zips:
        log("FATAL: Backup file not found.")
        sys.exit(1)

    src = os.path.join(CONFIG["TEMP_DIR"], zips[0])
    target_name = f"{CONFIG['HOSTNAME_VAR']}_pihole_{datetime.datetime.now().strftime('%Y%m%d')}.zip"
    dst = os.path.join(final_dest, target_name)

    shutil.copy2(src, dst)

    # Checksum
    with open(src, "rb") as f:
        src_sum = hashlib.sha256(f.read()).hexdigest()
    with open(dst, "rb") as f:
        dst_sum = hashlib.sha256(f.read()).hexdigest()

    if src_sum == dst_sum:
        log(f"VERIFIED: Checksum matches ({src_sum[:10]}...)")
    else:
        log("ERROR: Checksum mismatch!")
        sys.exit(1)


def run_health_check():
    import requests

    log("=== Starting Pi-hole Health Check ===")

    if os.path.exists(CONFIG["REPAIR_MARKER"]):
        log("RECOVERY: Found repair marker. Pulling Gravity...")
        cmd = (
            ["docker", "exec", CONFIG["DOCKER_CONTAINER_NAME"], "pihole", "-g"]
            if CONFIG["IS_DOCKER"]
            else ["pihole", "-g"]
        )
        subprocess.run(cmd)
        os.remove(CONFIG["REPAIR_MARKER"])
        return

    authenticate()
    headers = {"X-FTL-SID": state["sid"]} if state["sid"] else {}
    try:
        data = requests.get(f"{CONFIG['PI_URL']}/padd", headers=headers).json()
        domains = int(data.get("gravity_size", 0))
    except:
        log("ERROR: Invalid API response.")
        sys.exit(1)

    if domains <= 0:
        log("CRITICAL: 0 domains blocked! Repairing...")
        cmd = (
            ["docker", "exec", CONFIG["DOCKER_CONTAINER_NAME"], "pihole", "-g"]
            if CONFIG["IS_DOCKER"]
            else ["pihole", "-g"]
        )
        success = subprocess.run(cmd).returncode == 0

        if not success:
            # Low RAM Reboot Logic
            total_ram = int(
                subprocess.check_output(["free", "-m"])
                .decode()
                .splitlines()[1]
                .split()[1]
            )
            if not CONFIG["IS_DOCKER"] and total_ram < 1024:
                log(f"ACTION: Low memory ({total_ram}MB). Rebooting...")
                with open(CONFIG["REPAIR_MARKER"], "w") as f:
                    f.write("reboot")
                subprocess.run(["reboot"])
            else:
                log("WARNING: Skipping reboot repair.")
                sys.exit(1)
    else:
        log(f"HEALTHY: Gravity looks good ({domains} domains).")


def run_stats():
    import requests
    from rich.live import Live
    from rich.panel import Panel
    from rich.layout import Layout
    from rich.console import Console
    from rich.progress import BarColumn, Progress, TextColumn

    console = Console()
    authenticate()

    prev_queries = 0
    first_run = True

    def get_data():
        headers = {"X-FTL-SID": state["sid"]} if state["sid"] else {}
        return requests.get(f"{CONFIG['PI_URL']}/padd", headers=headers).json()

    with Live(auto_refresh=False, screen=True) as live:
        while True:
            try:
                data = get_data()

                # Calculations
                total = data.get("queries", {}).get("total", 0)
                qps = (
                    0
                    if first_run
                    else round((total - prev_queries) / CONFIG["REFRESH_RATE"], 1)
                )
                prev_queries = total
                first_run = False

                # UI Construction using Rich
                layout = Layout()
                layout.split_column(
                    Layout(name="header", size=3),
                    Layout(name="main", size=10),
                    Layout(name="footer", size=6),
                )

                layout["header"].update(
                    Panel(
                        f"WARPHOLE v3.2 [Python] - {CONFIG['HOSTNAME_VAR']} | {datetime.datetime.now().strftime('%H:%M:%S')}",
                        style="blue",
                    )
                )

                main_stats = (
                    f"[cyan]QUERIES (QPS):[/] [green]{total} ({qps}/s)[/]\n"
                    f"[cyan]BLOCKED:[/][red]      {data.get('queries', {}).get('blocked', 0)}[/]\n"
                    f"[cyan]BLOCK %:[/][yellow]      {data.get('queries', {}).get('percent_blocked', 0)}%[/]\n"
                    f"[cyan]MEM USAGE:[/][green]    {data.get('system', {}).get('memory', {}).get('ram', {}).get('%used', 0)}%[/]"
                )
                layout["main"].update(Panel(main_stats, title="Core Stats"))

                footer_text = (
                    f"[cyan]TOP DOMAIN:[/]  {data.get('top_domain', 'None')}\n"
                    f"[cyan]TOP BLOCKED:[/] [red]{data.get('top_blocked', 'None')}[/]\n"
                    f"[cyan]GRAVITY:[/]     {data.get('gravity_size', 0)} domains"
                )
                layout["footer"].update(Panel(footer_text, title="Insights"))

                live.update(layout, refresh=True)
                time.sleep(CONFIG["REFRESH_RATE"])
            except KeyboardInterrupt:
                break


# ==============================================================================
# 5. EXECUTION ROUTER
# ==============================================================================

if __name__ == "__main__":
    if os.getuid() != 0:
        print("CRITICAL: This script must be run as root.")
        sys.exit(1)

    check_dependencies()

    import argparse

    parser = argparse.ArgumentParser(description="Warphole v3.2 Python Edition")
    parser.add_argument("--backup-now", action="store_true")
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--stats", action="store_true")
    parser.add_argument("--keep-local", action="store_true")

    args = parser.parse_args()
    state["keep_local"] = args.keep_local

    import atexit

    atexit.register(cleanup)

    if args.backup_now:
        state["mode"] = "backup"
        run_backup()
    elif args.check:
        state["mode"] = "check"
        run_health_check()
    elif args.stats:
        state["mode"] = "stats"
        run_stats()
    elif CONFIG["DEFAULT_MODE"]:
        state["mode"] = CONFIG["DEFAULT_MODE"]
        if state["mode"] == "backup":
            run_backup()
        elif state["mode"] == "check":
            run_health_check()
        elif state["mode"] == "stats":
            run_stats()
    else:
        parser.print_help()