import Foundation

public enum DetectionStatus: Equatable, Sendable {
    case idle
    case appleMusicNotRunning
    case notPlaying
    case detecting
    case detected
    case permissionRequired
    case failed
}
