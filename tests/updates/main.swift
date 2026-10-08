import Foundation

let cases: [(String, String, Bool)] = [
    ("v1.0.0-rc.1", "1.0.0-rc.1", false),
    ("v1.0.0-rc.2", "1.0.0-rc.1", true),
    ("v1.0.0-rc.10", "1.0.0-rc.2", true),
    ("v1.0.0", "1.0.0-rc.1", true),
    ("v1.0.0-rc.1", "1.0.0", false),
    ("v0.9.0", "1.0.0-rc.1", false),
    ("v1.1.0", "1.0.0", true),
    ("invalid", "1.0.0", false)
]
for (candidate, current, expected) in cases {
    precondition(LauncherUpdates.isNewer(candidate, than: current) == expected,
                 "Invalid comparison: \(candidate) / \(current)")
}
print("Launcher release comparisons: \(cases.count) passed")

let preview: [String: Any] = ["draft": false, "prerelease": true, "tag_name": "v1.1.0-rc.1", "html_url": "https://github.com/XunFengCC/DSH-Launcher/releases/tag/v1.1.0-rc.1"]
let stable: [String: Any] = ["draft": false, "prerelease": false, "tag_name": "v1.0.0", "html_url": "https://github.com/XunFengCC/DSH-Launcher/releases/tag/v1.0.0"]
if case .current("v1.0.0") = LauncherUpdates.result(releases: [preview, stable], current: "1.0.0") {} else {
    preconditionFailure("Stable Apps must ignore preview releases")
}
if case .available("v1.1.0-rc.1", _) = LauncherUpdates.result(releases: [preview, stable], current: "1.0.0-rc.1") {} else {
    preconditionFailure("Preview Apps must be able to discover preview releases")
}
print("Stable and preview channel selection passed")
