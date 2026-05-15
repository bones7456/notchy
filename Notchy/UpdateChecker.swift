import Foundation
import AppKit

@Observable
class UpdateChecker {
    static let shared = UpdateChecker()

    enum State: Equatable {
        case idle
        case checking
        case upToDate(current: String)
        case updateAvailable(latest: String, current: String, url: URL)
        case failed(String)
    }

    private(set) var state: State = .idle

    private let releasesAPI = URL(string: "https://api.github.com/repos/bones7456/notchy/releases/latest")!
    private let releasesPage = URL(string: "https://github.com/bones7456/notchy/releases/latest")!

    var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }

    @MainActor
    func check() async {
        if case .checking = state { return }
        state = .checking

        var request = URLRequest(url: releasesAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                state = .failed("Server returned status \(code)")
                return
            }

            guard
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let tagName = json["tag_name"] as? String
            else {
                state = .failed("Unexpected response from GitHub")
                return
            }

            let latest = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
            let current = currentVersion
            let url = (json["html_url"] as? String).flatMap(URL.init(string:)) ?? releasesPage

            if UpdateChecker.isVersion(latest, newerThan: current) {
                state = .updateAvailable(latest: latest, current: current, url: url)
            } else {
                state = .upToDate(current: current)
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    static func isVersion(_ latest: String, newerThan current: String) -> Bool {
        let l = components(latest)
        let c = components(current)
        let count = max(l.count, c.count)
        for i in 0..<count {
            let a = i < l.count ? l[i] : 0
            let b = i < c.count ? c[i] : 0
            if a != b { return a > b }
        }
        return false
    }

    private static func components(_ version: String) -> [Int] {
        version
            .split(whereSeparator: { !$0.isNumber })
            .compactMap { Int($0) }
    }
}
