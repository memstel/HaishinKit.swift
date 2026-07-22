import CoreMedia

public protocol RTMPEncodedStreamOutput: AnyObject, Sendable {
    func stream(
        _ stream: RTMPStream,
        didOutputEncoded sampleBuffer: CMSampleBuffer
    )
}
