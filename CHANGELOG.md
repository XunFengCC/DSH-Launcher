# Changelog

This file records public product changes and the engineering reasons behind them. The first public source release is **DSH Launcher 1.0.0**; unpublished launcher version numbers and private workstation history are omitted. Upstream CLI versions are named where they define a compatibility boundary.

## 2026-10-09 — DSH Launcher 1.0.1

- Update the GitHub release query and trusted release-page path to `FengYinYH/DSH-Launcher`. After an owner rename, GitHub returns the new canonical page URL; the previous hard-coded path rejected that response as unpublished. The current release accepts the current owner directly, with no legacy alias fallback.
- Set the public feedback recipient to `FengYinYH@icloud.com` in both release configuration and the default, and refresh download/support links and fixtures. Existing installations and upstream CLI data are unchanged; install this signed revision to use the corrected update checker.

## 2026-10-08 — DSH Launcher 1.0.0

- Ship the controller and license inside the signed app, with an explicit macOS 14 deployment target. This makes a clean install independent of a maintainer’s source checkout and prevents the plist’s minimum-version declaration from drifting from the executable.
- Prefer a compatible installed Node/npm pair and Python. Download only a missing runtime from a pinned official archive, verify its SHA-256 and archive structure, then publish it in the user’s Application Support directory. This avoids administrator access and leaves system `PATH` and global npm state unchanged.
- Install the DSH CLI from the official npm `latest` tag only when no CLI is installed. New installs use a user-owned prefix; existing installations are not silently upgraded or moved.
- Provide optional account sign-in from the native menu while leaving the upstream web UI unchanged. The upstream Host owns credentials. Old CLIs without the required account methods receive an actionable compatibility message; sign-in never triggers an automatic CLI update.
- Add native language selection and synchronization through the supported locale interface in CLI `0.2.0-rc.2`. Older CLIs still localize the native menu without rewriting web settings.
- Show the app version/build and the version of the exact CLI selected by the controller. The offline `version --json` action reports installed, missing, and unreadable states without scanning another installation or exposing arbitrary command output.
- Make update and rollback transactional: check activity before writes, stop the service before taking a consistent data backup, and bind each data backup to its code snapshot. Installation, verification, restart, or smoke-check failures restore the matched pair. A missing local pair is rejected instead of being reconstructed from unrelated backups or an online package.
- Keep JSON command output machine-readable across the full update/rollback lifecycle. Diagnostic text goes to stderr; stdout contains one result object.
- Add reproducible Developer ID signing, notarization, stapling, ZIP/DMG packaging, and checksum generation. The optional CI example identifies its artifacts as development builds rather than notarized release packages; Actions is not enabled in this initial release.
- Publish the project under **GPL-3.0-only**. Upstream CLI, downloaded runtimes, and their dependencies retain their own licenses.

## Pre-release engineering notes

These notes preserve the reasons for design choices and the compatibility evidence used for the first release. They are curated for public maintenance; local account details, private contact information, and original workstation state are excluded.

### 2026-09-18 — Update handoff

- Keep the launcher process and native window alive when only the Harness changes. After a guarded restart, replace the WebView request with a fresh one-time auth URL rather than requiring a full app restart.
- Show completion only after the refreshed WebView finishes. If activity checks, restart, auth handoff, or navigation fails, show an explicit failure and retry path. Falling back to unauthenticated `localhost` produced a blank page and obscured the actual failure.
- Keep the activity guard fail-closed. A busy or unknown state leaves the installed update pending; explicit confirmation is the only path that can stop active work.
- Reload reacquires the current auth URL so it can recover an expired browser session. Auth tokens are not shown in the loading overlay or accessibility tree.

### 2026-09-16 — Feedback module

- Add a native feedback panel with preview, save, email-draft, and GitHub-issue paths. Email uses the release-configured recipient and attaches the complete report; the app never sends it on the user’s behalf.
- Preserve the user-entered description because whitespace and reproduction details can matter. Limit automatic report fields to app/build and environment metadata; do not collect sessions, logs, API keys, or controller state.
- Keep the GitHub destination constrained to `https://github.com/<owner>/<repo>/issues/new`. Since issue contents are public, the user reviews and submits them.
- Use UUID filenames and owner-only report permissions. An early layout alignment defect was corrected after isolated UI verification. A historical SVG conversion failure did not reproduce in the later full build; the source SVG was not altered to work around it.

### 2026-09-11 — Finder PATH and update-query reliability

- A Finder launch can have a minimal `PATH`, while npm and DSH shims use `#!/usr/bin/env node`. Resolve Node once and prepend its directory to child-process `PATH`; otherwise version checks and npm operations can fail even when Node is installed.
- A transient TLS handshake failure in the registry query motivated a bounded retry with short backoff. Retries are limited so a persistent error remains visible instead of hanging the UI.

### 2026-09-06 — Browser authentication and lifecycle safety

- Upstream CLI `0.1.2-rc.1` moved `/` and `/api` behind one-time-token browser authentication and renamed `session.list` to `session/list`. A launcher that continued to load an unauthenticated root could show a blank window while the service itself was ready. Parse the token from startup output into an owner-only state file and load the authenticated URL; a successful service start alone is not proof that the UI can authenticate.
- Restart initially lacked an activity guard and could terminate active work. Restart, update-with-restart, and rollback now reject busy or unknown states unless the user explicitly confirms.
- Update and rollback preserve paired code and data recovery points. Because rollback follows a failed restart smoke check, restoring only one side can combine incompatible code and state; both sides move together.
- Check update metadata without installing, use an explicit lifecycle-script allowlist to avoid interactive npm prompts, and verify the new CLI after installation. Failed verification or startup triggers offline restoration from the local snapshot.
- Keep the native window full-size and align its titlebar region with the upstream page header. The first layout left a visible band that conflicted with the page sidebar; adjusting the content region removed it without changing upstream page code.

### 2026-08 — Initial lifecycle and configuration

- Start and stop the web service on demand rather than registering a login item. Check activity before exit so closing the app cannot silently kill active work.
- Require the literal loopback host `http://localhost:3080/` for privileged Harness methods. A custom `*.localhost` name resolving to loopback was rejected by the upstream host, so DNS equivalence was not sufficient.
- Keep provider credentials in Keychain and inject them only into the Harness child process environment, never into arguments or files.
- Parameterize home, port, workspace, backup, and settings paths so the controller can be tested with temporary directories and does not depend on a particular machine layout.
- Retain verified fallback links while removing dangling links; do not delete a link merely because it points outside the active profile tree.

## Engineering records

Detailed release conditions, upstream protocol evidence, verification boundaries, and recovery behavior are documented in [the release engineering record](docs/diagnostics/20261004ReleasePreparation.md), [the restart authentication record](docs/diagnostics/20260911RestartAuthentication.md), and [the feedback module record](docs/diagnostics/20260916Feedback.md). Usage, configuration, and build instructions are in [the Chinese guide](docs/usage-and-build.zh.md) and [the English guide](docs/usage-and-build.md).
