import CryptoKit
import Darwin
import Foundation

/// Downloads only a missing, pinned CLI runtime into the user's Application
/// Support directory. The signed app carries the artifact hashes so a mutable
/// network response can never become an executable. Runtime work is called by
/// HarnessController from its serial background queue.
enum RuntimeBootstrap {
    static let downloadProgressNotification = Notification.Name("DSHRuntimeDownloadProgress")
    enum Kind: String, Hashable {
        case node
        case python
    }

    struct Artifact {
        let kind: Kind
        let version: String
        let archiveName: String
        let url: URL
        let sha256: String
        let maximumBytes: Int64
        let executableRelativePath: String
        let minimumVersion: [Int]
    }

    struct Paths {
        let python: String
        let node: String
    }

    enum BootstrapError: LocalizedError {
        case unsupportedArchitecture
        case download(String)
        case invalidArchive(String)
        case invalidRuntime(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedArchitecture:
                return "此 Mac 的处理器架构暂不支持自动配置运行环境。"
            case .download(let detail):
                return "无法下载本机运行环境：\(detail)"
            case .invalidArchive(let detail):
                return "下载的运行环境未通过完整性检查：\(detail)"
            case .invalidRuntime(let detail):
                return "本机运行环境无法启动：\(detail)"
            }
        }
    }

    private static let nodeVersion = "24.21.0"
    private static let pythonVersion = "3.14.8+20261003"

    static func pinnedArtifacts(architecture: String) throws -> [Artifact] {
        switch architecture {
        case "arm64":
            return [
                Artifact(
                    kind: .node,
                    version: nodeVersion,
                    archiveName: "node-v24.21.0-darwin-arm64.tar.gz",
                    url: URL(string: "https://nodejs.org/dist/v24.21.0/node-v24.21.0-darwin-arm64.tar.gz")!,
                    sha256: "bed7eea5325e1108f32ce5228ddd6a5f0f08a499ee42aa7442aea583702f6057",
                    maximumBytes: 60 * 1024 * 1024,
                    executableRelativePath: "bin/node",
                    minimumVersion: [22]
                ),
                Artifact(
                    kind: .python,
                    version: pythonVersion,
                    archiveName: "cpython-3.14.8+20261003-aarch64-apple-darwin-install_only_stripped.tar.gz",
                    url: URL(string: "https://github.com/astral-sh/python-build-standalone/releases/download/20261003/cpython-3.14.8%2B20261003-aarch64-apple-darwin-install_only_stripped.tar.gz")!,
                    sha256: "ed14e9042f36c0aa18383f5d9729bcbf17847e842666a793b5a5a5d8505c0ca1",
                    maximumBytes: 32 * 1024 * 1024,
                    executableRelativePath: "bin/python3",
                    minimumVersion: [3, 10]
                )
            ]
        case "x86_64":
            return [
                Artifact(
                    kind: .node,
                    version: nodeVersion,
                    archiveName: "node-v24.21.0-darwin-x64.tar.gz",
                    url: URL(string: "https://nodejs.org/dist/v24.21.0/node-v24.21.0-darwin-x64.tar.gz")!,
                    sha256: "1462cb3b3046b815cf8ea436d3da450ec1a9f11dac7e5a46b0ada5305d7e8097",
                    maximumBytes: 60 * 1024 * 1024,
                    executableRelativePath: "bin/node",
                    minimumVersion: [22]
                ),
                Artifact(
                    kind: .python,
                    version: pythonVersion,
                    archiveName: "cpython-3.14.8+20261003-x86_64-apple-darwin-install_only_stripped.tar.gz",
                    url: URL(string: "https://github.com/astral-sh/python-build-standalone/releases/download/20261003/cpython-3.14.8%2B20261003-x86_64-apple-darwin-install_only_stripped.tar.gz")!,
                    sha256: "08310045a2611bad730d7c1a01e847a1ea729d9dcfe29110ca67cbdf3998bb54",
                    maximumBytes: 32 * 1024 * 1024,
                    executableRelativePath: "bin/python3",
                    minimumVersion: [3, 10]
                )
            ]
        default:
            throw BootstrapError.unsupportedArchitecture
        }
    }

    static func defaultRoot(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment["DSH_RUNTIME_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        let bundleID = Bundle.main.bundleIdentifier ?? "dev.fengyin.deepseek-harness-launcher"
        let productDirectory = bundleID.hasSuffix("-dev") ? "DSH Launcher Dev" : "DSH Launcher"
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(productDirectory, isDirectory: true)
            .appendingPathComponent("Runtimes", isDirectory: true)
    }

    /// Returns only runtimes which pass version checks. Existing binaries are
    /// preferred, and a missing side is installed independently. Tests can
    /// inject artifacts and a temporary root without touching the user cache.
    static func resolve(
        root: URL,
        architecture: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        settings: [String: String] = [:],
        artifacts suppliedArtifacts: [Artifact]? = nil,
        forceMissing: Set<Kind> = [],
        download: ((Artifact, URL) throws -> Void)? = nil
    ) throws -> Paths {
        let artifacts = try suppliedArtifacts ?? pinnedArtifacts(architecture: architecture)
        guard let nodeArtifact = artifacts.first(where: { $0.kind == .node }),
              let pythonArtifact = artifacts.first(where: { $0.kind == .python }) else {
            throw BootstrapError.invalidArchive("运行环境清单不完整。")
        }
        let testForce = environment["DSH_TEST_FORCE_RUNTIME_BOOTSTRAP"] == "1"
        let inheritedPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        var node = testForce || forceMissing.contains(.node) ? nil : findNode(environment: environment, settings: settings, path: inheritedPath)
        var python = testForce || forceMissing.contains(.python) ? nil : findPython(environment: environment, settings: settings, path: inheritedPath)

        if node == nil {
            let executable = try ensure(nodeArtifact, root: root, environment: environment, download: download)
            try validate(executable, minimum: nodeArtifact.minimumVersion, label: "Node.js")
            let npm = executable.deletingLastPathComponent().appendingPathComponent("npm")
            guard FileManager.default.isExecutableFile(atPath: npm.path) else {
                throw BootstrapError.invalidRuntime("Node.js 归档缺少配套 npm。")
            }
            node = executable
        }
        if python == nil {
            let executable = try ensure(pythonArtifact, root: root, environment: environment, download: download)
            try validate(executable, minimum: pythonArtifact.minimumVersion, label: "Python")
            python = executable
        }
        guard let node, let python else {
            throw BootstrapError.invalidRuntime("未能解析 Node.js 与 Python 路径。")
        }
        return Paths(python: python.path, node: node.path)
    }

    private static func findNode(environment: [String: String], settings: [String: String], path: String) -> URL? {
        let candidates = [environment["DSH_NODE_BIN"], settings["node_bin"], "/opt/homebrew/bin/node", "/usr/local/bin/node"]
            .compactMap { $0 } + path.split(separator: ":").map { String($0) + "/node" }
        for candidate in candidates {
            let url = URL(fileURLWithPath: (candidate as NSString).expandingTildeInPath)
            guard FileManager.default.isExecutableFile(atPath: url.path),
                  FileManager.default.isExecutableFile(atPath: url.deletingLastPathComponent().appendingPathComponent("npm").path),
                  (try? validate(url, minimum: [22], label: "Node.js")) != nil else { continue }
            return url
        }
        return nil
    }

    private static func findPython(environment: [String: String], settings: [String: String], path: String) -> URL? {
        let candidates = [environment["DSH_PYTHON_BIN"], settings["python_bin"], "/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
            .compactMap { $0 } + path.split(separator: ":").map { String($0) + "/python3" }
        for candidate in candidates {
            let url = URL(fileURLWithPath: (candidate as NSString).expandingTildeInPath)
            // /usr/bin/python3 may be Apple's interactive developer-tools stub.
            guard url.path != "/usr/bin/python3",
                  FileManager.default.isExecutableFile(atPath: url.path),
                  (try? validate(url, minimum: [3, 10], label: "Python")) != nil else { continue }
            return url
        }
        return nil
    }

    private static func validate(_ executable: URL, minimum: [Int], label: String) throws {
        let result = try run(executable, arguments: ["--version"])
        guard result.status == 0,
              let version = result.output.split(whereSeparator: { !$0.isNumber && $0 != "." }).first,
              versionAtLeast(String(version), minimum: minimum) else {
            throw BootstrapError.invalidRuntime("\(label) 版本过旧或无法运行，需要至少 \(minimum.map(String.init).joined(separator: "."))。")
        }
    }

    private static func versionAtLeast(_ value: String, minimum: [Int]) -> Bool {
        let parts = value.split(separator: ".").compactMap { Int($0) }
        guard !parts.isEmpty else { return false }
        for index in 0..<max(parts.count, minimum.count) {
            let left = index < parts.count ? parts[index] : 0
            let right = index < minimum.count ? minimum[index] : 0
            if left != right { return left > right }
        }
        return true
    }

    private static func ensure(
        _ artifact: Artifact,
        root: URL,
        environment: [String: String],
        download injectedDownload: ((Artifact, URL) throws -> Void)?
    ) throws -> URL {
        let final = root.appendingPathComponent("\(artifact.kind.rawValue)-\(artifact.version)", isDirectory: true)
        let executable = final.appendingPathComponent(artifact.executableRelativePath)
        let marker = final.appendingPathComponent(".dsh-runtime.json")
        if isComplete(executable, marker: marker, artifact: artifact) { return executable }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let lock = root.appendingPathComponent(".install-\(artifact.kind.rawValue)-\(artifact.version).lock", isDirectory: true)
        let lockDeadline = Date().addingTimeInterval(240)
        while true {
            do {
                try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
                try String(getpid()).write(to: lock.appendingPathComponent("owner"), atomically: true, encoding: .utf8)
                break
            } catch {
                if isComplete(executable, marker: marker, artifact: artifact) { return executable }
                if isStaleLock(lock) {
                    try? FileManager.default.removeItem(at: lock)
                    continue
                }
                guard Date() < lockDeadline else {
                    throw BootstrapError.invalidRuntime("另一个启动器实例仍在配置此运行环境；请稍后重试。")
                }
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
        defer { try? FileManager.default.removeItem(at: lock) }
        if isComplete(executable, marker: marker, artifact: artifact) { return executable }

        let stage = root.appendingPathComponent(".\(artifact.kind.rawValue)-stage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: stage) }
        let archive = stage.appendingPathComponent(artifact.archiveName)
        if let injectedDownload {
            try injectedDownload(artifact, archive)
        } else if environment["DSH_TEST_FORCE_RUNTIME_BOOTSTRAP"] == "1",
                  let archiveRoot = environment["DSH_RUNTIME_ARCHIVES"] {
            let local = URL(fileURLWithPath: archiveRoot, isDirectory: true).appendingPathComponent(artifact.archiveName)
            try FileManager.default.copyItem(at: local, to: archive)
        } else {
            try download(artifact, to: archive)
        }
        let size = try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init) ?? 0
        guard size > 0, size <= artifact.maximumBytes else {
            throw BootstrapError.invalidArchive("归档大小超出允许范围。")
        }
        guard try sha256(of: archive) == artifact.sha256.lowercased() else {
            throw BootstrapError.invalidArchive("SHA-256 不匹配。")
        }
        let expectedTop = artifact.kind == .node ? "node-v\(artifact.version)-darwin-\(architectureSuffix(artifact))" : "python"
        let entries = try listArchive(archive)
        try validateArchiveEntries(entries, expectedTop: expectedTop)
        let expanded = stage.appendingPathComponent("expanded", isDirectory: true)
        try FileManager.default.createDirectory(at: expanded, withIntermediateDirectories: false)
        let tar = URL(fileURLWithPath: "/usr/bin/tar")
        let extraction = try run(tar, arguments: ["-xzf", archive.path, "-C", expanded.path])
        guard extraction.status == 0 else {
            throw BootstrapError.invalidArchive(extraction.output.isEmpty ? "无法展开归档。" : extraction.output)
        }
        let extractedRoot = expanded.appendingPathComponent(expectedTop, isDirectory: true)
        let extractedExecutable = extractedRoot.appendingPathComponent(artifact.executableRelativePath)
        guard FileManager.default.isExecutableFile(atPath: extractedExecutable.path) else {
            throw BootstrapError.invalidArchive("归档缺少预期的可执行文件。")
        }
        try validate(extractedExecutable, minimum: artifact.minimumVersion, label: artifact.kind == .node ? "Node.js" : "Python")
        if artifact.kind == .node {
            let npm = extractedRoot.appendingPathComponent("bin/npm")
            guard FileManager.default.isExecutableFile(atPath: npm.path) else {
                throw BootstrapError.invalidArchive("Node.js 归档缺少配套 npm。")
            }
        }

        // Publish only after hash, archive structure, and executable checks.
        // A failed staging tree is discarded; a previous version stays intact.
        let publishStage = stage.appendingPathComponent("publish", isDirectory: true)
        try FileManager.default.moveItem(at: extractedRoot, to: publishStage)
        let stagedExecutable = publishStage.appendingPathComponent(artifact.executableRelativePath)
        try FileManager.default.createDirectory(at: final.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stale = root.appendingPathComponent(".stale-\(artifact.kind.rawValue)-\(UUID().uuidString)")
        if FileManager.default.fileExists(atPath: final.path) {
            try FileManager.default.moveItem(at: final, to: stale)
        }
        do {
            try FileManager.default.moveItem(at: publishStage, to: final)
        } catch {
            if FileManager.default.fileExists(atPath: stale.path) { try? FileManager.default.moveItem(at: stale, to: final) }
            throw error
        }
        if FileManager.default.fileExists(atPath: stale.path) {
            // Retain the previous version as a recoverable tree, not a live path.
            let retained = root.appendingPathComponent("previous-\(artifact.kind.rawValue)-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.moveItem(at: stale, to: retained)
        }
        _ = stagedExecutable
        let publishedExecutable = final.appendingPathComponent(artifact.executableRelativePath)
        try validate(publishedExecutable, minimum: artifact.minimumVersion, label: artifact.kind == .node ? "Node.js" : "Python")
        let markerData = try JSONSerialization.data(withJSONObject: [
            "schema": 1, "kind": artifact.kind.rawValue, "version": artifact.version,
            "sha256": artifact.sha256.lowercased(), "archive": artifact.archiveName
        ], options: [.sortedKeys])
        try markerData.write(to: final.appendingPathComponent(".dsh-runtime.json"), options: .atomic)
        return publishedExecutable
    }

    private static func isComplete(_ executable: URL, marker: URL, artifact: Artifact) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: executable.path),
              let data = try? Data(contentsOf: marker),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["kind"] as? String == artifact.kind.rawValue,
              object["version"] as? String == artifact.version,
              object["sha256"] as? String == artifact.sha256.lowercased() else { return false }
        return (try? validate(executable, minimum: artifact.minimumVersion, label: artifact.kind == .node ? "Node.js" : "Python")) != nil
    }

    private static func isStaleLock(_ lock: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: lock.path) else { return false }
        guard let owner = try? String(contentsOf: lock.appendingPathComponent("owner"), encoding: .utf8),
              let pid = Int32(owner.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            let modified = (try? lock.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            return Date().timeIntervalSince(modified) > 5
        }
        if kill(pid, 0) == 0 || errno == EPERM { return false }
        return errno == ESRCH
    }

    private static func architectureSuffix(_ artifact: Artifact) -> String {
        artifact.archiveName.contains("aarch64") || artifact.archiveName.contains("arm64") ? "arm64" : "x64"
    }

    private static func download(_ artifact: Artifact, to destination: URL) throws {
        guard artifact.url.scheme == "https",
              isAllowedHost(artifact.url.host ?? "") else {
            throw BootstrapError.download("运行环境清单中的下载地址不受信任。")
        }
        let semaphore = DispatchSemaphore(value: 0)
        let resultLock = NSLock()
        var result: Result<URL, Error>?
        var request = URLRequest(url: artifact.url)
        request.timeoutInterval = 180
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 180
        configuration.waitsForConnectivity = false
        let delegate = RuntimeDownloadDelegate(artifact: artifact, destination: destination) { outcome in
            resultLock.lock()
            result = outcome
            resultLock.unlock()
            semaphore.signal()
        }
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let task = session.downloadTask(with: request)
        task.resume()
        guard semaphore.wait(timeout: .now() + 200) == .success else {
            task.cancel()
            session.invalidateAndCancel()
            throw BootstrapError.download("下载超时，请检查网络后重试。")
        }
        session.finishTasksAndInvalidate()
        resultLock.lock()
        let completed = result
        resultLock.unlock()
        guard let completed else { throw BootstrapError.download("下载没有完成。") }
        _ = try completed.get()
    }

    private final class RuntimeDownloadDelegate: NSObject, URLSessionDownloadDelegate {
        private let artifact: Artifact
        private let destination: URL
        private let completion: (Result<URL, Error>) -> Void
        private let lock = NSLock()
        private var didComplete = false

        init(artifact: Artifact, destination: URL, completion: @escaping (Result<URL, Error>) -> Void) {
            self.artifact = artifact
            self.destination = destination
            self.completion = completion
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                        totalBytesExpectedToWrite: Int64) {
            if totalBytesWritten > artifact.maximumBytes {
                downloadTask.cancel()
                finish(.failure(BootstrapError.download("服务器返回的归档超过大小上限。")))
                return
            }
            NotificationCenter.default.post(
                name: RuntimeBootstrap.downloadProgressNotification,
                object: nil,
                userInfo: ["kind": artifact.kind.rawValue, "received": totalBytesWritten,
                           "expected": totalBytesExpectedToWrite]
            )
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {
            guard let response = downloadTask.response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode),
                  isAllowedHost(response.url?.host ?? "") else {
                finish(.failure(BootstrapError.download("服务器没有返回有效归档。")))
                return
            }
            do { try FileManager.default.moveItem(at: location, to: destination); finish(.success(destination)) }
            catch { finish(.failure(error)) }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error { finish(.failure(error)) }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            guard let url = request.url, url.scheme == "https", isAllowedHost(url.host ?? "") else {
                completionHandler(nil)
                return
            }
            completionHandler(request)
        }

        private func finish(_ result: Result<URL, Error>) {
            lock.lock()
            guard !didComplete else { lock.unlock(); return }
            didComplete = true
            lock.unlock()
            completion(result)
        }
    }

    private static func isAllowedHost(_ host: String) -> Bool {
        host == "nodejs.org" || host == "github.com" || host == "release-assets.githubusercontent.com"
            || host == "objects.githubusercontent.com" || host == "github-releases.githubusercontent.com"
    }

    private static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private struct ArchiveEntry {
        let path: String
        let kind: Character
        let linkTarget: String?
    }

    private static func listArchive(_ archive: URL) throws -> [ArchiveEntry] {
        let listing = try run(URL(fileURLWithPath: "/usr/bin/tar"), arguments: ["-tzf", archive.path])
        guard listing.status == 0 else { throw BootstrapError.invalidArchive("无法读取归档目录。") }
        let names = listing.output.split(whereSeparator: \.isNewline).map(String.init)
        let verbose = try run(URL(fileURLWithPath: "/usr/bin/tar"), arguments: ["-tvzf", archive.path])
        guard verbose.status == 0 else { throw BootstrapError.invalidArchive("无法检查归档链接。") }
        let rows = verbose.output.split(whereSeparator: \.isNewline).map(String.init)
        var linkTargets: [String: String] = [:]
        for row in rows {
            guard let type = row.first else { continue }
            if type == "h" { throw BootstrapError.invalidArchive("归档包含不支持的硬链接。") }
            guard type == "l" else { continue }
            guard let range = row.range(of: " -> ", options: .backwards) else {
                throw BootstrapError.invalidArchive("无法读取归档符号链接。")
            }
            let prefix = String(row[..<range.lowerBound])
            let target = String(row[range.upperBound...])
            guard let name = names.first(where: { prefix.hasSuffix(" \($0)") }) else {
                throw BootstrapError.invalidArchive("无法核对归档符号链接路径。")
            }
            linkTargets[name] = target
        }
        return names.filter { !$0.isEmpty }.map { name in
            ArchiveEntry(path: name, kind: linkTargets[name] == nil ? "?" : "l", linkTarget: linkTargets[name])
        }
    }

    private static func validateArchiveEntries(_ entries: [ArchiveEntry], expectedTop: String) throws {
        var symlinks = Set<String>()
        for entry in entries {
            let path = entry.path
            guard !path.hasPrefix("/"), !path.contains("\\"),
                  !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw BootstrapError.invalidArchive("归档含绝对路径或异常文件名。")
            }
            let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard !components.isEmpty, !components.contains(".."), !components.contains(".") else {
                throw BootstrapError.invalidArchive("归档试图写入目标目录之外。")
            }
            guard components.first == expectedTop else {
                throw BootstrapError.invalidArchive("归档包含预期目录之外的内容。")
            }
            if entry.kind == "h" { throw BootstrapError.invalidArchive("归档包含不支持的硬链接。") }
            if entry.kind == "l" {
                guard let target = entry.linkTarget,
                      !target.hasPrefix("/"), !target.contains("\\") else {
                    throw BootstrapError.invalidArchive("归档含不安全的符号链接。")
                }
                var resolved = Array(components.dropLast())
                for component in target.split(separator: "/") {
                    if component == ".." {
                        guard !resolved.isEmpty else { throw BootstrapError.invalidArchive("符号链接越出解压目录。") }
                        resolved.removeLast()
                    } else if component != "." {
                        resolved.append(String(component))
                    }
                }
                guard resolved.first == expectedTop else {
                    throw BootstrapError.invalidArchive("符号链接指向预期运行环境目录之外。")
                }
                symlinks.insert(components.joined(separator: "/"))
            }
        }
        for entry in entries {
            let components = entry.path.split(separator: "/").map(String.init)
            for count in 1..<components.count where symlinks.contains(components.prefix(count).joined(separator: "/")) {
                throw BootstrapError.invalidArchive("归档试图通过符号链接写入目录。")
            }
        }
    }

    private static func run(_ executable: URL, arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let reader = DispatchGroup()
        reader.enter()
        var data = Data()
        DispatchQueue.global(qos: .utility).async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            reader.leave()
        }
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        if exited.wait(timeout: .now() + 180) != .success {
            process.terminate()
            process.waitUntilExit()
            reader.wait()
            throw BootstrapError.invalidArchive("归档检查或展开超过时限。")
        }
        reader.wait()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (process.terminationStatus, output.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
