# Privacy and data access

Codex Glass Companion is a local desktop utility. It has no analytics, advertising, crash uploader, account system, or project-operated server.

## Data sources

- The existing Codex CLI's `app-server` account-rate-limit endpoint, approximately once a minute. The CLI reuses its own authentication and may contact OpenAI. The companion does not ask for a password/API key or read authentication files itself.
- Read-only connections to the highest-version `state_*.sqlite` thread database under the Codex home, normally `~/.codex`.
- Incremental reads of the referenced rollout JSONL files for up to 60 recent non-archived main threads. This includes task lifecycle, recorded confirmation/input requests, public commentary, and available plan steps. Reasoning events affect only a generic status label; reasoning text is not displayed or transmitted.

Task and quota snapshots stay in process memory and are sent only through a local parent/child pipe to the native UI. There is no listening HTTP server. The companion does not upload your conversation history. Codex's own behavior and service terms are separate.

## Local writes

The app stores its appearance and position in its preferences domain. The optional installer writes its app, small event-driven watcher, launch-agent plist, upgrade backup and diagnostic launch logs in your user Library. It never changes Codex's application bundle, login, project files, or session database. It opens Codex chat links only when you click a relevant control.

The installer can be disabled or uninstalled as described in [INSTALL.md](docs/INSTALL.md). Preferences are retained on uninstall. There is no automatic update downloader.

## Demo and screenshots

`make demo` uses a separate app identity and synthetic data. It does not launch the data bridge or read Codex records. Repository screenshots are captured from that mode.

## Reporting

Please avoid posting authentication files, whole rollout logs, private task names, account identifiers or personal paths in public issues. See [SECURITY.md](SECURITY.md) for sensitive reports.
