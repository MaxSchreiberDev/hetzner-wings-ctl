# wings-ctl

A minimal Bash CLI for managing a Hetzner Cloud game server — spin it up from a snapshot, schedule automatic shutdown with backup, and track costs. Built for a [Pterodactyl](https://pterodactyl.io/) wings node that only needs to run on demand.

---

## Why

Running a game server 24/7 is wasteful. This script lets you boot the server when needed, set a shutdown timer, and automatically snapshot before deletion — so you only pay for what you use.

---

## How it works

```
wings-ctl up          # Create server from latest snapshot + start timer
wings-ctl down        # Snapshot + delete server
wings-ctl status      # Show server state, timer info & snapshot costs
wings-ctl schedule    # Change/reset the shutdown timer
wings-ctl cancel      # Cancel the shutdown timer (keeps server running)
wings-ctl kill        # Delete server immediately, no backup
wings-ctl rm <id>     # Delete a specific snapshot
```

---

## Usage examples

```bash
# Boot server, auto-shutdown in 4 hours (default)
./wings-ctl up

# Boot from a specific snapshot, shutdown in 2 hours, custom backup name
./wings-ctl up 12345678 --time 2h --name "before-update"

# Boot without creating a backup on shutdown
./wings-ctl up --no-backup

# Boot without starting a timer at all
./wings-ctl up --no-timer

# Extend or change the timer while server is running
./wings-ctl schedule 1h

# Check server state, timer, snapshots and monthly snapshot cost
./wings-ctl status

# Shutdown now with a custom snapshot name
./wings-ctl down "post-session-backup"

# Nuke the server immediately (no snapshot)
./wings-ctl kill
```

---

## Setup

**Requirements:**
- [hcloud CLI](https://github.com/hetznercloud/cli) installed and in `$PATH`
- A Hetzner Cloud account with at least one snapshot labeled `type=wings-backup`

**1. Clone and make executable**
```bash
git clone https://github.com/yourusername/wings-ctl.git
cd wings-ctl
chmod +x wings-ctl.sh
```

**2. Configure the script**

Open `wings-ctl.sh` and edit the config block at the top:

```bash
export HCLOUD_TOKEN="your_token_here"

SERVER_NAME="wings-node"       # Name for the created server
SERVER_TYPE="cax21"            # Hetzner server type
LOCATION="hel1"                # Datacenter location
PRIMARY_IP_NAME="your-ip-name" # Name of your reserved primary IP
SSH_KEY_NAME="your-key-name"   # SSH key registered in Hetzner
PRICE_PER_GB=0.0143            # Snapshot cost per GB/month (check Hetzner pricing)
```

**3. (Optional) Add to PATH**
```bash
sudo ln -s $(pwd)/wings-ctl.sh /usr/local/bin/wings-ctl
```

---

## Timer behavior

When you run `wings-ctl up`, a background timer starts (default: 4 hours). When it expires, the script automatically:
1. Creates a snapshot of the server
2. Deletes the server

The timer survives terminal sessions via `nohup`. You can check remaining time, cancel, or reschedule at any time with `status`, `cancel`, or `schedule`.

Desktop notifications are sent on shutdown if `notify-send` is available.

---

## Snapshot labels

All snapshots created by this script are labeled `type=wings-backup`. The `up` command always boots from the most recently created snapshot with this label, so the workflow is fully automatic after initial setup.

---

## Notes

- Developed with AI assistance (Claude)
- Tested on Arch Linux / CachyOS with hcloud CLI v1.x
- Not affiliated with Hetzner or Pterodactyl
