# Local Repository Status

Date: 2026-10-02

The main-repo worktree is active at upstream commit
`bab74230d28c7cfc5916d726582f9ee76d2e2e22`. Its Git objects pass strict fsck.
The previous new-package private-path audit was recovered from the preserved
backup; the old nano/tcc artifacts and their pinned hashes were not changed.
This local deployment note predates the Release publication commits.

## Staged Packages

- `packages/openjdk-17_17.0.20-android2_arm64.deb`
- Size: 121702632 bytes
- SHA256: `989f4510ad3b442ade1fcb355d4e2ecd01aeb332e802a9642625e549c7c8e0ea`
- Separate local checksum manifest: `packages/SHA256SUMS.openjdk`
- Repository state: `/var/lib/terminal-repo-client`
- All three packages (nano, tcc and OpenJDK) were imported into `repository/pool/main`.
- Active signed release: `/var/lib/terminal-repo-client/repository/dists/stable`
The OpenJDK release entry's Filename, Size and SHA256 match the accepted device
artifact. It is active in the signed stable release alongside nano and tcc. The
fixed remote nano/tcc bootstrap manifest remains unchanged.

## Active Service

A new RSA 4096 repository signing key was generated after the lost Termux key
could not be recovered. The primary fingerprint is
`A823B7EABD7E49BC620CBFC74F4203C9A033BF3C`. Its public key SHA256 is
`834b2a1b19cd8e0ce0d497adb366ecf73661c5c2e25275a94b941b29b988a247`. The
private key is retained only in `/home/Project/Android/remote-repo-signing`
with mode `700`; it is not in Git, the APK, or either public HTTP directory.

Terminal Debug HTTP authenticated at App UID 10229. The App keyring was
atomically replaced with this public key, and the old key plus both old source
files were backed up under
`/data/data/com.terminal/files/usr/var/backups/terminal-paths/`.
The active sources point to:
`http://192.168.1.7:8080 stable main` with `signed-by` set to the App keyring.

The repository nginx service is running on `0.0.0.0:8080` with pid `7081`.
A separate read-only public-key service is running on `0.0.0.0:9999`, serving
only `terminal-repo.gpg` from `repo-public-key-service`.

## Verification

`tests/run.sh` and `tests/bootstrap.sh` passed after the audit restoration and
OpenJDK staging. The live InRelease verifies with the new fingerprint, HTTP
POST to the repository is rejected, App UID `apt update` succeeded, and App UID
`apt download openjdk-17` produced the expected SHA256
`989f4510ad3b442ade1fcb355d4e2ecd01aeb332e802a9642625e549c7c8e0ea`.
