---
title: Phase 1 native scaffold
---

# Phase 1 — Flutter + native iOS LiDAR (implemented core)

Architecture and file map for Spatial Mesh Phase 1. Phase 1 now includes a working LiDAR session, scan controls, mesh processing/export, and Flutter bridge — not only stubs.

## File tree

```
spatial_mesh/
├── README.md
├── pubspec.yaml
├── docs/
│   └── phase-1-native-scaffold.md
├── lib/
│   ├── main.dart
│   ├── bridge/
│   │   └── lidar_scan_channel.dart
│   └── features/
│       ├── library/
│       │   └── project_library_page.dart
│       ├── scan/
│       │   ├── scan_page.dart
│       │   └── lidar_scan_view.dart
│       └── settings/
│           └── settings_page.dart
├── test/
│   └── widget_test.dart
└── ios/
    └── Runner/
        ├── AppDelegate.swift
        ├── Info.plist
        └── Scanning/
            ├── LiDARCapability.swift
            ├── LiDARScanViewController.swift
            ├── MeshWireframeVisualizer.swift
            ├── ScanOverlayControls.swift
            ├── TrackingQualityMonitor.swift
            ├── MeshExportUtility.swift
            ├── LiDARScanPlatformView.swift
            └── LiDARScanPlugin.swift
```

## Swift types

| File | Types | Responsibility |
|------|--------|----------------|
| `LiDARCapability.swift` | `LiDARCapability` | Guards via `supportsSceneReconstruction(.mesh)`; builds `ARWorldTrackingConfiguration` with `.mesh` + optional scene depth |
| `LiDARScanViewController.swift` | `LiDARScanViewController` | RealityKit `ARView` session; Start/Pause/Reset/Done; live mesh anchor tracking; async export |
| `MeshWireframeVisualizer.swift` | `MeshWireframeVisualizer` | `ARMeshAnchor` → RealityKit `ModelEntity` preview |
| `ScanOverlayControls.swift` | `ScanOverlayControls` | Native Start / Pause / Reset / Done + tracking / mesh-count labels |
| `TrackingQualityMonitor.swift` | `TrackingQualityMonitor` | Maps `ARCamera.trackingState` → overlay / Flutter payloads |
| `MeshExportUtility.swift` | `MeshExportUtility`, `MeshExportFormat` | Extract world-space mesh, weld/clean/decimate, write `.usdz` / `.obj` (ModelIO) and `.gltf` (custom) |
| `LiDARScanPlatformView.swift` | factory + platform view | Flutter `UiKitView` embedding; event fan-out |
| `LiDARScanPlugin.swift` | `LiDARScanPlugin` | Method + event channels; returns export path on `finishScan` |

## Linked frameworks

- **ARKit** — world tracking, mesh anchors, scene depth
- **RealityKit** — `ARView` + mesh entity visualization
- **Metal / MetalKit** — `MTKMeshBufferAllocator` for ModelIO buffers
- **ModelIO** — USDZ / OBJ writers

**Hardware:** iPhone 12 Pro+ or iPad Pro 2020+ with LiDAR. Deployment target iOS 15.0.

## Flutter bridge

- `LidarScanChannel`: `isLiDARAvailable`, `unsupportedReason`, `startScan`, `pauseScan`, `resetScan`, `finishScan({format})`, `meshCount`
- `LidarScanView` mounts `UiKitView` (`com.spatialmesh/lidar_scan_view`) or shows unsupported UI
- `finishScan` returns `{path: String}` or `EXPORT_FAILED` / `EMPTY_MESH`
- Events: `capability`, `tracking`, `meshCount`, `scanState`, `exportComplete`, `error`, `done`

## Export format honesty

| Format | Status |
|--------|--------|
| USDZ | ModelIO `MDLAsset.export(to:)` |
| OBJ | ModelIO `MDLAsset.export(to:)` |
| glTF | **Not** supported by ModelIO on iOS — custom minimal glTF 2.0 writer (positions + triangle indices, embedded buffer, no materials) |

## Info.plist

- `NSCameraUsageDescription`
- `UIRequiredDeviceCapabilities`: `arkit`, `metal`

## How to run

```bash
flutter pub get
flutter run -d <lidar-device>
```

Simulator: Flutter UI + unsupported / capability messaging only. Live mesh requires a LiDAR device.

## Next steps (post Phase 1)

1. Persist export paths into the project library (still local).
2. Optional Metal depth filtering / better mesh simplification.
3. Richer glTF (normals, materials) or USDZ preview in-library.
4. Pigeon typed contracts once the channel API stabilizes.
