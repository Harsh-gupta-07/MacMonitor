# MacMonitor

A lightweight, high-performance system monitor for macOS that lives in your menu bar.

Built with Swift and SwiftUI, MacMonitor shows real-time CPU, RAM and network activity at a glance (`CPU% : RAM%`) and opens a detailed view with a single click, all with an interface that feels at home on modern macOS.

---

## Table of Contents

- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Usage](#usage)
- [Launch at Login (launchd)](#launch-at-login-launchd)
- [Updating](#updating)
- [Uninstalling](#uninstalling)
- [Troubleshooting](#troubleshooting)
- [Development](#development)

---

## Features

- **Real-time CPU monitoring**: tracks processor load across all cores using high-precision Mach kernel APIs.
- **Accurate RAM usage**: calculates memory usage the same way Activity Monitor does (App Memory + Wired + Compressed).
- **Swap visibility**: shows swap usage alongside physical RAM for a complete picture of memory pressure.
- **Live network speed**: shows the actual data being sent and received every second (upload / download throughput), not your connection's maximum bandwidth.
- **Minimal footprint**: a single native binary with no dependencies, no Dock icon and no background services beyond itself.

## Requirements

| Requirement | Version / Notes |
| ----------- | --------------- |
| macOS       | 13.0 (Ventura) or later |
| Swift compiler (`swiftc`) | Included with Xcode or the Xcode Command Line Tools |
| `make`      | Included with Xcode or the Xcode Command Line Tools |

If you don't have the Command Line Tools installed yet:

```bash
xcode-select --install
```

## Installation

### 1. Clone the repository

```bash
git clone https://github.com/Harsh/MacMonitor.git
cd MacMonitor
```

### 2. Build

```bash
make build
```

The compiled executable is placed in `./bin/`.

### 3. Run

| Command | What it does |
| ------- | ------------ |
| `make run` | Runs MacMonitor attached to the current terminal (closes when the terminal closes). |
| `make run-detach` | Runs MacMonitor in the background so it keeps running after you close the terminal. |

> **Tip:** To have MacMonitor start automatically every time you log in, and restart if it ever crashes, set it up as a Launch Agent (see below).

## Usage

- **Open the monitor:** click the `CPU% : RAM%` readout in the menu bar.
- **View stats:** see physical RAM used, swap used and total system capacity.
- **Network activity:** see live upload and download speed, measured as the real data your Mac is sending and receiving each second.
- **Quit:** click the **✕** icon in the top-right corner of the monitor window.

## Launch at Login (launchd)

macOS uses `launchd` to start programs automatically. By registering MacMonitor as a **Launch Agent**, it will:

- start automatically when you log in (`RunAtLoad`), and
- restart automatically if it crashes, but **stay closed** when you quit it yourself with the ✕ button (`KeepAlive` → `SuccessfulExit = false`).

### Step 1: Stop any running instance

If you started MacMonitor with `make run` or `make run-detach`, stop it first so you don't end up with two menu bar items:

```bash
pkill -x MacMonitor
```

### Step 2: Copy the binary to a permanent location

launchd needs an absolute path to an executable that won't move or be deleted. This setup keeps the binary next to its plist in `~/Library/LaunchAgents`, so it's safe from a `make clean` or a deleted clone:

```bash
mkdir -p ~/Library/LaunchAgents
cp bin/MacMonitor ~/Library/LaunchAgents/MacMonitor
chmod +x ~/Library/LaunchAgents/MacMonitor
```

### Step 3: Create the plist file

Create `~/Library/LaunchAgents/Harsh.MacMonitor.plist`.

> **Note:** launchd does **not** expand `~` or `$HOME` inside a plist, so the path to the binary must be absolute. The command below writes the plist for you and fills in your home directory automatically:

```bash
cat > ~/Library/LaunchAgents/Harsh.MacMonitor.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.Harsh.MacMonitor</string>

    <key>ProgramArguments</key>
    <array>
        <!-- binary stored in LaunchAgents itself for safe storage -->
        <string>$HOME/Library/LaunchAgents/MacMonitor</string>
    </array>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
</dict>
</plist>
EOF
```

<details>
<summary>Prefer to create the file by hand? Click here for the full plist.</summary>

Replace `YOUR_USERNAME` with the output of `whoami`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.Harsh.MacMonitor</string>

    <key>ProgramArguments</key>
    <array>
        <!-- binary stored in LaunchAgents itself for safe storage -->
        <string>/Users/YOUR_USERNAME/Library/LaunchAgents/MacMonitor</string>
    </array>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
</dict>
</plist>
```

</details>

What each key does:

| Key | Purpose |
| --- | ------- |
| `Label` | Unique name launchd uses to identify the job (`com.Harsh.MacMonitor`). |
| `ProgramArguments` | Absolute path to the executable to run. |
| `RunAtLoad` | Start the app as soon as the agent is loaded (i.e. at login). |
| `KeepAlive` → `SuccessfulExit = false` | Relaunch only if the app exits with an error (a crash). Quitting normally keeps it closed. |

### Step 4: Validate the plist

```bash
plutil -lint ~/Library/LaunchAgents/Harsh.MacMonitor.plist
```

You should see `OK`. If not, fix the reported line before continuing.

### Step 5: Load it into launchctl

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/Harsh.MacMonitor.plist
```

MacMonitor should appear in your menu bar immediately, and it will now start automatically every time you log in.

### Step 6: Verify it's running

```bash
launchctl print gui/$(id -u)/com.Harsh.MacMonitor | grep -E "state|pid"
```

You should see `state = running` along with a process ID.

### Managing the Launch Agent

| Task | Command |
| ---- | ------- |
| Start it again after quitting via ✕ | `launchctl kickstart gui/$(id -u)/com.Harsh.MacMonitor` |
| Restart it (e.g. after updating the binary) | `launchctl kickstart -k gui/$(id -u)/com.Harsh.MacMonitor` |
| Stop it and remove it from launchd | `launchctl bootout gui/$(id -u)/com.Harsh.MacMonitor` |
| Load it again | `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/Harsh.MacMonitor.plist` |
| Check its status | `launchctl print gui/$(id -u)/com.Harsh.MacMonitor` |

> **Older syntax:** `launchctl load -w <plist>` and `launchctl unload -w <plist>` still work, but `bootstrap` / `bootout` are the recommended commands on current macOS.

## Updating

After pulling new changes, rebuild, copy the new binary into place and restart the agent:

```bash
git pull
make build
cp bin/MacMonitor ~/Library/LaunchAgents/MacMonitor
launchctl kickstart -k gui/$(id -u)/com.Harsh.MacMonitor
```

## Uninstalling

```bash
# 1. Stop and unregister the Launch Agent
launchctl bootout gui/$(id -u)/com.Harsh.MacMonitor

# 2. Remove the plist and the binary
rm ~/Library/LaunchAgents/Harsh.MacMonitor.plist
rm ~/Library/LaunchAgents/MacMonitor
```

Then delete the cloned `MacMonitor` folder if you no longer need the source.

## Troubleshooting

**`Bootstrap failed: 5: Input/output error`**
The agent is usually already loaded. Unload it first, then load it again:

```bash
launchctl bootout gui/$(id -u)/com.Harsh.MacMonitor
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/Harsh.MacMonitor.plist
```

If it still fails, run `plutil -lint` on the plist and confirm the binary path inside it exists and is executable (`ls -l ~/Library/LaunchAgents/MacMonitor`).

**Two MacMonitor items in the menu bar**
A copy started with `make run` / `make run-detach` is still running alongside the launchd one. Run `pkill -x MacMonitor`; launchd will not restart a cleanly terminated process, so then start a single copy with `launchctl kickstart gui/$(id -u)/com.Harsh.MacMonitor`.

**It doesn't start at login**
Check that the plist is in `~/Library/LaunchAgents/` (not `/Library/LaunchAgents/`) and that the path in `ProgramArguments` is absolute and correct. Also look in **System Settings → General → Login Items** and make sure MacMonitor's background item is allowed.

**Seeing logs**
To capture output and errors, add these keys inside the `<dict>` of the plist, then `bootout` and `bootstrap` again:

```xml
<key>StandardOutPath</key>
<string>/tmp/MacMonitor.out.log</string>
<key>StandardErrorPath</key>
<string>/tmp/MacMonitor.err.log</string>
```

## Development

The project is intentionally simple to modify: all core logic lives in a single file, `MenuBarWidgetApp.swift`.

| Item | Details |
| ---- | ------- |
| Main source | `MenuBarWidgetApp.swift` |
| Compiler flags | `-parse-as-library -framework SwiftUI -framework AppKit` |
| CPU stats | `mach_host_self`, `host_processor_info` |
| Memory stats | `host_statistics64` |
| System info (total RAM, swap) | `sysctlbyname` |

After making changes, run `make build && make run` to test, then follow [Updating](#updating) if you use the Launch Agent.
