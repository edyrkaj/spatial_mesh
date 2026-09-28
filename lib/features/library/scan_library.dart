import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:spatial_mesh/bridge/lidar_scan_channel.dart';

class SavedScan {
  const SavedScan({
    required this.path,
    required this.name,
    required this.bytes,
    required this.modified,
  });

  final String path;
  final String name;
  final int bytes;
  final DateTime modified;

  factory SavedScan.fromMap(Map<String, dynamic> map) {
    final path = map['path'] as String;
    final fallbackName = path.split('/').where((part) => part.isNotEmpty).last;
    return SavedScan(
      path: path,
      name: (map['name'] as String?)?.trim().isNotEmpty == true
          ? map['name'] as String
          : fallbackName,
      bytes: (map['bytes'] as num?)?.toInt() ?? 0,
      modified: DateTime.fromMillisecondsSinceEpoch(
        (map['modifiedMillis'] as num?)?.toInt() ?? 0,
      ),
    );
  }
}

/// Lists meshes written to Documents/scans on the phone.
class ScanLibraryController extends ChangeNotifier {
  ScanLibraryController._();

  static final instance = ScanLibraryController._();

  List<SavedScan> scans = const [];
  String? error;

  Future<void> reload() async {
    if (!LidarScanChannel.isIos) return;
    try {
      final raw = await LidarScanChannel.listScans();
      scans = raw.map(SavedScan.fromMap).toList();
      error = null;
    } on PlatformException catch (error) {
      this.error = error.message ?? error.code;
    } catch (error) {
      this.error = '$error';
    }
    notifyListeners();
  }

  void remove(String path) {
    scans = scans.where((scan) => scan.path != path).toList();
    notifyListeners();
  }
}

String formatScanBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

String formatScanTime(DateTime time) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${time.year}-${two(time.month)}-${two(time.day)} ${two(time.hour)}:${two(time.minute)}';
}
