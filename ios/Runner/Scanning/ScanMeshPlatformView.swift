import Flutter
import SceneKit
import UIKit

final class ScanMeshPlatformViewFactory: NSObject, FlutterPlatformViewFactory {
  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    ScanMeshPlatformView(frame: frame, path: Self.path(from: args))
  }

  private static func path(from args: Any?) -> String? {
    if let args = args as? [String: Any], let path = args["path"] as? String {
      return path
    }
    if let args = args as? NSDictionary, let path = args["path"] as? String {
      return path
    }
    return nil
  }
}

/// Orbit, pan, and pinch a saved scan. Only files inside Documents/scans can load.
final class ScanMeshPlatformView: NSObject, FlutterPlatformView {
  private let host = UIView()
  private let sceneView = SCNView()
  private let spinner = UIActivityIndicatorView(style: .large)
  private let message = UILabel()

  init(frame: CGRect, path: String?) {
    super.init()
    host.frame = frame
    host.backgroundColor = Self.backdrop
    sceneView.frame = host.bounds
    sceneView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    sceneView.backgroundColor = Self.backdrop
    sceneView.allowsCameraControl = true
    sceneView.defaultCameraController.interactionMode = .orbitTurntable
    sceneView.defaultCameraController.inertiaEnabled = true
    sceneView.autoenablesDefaultLighting = true
    host.addSubview(sceneView)

    spinner.color = .white
    spinner.translatesAutoresizingMaskIntoConstraints = false
    host.addSubview(spinner)
    NSLayoutConstraint.activate([
      spinner.centerXAnchor.constraint(equalTo: host.centerXAnchor),
      spinner.centerYAnchor.constraint(equalTo: host.centerYAnchor),
    ])

    message.textColor = UIColor.white.withAlphaComponent(0.9)
    message.font = .preferredFont(forTextStyle: .body)
    message.textAlignment = .center
    message.numberOfLines = 0
    message.translatesAutoresizingMaskIntoConstraints = false
    message.isHidden = true
    host.addSubview(message)
    NSLayoutConstraint.activate([
      message.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 24),
      message.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -24),
      message.centerYAnchor.constraint(equalTo: host.centerYAnchor),
    ])

    load(path: path)
  }

  func view() -> UIView { host }

  private func load(path: String?) {
    spinner.startAnimating()
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let loaded: Result<SCNScene, Error>
      do {
        guard let path, !path.isEmpty else {
          throw ScanMeshLoadError.invalid("That scan file is no longer on this device.")
        }
        let url = try ScanStorage.savedFile(path: path)
        loaded = .success(try ScanMeshScene.makeScene(from: url))
      } catch {
        loaded = .failure(error)
      }
      DispatchQueue.main.async {
        self?.show(loaded)
      }
    }
  }

  private func show(_ result: Result<SCNScene, Error>) {
    spinner.stopAnimating()
    switch result {
    case .success(let scene):
      scene.background.contents = Self.backdrop
      sceneView.scene = scene
      ScanMeshScene.frame(scene, in: sceneView)
    case .failure(let error):
      message.text = error.localizedDescription
      message.isHidden = false
    }
  }

  private static let backdrop = UIColor(red: 0.063, green: 0.165, blue: 0.200, alpha: 1)
}
