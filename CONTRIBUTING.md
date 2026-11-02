# Contributing

Thanks for trying Codex Glass Companion. Small, focused improvements are welcome, including compatibility reports, accessibility fixes, English UI/localization and data-schema support.

## Before a change

Search existing issues. For a substantial feature, describe the user problem and proposed behavior in an issue before building it. Include macOS version, CPU, Codex version and a minimal reproduction for bugs; use the provided templates and redact private data.

## Development

1. Fork and clone the repository; create a descriptive branch such as `fix/quota-window-label`.
2. Read the [README](README.md) and [privacy model](PRIVACY.md).
3. Run `make demo` for UI work and `make test` for affected behavior. The demo is offline and separate from your normal capsule.
4. For native glass changes, inspect both appearances, keyboard/click alternatives, Reduced Motion, hover transitions, and rounded corners. Avoid adding services or dependencies without a concrete need.
5. Submit a PR explaining the trigger, resulting behavior and relevant validation. Screenshots are useful for visual changes; use fictional demo data.

Use clear commit messages: `fix: preserve pending async questions until answered`, `feat: add English appearance labels`, or `docs: clarify Python prerequisites`. Do not commit generated apps, release ZIPs, database files, personal logs, credentials or development history. Keep the root structure; do not wrap the repository in another folder.

This project currently has no third-party runtime libraries. GitHub Actions dependencies are checked by Dependabot. Source contributions are distributed under the repository's MIT license; system APIs and third-party trademarks retain their own terms.
