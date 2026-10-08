import CryptoKit
import Foundation

private func require(_ value: @autoclosure () -> Bool, _ message: String) {
    guard value() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

private func process(_ executable: String, _ arguments: [String]) throws -> String {
    let child = Process()
    let pipe = Pipe()
    child.executableURL = URL(fileURLWithPath: executable)
    child.arguments = arguments
    child.standardOutput = pipe
    child.standardError = pipe
    child.standardInput = FileHandle.nullDevice
    try child.run()
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    child.waitUntilExit()
    guard child.terminationStatus == 0 else {
        throw NSError(domain: "RuntimeBootstrapTests", code: Int(child.terminationStatus), userInfo: [NSLocalizedDescriptionKey: String(decoding: output, as: UTF8.self)])
    }
    return String(decoding: output, as: UTF8.self)
}

private func writeExecutable(_ path: URL, _ contents: String) throws {
    try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    try contents.write(to: path, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
}

private func makeArchive(root: URL, top: String, kind: RuntimeBootstrap.Kind, maliciousLink: Bool = false) throws -> URL {
    let files = FileManager.default
    let source = root.appendingPathComponent("fixture-\(UUID().uuidString)", isDirectory: true)
    let bin = source.appendingPathComponent(top + "/bin", isDirectory: true)
    try files.createDirectory(at: bin, withIntermediateDirectories: true)
    if kind == .node {
        try writeExecutable(bin.appendingPathComponent("node"), "#!/bin/sh\necho v24.21.0\n")
        try writeExecutable(bin.appendingPathComponent("npm"), "#!/bin/sh\nexit 0\n")
        if maliciousLink {
            try files.createSymbolicLink(atPath: bin.appendingPathComponent("escape").path, withDestinationPath: "../../../../tmp/outside")
        }
    } else {
        try writeExecutable(bin.appendingPathComponent("python3"), "#!/bin/sh\necho 'Python 3.14.8'\n")
    }
    let archive = root.appendingPathComponent("\(kind.rawValue)-fixture-\(UUID().uuidString).tar.gz")
    _ = try process("/usr/bin/tar", ["-czf", archive.path, "-C", source.path, top])
    return archive
}

private func digest(_ url: URL) throws -> String {
    let data = try Data(contentsOf: url)
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func testArtifacts(node: URL, python: URL, wrongNodeHash: Bool = false) throws -> [RuntimeBootstrap.Artifact] {
    [
        RuntimeBootstrap.Artifact(
            kind: .node, version: "24.21.0", archiveName: "node-v24.21.0-darwin-arm64.tar.gz",
            url: URL(string: "https://fixture.invalid/node")!, sha256: wrongNodeHash ? String(repeating: "0", count: 64) : try digest(node),
            maximumBytes: 1024 * 1024, executableRelativePath: "bin/node", minimumVersion: [22]
        ),
        RuntimeBootstrap.Artifact(
            kind: .python, version: "3.14.8+20261003", archiveName: "python-fixture.tar.gz",
            url: URL(string: "https://fixture.invalid/python")!, sha256: try digest(python),
            maximumBytes: 1024 * 1024, executableRelativePath: "bin/python3", minimumVersion: [3, 10]
        )
    ]
}

let temp = FileManager.default.temporaryDirectory.appendingPathComponent("dsh-runtime-tests-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temp) }
let nodeArchive = try makeArchive(root: temp, top: "node-v24.21.0-darwin-arm64", kind: .node)
let pythonArchive = try makeArchive(root: temp, top: "python", kind: .python)
let artifacts = try testArtifacts(node: nodeArchive, python: pythonArchive)
let forced: [String: String] = ["PATH": "/usr/bin:/bin", "DSH_TEST_FORCE_RUNTIME_BOOTSTRAP": "1"]

// Both runtimes are checksum-verified, expanded in isolation and published.
let root = temp.appendingPathComponent("isolated-cache", isDirectory: true)
var downloadCount = 0
let paths = try RuntimeBootstrap.resolve(root: root, architecture: "arm64", environment: forced, artifacts: artifacts) { artifact, destination in
    downloadCount += 1
    let source = artifact.kind == .node ? nodeArchive : pythonArchive
    try FileManager.default.copyItem(at: source, to: destination)
}
require(downloadCount == 2, "expected one download for each missing runtime")
require(FileManager.default.isExecutableFile(atPath: paths.node), "published node executable")
require(FileManager.default.isExecutableFile(atPath: paths.python), "published python executable")
require(FileManager.default.fileExists(atPath: URL(fileURLWithPath: paths.node).deletingLastPathComponent().appendingPathComponent("npm").path), "node and npm stay paired")

// A complete cache is reused without downloading or trusting a half-tree.
let cached = try RuntimeBootstrap.resolve(root: root, architecture: "arm64", environment: forced, artifacts: artifacts) { _, _ in
    fatalError("complete cache unexpectedly attempted a download")
}
require(cached.node == paths.node && cached.python == paths.python, "complete cache reuse")

// A preinstalled supported Python is retained while only missing Node is added.
let existingRoot = temp.appendingPathComponent("existing-python", isDirectory: true)
let existingPython = temp.appendingPathComponent("existing/python3")
try writeExecutable(existingPython, "#!/bin/sh\necho 'Python 3.12.2'\n")
var kindsDownloaded: [RuntimeBootstrap.Kind] = []
_ = try RuntimeBootstrap.resolve(
    root: existingRoot, architecture: "arm64",
    environment: ["PATH": "/usr/bin:/bin", "DSH_PYTHON_BIN": existingPython.path],
    artifacts: artifacts, forceMissing: [.node]
) { artifact, destination in
    kindsDownloaded.append(artifact.kind)
    try FileManager.default.copyItem(at: artifact.kind == .node ? nodeArchive : pythonArchive, to: destination)
}
require(kindsDownloaded == [.node], "only absent runtime installed")

// Bad hashes and links escaping the extraction root leave no published cache.
let corruptRoot = temp.appendingPathComponent("bad-hash", isDirectory: true)
do {
    let badArtifacts = try testArtifacts(node: nodeArchive, python: pythonArchive, wrongNodeHash: true)
    _ = try RuntimeBootstrap.resolve(root: corruptRoot, architecture: "arm64", environment: forced, artifacts: badArtifacts) { _, destination in
        try FileManager.default.copyItem(at: nodeArchive, to: destination)
    }
    fatalError("wrong hash was accepted")
} catch let error as RuntimeBootstrap.BootstrapError {
    if case .invalidArchive = error {} else { fatalError("unexpected hash failure: \(error)") }
}
require(!FileManager.default.fileExists(atPath: corruptRoot.appendingPathComponent("node-24.21.0").path), "bad hash is not published")

let maliciousNode = try makeArchive(root: temp, top: "node-v24.21.0-darwin-arm64", kind: .node, maliciousLink: true)
let maliciousArtifacts = try testArtifacts(node: maliciousNode, python: pythonArchive)
let maliciousRoot = temp.appendingPathComponent("bad-link", isDirectory: true)
do {
    _ = try RuntimeBootstrap.resolve(root: maliciousRoot, architecture: "arm64", environment: forced, artifacts: maliciousArtifacts) { artifact, destination in
        try FileManager.default.copyItem(at: artifact.kind == .node ? maliciousNode : pythonArchive, to: destination)
    }
    fatalError("escaping symlink was accepted")
} catch let error as RuntimeBootstrap.BootstrapError {
    if case .invalidArchive = error {} else { fatalError("unexpected link failure: \(error)") }
}
require(!FileManager.default.fileExists(atPath: maliciousRoot.appendingPathComponent("node-24.21.0").path), "unsafe archive is not published")

// Optional local real-artifact proof. The Python wrapper supplies the two
// official archives under their pinned filenames; no network is used here.
if let realArchiveRoot = ProcessInfo.processInfo.environment["DSH_RUNTIME_ARCHIVES"] {
    let realRoot = temp.appendingPathComponent("real-artifact-cache", isDirectory: true)
    let realEnvironment = forced.merging(["DSH_RUNTIME_ARCHIVES": realArchiveRoot]) { _, new in new }
    let realPaths = try RuntimeBootstrap.resolve(root: realRoot, architecture: "arm64", environment: realEnvironment)
    require(FileManager.default.isExecutableFile(atPath: realPaths.node), "real Node archive executable")
    require(FileManager.default.isExecutableFile(atPath: realPaths.python), "real Python archive executable")
    print("Pinned Node and Python archives: SHA-256, links, extraction and execution passed")
}

print("Runtime bootstrap fixtures: 5 cases passed")
