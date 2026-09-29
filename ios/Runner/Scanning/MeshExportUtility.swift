import ARKit
import Foundation
import Metal
import MetalKit
import ModelIO
import SceneKit
import SceneKit.ModelIO
import simd

enum MeshExportFormat: String {
  case usdz
  case gltf
  case obj
}

enum MeshExportError: LocalizedError {
  case emptyMesh
  case unsupportedFormat(String)
  case writeFailed(String)
  case metalUnavailable

  var errorDescription: String? {
    switch self {
    case .emptyMesh:
      return "No mesh geometry captured yet. Scan surfaces before tapping Done."
    case .unsupportedFormat(let format):
      return "Export format '\(format)' is not supported."
    case .writeFailed(let detail):
      return "Failed to write mesh file: \(detail)"
    case .metalUnavailable:
      return "Metal is required to allocate mesh buffers for export."
    }
  }
}

/// Extracts a dense colored surface from LiDAR depth, and falls back to the
/// coarse ARKit mesh when depth frames are missing.
///
/// Format notes:
/// - `.usdz` — written via SceneKit `SCNScene.write(to:)`. ModelIO's
///   `MDLAsset.export(to:)` rejects `.usdz` (`canExportFileExtension` is false)
///   with `MDLErrorDomain` error 0.
/// - `.obj`  — written via ModelIO (reliable interchange fallback).
/// - `.gltf` — custom glTF 2.0. The surface is rebuilt from the LiDAR depth
///   image and painted with the camera, instead of the coarse scene mesh.
final class MeshExportUtility {
  struct ProcessedMesh {
    var positions: [SIMD3<Float>]
    var normals: [SIMD3<Float>]
    var indices: [UInt32]
    /// Camera colors in 0...1. Empty when no photo frames were captured.
    var colors: [SIMD3<Float>]
  }

  private let device: MTLDevice?

  init(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
    self.device = device
  }

  func export(
    meshAnchors: [ARMeshAnchor],
    colorFrames: [ScanColorFrame] = [],
    format: MeshExportFormat,
    to directory: URL,
    basename: String
  ) throws -> URL {
    let processed: ProcessedMesh
    if !meshAnchors.isEmpty {
      // The live mesh is every surface LiDAR has reconstructed, not a short patch of recent frames.
      var full = try process(meshAnchors: meshAnchors)
      full.colors = colors(for: full, from: colorFrames)
      processed = full
    } else if var dense = depthSurface(from: colorFrames) {
      dense = removeDegenerateTriangles(dense)
      guard !dense.indices.isEmpty else { throw MeshExportError.emptyMesh }
      processed = dense
    } else {
      throw MeshExportError.emptyMesh
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    switch format {
    case .usdz:
      return try writeUSDZ(processed, to: directory.appendingPathComponent("\(basename).usdz"))
    case .obj:
      return try writeOBJ(processed, to: directory.appendingPathComponent("\(basename).obj"))
    case .gltf:
      return try writeGLTF(processed, to: directory.appendingPathComponent("\(basename).gltf"))
    }
  }

  func process(meshAnchors: [ARMeshAnchor]) throws -> ProcessedMesh {
    guard !meshAnchors.isEmpty else { throw MeshExportError.emptyMesh }

    var positions: [SIMD3<Float>] = []
    var normals: [SIMD3<Float>] = []
    var indices: [UInt32] = []

    for anchor in meshAnchors {
      let geometry = anchor.geometry
      let transform = anchor.transform
      let baseIndex = UInt32(positions.count)
      let vertexCount = geometry.vertices.count
      guard vertexCount > 0, geometry.faces.count > 0 else { continue }

      for i in 0..<vertexCount {
        let local = vertex(at: i, of: geometry.vertices)
        let world = transform * SIMD4<Float>(local.x, local.y, local.z, 1)
        positions.append(SIMD3<Float>(world.x, world.y, world.z))

        if geometry.normals.count > i {
          let n = vertex(at: i, of: geometry.normals)
          let worldN = (transform * SIMD4<Float>(n.x, n.y, n.z, 0)).xyz
          normals.append(simd_normalize(worldN == .zero ? SIMD3<Float>(0, 1, 0) : worldN))
        } else {
          normals.append(SIMD3<Float>(0, 1, 0))
        }
      }

      for face in 0..<geometry.faces.count {
        let corners = faceIndices(at: face, of: geometry.faces)
        guard corners.count == 3 else { continue }
        let a = corners[0] + baseIndex
        let b = corners[1] + baseIndex
        let c = corners[2] + baseIndex
        if a == b || b == c || a == c { continue }
        indices.append(contentsOf: [a, b, c])
      }
    }

    guard !indices.isEmpty, !positions.isEmpty else {
      throw MeshExportError.emptyMesh
    }

    var mesh = ProcessedMesh(positions: positions, normals: normals, indices: indices, colors: [])
    mesh = weldVertices(mesh, epsilon: 0.0005)
    mesh = removeDegenerateTriangles(mesh)
    guard !mesh.indices.isEmpty else { throw MeshExportError.emptyMesh }
    return mesh
  }

  // MARK: - Writers

  private func writeUSDZ(_ mesh: ProcessedMesh, to url: URL) throws -> URL {
    let asset = try buildAsset(from: mesh)
    if FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }
    let scene = SCNScene(mdlAsset: asset)
    let wrote = scene.write(to: url, options: nil, delegate: nil, progressHandler: nil)
    guard wrote, FileManager.default.fileExists(atPath: url.path) else {
      throw MeshExportError.writeFailed("SceneKit could not write the USDZ file.")
    }
    return url
  }

  private func writeOBJ(_ mesh: ProcessedMesh, to url: URL) throws -> URL {
    let asset = try buildAsset(from: mesh)
    if FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }
    do {
      try asset.export(to: url)
    } catch {
      throw MeshExportError.writeFailed(error.localizedDescription)
    }
    return url
  }

  /// glTF 2.0 JSON with one embedded little-endian buffer.
  /// Same triangles as the live overlay: unlit cyan, double-sided, no smoothing.
  private func writeGLTF(_ mesh: ProcessedMesh, to url: URL) throws -> URL {
    let data = try Self.gltfData(for: mesh)
    if FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }
    do {
      try data.write(to: url, options: .atomic)
    } catch {
      throw MeshExportError.writeFailed(error.localizedDescription)
    }
    return url
  }

  static func gltfData(for mesh: ProcessedMesh) throws -> Data {
    let hasColors = mesh.colors.count == mesh.positions.count && !mesh.colors.isEmpty
    var blob = Data()
    appendVector3(mesh.positions, to: &blob)
    let positionByteLength = blob.count
    let normalOffset = blob.count
    let normals = mesh.normals.count == mesh.positions.count
      ? mesh.normals.map(finiteNormal)
      : Array(repeating: SIMD3<Float>(0, 1, 0), count: mesh.positions.count)
    appendVector3(normals, to: &blob)
    let normalByteLength = blob.count - normalOffset

    var colorOffset = 0
    var colorByteLength = 0
    if hasColors {
      pad(&blob, to: 4)
      colorOffset = blob.count
      for color in mesh.colors {
        var red = UInt8(min(255, max(0, Int((color.x * 255).rounded()))))
        var green = UInt8(min(255, max(0, Int((color.y * 255).rounded()))))
        var blue = UInt8(min(255, max(0, Int((color.z * 255).rounded()))))
        blob.append(Data(bytes: &red, count: 1))
        blob.append(Data(bytes: &green, count: 1))
        blob.append(Data(bytes: &blue, count: 1))
      }
      colorByteLength = blob.count - colorOffset
      pad(&blob, to: 4)
    }

    let indicesOffset = blob.count
    for index in mesh.indices {
      var value = index
      blob.append(Data(bytes: &value, count: MemoryLayout<UInt32>.size))
    }
    let indicesByteLength = blob.count - indicesOffset

    var minP = mesh.positions[0]
    var maxP = mesh.positions[0]
    for p in mesh.positions {
      minP = simd_min(minP, p)
      maxP = simd_max(maxP, p)
    }

    var bufferViews: [[String: Any]] = [
      ["buffer": 0, "byteOffset": 0, "byteLength": positionByteLength, "target": 34962],
      ["buffer": 0, "byteOffset": normalOffset, "byteLength": normalByteLength, "target": 34962],
    ]
    var accessors: [[String: Any]] = [
      [
        "bufferView": 0,
        "componentType": 5126,
        "count": mesh.positions.count,
        "type": "VEC3",
        "min": [minP.x, minP.y, minP.z],
        "max": [maxP.x, maxP.y, maxP.z],
      ],
      [
        "bufferView": 1,
        "componentType": 5126,
        "count": normals.count,
        "type": "VEC3",
      ],
    ]
    var attributes: [String: Int] = ["POSITION": 0, "NORMAL": 1]
    if hasColors {
      bufferViews.append([
        "buffer": 0,
        "byteOffset": colorOffset,
        "byteLength": colorByteLength,
        "target": 34962,
      ])
      accessors.append([
        "bufferView": 2,
        "componentType": 5121,
        "normalized": true,
        "count": mesh.colors.count,
        "type": "VEC3",
      ])
      attributes["COLOR_0"] = 2
    }
    let indexView = bufferViews.count
    bufferViews.append([
      "buffer": 0,
      "byteOffset": indicesOffset,
      "byteLength": indicesByteLength,
      "target": 34963,
    ])
    accessors.append([
      "bufferView": indexView,
      "componentType": 5125,
      "count": mesh.indices.count,
      "type": "SCALAR",
    ])

    let baseColor: [Double] = hasColors ? [1, 1, 1, 1] : [0.35, 0.85, 0.95, 1]
    let gltf: [String: Any] = [
      "asset": ["version": "2.0", "generator": "SpatialMesh"],
      "extensionsUsed": ["KHR_materials_unlit"],
      "buffers": [
        [
          "byteLength": blob.count,
          "uri": "data:application/octet-stream;base64,\(blob.base64EncodedString())",
        ],
      ],
      "bufferViews": bufferViews,
      "accessors": accessors,
      "materials": [
        [
          "name": "LiDAR",
          "doubleSided": true,
          "alphaMode": "OPAQUE",
          "pbrMetallicRoughness": [
            "baseColorFactor": baseColor,
            "metallicFactor": 0.0,
            "roughnessFactor": 1.0,
          ],
          "extensions": ["KHR_materials_unlit": [:]],
        ],
      ],
      "meshes": [
        [
          "name": "LiDARMesh",
          "primitives": [
            [
              "attributes": attributes,
              "indices": indexView,
              "material": 0,
              "mode": 4,
            ],
          ],
        ],
      ],
      "nodes": [["mesh": 0, "name": "LiDARMesh"]],
      "scenes": [["nodes": [0]]],
      "scene": 0,
    ]

    return try JSONSerialization.data(withJSONObject: gltf, options: [.prettyPrinted])
  }

  private static func pad(_ blob: inout Data, to alignment: Int) {
    let remainder = blob.count % alignment
    if remainder != 0 {
      blob.append(Data(count: alignment - remainder))
    }
  }

  private static func appendVector3(_ values: [SIMD3<Float>], to blob: inout Data) {
    for value in values {
      var x = value.x
      var y = value.y
      var z = value.z
      blob.append(Data(bytes: &x, count: 4))
      blob.append(Data(bytes: &y, count: 4))
      blob.append(Data(bytes: &z, count: 4))
    }
  }

  private static func finiteNormal(_ normal: SIMD3<Float>) -> SIMD3<Float> {
    guard normal.x.isFinite, normal.y.isFinite, normal.z.isFinite else {
      return SIMD3<Float>(0, 1, 0)
    }
    let length = simd_length(normal)
    guard length > 1e-8 else { return SIMD3<Float>(0, 1, 0) }
    return normal / length
  }

  /// Rebuilds the object from the LiDAR depth images. This is much finer than the
  /// scene-reconstruction mesh, which is why that mesh looks like large shapes.
  private func depthSurface(from frames: [ScanColorFrame]) -> ProcessedMesh? {
    let surfaces = frames.filter { $0.depth.count == $0.width * $0.height && $0.width > 1 }
    guard !surfaces.isEmpty else { return nil }

    let voxel: Float = 0.006
    let maxEdge: Float = 0.028
    var positions: [SIMD3<Float>] = []
    var colors: [SIMD3<Float>] = []
    var indices: [UInt32] = []
    var occupied: [SIMD3<Int32>: (index: UInt32, distance: Float)] = [:]

    for frame in surfaces {
      let camera = SIMD3<Float>(
        frame.cameraToWorld.columns.3.x,
        frame.cameraToWorld.columns.3.y,
        frame.cameraToWorld.columns.3.z
      )
      var local = [Int32](repeating: -1, count: frame.width * frame.height)
      for row in 0..<frame.height {
        for column in 0..<frame.width {
          let sample = row * frame.width + column
          let meters = frame.depth[sample]
          guard meters > 0.12 else { continue }
          guard let world = Self.unproject(column: column, row: row, depth: meters, frame: frame) else { continue }
          let key = SIMD3<Int32>(
            Int32((world.x / voxel).rounded()),
            Int32((world.y / voxel).rounded()),
            Int32((world.z / voxel).rounded())
          )
          let distance = simd_distance(camera, world)
          let color = Self.color(at: sample, frame: frame)
          if let existing = occupied[key] {
            local[sample] = Int32(existing.index)
            if distance + 0.008 < existing.distance {
              positions[Int(existing.index)] = world
              colors[Int(existing.index)] = color
              occupied[key] = (existing.index, distance)
            }
            continue
          }
          let index = UInt32(positions.count)
          positions.append(world)
          colors.append(color)
          occupied[key] = (index, distance)
          local[sample] = Int32(index)
        }
      }

      for row in 0..<(frame.height - 1) {
        for column in 0..<(frame.width - 1) {
          let i00 = local[row * frame.width + column]
          let i10 = local[row * frame.width + column + 1]
          let i01 = local[(row + 1) * frame.width + column]
          let i11 = local[(row + 1) * frame.width + column + 1]
          Self.addTriangle(i00, i10, i11, positions: positions, indices: &indices, maxEdge: maxEdge)
          Self.addTriangle(i00, i11, i01, positions: positions, indices: &indices, maxEdge: maxEdge)
        }
      }
    }

    guard !positions.isEmpty, !indices.isEmpty else { return nil }
    return ProcessedMesh(
      positions: positions,
      normals: Self.normals(for: positions, indices: indices),
      indices: indices,
      colors: colors
    )
  }

  private static func unproject(column: Int, row: Int, depth: Float, frame: ScanColorFrame) -> SIMD3<Float>? {
    let fx = frame.intrinsics.columns.0.x
    let fy = frame.intrinsics.columns.1.y
    let cx = frame.intrinsics.columns.2.x
    let cy = frame.intrinsics.columns.2.y
    guard fx > 1, fy > 1 else { return nil }
    let x = (Float(column) + 0.5 - cx) * depth / fx
    let y = -(Float(row) + 0.5 - cy) * depth / fy
    let world = frame.cameraToWorld * SIMD4<Float>(x, y, -depth, 1)
    guard world.x.isFinite, world.y.isFinite, world.z.isFinite else { return nil }
    return SIMD3(world.x, world.y, world.z)
  }

  private static func color(at sample: Int, frame: ScanColorFrame) -> SIMD3<Float> {
    let byte = sample * 4
    guard byte + 2 < frame.rgba.count else { return SIMD3(0.45, 0.45, 0.45) }
    return SIMD3(
      Float(frame.rgba[byte]) / 255,
      Float(frame.rgba[byte + 1]) / 255,
      Float(frame.rgba[byte + 2]) / 255
    )
  }

  private static func addTriangle(
    _ a: Int32,
    _ b: Int32,
    _ c: Int32,
    positions: [SIMD3<Float>],
    indices: inout [UInt32],
    maxEdge: Float
  ) {
    guard a >= 0, b >= 0, c >= 0, a != b, b != c, a != c else { return }
    let pa = positions[Int(a)]
    let pb = positions[Int(b)]
    let pc = positions[Int(c)]
    guard simd_distance(pa, pb) < maxEdge,
          simd_distance(pb, pc) < maxEdge,
          simd_distance(pa, pc) < maxEdge else { return }
    indices.append(UInt32(a))
    indices.append(UInt32(b))
    indices.append(UInt32(c))
  }

  private static func normals(for positions: [SIMD3<Float>], indices: [UInt32]) -> [SIMD3<Float>] {
    var normals = [SIMD3<Float>](repeating: .zero, count: positions.count)
    var offset = 0
    while offset + 2 < indices.count {
      let a = Int(indices[offset])
      let b = Int(indices[offset + 1])
      let c = Int(indices[offset + 2])
      let face = simd_cross(positions[b] - positions[a], positions[c] - positions[a])
      normals[a] += face
      normals[b] += face
      normals[c] += face
      offset += 3
    }
    return normals.map { Self.finiteNormal($0) }
  }

  /// Paints each vertex from the camera frame that saw that surface most directly.
  private func colors(for mesh: ProcessedMesh, from frames: [ScanColorFrame]) -> [SIMD3<Float>] {
    guard !frames.isEmpty, !mesh.positions.isEmpty else { return [] }
    var painted = Array(repeating: SIMD3<Float>(0.45, 0.45, 0.45), count: mesh.positions.count)
    var hitCount = 0
    for index in mesh.positions.indices {
      let normal = index < mesh.normals.count
        ? Self.finiteNormal(mesh.normals[index])
        : SIMD3<Float>(0, 1, 0)
      var bestScore: Float = 0
      var bestColor: SIMD3<Float>?
      for frame in frames {
        guard let sample = Self.sample(mesh.positions[index], normal: normal, frame: frame) else { continue }
        if sample.score > bestScore {
          bestScore = sample.score
          bestColor = sample.color
        }
      }
      if let bestColor {
        painted[index] = bestColor
        hitCount += 1
      }
    }
    return hitCount > 0 ? painted : []
  }

  private static func sample(
    _ world: SIMD3<Float>,
    normal: SIMD3<Float>,
    frame: ScanColorFrame
  ) -> (color: SIMD3<Float>, score: Float)? {
    let cameraPosition = SIMD3<Float>(
      frame.cameraToWorld.columns.3.x,
      frame.cameraToWorld.columns.3.y,
      frame.cameraToWorld.columns.3.z
    )
    let towardCamera = cameraPosition - world
    let distance = simd_length(towardCamera)
    guard distance > 0.05, distance < 5 else { return nil }
    let facing = simd_dot(normal, towardCamera / distance)
    guard facing > 0.2 else { return nil }

    let cameraPoint = simd_inverse(frame.cameraToWorld) * SIMD4<Float>(world.x, world.y, world.z, 1)
    let depth = -cameraPoint.z
    guard depth > 0.05 else { return nil }

    let pixelX = frame.intrinsics.columns.0.x * (cameraPoint.x / depth) + frame.intrinsics.columns.2.x
    let pixelY = frame.intrinsics.columns.1.y * (cameraPoint.y / depth) + frame.intrinsics.columns.2.y
    let x = Int(pixelX)
    let y = Int(pixelY)
    guard x >= 0, y >= 0, x < frame.width, y < frame.height else { return nil }
    let offset = (y * frame.width + x) * 4
    guard offset + 2 < frame.rgba.count else { return nil }

    let color = SIMD3<Float>(
      Float(frame.rgba[offset]) / 255,
      Float(frame.rgba[offset + 1]) / 255,
      Float(frame.rgba[offset + 2]) / 255
    )
    return (color, facing / distance)
  }

  private func buildAsset(from mesh: ProcessedMesh) throws -> MDLAsset {
    guard let device else { throw MeshExportError.metalUnavailable }
    let allocator = MTKMeshBufferAllocator(device: device)

    let vertexStride = 24
    var positionBytes = Data(count: mesh.positions.count * vertexStride)
    positionBytes.withUnsafeMutableBytes { raw in
      let dest = raw.bindMemory(to: Float.self)
      for (i, p) in mesh.positions.enumerated() {
        let normal = i < mesh.normals.count ? Self.finiteNormal(mesh.normals[i]) : SIMD3<Float>(0, 1, 0)
        let base = i * 6
        dest[base] = p.x
        dest[base + 1] = p.y
        dest[base + 2] = p.z
        dest[base + 3] = normal.x
        dest[base + 4] = normal.y
        dest[base + 5] = normal.z
      }
    }

    var indexBytes = Data(count: mesh.indices.count * MemoryLayout<UInt32>.stride)
    indexBytes.withUnsafeMutableBytes { raw in
      let dest = raw.bindMemory(to: UInt32.self)
      for (i, value) in mesh.indices.enumerated() {
        dest[i] = value
      }
    }

    let vertexBuffer = allocator.newBuffer(with: positionBytes, type: .vertex)
    let indexBuffer = allocator.newBuffer(with: indexBytes, type: .index)

    let vertexDescriptor = MDLVertexDescriptor()
    vertexDescriptor.attributes[0] = MDLVertexAttribute(
      name: MDLVertexAttributePosition,
      format: .float3,
      offset: 0,
      bufferIndex: 0
    )
    vertexDescriptor.attributes[1] = MDLVertexAttribute(
      name: MDLVertexAttributeNormal,
      format: .float3,
      offset: 12,
      bufferIndex: 0
    )
    vertexDescriptor.layouts[0] = MDLVertexBufferLayout(stride: vertexStride)

    let submesh = MDLSubmesh(
      indexBuffer: indexBuffer,
      indexCount: mesh.indices.count,
      indexType: .uInt32,
      geometryType: .triangles,
      material: nil
    )

    let mdlMesh = MDLMesh(
      vertexBuffer: vertexBuffer,
      vertexCount: mesh.positions.count,
      descriptor: vertexDescriptor,
      submeshes: [submesh]
    )
    let asset = MDLAsset(bufferAllocator: allocator)
    asset.add(mdlMesh)
    return asset
  }

  // MARK: - Geometry helpers

  private func vertex(at index: Int, of source: ARGeometrySource) -> SIMD3<Float> {
    let pointer = source.buffer.contents().advanced(by: source.offset + source.stride * index)
    let floats = pointer.bindMemory(to: Float.self, capacity: 3)
    return SIMD3<Float>(floats[0], floats[1], floats[2])
  }

  private func faceIndices(at faceIndex: Int, of faces: ARGeometryElement) -> [UInt32] {
    var result: [UInt32] = []
    result.reserveCapacity(faces.indexCountPerPrimitive)
    for vertexOffset in 0..<faces.indexCountPerPrimitive {
      let byteOffset = (faceIndex * faces.indexCountPerPrimitive + vertexOffset) * faces.bytesPerIndex
      let pointer = faces.buffer.contents().advanced(by: byteOffset)
      if faces.bytesPerIndex == 2 {
        result.append(UInt32(pointer.bindMemory(to: UInt16.self, capacity: 1).pointee))
      } else {
        result.append(pointer.bindMemory(to: UInt32.self, capacity: 1).pointee)
      }
    }
    return result
  }

  private func weldVertices(_ mesh: ProcessedMesh, epsilon: Float) -> ProcessedMesh {
    var map: [SIMD3<Int32>: UInt32] = [:]
    var newPositions: [SIMD3<Float>] = []
    var newNormals: [SIMD3<Float>] = []
    var remap: [UInt32] = Array(repeating: 0, count: mesh.positions.count)
    let scale = 1.0 / epsilon

    for (i, position) in mesh.positions.enumerated() {
      let key = SIMD3<Int32>(
        Int32((position.x * scale).rounded()),
        Int32((position.y * scale).rounded()),
        Int32((position.z * scale).rounded())
      )
      if let existing = map[key] {
        remap[i] = existing
        newNormals[Int(existing)] = simd_normalize(newNormals[Int(existing)] + mesh.normals[i])
      } else {
        let newIndex = UInt32(newPositions.count)
        map[key] = newIndex
        remap[i] = newIndex
        newPositions.append(position)
        newNormals.append(mesh.normals[i])
      }
    }

    let newIndices = mesh.indices.map { remap[Int($0)] }
    return ProcessedMesh(positions: newPositions, normals: newNormals, indices: newIndices, colors: [])
  }

  private func removeDegenerateTriangles(_ mesh: ProcessedMesh) -> ProcessedMesh {
    var filtered: [UInt32] = []
    filtered.reserveCapacity(mesh.indices.count)
    var i = 0
    while i + 2 < mesh.indices.count {
      let a = mesh.indices[i]
      let b = mesh.indices[i + 1]
      let c = mesh.indices[i + 2]
      if a != b && b != c && a != c {
        let pa = mesh.positions[Int(a)]
        let pb = mesh.positions[Int(b)]
        let pc = mesh.positions[Int(c)]
        let area = simd_length(simd_cross(pb - pa, pc - pa))
        if area > 1e-10 {
          filtered.append(contentsOf: [a, b, c])
        }
      }
      i += 3
    }
    return ProcessedMesh(positions: mesh.positions, normals: mesh.normals, indices: filtered, colors: mesh.colors)
  }
}

private extension SIMD4 where Scalar == Float {
  var xyz: SIMD3<Float> { SIMD3<Float>(x, y, z) }
}
