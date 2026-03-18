import 'package:flutter/material.dart';
import 'package:tuya_flutter_ha_sdk/tuya_flutter_ha_sdk.dart';
import 'device_control_screen.dart';
import 'device_pairing_screen.dart';
import 'login_screen.dart';
import 'smart_lock_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  dynamic _userInfo;
  List<Map<String, dynamic>> _devices = [];
  int? _homeId;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _loading = true);
    try {
      final user = await TuyaFlutterHaSdk.getCurrentUser();
      final homes = await TuyaFlutterHaSdk.getHomeList();

      int? homeId;
      List<Map<String, dynamic>> devices = [];

      if (homes.isNotEmpty) {
        homeId = homes.first['homeId'] as int? ?? homes.first['id'] as int?;
        if (homeId != null) {
          devices = await TuyaFlutterHaSdk.getHomeDevices(homeId: homeId);
        }
      }

      setState(() {
        _userInfo = user;
        _homeId = homeId;
        _devices = devices;
        _loading = false;
      });
    } catch (e) {
      debugPrint('Load error: $e');
      setState(() => _loading = false);
    }
  }

  Future<void> _logout() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sign Out'),
        content: const Text('Are you sure you want to sign out?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Sign Out')),
        ],
      ),
    );
    if (confirm != true) return;

    try {
      await TuyaFlutterHaSdk.userLogout();
      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const LoginScreen()),
        );
      }
    } catch (e) {
      _showSnackBar('Sign out failed: $e');
    }
  }

  Future<void> _removeDevice(String devId) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove Device'),
        content: const Text('Remove this device from your home?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Remove')),
        ],
      ),
    );
    if (confirm != true) return;

    try {
      await TuyaFlutterHaSdk.removeDevice(devId: devId);
      _showSnackBar('Device removed');
      _loadData();
    } catch (e) {
      _showSnackBar('Failed to remove: $e');
    }
  }

  bool _isLockCategory(String? category) {
    final cat = category?.toLowerCase() ?? '';
    return cat == 'ms' || cat == 'jtmspro' || cat.contains('lock');
  }

  IconData _deviceIcon(String? category) {
    final cat = category?.toLowerCase() ?? '';
    if (_isLockCategory(category)) return Icons.lock_outline;
    switch (cat) {
      case 'dj':
        return Icons.lightbulb_outline;
      case 'cz':
        return Icons.power_outlined;
      case 'kg':
        return Icons.toggle_on_outlined;
      case 'cl':
        return Icons.curtains;
      case 'wk':
        return Icons.thermostat;
      case 'sp':
        return Icons.videocam_outlined;
      default:
        return Icons.devices_other;
    }
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final nickname =
        _userInfo?.nickname ?? _userInfo?.uid ?? 'User';

    return Scaffold(
      appBar: AppBar(
        title: Text('Hi, $nickname'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadData,
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Sign Out',
            onPressed: _logout,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          int? homeId = _homeId;

          // If no home exists yet, create one first
          if (homeId == null) {
            try {
              _showSnackBar('Setting up your home…');
              homeId = await TuyaFlutterHaSdk.createHome(
                name: 'My Home',
                longitude: 0.0,
                latitude: 0.0,
                geoName: '',
                rooms: ['Default Room'],
              );
              setState(() => _homeId = homeId);
            } catch (e) {
              debugPrint('Create home error: $e');
              _showSnackBar('Could not create home: $e');
              return;
            }
          }

          if (!mounted) return;
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => DevicePairingScreen(homeId: homeId!),
            ),
          );
          _loadData();
        },
        icon: const Icon(Icons.add),
        label: const Text('Pair Device'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadData,
              child: _devices.isEmpty
                  ? ListView(
                      children: [
                        const SizedBox(height: 120),
                        Icon(Icons.devices_other,
                            size: 80, color: Colors.grey.shade400),
                        const SizedBox(height: 16),
                        Center(
                          child: Text(
                            'No devices yet',
                            style: Theme.of(context)
                                .textTheme
                                .titleLarge
                                ?.copyWith(color: cs.onSurfaceVariant),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Center(
                          child: Text(
                            'Tap the button below to add your first device',
                            style: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(color: cs.onSurfaceVariant),
                          ),
                        ),
                        const SizedBox(height: 24),
                        Center(
                          child: FilledButton.icon(
                            onPressed: () async {
                              int? homeId = _homeId;
                              if (homeId == null) {
                                try {
                                  _showSnackBar('Setting up your home…');
                                  homeId =
                                      await TuyaFlutterHaSdk.createHome(
                                    name: 'My Home',
                                    longitude: 0.0,
                                    latitude: 0.0,
                                    geoName: '',
                                    rooms: ['Default Room'],
                                  );
                                  setState(() => _homeId = homeId);
                                } catch (e) {
                                  debugPrint('Create home error: $e');
                                  _showSnackBar('Could not create home: $e');
                                  return;
                                }
                              }
                              if (!mounted) return;
                              await Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) =>
                                      DevicePairingScreen(homeId: homeId!),
                                ),
                              );
                              _loadData();
                            },
                            icon: const Icon(Icons.add),
                            label: const Text('Add Device'),
                          ),
                        ),
                      ],
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 80),
                      itemCount: _devices.length + 1, // +1 for header
                      itemBuilder: (context, index) {
                        if (index == 0) {
                          // Header with device count
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Text(
                              '${_devices.length} Device${_devices.length == 1 ? '' : 's'}',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          );
                        }

                        final device = _devices[index - 1];
                        final devId =
                            device['devId']?.toString() ?? device['id']?.toString() ?? '';
                        final name = device['name']?.toString() ?? 'Device';
                        final isOnline = device['isOnline'] == true;
                        final category = device['category']?.toString();

                        return Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          child: ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 4),
                            leading: CircleAvatar(
                              backgroundColor: isOnline
                                  ? cs.primaryContainer
                                  : cs.surfaceContainerHighest,
                              child: Icon(
                                _deviceIcon(category),
                                color: isOnline
                                    ? cs.primary
                                    : cs.onSurfaceVariant,
                              ),
                            ),
                            title: Text(name),
                            subtitle: Row(
                              children: [
                                Container(
                                  width: 8,
                                  height: 8,
                                  decoration: BoxDecoration(
                                    color: isOnline
                                        ? Colors.green
                                        : Colors.grey,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  isOnline ? 'Online' : 'Offline',
                                  style: TextStyle(
                                    color: isOnline
                                        ? Colors.green
                                        : Colors.grey,
                                  ),
                                ),
                              ],
                            ),
                            trailing: IconButton(
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () => _removeDevice(devId),
                            ),
                              onTap: () async {
                                print("Opening lock screen for devId: $devId");
                                print("Device category: $category");
                                print("Device name: $name");

                                final isLock =
                                    (category?.toLowerCase().contains('lock') ?? false) ||
                                        name.toLowerCase().contains('lock');

                                final screen = isLock
                                    ? SmartLockScreen(
                                  devId: devId,
                                  deviceName: name,
                                  homeId: _homeId,
                                )
                                    : DeviceControlScreen(
                                  devId: devId,
                                  deviceName: name,
                                );

                                await Navigator.push(
                                  context,
                                  MaterialPageRoute(builder: (_) => screen),
                                );

                                _loadData();
                              }
                          ),
                        );
                      },
                    ),
            ),
    );
  }
}
