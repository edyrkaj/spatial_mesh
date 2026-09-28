import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Method + event channel bridge to the native LiDAR scanner.
class LidarScanChannel {
  LidarScanChannel._();

  static const method = MethodChannel('com.spatialmesh/lidar_scan');
  static const events = EventChannel('com.spatialmesh/lidar_scan_events');

  static bool get isIos =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  static Future<bool> isLiDARAvailable() async {
    if (!isIos) return false;
    final value = await method.invokeMethod<bool>('isLiDARAvailable');
    return value ?? false;
  }

  static Future<String?> unsupportedReason() async {
    if (!isIos) {
      return 'LiDAR scanning is only available on iOS devices with LiDAR.';
    }
    return method.invokeMethod<String>('unsupportedReason');
  }

  static Future<void> startScan() => method.invokeMethod<void>('startScan');

  static Future<void> pauseScan() => method.invokeMethod<void>('pauseScan');

  static Future<void> resetScan() => method.invokeMethod<void>('resetScan');

  /// Returns `{path: String}` on success; throws [PlatformException] on failure.
  static Future<Map<String, dynamic>> finishScan({String format = 'usdz'}) async {
    final raw = await method.invokeMethod<dynamic>('finishScan', {
      'format': format,
    });
    if (raw is Map) {
      return Map<String, dynamic>.from(raw);
    }
    throw PlatformException(
      code: 'EXPORT_FAILED',
      message: 'Native finishScan returned an unexpected payload.',
    );
  }

  static Future<int> meshCount() async {
    final value = await method.invokeMethod<int>('meshCount');
    return value ?? 0;
  }

  static Stream<Map<String, dynamic>> eventStream() {
    if (!isIos) {
      return Stream<Map<String, dynamic>>.value({
        'type': 'capability',
        'available': false,
        'reason': 'LiDAR scanning requires an iOS LiDAR device.',
      });
    }
    return events.receiveBroadcastStream().map((event) {
      if (event is Map) {
        return Map<String, dynamic>.from(event);
      }
      return <String, dynamic>{'type': 'unknown', 'raw': '$event'};
    });
  }
}
