import Foundation

public enum DetectionStatus: Equatable, Sendable {
    case idle
    case appleMusicNotRunning
    case notPlaying
    case paused
    case detecting
    case detected
    case permissionRequired
    case failed
}
