import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tuya_flutter_ha_sdk/tuya_flutter_ha_sdk.dart';

/// Dedicated lock control screen.
/// Shows lock status, BLE lock/unlock, WiFi lock/unlock, dynamic password.
class SmartLockScreen extends StatefulWidget {
  final String devId;
  final String deviceName;
  final int? homeId;

  const SmartLockScreen({
    super.key,
    required this.devId,
    required this.deviceName,
    this.homeId,
  });

  @override
  State<SmartLockScreen> createState() => _SmartLockScreenState();
}

class _SmartLockScreenState extends State<SmartLockScreen> {
  Map<String, dynamic>? _deviceInfo;
  Map<String, dynamic> _dps = {};
  bool _loading = true;
  bool _actionLoading = false;
  bool _isMatter = false;
  Timer? _refreshTimer;
  StreamSubscription? _dpEventSub;

  @override
  void initState() {
    super.initState();

    print("SmartLockScreen opened for device: ${widget.devId}");

    // The native plugin sends DP updates through the pairingEvents channel
    // (there is no separate deviceEvents channel in the native layer).
    // DP updates arrive as strings: "onDpUpdate:{...}"
    // Pairing events arrive as Maps — we filter for DP strings only here.
    const EventChannel dpEventChannel =
        EventChannel('tuya_flutter_ha_sdk/pairingEvents');
    _dpEventSub = dpEventChannel.receiveBroadcastStream().listen((event) {
      debugPrint("PairingChannel Event: $event");

      if (event is String && event.startsWith("onDpUpdate:")) {
        final jsonStr = event.replaceFirst("onDpUpdate:", "");
        try {
          final Map<String, dynamic> dpData =
              Map<String, dynamic>.from(jsonDecode(jsonStr));
          if (mounted) {
            setState(() {
              _dps.addAll(dpData);
            });
          }
          debugPrint("DPS Updated: $_dps");
        } catch (e) {
          debugPrint("Failed to parse DP update: $e");
        }
      }
    }, onError: (error) {
      debugPrint("DP event stream error: $error");
    });
    _initAndLoad();
  }


  Future<void> _initAndLoad() async {
    setState(() => _loading = true);

    try {
      // Step 1: Pre-load home data so the SDK caches member info
      // This is critical for BLE unlock — without it, getCurrentMemberDetail
      // returns lockUserId=0 and BLE auth fails with timeout.
      if (widget.homeId != null) {
        debugPrint("Step 0 → loading home devices for homeId: ${widget.homeId}");
        await TuyaFlutterHaSdk.getHomeDevices(homeId: widget.homeId!);
        debugPrint("Step 0 → home devices loaded (member cache populated)");
      }

      debugPrint("Step 1 → initDevice");
      await TuyaFlutterHaSdk.initDevice(devId: widget.devId);
      debugPrint("Step 2 → device initialized");

      await _refreshStatus();
    } catch (e) {
      debugPrint("initDevice error: $e");
    }

    if (!mounted) return;
    setState(() => _loading = false);
  }


  Future<void> _refreshStatus() async {
    try {
      debugPrint("Fetching device info...");

      // queryDeviceInfo only calls getDpList and returns null on success,
      // so we use getHomeDevices to get full device metadata (online status,
      // category, DPs, etc.) from the SDK's cached DeviceBean.
      if (widget.homeId != null) {
        final devices =
            await TuyaFlutterHaSdk.getHomeDevices(homeId: widget.homeId!);
        if (devices != null) {
          final devList = List<Map<String, dynamic>>.from(
            devices.map((d) => Map<String, dynamic>.from(d as Map)),
          );
          final match = devList.where((d) => d['devId'] == widget.devId);
          if (match.isNotEmpty && mounted) {
            final info = match.first;
            debugPrint("Device info from home: $info");
            setState(() {
              _deviceInfo = info;
              if (info['dps'] != null) {
                _dps = Map<String, dynamic>.from(info['dps'] as Map);
              }
            });
            return;
          }
        }
      }

      // Fallback: try queryDeviceInfo (may return null on success)
      final info = await TuyaFlutterHaSdk.queryDeviceInfo(
        devId: widget.devId,
        dps: [],
      );
      debugPrint("Device info (queryDeviceInfo): $info");
      if (info != null && mounted) {
        setState(() {
          _deviceInfo = info;
          _dps = Map<String, dynamic>.from(info['dps'] ?? {});
        });
      }
    } catch (e) {
      debugPrint('Refresh lock status error: $e');
    }
  }

  /// Determine if the lock is currently locked based on DPS values.
  /// Common Tuya lock DPS:
  ///   dp 1 = switch / motor state (bool)
  ///   dp 47 = lock state (bool: true=locked)
  ///   dp 8 = open from inside

  bool? get _isLocked {
    debugPrint("Checking lock state from DPS: $_dps");

    // First check DP47 (some locks use this)
    if (_dps.containsKey('47')) {
      debugPrint("Using DP47 for lock state: ${_dps['47']}");
      return _dps['47'] == true;
    }

    // Most Tuya locks use DP1
    if (_dps.containsKey('1')) {
      debugPrint("Using DP1 for lock state: ${_dps['1']}");
      return _dps['1'] == 0; // 0 = locked, 1 = unlocked
    }

    debugPrint("Lock state unknown");
    return null;
  }

  bool get _isOnline => _deviceInfo?['isOnline'] == true;

  // ── BLE Lock Controls ──
  Future<void> _unlockBLE() async {
    setState(() => _actionLoading = true);

    try {
      debugPrint("Sending BLE unlock command...");

      // Re-load home data before BLE unlock to ensure member cache is fresh.
      // The Tuya SDK's getCurrentMemberDetail needs this to return a valid
      // lockUserId (otherwise it returns 0 and bleUnlock times out).
      if (widget.homeId != null) {
        debugPrint("Pre-loading home data for BLE auth...");
        await TuyaFlutterHaSdk.getHomeDevices(homeId: widget.homeId!);
      }

      await TuyaFlutterHaSdk.unlockBLELock(devId: widget.devId);

      _showSnackBar('Lock opened via BLE');
      await Future.delayed(const Duration(seconds: 2));
      await _refreshStatus();
    } catch (e) {
      final errStr = e.toString();
      debugPrint("BLE unlock failed: $errStr");

      if (errStr.contains('Empty key') ||
          errStr.contains('SecretKeySpec')) {
        // Security AAR can't derive BLE encryption keys — SHA256 mismatch
        _showSnackBar(
          'BLE security error. Verify your keystore SHA256 is '
          'registered on the Tuya platform.',
        );
      } else if (errStr.contains('time out') ||
          errStr.contains('10204') ||
          errStr.contains('User ID') && errStr.contains('0')) {
        debugPrint("BLE unlock timed out, retrying after re-init...");
        _showSnackBar('Retrying BLE unlock...');
        try {
          await TuyaFlutterHaSdk.initDevice(devId: widget.devId);
          await Future.delayed(const Duration(seconds: 1));
          await TuyaFlutterHaSdk.unlockBLELock(devId: widget.devId);
          _showSnackBar('Lock opened via BLE');
          await Future.delayed(const Duration(seconds: 2));
          await _refreshStatus();
        } catch (retryError) {
          debugPrint("BLE unlock retry failed: $retryError");
          _showSnackBar(
            'BLE unlock failed. Make sure you are near the lock '
            'and Bluetooth is enabled. If the issue persists, '
            'verify SHA256 is registered on Tuya platform.',
          );
        }
      } else {
        _showSnackBar('BLE unlock failed: $e');
      }
    }

    if (mounted) setState(() => _actionLoading = false);
  }

  Future<void> _lockBLE() async {
    setState(() => _actionLoading = true);
    try {
      debugPrint("Sending BLE lock command...");

      if (widget.homeId != null) {
        await TuyaFlutterHaSdk.getHomeDevices(homeId: widget.homeId!);
      }

      await TuyaFlutterHaSdk.lockBLELock(devId: widget.devId);
      _showSnackBar('Lock closed via BLE');
      await Future.delayed(const Duration(seconds: 2));
      await _refreshStatus();
    } catch (e) {
      debugPrint("BLE lock failed: $e");
      if (e.toString().contains('time out') || e.toString().contains('10204')) {
        _showSnackBar(
          'BLE lock failed. Make sure you are near the lock '
          'and Bluetooth is enabled.',
        );
      } else {
        _showSnackBar('Lock failed: $e');
      }
    }
    if (mounted) setState(() => _actionLoading = false);
  }

  // ── WiFi Lock Controls ──
  Future<void> _wifiUnlock() async {
    if (!_isOnline) {
      _showSnackBar(
        'Device is offline. WiFi unlock requires cloud connection.',
      );
      return;
    }

    setState(() => _actionLoading = true);
    try {
      debugPrint("Sending WiFi unlock command via publishDps...");
      // Send DP command to unlock via cloud (DP 1 = switch/motor)
      await TuyaFlutterHaSdk.controlMatter(
        devId: widget.devId,
        dps: {'1': true},
      );
      _showSnackBar('Unlock command sent via WiFi');
      await Future.delayed(const Duration(seconds: 2));
      await _refreshStatus();
    } catch (e) {
      debugPrint("WiFi unlock failed: $e");
      _showSnackBar('WiFi unlock failed: $e');
    }
    if (mounted) setState(() => _actionLoading = false);
  }

  Future<void> _wifiLock() async {
    if (!_isOnline) {
      _showSnackBar(
        'Device is offline. WiFi lock requires cloud connection.',
      );
      return;
    }

    setState(() => _actionLoading = true);
    try {
      debugPrint("Sending WiFi lock command via publishDps...");
      await TuyaFlutterHaSdk.controlMatter(
        devId: widget.devId,
        dps: {'1': false},
      );
      _showSnackBar('Lock command sent via WiFi');
      await Future.delayed(const Duration(seconds: 2));
      await _refreshStatus();
    } catch (e) {
      debugPrint("WiFi lock failed: $e");
      _showSnackBar('WiFi lock failed: $e');
    }
    if (mounted) setState(() => _actionLoading = false);
  }

  Future<void> _getDynamicPassword() async {
    try {
      final password = await TuyaFlutterHaSdk.dynamicWifiLockPassword(
        devId: widget.devId,
      );
      debugPrint("Dynamic password generated: $password");
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Dynamic Password'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Enter this password on the lock keypad:'),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: SelectableText(
                  password.toString(),
                  style: TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.onPrimaryContainer,
                    letterSpacing: 4,
                  ),
                ),
              ),
            ],
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Done'),
            ),
          ],
        ),
      );
    } catch (e) {
      _showSnackBar('Failed to get password: $e');
    }
  }

  // ── DPS Control (for sending raw DP commands) ──
  Future<void> _sendDps(String dpId, dynamic value) async {
    setState(() => _actionLoading = true);
    try {
      await TuyaFlutterHaSdk.controlMatter(
        devId: widget.devId,
        dps: {dpId: value},
      );
      debugPrint("Sending DPS command -> DP:$dpId Value:$value");
      _showSnackBar('Command sent (DP $dpId = $value)');
      await Future.delayed(const Duration(seconds: 1));
      await _refreshStatus();
    } catch (e) {
      _showSnackBar('Command failed: $e');
    }
    if (mounted) setState(() => _actionLoading = false);
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _dpEventSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final locked = _isLocked;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.deviceName),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _refreshStatus,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _refreshStatus,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  // ── Status card ──
                  Card(
                    color: _isOnline
                        ? (locked == true
                            ? cs.primaryContainer
                            : cs.errorContainer)
                        : cs.surfaceContainerHighest,
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        children: [
                          Icon(
                            locked == true
                                ? Icons.lock
                                : locked == false
                                    ? Icons.lock_open
                                    : Icons.lock_outline,
                            size: 80,
                            color: _isOnline
                                ? (locked == true
                                    ? cs.onPrimaryContainer
                                    : cs.onErrorContainer)
                                : cs.onSurfaceVariant,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            locked == true
                                ? 'LOCKED'
                                : locked == false
                                    ? 'UNLOCKED'
                                    : 'STATUS UNKNOWN',
                            style: Theme.of(context)
                                .textTheme
                                .headlineSmall
                                ?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: _isOnline
                                      ? (locked == true
                                          ? cs.onPrimaryContainer
                                          : cs.onErrorContainer)
                                      : cs.onSurfaceVariant,
                                ),
                          ),
                          const SizedBox(height: 4),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Container(
                                width: 10,
                                height: 10,
                                decoration: BoxDecoration(
                                  color: _isOnline
                                      ? Colors.green
                                      : Colors.grey,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                _isOnline ? 'Online' : 'Offline',
                                style: TextStyle(
                                    color: _isOnline
                                        ? Colors.green
                                        : Colors.grey),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),

                  if (_isMatter)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Card(
                        color: cs.tertiaryContainer,
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Row(
                            children: [
                              Icon(Icons.info_outline,
                                  color: cs.onTertiaryContainer),
                              const SizedBox(width: 8),
                              Text('Matter-enabled device',
                                  style: TextStyle(
                                      color: cs.onTertiaryContainer)),
                            ],
                          ),
                        ),
                      ),
                    ),

                  const SizedBox(height: 16),

                  // ── WiFi Lock Controls ──
                  Text('Lock Control',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 4),
                  if (!_isOnline)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        'Device is offline — controls unavailable',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: cs.error,
                            ),
                      ),
                    ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed:
                              (_actionLoading || !_isOnline) ? null : _wifiUnlock,
                          icon: const Icon(Icons.lock_open),
                          label: const Text('Unlock'),
                          style: FilledButton.styleFrom(
                            minimumSize: const Size(0, 48),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed:
                              (_actionLoading || !_isOnline) ? null : _wifiLock,
                          icon: const Icon(Icons.lock),
                          label: const Text('Lock'),
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(0, 48),
                          ),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 24),

                  // ── Dynamic Password ──
                  Text('Dynamic Password',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Generate a one-time password to unlock via the lock keypad.',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: cs.onSurfaceVariant,
                                ),
                          ),
                          const SizedBox(height: 12),
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton.tonalIcon(
                              onPressed: (_actionLoading || !_isOnline)
                                  ? null
                                  : _getDynamicPassword,
                              icon: const Icon(Icons.password),
                              label: const Text('Generate Password'),
                              style: FilledButton.styleFrom(
                                minimumSize: const Size(0, 48),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  // ── DPS raw data ──
                  if (_dps.isNotEmpty) ...[
                    const SizedBox(height: 24),
                    Text('Device Data Points',
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          children: _dps.entries.map((entry) {
                            return _buildDpRow(entry.key, entry.value);
                          }).toList(),
                        ),
                      ),
                    ),
                  ],

                  if (_actionLoading)
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Center(child: CircularProgressIndicator()),
                    ),

                  // ── Device info ──
                  const SizedBox(height: 24),
                  Text('Device Info',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _infoRow('Device ID', widget.devId),
                          _infoRow('Category',
                              _deviceInfo?['category']?.toString() ?? 'N/A'),
                          _infoRow('Product ID',
                              _deviceInfo?['productId']?.toString() ?? 'N/A'),
                          _infoRow(
                              'Online', _isOnline ? 'Yes' : 'No'),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _buildDpRow(String dpId, dynamic value) {
    if (value is bool) {
      return SwitchListTile(
        title: Text('DP $dpId'),
        subtitle: Text(value ? 'ON' : 'OFF'),
        value: value,
        onChanged: _actionLoading
            ? null
            : (newVal) => _sendDps(dpId, newVal),
      );
    }
    return ListTile(
      title: Text('DP $dpId'),
      trailing: Text('$value', style: const TextStyle(fontSize: 16)),
      dense: true,
    );
  }

  Widget _infoRow(String label, String value) {
    debugPrint("$label : $value");
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 90,
            child: Text(label,
                style: const TextStyle(fontWeight: FontWeight.w500)),
          ),
          Expanded(
            child: Text(value,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ),
        ],
      ),
    );
  }
}
