import AVFoundation
import Foundation
import Testing

@testable import RTMPHaishinKit

@Suite struct RTMPURLTests {
    @Test(arguments: ["rtmps:/", "rtmps://localhost", "rtmps://localhost/"])
    func missingStreamName(_ value: String) throws {
        let url = RTMPURL(url: try #require(URL(string: value)))
        #expect(url.streamName.isEmpty)
        _ = url.command
    }

    @Test func main() {
        let url = RTMPURL(url: URL(string: "rtmp://localhost/live/live")!)
        #expect(url.streamName == "live")
        #expect(url.command == "rtmp://localhost/live")
    }

    @Test func query() {
        let url = RTMPURL(url: URL(string: "rtmp://localhost/live/live?parameter")!)
        #expect(url.streamName == "live?parameter")
        #expect(url.command == "rtmp://localhost/live")
    }
}
