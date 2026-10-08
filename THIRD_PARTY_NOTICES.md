# Third-party notices — DSH Launcher 1.0.0

## Project scope and license

These notices describe DSH Launcher 1.0.0. DSH Launcher is an unofficial macOS launcher for the DeepSeek Harness CLI. The
project-authored Swift application, Python controller, build/release scripts,
and tests are released under **GNU GPL-3.0-only** (SPDX identifier
`GPL-3.0-only`); see [`LICENSE`](LICENSE). This project license does not replace
the separate licenses of upstream software or assets.

The source project is by 风吟, with assistance from the AI partner 砚衡. This is
an acknowledgment of the collaboration, not a claim that DeepSeek, Node.js,
Astral, or the Python Software Foundation sponsors or endorses this project.
DSH Launcher is not affiliated with DeepSeek.

## DeepSeek Harness CLI, Web UI, account protocol, and icon

The upstream [`@deepseek-ai/dsh`](https://github.com/deepseek-ai/deepseek-harness/tree/dsh-v0.2.0-rc.2/apps/cli)
package and the related Web frontend and account-controller packages are
published under the MIT License, copyright © 2026 DeepSeek. The release
preparation validated the CLI and protocol against `@deepseek-ai/dsh`
**0.2.0-rc.2**, source tag `dsh-v0.2.0-rc.2`. The client UI and account protocol
are maintained in the same upstream repository, including
[`apps/web`](https://github.com/deepseek-ai/deepseek-harness/tree/dsh-v0.2.0-rc.2/apps/web)
and
[`packages/api/account-controller`](https://github.com/deepseek-ai/deepseek-harness/tree/dsh-v0.2.0-rc.2/packages/api/account-controller).
The App's interoperability implementation is project-authored GPL-3.0-only
code; it does not embed the upstream CLI or Web UI source.

The default application icon is derived from the upstream
[`@deepseek-ai/dsh-web-frontend` 0.2.0-rc.2 package](https://www.npmjs.com/package/@deepseek-ai/dsh-web-frontend/v/0.2.0-rc.2),
whose source is in upstream [`apps/web`](https://github.com/deepseek-ai/deepseek-harness/tree/dsh-v0.2.0-rc.2/apps/web).
Its distributed `dist/favicon.svg` is licensed with the package under the MIT License. The build converts
the SVG to an `.icns` icon and changes its presentation for macOS. The source
package's copyright and license notice are reproduced below. A build that sets
`DSH_LAUNCHER_FAVICON` to a different file must separately identify and comply
with that file's license.

The CLI is installed separately by npm when it is missing; it is not embedded
in the App. The launcher installs the npm `latest` tag for a fresh installation,
so the installed CLI may be newer than the version validated above. The CLI
package and its dependencies retain their own license files in the npm install
tree; this notice records the version and sources validated for this release
preparation, not a blanket license statement for future npm releases or every
transitive dependency.

MIT License

Copyright (c) 2026 DeepSeek

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Separately downloaded runtimes

The App bundle does **not** contain Node.js, npm, or Python. On first launch it
reuses a compatible local runtime where available and downloads only a missing
runtime into the user's Application Support directory. `Sources/RuntimeBootstrap.swift`
pins the current automatic downloads to the official sources below; it stores
the archive integrity hashes in the signed App and does not repackage or modify
the runtime archives. These are separate upstream installations, not additional
libraries bundled into DSH Launcher.

- **Node.js 24.21.0**: official macOS arm64/x64 archives from
  [nodejs.org](https://nodejs.org/dist/v24.21.0/) (for example, the
  [arm64 archive](https://nodejs.org/dist/v24.21.0/node-v24.21.0-darwin-arm64.tar.gz)
  and [x64 archive](https://nodejs.org/dist/v24.21.0/node-v24.21.0-darwin-x64.tar.gz)).
  Node.js source is MIT licensed; see the versioned
  [Node.js `LICENSE`](https://github.com/nodejs/node/blob/v24.21.0/LICENSE).
  The official distribution's `LICENSE` also records licenses for
  externally maintained components, and npm/dependencies carry their own
  notices. Consult the license files in the installed Node distribution.
- **CPython 3.14.8+20261003**: the `install_only_stripped` macOS arm64/x64
  artifacts from Astral's
  [python-build-standalone 20261003 release](https://github.com/astral-sh/python-build-standalone/releases/tag/20261003).
  The [arm64 artifact](https://github.com/astral-sh/python-build-standalone/releases/download/20261003/cpython-3.14.8%2B20261003-aarch64-apple-darwin-install_only_stripped.tar.gz)
  and [x64 artifact](https://github.com/astral-sh/python-build-standalone/releases/download/20261003/cpython-3.14.8%2B20261003-x86_64-apple-darwin-install_only_stripped.tar.gz)
  are selected by architecture.
  The build project itself is licensed under
  [MPL-2.0](https://github.com/astral-sh/python-build-standalone/blob/20261003/LICENSE),
  while CPython software is under the
  [Python Software Foundation License Version 2](https://github.com/python/cpython/blob/v3.14.8/LICENSE).
  Components in the built runtime retain their own licenses; the Python
  installation includes `lib/python3.14/LICENSE.txt` and applicable
  component/package license files. The build project's license does not
  relicense CPython or those components. Consult the files installed with the
  runtime for the exact notices applicable to that artifact.

These downloads are pinned in the source revision, but the selected artifact
depends on the Mac architecture. A future version change must be checked against
the corresponding upstream release and its included license files.
