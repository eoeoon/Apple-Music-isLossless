import Foundation

public struct AudioFormat: Equatable, Sendable {
    public let codec: String?
    public let bitDepth: Int?
    public let bitRate: Int?
    public let sampleRate: Double?

    public init(codec: String? = nil, bitDepth: Int? = nil, bitRate: Int? = nil, sampleRate: Double? = nil) {
        self.codec = codec
        self.bitDepth = bitDepth
        self.bitRate = bitRate
        self.sampleRate = sampleRate
    }

    public var isEmpty: Bool {
        codec == nil && bitDepth == nil && bitRate == nil && sampleRate == nil
    }
}
