import Flutter
import UIKit

final class LiDARScanPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private var eventSink: FlutterEventSink?
  private var pendingFinishResult: FlutterResult?

  static func register(with registrar: FlutterPluginRegistrar) {
    let instance = LiDARScanPlugin()
    LiDARScanRegistry.plugin = instance

    let method = FlutterMethodChannel(
      name: "com.spatialmesh/lidar_scan",
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(instance, channel: method)

    let events = FlutterEventChannel(
      name: "com.spatialmesh/lidar_scan_events",
      binaryMessenger: registrar.messenger()
    )
    events.setStreamHandler(instance)

    let factory = LiDARScanPlatformViewFactory(messenger: registrar.messenger())
    registrar.register(factory, withId: "com.spatialmesh/lidar_scan_view")

    let meshFactory = ScanMeshPlatformViewFactory()
    registrar.register(meshFactory, withId: "com.spatialmesh/scan_mesh_view")
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isLiDARAvailable":
      result(LiDARCapability.isSupported)
    case "unsupportedReason":
      result(LiDARCapability.unsupportedReason)
    case "startScan":
      guard let controller = LiDARScanRegistry.activeController else {
        result(FlutterError(code: "NO_VIEW", message: "Scan view is not mounted.", details: nil))
        return
      }
      controller.startScan()
      result(nil)
    case "pauseScan":
      LiDARScanRegistry.activeController?.pauseScan()
      result(nil)
    case "resetScan":
      LiDARScanRegistry.activeController?.resetScan()
      result(nil)
    case "finishScan":
      guard let controller = LiDARScanRegistry.activeController else {
        result(FlutterError(code: "NO_VIEW", message: "Scan view is not mounted.", details: nil))
        return
      }
      if pendingFinishResult != nil {
        result(FlutterError(code: "BUSY", message: "Export already in progress.", details: nil))
        return
      }
      pendingFinishResult = result
      let args = call.arguments as? [String: Any]
      let format = args?["format"] as? String
      controller.finishScan(format: format)
    case "setExportFormat":
      let args = call.arguments as? [String: Any]
      let raw = (args?["format"] as? String)?.lowercased() ?? ""
      guard let parsed = MeshExportFormat(rawValue: raw) else {
        result(FlutterError(code: "BAD_FORMAT", message: "Unknown export format '\(raw)'.", details: nil))
        return
      }
      LiDARScanRegistry.exportFormat = parsed
      LiDARScanRegistry.activeController?.setExportFormat(parsed)
      result(nil)
    case "listScans":
      do {
        result(try ScanStorage.list())
      } catch {
        result(FlutterError(code: "LIST_FAILED", message: error.localizedDescription, details: nil))
      }
    case "shareScan":
      let path = Self.stringArgument(call, key: "path") ?? ""
      do {
        try ScanStorage.share(path: path)
        result(nil)
      } catch {
        result(FlutterError(code: "SHARE_FAILED", message: error.localizedDescription, details: nil))
      }
    case "deleteScan":
      let path = Self.stringArgument(call, key: "path") ?? ""
      let name = Self.stringArgument(call, key: "name") ?? ""
      do {
        try ScanStorage.delete(path: path, name: name)
        result(nil)
      } catch {
        result(FlutterError(code: "DELETE_FAILED", message: error.localizedDescription, details: nil))
      }
    case "meshCount":
      result(LiDARScanRegistry.activeController?.currentMeshCount() ?? 0)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Flutter maps arrive as `NSDictionary`, which does not always cast to `[String: Any]`.
  private static func stringArgument(_ call: FlutterMethodCall, key: String) -> String? {
    if let args = call.arguments as? [String: Any], let value = args[key] as? String {
      return value
    }
    if let args = call.arguments as? [AnyHashable: Any], let value = args[key] as? String {
      return value
    }
    if let args = call.arguments as? NSDictionary, let value = args[key] as? String {
      return value
    }
    return nil
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    events([
      "type": "capability",
      "available": LiDARCapability.isSupported,
      "reason": LiDARCapability.unsupportedReason as Any,
    ])
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  func sendEvent(_ payload: [String: Any]) {
    DispatchQueue.main.async { [weak self] in
      self?.eventSink?(payload)
    }
  }

  func completePendingFinish(path: String?, error: String?) {
    DispatchQueue.main.async { [weak self] in
      guard let self, let pending = self.pendingFinishResult else { return }
      self.pendingFinishResult = nil
      if let error {
        pending(FlutterError(code: "EXPORT_FAILED", message: error, details: nil))
      } else if let path {
        pending(["path": path])
      } else {
        pending(FlutterError(code: "EXPORT_FAILED", message: "Unknown export failure.", details: nil))
      }
    }
  }
}
