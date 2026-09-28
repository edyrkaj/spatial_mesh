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

On first launch, grant camera permission. Use **Start** → sweep surfaces slowly → **Done** to export.

## Export formats

| Format | Writer | Notes |
|--------|--------|-------|
| `.usdz` | ModelIO `MDLAsset.export` | Default |
| `.obj` | ModelIO | Interchange fallback |
| `.gltf` | Custom minimal glTF 2.0 | Geometry only (positions + indices). ModelIO does **not** write glTF |

Exports land under the app temporary directory (`…/spatial_mesh_exports/`). The Flutter Scan tab shows the returned path.

## Architecture

See [docs/phase-1-native-scaffold.md](docs/phase-1-native-scaffold.md).

## Channel API

- Method channel: `com.spatialmesh/lidar_scan`
  - `isLiDARAvailable`, `unsupportedReason`, `startScan`, `pauseScan`, `resetScan`, `finishScan({format})`, `meshCount`
- Event channel: `com.spatialmesh/lidar_scan_events`
- Platform view: `com.spatialmesh/lidar_scan_view`
