import 'package:flutter/material.dart';
import 'package:tuya_flutter_ha_sdk/tuya_flutter_ha_sdk.dart';
import 'device_control_screen.dart';
import 'device_pairing_screen.dart';

class DeviceListScreen extends StatefulWidget {
  final int homeId;
  const DeviceListScreen({super.key, required this.homeId});

  @override
  State<DeviceListScreen> createState() => _DeviceListScreenState();
}

class _DeviceListScreenState extends State<DeviceListScreen> {
  List<Map<String, dynamic>> _devices = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadDevices();
  }

  Future<void> _loadDevices() async {
    setState(() => _loading = true);
    try {
      final devices = await TuyaFlutterHaSdk.getHomeDevices(homeId: widget.homeId);
      setState(() {
        _devices = devices;
        _loading = false;
      });
    } catch (e) {
      _showSnackBar('Failed to load devices: $e');
      setState(() => _loading = false);
    }
  }

  Future<void> _removeDevice(String devId) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove Device'),
        content: const Text('Are you sure you want to remove this device?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
        ],
      ),
    );
    if (confirm != true) return;

    try {
      await TuyaFlutterHaSdk.removeDevice(devId: devId);
      _showSnackBar('Device removed');
      _loadDevices();
    } catch (e) {
      _showSnackBar('Failed to remove: $e');
    }
  }

  IconData _getDeviceIcon(String? category) {
    switch (category?.toLowerCase()) {
      case 'dj': return Icons.lightbulb;
      case 'cz': return Icons.power;
      case 'kg': return Icons.toggle_on;
      case 'cl': return Icons.curtains;
      case 'wk': return Icons.thermostat;
      case 'sp': return Icons.videocam;
      case 'ms': return Icons.lock;
      default: return Icons.devices_other;
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
      appBar: AppBar(title: const Text('Devices')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => DevicePairingScreen(homeId: widget.homeId),
            ),
          );
          _loadDevices();
        },
        icon: const Icon(Icons.add),
        label: const Text('Pair Device'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _devices.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.devices_other, size: 64, color: Colors.grey.shade400),
                      const SizedBox(height: 16),
                      const Text('No devices found'),
                      const SizedBox(height: 8),
                      const Text('Tap + to pair a new device'),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _loadDevices,
                  child: ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: _devices.length,
                    itemBuilder: (context, index) {
                      final device = _devices[index];
                      final devId = device['devId'] ?? device['id'] ?? '';
                      final name = device['name'] ?? 'Device';
                      final isOnline = device['isOnline'] ?? false;
                      final category = device['category'];

                      return Card(
                        child: ListTile(
                          leading: CircleAvatar(
                            child: Icon(_getDeviceIcon(category)),
                          ),
                          title: Text(name),
                          subtitle: Row(
                            children: [
                              Container(
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  color: isOnline ? Colors.green : Colors.grey,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(isOnline ? 'Online' : 'Offline'),
                            ],
                          ),
                          trailing: PopupMenuButton(
                            itemBuilder: (ctx) => [
                              const PopupMenuItem(value: 'control', child: Text('Control')),
                              const PopupMenuItem(value: 'remove', child: Text('Remove')),
                            ],
                            onSelected: (value) {
                              if (value == 'control') {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => DeviceControlScreen(
                                      devId: devId,
                                      deviceName: name,
                                    ),
                                  ),
                                );
                              }
                              if (value == 'remove') _removeDevice(devId);
                            },
                          ),
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => DeviceControlScreen(
                                devId: devId,
                                deviceName: name,
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
    );
  }
}
