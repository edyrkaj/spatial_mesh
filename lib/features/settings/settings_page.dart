import 'package:flutter/material.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: const [
          ListTile(
            title: Text('Local exports only'),
            subtitle: Text('Phase 1 keeps meshes on-device. No cloud sync.'),
          ),
          ListTile(
            title: Text('Hardware'),
            subtitle: Text('iPhone 12 Pro+ or iPad Pro 2020+ with LiDAR. iOS 15+.'),
          ),
          ListTile(
            title: Text('Export formats'),
            subtitle: Text('USDZ and OBJ via ModelIO. glTF via a minimal custom writer (geometry only).'),
          ),
        ],
      ),
    );
  }
}
