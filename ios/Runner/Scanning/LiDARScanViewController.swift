import ARKit
import Flutter
import RealityKit
import UIKit

protocol LiDARScanViewControllerDelegate: AnyObject {
  func scanController(_ controller: LiDARScanViewController, didEmitEvent payload: [String: Any])
  func scanController(_ controller: LiDARScanViewController, didFinishWithPath path: String?, error: String?)
}

/// Hosts RealityKit ARView, mesh visualization, overlay controls, and export.
final class LiDARScanViewController: UIViewController {
  weak var eventDelegate: LiDARScanViewControllerDelegate?

  private var arView: ARView!
  private let overlay = ScanOverlayControls()
  private let visualizer = MeshWireframeVisualizer()
  private let exporter = MeshExportUtility()
  private var meshAnchors: [UUID: ARMeshAnchor] = [:]

  private var isRunning = false
  private var isPaused = false
  private var isFinishing = false
  private var preferredFormat: MeshExportFormat = .usdz

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black
    configureARView()
    configureOverlay()
    publishCapability()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    if !isRunning && !isPaused {
      // Keep session cold until Start — saves battery on non-scan screens.
      overlay.updateScanState(isRunning: false, isPaused: false, canFinish: false)
    }
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    if isRunning {
      pauseScan()
    }
  }

  // MARK: - Public commands (Flutter channel + overlay)

  func startScan() {
    guard LiDARCapability.isSupported else {
      let reason = LiDARCapability.unsupportedReason ?? "LiDAR unavailable"
      overlay.showError(reason)
      emit(["type": "error", "code": "LIDAR_UNSUPPORTED", "message": reason])
      return
    }

    overlay.clearError()
    let configuration = LiDARCapability.makeWorldTrackingConfiguration()
    if isPaused {
      arView.session.run(configuration, options: [])
    } else {
      meshAnchors.removeAll()
      visualizer.clear(from: arView)
      arView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }
    isRunning = true
    isPaused = false
    refreshOverlayState()
    emit(["type": "scanState", "state": "running"])
  }

  func pauseScan() {
    guard isRunning else { return }
    arView.session.pause()
    isRunning = false
    isPaused = true
    refreshOverlayState()
    emit(["type": "scanState", "state": "paused"])
  }

  func resetScan() {
    meshAnchors.removeAll()
    visualizer.clear(from: arView)
    isPaused = false
    isRunning = false
    arView.session.pause()
    overlay.clearError()
    refreshOverlayState()
    emit(["type": "scanState", "state": "reset", "meshCount": 0])
  }

  func finishScan(format: String?) {
    guard !isFinishing else { return }
    if let format, let parsed = MeshExportFormat(rawValue: format.lowercased()) {
      preferredFormat = parsed
    }

    let anchors = Array(meshAnchors.values)
    guard !anchors.isEmpty else {
      let message = MeshExportError.emptyMesh.localizedDescription
      overlay.showError(message)
      eventDelegate?.scanController(self, didFinishWithPath: nil, error: message)
      emit(["type": "error", "code": "EMPTY_MESH", "message": message])
      return
    }

    isFinishing = true
    overlay.clearError()
    overlay.updateScanState(isRunning: isRunning, isPaused: isPaused, canFinish: false)
    statusBusy("Exporting mesh…")

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else { return }
      do {
        let directory = FileManager.default.temporaryDirectory
          .appendingPathComponent("spatial_mesh_exports", isDirectory: true)
        let basename = "scan_\(Self.timestamp())"
        let url = try self.exporter.export(
          meshAnchors: anchors,
          format: self.preferredFormat,
          to: directory,
          basename: basename
        )
        DispatchQueue.main.async {
          self.isFinishing = false
          self.pauseScan()
          self.refreshOverlayState()
          self.emit([
            "type": "exportComplete",
            "path": url.path,
            "format": self.preferredFormat.rawValue,
          ])
          self.eventDelegate?.scanController(self, didFinishWithPath: url.path, error: nil)
        }
      } catch {
        DispatchQueue.main.async {
          self.isFinishing = false
          let message = error.localizedDescription
          self.overlay.showError(message)
          self.refreshOverlayState()
          self.emit(["type": "error", "code": "EXPORT_FAILED", "message": message])
          self.eventDelegate?.scanController(self, didFinishWithPath: nil, error: message)
        }
      }
    }
  }

  func currentMeshCount() -> Int { meshAnchors.count }

  // MARK: - Setup

  private func configureARView() {
    let arView = ARView(frame: view.bounds, cameraMode: .ar, automaticallyConfigureSession: false)
    arView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    arView.session.delegate = self
    arView.renderOptions.insert(.disableMotionBlur)
    view.addSubview(arView)
    self.arView = arView
    visualizer.attach(to: arView)
  }

  private func configureOverlay() {
    overlay.translatesAutoresizingMaskIntoConstraints = false
    overlay.delegate = self
    view.addSubview(overlay)
    NSLayoutConstraint.activate([
      overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      overlay.topAnchor.constraint(equalTo: view.topAnchor),
      overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
  }

  private func publishCapability() {
    emit([
      "type": "capability",
      "available": LiDARCapability.isSupported,
      "reason": LiDARCapability.unsupportedReason as Any,
    ])
    if let reason = LiDARCapability.unsupportedReason {
      overlay.showError(reason)
    }
  }

  private func refreshOverlayState() {
    overlay.updateMeshCount(meshAnchors.count)
    overlay.updateScanState(
      isRunning: isRunning,
      isPaused: isPaused,
      canFinish: !meshAnchors.isEmpty && !isFinishing
    )
  }

  private func statusBusy(_ text: String) {
    overlay.updateTracking(text, level: "warn")
  }

  private func emit(_ payload: [String: Any]) {
    eventDelegate?.scanController(self, didEmitEvent: payload)
  }

  private static func timestamp() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd_HHmmss"
    return formatter.string(from: Date())
  }
}

extension LiDARScanViewController: ScanOverlayControlsDelegate {
  func overlayDidTapStart() { startScan() }
  func overlayDidTapPause() { pauseScan() }
  func overlayDidTapReset() { resetScan() }
  func overlayDidTapDone() { finishScan(format: preferredFormat.rawValue) }
}

extension LiDARScanViewController: ARSessionDelegate {
  func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
    handle(anchors: anchors, removed: false)
  }

  func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
    handle(anchors: anchors, removed: false)
  }

  func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
    handle(anchors: anchors, removed: true)
  }

  func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
    let snap = TrackingQualityMonitor.snapshot(for: camera.trackingState)
    overlay.updateTracking(snap.message, level: snap.level)
    var payload = snap.asDictionary
    payload["type"] = "tracking"
    emit(payload)
  }

  func session(_ session: ARSession, didFailWithError error: Error) {
    let message = error.localizedDescription
    overlay.showError(message)
    emit(["type": "error", "code": "SESSION_FAILED", "message": message])
  }

  private func handle(anchors: [ARAnchor], removed: Bool) {
    for anchor in anchors {
      guard let mesh = anchor as? ARMeshAnchor else { continue }
      if removed {
        meshAnchors.removeValue(forKey: mesh.identifier)
        visualizer.remove(id: mesh.identifier, from: arView)
      } else {
        meshAnchors[mesh.identifier] = mesh
        visualizer.upsert(meshAnchor: mesh, in: arView)
      }
    }
    refreshOverlayState()
    emit(["type": "meshCount", "count": meshAnchors.count])
  }
}
