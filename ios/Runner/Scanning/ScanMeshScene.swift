import SceneKit
import UIKit

/// Builds a SceneKit scene from a saved scan (glTF written by this app, OBJ, or USDZ).
enum ScanMeshScene {
  static func makeScene(from url: URL) throws -> SCNScene {
    switch url.pathExtension.lowercased() {
    case "gltf":
      return try gltfScene(from: url)
    case "obj", "usdz":
      return try importedScene(from: url)
    case let ext where ext.isEmpty:
      throw ScanMeshLoadError.unsupported("Can't view this file type in the app.")
    default:
      throw ScanMeshLoadError.unsupported("Can't view .\(url.pathExtension) files in the app.")
    }
  }

  static func frame(_ scene: SCNScene, in view: SCNView) {
    guard let bounds = worldBounds(of: scene.rootNode) else { return }
    let center = SCNVector3(
      (bounds.min.x + bounds.max.x) / 2,
      (bounds.min.y + bounds.max.y) / 2,
      (bounds.min.z + bounds.max.z) / 2
    )
    let extent = max(
      bounds.max.x - bounds.min.x,
      max(bounds.max.y - bounds.min.y, bounds.max.z - bounds.min.z)
    )
    let half = max(Double(extent) / 2, 0.05)
    let fov = 45.0 * Double.pi / 180
    let distance = Float((half / tan(fov / 2)) * 1.25)
    let camera = SCNCamera()
    camera.fieldOfView = 45
    camera.zNear = 0.001
    camera.zFar = Double(max(distance * 40, 50))
    camera.automaticallyAdjustsZRange = true
    let cameraNode = SCNNode()
    cameraNode.camera = camera
    cameraNode.position = SCNVector3(center.x, center.y, center.z + distance)
    scene.rootNode.addChildNode(cameraNode)
    cameraNode.look(at: center)
    view.pointOfView = cameraNode
    view.defaultCameraController.target = center
  }

  private static func importedScene(from url: URL) throws -> SCNScene {
    let scene: SCNScene
    do {
      scene = try SCNScene(url: url, options: nil)
    } catch {
      throw ScanMeshLoadError.invalid("This scan file could not be opened.")
    }
    if worldBounds(of: scene.rootNode) == nil {
      throw ScanMeshLoadError.invalid("This scan has no mesh to show.")
    }
    return scene
  }

  private static func gltfScene(from url: URL) throws -> SCNScene {
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch {
      throw ScanMeshLoadError.invalid("This scan file could not be opened.")
    }
    let jsonObject: Any
    do {
      jsonObject = try JSONSerialization.jsonObject(with: data)
    } catch {
      throw ScanMeshLoadError.invalid("This scan file could not be read.")
    }
    guard let root = dictionary(jsonObject) else {
      throw ScanMeshLoadError.invalid("This scan file could not be read.")
    }
    let geometry = try gltfGeometry(root)
    let node = SCNNode(geometry: geometry)
    let scene = SCNScene()
    scene.rootNode.addChildNode(node)
    return scene
  }

  private static func gltfGeometry(_ root: [String: Any]) throws -> SCNGeometry {
    let buffers = dictionaries(root["buffers"])
    guard let blob = try decodeFirstBuffer(buffers) else {
      throw ScanMeshLoadError.invalid("This scan file is missing its mesh data.")
    }
    let bufferViews = dictionaries(root["bufferViews"])
    let accessors = dictionaries(root["accessors"])
    guard
      let mesh = dictionaries(root["meshes"]).first,
      let primitive = dictionaries(mesh["primitives"]).first
    else {
      throw ScanMeshLoadError.invalid("This scan has no mesh to show.")
    }
    if let mode = intValue(primitive["mode"]), mode != 4 {
      throw ScanMeshLoadError.invalid("This scan uses a mesh type the viewer can't show.")
    }
    let attributes = dictionary(primitive["attributes"]) ?? [:]
    guard let positionIndex = intValue(attributes["POSITION"]) else {
      throw ScanMeshLoadError.invalid("This scan has no mesh to show.")
    }
    let positions = try packed(
      accessor: accessor(accessors, positionIndex),
      views: bufferViews,
      in: blob,
      componentType: 5126,
      type: "VEC3",
      components: 3,
      bytes: 4
    )
    guard !positions.isEmpty else {
      throw ScanMeshLoadError.invalid("This scan has no mesh to show.")
    }

    var sources = [
      SCNGeometrySource(
        data: positions,
        semantic: .vertex,
        vectorCount: positions.count / 12,
        usesFloatComponents: true,
        componentsPerVector: 3,
        bytesPerComponent: 4,
        dataOffset: 0,
        dataStride: 12
      ),
    ]

    var hasColors = false
    if let normalIndex = intValue(attributes["NORMAL"]) {
      let normals = try packed(
        accessor: accessor(accessors, normalIndex),
        views: bufferViews,
        in: blob,
        componentType: 5126,
        type: "VEC3",
        components: 3,
        bytes: 4
      )
      sources.append(
        SCNGeometrySource(
          data: normals,
          semantic: .normal,
          vectorCount: normals.count / 12,
          usesFloatComponents: true,
          componentsPerVector: 3,
          bytesPerComponent: 4,
          dataOffset: 0,
          dataStride: 12
        )
      )
    }
    if let colorIndex = intValue(attributes["COLOR_0"]) {
      let colors = try packed(
        accessor: accessor(accessors, colorIndex),
        views: bufferViews,
        in: blob,
        componentType: 5121,
        type: "VEC3",
        components: 3,
        bytes: 1
      )
      let colorFloats = rgbaFloats(fromRGBBytes: colors)
      hasColors = !colorFloats.isEmpty
      if hasColors {
        sources.append(
          SCNGeometrySource(
            data: colorFloats,
            semantic: .color,
            vectorCount: colorFloats.count / 12,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: 4,
            dataOffset: 0,
            dataStride: 12
          )
        )
      }
    }

    guard let indicesIndex = intValue(primitive["indices"]) else {
      throw ScanMeshLoadError.invalid("This scan has no mesh to show.")
    }
    let indices = try packed(
      accessor: accessor(accessors, indicesIndex),
      views: bufferViews,
      in: blob,
      componentType: 5125,
      type: "SCALAR",
      components: 1,
      bytes: 4
    )
    guard indices.count >= 12, indices.count.isMultiple(of: 12) else {
      throw ScanMeshLoadError.invalid("This scan has no mesh to show.")
    }
    let element = SCNGeometryElement(
      data: indices,
      primitiveType: .triangles,
      primitiveCount: indices.count / 12,
      bytesPerIndex: 4
    )
    let geometry = SCNGeometry(sources: sources, elements: [element])
    let material = SCNMaterial()
    material.lightingModel = .constant
    material.isDoubleSided = true
    material.diffuse.contents = hasColors
      ? UIColor.white
      : UIColor(red: 0.35, green: 0.85, blue: 0.95, alpha: 1)
    geometry.materials = [material]
    return geometry
  }

  private static func decodeFirstBuffer(_ buffers: [[String: Any]]) throws -> Data? {
    guard let buffer = buffers.first, let uri = buffer["uri"] as? String else { return nil }
    guard let marker = uri.range(of: "base64,") else { return nil }
    let payload = String(uri[marker.upperBound...])
    return Data(base64Encoded: payload, options: .ignoreUnknownCharacters)
  }

  private static func accessor(_ accessors: [[String: Any]], _ index: Int) throws -> [String: Any] {
    guard accessors.indices.contains(index) else {
      throw ScanMeshLoadError.invalid("This scan file could not be read.")
    }
    return accessors[index]
  }

  /// Copies a tightly packed accessor out of the embedded glTF buffer.
  private static func packed(
    accessor: [String: Any],
    views: [[String: Any]],
    in blob: Data,
    componentType: Int,
    type: String,
    components: Int,
    bytes: Int
  ) throws -> Data {
    guard
      intValue(accessor["componentType"]) == componentType,
      (accessor["type"] as? String) == type
    else {
      throw ScanMeshLoadError.invalid("This scan file could not be read.")
    }
    guard let viewIndex = intValue(accessor["bufferView"]), views.indices.contains(viewIndex) else {
      throw ScanMeshLoadError.invalid("This scan file could not be read.")
    }
    let view = views[viewIndex]
    if intValue(view["buffer"]) != 0 && view["buffer"] != nil {
      throw ScanMeshLoadError.invalid("This scan file could not be read.")
    }
    let count = intValue(accessor["count"]) ?? 0
    let stride = components * bytes
    if let byteStride = intValue(view["byteStride"]), byteStride != stride {
      throw ScanMeshLoadError.invalid("This scan file could not be read.")
    }
    let start = (intValue(view["byteOffset"]) ?? 0) + (intValue(accessor["byteOffset"]) ?? 0)
    let length = count * stride
    let end = start + length
    guard count > 0, start >= 0, end <= blob.count else {
      throw ScanMeshLoadError.invalid("This scan file could not be read.")
    }
    return blob.subdata(in: start..<end)
  }

  /// SceneKit color sources want tightly packed floats, not the glTF byte RGB.
  private static func rgbaFloats(fromRGBBytes colors: Data) -> Data {
    let triples = colors.count / 3
    guard triples > 0 else { return Data() }
    var floats = [Float](repeating: 0, count: triples * 3)
    colors.withUnsafeBytes { raw in
      let bytes = raw.bindMemory(to: UInt8.self)
      for index in 0..<triples {
        floats[index * 3] = Float(bytes[index * 3]) / 255
        floats[index * 3 + 1] = Float(bytes[index * 3 + 1]) / 255
        floats[index * 3 + 2] = Float(bytes[index * 3 + 2]) / 255
      }
    }
    return floats.withUnsafeBufferPointer { Data(buffer: $0) }
  }

  private static func worldBounds(of root: SCNNode) -> (min: SCNVector3, max: SCNVector3)? {
    var minPoint: SCNVector3?
    var maxPoint: SCNVector3?
    root.enumerateHierarchy { node, _ in
      guard node.geometry != nil else { return }
      let box = node.boundingBox
      let corners = [
        SCNVector3(box.min.x, box.min.y, box.min.z),
        SCNVector3(box.min.x, box.min.y, box.max.z),
        SCNVector3(box.min.x, box.max.y, box.min.z),
        SCNVector3(box.min.x, box.max.y, box.max.z),
        SCNVector3(box.max.x, box.min.y, box.min.z),
        SCNVector3(box.max.x, box.min.y, box.max.z),
        SCNVector3(box.max.x, box.max.y, box.min.z),
        SCNVector3(box.max.x, box.max.y, box.max.z),
      ]
      for corner in corners {
        let world = node.convertPosition(corner, to: nil)
        guard let currentMin = minPoint, let currentMax = maxPoint else {
          minPoint = world
          maxPoint = world
          continue
        }
        minPoint = SCNVector3(
          min(currentMin.x, world.x),
          min(currentMin.y, world.y),
          min(currentMin.z, world.z)
        )
        maxPoint = SCNVector3(
          max(currentMax.x, world.x),
          max(currentMax.y, world.y),
          max(currentMax.z, world.z)
        )
      }
    }
    guard let minPoint, let maxPoint else { return nil }
    return (minPoint, maxPoint)
  }

  private static func dictionary(_ value: Any?) -> [String: Any]? {
    if let dict = value as? [String: Any] { return dict }
    guard let dict = value as? NSDictionary else { return nil }
    var result: [String: Any] = [:]
    for (key, item) in dict {
      if let key = key as? String { result[key] = item }
    }
    return result
  }

  private static func dictionaries(_ value: Any?) -> [[String: Any]] {
    let items = value as? [Any] ?? (value as? NSArray as? [Any]) ?? []
    return items.compactMap(dictionary)
  }

  private static func intValue(_ value: Any?) -> Int? {
    if let number = value as? Int { return number }
    if let number = value as? NSNumber { return number.intValue }
    return nil
  }
}

enum ScanMeshLoadError: LocalizedError {
  case unsupported(String)
  case invalid(String)

  var errorDescription: String? {
    switch self {
    case .unsupported(let message), .invalid(let message):
      return message
    }
  }
}
