import ARKit
import Foundation
import RealityKit
import SwiftUI
import UIKit

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

  /// Values read from this phone, not a generic requirement line.
  static func deviceReport() -> [String: Any] {
    let machine = machineIdentifier()
    let product = marketingName(for: machine)
    return [
      "name": product,
      "machine": machine,
      "systemName": UIDevice.current.systemName,
      "systemVersion": UIDevice.current.systemVersion,
      "lidar": isSupported,
      "sceneDepth": ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
        || ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth),
      "objectCapture": objectCaptureSupported(),
      "photogrammetry": photogrammetrySupported(),
    ]
  }

  private static func objectCaptureSupported() -> Bool {
    guard #available(iOS 17.0, *) else { return false }
    return MainActor.assumeIsolated { ObjectCaptureSession.isSupported }
  }

  private static func photogrammetrySupported() -> Bool {
    guard #available(iOS 17.0, *) else { return false }
    return PhotogrammetrySession.isSupported
  }

  private static func machineIdentifier() -> String {
    var systemInfo = utsname()
    uname(&systemInfo)
    return withUnsafeBytes(of: &systemInfo.machine) { raw in
      let bytes = raw.bindMemory(to: CChar.self)
      return String(cString: bytes.baseAddress!)
    }
  }

  /// Apple's public model name when this identifier is known. Otherwise the identifier itself.
  private static func marketingName(for machine: String) -> String {
    let names = [
      "iPhone13,3": "iPhone 12 Pro",
      "iPhone13,4": "iPhone 12 Pro Max",
      "iPhone14,2": "iPhone 13 Pro",
      "iPhone14,3": "iPhone 13 Pro Max",
      "iPhone15,2": "iPhone 14 Pro",
      "iPhone15,3": "iPhone 14 Pro Max",
      "iPhone16,1": "iPhone 15 Pro",
      "iPhone16,2": "iPhone 15 Pro Max",
      "iPhone17,1": "iPhone 16 Pro",
      "iPhone17,2": "iPhone 16 Pro Max",
      "iPhone17,3": "iPhone 16",
      "iPhone17,4": "iPhone 16 Plus",
      "iPad8,9": "iPad Pro 11-inch (2nd generation)",
      "iPad8,10": "iPad Pro 11-inch (2nd generation)",
      "iPad8,11": "iPad Pro 12.9-inch (4th generation)",
      "iPad8,12": "iPad Pro 12.9-inch (4th generation)",
      "iPad13,4": "iPad Pro 11-inch (3rd generation)",
      "iPad13,5": "iPad Pro 11-inch (3rd generation)",
      "iPad13,6": "iPad Pro 11-inch (3rd generation)",
      "iPad13,7": "iPad Pro 11-inch (3rd generation)",
      "iPad13,8": "iPad Pro 12.9-inch (5th generation)",
      "iPad13,9": "iPad Pro 12.9-inch (5th generation)",
      "iPad13,10": "iPad Pro 12.9-inch (5th generation)",
      "iPad13,11": "iPad Pro 12.9-inch (5th generation)",
      "iPad14,3": "iPad Pro 11-inch (4th generation)",
      "iPad14,4": "iPad Pro 11-inch (4th generation)",
      "iPad14,5": "iPad Pro 12.9-inch (6th generation)",
      "iPad14,6": "iPad Pro 12.9-inch (6th generation)",
      "iPad16,3": "iPad Pro 11-inch (M4)",
      "iPad16,4": "iPad Pro 11-inch (M4)",
      "iPad16,5": "iPad Pro 13-inch (M4)",
      "iPad16,6": "iPad Pro 13-inch (M4)",
    ]
    return names[machine] ?? machine
  }
}
