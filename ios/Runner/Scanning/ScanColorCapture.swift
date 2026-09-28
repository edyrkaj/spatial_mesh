import ARKit
import CoreVideo
import simd

/// A downscaled camera photo plus the pose needed to paint mesh vertices.
struct ScanColorFrame {
  var cameraToWorld: simd_float4x4
  var intrinsics: simd_float3x3
  var width: Int
  var height: Int
  var rgba: [UInt8]
}

/// Keeps a short ring of camera frames while scanning so export can color the mesh.
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
    guard now.timeIntervalSince(lastCapture) >= 0.4 || moved >= 0.15 else { return }
    guard let stored = Self.makeFrame(from: frame) else { return }

    lastCapture = now
    lastPosition = position
    lock.lock()
    frames.append(stored)
    if frames.count > 40 {
      frames.removeFirst(frames.count - 40)
    }
    lock.unlock()
  }

  /// Copies the rear-camera buffer in its native top-left orientation and scales
  /// the intrinsics to match, so later projection uses the same pixels.
  private static func makeFrame(from frame: ARFrame) -> ScanColorFrame? {
    let pixelBuffer = frame.capturedImage
    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

    let sourceWidth = CVPixelBufferGetWidth(pixelBuffer)
    let sourceHeight = CVPixelBufferGetHeight(pixelBuffer)
    guard sourceWidth > 8, sourceHeight > 8 else { return nil }
    guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
          let uvBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else {
      return nil
    }

    let yRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
    let uvRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
    let step = max(1, sourceWidth / 480)
    let width = sourceWidth / step
    let height = sourceHeight / step
    let fullRange = CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange

    var rgba = [UInt8](repeating: 0, count: width * height * 4)
    let yPointer = yBase.assumingMemoryBound(to: UInt8.self)
    let uvPointer = uvBase.assumingMemoryBound(to: UInt8.self)

    for row in 0..<height {
      let sourceY = min(sourceHeight - 1, row * step)
      for column in 0..<width {
        let sourceX = min(sourceWidth - 1, column * step)
        let yByte = yPointer[sourceY * yRow + sourceX]
        let uvIndex = (sourceY / 2) * uvRow + (sourceX / 2) * 2
        let cb = Int(uvPointer[uvIndex]) - 128
        let cr = Int(uvPointer[uvIndex + 1]) - 128
        let yValue = fullRange ? Int(yByte) : (Int(yByte) - 16) * 255 / 219
        let red = min(255, max(0, yValue + (cr * 1436) / 1024))
        let green = min(255, max(0, yValue - (cb * 352) / 1024 - (cr * 731) / 1024))
        let blue = min(255, max(0, yValue + (cb * 1815) / 1024))
        let offset = (row * width + column) * 4
        rgba[offset] = UInt8(red)
        rgba[offset + 1] = UInt8(green)
        rgba[offset + 2] = UInt8(blue)
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
      rgba: rgba
    )
  }
}
