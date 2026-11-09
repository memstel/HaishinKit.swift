import Foundation
import Testing

@testable import HaishinKit

@Suite struct StreamSessionBuilderFactoryTests {
    @Test(arguments: ["rtmp", "rtmps", "srt", "http", "https", "whep"])
    func rejectsMissingAuthority(_ scheme: String) async throws {
        let factory = StreamSessionBuilderFactory.shared
        for value in ["\(scheme):/", "\(scheme):/localhost/live/stream", "\(scheme):localhost/live/stream"] {
            let uri = try #require(URL(string: value))
            await #expect {
                _ = try await factory.make(uri)
            } throws: { error in
                guard case StreamSessionBuilderFactory.Error.illegalArgument = error else {
                    return false
                }
                return true
            }
            await #expect {
                _ = try await factory.build(uri, method: .publish, configuration: nil)
            } throws: { error in
                guard case StreamSessionBuilderFactory.Error.illegalArgument = error else {
                    return false
                }
                return true
            }
        }
    }

    @Test(arguments: [nil, "/live/stream", "//localhost/live/stream", "rtmps://", "https:///whep"] as [String?])
    func rejectsInvalidURL(_ value: String?) async {
        let uri = value.flatMap { URL(string: $0) }
        await #expect {
            _ = try await StreamSessionBuilderFactory.shared.make(uri)
        } throws: { error in
            guard case StreamSessionBuilderFactory.Error.illegalArgument = error else {
                return false
            }
            return true
        }
    }

    @Test func unsupportedScheme() async throws {
        let builder = try await StreamSessionBuilderFactory.shared.make(URL(string: "whep://localhost/live"))
        await #expect {
            _ = try await builder.build()
        } throws: { error in
            guard case StreamSessionBuilderFactory.Error.notFound = error else {
                return false
            }
            return true
        }
    }

    @Test(arguments: ["rtmp://localhost/live/stream", "rtmps://localhost/live/stream", "srt://localhost:9000", "srt://:9000", "http://localhost/whep", "https://localhost/whep"])
    func acceptsValidAuthority(_ value: String) async throws {
        _ = try await StreamSessionBuilderFactory.shared.make(URL(string: value))
    }
}
