import Foundation

public struct AudioFormat: Equatable, Sendable {
    public let bitDepth: Int?
    public let sampleRate: Double?

    public init(bitDepth: Int? = nil, sampleRate: Double? = nil) {
        self.bitDepth = bitDepth
        self.sampleRate = sampleRate
    }

    public var isEmpty: Bool {
        bitDepth == nil && sampleRate == nil
    }
}
