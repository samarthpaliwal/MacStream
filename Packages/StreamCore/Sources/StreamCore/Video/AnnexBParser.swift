import Foundation

/// Splits Annex-B streams into NAL units and classifies parameter sets, the
/// two things a decoder needs before it can build a format description.
public enum AnnexBParser {
    /// NAL units in order, without start codes.
    public static func nalUnits(in data: Data) -> [Data] {
        let bytes = Data(data)
        var units: [Data] = []
        var index = 0
        var unitStart: Int?
        let count = bytes.count

        while index + 2 < count {
            if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                if let start = unitStart {
                    // Trailing zero of a 4-byte start code belongs to the code, not the unit.
                    var end = index
                    if end > start, bytes[end - 1] == 0 { end -= 1 }
                    if end > start { units.append(bytes[start..<end]) }
                }
                index += 3
                unitStart = index
            } else {
                index += 1
            }
        }
        if let start = unitStart, start < count {
            units.append(bytes[start..<count])
        }
        return units
    }

    public static func isParameterSet(_ nal: Data, codec: VideoPacketHeader.Codec) -> Bool {
        guard let first = nal.first else { return false }
        switch codec {
        case .hevc:
            let type = (first >> 1) & 0x3f
            return type >= 32 && type <= 34        // VPS, SPS, PPS
        case .h264:
            let type = first & 0x1f
            return type == 7 || type == 8           // SPS, PPS
        case .pcmAudio:
            return false
        }
    }

    /// Concatenates units with 4-byte big-endian length prefixes (AVCC/HVCC
    /// style), which is what CMSampleBuffer-based decoders expect.
    public static func lengthPrefixed(_ units: [Data]) -> Data {
        var out = Data(capacity: units.reduce(0) { $0 + $1.count + 4 })
        for unit in units {
            var length = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
            out.append(unit)
        }
        return out
    }
}
