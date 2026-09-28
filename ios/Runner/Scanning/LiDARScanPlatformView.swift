import Flutter
import UIKit

/// Shared registry so method-channel calls reach the active platform view controller.
enum LiDARScanRegistry {
  static weak var activeController: LiDARScanViewController?
  static weak var plugin: LiDARScanPlugin?
}

final class LiDARScanPlatformViewFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    LiDARScanPlatformView(frame: frame, viewId: viewId, args: args, messenger: messenger)
  }
}

final class LiDARScanPlatformView: NSObject, FlutterPlatformView, LiDARScanViewControllerDelegate {
  private let controller: LiDARScanViewController

  init(frame: CGRect, viewId: Int64, args: Any?, messenger: FlutterBinaryMessenger) {
    controller = LiDARScanViewController()
    super.init()
    controller.eventDelegate = self
    LiDARScanRegistry.activeController = controller
    _ = frame
    _ = viewId
    _ = args
    _ = messenger
  }

  func view() -> UIView {
    controller.view
  }

  func scanController(_ controller: LiDARScanViewController, didEmitEvent payload: [String: Any]) {
    LiDARScanRegistry.plugin?.sendEvent(payload)
  }

  func scanController(
    _ controller: LiDARScanViewController,
    didFinishWithPath path: String?,
    error: String?
  ) {
    var payload: [String: Any] = ["type": "done"]
    if let path {
      payload["path"] = path
    }
    if let error {
      payload["error"] = error
    }
    LiDARScanRegistry.plugin?.sendEvent(payload)
    LiDARScanRegistry.plugin?.completePendingFinish(path: path, error: error)
  }
}
