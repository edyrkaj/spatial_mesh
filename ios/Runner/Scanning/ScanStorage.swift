import Foundation
import UIKit

/// Saved scans live in Documents/scans so they survive Done and can be shared
/// from the same file the Library lists.
enum ScanStorage {
  static var directory: URL {
    let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    return documents.appendingPathComponent("scans", isDirectory: true)
  }

  static func list() throws -> [[String: Any]] {
    let folder = directory
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let urls = try FileManager.default.contentsOfDirectory(
      at: folder,
      includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
      options: [.skipsHiddenFiles]
    )
    return urls.compactMap { url -> [String: Any]? in
      let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
      guard values?.isRegularFile == true else { return nil }
      let modified = values?.contentModificationDate ?? Date()
      return [
        "path": url.path,
        "name": url.lastPathComponent,
        "bytes": values?.fileSize ?? 0,
        "modifiedMillis": Int(modified.timeIntervalSince1970 * 1000),
      ]
    }
    .sorted { lhs, rhs in
      (lhs["modifiedMillis"] as? Int ?? 0) > (rhs["modifiedMillis"] as? Int ?? 0)
    }
  }

  /// The file at `path` when it lives in Documents/scans.
  static func savedFile(path: String) throws -> URL {
    let url = try fileInsideScans(path)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw ScanStorageError.missing
    }
    return url
  }

  static func share(path: String) throws {
    let url = try fileInsideScans(path)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw ScanStorageError.missing
    }
    guard let presenter = topViewController() else {
      throw ScanStorageError.noPresenter
    }

    let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
    if let popover = activity.popoverPresentationController {
      popover.sourceView = presenter.view
      popover.sourceRect = CGRect(
        x: presenter.view.bounds.midX,
        y: presenter.view.bounds.midY,
        width: 1,
        height: 1
      )
      popover.permittedArrowDirections = []
    }
    presenter.present(activity, animated: true)
  }

  static func delete(path: String, name: String) throws {
    let fileName = storedFileName(name) ?? storedFileName(URL(fileURLWithPath: path).lastPathComponent)
    guard let fileName else { throw ScanStorageError.outsideLibrary }

    let url = directory.appendingPathComponent(fileName, isDirectory: false)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw ScanStorageError.missing
    }
    try FileManager.default.removeItem(at: url)
  }

  /// Accept only a single file name so a bad path cannot delete outside Documents/scans.
  private static func storedFileName(_ raw: String?) -> String? {
    guard let raw, !raw.isEmpty else { return nil }
    let name = (raw as NSString).lastPathComponent
    guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else { return nil }
    return name
  }

  private static func fileInsideScans(_ path: String) throws -> URL {
    let url = URL(fileURLWithPath: path)
    let root = directory.resolvingSymlinksInPath().path
    let file = url.resolvingSymlinksInPath().path
    guard file == root || file.hasPrefix(root + "/") else {
      throw ScanStorageError.outsideLibrary
    }
    return url
  }

  private static func topViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let root = scenes.flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController
      ?? scenes.first?.windows.first?.rootViewController
    var presenter = root
    while let presented = presenter?.presentedViewController {
      presenter = presented
    }
    return presenter
  }
}

enum ScanStorageError: LocalizedError {
  case missing
  case noPresenter
  case outsideLibrary

  var errorDescription: String? {
    switch self {
    case .missing:
      return "That scan file is no longer on this device."
    case .noPresenter:
      return "Could not open the share sheet."
    case .outsideLibrary:
      return "Only saved scans can be used."
    }
  }
}
