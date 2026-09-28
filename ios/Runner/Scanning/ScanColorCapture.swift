import ARKit
import CoreVideo
import simd

/// One camera moment: color and, when LiDAR depth exists, a depth sample per pixel.
struct ScanColorFrame {
  var cameraToWorld: simd_float4x4
  /// Intrinsics for `width` x `height`. Depth frames use the depth-map pixel space.
  var intrinsics: simd_float3x3
  var width: Int
  var height: Int
  var rgba: [UInt8]
  /// Meters. Empty when this frame has no LiDAR depth. Otherwise `width * height`.
  var depth: [Float]
}

/// Keeps camera + LiDAR depth frames so export can rebuild a dense colored surface.
final class ScanColorCapture {
  private let lock = NSLock()
  private var frames: [ScanColorFrame] = []
  private var lastCapture = Date.distantPast
  private var lastPosition = SIMD3<Float>(repeating: .greatestFiniteMagnitude)

  func reset() {
    lock.lock()
    frames.removeAll()
    lastCapture = .distantPast
    lastPosition = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
    lock.unlock()
  }

  func snapshot() -> [ScanColorFrame] {
    lock.lock()
    defer { lock.unlock() }
    return frames
  }

  func record(_ frame: ARFrame) {
    let now = Date()
    let position = SIMD3<Float>(
      frame.camera.transform.columns.3.x,
      frame.camera.transform.columns.3.y,
      frame.camera.transform.columns.3.z
    )
    let moved = simd_distance(position, lastPosition)
    guard now.timeIntervalSince(lastCapture) >= 0.25 || moved >= 0.08 else { return }
    guard let stored = Self.makeFrame(from: frame) else { return }

    lastCapture = now
    lastPosition = position
    lock.lock()
    frames.append(stored)
    if frames.count > 48 {
      frames.removeFirst(frames.count - 48)
    }
    lock.unlock()
  }

  private static func makeFrame(from frame: ARFrame) -> ScanColorFrame? {
    let colorBuffer = frame.capturedImage
    CVPixelBufferLockBaseAddress(colorBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(colorBuffer, .readOnly) }

    let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth
    if let depthData {
      return makeDepthFrame(from: frame, colorBuffer: colorBuffer, depthData: depthData)
    }
    return makeColorFrame(from: frame, colorBuffer: colorBuffer)
  }

  private static func makeDepthFrame(
    from frame: ARFrame,
    colorBuffer: CVPixelBuffer,
    depthData: ARDepthData
  ) -> ScanColorFrame? {
    let depthBuffer = depthData.depthMap
    CVPixelBufferLockBaseAddress(depthBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(depthBuffer, .readOnly) }

    let confidenceBuffer = depthData.confidenceMap
    if let confidenceBuffer {
      CVPixelBufferLockBaseAddress(confidenceBuffer, .readOnly)
    }
    defer {
      if let confidenceBuffer {
        CVPixelBufferUnlockBaseAddress(confidenceBuffer, .readOnly)
      }
    }

    guard let depthBase = CVPixelBufferGetBaseAddress(depthBuffer) else { return nil }
    let depthWidth = CVPixelBufferGetWidth(depthBuffer)
    let depthHeight = CVPixelBufferGetHeight(depthBuffer)
    let depthStride = CVPixelBufferGetBytesPerRow(depthBuffer) / MemoryLayout<Float>.size
    guard depthWidth > 8, depthHeight > 8, depthStride >= depthWidth else { return nil }

    let colorWidth = CVPixelBufferGetWidth(colorBuffer)
    let colorHeight = CVPixelBufferGetHeight(colorBuffer)
    guard colorWidth > 8, colorHeight > 8,
          let yBase = CVPixelBufferGetBaseAddressOfPlane(colorBuffer, 0),
          let uvBase = CVPixelBufferGetBaseAddressOfPlane(colorBuffer, 1) else {
      return nil
    }

    let yPointer = yBase.assumingMemoryBound(to: UInt8.self)
    let uvPointer = uvBase.assumingMemoryBound(to: UInt8.self)
    let yRow = CVPixelBufferGetBytesPerRowOfPlane(colorBuffer, 0)
    let uvRow = CVPixelBufferGetBytesPerRowOfPlane(colorBuffer, 1)
    let fullRange = CVPixelBufferGetPixelFormatType(colorBuffer) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    let depthPointer = depthBase.assumingMemoryBound(to: Float.self)

    var confidencePointer: UnsafeMutablePointer<UInt8>?
    var confidenceStride = 0
    if let confidenceBuffer, let confidenceBase = CVPixelBufferGetBaseAddress(confidenceBuffer) {
      confidencePointer = confidenceBase.assumingMemoryBound(to: UInt8.self)
      confidenceStride = CVPixelBufferGetBytesPerRow(confidenceBuffer)
    }

    var rgba = [UInt8](repeating: 0, count: depthWidth * depthHeight * 4)
    var depth = [Float](repeating: 0, count: depthWidth * depthHeight)

    for row in 0..<depthHeight {
      for column in 0..<depthWidth {
        let meters = depthPointer[row * depthStride + column]
        let offset = row * depthWidth + column
        if let confidencePointer, confidenceStride > 0 {
          let confidence = confidencePointer[row * confidenceStride + column]
          if confidence == 0 {
            continue
          }
        }
        guard meters.isFinite, meters > 0.12, meters < 4 else { continue }
        depth[offset] = meters

        let colorX = min(colorWidth - 1, column * colorWidth / depthWidth)
        let colorY = min(colorHeight - 1, row * colorHeight / depthHeight)
        let rgb = rgb(atX: colorX, y: colorY, yPointer: yPointer, uvPointer: uvPointer, yRow: yRow, uvRow: uvRow, fullRange: fullRange)
        let byte = offset * 4
        rgba[byte] = rgb.0
        rgba[byte + 1] = rgb.1
        rgba[byte + 2] = rgb.2
        rgba[byte + 3] = 255
      }
    }

    var intrinsics = frame.camera.intrinsics
    let scaleX = Float(depthWidth) / Float(colorWidth)
    let scaleY = Float(depthHeight) / Float(colorHeight)
    intrinsics.columns.0.x *= scaleX
    intrinsics.columns.1.y *= scaleY
    intrinsics.columns.2.x *= scaleX
    intrinsics.columns.2.y *= scaleY

    return ScanColorFrame(
      cameraToWorld: frame.camera.transform,
      intrinsics: intrinsics,
      width: depthWidth,
      height: depthHeight,
      rgba: rgba,
      depth: depth
    )
  }

  private static func makeColorFrame(from frame: ARFrame, colorBuffer: CVPixelBuffer) -> ScanColorFrame? {
    let sourceWidth = CVPixelBufferGetWidth(colorBuffer)
    let sourceHeight = CVPixelBufferGetHeight(colorBuffer)
    guard sourceWidth > 8, sourceHeight > 8,
          let yBase = CVPixelBufferGetBaseAddressOfPlane(colorBuffer, 0),
          let uvBase = CVPixelBufferGetBaseAddressOfPlane(colorBuffer, 1) else {
      return nil
    }

    let yRow = CVPixelBufferGetBytesPerRowOfPlane(colorBuffer, 0)
    let uvRow = CVPixelBufferGetBytesPerRowOfPlane(colorBuffer, 1)
    let step = max(1, sourceWidth / 480)
    let width = sourceWidth / step
    let height = sourceHeight / step
    let fullRange = CVPixelBufferGetPixelFormatType(colorBuffer) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    let yPointer = yBase.assumingMemoryBound(to: UInt8.self)
    let uvPointer = uvBase.assumingMemoryBound(to: UInt8.self)

    var rgba = [UInt8](repeating: 0, count: width * height * 4)
    for row in 0..<height {
      let sourceY = min(sourceHeight - 1, row * step)
      for column in 0..<width {
        let sourceX = min(sourceWidth - 1, column * step)
        let rgb = rgb(atX: sourceX, y: sourceY, yPointer: yPointer, uvPointer: uvPointer, yRow: yRow, uvRow: uvRow, fullRange: fullRange)
        let offset = (row * width + column) * 4
        rgba[offset] = rgb.0
        rgba[offset + 1] = rgb.1
        rgba[offset + 2] = rgb.2
        rgba[offset + 3] = 255
      }
    }

    var intrinsics = frame.camera.intrinsics
    let factor = Float(step)
    intrinsics.columns.0.x /= factor
    intrinsics.columns.1.y /= factor
    intrinsics.columns.2.x /= factor
    intrinsics.columns.2.y /= factor

    return ScanColorFrame(
      cameraToWorld: frame.camera.transform,
      intrinsics: intrinsics,
      width: width,
      height: height,
      rgba: rgba,
      depth: []
    )
  }

  private static func rgb(
    atX x: Int,
    y: Int,
    yPointer: UnsafePointer<UInt8>,
    uvPointer: UnsafePointer<UInt8>,
    yRow: Int,
    uvRow: Int,
    fullRange: Bool
  ) -> (UInt8, UInt8, UInt8) {
    let yByte = yPointer[y * yRow + x]
    let uvIndex = (y / 2) * uvRow + (x / 2) * 2
    let cb = Int(uvPointer[uvIndex]) - 128
    let cr = Int(uvPointer[uvIndex + 1]) - 128
    let yValue = fullRange ? Int(yByte) : (Int(yByte) - 16) * 255 / 219
    let red = min(255, max(0, yValue + (cr * 1436) / 1024))
    let green = min(255, max(0, yValue - (cb * 352) / 1024 - (cr * 731) / 1024))
    let blue = min(255, max(0, yValue + (cb * 1815) / 1024))
    return (UInt8(red), UInt8(green), UInt8(blue))
  }
}
