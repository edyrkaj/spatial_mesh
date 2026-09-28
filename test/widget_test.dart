import 'package:flutter_test/flutter_test.dart';
import 'package:spatial_mesh/main.dart';

void main() {
  testWidgets('Spatial Mesh shell shows Library tab', (tester) async {
    await tester.pumpWidget(const SpatialMeshApp());
    expect(find.text('Spatial Mesh'), findsOneWidget);
    expect(find.text('No scans yet'), findsOneWidget);
    expect(find.text('Library'), findsOneWidget);
    expect(find.text('Scan'), findsOneWidget);
  });
}
