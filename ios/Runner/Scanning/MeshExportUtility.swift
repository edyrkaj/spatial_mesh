import ARKit
import Foundation
import Metal
import MetalKit
import ModelIO
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

/// Extracts ARMeshGeometry, applies basic clean/decimate, writes local mesh files.
///
/// Format notes:
/// - `.usdz` — written via ModelIO `MDLAsset.export(to:)` (supported on iOS).
/// - `.obj`  — written via ModelIO (reliable interchange fallback).
/// - `.gltf` — ModelIO does **not** export glTF; we ship a minimal custom glTF 2.0
///   writer (positions + triangle indices, no materials/textures).
final class MeshExportUtility {
  struct ProcessedMesh {
    var positions: [SIMD3<Float>]
    var normals: [SIMD3<Float>]
    var indices: [UInt32]
  }

  private let device: MTLDevice?

  init(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
    self.device = device
  }

  func export(
    meshAnchors: [ARMeshAnchor],
    format: MeshExportFormat,
    to directory: URL,
    basename: String,
    targetFaceBudget: Int = 80_000
  ) throws -> URL {
    let processed = try process(meshAnchors: meshAnchors, targetFaceBudget: targetFaceBudget)
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

  func process(meshAnchors: [ARMeshAnchor], targetFaceBudget: Int) throws -> ProcessedMesh {
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

    var mesh = ProcessedMesh(positions: positions, normals: normals, indices: indices)
    mesh = weldVertices(mesh, epsilon: 0.0005)
    mesh = removeDegenerateTriangles(mesh)
    mesh = decimate(mesh, targetFaceBudget: targetFaceBudget)
    guard !mesh.indices.isEmpty else { throw MeshExportError.emptyMesh }
    return mesh
  }

  // MARK: - Writers

  private func writeUSDZ(_ mesh: ProcessedMesh, to url: URL) throws -> URL {
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

  /// Minimal glTF 2.0 (JSON + embedded base64 buffer). Not via ModelIO.
  private func writeGLTF(_ mesh: ProcessedMesh, to url: URL) throws -> URL {
    var blob = Data()
    for p in mesh.positions {
      var x = p.x, y = p.y, z = p.z
      blob.append(Data(bytes: &x, count: 4))
      blob.append(Data(bytes: &y, count: 4))
      blob.append(Data(bytes: &z, count: 4))
    }
    let positionByteLength = blob.count
    let indicesOffset = blob.count
    for index in mesh.indices {
      var value = index
      blob.append(Data(bytes: &value, count: 4))
    }
    let indicesByteLength = blob.count - indicesOffset

    var minP = mesh.positions[0]
    var maxP = mesh.positions[0]
    for p in mesh.positions {
      minP = simd_min(minP, p)
      maxP = simd_max(maxP, p)
    }

    let gltf: [String: Any] = [
      "asset": ["version": "2.0", "generator": "SpatialMesh-Phase1"],
      "buffers": [
        ["byteLength": blob.count, "uri": "data:application/octet-stream;base64,\(blob.base64EncodedString())"],
      ],
      "bufferViews": [
        ["buffer": 0, "byteOffset": 0, "byteLength": positionByteLength, "target": 34962],
        ["buffer": 0, "byteOffset": indicesOffset, "byteLength": indicesByteLength, "target": 34963],
      ],
      "accessors": [
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
          "componentType": 5125,
          "count": mesh.indices.count,
          "type": "SCALAR",
        ],
      ],
      "meshes": [
        [
          "primitives": [
            ["attributes": ["POSITION": 0], "indices": 1, "mode": 4],
          ],
        ],
      ],
      "nodes": [["mesh": 0, "name": "LiDARMesh"]],
      "scenes": [["nodes": [0]]],
      "scene": 0,
    ]

    let data = try JSONSerialization.data(withJSONObject: gltf, options: [.prettyPrinted])
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

  private func buildAsset(from mesh: ProcessedMesh) throws -> MDLAsset {
    guard let device else { throw MeshExportError.metalUnavailable }
    let allocator = MTKMeshBufferAllocator(device: device)

    var positionBytes = Data(count: mesh.positions.count * MemoryLayout<SIMD3<Float>>.stride)
    positionBytes.withUnsafeMutableBytes { raw in
      let dest = raw.bindMemory(to: SIMD3<Float>.self)
      for (i, p) in mesh.positions.enumerated() {
        dest[i] = p
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
    vertexDescriptor.layouts[0] = MDLVertexBufferLayout(stride: MemoryLayout<SIMD3<Float>>.stride)

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
    mdlMesh.addNormals(withAttributeNamed: MDLVertexAttributeNormal, creaseThreshold: 0.5)

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
    return ProcessedMesh(positions: newPositions, normals: newNormals, indices: newIndices)
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
    return ProcessedMesh(positions: mesh.positions, normals: mesh.normals, indices: filtered)
  }

  /// Simple stride-based face decimation for Phase 1 (keeps topology roughly uniform).
  private func decimate(_ mesh: ProcessedMesh, targetFaceBudget: Int) -> ProcessedMesh {
    let faceCount = mesh.indices.count / 3
    guard faceCount > targetFaceBudget, targetFaceBudget > 0 else { return mesh }
    let stride = max(1, faceCount / targetFaceBudget)
    var filtered: [UInt32] = []
    filtered.reserveCapacity(targetFaceBudget * 3)
    var face = 0
    while face < faceCount {
      if face % stride == 0 {
        let base = face * 3
        filtered.append(contentsOf: mesh.indices[base..<(base + 3)])
      }
      face += 1
    }
    return ProcessedMesh(positions: mesh.positions, normals: mesh.normals, indices: filtered)
  }
}

private extension SIMD4 where Scalar == Float {
  var xyz: SIMD3<Float> { SIMD3<Float>(x, y, z) }
}
