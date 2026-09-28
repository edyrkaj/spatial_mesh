import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

/// Native SceneKit viewer for a file under Documents/scans.
class SavedMeshView extends StatelessWidget {
  const SavedMeshView({super.key, required this.path});

  final String path;

  static const viewType = 'com.spatialmesh/scan_mesh_view';

  @override
  Widget build(BuildContext context) {
    return UiKitView(
      viewType: viewType,
      layoutDirection: TextDirection.ltr,
      creationParams: <String, dynamic>{'path': path},
      creationParamsCodec: const StandardMessageCodec(),
      gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{
        Factory<OneSequenceGestureRecognizer>(EagerGestureRecognizer.new),
      },
      hitTestBehavior: PlatformViewHitTestBehavior.opaque,
    );
  }
}
