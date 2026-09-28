import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:spatial_mesh/bridge/lidar_scan_channel.dart';
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
  String _tracking = 'Waiting for scanner…';
  String _status = 'Idle';
  int _meshCount = 0;
  String? _lastExportPath;
  String? _error;
  bool _exporting = false;
  String _format = 'usdz';

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
    setState(() {
      switch (type) {
        case 'capability':
          _available = event['available'] == true;
          _unsupportedReason = event['reason'] as String?;
        case 'tracking':
          _tracking = event['message'] as String? ?? _tracking;
        case 'meshCount':
          _meshCount = (event['count'] as num?)?.toInt() ?? _meshCount;
        case 'scanState':
          _status = event['state'] as String? ?? _status;
          if (event['meshCount'] != null) {
            _meshCount = (event['meshCount'] as num).toInt();
          }
        case 'exportComplete':
          _lastExportPath = event['path'] as String?;
          _error = null;
          _status = 'exported';
        case 'error':
          _error = event['message'] as String? ?? 'Unknown scanner error';
        case 'done':
          _lastExportPath = event['path'] as String?;
          _error = event['error'] as String?;
      }
    });
  }

  Future<void> _finish() async {
    setState(() {
      _exporting = true;
      _error = null;
    });
    try {
      final result = await LidarScanChannel.finishScan(format: _format);
      if (!mounted) return;
      setState(() {
        _lastExportPath = result['path'] as String?;
        _status = 'exported';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Exported to ${_lastExportPath ?? "(unknown)"}'),
        ),
      );
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() => _error = error.message ?? error.code);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
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
            onSelected: (value) => setState(() => _format = value),
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'usdz', child: Text('USDZ (ModelIO)')),
              PopupMenuItem(value: 'gltf', child: Text('glTF (custom)')),
              PopupMenuItem(value: 'obj', child: Text('OBJ (ModelIO)')),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Center(child: Text(_format.toUpperCase())),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _checking
                ? const Center(child: CircularProgressIndicator())
                : LidarScanView(
                    unsupportedReason: _available ? null : _unsupportedReason,
                  ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(_statusLabel, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(_tracking, style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 4),
                  Text(
                    _meshCount == 0
                        ? 'No mesh captured yet'
                        : 'Mesh anchors: $_meshCount',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _error!,
                      style: TextStyle(color: Theme.of(context).colorScheme.error),
                    ),
                  ],
                  if (_lastExportPath != null) ...[
                    const SizedBox(height: 8),
                    SelectableText(
                      'Last export:\n$_lastExportPath',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton(
                        onPressed: !_available || _exporting
                            ? null
                            : () => LidarScanChannel.startScan(),
                        child: const Text('Start'),
                      ),
                      OutlinedButton(
                        onPressed: !_available || _exporting
                            ? null
                            : () => LidarScanChannel.pauseScan(),
                        child: const Text('Pause'),
                      ),
                      OutlinedButton(
                        onPressed: !_available || _exporting
                            ? null
                            : () => LidarScanChannel.resetScan(),
                        child: const Text('Reset'),
                      ),
                      FilledButton.tonal(
                        onPressed: !_available || _exporting || _meshCount == 0
                            ? null
                            : _finish,
                        child: _exporting
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Text('Done'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String get _statusLabel {
    switch (_status) {
      case 'running':
        return 'Scanning';
      case 'paused':
        return 'Paused';
      case 'reset':
        return 'Reset';
      case 'exported':
        return 'Export complete';
      default:
        return 'Ready';
    }
  }
}
