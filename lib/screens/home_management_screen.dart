import 'package:flutter/material.dart';
import 'package:tuya_flutter_ha_sdk/tuya_flutter_ha_sdk.dart';
import '../widgets/location_picker.dart';

class HomeManagementScreen extends StatefulWidget {
  const HomeManagementScreen({super.key});

  @override
  State<HomeManagementScreen> createState() => _HomeManagementScreenState();
}

class _HomeManagementScreenState extends State<HomeManagementScreen> {
  List<Map<String, dynamic>> _homes = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadHomes();
  }

  Future<void> _loadHomes() async {
    setState(() => _loading = true);
    try {
      final homes = await TuyaFlutterHaSdk.getHomeList();
      setState(() {
        _homes = homes;
        _loading = false;
      });
    } catch (e) {
      _showSnackBar('Failed to load homes: $e');
      setState(() => _loading = false);
    }
  }

  Future<void> _createHome() async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => _CreateHomeDialog(),
    );
    if (result == null) return;

    try {
      await TuyaFlutterHaSdk.createHome(
        name: result['name'] as String,
        geoName: (result['geoName'] as String?) ?? '',
        rooms: (result['rooms'] as String?)?.split(',').map((r) => r.trim()).toList() ?? [],
        latitude: (result['latitude'] as double?) ?? 0.0,
        longitude: (result['longitude'] as double?) ?? 0.0,
      );
      _showSnackBar('Home created successfully');
      _loadHomes();
    } catch (e) {
      _showSnackBar('Failed to create home: $e');
    }
  }

  Future<void> _deleteHome(int homeId) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Home'),
        content: const Text('Are you sure you want to delete this home?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirm != true) return;

    try {
      await TuyaFlutterHaSdk.deleteHome(homeId: homeId);
      _showSnackBar('Home deleted');
      _loadHomes();
    } catch (e) {
      _showSnackBar('Failed to delete: $e');
    }
  }

  Future<void> _editHome(Map<String, dynamic> home) async {
    final homeId = home['homeId'] ?? home['id'];
    final nameController = TextEditingController(text: home['name'] ?? '');
    double lat = (home['latitude'] as num?)?.toDouble() ?? 0.0;
    double lng = (home['longitude'] as num?)?.toDouble() ?? 0.0;
    String geoName = home['geoName']?.toString() ?? '';

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit Home'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(labelText: 'Home Name'),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.place),
                label: Text(geoName.isNotEmpty ? geoName : 'Set Location'),
                onPressed: () async {
                  final loc = await showLocationPicker(
                    ctx,
                    lat: lat,
                    lng: lng,
                    geoName: geoName,
                  );
                  if (loc != null) {
                    lat = loc['latitude'] as double;
                    lng = loc['longitude'] as double;
                    geoName = loc['geoName'] as String;
                  }
                },
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
        ],
      ),
    );

    if (result != true) return;

    try {
      await TuyaFlutterHaSdk.updateHomeInfo(
        homeId: homeId,
        homeName: nameController.text,
        geoName: geoName,
        latitude: lat,
        longitude: lng,
      );
      _showSnackBar('Home updated');
      _loadHomes();
    } catch (e) {
      _showSnackBar('Failed to update: $e');
    }
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Home Management')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _createHome,
        icon: const Icon(Icons.add),
        label: const Text('New Home'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _homes.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.home_work_outlined, size: 64, color: Colors.grey.shade400),
                      const SizedBox(height: 16),
                      const Text('No homes yet'),
                      const SizedBox(height: 8),
                      const Text('Tap + to create your first home'),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _loadHomes,
                  child: ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: _homes.length,
                    itemBuilder: (context, index) {
                      final home = _homes[index];
                      final homeId = home['homeId'] ?? home['id'];
                      return Card(
                        child: ListTile(
                          leading: const CircleAvatar(child: Icon(Icons.home)),
                          title: Text(home['name'] ?? 'Home $homeId'),
                          subtitle: Text(home['geoName'] ?? 'ID: $homeId'),
                          trailing: PopupMenuButton(
                            itemBuilder: (ctx) => [
                              const PopupMenuItem(value: 'edit', child: Text('Edit')),
                              const PopupMenuItem(value: 'delete', child: Text('Delete')),
                            ],
                            onSelected: (value) {
                              if (value == 'edit') _editHome(home);
                              if (value == 'delete') _deleteHome(homeId);
                            },
                          ),
                        ),
                      );
                    },
                  ),
                ),
    );
  }
}

class _CreateHomeDialog extends StatefulWidget {
  @override
  State<_CreateHomeDialog> createState() => _CreateHomeDialogState();
}

class _CreateHomeDialogState extends State<_CreateHomeDialog> {
  final _nameController = TextEditingController();
  final _roomsController = TextEditingController();
  String _geoName = '';
  double _lat = 0.0;
  double _lng = 0.0;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Create New Home'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _nameController,
            decoration: const InputDecoration(labelText: 'Home Name'),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              icon: const Icon(Icons.place),
              label: Text(_geoName.isNotEmpty ? _geoName : 'Set Location (optional)'),
              onPressed: () async {
                final loc = await showLocationPicker(
                  context,
                  lat: _lat,
                  lng: _lng,
                  geoName: _geoName,
                );
                if (loc != null) {
                  setState(() {
                    _lat = loc['latitude'] as double;
                    _lng = loc['longitude'] as double;
                    _geoName = loc['geoName'] as String;
                  });
                }
              },
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _roomsController,
            decoration: const InputDecoration(
              labelText: 'Rooms (comma separated)',
              hintText: 'Living Room, Bedroom, Kitchen',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            if (_nameController.text.isEmpty) return;
            Navigator.pop(context, {
              'name': _nameController.text,
              'geoName': _geoName,
              'rooms': _roomsController.text,
              'latitude': _lat,
              'longitude': _lng,
            });
          },
          child: const Text('Create'),
        ),
      ],
    );
  }
}
