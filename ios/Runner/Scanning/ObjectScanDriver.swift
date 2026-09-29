import ImageIO
import ModelIO
import RealityKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import zlib

enum ObjectScanError: LocalizedError {
  case unsupported
  case notEnoughViews
  case noModel
  case cancelled

  var errorDescription: String? {
    switch self {
    case .unsupported:
      return "This iPhone cannot build an object model on device. Use iPhone 12 Pro or newer on iOS 17."
    case .notEnoughViews:
      return "Walk around the object a little so there is at least one photo, then tap Done."
    case .noModel:
      return "Could not build the object. Orbit it again in steady light, with a plain background."
    case .cancelled:
      return "Object build was cancelled."
    }
  }
}

/// Object-focused capture. Stills from an orbit beat a video: each shot is sharp and posed,
/// which is what photogrammetry needs to reconstruct a real mesh.
@available(iOS 17.0, *)
@MainActor
final class ObjectScanDriver: ObservableObject {
  @Published private(set) var session = ObjectCaptureSession()
  @Published private(set) var shots = 0
  @Published private(set) var guidePhase = 0
  @Published private(set) var passComplete = false
  private var awaitingNextPass = false
  private(set) var isActive = false

  var onStatus: ((String, String) -> Void)?
  var onShots: ((Int) -> Void)?
  /// Called after the photo set is closed, before the model is built.
  var onCaptureClosed: (() -> Void)?

  private var imagesDirectory: URL?
  private var watchers: [Task<Void, Never>] = []
  private var photogrammetry: PhotogrammetrySession?
  private var didStartCapturing = false

  func beginDetecting() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("object_capture_\(UUID().uuidString)", isDirectory: true)
    let images = root.appendingPathComponent("Images", isDirectory: true)
    let checkpoint = root.appendingPathComponent("Checkpoint", isDirectory: true)
    try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: checkpoint, withIntermediateDirectories: true)

    imagesDirectory = images
    didStartCapturing = false
    shots = 0
    passComplete = false
    guidePhase = 0
    awaitingNextPass = false
    isActive = true
    observe(session)

    var configuration = ObjectCaptureSession.Configuration()
    configuration.checkpointDirectory = checkpoint
    configuration.isOverCaptureEnabled = true
    session.start(imagesDirectory: images, configuration: configuration)
    if #available(iOS 18.0, *) {
      session.isAutoCaptureEnabled = true
      session.shouldPlayHaptics = true
    }
    session.startDetecting()
    onShots?(0)
    onStatus?("Center the object in the box, then tap Start", "warn")
  }

  func shoot() {
    guard isActive, didStartCapturing else { return }
    guard session.canRequestImageCapture else {
      onStatus?("Move to the mark, hold still, then tap Shoot again", "warn")
      return
    }
    session.requestImageCapture()
    onStatus?(Self.nextPosition(shots: shots, passComplete: passComplete), "good")
  }

  func beginCapturing() {
    guard isActive, !didStartCapturing else { return }
    didStartCapturing = true
    guidePhase = 1
    session.startCapturing()
    onStatus?("Move so each photo overlaps the last one. Green glitter marks what is already scanned.", "good")
  }

  func pause() {
    guard !session.isPaused else { return }
    session.pause()
    onStatus?("Paused", "warn")
  }

  func resume() {
    guard session.isPaused else { return }
    session.resume()
    onStatus?("Keep moving. Green glitter shows the parts already scanned.", "good")
  }

  /// Keeps capturing the same object. A new pass continues from the photos already taken
  /// and does not require lifting the object or looking at its underside.
  func continueCapturing() {
    guard isActive, session.userCompletedScanPass else { return }
    session.beginNewScanPass()
    passComplete = false
    onStatus?("Keep covering the sides you can reach. Tap Done to build from these photos.", "good")
  }

  func cancel() {
    isActive = false
    watchers.forEach { $0.cancel() }
    watchers = []
    photogrammetry?.cancel()
    photogrammetry = nil
    session.cancel()
    if let imagesDirectory {
      try? FileManager.default.removeItem(at: imagesDirectory.deletingLastPathComponent())
    }
    imagesDirectory = nil
  }

  func finishAndExport(to directory: URL, basename: String) async throws -> URL {
    guard PhotogrammetrySession.isSupported else { throw ObjectScanError.unsupported }
    let images = try await finishCapture()
    await MainActor.run { self.onCaptureClosed?() }
    let count = Self.imageCount(in: images)
    guard count > 0 else { throw ObjectScanError.notEnoughViews }

    let scratch = FileManager.default.temporaryDirectory
      .appendingPathComponent("object_model_\(UUID().uuidString).usdz")
    defer { try? FileManager.default.removeItem(at: scratch) }

    try await reconstruct(images: images, usdz: scratch)
    photogrammetry = nil
    try await Task.sleep(nanoseconds: 750_000_000)
    guard FileManager.default.fileExists(atPath: scratch.path) else {
      throw ObjectScanError.noModel
    }

    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let packaged = directory.appendingPathComponent("\(basename).usdz")
    if FileManager.default.fileExists(atPath: packaged.path) {
      try FileManager.default.removeItem(at: packaged)
    }
    try FileManager.default.copyItem(at: scratch, to: packaged)

    await MainActor.run { self.onStatus?("Saving…", "good") }
    let output = directory.appendingPathComponent("\(basename).gltf")
    let data = try await Task.detached(priority: .userInitiated) {
      try TexturedModelGLTF.data(fromUSDZ: packaged)
    }.value
    try data.write(to: output, options: .atomic)
    if let imagesDirectory {
      try? FileManager.default.removeItem(at: imagesDirectory.deletingLastPathComponent())
      self.imagesDirectory = nil
    }
    isActive = false
    return output
  }

  private func finishCapture() async throws -> URL {
    guard let imagesDirectory else { throw ObjectScanError.noModel }
    isActive = false
    await MainActor.run { session.finish() }
    for _ in 0..<120 {
      let state = await MainActor.run { session.state }
      if case .completed = state { return imagesDirectory }
      if case .failed(let error) = state { throw error }
      try await Task.sleep(nanoseconds: 500_000_000)
    }
    throw ObjectScanError.noModel
  }

  private func reconstruct(images: URL, usdz: URL) async throws {
    try await runReconstruction(images: images, usdz: usdz, detail: .reduced)
  }

  private func runReconstruction(
    images: URL,
    usdz: URL,
    detail: PhotogrammetrySession.Request.Detail
  ) async throws {
    var configuration = PhotogrammetrySession.Configuration()
    configuration.sampleOrdering = .unordered
    configuration.featureSensitivity = .normal
    let session = try PhotogrammetrySession(input: images, configuration: configuration)
    photogrammetry = session
    let request = PhotogrammetrySession.Request.modelFile(url: usdz, detail: detail)
    try session.process(requests: [request])

    for try await output in session.outputs {
      switch output {
      case .requestProgress(_, let fraction):
        let percent = min(100, Int((fraction * 100).rounded()))
        let message = percent >= 100 ? "Saving…" : "Building the 3D object… \(percent)%"
        await MainActor.run { self.onStatus?(message, "warn") }
      case .requestError(_, let error):
        throw error
      case .processingCancelled:
        throw ObjectScanError.cancelled
      case .processingComplete:
        return
      default:
        break
      }
    }
  }

  private func observe(_ session: ObjectCaptureSession) {
    watchers.forEach { $0.cancel() }
    watchers = [
      Task { @MainActor in
        for await _ in session.stateUpdates {
          self.publish(session)
        }
      },
      Task { @MainActor in
        for await count in session.numberOfShotsTakenUpdates {
          self.shots = count
          self.onShots?(count)
          self.publish(session)
        }
      },
      Task { @MainActor in
        for await _ in session.feedbackUpdates {
          self.publish(session)
        }
      },
    ]
  }

  private func publish(_ session: ObjectCaptureSession) {
    let shots = session.numberOfShotsTaken
    if shots != self.shots {
      self.shots = shots
      onShots?(shots)
    }
    guard isActive else { return }
    let passDone = session.userCompletedScanPass
    passComplete = passDone
    if passDone, !awaitingNextPass {
      awaitingNextPass = true
      advanceGuide()
    } else if !passDone {
      awaitingNextPass = false
    }
    if case .failed(let error) = session.state {
      onStatus?(error.localizedDescription, "bad")
      return
    }
    let message = Self.coaching(session, guidePhase: guidePhase)
    if !message.isEmpty {
      onStatus?(message, "good")
    }
  }

  private func advanceGuide() {
    guidePhase = 1
    session.beginNewScanPass()
    passComplete = false
    onStatus?("Keep moving so each view overlaps the last. Cover what you can reach, then tap Done.", "good")
  }

  static let aroundNames = [
    "front",
    "30° to the right",
    "60° to the right",
    "the right side",
    "120°",
    "150°",
    "the back",
    "210°",
    "240°",
    "the left side",
    "300°",
    "330°",
  ]
  static let aroundCount = 12
  static let topCount = 12
  static let underCount = 12
  static var requiredShots: Int { aroundCount + topCount + underCount }

  static func nextPosition(shots: Int, passComplete: Bool) -> String {
    if shots < aroundCount {
      return "Around, \(aroundNames[shots]). Stay level, move, then tap Shoot."
    }
    if shots < aroundCount + topCount {
      let step = shots - aroundCount + 1
      return "Top \(step) of \(topCount). Raise the phone and look down, then tap Shoot."
    }
    if shots < requiredShots {
      let step = shots - aroundCount - topCount + 1
      return "Under \(step) of \(underCount). Tip the object so the bottom faces you, then tap Shoot."
    }
    return passComplete
      ? "All \(requiredShots) photos are in. Tap Done"
      : "Around, top, and underside are in. Tap Done"
  }

  private static func coaching(_ session: ObjectCaptureSession, guidePhase: Int) -> String {
    let feedback = session.feedback
    if feedback.contains(.movingTooFast) {
      return "Slow down. Keep the object in frame and overlap the green glitter."
    }
    if feedback.contains(.objectTooFar) { return "Move closer to the object" }
    if feedback.contains(.objectTooClose) { return "Step back so the whole object fits" }
    if feedback.contains(.environmentTooDark) || feedback.contains(.environmentLowLight) {
      return "More light will make the real texture sharper"
    }
    if feedback.contains(.outOfFieldOfView) { return "Keep the object inside the frame" }
    if session.state == .capturing {
      return "Move so the next photo overlaps the green glitter. Cover the sides you can reach, then tap Done."
    }
    return ""
  }

  static func readable(_ error: Error) -> String {
    let nsError = error as NSError
    let domain = nsError.domain
    if nsError.code == 6, domain.contains("Photogrammetry") || domain.contains("CoreOC") {
      return "These photos do not overlap enough to build a model. Move slowly so each view shares part of the last one. For a room or a large piece, tap Reset and choose Room. Room builds the 3D from the LiDAR of the surfaces you scanned."
    }
    return error.localizedDescription
  }

  private static func imageCount(in folder: URL) -> Int {
    guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else {
      return 0
    }
    var count = 0
    for case let file as URL in enumerator {
      switch file.pathExtension.lowercased() {
      case "heic", "jpg", "jpeg", "png":
        count += 1
      default:
        break
      }
    }
    return count
  }
}

@available(iOS 17.0, *)
struct ObjectScanCamera: View {
  let session: ObjectCaptureSession
  @ObservedObject var driver: ObjectScanDriver

  var body: some View {
    ZStack(alignment: .bottomLeading) {
      StableCaptureLayer(session: session)
        .ignoresSafeArea()
      OrbitStoryboard(shots: driver.shots, guidePhase: driver.guidePhase)
        .padding(.leading, 12)
        .padding(.bottom, 230)
        .allowsHitTesting(false)
    }
  }
}

/// Camera plus a glittering point cloud on the surfaces already photographed.
/// Both capture views are created once, so they are not built again after the session ends.
@available(iOS 17.0, *)
private struct StableCaptureLayer: UIViewControllerRepresentable {
  let session: ObjectCaptureSession

  func makeUIViewController(context: Context) -> CaptureContainerController {
    CaptureContainerController(session: session)
  }

  func updateUIViewController(_ controller: CaptureContainerController, context: Context) {}
}

@available(iOS 17.0, *)
private final class CaptureContainerController: UIViewController {
  private let cameraHost: UIHostingController<ObjectCaptureView<EmptyView>>
  private let pointsHost: UIHostingController<ObjectCapturePointCloudView>

  init(session: ObjectCaptureSession) {
    cameraHost = UIHostingController(rootView: ObjectCaptureView(session: session))
    pointsHost = UIHostingController(rootView: ObjectCapturePointCloudView(session: session))
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black
    embed(cameraHost)
    embed(pointsHost)
    pointsHost.view.backgroundColor = .clear
    pointsHost.view.isUserInteractionEnabled = false
    let tint = UIView(frame: pointsHost.view.bounds)
    tint.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    tint.isUserInteractionEnabled = false
    tint.backgroundColor = UIColor(red: 0.2, green: 0.95, blue: 0.4, alpha: 1)
    tint.layer.compositingFilter = "sourceIn"
    pointsHost.view.addSubview(tint)
    // Black stays invisible, so the green glitter sits on the camera.
    pointsHost.view.layer.compositingFilter = "screen"
    let glitter = CABasicAnimation(keyPath: "opacity")
    glitter.fromValue = 0.2
    glitter.toValue = 1
    glitter.duration = 0.42
    glitter.autoreverses = true
    glitter.repeatCount = .infinity
    glitter.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    pointsHost.view.layer.add(glitter, forKey: "glitter")
  }

  private func embed(_ host: UIViewController) {
    addChild(host)
    host.view.frame = view.bounds
    host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    view.addSubview(host.view)
    host.didMove(toParent: self)
  }
}

/// Live hint while photographing a small object: overlap the views you can actually reach.
@available(iOS 17.0, *)
private struct OrbitStoryboard: View {
  let shots: Int
  let guidePhase: Int

  private let names = ObjectScanDriver.aroundNames

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Overlap the sides you can reach. Green is already photographed.")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white)
        .lineLimit(3)
        .frame(width: 200, alignment: .leading)
      ZStack {
        Circle()
          .stroke(.white.opacity(0.35), lineWidth: 2)
          .frame(width: 112, height: 112)
        ForEach(names.indices, id: \.self) { index in
          ringStop(index)
        }
        Image(systemName: "cube")
          .font(.caption)
          .foregroundStyle(.white.opacity(0.9))
      }
      .frame(width: 200, height: 140)
    }
    .padding(10)
    .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
  }

  private func ringStop(_ index: Int) -> some View {
    let progress = min(1, Double(shots) / Double(names.count))
    let filled = guidePhase > 1 || progress * Double(names.count) > Double(index)
    let angle = (Double(index) / Double(names.count)) * 2 * Double.pi - Double.pi / 2
    let radius = 50.0
    return marker(done: filled, isNext: guidePhase == 1, symbol: "camera.fill")
      .offset(x: CGFloat(cos(angle) * radius), y: CGFloat(sin(angle) * radius))
  }

  private func marker(done: Bool, isNext: Bool, symbol: String) -> some View {
    Circle()
      .fill(done ? Color(red: 0.35, green: 0.95, blue: 0.85) : Color.white.opacity(isNext ? 0.95 : 0.28))
      .frame(width: isNext ? 20 : 14, height: isNext ? 20 : 14)
      .overlay {
        if isNext {
          Image(systemName: symbol)
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.black)
        }
      }
      .scaleEffect(isNext ? 1.12 : 1)
      .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: isNext)
  }
}

/// Turns a photogrammetry USDZ (textured mesh) into a glTF Three.js can load.
enum TexturedModelGLTF {
  static func data(fromUSDZ url: URL) throws -> Data {
    let textures = try unpackedTextures(from: url)
    defer { try? FileManager.default.removeItem(at: textures.root) }
    let asset = MDLAsset(url: url)

    var positions: [SIMD3<Float>] = []
    var normals: [SIMD3<Float>] = []
    var uvs: [SIMD2<Float>] = []
    var indices: [UInt32] = []
    var texture: CGImage? = textures.albedo.flatMap { UIImage(contentsOfFile: $0.path)?.cgImage }

    for index in 0..<asset.count {
      collect(asset.object(at: index), positions: &positions, normals: &normals, uvs: &uvs, indices: &indices, texture: &texture)
    }
    guard !positions.isEmpty, !indices.isEmpty else { throw ObjectScanError.noModel }
    if normals.count != positions.count {
      normals = Array(repeating: SIMD3<Float>(0, 1, 0), count: positions.count)
    }
    if uvs.count != positions.count {
      uvs = Array(repeating: SIMD2<Float>(0, 0), count: positions.count)
    }

    let png = texture.flatMap(pngData(from:))
    return try gltf(positions: positions, normals: normals, uvs: uvs, indices: indices, png: png)
  }

  private struct UnpackedTextures {
    var root: URL
    var albedo: URL?
  }

  /// Pulls the color photo out of the USDZ. The mesh file references it as
  /// `0/<name>_tex0.png`, which is the image that makes the USDZ look real.
  private static func unpackedTextures(from url: URL) throws -> UnpackedTextures {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("usdz_pack_\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try ZipUnpack.extract(url, to: root)
    return UnpackedTextures(root: root, albedo: albedoTexture(in: root))
  }

  private static func albedoTexture(in root: URL) -> URL? {
    guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
    var fallback: URL?
    for case let file as URL in files where file.pathExtension.lowercased() == "png" {
      let name = file.lastPathComponent.lowercased()
      if name.contains("norm") || name.contains("_ao") { continue }
      if name.contains("tex0") || name.contains("color") || name.contains("albedo") { return file }
      fallback = fallback ?? file
    }
    return fallback
  }

  private static func collect(
    _ object: MDLObject,
    positions: inout [SIMD3<Float>],
    normals: inout [SIMD3<Float>],
    uvs: inout [SIMD2<Float>],
    indices: inout [UInt32],
    texture: inout CGImage?
  ) {
    if let mesh = object as? MDLMesh {
      let base = UInt32(positions.count)
      appendVertices(mesh, positions: &positions, normals: &normals, uvs: &uvs)
      if let submeshes = mesh.submeshes as? [MDLSubmesh] {
        for submesh in submeshes {
          appendIndices(submesh, base: base, indices: &indices)
          if texture == nil {
            texture = baseColorImage(from: submesh.material)
          }
        }
      }
    }
    for child in object.children.objects {
      collect(child, positions: &positions, normals: &normals, uvs: &uvs, indices: &indices, texture: &texture)
    }
  }

  private static func appendVertices(
    _ mesh: MDLMesh,
    positions: inout [SIMD3<Float>],
    normals: inout [SIMD3<Float>],
    uvs: inout [SIMD2<Float>]
  ) {
    guard let positionData = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributePosition) else { return }
    let normalData = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributeNormal)
    let uvData = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributeTextureCoordinate)
    for index in 0..<mesh.vertexCount {
      positions.append(readFloat3(positionData, index: index))
      if let normalData {
        normals.append(readFloat3(normalData, index: index))
      }
      if let uvData {
        let uv = readFloat2(uvData, index: index)
        uvs.append(SIMD2(uv.x, 1 - uv.y))
      }
    }
  }

  private static func appendIndices(_ submesh: MDLSubmesh, base: UInt32, indices: inout [UInt32]) {
    let map = submesh.indexBuffer.map()
    let raw = map.bytes.assumingMemoryBound(to: UInt8.self)
    let stride = submesh.indexType == .uInt16 ? 2 : 4
    for index in 0..<submesh.indexCount {
      let value: UInt32
      if stride == 2 {
        value = UInt32(raw.advanced(by: index * 2).withMemoryRebound(to: UInt16.self, capacity: 1) { $0.pointee })
      } else {
        value = raw.advanced(by: index * 4).withMemoryRebound(to: UInt32.self, capacity: 1) { $0.pointee }
      }
      indices.append(base + value)
    }
  }

  private static func readFloat3(_ data: MDLVertexAttributeData, index: Int) -> SIMD3<Float> {
    let pointer = data.dataStart.advanced(by: index * data.stride).assumingMemoryBound(to: Float.self)
    return SIMD3(pointer[0], pointer[1], pointer[2])
  }

  private static func readFloat2(_ data: MDLVertexAttributeData, index: Int) -> SIMD2<Float> {
    let pointer = data.dataStart.advanced(by: index * data.stride).assumingMemoryBound(to: Float.self)
    return SIMD2(pointer[0], pointer[1])
  }

  private static func baseColorImage(from material: MDLMaterial?) -> CGImage? {
    guard let property = material?.property(with: .baseColor) else { return nil }
    if let texture = property.textureSamplerValue?.texture,
       let image = texture.imageFromTexture()?.takeRetainedValue() {
      return image
    }
    if let url = property.urlValue, let image = UIImage(contentsOfFile: url.path)?.cgImage {
      return image
    }
    return nil
  }

  private static func pngData(from image: CGImage) -> Data? {
    let limited = resized(image, maxDimension: 2048)
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
      return nil
    }
    CGImageDestinationAddImage(destination, limited, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return data as Data
  }

  private static func resized(_ image: CGImage, maxDimension: Int) -> CGImage {
    let width = image.width
    let height = image.height
    let largest = max(width, height)
    guard largest > maxDimension else { return image }
    let scale = Double(maxDimension) / Double(largest)
    let target = CGSize(width: Double(width) * scale, height: Double(height) * scale)
    let renderer = UIGraphicsImageRenderer(size: target)
    let rendered = renderer.image { _ in
      UIImage(cgImage: image).draw(in: CGRect(origin: .zero, size: target))
    }
    return rendered.cgImage ?? image
  }

  private static func gltf(
    positions: [SIMD3<Float>],
    normals: [SIMD3<Float>],
    uvs: [SIMD2<Float>],
    indices: [UInt32],
    png: Data?
  ) throws -> Data {
    var blob = Data()
    func appendFloats(_ values: [Float]) {
      for value in values {
        var copy = value
        blob.append(Data(bytes: &copy, count: 4))
      }
    }
    for position in positions { appendFloats([position.x, position.y, position.z]) }
    let positionLength = blob.count
    let normalOffset = blob.count
    for normal in normals { appendFloats([normal.x, normal.y, normal.z]) }
    let normalLength = blob.count - normalOffset
    let uvOffset = blob.count
    for uv in uvs { appendFloats([uv.x, uv.y]) }
    let uvLength = blob.count - uvOffset
    let remainder = blob.count % 4
    if remainder != 0 { blob.append(Data(count: 4 - remainder)) }
    let indexOffset = blob.count
    for index in indices {
      var copy = index
      blob.append(Data(bytes: &copy, count: 4))
    }
    let indexLength = blob.count - indexOffset

    var minP = positions[0]
    var maxP = positions[0]
    for position in positions {
      minP = SIMD3(min(minP.x, position.x), min(minP.y, position.y), min(minP.z, position.z))
      maxP = SIMD3(max(maxP.x, position.x), max(maxP.y, position.y), max(maxP.z, position.z))
    }

    var material: [String: Any] = [
      "name": "Object",
      "doubleSided": true,
      "pbrMetallicRoughness": [
        "metallicFactor": 0.0,
        "roughnessFactor": 0.65,
        "baseColorFactor": [1.0, 1.0, 1.0, 1.0],
      ],
    ]
    var root: [String: Any] = [
      "asset": ["version": "2.0", "generator": "SpatialMesh-ObjectCapture"],
      "buffers": [["byteLength": blob.count, "uri": "data:application/octet-stream;base64,\(blob.base64EncodedString())"]],
      "bufferViews": [
        ["buffer": 0, "byteOffset": 0, "byteLength": positionLength, "target": 34962],
        ["buffer": 0, "byteOffset": normalOffset, "byteLength": normalLength, "target": 34962],
        ["buffer": 0, "byteOffset": uvOffset, "byteLength": uvLength, "target": 34962],
        ["buffer": 0, "byteOffset": indexOffset, "byteLength": indexLength, "target": 34963],
      ],
      "accessors": [
        ["bufferView": 0, "componentType": 5126, "count": positions.count, "type": "VEC3", "min": [minP.x, minP.y, minP.z], "max": [maxP.x, maxP.y, maxP.z]],
        ["bufferView": 1, "componentType": 5126, "count": normals.count, "type": "VEC3"],
        ["bufferView": 2, "componentType": 5126, "count": uvs.count, "type": "VEC2"],
        ["bufferView": 3, "componentType": 5125, "count": indices.count, "type": "SCALAR"],
      ],
    ]
    var attributes: [String: Int] = ["POSITION": 0, "NORMAL": 1, "TEXCOORD_0": 2]
    if let png {
      let base64 = png.base64EncodedString()
      root["images"] = [["uri": "data:image/png;base64,\(base64)"]]
      root["textures"] = [["source": 0]]
      var pbr = material["pbrMetallicRoughness"] as? [String: Any] ?? [:]
      pbr["baseColorTexture"] = ["index": 0]
      material["pbrMetallicRoughness"] = pbr
    }
    root["materials"] = [material]
    root["meshes"] = [["name": "Object", "primitives": [["attributes": attributes, "indices": 3, "material": 0, "mode": 4]]]]
    root["nodes"] = [["mesh": 0, "name": "Object"]]
    root["scenes"] = [["nodes": [0]]]
    root["scene"] = 0
    return try JSONSerialization.data(withJSONObject: root, options: [])
  }
}

/// Reads the store and deflate entries in a USDZ zip.
private enum ZipUnpack {
  static func extract(_ archive: URL, to directory: URL) throws {
    let data = try Data(contentsOf: archive)
    guard data.count > 22, data[0] == 0x50, data[1] == 0x4b else {
      try FileManager.default.copyItem(at: archive, to: directory.appendingPathComponent(archive.lastPathComponent))
      return
    }
    for entry in centralDirectory(data) {
      let destination = directory.appendingPathComponent(entry.name)
      if entry.name.hasSuffix("/") {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        continue
      }
      try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      guard let bytes = contents(of: entry, in: data) else { continue }
      try bytes.write(to: destination)
    }
  }

  private struct Entry {
    var name: String
    var method: UInt16
    var compressedSize: Int
    var uncompressedSize: Int
    var localOffset: Int
  }

  private static func centralDirectory(_ data: Data) -> [Entry] {
    let eocd = 0x06054b50
    var cursor = data.count - 22
    var found = -1
    while cursor >= 0 {
      if readUInt32(data, cursor) == eocd {
        found = cursor
        break
      }
      cursor -= 1
    }
    guard found >= 0 else { return [] }
    let count = Int(readUInt16(data, found + 10))
    var offset = Int(readUInt32(data, found + 16))
    var entries: [Entry] = []
    entries.reserveCapacity(count)
    for _ in 0..<count {
      guard readUInt32(data, offset) == 0x02014b50 else { break }
      let method = readUInt16(data, offset + 10)
      let compressed = Int(readUInt32(data, offset + 20))
      let uncompressed = Int(readUInt32(data, offset + 24))
      let nameLength = Int(readUInt16(data, offset + 28))
      let extraLength = Int(readUInt16(data, offset + 30))
      let commentLength = Int(readUInt16(data, offset + 32))
      let local = Int(readUInt32(data, offset + 42))
      let nameData = data.subdata(in: (offset + 46)..<(offset + 46 + nameLength))
      let name = String(data: nameData, encoding: .utf8) ?? ""
      entries.append(Entry(name: name, method: method, compressedSize: compressed, uncompressedSize: uncompressed, localOffset: local))
      offset += 46 + nameLength + extraLength + commentLength
    }
    return entries
  }

  private static func contents(of entry: Entry, in data: Data) -> Data? {
    let nameLength = Int(readUInt16(data, entry.localOffset + 26))
    let extraLength = Int(readUInt16(data, entry.localOffset + 28))
    let start = entry.localOffset + 30 + nameLength + extraLength
    let end = start + entry.compressedSize
    guard start >= 0, end <= data.count else { return nil }
    let compressed = data.subdata(in: start..<end)
    if entry.method == 0 { return compressed }
    if entry.method == 8 { return inflateRaw(compressed, expected: entry.uncompressedSize) }
    return nil
  }

  private static func inflateRaw(_ source: Data, expected: Int) -> Data? {
    guard expected > 0 else { return Data() }
    var stream = z_stream()
    guard source.withUnsafeBytes({ raw -> Bool in
      stream.next_in = UnsafeMutablePointer(mutating: raw.bindMemory(to: Bytef.self).baseAddress)
      stream.avail_in = uInt(raw.count)
      return inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK
    }) else { return nil }
    defer { inflateEnd(&stream) }
    var output = Data(count: expected)
    let status: Int32 = output.withUnsafeMutableBytes { raw in
      stream.next_out = raw.bindMemory(to: Bytef.self).baseAddress
      stream.avail_out = uInt(expected)
      return inflate(&stream, Z_FINISH)
    }
    guard status == Z_STREAM_END else { return nil }
    return output
  }

  private static func readUInt16(_ data: Data, _ offset: Int) -> UInt16 {
    guard offset + 1 < data.count else { return 0 }
    return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
  }

  private static func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
    guard offset + 3 < data.count else { return 0 }
    return UInt32(data[offset])
      | (UInt32(data[offset + 1]) << 8)
      | (UInt32(data[offset + 2]) << 16)
      | (UInt32(data[offset + 3]) << 24)
  }
}
