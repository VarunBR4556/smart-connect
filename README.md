# Smart Connect

Access your laptop's terminal from your phone — free, using **Tailscale + SSH**.

No port forwarding, no public IP, no paid services. Traffic stays inside your private Tailscale network.

## Features

- Single `run` script — no dependencies beyond Bash
- Install, start, stop, update, status in one place
- `stop` kills everything (SSH service + sockets + `tailscaled` daemon) — nothing left running in the background
- No boot persistence — services only run while you want them to
- Works on apt, dnf, and pacman distros
- Auto-detects `ssh.service` vs `sshd.service` and socket activation
- Handles Tailscale "non-default flags" retries automatically

## Compatibility

| Requirement | Supported |
|-------------|-----------|
| **OS** | Linux only (not macOS/Windows) |
| **Init system** | systemd (required for service management) |
| **Shell** | Bash 4+ |
| **Package managers** | `apt` (Debian/Ubuntu), `dnf` (Fedora/RHEL), `pacman` (Arch) |
| **Phone OS** | Android (Termux), iOS (Blink Shell) |
| **Network** | Any — Tailscale works behind NAT/firewalls |

Tested on Ubuntu (systemd + `ssh.socket` activation). Should work on Debian, Fedora, Arch, and derivatives.

> **Not compatible** with non-systemd systems (e.g., Alpine with OpenRC, older SysVinit-only distros). The script uses `systemctl` for SSH service and `tailscaled` management.

## Quick start

```bash
cd ~/Desktop/smart-connect
./run setup
```

When it prints a Tailscale login URL, open it in your browser and sign in (Google/GitHub/Microsoft). Then run `./run ip` to get the address for your phone.

## Commands

```bash
./run setup     # first time: install SSH, install & connect Tailscale
./run start     # start SSH and bring Tailscale up
./run stop      # stop SSH and Tailscale completely
./run update    # keep SSH and Tailscale up to date and running
./run status    # show SSH + Tailscale status and your IP
./run ip        # print your Tailscale IP and the phone SSH command
./run help      # show usage
```

## What `stop` actually stops

Unlike a plain `tailscale down` or `systemctl stop ssh`, `./run stop` fully tears everything down:

- `ssh.service` (or `sshd.service`)
- `ssh.socket` / `sshd.socket` / `sshd-unix-local.socket` (prevents port 22 from staying open via socket activation)
- Disables those sockets so nothing respawns
- `tailscaled` daemon (not just the network connection)

Nothing is left running in the background. Run `./run start` to bring it all back.

## Set up your phone

1. Install **Tailscale**:
   - Android: Play Store
   - iOS: App Store
2. Log in with the **same account** as your laptop.
3. Install an SSH app:
   - Android: Termux (from F-Droid)
   - iOS: Blink Shell
4. Run `./run ip` on the laptop, then connect from the phone:

```bash
ssh YOUR_USERNAME@YOUR_TAILSCALE_IP
```

Enter your laptop password when asked. Done — you have a full terminal.

## Optional: passwordless login

On the phone (Termux):

```bash
ssh-keygen -t ed25519 -C "phone" -N ""
ssh-copy-id YOUR_USERNAME@YOUR_TAILSCALE_IP
```

## Requirements

- Linux laptop with sudo access
- Internet connection (for Tailscale install/login)
- Phone on the same Tailscale account

## Security

- 100% free and private — traffic is end-to-end encrypted via WireGuard inside your Tailscale network
- No ports are exposed to the public internet
- SSH is only reachable from devices on your tailnet
- `stop` fully shuts down the attack surface (SSH + Tailscale daemon)

## License

MIT
