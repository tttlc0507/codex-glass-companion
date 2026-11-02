# Releasing

1. Update `VERSION` and `CHANGELOG.md`, describe material limitations, and run `make test` and `make package` on a supported Mac/SDK. Verify both architectures with `lipo -info` and verify the archive checksum after extraction.
2. Review screenshots and the exact tracked file list for personal data. Demo screenshots only. Use `git status --short` and keep build output out of commits.
3. Create a version tag matching `VERSION` and publish a GitHub **pre-release** with the notes in `docs/release-notes.md`. The release workflow checks the tag/version match, builds/tests a universal app, and attaches its ZIP and SHA256SUMS to that release. Executables are not source-tree commits.
4. Inspect the Actions result and public release assets. Download and check the ZIP before announcing it. Do not claim a successful release if the build/upload is still failing.
5. Future stable releases should add Developer ID signing/notarization before claiming a trusted production distribution. Do not store credentials or signing material in the repository.

Use a GitHub noreply address for public commits. Account 2FA and SSH are recommended personal account choices; never commit private keys or tokens. HTTPS with a credential manager is also a supported Git transport.
