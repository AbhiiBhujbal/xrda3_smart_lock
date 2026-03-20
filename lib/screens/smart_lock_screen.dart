import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tuya_flutter_ha_sdk/tuya_flutter_ha_sdk.dart';

/// Dedicated lock control screen.
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
  static const _lockExtras =
  MethodChannel('xrda3_smart_lock/lock_extras');

  Map<String, dynamic>? _deviceInfo;
  Map<String, dynamic> _dps = {};
  bool _loading = true;
  bool _actionLoading = false;
  Timer? _refreshTimer;

  // Recent lock events (alarms, unlock events) from DP updates
  final List<_LockEvent> _recentEvents = [];
  StreamSubscription? _dpEventSub;

  // Unlock history from cloud
  List<Map<String, dynamic>> _unlockHistory = [];
  bool _historyLoading = false;

  // BLE connection status
  bool _bleConnected = false;

  @override
  void initState() {
    super.initState();

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
              _processLockEvents(dpData);
            });
          }
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
      if (widget.homeId != null) {
        await TuyaFlutterHaSdk.getHomeDevices(homeId: widget.homeId!);
      }
      await TuyaFlutterHaSdk.initDevice(devId: widget.devId);
      await _refreshStatus();
      _checkBleStatus();
      _loadUnlockHistory();
    } catch (e) {
      debugPrint("initDevice error: $e");
    }

    if (!mounted) return;
    setState(() => _loading = false);
  }

  Future<void> _refreshStatus() async {
    try {
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

      final info = await TuyaFlutterHaSdk.queryDeviceInfo(
        devId: widget.devId,
        dps: [],
      );
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

  Future<void> _checkBleStatus() async {
    try {
      final connected = await _lockExtras.invokeMethod<bool>(
        'isBLEConnected',
        {'devId': widget.devId},
      );
      if (mounted) setState(() => _bleConnected = connected ?? false);
    } catch (_) {}
  }

  Future<void> _loadUnlockHistory() async {
    setState(() => _historyLoading = true);
    try {
      final result = await _lockExtras.invokeMethod<Map>(
        'getUnlockRecordsBLE',
        {'devId': widget.devId, 'offset': 0, 'limit': 20},
      );
      if (result != null && mounted) {
        final records = (result['records'] as List?)
            ?.map((r) => Map<String, dynamic>.from(r as Map))
            .toList() ??
            [];
        setState(() => _unlockHistory = records);
      }
    } catch (e) {
      debugPrint("Unlock history error: $e");
    }
    if (mounted) setState(() => _historyLoading = false);
  }

  // ── Lock State ──
  bool? get _isLocked {
    if (_dps.containsKey('18')) {
      final raw = _dps['18'];
      final state = raw?.toString().toLowerCase().trim();
      if (raw is bool) return raw;
      if (state == 'closed' || state == 'true' || state == '1') return true;
      if (state == 'opened' || state == 'false' || state == '0') return false;
      return null;
    }
    if (_dps.containsKey('47')) return _dps['47'] == true;
    return null;
  }

  String get _lastUnlockMethod {
    final val = _dps['1'];
    if (val == null) return 'Unknown';
    switch (val.toString()) {
      case '1': return 'Fingerprint';
      case '2': return 'Password';
      case '3': return 'Card';
      case '4': return 'Key';
      case '5': return 'Remote';
      case '6': return 'Face';
      default: return 'Method $val';
    }
  }

  bool get _isOnline => _deviceInfo?['isOnline'] == true;

  // ── Event Processing ──
  void _processLockEvents(Map<String, dynamic> dpData) {
    final now = DateTime.now();

    if (dpData.containsKey('8')) {
      final alarm = dpData['8'].toString();
      _recentEvents.insert(0, _LockEvent(
        time: now,
        type: _LockEventType.alarm,
        title: _alarmTitle(alarm),
        detail: alarm,
      ));
    }

    if (dpData.containsKey('18')) {
      final raw = dpData['18'];
      final state = raw.toString().toLowerCase().trim();
      final isLocked = (raw == true) ||
          state == 'closed' ||
          state == 'true' ||
          state == '1';
      _recentEvents.insert(0, _LockEvent(
        time: now,
        type: isLocked ? _LockEventType.locked : _LockEventType.unlocked,
        title: isLocked ? 'Door Locked' : 'Door Unlocked',
        detail: state,
      ));
    }

    if (dpData.containsKey('1') && !dpData.containsKey('18')) {
      final method = dpData['1'].toString();
      _recentEvents.insert(0, _LockEvent(
        time: now,
        type: _LockEventType.unlocked,
        title: 'Unlocked via ${_unlockMethodName(method)}',
        detail: method,
      ));
    }

    if (_recentEvents.length > 20) {
      _recentEvents.removeRange(20, _recentEvents.length);
    }
  }

  String _alarmTitle(String alarm) {
    switch (alarm) {
      case 'wrong_finger': return 'Wrong Fingerprint';
      case 'wrong_password': return 'Wrong Password';
      case 'wrong_card': return 'Wrong Card';
      case 'wrong_face': return 'Wrong Face';
      case 'tongue_bad': return 'Bolt Stuck';
      case 'too_hot': return 'High Temperature';
      case 'unclosed_time': return 'Door Unclosed Timeout';
      case 'tongue_not_out': return 'Bolt Not Ejected';
      case 'pry': return 'Anti-Pry Alert';
      case 'key_in': return 'Key Inserted';
      case 'low_battery': return 'Low Battery';
      case 'power_off': return 'Battery Exhausted';
      case 'shock': return 'Vibration Detected';
      case 'defense': return 'Defense Mode';
      case 'stay_alarm': return 'Stay Alarm';
      case 'doorbell': return 'Doorbell';
      default: return 'Alert: $alarm';
    }
  }

  String _unlockMethodName(String val) {
    switch (val) {
      case '1': return 'Fingerprint';
      case '2': return 'Password';
      case '3': return 'Card';
      case '4': return 'Key';
      case '5': return 'Remote';
      case '6': return 'Face';
      default: return 'Method $val';
    }
  }

  // ── BLE Lock Controls ──
  Future<void> _unlockBLE() async {
    setState(() => _actionLoading = true);
    try {
      if (widget.homeId != null) {
        await TuyaFlutterHaSdk.getHomeDevices(homeId: widget.homeId!);
      }
      await TuyaFlutterHaSdk.unlockBLELock(devId: widget.devId);
      _showSnackBar('Lock opened via BLE');
      await Future.delayed(const Duration(seconds: 2));
      await _refreshStatus();
    } catch (e) {
      final errStr = e.toString();
      if (errStr.contains('Empty key') || errStr.contains('SecretKeySpec')) {
        _showSnackBar('BLE security error — verify SHA256 on Tuya platform.');
      } else {
        _showSnackBar('BLE unlock failed: $e');
      }
    }
    if (mounted) setState(() => _actionLoading = false);
  }

  Future<void> _lockBLE() async {
    setState(() => _actionLoading = true);
    try {
      if (widget.homeId != null) {
        await TuyaFlutterHaSdk.getHomeDevices(homeId: widget.homeId!);
      }
      await TuyaFlutterHaSdk.lockBLELock(devId: widget.devId);
      _showSnackBar('Lock closed via BLE');
      await Future.delayed(const Duration(seconds: 2));
      await _refreshStatus();
    } catch (e) {
      _showSnackBar('BLE lock failed: $e');
    }
    if (mounted) setState(() => _actionLoading = false);
  }

  // ── WiFi Remote Unlock ──
  Future<void> _wifiRemoteUnlock() async {
    if (!_isOnline) {
      _showSnackBar('Device is offline.');
      return;
    }
    setState(() => _actionLoading = true);
    try {
      await TuyaFlutterHaSdk.replyRequestUnlock(
          devId: widget.devId, open: true);
      _showSnackBar('Remote unlock approved');
      await Future.delayed(const Duration(seconds: 2));
      await _refreshStatus();
    } catch (e) {
      final errStr = e.toString();
      if (errStr.contains('OPERATE_NOT_SUPPORTED') ||
          errStr.contains('no remote')) {
        _showSnackBar('No pending unlock request from the lock.');
      } else {
        _showSnackBar('Remote unlock failed: $e');
      }
    }
    if (mounted) setState(() => _actionLoading = false);
  }

  Future<void> _wifiRemoteDeny() async {
    if (!_isOnline) return;
    setState(() => _actionLoading = true);
    try {
      await TuyaFlutterHaSdk.replyRequestUnlock(
          devId: widget.devId, open: false);
      _showSnackBar('Remote unlock denied');
    } catch (e) {
      _showSnackBar('Failed: $e');
    }
    if (mounted) setState(() => _actionLoading = false);
  }

  // ── Dynamic Password (OTP) ──
  Future<void> _getDynamicPassword() async {
    setState(() => _actionLoading = true);
    String? password;
    String source = 'BLE';

    try {
      password = await _lockExtras.invokeMethod<String>(
          'getDynamicPasswordBLE', {'devId': widget.devId});
    } catch (e) {
      debugPrint("BLE dynamic password failed: $e");
    }

    if (password == null || password.isEmpty) {
      try {
        source = 'WiFi';
        final wifiPwd = await TuyaFlutterHaSdk.dynamicWifiLockPassword(
            devId: widget.devId);
        password = wifiPwd?.toString();
      } catch (e) {
        debugPrint("WiFi dynamic password failed: $e");
      }
    }

    if (mounted) setState(() => _actionLoading = false);

    if (password != null && password.isNotEmpty && mounted) {
      _showPasswordDialog(
        title: 'Dynamic Password (OTP)',
        password: password,
        subtitle: 'Enter on lock keypad. Valid 5 min. (via $source)',
      );
    } else if (mounted) {
      _showSnackBar('Could not generate OTP. Ensure Bluetooth is on.');
    }
  }

  // ── Offline Temp Password (Single-use) ──
  Future<void> _getOfflineSinglePassword() async {
    setState(() => _actionLoading = true);
    try {
      final result = await _lockExtras.invokeMethod<Map>(
        'createOfflinePasswordBLE',
        {
          'devId': widget.devId,
          'name': 'One-Time Code',
          'type': 'single',
        },
      );
      if (mounted) setState(() => _actionLoading = false);

      if (result != null && result['password'] != null && mounted) {
        _showPasswordDialog(
          title: 'One-Time Password',
          password: result['password'].toString(),
          subtitle: 'Single use only. Share with a guest for one-time access.',
        );
      } else if (mounted) {
        _showSnackBar('Could not generate one-time password.');
      }
    } catch (e) {
      if (mounted) setState(() => _actionLoading = false);
      _showSnackBar('One-time password failed: $e');
    }
  }

  // ── Timed Temp Password (Reusable until expiry) ──
  Future<void> _getTimedTempPassword() async {
    // Let user pick duration
    final hours = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Password Valid For'),
        children: [
          for (final entry in {1: '1 Hour', 6: '6 Hours', 24: '24 Hours', 72: '3 Days'}.entries)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, entry.key),
              child: Text(entry.value),
            ),
        ],
      ),
    );
    if (hours == null) return;

    setState(() => _actionLoading = true);
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      final result = await _lockExtras.invokeMethod<Map>(
        'createOfflinePasswordBLE',
        {
          'devId': widget.devId,
          'name': 'Temp ${hours}h',
          'type': 'multiple',
          'effectiveTime': now,
          'invalidTime': now + (hours * 60 * 60 * 1000),
        },
      );
      if (mounted) setState(() => _actionLoading = false);

      if (result != null && result['password'] != null && mounted) {
        _showPasswordDialog(
          title: 'Timed Password (${hours}h)',
          password: result['password'].toString(),
          subtitle: 'Reusable for $hours hours. Share for guest access.',
        );
      } else if (mounted) {
        _showSnackBar('Could not generate timed password.');
      }
    } catch (e) {
      if (mounted) setState(() => _actionLoading = false);
      _showSnackBar('Timed password failed: $e');
    }
  }

  void _showPasswordDialog({
    required String title,
    required String password,
    required String subtitle,
  }) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(subtitle),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Flexible(
                    child: SelectableText(
                      password,
                      style: TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.onPrimaryContainer,
                        letterSpacing: 4,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(Icons.copy, size: 20),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: password));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Copied!')),
                      );
                    },
                  ),
                ],
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
    final iconUrl = _deviceInfo?['iconUrl']?.toString();

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.deviceName),
        actions: [
          // BLE indicator
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Icon(
              Icons.bluetooth,
              size: 18,
              color: _bleConnected ? Colors.blue : Colors.grey,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loading
                ? null
                : () {
              _refreshStatus();
              _checkBleStatus();
              _loadUnlockHistory();
            },
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
        onRefresh: () async {
          await _refreshStatus();
          _checkBleStatus();
          _loadUnlockHistory();
        },
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // ── Status Card (tappable) ──
            _buildStatusCard(cs, locked, iconUrl),

            const SizedBox(height: 16),

            // ── Quick Actions Row ──
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _actionLoading ? null : _unlockBLE,
                    icon: const Icon(Icons.lock_open, size: 18),
                    label: const Text('Unlock'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 48),
                      backgroundColor: cs.primary,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _actionLoading ? null : _lockBLE,
                    icon: const Icon(Icons.lock, size: 18),
                    label: const Text('Lock'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 48),
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 16),

            // ── OTP & Passwords Section ──
            _buildOtpCard(cs),

            const SizedBox(height: 16),

            // ── WiFi Remote Unlock ──
            _buildWifiCard(cs),

            const SizedBox(height: 16),

            // ── Unlock History ──
            _buildHistoryCard(cs),

            const SizedBox(height: 16),

            // ── Recent Events (real-time) ──
            _buildEventsCard(cs),

            const SizedBox(height: 16),

            // ── Lock Details ──
            _buildDetailsCard(cs, locked),
          ],
        ),
      ),
    );
  }

  // ── Status Card ──
  Widget _buildStatusCard(ColorScheme cs, bool? locked, String? iconUrl) {
    return GestureDetector(
      onTap: _actionLoading
          ? null
          : () {
        if (locked == true) {
          _unlockBLE();
        } else {
          _lockBLE();
        }
      },
      child: Card(
        elevation: 4,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        color: _isOnline
            ? (locked == true ? cs.primaryContainer : cs.errorContainer)
            : cs.surfaceContainerHighest,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 24),
          child: Column(
            children: [
              if (iconUrl != null && iconUrl.isNotEmpty)
                ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Image.network(iconUrl, width: 72, height: 72,
                      fit: BoxFit.contain,
                      errorBuilder: (_, __, ___) => Icon(
                          _lockIcon(locked), size: 72,
                          color: _statusColor(cs, locked))),
                )
              else
                Icon(_lockIcon(locked), size: 72,
                    color: _statusColor(cs, locked)),
              const SizedBox(height: 12),
              Text(
                locked == true
                    ? 'LOCKED'
                    : locked == false
                    ? 'UNLOCKED'
                    : 'STATUS UNKNOWN',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: _statusColor(cs, locked),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _statusDot(_isOnline ? Colors.green : Colors.grey),
                  const SizedBox(width: 6),
                  Text(_isOnline ? 'Online' : 'Offline',
                      style: TextStyle(
                          color: _isOnline ? Colors.green : Colors.grey)),
                  const SizedBox(width: 16),
                  _statusDot(_bleConnected ? Colors.blue : Colors.grey),
                  const SizedBox(width: 6),
                  Text(_bleConnected ? 'BLE On' : 'BLE Off',
                      style: TextStyle(
                          color: _bleConnected ? Colors.blue : Colors.grey)),
                ],
              ),
              if (!_actionLoading) ...[
                const SizedBox(height: 10),
                Text(
                  locked == true ? 'Tap to unlock' : 'Tap to lock',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: _statusColor(cs, locked)?.withAlpha(180),
                  ),
                ),
              ],
              if (_actionLoading)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: SizedBox(width: 24, height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // ── OTP & Password Card ──
  Widget _buildOtpCard(ColorScheme cs) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.vpn_key, color: cs.primary, size: 20),
                const SizedBox(width: 8),
                Text('Passwords & OTP',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600)),
              ],
            ),
            const SizedBox(height: 12),
            // Dynamic OTP button
            SizedBox(
              width: double.infinity,
              child: FilledButton.tonalIcon(
                onPressed: _actionLoading ? null : _getDynamicPassword,
                icon: const Icon(Icons.password),
                label: const Text('Generate OTP (Dynamic Password)'),
                style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 46)),
              ),
            ),
            const SizedBox(height: 8),
            // One-time and Timed password buttons
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _actionLoading ? null : _getOfflineSinglePassword,
                    icon: const Icon(Icons.looks_one, size: 18),
                    label: const Text('One-Time'),
                    style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 42)),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _actionLoading ? null : _getTimedTempPassword,
                    icon: const Icon(Icons.timer, size: 18),
                    label: const Text('Timed'),
                    style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 42)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'OTP: 5-min code  •  One-Time: single use  •  Timed: reusable for set hours',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: cs.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  // ── WiFi Remote Card ──
  Widget _buildWifiCard(ColorScheme cs) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.wifi, color: cs.primary, size: 20),
                const SizedBox(width: 8),
                Text('WiFi Remote Unlock',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600)),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Press remote unlock on the lock first, then approve here.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: (_actionLoading || !_isOnline)
                        ? null : _wifiRemoteUnlock,
                    icon: const Icon(Icons.check_circle_outline, size: 18),
                    label: const Text('Approve'),
                    style: FilledButton.styleFrom(
                        minimumSize: const Size(0, 44)),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: (_actionLoading || !_isOnline)
                        ? null : _wifiRemoteDeny,
                    icon: const Icon(Icons.block, size: 18),
                    label: const Text('Deny'),
                    style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 44)),
                  ),
                ),
              ],
            ),
            if (!_isOnline)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('Device offline — WiFi unavailable',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: cs.error)),
              ),
          ],
        ),
      ),
    );
  }

  // ── Unlock History Card ──
  Widget _buildHistoryCard(ColorScheme cs) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.history, color: cs.primary, size: 20),
                const SizedBox(width: 8),
                Text('Unlock History',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600)),
                const Spacer(),
                if (_historyLoading)
                  const SizedBox(width: 16, height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                else
                  TextButton(
                    onPressed: _loadUnlockHistory,
                    child: const Text('Refresh'),
                  ),
              ],
            ),
            const Divider(height: 16),
            if (_unlockHistory.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Center(
                  child: Text('No unlock records yet.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant)),
                ),
              ),
            ...(_unlockHistory.take(10).map((r) => _buildHistoryTile(r, cs))),
          ],
        ),
      ),
    );
  }

  Widget _buildHistoryTile(Map<String, dynamic> record, ColorScheme cs) {
    final unlockType = record['unlockType']?.toString() ?? '';
    final unlockName = record['unlockName']?.toString() ?? '';
    final userName = record['userName']?.toString() ?? '';
    final createTime = record['createTime'] as int? ?? 0;
    final time = DateTime.fromMillisecondsSinceEpoch(createTime * 1000);
    final timeStr = '${time.month}/${time.day} ${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

    IconData icon;
    switch (unlockType) {
      case '1': icon = Icons.fingerprint; break;
      case '2': icon = Icons.dialpad; break;
      case '3': icon = Icons.credit_card; break;
      case '4': icon = Icons.key; break;
      case '5': icon = Icons.wifi; break;
      case '6': icon = Icons.face; break;
      default: icon = Icons.lock_open;
    }

    final label = unlockName.isNotEmpty
        ? unlockName
        : _unlockMethodName(unlockType);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 20, color: cs.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: const TextStyle(fontWeight: FontWeight.w500)),
                if (userName.isNotEmpty)
                  Text(userName,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant)),
              ],
            ),
          ),
          Text(timeStr, style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: cs.onSurfaceVariant)),
        ],
      ),
    );
  }

  // ── Events Card (real-time DP updates) ──
  Widget _buildEventsCard(ColorScheme cs) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.notifications_active, color: cs.primary, size: 20),
                const SizedBox(width: 8),
                Text('Live Events',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600)),
                const Spacer(),
                if (_recentEvents.isNotEmpty)
                  TextButton(
                    onPressed: () => setState(() => _recentEvents.clear()),
                    child: const Text('Clear'),
                  ),
              ],
            ),
            const Divider(height: 16),
            if (_dps.containsKey('8'))
              _buildEventTile(
                _LockEvent(
                  time: DateTime.now(),
                  type: _LockEventType.alarm,
                  title: _alarmTitle(_dps['8'].toString()),
                  detail: _dps['8'].toString(),
                ),
                isCurrent: true,
              ),
            if (_recentEvents.isEmpty && !_dps.containsKey('8'))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Center(
                  child: Text(
                    'Events appear here in real-time.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant),
                  ),
                ),
              ),
            ...(_recentEvents.take(10).map((e) => _buildEventTile(e))),
          ],
        ),
      ),
    );
  }

  // ── Lock Details Card ──
  Widget _buildDetailsCard(ColorScheme cs, bool? locked) {
    final mac = _deviceInfo?['mac']?.toString();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.info_outline, color: cs.primary, size: 20),
                const SizedBox(width: 8),
                Text('Lock Details',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600)),
              ],
            ),
            const Divider(height: 20),
            _infoRow('Name', widget.deviceName),
            _infoRow('State',
                locked == true ? 'Closed' : locked == false ? 'Open' : 'Unknown'),
            _infoRow('Last Unlock', _lastUnlockMethod),
            _infoRow('Volume', _dps['11']?.toString() ?? 'Unknown'),
            _infoRow('Child Lock', _dps['17'] == true ? 'On' : 'Off'),
            _infoRow('Auto Lock', _dps['19'] == true ? 'On' : 'Off'),
            if (mac != null && mac.isNotEmpty) _infoRow('MAC', mac),
            _infoRow('Cloud',
                _deviceInfo?['isCloudOnline'] == true ? 'Connected' : 'Disconnected'),
          ],
        ),
      ),
    );
  }

  // ── Helpers ──
  Widget _statusDot(Color color) {
    return Container(
      width: 8, height: 8,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }

  IconData _lockIcon(bool? locked) {
    if (locked == true) return Icons.lock;
    if (locked == false) return Icons.lock_open;
    return Icons.lock_outline;
  }

  Color? _statusColor(ColorScheme cs, bool? locked) {
    if (!_isOnline) return cs.onSurfaceVariant;
    if (locked == true) return cs.onPrimaryContainer;
    return cs.onErrorContainer;
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 80,
            child: Text(label,
                style: TextStyle(
                    fontWeight: FontWeight.w500,
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ),
          Expanded(
            child: Text(value,
                style: const TextStyle(fontWeight: FontWeight.w400)),
          ),
        ],
      ),
    );
  }

  Widget _buildEventTile(_LockEvent event, {bool isCurrent = false}) {
    final cs = Theme.of(context).colorScheme;
    IconData icon;
    Color iconColor;

    switch (event.type) {
      case _LockEventType.alarm:
        icon = Icons.warning_amber_rounded;
        iconColor = cs.error;
        break;
      case _LockEventType.unlocked:
        icon = Icons.lock_open;
        iconColor = Colors.orange;
        break;
      case _LockEventType.locked:
        icon = Icons.lock;
        iconColor = Colors.green;
        break;
    }

    final timeStr = isCurrent
        ? 'Current'
        : '${event.time.hour.toString().padLeft(2, '0')}:'
        '${event.time.minute.toString().padLeft(2, '0')}:'
        '${event.time.second.toString().padLeft(2, '0')}';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 20, color: iconColor),
          const SizedBox(width: 10),
          Expanded(
            child: Text(event.title,
                style: TextStyle(
                  fontWeight: isCurrent ? FontWeight.w600 : FontWeight.w400,
                  color: event.type == _LockEventType.alarm ? cs.error : null,
                )),
          ),
          Text(timeStr,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: cs.onSurfaceVariant)),
        ],
      ),
    );
  }
}

enum _LockEventType { alarm, unlocked, locked }

class _LockEvent {
  final DateTime time;
  final _LockEventType type;
  final String title;
  final String detail;

  _LockEvent({
    required this.time,
    required this.type,
    required this.title,
    required this.detail,
  });
}