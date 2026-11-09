import Foundation
import Testing

import libsrt
@testable import SRTHaishinKit

@Suite struct SRTConnectionTests {
    @Test(arguments: ["srt:/", "srt:/localhost:9000", "srt:localhost:9000"])
    func rejectsMalformedURL(_ value: String) async throws {
        let uri = try #require(URL(string: value))
        let connection = SRTConnection()
        await #expect {
            try await connection.connect(uri)
        } throws: { error in
            guard case SRTConnection.Error.unsupportedUri(let value) = error else {
                return false
            }
            return value == uri
        }
        #expect(await connection.connected == false)
        #expect(await connection.uri == nil)
    }

    @Test func streamid_success() async throws {
        Task {
            let listener = SRTConnection()
            try await listener.connect(URL(string: "srt://:10000?streamid=test"))
        }
        Task {
            let connection = SRTConnection()
            try await Task.sleep(nanoseconds: UInt64(1 * 1_000_000_000))
            try await connection.connect(URL(string: "srt://127.0.0.1:10000?streamid=test"))
            await connection.close()
        }
    }

    @Test func streamid_failed() async throws {
        Task {
            let listener = SRTConnection()
            try await listener.connect(URL(string: "srt://:10001?streamid=test&passphrase=a546994dbf25a0823f0cbadff9cc5088k9e7c2027e8e40933a04ef574bc61cd4a"))
        }
        Task {
            let connection = SRTConnection()
            try await Task.sleep(nanoseconds: UInt64(1 * 1_000_000_000))
            await #expect(throws: SRTConnection.Error.self) {
                try await connection.connect(URL(string: "srt://127.0.0.1:10001?streamid=test2&passphrase=a546994dbf25a0823f0cbadff9cc5088k9e7c2027e8e40933a04ef574bc61cd4"))
            }
            await connection.close()
        }
    }
}
