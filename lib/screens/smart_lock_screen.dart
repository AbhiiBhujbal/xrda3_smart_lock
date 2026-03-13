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
  static const _lockExtras =
      MethodChannel('xrda3_smart_lock/lock_extras');

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
  /// Smart lock MINI uses DP 18 for lock state: "closed" = locked, "opened" = unlocked.
  /// DP 1 is the unlock method record (enum, read-only), NOT a switch.
  bool? get _isLocked {
    // DP 18 is the lock state for this device
    if (_dps.containsKey('18')) {
      final state = _dps['18']?.toString().toLowerCase();
      debugPrint("Lock state (DP18): $state");
      return state == 'closed';
    }

    // Fallback: DP 47 (some other lock models)
    if (_dps.containsKey('47')) {
      return _dps['47'] == true;
    }

    debugPrint("Lock state unknown");
    return null;
  }

  /// Last unlock method from DP 1 (read-only enum)
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

  /// Volume setting from DP 11
  String get _volumeLevel => _dps['11']?.toString() ?? 'Unknown';

  /// Child lock from DP 17
  bool get _childLock => _dps['17'] == true;

  /// Auto lock from DP 19
  bool get _autoLock => _dps['19'] == true;

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

  // ── WiFi Remote Unlock ──
  // Smart locks use replyRemoteUnlock to RESPOND to a lock-initiated request.
  // The lock must first send a remote unlock request (user presses button on
  // the lock), then the app replies with allow/deny.
  Future<void> _wifiRemoteUnlock() async {
    if (!_isOnline) {
      _showSnackBar('Device is offline.');
      return;
    }

    setState(() => _actionLoading = true);
    try {
      debugPrint("Sending remote unlock reply (allow)...");
      await TuyaFlutterHaSdk.replyRequestUnlock(
        devId: widget.devId,
        open: true,
      );
      _showSnackBar('Remote unlock approved');
      await Future.delayed(const Duration(seconds: 2));
      await _refreshStatus();
    } catch (e) {
      debugPrint("Remote unlock failed: $e");
      final errStr = e.toString();
      if (errStr.contains('OPERATE_NOT_SUPPORTED') ||
          errStr.contains('no remote')) {
        _showSnackBar(
          'No pending unlock request from the lock. '
          'Press the remote unlock button on the lock first.',
        );
      } else {
        _showSnackBar('Remote unlock failed: $e');
      }
    }
    if (mounted) setState(() => _actionLoading = false);
  }

  Future<void> _wifiRemoteDeny() async {
    if (!_isOnline) {
      _showSnackBar('Device is offline.');
      return;
    }

    setState(() => _actionLoading = true);
    try {
      debugPrint("Sending remote unlock reply (deny)...");
      await TuyaFlutterHaSdk.replyRequestUnlock(
        devId: widget.devId,
        open: false,
      );
      _showSnackBar('Remote unlock denied');
    } catch (e) {
      debugPrint("Remote deny failed: $e");
      _showSnackBar('Failed: $e');
    }
    if (mounted) setState(() => _actionLoading = false);
  }

  Future<void> _getDynamicPassword() async {
    setState(() => _actionLoading = true);
    String? password;
    String source = 'BLE';

    // Try BLE dynamic password first (works offline, generated locally)
    try {
      debugPrint("Trying BLE dynamic password...");
      password = await _lockExtras.invokeMethod<String>(
        'getDynamicPasswordBLE',
        {'devId': widget.devId},
      );
      debugPrint("BLE dynamic password: $password");
    } catch (e) {
      debugPrint("BLE dynamic password failed: $e");
    }

    // Fallback to WiFi dynamic password if BLE failed
    if (password == null || password.isEmpty) {
      try {
        debugPrint("Trying WiFi dynamic password...");
        source = 'WiFi';
        final wifiPwd = await TuyaFlutterHaSdk.dynamicWifiLockPassword(
          devId: widget.devId,
        );
        password = wifiPwd?.toString();
        debugPrint("WiFi dynamic password: $password");
      } catch (e) {
        debugPrint("WiFi dynamic password failed: $e");
      }
    }

    if (mounted) setState(() => _actionLoading = false);

    if (password != null && password.isNotEmpty && mounted) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Dynamic Password'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Enter this password on the lock keypad.\n'
                  'Valid for 5 minutes. (via $source)'),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: SelectableText(
                  password,
                  style: TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    color:
                        Theme.of(context).colorScheme.onPrimaryContainer,
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
    } else if (mounted) {
      _showSnackBar(
        'Could not generate dynamic password. '
        'Make sure Bluetooth is on and you are near the lock.',
      );
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
    final iconUrl = _deviceInfo?['iconUrl']?.toString();
    final mac = _deviceInfo?['mac']?.toString();
    final uuid = _deviceInfo?['uuid']?.toString();
    final productId = _deviceInfo?['productId']?.toString();

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
                  // ── Tappable status card ──
                  GestureDetector(
                    onTap: (_actionLoading || !_isOnline)
                        ? null
                        : _wifiRemoteUnlock,
                    child: Card(
                      elevation: 4,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                      color: _isOnline
                          ? (locked == true
                              ? cs.primaryContainer
                              : cs.errorContainer)
                          : cs.surfaceContainerHighest,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            vertical: 32, horizontal: 24),
                        child: Column(
                          children: [
                            // Lock icon image or fallback icon
                            if (iconUrl != null && iconUrl.isNotEmpty)
                              ClipRRect(
                                borderRadius: BorderRadius.circular(16),
                                child: Image.network(
                                  iconUrl,
                                  width: 80,
                                  height: 80,
                                  fit: BoxFit.contain,
                                  errorBuilder: (_, __, ___) => Icon(
                                    _lockIcon(locked),
                                    size: 80,
                                    color: _statusColor(cs, locked),
                                  ),
                                ),
                              )
                            else
                              Icon(
                                _lockIcon(locked),
                                size: 80,
                                color: _statusColor(cs, locked),
                              ),
                            const SizedBox(height: 16),
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
                                    color: _statusColor(cs, locked),
                                  ),
                            ),
                            const SizedBox(height: 8),
                            // Online indicator
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
                                        : Colors.grey,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            // Tap hint
                            if (_isOnline && !_actionLoading)
                              Text(
                                'Tap to approve remote unlock',
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(
                                      color: _statusColor(cs, locked)
                                          ?.withOpacity(0.7),
                                    ),
                              ),
                            if (_actionLoading)
                              const Padding(
                                padding: EdgeInsets.only(top: 4),
                                child: SizedBox(
                                  width: 24,
                                  height: 24,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 16),

                  // ── Remote Unlock / Deny buttons ──
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: (_actionLoading || !_isOnline)
                              ? null
                              : _wifiRemoteUnlock,
                          icon: const Icon(Icons.lock_open),
                          label: const Text('Approve Unlock'),
                          style: FilledButton.styleFrom(
                            minimumSize: const Size(0, 52),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: (_actionLoading || !_isOnline)
                              ? null
                              : _wifiRemoteDeny,
                          icon: const Icon(Icons.block),
                          label: const Text('Deny'),
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(0, 52),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Remote unlock: press the button on the lock first, '
                    'then tap Approve here.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                  ),

                  if (!_isOnline)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        'Device is offline — controls unavailable',
                        textAlign: TextAlign.center,
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: cs.error),
                      ),
                    ),

                  const SizedBox(height: 24),

                  // ── Dynamic Password ──
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.vpn_key,
                                  color: cs.primary, size: 20),
                              const SizedBox(width: 8),
                              Text('Dynamic Password',
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleSmall
                                      ?.copyWith(
                                          fontWeight: FontWeight.w600)),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Generate a one-time password to unlock via '
                            'the lock keypad. Valid for 5 minutes.',
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: cs.onSurfaceVariant),
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

                  const SizedBox(height: 16),

                  // ── Lock Details ──
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.info_outline,
                                  color: cs.primary, size: 20),
                              const SizedBox(width: 8),
                              Text('Lock Details',
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleSmall
                                      ?.copyWith(
                                          fontWeight: FontWeight.w600)),
                            ],
                          ),
                          const Divider(height: 20),
                          _infoRow('Name', widget.deviceName),
                          _infoRow('Lock State',
                              locked == true ? 'Closed' : locked == false ? 'Open' : 'Unknown'),
                          _infoRow('Last Unlock', _lastUnlockMethod),
                          _infoRow('Volume', _volumeLevel),
                          _infoRow('Child Lock', _childLock ? 'On' : 'Off'),
                          _infoRow('Auto Lock', _autoLock ? 'On' : 'Off'),
                          if (mac != null && mac.isNotEmpty)
                            _infoRow('MAC', mac),
                          _infoRow(
                              'Cloud',
                              _deviceInfo?['isCloudOnline'] == true
                                  ? 'Connected'
                                  : 'Disconnected'),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
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
            width: 70,
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
}
