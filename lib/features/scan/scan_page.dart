import 'dart:async';

import 'package:flutter/material.dart';
import 'package:spatial_mesh/bridge/lidar_scan_channel.dart';
import 'package:spatial_mesh/features/library/scan_library.dart';
import 'package:spatial_mesh/features/scan/lidar_scan_view.dart';

class ScanPage extends StatefulWidget {
  const ScanPage({super.key});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  StreamSubscription<Map<String, dynamic>>? _events;
  bool _checking = true;
  bool _available = false;
  String? _unsupportedReason;
  String _format = 'gltf';

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    try {
      final available = await LidarScanChannel.isLiDARAvailable();
      final reason = await LidarScanChannel.unsupportedReason();
      if (!mounted) return;
      setState(() {
        _available = available;
        _unsupportedReason = reason;
        _checking = false;
      });
      _events = LidarScanChannel.eventStream().listen(_onEvent);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _checking = false;
        _available = false;
        _unsupportedReason = '$error';
      });
    }
  }

  void _onEvent(Map<String, dynamic> event) {
    if (!mounted) return;
    final type = event['type'] as String? ?? '';
    switch (type) {
      case 'capability':
        setState(() {
          _available = event['available'] == true;
          _unsupportedReason = event['reason'] as String?;
        });
      case 'scanState':
        if (event['state'] == 'reset') {
          ScaffoldMessenger.of(context).clearSnackBars();
        }
      case 'done':
        final error = event['error'] as String?;
        final path = event['path'] as String?;
        if (error == null && path != null && path.isNotEmpty) {
          _notifyScanCompleted(path);
        }
    }
  }

  void _notifyScanCompleted(String path) {
    unawaited(ScanLibraryController.instance.reload());
    final name = _fileName(path);
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    messenger.showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 6),
        content: Text('Scan completed\n$name'),
      ),
    );
  }

  String _fileName(String path) {
    final name = path.split('/').where((part) => part.isNotEmpty).last;
    return name.isEmpty ? 'scan' : name;
  }

  @override
  void dispose() {
    _events?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan'),
        actions: [
          PopupMenuButton<String>(
            initialValue: _format,
            tooltip: 'Export format',
            onSelected: (value) {
              setState(() => _format = value);
              unawaited(LidarScanChannel.setExportFormat(value));
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'gltf', child: Text('glTF (Three.js)')),
              PopupMenuItem(value: 'usdz', child: Text('USDZ')),
              PopupMenuItem(value: 'obj', child: Text('OBJ')),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Center(child: Text(_format.toUpperCase())),
            ),
          ),
        ],
      ),
      body: _checking
          ? const Center(child: CircularProgressIndicator())
          : LidarScanView(
              unsupportedReason: _available ? null : _unsupportedReason,
            ),
    );
  }
}
