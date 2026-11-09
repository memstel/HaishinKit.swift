import Foundation
import HaishinKit
import Testing

@testable import RTCHaishinKit

@Suite struct HTTPSessionTests {
    @Test(arguments: ["http:/localhost/whep", "https:/localhost/whep", "whep:/localhost/live", "https://", "https:///whep"])
    func rejectsMalformedURL(_ value: String) async throws {
        let uri = try #require(URL(string: value))
        for mode in [StreamSessionMode.publish, .playback] {
            let session = HTTPSessionFactory().make(uri, mode: mode, configuration: nil)
            await #expect {
                try await session.connect { }
            } throws: { error in
                (error as? URLError)?.code == .badURL
            }
            #expect(await session.connected == false)
            var states = await session.readyState.makeAsyncIterator()
            #expect(await states.next() == .closed)
        }
    }
}
