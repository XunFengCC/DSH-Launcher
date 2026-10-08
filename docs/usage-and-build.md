# DSH Launcher: usage and build

DSH Launcher is a native macOS window for the official [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) CLI. Opening the app starts the local web service. Closing it checks activity before stopping the service; the app does not install a login item.

## Install and first launch

Version 1.0.0 is the Apple Silicon release and targets macOS 14 or later. The [release engineering record](diagnostics/20261004ReleasePreparation.md) documents verification evidence and platform limits. The source can build for Intel, but there is no Intel release artifact or physical-machine acceptance yet.

1. Drag **DSH Launcher.app** from the DMG to Applications and open it. The controller is bundled in the signed app. If macOS asks whether to open it, verify the app name and Developer ID signature.
2. The launcher uses a suitable installed Node/npm pair and Python when available. It downloads and verifies only missing runtimes from pinned official sources, then prepares them in the user’s Application Support directory. No administrator password or developer tools are required. If both are missing, the download is about 80 MB and progress is shown.
3. If the DSH CLI is missing, the launcher installs the official npm `latest` version and shows progress. A first install uses a user-owned prefix; an existing CLI stays in its configured location.
4. Configure a DeepSeek API key in the official web UI under **Settings → Models**, or start account authorization from **DSH Launcher → Sign in to DeepSeek**. The menu item changes to **Sign out of DeepSeek** after authorization. An in-progress sign-in can be canceled in its authorization window. The launcher does not show a first-run authentication wizard or automatically upgrade an installed CLI to enable sign-in.

The upstream web interface is not modified. The Harness manages account credentials. Account authorization begins only when the user selects the app-menu action; the local RPC uses the authenticated WebView origin. Runtime downloads are on demand, keeping the app bundle small.

## Updates and recovery

Native menus follow the system language by default. With CLI `0.2.0-rc.2` and its locale protocol, the **DSH Launcher → Language** menu synchronizes with **Settings → General → Language**. Older CLIs change only the native menu and do not cause the launcher to rewrite web settings. **About DSH Launcher** shows the app version/build and the CLI version actually selected by the controller; missing and unreadable versions are distinct.

**Check for Updates…** (⌘U) reports the launcher and CLI separately:

- The app checks its own GitHub Release source. When an update is available, it opens the release page for the user to install the signed app. An unpublished release and a query failure are reported separately; either state leaves CLI functions available.
- The CLI check uses the official npm registry. Before writing, the controller checks activity and stops the service, then creates paired code and data recovery points. A failed update restores that pair instead of combining one version’s code with data from another time.
- If work is active or activity cannot be confirmed, the launcher refuses the update. It preserves the current state before restoring data and does not silently discard post-update state.

The service listens only on `127.0.0.1`. The one-time browser-auth token is stored in a permission-restricted local state file and is not shown in the loading overlay. Feedback actions prepare a report or email draft; the user reviews and sends it.

## Build and package

Builds require Xcode Command Line Tools. The app icon is sourced from the installed official CLI favicon; `DSH_LAUNCHER_FAVICON` can select another source SVG.

Run these commands from the repository root:

```sh
zsh buildApp.sh
DSH_BUILD_ARCH=x86_64 DSH_SIGNING_MODE=adhoc zsh buildApp.sh
```

If a Developer ID certificate is available, `buildApp.sh` uses Hardened Runtime and a secure timestamp; otherwise it uses ad-hoc signing. If an explicitly selected identity is unavailable, the build fails instead of silently switching identity. A public release must be signed with Developer ID, notarized, and stapled.

`DSH_BUILD_NUMBER` optionally overrides the Git commit count and must be a positive integer. Public version 1.0.0 uses build 23. The release receipt records the exact source revision and signing/notarization results.

```sh
DSH_NOTARY_PROFILE=profile-name zsh scripts/packageRelease.sh
```

The packaging script builds and notarizes the app, prepares ZIP and DMG artifacts, notarizes the DMG, and writes SHA256SUMS. It does not install the app or upload artifacts. Credentials stay in Keychain and are not passed on the command line. Existing output directories are not overwritten.

## Configuration

All environment variables are optional. Settings use snake_case keys in the JSON file selected by `DSH_SETTINGS`; precedence is environment variable, then settings file, then default.

| Variable | Default | Purpose |
|---|---|---|
| `DSH_HOME` | `~/.dsh` | Harness data directory |
| `DSH_PORT` | `3080` | Local web port |
| `DSH_NODE_BIN` | `/opt/homebrew/bin/node`, `/usr/local/bin/node`, then `PATH` | Node executable |
| `DSH_BIN` | Configured install prefix plus `/bin/dsh` | DSH CLI entry point |
| `DSH_INSTALL_PREFIX` | Existing CLI prefix; otherwise a private user prefix | CLI install target |
| `DSH_PYTHON_BIN` | Suitable installed Python, or the managed runtime | Controller interpreter |
| `DSH_RUNTIME_ROOT` | `~/Library/Application Support/DSH Launcher/Runtimes` | Managed Node/Python cache |
| `DSH_WORKSPACE` | `~/DeepSeekHarnessWorkspace` | Default working directory |
| `DSH_BACKUP_DIR` | `~/.local/share/deepseek-harness/backups` | Data backups and deployment snapshots |
| `DSH_KEYCHAIN_SERVICE` | `deepseek-harness/deepseek-api` | Keychain service name |
| `DSH_KEYCHAIN_ACCOUNT` | `deepseek-api` | Keychain account name |
| `DSH_CONTROLLER` | Controller bundled in the app | Controller path override |
| `DSH_LOG` | `$DSH_HOME/launcher/web.log` | Service log path |
| `DSH_LAUNCHER_FAVICON` | Detected from the npm tree | Build-time icon override |
| `DSH_SETTINGS` | `~/.config/deepseek-harness-launcher/settings.json` | Settings file |
| `DSH_FEEDBACK_EMAIL` | Set by the release configuration | Feedback recipient |
| `DSH_FEEDBACK_NAME` | Set by the release configuration | Recipient display name |
| `DSH_FEEDBACK_GITHUB_ISSUES_URL` | `https://github.com/XunFengCC/DSH-Launcher/issues/new` | Public feedback issue page |

For example, a settings file may contain:

```json
{"dsh_home": "/path/to/dsh-data", "port": "8080"}
```

For an isolated controller run, override every data-bearing path and port:

```sh
DSH_HOME=/tmp/dsh-test DSH_WORKSPACE=/tmp/dsh-work \
DSH_BACKUP_DIR=/tmp/dsh-backups DSH_PORT=3081 \
python3 controller/deepseekHarness.py start
```

## Security and feedback

- The service binds to the literal loopback address `127.0.0.1`; the upstream Harness rejects non-literal loopback hosts for privileged methods.
- The launcher parses the one-time auth token from startup output and stores it in an owner-only (`0600`) state file. It does not print the token in command output.
- API keys are read from Keychain at runtime and passed only in the Harness child process environment, not in arguments or files.
- The repository contains no credentials; it refers to Keychain item names only.

Open **Problem Feedback…** from the app or Help menu to preview, save, or prepare a report:

- Email uses the recipient configured for the release. The system share service prepares a draft with the full report in the message and a text attachment. The user sends it. If no mail client is available, the app provides manual handling instructions and reveals the report in Finder.
- GitHub opens a prefilled issue page. Issue content is public; review the description and remove anything that should not be public before submitting.
- Reports contain app version/build, macOS version, architecture, timestamp, and the description the user enters. The description is preserved as written. Automatic collection excludes sessions, logs, API keys, and controller state.

Reports default to `~/Library/Application Support/DSH Launcher/Feedback/`; timestamp-and-UUID filenames avoid collisions, and directory/file permissions are `0700`/`0600`. The user can choose another location. Configure feedback settings through environment variables, settings JSON, or the corresponding Info.plist fields. GitHub destinations must be exactly `https://github.com/<owner>/<repo>/issues/new`, without credentials, port, query, or fragment. Feedback configuration is not included in reports.

The isolated feedback regression command is:

```sh
xcrun swiftc -O Sources/FeedbackCore.swift tests/feedback/main.swift \
  -o /tmp/dsh-feedback-tests && /tmp/dsh-feedback-tests
```

## Clean-environment testing and limits

GitHub Actions is not enabled for the initial release: the publishing account’s existing authorization cannot upload workflows. The optional configuration is preserved at [`ci/build.yml`](ci/build.yml); a maintainer with workflow permission can move it into `.github/workflows/`. It produces development artifacts, not notarized releases. The CI workflow builds on a fresh macOS runner. For local controller tests, use temporary data paths as above. A temporary macOS user or VM is closer to a first-run machine; the path overrides make that test repeatable without uninstalling the app.

The compatibility validation for this release used upstream CLI `0.2.0-rc.2`, which was a developer preview; its internal interfaces can change. For example, `0.1.2-rc.1` introduced browser-token authentication and changed an endpoint. Review version compatibility before unattended updates. Older CLIs may not implement newer optional launcher features.

If no Developer ID certificate is available, a locally built app uses ad-hoc signing and may need to be opened through Finder’s confirmation flow. Developer ID signing alone does not replace notarization for public distribution. Keychain service/account names can be overridden for another deployment.

## License

DSH Launcher is licensed under **GPL-3.0-only**; see the [repository license](../LICENSE). The upstream `@deepseek-ai/dsh` package has its own MIT license. The favicon comes from the official `dsh-web-frontend` package. Third-party runtime and dependency licenses remain those stated by their respective projects. DeepSeek Harness names and marks belong to their owners; this project is unofficial and unaffiliated.

For project history and the reasons behind changes, see the [changelog](../CHANGELOG.md).
