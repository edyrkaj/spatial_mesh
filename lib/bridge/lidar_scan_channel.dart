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

  /// Kept in sync with the native overlay Done button.
  static Future<void> setExportFormat(String format) async {
    if (!isIos) return;
    await method.invokeMethod<void>('setExportFormat', {'format': format});
  }

  /// Returns `{path: String}` on success; throws [PlatformException] on failure.
  static Future<Map<String, dynamic>> finishScan({String format = 'gltf'}) async {
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

  static Future<List<Map<String, dynamic>>> listScans() async {
    if (!isIos) return const [];
    final raw = await method.invokeMethod<List<dynamic>>('listScans');
    return (raw ?? const []).map((entry) {
      if (entry is Map) return Map<String, dynamic>.from(entry);
      return <String, dynamic>{};
    }).where((entry) => entry['path'] is String).toList();
  }

  static Future<void> shareScan(String path) {
    return method.invokeMethod<void>('shareScan', {'path': path});
  }

  static Future<void> deleteScan(String path) async {
    final parts = path.split('/').where((part) => part.isNotEmpty);
    final name = parts.isEmpty ? '' : parts.last;
    if (name.isEmpty) {
      throw PlatformException(
        code: 'DELETE_FAILED',
        message: 'Missing scan file name.',
      );
    }
    await method.invokeMethod<void>('deleteScan', {
      'path': path,
      'name': name,
    });
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
