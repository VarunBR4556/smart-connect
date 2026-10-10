# Smart Connect

Use your phone to open your laptop's terminal. It uses **Tailscale + SSH**. Free, private, no port forwarding.

## What it does

- One script runs everything. Same commands on Linux and Windows.
- Sets up an SSH server and connects Tailscale for you.
- Gives you a local **web console** (a page in your browser) with buttons to start, stop, update, and copy your SSH command.
- Has a built-in terminal in the web page. Type commands, see output live.
- `stop` shuts down SSH and Tailscale fully. Nothing runs in the background.
- `sos` removes everything: SSH, Tailscale, and all project files.

## Quick start

Linux:

```bash
cd smart-connect
./run setup
```

Windows (PowerShell):

```powershell
cd smart-connect
.\run.ps1 setup
```

`setup` prints a Tailscale login link. Open it and log in. Then run:

```bash
./run ip        # Linux
.\run.ps1 ip    # Windows
```

It prints the address for your phone.

## Web console

Run `./run gui` (or `./run` with no command) to open the console in your browser.

It shows SSH and Tailscale status, has **Start / Stop / Update / Setup / Check** buttons, and a Copy button for your `ssh user@ip` command. The **Activity** box is a real terminal: type a command and press Enter, output streams live with colors. The buttons print their output there too, so long jobs show progress.

The page has a dark mode toggle and a resizable terminal. Drag the bar under the terminal to change its height.

The console runs only on your machine (`127.0.0.1`) on a random port and needs a session token. It is not reachable from other devices.

## Commands

```bash
./run gui       # open the web console
./run setup     # install SSH, install and connect Tailscale
./run start     # start SSH and Tailscale
./run stop      # stop SSH and Tailscale fully
./run update    # update SSH and Tailscale
./run status    # show SSH + Tailscale status and your IP
./run ip        # print your Tailscale IP and phone SSH command
./run check     # check this system meets the requirements
./run sos       # remove SSH, Tailscale and every file
./run help      # show help
```

On Windows (PowerShell), `./run` and `.\run.ps1` are the same thing — PowerShell auto-resolves `./run` to `run.ps1`, so every command in this table works exactly as written on both Linux and Windows.

`sos` is permanent. From the web console you must type `SOS` to confirm. There is no undo.

## Set up your phone

1. Install **Tailscale** (Play Store or App Store) and log in with the same account.
2. Install an SSH app: **Termux** (Android) or **Blink Shell** (iOS).
3. Run `./run ip` on the laptop, then connect from the phone:

```bash
ssh YOUR_USERNAME@YOUR_TAILSCALE_IP
```

Enter your laptop password. You now have a terminal.

## What `stop` stops

- SSH service and its sockets (so port 22 does not stay open), on Linux and Windows
- The `tailscaled` daemon (not just the connection)

Nothing is left running. Bring it back with `./run start`.

## Requirements

- Linux (systemd) or Windows 10/11, with admin/root access
- Internet for the Tailscale install and login
- A phone on the same Tailscale account

Not supported: macOS, and Linux without systemd.

## Security

- Traffic is encrypted by Tailscale (WireGuard) inside your private network.
- No ports are open to the internet.
- SSH works only from devices on your tailnet.
- The web console can run any command as you. Treat its URL like a password.

## Files

Only four files really matter:

- `run` — everything on Linux. The web console backend is built in (it is streamed straight into `python3`, nothing extra on disk).
- `run.ps1` — everything on Windows. The web console backend is built in.
- `gui.html` — the web console page.
- `README.md` — this file.

Run `./run gui` — or just `./run` — to open the console.
