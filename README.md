# Spatial Mesh

iOS-first LiDAR room scanning app. Flutter UI + native ARKit / RealityKit / ModelIO mesh capture and local export. No auth or cloud sync in Phase 1.

## Requirements

- macOS with Xcode 15+
- Flutter 3.47+ (`brew install --cask flutter`)
- Physical **LiDAR** device: iPhone 12 Pro / 13 Pro / 14 Pro / 15 Pro / 16 Pro (or Pro Max) or iPad Pro 2020+
- iOS 15.0+ deployment target

Simulator can compile and show the Flutter shell, but **scene reconstruction does not run without LiDAR hardware**.

## Run on a LiDAR device

```bash
cd /Users/a/Code/github/spatial_mesh
flutter pub get
flutter devices
flutter run -d <your-device-id> --release
```

Or open `ios/Runner.xcworkspace` / `ios/Runner.xcodeproj` in Xcode, select your team for signing, and run on the device.

Done saves a textured `.gltf` of one object. On iOS 17, tap **Start**, fit the box, tap **Start** again, and orbit until sparkles cover the surface. The saved model is a photogrammetry mesh, not the coarse room shape.

## Export formats

| Format | Writer | Notes |
|--------|--------|-------|
| `.gltf` | Custom glTF 2.0 | Default. Dense LiDAR depth surface with camera color |
| `.usdz` | SceneKit `SCNScene.write` | ModelIO rejects `.usdz` on device |
| `.obj` | ModelIO | Interchange fallback |

Done saves the mesh under the app Documents folder (`Documents/scans/`). That file stays on the phone, shows in the Library tab, and can be viewed, shared, or deleted. View opens the mesh in the app. Share sends that same file. The same folder is visible in the Files app.

## Architecture

See [docs/phase-1-native-scaffold.md](docs/phase-1-native-scaffold.md).

## Channel API

- Method channel: `com.spatialmesh/lidar_scan`
  - `isLiDARAvailable`, `unsupportedReason`, `startScan`, `pauseScan`, `resetScan`, `finishScan({format})`, `meshCount`
- Event channel: `com.spatialmesh/lidar_scan_events`
- Platform view: `com.spatialmesh/lidar_scan_view`
