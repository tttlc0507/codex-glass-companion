# Security policy

The latest public preview is the supported version. Local Codex interfaces can change; a compatibility failure should show unavailable data rather than request new credentials or modify Codex records.

For a potential exposure of credentials or private conversation data, use the repository's **Security → Report a vulnerability** feature if available. If private reporting is unavailable, open an issue containing only a request for a private contact channel; do not include the exploit, secrets, logs or personal records there.

For ordinary UI bugs, inaccurate status, or schema compatibility, use the normal issue templates with sanitized examples. We do not promise a response time.

The preview binaries are ad-hoc signed, not Developer-ID signed or notarized. Verify release checksums and review/build the source if required by your environment. No part of the installation requires disabling system-wide security protections, `sudo`, a GitHub token, or sharing a Codex authentication file.
