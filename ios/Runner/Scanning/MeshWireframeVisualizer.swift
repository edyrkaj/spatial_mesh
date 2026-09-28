import ARKit
import RealityKit
import simd

/// Builds translucent wireframe-style RealityKit entities from ARMeshAnchors.
final class MeshWireframeVisualizer {
  private var entities: [UUID: ModelEntity] = [:]
  private let material: UnlitMaterial

  init() {
    var mat = UnlitMaterial()
    mat.color = .init(tint: .init(red: 0.35, green: 0.85, blue: 0.95, alpha: 0.16))
    material = mat
  }

  func attach(to arView: ARView) {
    // Anchor entities are parented under the AR session's scene via mesh anchors.
    _ = arView
  }

  func upsert(meshAnchor: ARMeshAnchor, in arView: ARView) {
    guard let mesh = makeMeshResource(from: meshAnchor.geometry) else { return }
    let entity: ModelEntity
    if let existing = entities[meshAnchor.identifier] {
      existing.model = ModelComponent(mesh: mesh, materials: [material])
      entity = existing
    } else {
      entity = ModelEntity(mesh: mesh, materials: [material])
      entities[meshAnchor.identifier] = entity
      let anchorEntity = AnchorEntity(anchor: meshAnchor)
      anchorEntity.addChild(entity)
      arView.scene.addAnchor(anchorEntity)
    }
  }

  func remove(id: UUID, from arView: ARView) {
    guard let entity = entities.removeValue(forKey: id) else { return }
    entity.anchor?.removeFromParent()
    entity.removeFromParent()
    _ = arView
  }

  func clear(from arView: ARView) {
    for id in Array(entities.keys) {
      remove(id: id, from: arView)
    }
  }

  private func makeMeshResource(from geometry: ARMeshGeometry) -> MeshResource? {
    let vertexCount = geometry.vertices.count
    let faceCount = geometry.faces.count
    guard vertexCount > 0, faceCount > 0 else { return nil }

    var positions: [SIMD3<Float>] = []
    positions.reserveCapacity(vertexCount)
    for index in 0..<vertexCount {
      let pointer = geometry.vertices.buffer.contents()
        .advanced(by: geometry.vertices.offset + geometry.vertices.stride * index)
      let floats = pointer.bindMemory(to: Float.self, capacity: 3)
      positions.append(SIMD3<Float>(floats[0], floats[1], floats[2]))
    }

    var indices: [UInt32] = []
    indices.reserveCapacity(faceCount * geometry.faces.indexCountPerPrimitive)
    for faceIndex in 0..<faceCount {
      for vertexOffset in 0..<geometry.faces.indexCountPerPrimitive {
        let byteOffset = (faceIndex * geometry.faces.indexCountPerPrimitive + vertexOffset)
          * geometry.faces.bytesPerIndex
        let pointer = geometry.faces.buffer.contents().advanced(by: byteOffset)
        let value: UInt32
        if geometry.faces.bytesPerIndex == 2 {
          value = UInt32(pointer.bindMemory(to: UInt16.self, capacity: 1).pointee)
        } else {
          value = pointer.bindMemory(to: UInt32.self, capacity: 1).pointee
        }
        indices.append(value)
      }
    }

    var descriptor = MeshDescriptor(name: "lidar_mesh")
    descriptor.positions = MeshBuffers.Positions(positions)
    descriptor.primitives = .triangles(indices)
    return try? MeshResource.generate(from: [descriptor])
  }
}
