import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:spatial_mesh/bridge/lidar_scan_channel.dart';
import 'package:spatial_mesh/features/library/scan_library.dart';

/// Saved scans from Documents/scans, with a share sheet for each file.
class ProjectLibraryPage extends StatefulWidget {
  const ProjectLibraryPage({super.key});

  @override
  State<ProjectLibraryPage> createState() => _ProjectLibraryPageState();
}

class _ProjectLibraryPageState extends State<ProjectLibraryPage> {
  final ScanLibraryController _library = ScanLibraryController.instance;

  @override
  void initState() {
    super.initState();
    _library.addListener(_onLibrary);
    unawaited(_library.reload());
  }

  @override
  void dispose() {
    _library.removeListener(_onLibrary);
    super.dispose();
  }

  void _onLibrary() {
    if (mounted) setState(() {});
  }

  Future<void> _delete(SavedScan scan) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Delete scan?'),
          content: Text('Remove ${scan.name} from this iPhone?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !mounted) return;
    try {
      await LidarScanChannel.deleteScan(scan.path);
      _library.remove(scan.path);
      await _library.reload();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Deleted ${scan.name}')),
      );
    } on PlatformException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.message ?? 'Could not delete this scan.')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$error')),
      );
    }
  }

  Future<void> _share(SavedScan scan) async {
    try {
      await LidarScanChannel.shareScan(scan.path);
    } on PlatformException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.message ?? 'Could not share this scan.')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$error')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final scans = _library.scans;
    return Scaffold(
      appBar: AppBar(title: const Text('Spatial Mesh')),
      body: scans.isEmpty
          ? _EmptyLibrary(error: _library.error)
          : RefreshIndicator(
              onRefresh: _library.reload,
              child: ListView.separated(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                itemCount: scans.length,
                separatorBuilder: (context, index) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final scan = scans[index];
                  return Card(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        ListTile(
                          leading: const Icon(Icons.view_in_ar_outlined),
                          title: Text(scan.name),
                          subtitle: Text(
                            '${formatScanTime(scan.modified)} · ${formatScanBytes(scan.bytes)}\nOn this iPhone · Documents/scans',
                          ),
                          isThreeLine: true,
                        ),
                        Align(
                          alignment: Alignment.centerRight,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              TextButton.icon(
                                onPressed: () => unawaited(_delete(scan)),
                                icon: const Icon(Icons.delete_outline),
                                label: const Text('Delete'),
                                style: TextButton.styleFrom(
                                  foregroundColor: Theme.of(context).colorScheme.error,
                                ),
                              ),
                              TextButton.icon(
                                onPressed: () => unawaited(_share(scan)),
                                icon: const Icon(Icons.ios_share),
                                label: const Text('Share'),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
    );
  }
}

class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary({this.error});

  final String? error;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.view_in_ar_outlined,
                size: 64,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 16),
              Text(
                'No scans yet',
                style: Theme.of(context).textTheme.headlineSmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'Tap Done on the Scan tab to save a mesh on this iPhone. Saved scans can be shared or deleted.',
                style: Theme.of(context).textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
              if (error != null) ...[
                const SizedBox(height: 12),
                Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                  textAlign: TextAlign.center,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
