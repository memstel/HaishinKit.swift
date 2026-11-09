import Foundation
import Testing

@testable import SRTHaishinKit

@Suite struct SRTSocketURLTests {
    @Test(arguments: ["srt://:9000", "srt://:9000?mode=listener"])
    func acceptsListenerWithoutHost(_ value: String) throws {
        let url = try #require(SRTSocketURL(URL(string: value)))
        #expect(url.mode == .listener)
        #expect(url.local != nil)
    }

    @Test func acceptsCaller() throws {
        let url = try #require(SRTSocketURL(URL(string: "srt://localhost:9000")))
        #expect(url.mode == .caller)
        #expect(url.remote != nil)
    }
}
