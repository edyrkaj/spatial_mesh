import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spatial_mesh/features/library/project_library_page.dart';
import 'package:spatial_mesh/features/library/scan_library.dart';

void main() {
  tearDown(() {
    ScanLibraryController.instance.debugSetScans(const []);
  });

  testWidgets('View sits with Delete and Share and opens the scan', (tester) async {
    ScanLibraryController.instance.debugSetScans([
      SavedScan(
        path: '/tmp/scans/room.gltf',
        name: 'room.gltf',
        bytes: 2048,
        modified: DateTime(2026, 9, 28, 15),
      ),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(splashFactory: NoSplash.splashFactory),
        home: const ProjectLibraryPage(),
      ),
    );

    expect(find.text('View'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);
    expect(find.text('Share'), findsOneWidget);

    final viewX = tester.getCenter(find.text('View')).dx;
    final deleteX = tester.getCenter(find.text('Delete')).dx;
    final shareX = tester.getCenter(find.text('Share')).dx;
    expect(viewX, lessThan(deleteX));
    expect(deleteX, lessThan(shareX));

    await tester.tap(find.text('View'));
    await tester.pumpAndSettle();

    expect(
      find.descendant(of: find.byType(AppBar), matching: find.text('room.gltf')),
      findsOneWidget,
    );
    expect(find.text('Scan viewing is available on iPhone.'), findsOneWidget);
  });
}
