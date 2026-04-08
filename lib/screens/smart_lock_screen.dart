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

class _SmartLockScreenState extends State<SmartLockScreen>
    with WidgetsBindingObserver {
  static const _lockExtras =
      MethodChannel('xrda3_smart_lock/lock_extras');

  Map<String, dynamic>? _deviceInfo;
  Map<String, dynamic> _dps = {};
  bool _loading = true;
  bool _actionLoading = false;
  Timer? _refreshTimer;
  Timer? _bleCheckTimer;

  // Recent lock events (alarms, unlock events) from DP updates
  final List<_LockEvent> _recentEvents = [];
  StreamSubscription? _dpEventSub;

  // Unlock history from cloud
  List<Map<String, dynamic>> _unlockHistory = [];
  bool _historyLoading = false;

  // BLE connection status
  bool _bleConnected = false;

  // Remote unlock request listener
  StreamSubscription? _remoteUnlockSub;
  bool _remoteUnlockEnabled = false;
  int _remoteUnlockCountdown = 0;
  Timer? _countdownTimer;

  // Doorbell debounce — prevent multiple launches
  DateTime? _lastDoorbellLaunch;

  // Grace period: suppress DP-18 auto-relock updates right after user unlock
  DateTime? _unlockGraceUntil;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

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
            // During grace period, ignore ALL lock-state DP updates
            // from the device's auto-lock so the UI stays on "unlocked"
            // until the user explicitly taps Lock.
            if (_unlockGraceUntil != null &&
                DateTime.now().isBefore(_unlockGraceUntil!)) {
              for (final dpKey in _lockStateDps) {
                if (dpData.containsKey(dpKey)) {
                  final raw = dpData[dpKey];
                  final state = raw?.toString().toLowerCase().trim();
                  final isLocking = (raw == true) ||
                      state == 'closed' ||
                      state == 'true' ||
                      state == '1';
                  if (isLocking) {
                    debugPrint("Suppressed auto-relock DP-$dpKey during grace period");
                    dpData.remove(dpKey);
                  }
                }
              }
              if (dpData.isEmpty) return;
            }
            setState(() {
              _dps.addAll(dpData);
              _processLockEvents(dpData);
            });

            // ── Handle doorbell (DP 53) and video (DP 212) events ──
            // IMPORTANT: Only trigger on small DP updates (actual events),
            // NOT on full status dumps (which have 10+ DPs and include stale "53":true).
            final isRealEvent = dpData.length <= 3; // Real events have 1-3 DPs
            if (isRealEvent) {
              if (dpData.containsKey('53') && dpData['53'] == true) {
                _handleDoorbellEvent(dpData);
              } else if (dpData.containsKey('212') &&
                  dpData['212'].toString().isNotEmpty &&
                  dpData['212'].toString() != '') {
                debugPrint('📹 Lock camera event (DP 212)');
                _launchDoorbellCall();
              }
            } else if (dpData.length > 3) {
              debugPrint('Ignoring doorbell in full DP dump (${dpData.length} DPs)');
            }
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

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      _checkBleStatus();
      _refreshStatus();
    }
  }

  Future<void> _initAndLoad() async {
    setState(() => _loading = true);

    try {
      if (widget.homeId != null) {
        await TuyaFlutterHaSdk.getHomeDevices(homeId: widget.homeId!);
      }
      await TuyaFlutterHaSdk.initDevice(devId: widget.devId);
      await _refreshStatus();
      await _checkBleStatus();
      _loadUnlockHistory();
      _registerRemoteUnlockListener();
      _checkRemoteUnlockEnabled();
    } catch (e) {
      debugPrint("initDevice error: $e");
    }

    if (!mounted) return;
    setState(() => _loading = false);

    // Poll BLE status every 5 seconds to keep the indicator accurate
    _bleCheckTimer?.cancel();
    _bleCheckTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _checkBleStatus(),
    );
  }

  /// Register a listener for incoming remote unlock requests from the lock.
  Future<void> _registerRemoteUnlockListener() async {
    try {
      await _lockExtras.invokeMethod(
          'registerRemoteUnlockListener', {'devId': widget.devId});
      debugPrint('Remote unlock listener registered');
    } catch (e) {
      debugPrint('registerRemoteUnlockListener error: $e');
    }

    // Listen for remote unlock events
    _remoteUnlockSub?.cancel();
    const remoteChannel =
        EventChannel('xrda3_smart_lock/remote_unlock_events');
    _remoteUnlockSub =
        remoteChannel.receiveBroadcastStream().listen((event) {
      if (event is Map && event['event'] == 'remote_unlock_request') {
        final countdown = event['countdown'] as int? ?? 30;
        debugPrint('Remote unlock request! Countdown: ${countdown}s');
        if (mounted) {
          _showRemoteUnlockDialog(countdown);
        }
      }
    });
  }

  /// Check if remote unlock is enabled on this lock.
  Future<void> _checkRemoteUnlockEnabled() async {
    try {
      final enabled = await _lockExtras.invokeMethod<bool>(
            'fetchRemoteUnlockEnabled',
            {'devId': widget.devId},
          ) ??
          false;
      if (mounted) setState(() => _remoteUnlockEnabled = enabled);
    } catch (e) {
      debugPrint('checkRemoteUnlockEnabled error: $e');
    }
  }

  /// Show dialog when lock sends a remote unlock request.
  void _showRemoteUnlockDialog(int seconds) {
    _remoteUnlockCountdown = seconds;
    _countdownTimer?.cancel();

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            // Start countdown timer
            _countdownTimer?.cancel();
            _countdownTimer =
                Timer.periodic(const Duration(seconds: 1), (timer) {
              if (_remoteUnlockCountdown <= 0) {
                timer.cancel();
                Navigator.of(ctx, rootNavigator: true).pop();
                _showSnackBar('Remote unlock request expired');
              } else {
                setDialogState(() => _remoteUnlockCountdown--);
              }
            });

            return AlertDialog(
              icon: const Icon(Icons.lock_open, size: 48, color: Colors.orange),
              title: const Text('Remote Unlock Request'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Someone pressed the button on your lock.'),
                  const SizedBox(height: 8),
                  Text(
                    'Approve unlock? (${_remoteUnlockCountdown}s remaining)',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () async {
                    _countdownTimer?.cancel();
                    Navigator.pop(ctx);
                    await _replyRemoteUnlock(false);
                  },
                  child: const Text('Deny'),
                ),
                FilledButton.icon(
                  onPressed: () async {
                    _countdownTimer?.cancel();
                    Navigator.pop(ctx);
                    await _replyRemoteUnlock(true);
                  },
                  icon: const Icon(Icons.lock_open),
                  label: const Text('Approve Unlock'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// Reply to a remote unlock request.
  Future<void> _replyRemoteUnlock(bool allow) async {
    setState(() => _actionLoading = true);
    try {
      await _lockExtras.invokeMethod('replyRemoteUnlock', {
        'devId': widget.devId,
        'allow': allow,
      });
      _showSnackBar(allow ? 'Unlock approved!' : 'Unlock denied');
      if (allow) {
        final dpKey = _lockDpKey;
        setState(() {
          _dps[dpKey] = dpKey == '47' ? false : 'opened';
        });
        _unlockGraceUntil = DateTime.now().add(const Duration(seconds: 30));
      }
    } catch (e) {
      _showSnackBar('Reply failed: $e');
    }
    if (mounted) setState(() => _actionLoading = false);
  }

  Future<void> _refreshStatus() async {
    // During unlock grace period, preserve ALL lock-state DPs
    // so the UI doesn't snap back to "locked" from server data.
    final bool inGracePeriod = _unlockGraceUntil != null &&
        DateTime.now().isBefore(_unlockGraceUntil!);
    final Map<String, dynamic> savedLockDps = {};
    if (inGracePeriod) {
      for (final dp in _lockStateDps) {
        if (_dps.containsKey(dp)) savedLockDps[dp] = _dps[dp];
      }
    }

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
              // Restore lock DPs during grace period to keep "unlocked" state
              if (inGracePeriod) {
                savedLockDps.forEach((k, v) => _dps[k] = v);
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
          if (inGracePeriod) {
            savedLockDps.forEach((k, v) => _dps[k] = v);
          }
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
      final newVal = connected ?? false;
      // Only rebuild if the value actually changed — prevents flicker
      if (mounted && newVal != _bleConnected) {
        setState(() => _bleConnected = newVal);
      }
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

  // ═══════════════════════════════════════════════════════════
  // UNIVERSAL TUYA LOCK DP MAP
  // Supports all known DP versions from oldest to newest.
  // ═══════════════════════════════════════════════════════════

  // Lock state DPs — priority order (first non-empty wins)
  // DP 47: bool  — most common (true=locked, false=unlocked)
  // DP 18: mixed — older models ("closed"/"opened", bool, or "1"/"0")
  // DP 2:  bool  — some basic locks (true=locked)
  // DP 15: bool  — some ZigBee locks
  // DP 36: bool  — some cat-eye locks
  static const _lockStateDps = ['47', '18', '2', '15', '36'];

  // Unlock method DPs
  // DP 1:  unlock record (finger/password/card/key/remote/face)
  // DP 10: unlock record in some newer models
  // DP 5:  unlock method on some models
  static const _unlockMethodDps = ['1', '10', '5'];

  // Alarm DP
  // DP 8:  alarm events (wrong_finger, pry, etc.)
  // DP 21: alarm on some models
  static const _alarmDps = ['8', '21'];

  // Battery DP
  // DP 45: battery percentage (most common)
  // DP 12: battery on some models
  static const _batteryDps = ['45', '12'];

  // Other feature DPs
  // DP 11: volume          DP 17: child lock
  // DP 19: auto-lock       DP 39: lock mode
  // DP 52: anti-lock       DP 53: do-not-disturb
  // DP 63: lock times      DP 98: manual lock

  /// Auto-detect which DP key this lock uses for its lock state.
  String get _lockDpKey {
    for (final dp in _lockStateDps) {
      if (_dps.containsKey(dp)) {
        final val = _dps[dp];
        // Skip empty strings and null — means this lock doesn't use this DP
        if (val == null) continue;
        if (val is String && val.trim().isEmpty) continue;
        return dp;
      }
    }
    return '47'; // safe default
  }

  /// All lock-state DP keys that have actual values in this device.
  /// Used for grace-period protection so no lock DP can sneak through.
  List<String> get _activeLockDps {
    return _lockStateDps.where((dp) {
      if (!_dps.containsKey(dp)) return false;
      final val = _dps[dp];
      if (val == null) return false;
      if (val is String && val.trim().isEmpty) return false;
      return true;
    }).toList();
  }

  // ── Lock State (universal) ──
  bool? get _isLocked {
    final key = _lockDpKey;
    final raw = _dps[key];
    if (raw == null) return null;

    if (raw is bool) return raw;

    final state = raw.toString().toLowerCase().trim();
    if (state.isEmpty) return null;
    if (state == 'closed' || state == 'true' || state == '1') return true;
    if (state == 'opened' || state == 'false' || state == '0') return false;
    return null;
  }

  /// Read battery from whichever DP reports it.
  int? get _batteryLevel {
    for (final dp in _batteryDps) {
      final val = _dps[dp];
      if (val is int) return val;
      if (val is double) return val.toInt();
      final parsed = int.tryParse(val?.toString() ?? '');
      if (parsed != null) return parsed;
    }
    return null;
  }

  /// Read the last unlock method from whichever DP reports it.
  String get _lastUnlockMethod {
    for (final dp in _unlockMethodDps) {
      final val = _dps[dp];
      if (val != null && val.toString().isNotEmpty) {
        return _unlockMethodName(val.toString());
      }
    }
    return 'Unknown';
  }

  /// Read the latest alarm from whichever DP reports it.
  String? get _currentAlarm {
    for (final dp in _alarmDps) {
      final val = _dps[dp];
      if (val != null && val.toString().isNotEmpty && val != false) {
        return _alarmTitle(val.toString());
      }
    }
    return null;
  }

  String _unlockMethodName(String val) {
    switch (val) {
      case '1': return 'Fingerprint';
      case '2': return 'Password';
      case '3': return 'Card';
      case '4': return 'Key';
      case '5': return 'Remote';
      case '6': return 'Face';
      case '7': return 'Eye';
      case '8': return 'Palm';
      case '9': return 'Finger Vein';
      default: return 'Method $val';
    }
  }

  bool get _isOnline => _deviceInfo?['isOnline'] == true;

  // ── Event Processing (universal DP support) ──
  void _processLockEvents(Map<String, dynamic> dpData) {
    final now = DateTime.now();
    bool hasLockStateEvent = false;

    // Check all alarm DPs (8, 21, ...)
    for (final dp in _alarmDps) {
      if (dpData.containsKey(dp)) {
        final val = dpData[dp];
        if (val != null && val != false && val.toString().isNotEmpty) {
          _recentEvents.insert(0, _LockEvent(
            time: now,
            type: _LockEventType.alarm,
            title: _alarmTitle(val.toString()),
            detail: val.toString(),
          ));
        }
      }
    }

    // Check all lock-state DPs (47, 18, 2, 15, 36, ...)
    for (final dp in _lockStateDps) {
      if (dpData.containsKey(dp) && !hasLockStateEvent) {
        final raw = dpData[dp];
        if (raw == null) continue;
        final state = raw.toString().toLowerCase().trim();
        if (state.isEmpty) continue;

        final isLocked = (raw == true) ||
            state == 'closed' ||
            state == 'true' ||
            state == '1';
        _recentEvents.insert(0, _LockEvent(
          time: now,
          type: isLocked ? _LockEventType.locked : _LockEventType.unlocked,
          title: isLocked ? 'Door Locked' : 'Door Unlocked',
          detail: 'DP $dp: $state',
        ));
        hasLockStateEvent = true;
      }
    }

    // Check all unlock method DPs (1, 10, 5, ...) — only if no lock state event
    if (!hasLockStateEvent) {
      for (final dp in _unlockMethodDps) {
        if (dpData.containsKey(dp)) {
          final method = dpData[dp].toString();
          if (method.isNotEmpty) {
            _recentEvents.insert(0, _LockEvent(
              time: now,
              type: _LockEventType.unlocked,
              title: 'Unlocked via ${_unlockMethodName(method)}',
              detail: method,
            ));
            break;
          }
        }
      }
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

  // ── Matter Detection ──
  Future<bool> _isMatterDevice() async {
    try {
      final isMatter = await TuyaFlutterHaSdk.checkIsMatter(
        devId: widget.devId,
      );
      debugPrint('Matter check: $isMatter');
      return isMatter == true;
    } catch (e) {
      debugPrint('Matter check failed (assuming non-Matter): $e');
      return false;
    }
  }

  // ── BLE Lock Controls ──
  Future<void> _unlockBLE() async {
    setState(() => _actionLoading = true);
    try {
      if (widget.homeId != null) {
        await TuyaFlutterHaSdk.getHomeDevices(homeId: widget.homeId!);
      }

      // Check if this is a Matter device — use different unlock method
      final isMatter = await _isMatterDevice();
      if (isMatter) {
        await TuyaFlutterHaSdk.controlMatter(
          devId: widget.devId,
          dps: {'1': true},
        );
      } else {
        // Try our robust unlock first (syncs member data + V3 fallback)
        // Falls back to SDK's built-in unlock if robust fails
        try {
          await _lockExtras.invokeMethod('robustBleUnlock', {'devId': widget.devId});
        } catch (robustErr) {
          debugPrint('Robust unlock failed ($robustErr), trying SDK unlock');
          await TuyaFlutterHaSdk.unlockBLELock(devId: widget.devId);
        }
      }
      _showSnackBar('Lock opened via ${isMatter ? "Matter" : "BLE"}');

      // Set optimistic unlocked state immediately in the UI
      final dpKey = _lockDpKey;
      setState(() {
        if (dpKey == '47') {
          _dps['47'] = false; // DP 47: false = unlocked
        } else {
          _dps['18'] = 'opened';
        }
      });

      // Grace period: ignore auto-relock DP updates for 30 seconds
      // so the UI stays "unlocked" until the user manually taps Lock.
      _unlockGraceUntil = DateTime.now().add(const Duration(seconds: 30));

      _checkBleStatus();
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
    _unlockGraceUntil = null;
    setState(() => _actionLoading = true);
    debugPrint('=== LOCK ATTEMPT START ===');

    // Strategy 1: Publish DP 47=true via WiFi lock instance (uses LAN like Smart Life)
    try {
      debugPrint('Trying publishDpViaWifiLock (DP 47=true, LAN)...');
      await _lockExtras.invokeMethod('publishDpViaWifiLock', {
        'devId': widget.devId,
        'dpId': '47',
        'dpValue': true,
      });
      debugPrint('publishDpViaWifiLock SUCCESS!');
      _showSnackBar('Door locked!');
      setState(() => _dps['47'] = true);
      if (mounted) setState(() => _actionLoading = false);
      return;
    } catch (e) {
      debugPrint('publishDpViaWifiLock FAILED: $e');
    }

    // Strategy 2: Publish DP 8=true via WiFi lock instance (manual_lock)
    try {
      debugPrint('Trying publishDpViaWifiLock (DP 8=true, LAN)...');
      await _lockExtras.invokeMethod('publishDpViaWifiLock', {
        'devId': widget.devId,
        'dpId': '8',
        'dpValue': true,
      });
      debugPrint('publishDpViaWifiLock DP8 SUCCESS!');
      _showSnackBar('Door locked!');
      setState(() => _dps['47'] = true);
      if (mounted) setState(() => _actionLoading = false);
      return;
    } catch (e1) {
      debugPrint('publishDpViaWifiLock DP8 FAILED: $e1');
    }

    // Strategy 3: BLE manual lock with auto-connect
    try {
      debugPrint('Trying bleManualLock (native with auto-connect)...');
      await _lockExtras.invokeMethod('bleManualLock', {
        'devId': widget.devId,
      }).timeout(const Duration(seconds: 15));
      debugPrint('bleManualLock SUCCESS!');
      _showSnackBar('Door locked!');
      setState(() => _dps['47'] = true);
      if (mounted) setState(() => _actionLoading = false);
      return;
    } catch (e2) {
      debugPrint('bleManualLock FAILED: $e2');
    }

    // Strategy 4: remoteSwitchLock(false)
    try {
      debugPrint('Trying remoteSwitchLock(false)...');
      await _lockExtras.invokeMethod('remoteSwitchLock', {
        'devId': widget.devId,
        'open': false,
      }).timeout(const Duration(seconds: 15));
      debugPrint('remoteSwitchLock(lock) SUCCESS!');
      _showSnackBar('Door locked remotely!');
      setState(() => _dps['47'] = true);
      if (mounted) setState(() => _actionLoading = false);
      return;
    } catch (e3) {
      debugPrint('remoteSwitchLock(lock) FAILED: $e3');
    }

    debugPrint('=== ALL LOCK STRATEGIES FAILED ===');
    if (mounted) {
      setState(() => _actionLoading = false);
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.info_outline, size: 36, color: Colors.orange),
          title: const Text('Remote Lock Not Supported'),
          content: const Text(
            'This lock does not support remote locking from the app '
            '(security feature to prevent lockouts).\n\n'
            'Your lock will auto-relock after a few seconds. '
            'You can also lock it manually using the lock\'s keypad or handle.',
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    }
  }

  // ── WiFi Cloud Unlock ──
  //
  // IMPORTANT: Tuya WiFi locks use a REQUEST-REPLY pattern, not direct DP writes.
  // DP 47 is READ-ONLY — it reports lock state but cannot be written to.
  //
  // Flow: User presses button on lock → lock sends remote unlock request →
  // app receives it via RemoteUnlockListener → app replies allow/deny.
  //
  // If no pending request exists, we try replyRemoteUnlock first (in case
  // there's one queued), then fall back to BLE if available.
  Future<void> _wifiCloudUnlock() async {
    if (!_isOnline) {
      _showSnackBar('Device is offline.');
      return;
    }
    setState(() => _actionLoading = true);

    // Strategy 1: remoteSwitchLock — the proper Tuya BLE Lock V2 API
    // for remote unlock via cloud/LAN (same as Smart Life app)
    try {
      await _lockExtras.invokeMethod('remoteSwitchLock', {
        'devId': widget.devId,
        'open': true,
      });
      _showSnackBar('Remote unlock success!');
      final dpKey = _lockDpKey;
      setState(() {
        _dps[dpKey] = dpKey == '47' ? false : 'opened';
      });
      _unlockGraceUntil = DateTime.now().add(const Duration(seconds: 30));
      if (mounted) setState(() => _actionLoading = false);
      return;
    } catch (e) {
      debugPrint('remoteSwitchLock failed: $e — trying DP publish...');
    }

    // Strategy 2: Direct DP publish (DP 47 is rw on this lock)
    try {
      await _lockExtras.invokeMethod('publishDp', {
        'devId': widget.devId,
        'dpId': _lockDpKey,
        'dpValue': _lockDpKey == '47' ? false : 'opened',
      });
      _showSnackBar('WiFi unlock sent via DP!');
      final dpKey = _lockDpKey;
      setState(() {
        _dps[dpKey] = dpKey == '47' ? false : 'opened';
      });
      _unlockGraceUntil = DateTime.now().add(const Duration(seconds: 30));
      if (mounted) setState(() => _actionLoading = false);
      return;
    } catch (e2) {
      debugPrint('DP publish also failed: $e2');
    }

    // Strategy 3: Reply to pending remote unlock request
    try {
      await _lockExtras.invokeMethod('replyRemoteUnlock', {
        'devId': widget.devId,
        'allow': true,
      });
      _showSnackBar('Remote unlock approved!');
      final dpKey = _lockDpKey;
      setState(() {
        _dps[dpKey] = dpKey == '47' ? false : 'opened';
      });
      _unlockGraceUntil = DateTime.now().add(const Duration(seconds: 30));
    } catch (e3) {
      debugPrint('All unlock strategies failed: $e3');
      _showSnackBar('WiFi unlock failed. Check logcat for details.');
    }
    if (mounted) setState(() => _actionLoading = false);
  }

  /// Dump device schema to see which DPs are rw/ro/wr.
  // ── Doorbell & Video Lock Camera Events ──

  /// Handle doorbell ring (DP 53 = true).
  /// Often arrives together with DP 212 (video), but DP 53 may come first.
  void _handleDoorbellEvent(Map<String, dynamic> dpData) {
    debugPrint('🔔 Doorbell ring detected! Launching video call...');
    // Launch native doorbell call Activity with live P2P video
    _launchDoorbellCall();
  }

  /// Launch the native Android DoorbellCallActivity for full video call experience.
  Future<void> _launchDoorbellCall() async {
    // Debounce: prevent multiple launches within 10 seconds
    if (_lastDoorbellLaunch != null &&
        DateTime.now().difference(_lastDoorbellLaunch!).inSeconds < 10) {
      debugPrint('Doorbell launch debounced');
      return;
    }
    _lastDoorbellLaunch = DateTime.now();

    try {
      await _lockExtras.invokeMethod('launchDoorbellCall', {
        'devId': widget.devId,
        'deviceName': widget.deviceName,
      });
      debugPrint('DoorbellCallActivity launched');
    } catch (e) {
      debugPrint('Failed to launch doorbell call: $e');
      // Fallback: show simple dialog
      _showDoorbellDialog(null, null);
    }
  }

  /// Handle DP 212 video event — decode hex JSON, extract snapshot + video URLs.
  void _handleVideoEvent(String hexOrJson) {
    try {
      // DP 212 comes as hex-encoded JSON string
      String jsonStr;
      if (hexOrJson.startsWith('{')) {
        jsonStr = hexOrJson; // already decoded
      } else {
        // Decode hex to ASCII
        final bytes = <int>[];
        for (var i = 0; i < hexOrJson.length - 1; i += 2) {
          bytes.add(int.parse(hexOrJson.substring(i, i + 2), radix: 16));
        }
        jsonStr = String.fromCharCodes(bytes);
      }

      final Map<String, dynamic> videoData = jsonDecode(jsonStr);
      debugPrint('📹 Lock video event: ${videoData['cmd']}');

      final files = videoData['files'] as List<dynamic>? ?? [];
      String? snapshotUrl;
      String? videoUrl;
      String? snapshotBucket;
      String? snapshotPath;
      String? videoBucket;
      String? videoPath;

      for (final file in files) {
        if (file is List && file.length >= 2) {
          final bucket = file[0].toString();
          final path = file[1].toString();

          if (path.endsWith('.jpg') || path.endsWith('.jpeg') || path.endsWith('.png')) {
            snapshotBucket = bucket;
            snapshotPath = path;
            // Build URL — Tuya lock camera uses their CDN
            snapshotUrl = 'https://$bucket.oss-ap-south-1.aliyuncs.com$path';
          } else if (path.endsWith('.mjpeg') || path.endsWith('.mp4')) {
            videoBucket = bucket;
            videoPath = path;
            videoUrl = 'https://$bucket.oss-ap-south-1.aliyuncs.com$path';
          }
        }
      }

      debugPrint('📸 Snapshot: $snapshotUrl');
      debugPrint('🎥 Video: $videoUrl');

      _showDoorbellDialog(snapshotUrl, videoUrl);
    } catch (e) {
      debugPrint('Failed to parse DP 212 video event: $e');
      _showDoorbellDialog(null, null);
    }
  }

  /// Show doorbell alert with optional snapshot and video.
  void _showDoorbellDialog(String? snapshotUrl, String? videoUrl) {
    if (!mounted) return;

    // Don't show multiple dialogs
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.doorbell, size: 48, color: Colors.orange),
        title: const Text('Doorbell Ring!'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Someone is at the door'),
            if (snapshotUrl != null) ...[
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.network(
                  snapshotUrl,
                  height: 180,
                  width: double.infinity,
                  fit: BoxFit.cover,
                  loadingBuilder: (_, child, progress) {
                    if (progress == null) return child;
                    return SizedBox(
                      height: 180,
                      child: Center(
                        child: CircularProgressIndicator(
                          value: progress.expectedTotalBytes != null
                              ? progress.cumulativeBytesLoaded /
                                  progress.expectedTotalBytes!
                              : null,
                        ),
                      ),
                    );
                  },
                  errorBuilder: (_, __, ___) => Container(
                    height: 120,
                    color: Colors.grey[200],
                    child: const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.image_not_supported, size: 32),
                          SizedBox(height: 4),
                          Text('Snapshot not accessible',
                              style: TextStyle(fontSize: 12)),
                          Text('(May need Tuya cloud auth)',
                              style: TextStyle(fontSize: 10, color: Colors.grey)),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ] else ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.grey[100],
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Column(
                  children: [
                    Icon(Icons.videocam, size: 32, color: Colors.grey),
                    SizedBox(height: 4),
                    Text('No snapshot available',
                        style: TextStyle(fontSize: 12, color: Colors.grey)),
                  ],
                ),
              ),
            ],
            if (videoUrl != null) ...[
              const SizedBox(height: 8),
              Text('Video clip available',
                  style: TextStyle(fontSize: 11, color: Colors.grey[600])),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Dismiss'),
          ),
          FilledButton.icon(
            onPressed: () {
              Navigator.pop(ctx);
              // TODO: Open live camera view or play video
              _showSnackBar('Video playback coming soon');
            },
            icon: const Icon(Icons.videocam),
            label: const Text('View'),
          ),
        ],
      ),
    );
  }

  Future<void> _dumpDeviceSchema() async {
    try {
      final schema = await _lockExtras.invokeMethod<List>(
        'getDeviceSchema',
        {'devId': widget.devId},
      );
      if (schema != null && mounted) {
        final lines = schema.map((s) {
          final m = Map<String, dynamic>.from(s);
          return 'DP ${m['dpId']}: ${m['code']} [${m['mode']}] (${m['type']})';
        }).join('\n');
        debugPrint('=== DEVICE SCHEMA ===\n$lines');
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Device DP Schema'),
            content: SingleChildScrollView(
              child: Text(lines, style: const TextStyle(fontSize: 12)),
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      debugPrint('Schema dump error: $e');
    }
  }

  Future<void> _wifiCloudLock() async {
    if (!_isOnline) {
      _showSnackBar('Device is offline.');
      return;
    }

    setState(() => _actionLoading = true);

    try {
      // Step 1: trigger lock request
      await _lockExtras.invokeMethod('remoteSwitchLock', {
        'devId': widget.devId,
        'open': false,
      });

      _showSnackBar('Lock request sent...');
    } catch (e) {
      debugPrint('Lock trigger failed: $e');
    }

    // Step 2: approve request (IMPORTANT)
    try {
      await _lockExtras.invokeMethod('replyRemoteUnlock', {
        'devId': widget.devId,
        'allow': true,
      });

      _showSnackBar('Door locked successfully!');
    } catch (e) {
      debugPrint('Approval failed: $e');
      _showSnackBar('Lock failed.');
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
    String source = '';

    debugPrint('=== GENERATE PASSWORD START ===');

    // Strategy 1: WiFi dynamic password via our native channel (most reliable)
    try {
      debugPrint('Trying WiFi dynamic password (native)...');
      final wifiPwd = await _lockExtras.invokeMethod<String>(
        'getDynamicPasswordWiFi', {'devId': widget.devId});
      if (wifiPwd != null && wifiPwd.isNotEmpty) {
        password = wifiPwd;
        source = 'WiFi';
        debugPrint('WiFi dynamic password SUCCESS: $password');
      }
    } catch (e) {
      debugPrint("WiFi dynamic password (native) failed: $e");
    }

    // Strategy 2: WiFi dynamic password via SDK Flutter plugin
    if (password == null || password.isEmpty) {
      try {
        debugPrint('Trying WiFi dynamic password (SDK plugin)...');
        final wifiPwd = await TuyaFlutterHaSdk.dynamicWifiLockPassword(
          devId: widget.devId);
        if (wifiPwd != null && wifiPwd.toString().isNotEmpty) {
          password = wifiPwd.toString();
          source = 'WiFi';
          debugPrint('WiFi dynamic password (SDK) SUCCESS: $password');
        }
      } catch (e) {
        debugPrint("WiFi dynamic password (SDK) failed: $e");
      }
    }

    // Strategy 3: BLE dynamic password (needs BLE connection)
    if (password == null || password.isEmpty) {
      try {
        debugPrint('Trying BLE dynamic password...');
        password = await _lockExtras.invokeMethod<String>(
          'getDynamicPasswordBLE', {'devId': widget.devId});
        if (password != null && password.isNotEmpty) {
          source = 'BLE';
          debugPrint('BLE dynamic password SUCCESS: $password');
        }
      } catch (e) {
        debugPrint("BLE dynamic password failed: $e");
      }
    }

    // Strategy 4: Offline single-use password
    if (password == null || password.isEmpty) {
      try {
        debugPrint('Trying offline single-use password...');
        final result = await _lockExtras.invokeMethod<Map>(
          'createOfflinePasswordBLE',
          {
            'devId': widget.devId,
            'name': 'Quick OTP',
            'type': 'single',
          },
        );
        if (result != null && result['password'] != null) {
          password = result['password'].toString();
          source = 'Offline';
          debugPrint('Offline password SUCCESS: $password');
        }
      } catch (e) {
        debugPrint("Offline password failed: $e");
      }
    }

    debugPrint('=== GENERATE PASSWORD END: ${password != null ? "got $source" : "ALL FAILED"} ===');

    if (mounted) setState(() => _actionLoading = false);

    if (password != null && password.isNotEmpty && mounted) {
      _showPasswordDialog(
        title: source == 'Offline' ? 'One-Time Password' : 'Dynamic Password (OTP)',
        password: password,
        subtitle: source == 'Offline'
          ? 'Single use only. Enter on lock keypad.'
          : 'Enter on lock keypad. Valid 5 min. (via $source)',
      );
    } else if (mounted) {
      _showSnackBar('Could not generate password. Check lock connection.');
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
    WidgetsBinding.instance.removeObserver(this);
    _refreshTimer?.cancel();
    _bleCheckTimer?.cancel();
    _dpEventSub?.cancel();
    _remoteUnlockSub?.cancel();
    _countdownTimer?.cancel();
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
                          onPressed: _actionLoading ? null : _wifiCloudLock,
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
                    onPressed: _actionLoading ? null : _getDynamicPassword,
                    icon: const Icon(Icons.looks_one, size: 18),
                    label: const Text('One-Time'),
                    style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 42)),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _actionLoading ? null : _getDynamicPassword, // call _getDynamicPassword, this function to one time password
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

  // ── WiFi Cloud Control Card ──
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
                Text('WiFi Cloud Control',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600)),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Control lock via WiFi/LAN. Tries direct command first, '
                    'then remote unlock approval.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant),
                  ),
                ),
                TextButton(
                  onPressed: _dumpDeviceSchema,
                  child: const Text('Debug DPs', style: TextStyle(fontSize: 11)),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: (_actionLoading || !_isOnline)
                        ? null : _wifiCloudUnlock,
                    icon: const Icon(Icons.lock_open, size: 18),
                    label: const Text('Unlock'),
                    style: FilledButton.styleFrom(
                        minimumSize: const Size(0, 44)),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: (_actionLoading || !_isOnline)
                        ? null : _wifiCloudLock,
                    icon: const Icon(Icons.lock, size: 18),
                    label: const Text('Lock'),
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
            if (_currentAlarm != null)
              _buildEventTile(
                _LockEvent(
                  time: DateTime.now(),
                  type: _LockEventType.alarm,
                  title: _currentAlarm!,
                  detail: '',
                ),
                isCurrent: true,
              ),
            if (_recentEvents.isEmpty && _currentAlarm == null)
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
            if (_batteryLevel != null)
              _infoRow('Battery', '$_batteryLevel%'),
            _infoRow('Volume', _dps['11']?.toString() ?? _dps['13']?.toString() ?? 'Unknown'),
            _infoRow('Child Lock',
                (_dps['17'] == true || _dps['40'] == true) ? 'On' : 'Off'),
            _infoRow('Auto Lock',
                (_dps['19'] == true || _dps['46'] == true) ? 'On' : 'Off'),
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
