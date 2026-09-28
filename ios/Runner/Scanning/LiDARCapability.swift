import ARKit
import Foundation

/// Hardware / OS guards for Phase 1 LiDAR mesh scanning.
enum LiDARCapability {
  static var isSupported: Bool {
    ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
  }

  static var unsupportedReason: String? {
    guard ARWorldTrackingConfiguration.isSupported else {
      return "This device does not support ARKit world tracking."
    }
    guard isSupported else {
      return "LiDAR scene reconstruction requires iPhone 12 Pro / iPad Pro (2020) or newer."
    }
    return nil
  }

  static func makeWorldTrackingConfiguration() -> ARWorldTrackingConfiguration {
    let configuration = ARWorldTrackingConfiguration()
    if isSupported {
      configuration.sceneReconstruction = .mesh
    }
    if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
      configuration.frameSemantics.insert(.smoothedSceneDepth)
    } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
      configuration.frameSemantics.insert(.sceneDepth)
    }
    configuration.environmentTexturing = .automatic
    configuration.planeDetection = [.horizontal, .vertical]
    return configuration
  }
}
