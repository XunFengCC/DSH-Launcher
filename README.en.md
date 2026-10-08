# DSH Launcher

Use DeepSeek Harness CLI without opening a terminal every time.

An unofficial native macOS launcher that puts the upstream Web UI in its own window and handles starting, stopping, installation and updates. You keep using the CLI; you get an App you can click.

[下载与中文说明](README.md) · [Download 1.0.0](https://github.com/XunFengCC/DSH-Launcher/releases/tag/v1.0.0)

## Features

- Start the local service on opening; check active tasks before quitting.
- Install official npm latest only when the CLI is missing. Keep an existing CLI unchanged until you choose to update. Prepare missing runtimes in the user directory with pinned hashes.
- Check App and CLI updates separately; restore paired code/data snapshots after CLI update failure.
- Configure an API key in the official Web UI, or use the native account menu to sign in/out. Cancel an authorization in its sheet.
- Chinese/English native menus follow the system and synchronize with supported Web UI language settings. About shows App/build and the actual CLI version.

Independent use does not automatically isolate existing CLI data. Defaults reuse the detected installation and user data; separate environments can be configured.

## Installation

The release supports Apple Silicon; the build target is macOS 14+. See [verification limits](docs/diagnostics/20261004ReleasePreparation.md).

1. Download `DSH-Launcher-1.0.0-macOS-arm64.dmg` from the release page.
2. Drag DSH Launcher.app into Applications and open it.
3. Wait for first-run setup, then configure an API key or choose Sign In to DeepSeek from the App menu.

App and DMG are Developer ID signed and Apple notarized. Initial setup needs network access. Existing CLIs are not automatically upgraded. Account/locale protocols were verified with official CLI 0.2.0-rc.2; older versions may require a manual update.

## Credits and development

Swift/AppKit/WebKit and a custom Python controller, made together by 风吟 and AI partner 砚衡. CLI, Web UI, protocol and favicon come from [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness); runtimes come from Node.js, Python and Python Build Standalone. This project has no official affiliation or endorsement.

[Third-party notices](THIRD_PARTY_NOTICES.md) · [Configuration and builds](docs/usage-and-build.md) · [Engineering evidence](docs/diagnostics/20261004ReleasePreparation.md) · [Changelog](CHANGELOG.md) · [Issues](https://github.com/XunFengCC/DSH-Launcher/issues)

Custom code is licensed under **GPL-3.0-only**; third-party components retain their own licenses. See [LICENSE](LICENSE).
