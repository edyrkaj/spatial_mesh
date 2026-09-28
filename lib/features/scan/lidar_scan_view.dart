import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:spatial_mesh/bridge/lidar_scan_channel.dart';

/// Embeds the native ARKit scan view, or a clear unsupported placeholder.
class LidarScanView extends StatelessWidget {
  const LidarScanView({
    super.key,
    this.unsupportedReason,
  });

  final String? unsupportedReason;

  static const viewType = 'com.spatialmesh/lidar_scan_view';

  @override
  Widget build(BuildContext context) {
    if (!LidarScanChannel.isIos) {
      return _UnsupportedPanel(
        reason: unsupportedReason ??
            'LiDAR scanning requires a physical iPhone/iPad with LiDAR.',
      );
    }

    if (unsupportedReason != null && unsupportedReason!.isNotEmpty) {
      return _UnsupportedPanel(reason: unsupportedReason!);
    }

    return UiKitView(
      viewType: viewType,
      layoutDirection: TextDirection.ltr,
      creationParams: const <String, dynamic>{},
      creationParamsCodec: const StandardMessageCodec(),
      gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{
        Factory<OneSequenceGestureRecognizer>(EagerGestureRecognizer.new),
      },
      hitTestBehavior: PlatformViewHitTestBehavior.opaque,
    );
  }
}

class _UnsupportedPanel extends StatelessWidget {
  const _UnsupportedPanel({required this.reason});

  final String reason;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: const Color(0xFF102A33),
      padding: const EdgeInsets.all(24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.sensors_off, size: 56, color: scheme.onPrimary),
              const SizedBox(height: 16),
              Text(
                'LiDAR unavailable',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 10),
              Text(
                reason,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Colors.white.withValues(alpha: 0.85),
                    ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
