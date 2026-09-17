# openclaw-vnc

A Ubuntu 26.04 container image with a VNC desktop (xfce4 + Firefox), [openclaw](https://github.com/openclaw/openclaw) (CLI/Gateway) preinstalled, the GitHub CLI (`gh`), and the Claude Code CLI (`claude`). Container PID 1 is a real system-level `systemd`, so `openclaw gateway install/start/stop/restart` go through standard systemd service management.

*(A Chinese version of this document is available at [README_CN.md](README_CN.md).)*

## Prerequisites

- A Linux host (this repo was developed and verified on Ubuntu; other distributions work the same way in principle)
- [Podman](https://podman.io/), rootless mode, 5.x recommended (developed and verified on podman 5.7)
- The current user already has a subuid/subgid range assigned (modern distros usually set this up automatically when the user is created via `useradd`; check with the command below):

  ```bash
  grep "^$(whoami):" /etc/subuid /etc/subgid
  ```

  If there's no output, assign a range first with something like `sudo usermod --add-subuids 231072-296607 --add-subgids 231072-296607 $(whoami)`, then log back in.

## Quick start

```bash
git clone https://github.com/liuweiseu/openclaw-container.git openclaw-container
cd openclaw-container

# 1. Create the three runtime data directories (not shipped in the repo, see
#    "Directory overview" below)
mkdir -p data openclaw_data openclaw_systemd_user

# 2. Fix ownership: under rootless podman, the container's node user (uid 1001)
#    maps to a subuid on the host, not your own host user, so a plain chown
#    can't do it — use podman unshare instead
podman unshare chown -R 1001:1001 data openclaw_data openclaw_systemd_user

# openclaw itself has a safety check requiring its systemd service directory
# to not be group/other writable
chmod 700 openclaw_systemd_user

# 3. Build the image (the first build downloads Node.js / Firefox / npm
#    dependencies, so it takes a while)
podman build -t openclaw-vnc:ubuntu26.04 .

# 4. Start the container — --systemd=always is required, see "Why
#    --systemd=always is required" below
podman run -d \
  --name openclaw \
  --systemd=always \
  -p 5901:5901 \
  -p 18789:18789 \
  -v ./data:/mnt \
  -v ./openclaw_data:/home/node/.openclaw \
  -v ./openclaw_systemd_user:/home/node/.config/systemd/user \
  --restart unless-stopped \
  localhost/openclaw-vnc:ubuntu26.04
```

Once it's up, verify the state:

```bash
podman ps -a --filter name=openclaw          # should be Up
podman exec openclaw systemctl --failed      # should be 0 loaded units
```

## Connecting to the desktop

Connect with any VNC client to `<host-ip>:5901`; the default password is `openclaw` (override it with `-e VNC_PASSWORD=yourpassword` on `podman run` — the container regenerates the password file from this env var on every start).

The desktop is xfce4 (Greybird theme + elementary-xfce icons), Firefox is the default browser, and CJK fonts are installed so Chinese pages won't show mojibake.

## First-time openclaw configuration

The image only ships the openclaw **software itself** — it does not contain any agent / Discord account / gateway auth **configuration**. That's intentional: those things (tokens and other secrets) shouldn't be baked into the image; they're runtime state, stored in the two volumes `openclaw_data/` and `openclaw_systemd_user/`. On a brand-new machine, you need to configure it once:

```bash
# Enter the container as node (the container's default exec user is root,
# because PID 1 has to be root's systemd)
podman exec -it -u node -e HOME=/home/node -e XDG_RUNTIME_DIR=/run/user/1001 openclaw bash

# Once inside:
openclaw configure          # interactive model/gateway/auth setup
openclaw channels add       # add Discord/Telegram/etc. accounts, following the prompts
openclaw agents add <id>    # create additional agents if needed
openclaw agents bind --agent <id> --bind discord:<accountId>   # bind routing

# The gateway only listens on loopback by default, unreachable from outside
# the container — change it to lan:
openclaw config set gateway.bind lan

# Install the gateway as a systemd service (persisted in the
# openclaw_systemd_user volume, so it survives future container rebuilds)
openclaw gateway install
```

For a more convenient way to enter the container, run the host-side convenience installer bundled with the repo (see "Host-side convenience setup" below); once installed, just run:

```bash
openclaw-shell
```

## Host-side convenience setup

`host-config/` holds things that have nothing to do with the container itself — purely convenience on the **host** (currently just the `openclaw-shell` alias). Run the installer once; it's safe to re-run and skips itself if already installed:

```bash
./host-config/install.sh
source ~/.bashrc   # or just open a new terminal
```

All it does is append a line `source "<repo-path>/host-config/bash_aliases"` to `~/.bash_aliases`, without touching anything else already in there. To add new host aliases/functions later, just edit `host-config/bash_aliases` directly — no need to re-run the installer.

## Common operations

```bash
# Gateway service management (as node, needs XDG_RUNTIME_DIR)
openclaw gateway status
openclaw gateway start | stop --force | restart

# Gateway logs
systemctl --user status openclaw-gateway
journalctl --user -u openclaw-gateway -f

# Desktop/VNC-side logs
systemctl status openclaw-desktop
```

## Directory overview

| Host path | Mounted to | Contents | Shipped in the repo? |
| --- | --- | --- | --- |
| `data/` | `/mnt` | Your own workspace/project files, for agents to use | No, create it yourself |
| `openclaw_data/` | `/home/node/.openclaw` | All of openclaw's state: config, sessions, secrets, agent workspaces | No, create it yourself |
| `openclaw_systemd_user/` | `/home/node/.config/systemd/user` | The systemd unit generated by `openclaw gateway install` | No, create it yourself |

All three directories are excluded via `.gitignore` (they're either large/private data, contain secrets, or are runtime-generated state). After moving to a new machine or a fresh clone, redo steps 1 and 2 of "Quick start".

## Default credentials (remember to change them)

| Purpose | Username | Default password | How to change |
| --- | --- | --- | --- |
| VNC | - | `openclaw` | `podman run -e VNC_PASSWORD=xxx ...` |
| Linux account inside the container (in the sudo group) | `node` | `node` | `passwd node` after entering the container |

These defaults exist purely for out-of-the-box convenience. Change them before exposing the container to the public internet or any untrusted network.

## Why `--systemd=always` is required

Container PID 1 is a real system-level `/lib/systemd/systemd`. `openclaw gateway install` actively probes the system-level `systemctl` to make sure no other service manager already owns the same unit name (to avoid two managers fighting over it), and that probe only succeeds when a genuine system-level systemd is actually running. Without `--systemd=always`, podman won't mount `/sys/fs/cgroup` read-write, systemd can't start, and the container effectively won't come up at all.

## Troubleshooting

- **`systemctl --failed` shows entries / the container won't start**: check first whether you forgot `--systemd=always`.
- **`EPERM` / `Permission denied` inside the container, especially touching files under `~/.openclaw` or `/mnt`**: rootless podman's UID mapping means the host directory's owner doesn't match the container's node user. Fix it with `podman unshare chown -R 1001:1001 <host-directory>` (a plain `chown` won't work — on the host you don't have permission to chown to an arbitrary UID).
- **`openclaw gateway install` reports "unsafe-permissions"**: `~/.config/systemd/user` (i.e. `openclaw_systemd_user/`) is too permissive; `chmod 700 openclaw_systemd_user` fixes it.
- **The gateway "disappears" after rebuilding the container**: make sure `podman run` includes `-v ./openclaw_systemd_user:/home/node/.config/systemd/user` — that service unit file doesn't live under `~/.openclaw`, and omitting this mount loses it.
