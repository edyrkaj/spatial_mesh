import ARKit
import CoreVideo
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
        message: "Green is already covered. Move on to surfaces that are still clear.",
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

struct ScanPoseSample {
  var position = SIMD3<Float>(repeating: 0)
  var time: TimeInterval = 0
  var hasSample = false
}

struct ScanAim {
  let symbol: String
  let message: String
  let level: String
}

/// Live "where to hold the phone" cue for a room scan.
enum ScanPoseCoach {
  static func room(frame: ARFrame, sample: inout ScanPoseSample) -> ScanAim {
    switch frame.camera.trackingState {
    case .notAvailable:
      return ScanAim(symbol: "sun.max", message: "Find more light, then hold the phone upright.", level: "bad")
    case .limited(.initializing):
      return ScanAim(symbol: "iphone", message: "Hold the phone upright at chest height and move slowly.", level: "warn")
    case .limited(.excessiveMotion):
      return ScanAim(symbol: "tortoise", message: "Slow down. Keep the phone steady while you sweep.", level: "warn")
    case .limited(.insufficientFeatures):
      return ScanAim(symbol: "lightbulb", message: "Point at a wall with texture, not a blank or dark surface.", level: "warn")
    case .limited(.relocalizing):
      return ScanAim(symbol: "arrow.uturn.backward", message: "Point the phone back at an area you already scanned.", level: "warn")
    case .limited:
      return ScanAim(symbol: "iphone", message: "Hold the phone upright and point it at the wall.", level: "warn")
    case .normal:
      break
    }

    let transform = frame.camera.transform
    let look = SIMD3<Float>(-transform.columns.2.x, -transform.columns.2.y, -transform.columns.2.z)
    let up = SIMD3<Float>(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z)
    let position = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)

    if up.y < 0.65 {
      return ScanAim(symbol: "iphone", message: "Hold the phone upright, the way you read it.", level: "warn")
    }
    if look.y < -0.5 {
      return ScanAim(symbol: "arrow.up", message: "Raise the phone. Point it at the wall, not the floor.", level: "warn")
    }
    if look.y > 0.4 {
      return ScanAim(symbol: "arrow.down", message: "Lower the phone. Point it at the wall, not the ceiling.", level: "warn")
    }

    if let depth = centerDepth(frame) {
      if depth < 0.4 {
        return ScanAim(symbol: "arrow.backward", message: "Step back. Stay about an arm's length from the surface.", level: "warn")
      }
      if depth > 4 {
        return ScanAim(symbol: "arrow.forward", message: "Move closer. Stay within a few steps of the wall.", level: "warn")
      }
    }

    if sample.hasSample {
      let dt = frame.timestamp - sample.time
      if dt > 0.05 {
        let speed = simd_distance(position, sample.position) / Float(dt)
        sample.position = position
        sample.time = frame.timestamp
        if speed > 0.7 {
          return ScanAim(symbol: "tortoise", message: "Slow down. Sweep sideways and keep the phone at this height.", level: "warn")
        }
      }
    } else {
      sample.position = position
      sample.time = frame.timestamp
      sample.hasSample = true
    }

    return ScanAim(
      symbol: "arrow.left.and.right",
      message: "Hold it here. Sweep slowly sideways. Skip areas that are already green.",
      level: "good"
    )
  }

  private static func centerDepth(_ frame: ARFrame) -> Float? {
    guard let depth = frame.smoothedSceneDepth ?? frame.sceneDepth else { return nil }
    let map = depth.depthMap
    CVPixelBufferLockBaseAddress(map, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
    let width = CVPixelBufferGetWidth(map)
    let height = CVPixelBufferGetHeight(map)
    guard width > 0, height > 0, let base = CVPixelBufferGetBaseAddress(map) else { return nil }
    let bytesPerRow = CVPixelBufferGetBytesPerRow(map)
    let row = base.advanced(by: (height / 2) * bytesPerRow).bindMemory(to: Float32.self, capacity: width)
    let value = row[width / 2]
    guard value.isFinite, value > 0 else { return nil }
    return value
  }
}
