import Foundation

struct RTMPURL {
    let url: URL

    var streamName: String {
        let pathComponents = url.pathComponents.dropFirst(2)
        if let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.query {
            return pathComponents.joined(separator: "/") + "?" + query
        } else {
            return pathComponents.joined(separator: "/")
        }
    }

    var command: String {
        let target = "/" + streamName
        let urlString = url.absoluteString
        guard let range = urlString.range(of: target) else {
            return urlString
        }
        return urlString.replacingOccurrences(of: target, with: "", options: [], range: range)
    }

    init(url: URL) {
        self.url = url
    }
}
