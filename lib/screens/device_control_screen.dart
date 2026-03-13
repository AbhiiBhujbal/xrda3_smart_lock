import 'package:flutter/material.dart';
import 'package:tuya_flutter_ha_sdk/tuya_flutter_ha_sdk.dart';

class DeviceControlScreen extends StatefulWidget {
  final String devId;
  final String deviceName;

  const DeviceControlScreen({
    super.key,
    required this.devId,
    required this.deviceName,
  });

  @override
  State<DeviceControlScreen> createState() => _DeviceControlScreenState();
}

class _DeviceControlScreenState extends State<DeviceControlScreen> {
  Map<String, dynamic>? _deviceInfo;
  bool _loading = true;
  String? _wifiStrength;

  @override
  void initState() {
    super.initState();
    print("DeviceControl opened for device: ${widget.devId}");

    _initDevice();
  }

  Future<void> _initDevice() async {
    setState(() => _loading = true);
    try {
      await TuyaFlutterHaSdk.initDevice(devId: widget.devId);
      final info = await TuyaFlutterHaSdk.queryDeviceInfo(
        devId: widget.devId,
        dps: [],
      );
      setState(() {
        _deviceInfo = info is Map<String, dynamic> ? info : null;
        _loading = false;
      });
    } catch (e) {
      _showSnackBar('Failed to init device: $e');
      setState(() => _loading = false);
    }
  }

  Future<void> _queryWifiStrength() async {
    try {
      final strength = await TuyaFlutterHaSdk.queryDeviceWiFiStrength(
        devId: widget.devId,
      );
      setState(() => _wifiStrength = strength);
    } catch (e) {
      _showSnackBar('WiFi query failed: $e');
    }
  }

  Future<void> _renameDevice() async {
    final controller = TextEditingController(text: widget.deviceName);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename Device'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(labelText: 'New Name'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;

    try {
      await TuyaFlutterHaSdk.renameDevice(devId: widget.devId, name: name);
      _showSnackBar('Device renamed');
    } catch (e) {
      _showSnackBar('Rename failed: $e');
    }
  }

  Future<void> _factoryReset() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Factory Reset'),
        content: const Text('This will restore the device to factory defaults. Continue?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    try {
      await TuyaFlutterHaSdk.restoreFactoryDefaults(devId: widget.devId);
      _showSnackBar('Factory reset successful');
      if (mounted) Navigator.pop(context);
    } catch (e) {
      _showSnackBar('Factory reset failed: $e');
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

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.deviceName),
        actions: [
          PopupMenuButton(
            itemBuilder: (ctx) => [
              const PopupMenuItem(value: 'rename', child: Text('Rename')),
              const PopupMenuItem(value: 'reset', child: Text('Factory Reset')),
            ],
            onSelected: (value) {
              if (value == 'rename') _renameDevice();
              if (value == 'reset') _factoryReset();
            },
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // Device info card
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Device Info',
                            style: Theme.of(context).textTheme.titleMedium),
                        const Divider(),
                        _InfoRow(label: 'Device ID', value: widget.devId),
                        if (_deviceInfo != null) ...[
                          _InfoRow(
                            label: 'Online',
                            value: '${_deviceInfo!['isOnline'] ?? 'N/A'}',
                          ),
                          _InfoRow(
                            label: 'Category',
                            value: '${_deviceInfo!['category'] ?? 'N/A'}',
                          ),
                          _InfoRow(
                            label: 'Product ID',
                            value: '${_deviceInfo!['productId'] ?? 'N/A'}',
                          ),
                        ],
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 12),

                // DPS (Data Points) card
                if (_deviceInfo?['dps'] != null)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Data Points (DPS)',
                              style: Theme.of(context).textTheme.titleMedium),
                          const Divider(),
                          ...(_deviceInfo!['dps'] as Map<String, dynamic>? ?? {})
                              .entries
                              .map(
                                (e) => _DpsControl(
                                  dpId: e.key,
                                  value: e.value,
                                  devId: widget.devId,
                                  onChanged: _initDevice,
                                ),
                              ),
                        ],
                      ),
                    ),
                  ),

                const SizedBox(height: 12),

                // Actions
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Actions',
                            style: Theme.of(context).textTheme.titleMedium),
                        const Divider(),
                        ListTile(
                          leading: Icon(Icons.wifi, color: cs.primary),
                          title: const Text('Check WiFi Strength'),
                          subtitle: _wifiStrength != null
                              ? Text('Signal: $_wifiStrength')
                              : null,
                          onTap: _queryWifiStrength,
                        ),
                        ListTile(
                          leading: Icon(Icons.devices, color: cs.secondary),
                          title: const Text('Query Sub-Devices'),
                          onTap: () async {
                            try {
                              final subs = await TuyaFlutterHaSdk
                                  .querySubDeviceList(devId: widget.devId);
                              _showSnackBar('Sub-devices: $subs');
                            } catch (e) {
                              _showSnackBar('Error: $e');
                            }
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(label, style: const TextStyle(fontWeight: FontWeight.w500)),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}

class _DpsControl extends StatelessWidget {
  final String dpId;
  final dynamic value;
  final String devId;
  final VoidCallback onChanged;

  const _DpsControl({
    required this.dpId,
    required this.value,
    required this.devId,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    if (value is bool) {
      return SwitchListTile(
        title: Text('DP $dpId'),
        subtitle: Text(value ? 'ON' : 'OFF'),
        value: value,
        onChanged: (newVal) async {
          try {
            // Send DPS command to the device
            await TuyaFlutterHaSdk.controlMatter(
              devId: devId,
              dps: {dpId: newVal},
            );
            onChanged();
          } catch (e) {
            debugPrint('DP control error: $e');
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Failed to set DP $dpId: $e')),
            );
          }
        },
      );
    }

    if (value is int || value is double) {
      return ListTile(
        title: Text('DP $dpId'),
        trailing: Text('$value',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
      );
    }

    return ListTile(
      title: Text('DP $dpId'),
      trailing: Text('$value'),
    );
  }
}
