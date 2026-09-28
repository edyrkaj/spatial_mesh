import 'package:flutter/material.dart';
import 'package:spatial_mesh/bridge/lidar_scan_channel.dart';
import 'package:spatial_mesh/features/library/saved_mesh_view.dart';
import 'package:spatial_mesh/features/library/scan_library.dart';

/// Full-screen orbit view of one saved scan.
class ScanViewerPage extends StatelessWidget {
  const ScanViewerPage({super.key, required this.scan});

  final SavedScan scan;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF102A33),
      appBar: AppBar(
        title: Text(scan.name),
        backgroundColor: const Color(0xFF102A33),
        foregroundColor: Colors.white,
      ),
      body: LidarScanChannel.isIos
          ? Stack(
              children: [
                Positioned.fill(child: SavedMeshView(path: scan.path)),
                const Align(
                  alignment: Alignment.bottomCenter,
                  child: IgnorePointer(
                    child: SafeArea(
                      child: Padding(
                        padding: EdgeInsets.only(bottom: 12),
                        child: Text(
                          'Drag to orbit · pinch to zoom',
                          style: TextStyle(color: Colors.white70),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            )
          : const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Scan viewing is available on iPhone.',
                  style: TextStyle(color: Colors.white),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
    );
  }
}
