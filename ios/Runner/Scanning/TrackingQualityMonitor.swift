import ARKit
import Foundation

struct TrackingQualitySnapshot: Equatable {
  let state: String
  let message: String
  let level: String

  var asDictionary: [String: Any] {
    [
      "state": state,
      "message": message,
      "level": level,
    ]
  }
}

enum TrackingQualityMonitor {
  static func snapshot(for trackingState: ARCamera.TrackingState) -> TrackingQualitySnapshot {
    switch trackingState {
    case .normal:
      return TrackingQualitySnapshot(
        state: "normal",
        message: "Tracking OK — keep sweeping slowly across surfaces.",
        level: "good"
      )
    case .notAvailable:
      return TrackingQualitySnapshot(
        state: "notAvailable",
        message: "Tracking unavailable. Move to a well-lit area.",
        level: "error"
      )
    case .limited(let reason):
      switch reason {
      case .initializing:
        return TrackingQualitySnapshot(
          state: "initializing",
          message: "Initializing… move the device slowly.",
          level: "warn"
        )
      case .excessiveMotion:
        return TrackingQualitySnapshot(
          state: "excessiveMotion",
          message: "Too much motion — slow down.",
          level: "warn"
        )
      case .insufficientFeatures:
        return TrackingQualitySnapshot(
          state: "insufficientFeatures",
          message: "Need more texture / light for tracking.",
          level: "warn"
        )
      case .relocalizing:
        return TrackingQualitySnapshot(
          state: "relocalizing",
          message: "Relocalizing — return to a familiar area.",
          level: "warn"
        )
      @unknown default:
        return TrackingQualitySnapshot(
          state: "limited",
          message: "Tracking limited.",
          level: "warn"
        )
      }
    }
  }
}
