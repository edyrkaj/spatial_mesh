import 'package:flutter/material.dart';
import 'package:spatial_mesh/bridge/lidar_scan_channel.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  String _hardware = 'Reading this device…';

  @override
  void initState() {
    super.initState();
    _loadHardware();
  }

  Future<void> _loadHardware() async {
    try {
      final info = await LidarScanChannel.deviceHardware();
      if (!mounted) return;
      setState(() => _hardware = _hardwareText(info));
    } catch (error) {
      if (!mounted) return;
      setState(() => _hardware = '$error');
    }
  }

  String _hardwareText(Map<String, dynamic> info) {
    final name = info['name'] as String? ?? 'Unknown device';
    final machine = info['machine'] as String? ?? '';
    final systemName = info['systemName'] as String? ?? 'iOS';
    final systemVersion = info['systemVersion'] as String? ?? '';
    final model = machine.isEmpty || machine == name ? name : '$name ($machine)';
    return [
      model,
      '$systemName $systemVersion'.trim(),
      'LiDAR ${_yes(info['lidar'])}',
      'Scene depth ${_yes(info['sceneDepth'])}',
      'Object Capture ${_yes(info['objectCapture'])}',
      'Photogrammetry ${_yes(info['photogrammetry'])}',
    ].join('\n');
  }

  String _yes(Object? value) => value == true ? 'yes' : 'no';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          const ListTile(
            title: Text('Local exports only'),
            subtitle: Text('Phase 1 keeps meshes on-device. No cloud sync.'),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Hardware', style: Theme.of(context).textTheme.bodyLarge),
                const SizedBox(height: 4),
                Text(_hardware, style: Theme.of(context).textTheme.bodyMedium),
              ],
            ),
          ),
          const ListTile(
            title: Text('Export formats'),
            subtitle: Text('Default is glTF for Three.js. USDZ and OBJ stay available from the Scan menu.'),
          ),
        ],
      ),
    );
  }
}
