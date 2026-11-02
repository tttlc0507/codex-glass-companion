# Installation and troubleshooting / 安装与排错

Requirements: macOS 14+, Python 3.9+, and a signed-in Codex desktop app or CLI for live data. UI language: Simplified Chinese. The native Liquid Glass layer requires macOS 26; older systems use frosted material.

## Release archive

Download the universal ZIP and `SHA256SUMS` from the same GitHub release. In that download directory:

```sh
shasum -a 256 -c SHA256SUMS
```

Extract the ZIP, open `CompanionHover.app`, or run the bundled installer from the extracted folder:

```sh
python3 install.py
```

This installs only for your macOS user and enables follow-Codex startup. It requires no `sudo`. If Codex is already running, the capsule opens; otherwise it opens the next time Codex starts. A previous managed app is retained as a backup during upgrade, and installation attempts restore the previous app/agent on failure.

The preview release is ad-hoc signed and **not notarized**. A downloaded app may need to be allowed individually in **System Settings → Privacy & Security** using [Apple's supported procedure](https://support.apple.com/en-us/102445). Do not disable Gatekeeper or strip quarantine globally. Building locally is another option.

## Source build

```sh
xcode-select --install  # Only if Apple's compiler tools are missing
make run
```

An existing Python 3.9+ installation and Command Line Tools are prerequisites; installing those prerequisites can take longer than a minute. No Python packages, npm, or full Xcode installation are required.

For live allowance data, the resolver tries `COMPANION_CODEX_CLI`, `codex` on PATH, the desktop bundle found by macOS, and standard `/Applications` or `~/Applications` Codex/ChatGPT locations. The desktop host is identified by bundle ID `com.openai.codex`, not its displayed name. A standalone CLI can supply data; automatic launch following still needs the desktop app.

To use a custom executable for a manual run:

```sh
COMPANION_CODEX_CLI=/absolute/path/to/codex build/CompanionHover.app/Contents/MacOS/CompanionHover
```

The app tries Python under `/opt/homebrew/bin`, `/usr/local/bin`, and `/usr/bin`; `COMPANION_PYTHON` can override it for a manual run. It respects an existing `CODEX_HOME` setting; by default records are read from `~/.codex`. Finder/LaunchAgent launches do not inherit interactive shell configuration, so custom shell-only environment variables may require starting the executable from that shell.

## Appearance and controls

Right-click the capsule or click its menu-bar icon → **外观**:

- **跟随系统** — system appearance.
- **浅色玻璃** — light glass.
- **深色玻璃** — dark glass.

The capsule and hover panels switch together, and the preference is saved. Drag the capsule to move it; the context menu can put it back in the lower-right corner. The middle/right controls support clicking as well as hovering. Moving into a hover panel keeps it open.

## Offline demo

```sh
make demo
```

For screenshot review, build the separate demo app and run one configuration at a time:

```sh
build/CompanionHoverDemo.app/Contents/MacOS/CompanionHover --demo --appearance=dark --state=running
# --panel=usage or --panel=tasks shows only that sample panel.
# --state=attention, completed, idle are also available.
```

Demo mode does not start the data bridge or read Codex sessions. Its new-chat control and sample task links do not open real chats.

## Disable or remove

From a source checkout:

```sh
make disable
make uninstall
```

From a release folder:

```sh
python3 install.py --disable
python3 install.py --uninstall
```

Disable removes only the launch agent and leaves the app. Uninstall removes the managed app and watcher; companion preferences and all Codex data are kept. You can also right-click → **退出悬浮助手** to stop it for the current Codex session.

Managed locations:

- `~/Library/Application Support/CompanionHover/`
- `~/Library/LaunchAgents/local.companion.hover.follow-chatgpt.plist`
- Preferences domain: `local.companion.hover`.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Usage unavailable | Sign in to Codex; confirm the CLI is installed and supports `app-server`; wait for the next refresh or use the capsule's refresh command. |
| Tasks unavailable | Confirm local records exist. A newer schema may need an update; browser-only chats are not guaranteed to appear. |
| Python connection cannot start | Install Python 3.9+ or Command Line Tools. Check the custom executable setting for manual runs. |
| Capsule missing | Start Codex; use the menu-bar capsule to show/reposition it; a manual Quit is respected until the next Codex launch. |
| Yellow light missing | The permission/input request may not be recorded in the local log; not every system dialog is observable. |
| Glass looks gray/less transparent | Background tint, macOS version and Reduce Transparency affect system material. This is not a fixed gray image. |
| Multiple capsules | The native Mini/Pets control and this independent app can both be enabled. Hide whichever you do not need in its own settings. |

Before filing an issue, include macOS/CPU, Codex version, companion version and a reproduction. Redact account details, project names, paths, authentication data and private logs.
