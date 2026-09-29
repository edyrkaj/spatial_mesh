import ARKit
import Flutter
import RealityKit
import SwiftUI
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
  private let colorCapture = ScanColorCapture()
  private var meshAnchors: [UUID: ARMeshAnchor] = [:]

  private var isRunning = false
  private var isPaused = false
  private var isFinishing = false
  private var scanEpoch = 0
  private var preferredFormat: MeshExportFormat = LiDARScanRegistry.exportFormat
  private var scanSubject: ScanSubject = .room
  private var objectPhase: ObjectPhase = .idle
  private var objectDriverBox: AnyObject?
  private var objectHost: UIViewController?
  private var objectBuild: Task<Void, Never>?

  private enum ObjectPhase {
    case idle
    case detecting
    case capturing
    case building
  }

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
    if scanSubject == .object {
      guard #available(iOS 17.0, *), PhotogrammetrySession.isSupported else {
        let message = "Object photos need iOS 17 on this iPhone. Choose Room to build from the LiDAR of what you scan."
        overlay.showError(message)
        emit(["type": "error", "code": "OBJECT_UNSUPPORTED", "message": message])
        return
      }
      startObjectScan()
      return
    }
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
      colorCapture.reset()
      arView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }
    isRunning = true
    isPaused = false
    refreshOverlayState()
    overlay.showStatus("Walk the room")
    overlay.updateTracking(
      "A green mask covers surfaces already scanned. Leave those areas and aim at what is still clear.",
      level: "good"
    )
    emit(["type": "scanState", "state": "running"])
  }

  func pauseScan() {
    if #available(iOS 17.0, *), objectPhase == .capturing || objectPhase == .detecting {
      objectDriver?.pause()
      isRunning = false
      isPaused = true
      refreshObjectControls()
      emit(["type": "scanState", "state": "paused"])
      return
    }
    guard isRunning else { return }
    arView.session.pause()
    isRunning = false
    isPaused = true
    refreshOverlayState()
    emit(["type": "scanState", "state": "paused"])
  }

  func resetScan() {
    scanEpoch += 1
    objectBuild?.cancel()
    objectBuild = nil
    if #available(iOS 17.0, *) {
      retireObjectCapture()
    }
    objectPhase = .idle
    arView.isHidden = false
    meshAnchors.removeAll()
    visualizer.clear(from: arView)
    colorCapture.reset()
    isPaused = false
    isRunning = false
    isFinishing = false
    if LiDARCapability.isSupported {
      let configuration = LiDARCapability.makeWorldTrackingConfiguration()
      arView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }
    arView.session.pause()
    overlay.prepareForNewScan()
    overlay.setSubject(scanSubject, locked: false)
    showIdleGuidance()
    emit(["type": "scanState", "state": "reset", "meshCount": 0])
    emit(["type": "meshCount", "count": 0])
  }

  func finishScan(format: String?) {
    guard !isFinishing else { return }
    if let format, let parsed = MeshExportFormat(rawValue: format.lowercased()) {
      preferredFormat = parsed
      LiDARScanRegistry.exportFormat = parsed
    }

    if #available(iOS 17.0, *), objectPhase == .capturing || objectPhase == .detecting {
      finishObjectScan()
      return
    }

    let anchors = Array(meshAnchors.values)
    let frames = colorCapture.snapshot()
    guard !anchors.isEmpty else {
      let message = MeshExportError.emptyMesh.localizedDescription
      overlay.showError(message)
      eventDelegate?.scanController(self, didFinishWithPath: nil, error: message)
      emit(["type": "error", "code": "EMPTY_MESH", "message": message])
      return
    }

    isFinishing = true
    let epoch = scanEpoch
    overlay.clearError()
    overlay.updateScanState(isRunning: isRunning, isPaused: isPaused, canFinish: false)
    statusBusy("Saving scan…")

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else { return }
      do {
        let directory = ScanStorage.directory
        let basename = "scan_\(Self.timestamp())"
        let url = try self.exporter.export(
          meshAnchors: anchors,
          colorFrames: frames,
          format: self.preferredFormat,
          to: directory,
          basename: basename
        )
        DispatchQueue.main.async {
          let stillCurrent = self.scanEpoch == epoch
          self.isFinishing = false
          self.eventDelegate?.scanController(self, didFinishWithPath: url.path, error: nil)
          guard stillCurrent else { return }
          self.pauseScan()
          self.refreshOverlayState()
          self.overlay.showCompleted(fileName: url.lastPathComponent)
          self.emit([
            "type": "exportComplete",
            "path": url.path,
            "format": self.preferredFormat.rawValue,
          ])
        }
      } catch {
        DispatchQueue.main.async {
          let stillCurrent = self.scanEpoch == epoch
          self.isFinishing = false
          let message = error.localizedDescription
          self.eventDelegate?.scanController(self, didFinishWithPath: nil, error: message)
          guard stillCurrent else { return }
          self.overlay.showError(message)
          self.refreshOverlayState()
          self.emit(["type": "error", "code": "EXPORT_FAILED", "message": message])
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
    overlay.setSubject(scanSubject, locked: false)
    showIdleGuidance()
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
    overlay.setSubject(scanSubject, locked: isRunning || isPaused || isFinishing)
    overlay.updateScanState(
      isRunning: isRunning,
      isPaused: isPaused,
      canFinish: !meshAnchors.isEmpty && !isFinishing
    )
  }

  private func showIdleGuidance() {
    switch scanSubject {
    case .room:
      overlay.showStatus("Room scan")
      overlay.updateTracking(
        "For a room or anything too big to look over. Green marks what is already covered. Aim at the clear areas.",
        level: "good"
      )
    case .object:
      overlay.showStatus("Object scan")
      overlay.updateTracking(
        "For a small item you can walk around. The photos you take become the model. Skip any side you cannot reach.",
        level: "good"
      )
    }
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
  func setExportFormat(_ format: MeshExportFormat) {
    preferredFormat = format
    LiDARScanRegistry.exportFormat = format
  }

  func overlayDidTapDone() { finishScan(format: preferredFormat.rawValue) }

  func overlayDidSelectSubject(_ subject: ScanSubject) {
    guard objectPhase == .idle, !isRunning, !isPaused, !isFinishing else {
      overlay.setSubject(scanSubject, locked: true)
      return
    }
    scanSubject = subject
    showIdleGuidance()
  }

  func overlayDidTapShoot() {
    if #available(iOS 17.0, *) {
      objectDriver?.shoot()
    }
  }
}

@available(iOS 17.0, *)
private extension LiDARScanViewController {
  var objectDriver: ObjectScanDriver? {
    get { objectDriverBox as? ObjectScanDriver }
    set { objectDriverBox = newValue }
  }

  func startObjectScan() {
    switch objectPhase {
    case .idle:
      beginObjectDetecting()
    case .detecting:
      beginObjectOrbit()
    case .capturing where objectDriver?.passComplete == true && !isPaused:
      objectDriver?.continueCapturing()
      emit(["type": "scanState", "state": "running"])
    case .capturing where isPaused:
      objectDriver?.resume()
      isRunning = true
      isPaused = false
      objectPhase = .capturing
      refreshObjectControls()
      overlay.showStatus("Keep moving so each photo overlaps the last one")
      emit(["type": "scanState", "state": "running"])
    default:
      break
    }
  }

  func beginObjectDetecting() {
    arView.session.pause()
    arView.isHidden = true
    detachObjectCamera()
    let driver = ObjectScanDriver()
    driver.onStatus = { [weak self] message, level in
      self?.overlay.showStatus(message)
      self?.overlay.updateTracking(message, level: level)
      self?.emit(["type": "tracking", "message": message, "level": level])
    }
    driver.onCaptureClosed = { [weak self] in
      self?.detachObjectCamera()
    }
    driver.onShots = { [weak self] shots in
      guard let self else { return }
      self.overlay.updateObjectCoverage(shots: shots)
      self.refreshObjectControls(shots: shots)
      self.emit(["type": "meshCount", "count": shots])
    }
    objectDriver = driver
    do {
      try driver.beginDetecting()
    } catch {
      objectDriver = nil
      overlay.showError(error.localizedDescription)
      emit(["type": "error", "code": "OBJECT_SCAN", "message": error.localizedDescription])
      return
    }
    installObjectCamera(driver)
    objectPhase = .detecting
    isRunning = false
    isPaused = false
    refreshObjectControls()
    overlay.showStatus("Center the object in the box, then tap Start")
    emit(["type": "scanState", "state": "running"])
  }

  func beginObjectOrbit() {
    objectDriver?.beginCapturing()
    objectPhase = .capturing
    isRunning = true
    isPaused = false
    refreshObjectControls()
    overlay.showStatus("Move so each photo overlaps the last one.")
    overlay.updateTracking(
      "Green marks what is already photographed. Skip those areas and cover what is still clear. Tap Done to build from those photos.",
      level: "good"
    )
    emit(["type": "scanState", "state": "running"])
  }

  func finishObjectScan() {
    guard let driver = objectDriver else { return }
    guard driver.shots > 0 else {
      let message = ObjectScanError.notEnoughViews.localizedDescription
      overlay.showError(message)
      emit(["type": "error", "code": "NEED_ORBIT", "message": message])
      return
    }
    isFinishing = true
    objectPhase = .building
    let epoch = scanEpoch
    overlay.showStatus("Building from the photos you took…")
    overlay.updateTracking("The model uses these shots. This can take a few minutes.", level: "warn")
    refreshObjectControls()
    objectBuild = Task { [weak self] in
      guard let self else { return }
      do {
        let url = try await driver.finishAndExport(to: ScanStorage.directory, basename: "object_\(Self.timestamp())")
        await MainActor.run {
          guard self.scanEpoch == epoch else { return }
          self.completeScan(path: url.path, epoch: epoch)
        }
      } catch {
        await MainActor.run {
          guard self.scanEpoch == epoch else { return }
          self.failScan(message: ObjectScanDriver.readable(error), epoch: epoch)
        }
      }
    }
  }

  func detachObjectCamera() {
    let host = objectHost
    objectHost = nil
    host?.willMove(toParent: nil)
    host?.view.removeFromSuperview()
    host?.removeFromParent()
  }

  func retireObjectCapture() {
    detachObjectCamera()
    let driver = objectDriver
    objectDriver = nil
    DispatchQueue.main.async {
      driver?.cancel()
    }
  }

  func installObjectCamera(_ driver: ObjectScanDriver) {
    detachObjectCamera()
    let host = UIHostingController(rootView: ObjectScanCamera(session: driver.session, driver: driver))
    host.view.backgroundColor = .black
    host.view.frame = view.bounds
    host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    addChild(host)
    view.insertSubview(host.view, belowSubview: overlay)
    host.didMove(toParent: self)
    objectHost = host
  }

  func completeScan(path: String, epoch: Int) {
    guard scanEpoch == epoch else { return }
    isFinishing = false
    objectPhase = .idle
    isRunning = false
    isPaused = false
    eventDelegate?.scanController(self, didFinishWithPath: path, error: nil)
    retireObjectCapture()
    arView.isHidden = false
    overlay.prepareForNewScan()
    overlay.setSubject(scanSubject, locked: false)
    showIdleGuidance()
    emit(["type": "meshCount", "count": 0])
  }

  func failScan(message: String, epoch: Int) {
    isFinishing = false
    if objectPhase == .building {
      objectPhase = .capturing
    }
    eventDelegate?.scanController(self, didFinishWithPath: nil, error: message)
    guard scanEpoch == epoch else { return }
    overlay.showError(message)
    refreshObjectControls()
    emit(["type": "error", "code": "EXPORT_FAILED", "message": message])
  }

  func refreshObjectControls(shots: Int? = nil) {
    let count = shots ?? objectDriver?.shots ?? 0
    overlay.updateScanState(
      isRunning: isRunning,
      isPaused: isPaused,
      canFinish: count > 0 && !isFinishing && objectPhase == .capturing,
      preserveStatus: true
    )
    overlay.showShootButton(false)
    overlay.setSubject(scanSubject, locked: objectPhase != .idle || isFinishing)
  }
}

extension LiDARScanViewController: ARSessionDelegate {
  func session(_ session: ARSession, didUpdate frame: ARFrame) {
    guard isRunning else { return }
    colorCapture.record(frame)
  }

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
    guard objectPhase == .idle else { return }
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
