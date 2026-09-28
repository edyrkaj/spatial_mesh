import 'package:flutter_test/flutter_test.dart';
import 'package:spatial_mesh/features/library/scan_library.dart';

void main() {
  test('SavedScan reads the phone file fields', () {
    final scan = SavedScan.fromMap({
      'path': '/var/mobile/Containers/Data/Application/abc/Documents/scans/scan_20260928.gltf',
      'name': 'scan_20260928.gltf',
      'bytes': 1536,
      'modifiedMillis': DateTime(2026, 9, 28, 14, 44).millisecondsSinceEpoch,
    });

    expect(scan.name, 'scan_20260928.gltf');
    expect(scan.path, endsWith('Documents/scans/scan_20260928.gltf'));
    expect(scan.bytes, 1536);
    expect(formatScanBytes(1536), '1.5 KB');
    expect(formatScanTime(scan.modified), '2026-09-28 14:44');
  });
}
