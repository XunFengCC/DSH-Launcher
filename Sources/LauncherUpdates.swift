import Foundation

/// GitHub release checks are read-only. A missing unpublished repository and
/// network failure must remain distinct from "up to date". Downloads are left
/// to the signed release page; this application never overwrites itself.
enum LauncherUpdateCheck: Sendable {
    case available(String, URL)
    case current(String)
    case unpublished
    case failed(String)
}

enum LauncherUpdates {
    private final class Response: @unchecked Sendable {
        var data: Data?
        var response: URLResponse?
        var error: Error?
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ value: String) -> ([Int], String?) {
            let trimmed = value.hasPrefix("v") ? String(value.dropFirst()) : value
            let pair = trimmed.split(separator: "-", maxSplits: 1)
            let numbers = (pair.first ?? "").split(separator: ".").compactMap { Int($0) }
            return (numbers, pair.count > 1 ? String(pair[1]) : nil)
        }
        let lhs = parts(candidate), rhs = parts(current)
        guard lhs.0.count == 3, rhs.0.count == 3 else { return false }
        for index in 0..<3 where lhs.0[index] != rhs.0[index] {
            return lhs.0[index] > rhs.0[index]
        }
        if lhs.1 == rhs.1 { return false }
        if lhs.1 == nil { return true }
        if rhs.1 == nil { return false }
        return lhs.1!.compare(rhs.1!, options: .numeric) == .orderedDescending
    }

    static func check(current: String) -> LauncherUpdateCheck {
        let url = URL(string: "https://api.github.com/repos/FengYinYH/DSH-Launcher/releases?per_page=20")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("DSH-Launcher", forHTTPHeaderField: "User-Agent")
        let box = Response()
        let completed = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            box.data = data; box.response = response; box.error = error
            completed.signal()
        }
        task.resume()
        guard completed.wait(timeout: .now() + 12) == .success else {
            task.cancel()
            return .failed("连接超时，请稍后重试")
        }
        if let error = box.error { return .failed(error.localizedDescription) }
        guard let http = box.response as? HTTPURLResponse else { return .failed("未收到有效响应") }
        if http.statusCode == 404 { return .unpublished }
        guard http.statusCode == 200, let data = box.data,
              let releases = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return .failed("发布源返回 HTTP \(http.statusCode)")
        }
        return result(releases: releases, current: current)
    }

    /// Stable Apps follow stable releases; preview Apps may discover previews.
    /// The list endpoint is used because GitHub /latest omits prereleases.
    static func result(releases: [[String: Any]], current: String) -> LauncherUpdateCheck {
        let previewsAllowed = current.contains("-")
        let eligible = releases.filter {
            ($0["draft"] as? Bool) != true && (previewsAllowed || ($0["prerelease"] as? Bool) != true)
        }
        guard let latest = eligible.first, let tag = latest["tag_name"] as? String,
              let page = latest["html_url"] as? String, let pageURL = URL(string: page),
              pageURL.scheme == "https", pageURL.host == "github.com",
              pageURL.path.hasPrefix("/FengYinYH/DSH-Launcher/releases/tag/") else { return .unpublished }
        return isNewer(tag, than: current) ? .available(tag, pageURL) : .current(tag)
    }
}
