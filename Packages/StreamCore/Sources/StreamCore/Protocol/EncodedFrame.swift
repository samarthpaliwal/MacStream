import Foundation

/// One encoded video frame ready for the network or a file.
/// `data` is Annex-B (start-code delimited NAL units). Keyframes carry their
/// parameter sets (VPS/SPS/PPS) in front so a decoder can start from any
/// keyframe without out-of-band configuration.
public struct EncodedFrame: Sendable {
    public var data: Data
    public var isKeyframe: Bool
    public var codec: VideoPacketHeader.Codec
    public var width: Int
    public var height: Int
    /// Host monotonic clock when the frame was displayed on the Mac.
    public var captureNanos: UInt64
    /// Host monotonic clock when the capture framework delivered the frame.
    public var deliveredNanos: UInt64
    /// Host monotonic clock when the encoder emitted the frame.
    public var encodedNanos: UInt64

    public init(data: Data, isKeyframe: Bool, codec: VideoPacketHeader.Codec, width: Int, height: Int, captureNanos: UInt64, deliveredNanos: UInt64, encodedNanos: UInt64) {
        self.data = data
        self.isKeyframe = isKeyframe
        self.codec = codec
        self.width = width
        self.height = height
        self.captureNanos = captureNanos
        self.deliveredNanos = deliveredNanos
        self.encodedNanos = encodedNanos
    }
}
