import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tuya_flutter_ha_sdk/tuya_flutter_ha_sdk.dart';
import 'package:wifi_scan/wifi_scan.dart';

class DevicePairingScreen extends StatefulWidget {
  final int homeId;
  const DevicePairingScreen({super.key, required this.homeId, String? initialMode});

  @override
  State<DevicePairingScreen> createState() => _DevicePairingScreenState();
}

class _DevicePairingScreenState extends State<DevicePairingScreen>
    with TickerProviderStateMixin {
  // ── State ──
  _PairingPhase _phase = _PairingPhase.scanning;
  Map<String, dynamic>? _discoveredDevice;
  // ── WiFi fields ──
  String _status = 'Searching for nearby devices…';
  bool _pairing = false;
  StreamSubscription? _pairingEventSub;

  final _ssidController = TextEditingController();
  final _wifiPwdController = TextEditingController();
  bool _obscureWifiPwd = true;

  // ── Radar animation ──
  late AnimationController _radarController;
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  // ── Saved WiFi prefs ──
  static const _prefSsid = 'pairing_wifi_ssid';
  static const _prefPwd = 'pairing_wifi_pwd';

  @override
  void initState() {
    super.initState();

    // Radar rotation: continuous 360° spin
    _radarController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();

    // Pulse animation for the rings
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat();
    _pulseAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeOut),
    );

    _listenPairingEvents();
    // Load WiFi first, then start scanning (avoids concurrent platform calls)
    _initAndScan();
  }

  Future<void> _initAndScan() async {
    await _loadSavedWifi();
    // Small delay to ensure native SDK is fully ready after screen transition
    await Future.delayed(const Duration(milliseconds: 500));
    if (mounted) _startBleScan();
  }

  void _listenPairingEvents() {
    _pairingEventSub = TuyaFlutterHaSdk.pairingEvents.listen((event) {
      debugPrint('Pairing event: $event');
      final eventType = event['event']?.toString() ?? '';

      if (eventType == 'onPairingSuccess') {
        final devId = event['deviceId'] ?? event['devId'] ?? '';
        setState(() {
          _phase = _PairingPhase.success;
          _status = 'Paired successfully!';
          _pairing = false;
        });
        Future.delayed(const Duration(seconds: 1), () {
          if (mounted) Navigator.pop(context, devId);
        });
      } else if (eventType == 'onPairingError' ||
          eventType == 'onConfigError') {
        setState(() {
          _phase = _PairingPhase.error;
          _status = event['message']?.toString() ?? 'Pairing failed';
          _pairing = false;
        });
      } else if (eventType == 'onConfigSent') {
        setState(() => _status = 'Config sent, connecting to WiFi…');
      }
    }, onError: (e) {
      debugPrint('Pairing event error: $e');
    });
  }

  Future<void> _loadSavedWifi() async {
    // Load current SSID from device
    try {
      final ssid = await TuyaFlutterHaSdk.getSSID();
      if (ssid is String && ssid.isNotEmpty) {
        _ssidController.text = ssid;
      }
    } catch (_) {}

    // Load saved password for this SSID
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedSsid = prefs.getString(_prefSsid);
      final savedPwd = prefs.getString(_prefPwd);
      if (savedPwd != null && savedPwd.isNotEmpty) {
        _wifiPwdController.text = savedPwd;
      }
      // If SSID wasn't detected, use saved one
      if (_ssidController.text.isEmpty && savedSsid != null) {
        _ssidController.text = savedSsid;
      }
    } catch (_) {}
  }

  Future<void> _saveWifiCredentials() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefSsid, _ssidController.text);
      await prefs.setString(_prefPwd, _wifiPwdController.text);
    } catch (_) {}
  }

  // ─────────────────────────────────────────────
  // Phase 1: BLE Scan (auto-starts)
  // ─────────────────────────────────────────────
  Future<void> _startBleScan() async {
    setState(() {
      _phase = _PairingPhase.scanning;
      _discoveredDevice = null;
      _status = 'Searching for nearby devices…';
    });

    try {
      // The native discoverDeviceInfo() never completes if no device is found,
      // so we wrap it with a timeout to avoid hanging forever.
      final device = await TuyaFlutterHaSdk.discoverDeviceInfo()
          .timeout(const Duration(seconds: 60), onTimeout: () => null);
      debugPrint("BLE scan result -> $device");

      if (device != null && mounted) {
        setState(() {
          _discoveredDevice = device;
          _phase = _PairingPhase.found;
          _status = 'Found: ${device['name'] ?? device['uuid'] ?? 'Device'}';
        });
        // Don't auto-trigger pairing — let user see the device on radar
        // and tap "Connect" when ready.
      } else if (mounted) {
        setState(() {
          _phase = _PairingPhase.error;
          _status = 'No device found. Make sure it\'s in pairing mode.';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _phase = _PairingPhase.error;
          _status = 'Scan failed: ${e.toString().replaceAll('PlatformException', '').trim()}';
        });
      }
    }
  }

  // ─────────────────────────────────────────────
  // Phase 2: WiFi Credentials Popup
  // ─────────────────────────────────────────────
  void _showWifiDialog() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(
          24, 24, 24, MediaQuery.of(ctx).viewInsets.bottom + 24,
        ),
        child: StatefulBuilder(
          builder: (ctx, setSheetState) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Handle bar
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.outlineVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Icon(Icons.wifi,
                      color: Theme.of(context).colorScheme.primary),
                  const SizedBox(width: 10),
                  Text('Connect to WiFi',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      )),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Your device needs WiFi to complete setup.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 20),
              TextField(
                controller: _ssidController,
                decoration: InputDecoration(
                  labelText: 'WiFi Network',
                  prefixIcon: const Icon(Icons.wifi),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  filled: true,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _wifiPwdController,
                obscureText: _obscureWifiPwd,
                decoration: InputDecoration(
                  labelText: 'Password',
                  prefixIcon: const Icon(Icons.lock_outline),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  filled: true,
                  suffixIcon: IconButton(
                    icon: Icon(_obscureWifiPwd
                        ? Icons.visibility_off
                        : Icons.visibility),
                    onPressed: () {
                      setSheetState(
                              () => _obscureWifiPwd = !_obscureWifiPwd);
                      setState(
                              () {}); // sync outer state
                    },
                  ),
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: FilledButton.icon(
                  onPressed: () {
                    if (_ssidController.text.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Enter WiFi SSID')),
                      );
                      return;
                    }
                    Navigator.pop(ctx);
                    _saveWifiCredentials();
                    _pairCombo();
                  },
                  icon: const Icon(Icons.link),
                  label: const Text('Connect & Pair'),
                  style: FilledButton.styleFrom(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Center(
                child: Text(
                  'Credentials are saved for next time',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────
  // Phase 3a: BLE-only pairing
  // ─────────────────────────────────────────────
  Future<void> _pairBle() async {
    if (_discoveredDevice == null) return;

    final uuid = _discoveredDevice!['uuid']?.toString() ?? '';
    final productId = _discoveredDevice!['productId']?.toString() ?? '';
    final deviceType = _discoveredDevice!['deviceType'] as int?;
    final address = _discoveredDevice!['address']?.toString();
    final flag = _discoveredDevice!['flag'] as int?;

    setState(() {
      _phase = _PairingPhase.pairing;
      _pairing = true;
      _status = 'Connecting…';
    });

    try {
      await TuyaFlutterHaSdk.getToken(homeId: widget.homeId);
      setState(() => _status = 'Pairing via Bluetooth…');

      final result = await TuyaFlutterHaSdk.pairBleDevice(
        uuid: uuid,
        productId: productId,
        homeId: widget.homeId,
        deviceType: deviceType,
        address: address,
        flag: flag,
        timeout: 120,
      );

      if (result != null && mounted) {
        final devId = result['devId'] ?? result['deviceId'] ?? '';
        final name = result['name'] ?? 'Device';
        setState(() {
          _phase = _PairingPhase.success;
          _pairing = false;
          _status = 'Paired! ($name)';
        });
        Future.delayed(const Duration(seconds: 1), () {
          if (mounted) Navigator.pop(context, devId);
        });
      } else {
        setState(() => _status = 'Waiting for device activation…');
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _phase = _PairingPhase.error;
          _pairing = false;
          _status = 'Pairing failed: ${e.toString().replaceAll('PlatformException', '').trim()}';
        });
      }
    }
  }

  // ─────────────────────────────────────────────
  // Phase 3b: Combo pairing (BLE → WiFi)
  // ─────────────────────────────────────────────
  Future<void> _pairCombo() async {
    if (_discoveredDevice == null) return;

    final uuid = _discoveredDevice!['uuid']?.toString() ?? '';
    final productId = _discoveredDevice!['productId']?.toString() ?? '';
    final deviceType = _discoveredDevice!['deviceType'] as int?;
    final address = _discoveredDevice!['address']?.toString();
    final flag = _discoveredDevice!['flag'] as int?;

    setState(() {
      _phase = _PairingPhase.pairing;
      _pairing = true;
      _status = 'Getting token…';
    });

    try {
      final token = await TuyaFlutterHaSdk.getToken(homeId: widget.homeId);
      setState(() => _status = 'Connecting via BLE + WiFi…');

      final result = await TuyaFlutterHaSdk.startComboPairing(
        uuid: uuid,
        productId: productId,
        homeId: widget.homeId,
        ssid: _ssidController.text,
        password: _wifiPwdController.text,
        token: token,
        deviceType: deviceType,
        address: address,
        flag: flag,
        timeout: 120,
      );

      if (result != null && mounted) {
        final devId = result['devId'] ?? result['deviceId'] ?? '';
        final name = result['name'] ?? 'Device';
        setState(() {
          _phase = _PairingPhase.success;
          _pairing = false;
          _status = 'Paired! ($name)';
        });
        Future.delayed(const Duration(seconds: 1), () {
          if (mounted) Navigator.pop(context, devId);
        });
      } else {
        setState(() => _status = 'Config sent, waiting for activation…');
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _phase = _PairingPhase.error;
          _pairing = false;
          _status = 'Pairing failed: ${e.toString().replaceAll('PlatformException', '').trim()}';
        });
      }
    }
  }

  Future<void> _stopPairing() async {
    try {
      await TuyaFlutterHaSdk.stopConfigWiFi();
    } catch (_) {}
    setState(() {
      _pairing = false;
      _phase = _PairingPhase.scanning;
      _status = 'Pairing cancelled';
    });
  }

  Future<List<WiFiAccessPoint>> _scanWifi() async {
    final can = await WiFiScan.instance.canStartScan();

    if (can == CanStartScan.yes) {
      await WiFiScan.instance.startScan();
      await Future.delayed(const Duration(seconds: 2));
      return await WiFiScan.instance.getScannedResults();
    } else {
      return [];
    }
  }

  bool _is5GHz(WiFiAccessPoint wifi) {
    return wifi.frequency > 4900;
  }

  void _showWifiListDialog() async {
    List<WiFiAccessPoint> wifiList = await _scanWifi();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return Container(
          height: MediaQuery.of(context).size.height * 0.75,
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            children: [
              const SizedBox(height: 12),

              // 🔘 Top handle
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),

              const SizedBox(height: 16),

              // Title
              const Text(
                "Select a Wi-Fi Network from the List",
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),

              const SizedBox(height: 6),

              const Text(
                "Choose Wi-Fi and enter password",
                style: TextStyle(color: Colors.grey),
              ),

              const SizedBox(height: 16),

              //  WIFI LIST
              Expanded(
                child: ListView.builder(
                  itemCount: wifiList.length,
                  itemBuilder: (context, index) {
                    final wifi = wifiList[index];
                    final is5G = _is5GHz(wifi);

                    return ListTile(
                      title: Text(
                        wifi.ssid.isEmpty ? "Hidden Network" : wifi.ssid,
                        style: TextStyle(
                          color: is5G ? Colors.grey : Colors.black,
                          fontWeight:
                          is5G ? FontWeight.normal : FontWeight.w500,
                        ),
                      ),

                      //  Lock icon (optional)
                      leading: const Icon(Icons.lock_outline, size: 18),

                      // 📡 Right side
                      trailing: is5G
                          ? const Text(
                        "5G",
                        style: TextStyle(
                          color: Colors.grey,
                          fontWeight: FontWeight.bold,
                        ),
                      )
                          : const Icon(Icons.wifi),

                      enabled: !is5G,

                      onTap: is5G
                          ? null
                          : () {
                        Navigator.pop(ctx);

                        _ssidController.text = wifi.ssid;

                        // Open your existing password dialog
                        _showWifiDialog();
                      },
                    );
                  },
                ),
              ),

              // 🔽 Enter manually
              Padding(
                padding: const EdgeInsets.all(16),
                child: ListTile(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  tileColor: Colors.grey.shade100,
                  title: const Text("Enter manually"),
                  trailing: const Icon(Icons.arrow_forward_ios, size: 16),
                  onTap: () {
                    Navigator.pop(ctx);
                    _showWifiDialog();
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    _radarController.dispose();
    _pulseController.dispose();
    _pairingEventSub?.cancel();
    _ssidController.dispose();
    _wifiPwdController.dispose();
    if (_pairing) TuyaFlutterHaSdk.stopConfigWiFi();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isActive = _phase == _PairingPhase.scanning ||
        _phase == _PairingPhase.pairing;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Add Device'),
        actions: [
          if (_pairing)
            TextButton(
              onPressed: _stopPairing,
              child: const Text('Cancel'),
            ),
        ],
      ),
      body: Column(
        children: [
          const Spacer(flex: 1),

          // ── Radar Animation Area ──
          SizedBox(
            width: 260,
            height: 260,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // Pulsing rings
                if (isActive)
                  AnimatedBuilder(
                    animation: _pulseAnimation,
                    builder: (context, child) {
                      return CustomPaint(
                        size: const Size(260, 260),
                        painter: _RadarRingsPainter(
                          progress: _pulseAnimation.value,
                          color: cs.primary,
                        ),
                      );
                    },
                  ),

                // Radar sweep line
                if (_phase == _PairingPhase.scanning)
                  AnimatedBuilder(
                    animation: _radarController,
                    builder: (context, child) {
                      return Transform.rotate(
                        angle: _radarController.value * 2 * pi,
                        child: CustomPaint(
                          size: const Size(260, 260),
                          painter: _RadarSweepPainter(color: cs.primary),
                        ),
                      );
                    },
                  ),

                // Device blip on radar when found
                if (_discoveredDevice != null &&
                    (_phase == _PairingPhase.found ||
                        _phase == _PairingPhase.pairing))
                  Positioned(
                    top: 45,
                    right: 65,
                    child: TweenAnimationBuilder<double>(
                      tween: Tween(begin: 0.0, end: 1.0),
                      duration: const Duration(milliseconds: 600),
                      curve: Curves.elasticOut,
                      builder: (context, value, child) => Transform.scale(
                        scale: value,
                        child: child,
                      ),
                      child: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: Colors.green,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 2),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.green.withOpacity(0.4),
                              blurRadius: 10,
                              spreadRadius: 2,
                            ),
                          ],
                        ),
                        child: const Icon(Icons.lock_outline,
                            size: 18, color: Colors.white),
                      ),
                    ),
                  ),

                // Center icon
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 400),
                  child: Container(
                    key: ValueKey(_phase),
                    width: 90,
                    height: 90,
                    decoration: BoxDecoration(
                      color: _centerColor(cs),
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: _centerColor(cs).withOpacity(0.3),
                          blurRadius: 20,
                          spreadRadius: 4,
                        ),
                      ],
                    ),
                    child: Icon(
                      _centerIcon,
                      size: 40,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 32),

          // ── Status text ──
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Text(
              _status,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w500,
              ),
            ),
          ),

          const SizedBox(height: 8),

          // ── Subtitle / instructions ──
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 48),
            child: Text(
              _subtitle,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
          ),

          // ── Device info chip (when found) ──
          if (_discoveredDevice != null &&
              _phase != _PairingPhase.scanning) ...[
            const SizedBox(height: 20),
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 40),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: cs.primaryContainer.withOpacity(0.5),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.bluetooth, size: 18, color: cs.primary),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      _discoveredDevice!['name']?.toString().isNotEmpty == true
                          ? _discoveredDevice!['name'].toString()
                          : _discoveredDevice!['uuid']?.toString() ?? 'Device',
                      style: TextStyle(
                        color: cs.onPrimaryContainer,
                        fontWeight: FontWeight.w500,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ],

          const Spacer(flex: 1),

          // ── Bottom action buttons ──
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 40),
            child: Column(
              children: [
                if (_phase == _PairingPhase.found &&
                    _discoveredDevice != null) ...[
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: FilledButton.icon(
                      onPressed: () async {
                        String? currentSSID = await TuyaFlutterHaSdk.getSSID();

                        bool is5G = currentSSID != null &&
                            currentSSID.toLowerCase().contains("5g");

                        if (is5G) {
                          _showWifiListDialog(); // 🔥 NEW
                        } else {
                          _showWifiDialog(); // existing
                        }
                      },                      icon: const Icon(Icons.wifi),
                      label: const Text('Connect & Pair'),
                      style: FilledButton.styleFrom(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                if (_phase == _PairingPhase.error) ...[
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: FilledButton.icon(
                      onPressed: _startBleScan,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Scan Again'),
                      style: FilledButton.styleFrom(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                if (_pairing)
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: OutlinedButton.icon(
                      onPressed: _stopPairing,
                      icon: const Icon(Icons.stop),
                      label: const Text('Stop'),
                      style: OutlinedButton.styleFrom(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                    ),
                  ),
                // Instructions at very bottom
                const SizedBox(height: 16),
                Text(
                  'Make sure your device is in pairing mode\n'
                      '(usually long-press reset for 5 seconds)',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant.withOpacity(0.7),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Color _centerColor(ColorScheme cs) {
    switch (_phase) {
      case _PairingPhase.scanning:
        return cs.primary;
      case _PairingPhase.found:
        return Colors.blue;
      case _PairingPhase.pairing:
        return cs.tertiary;
      case _PairingPhase.success:
        return Colors.green;
      case _PairingPhase.error:
        return cs.error;
    }
  }

  IconData get _centerIcon {
    switch (_phase) {
      case _PairingPhase.scanning:
        return Icons.bluetooth_searching;
      case _PairingPhase.found:
        return Icons.devices;
      case _PairingPhase.pairing:
        return Icons.sync;
      case _PairingPhase.success:
        return Icons.check;
      case _PairingPhase.error:
        return Icons.close;
    }
  }

  String get _subtitle {
    switch (_phase) {
      case _PairingPhase.scanning:
        return 'Keep your device nearby with Bluetooth enabled';
      case _PairingPhase.found:
        return 'Tap "Connect & Pair" to set up this device';
      case _PairingPhase.pairing:
        return 'This may take up to 2 minutes. Don\'t close the app.';
      case _PairingPhase.success:
        return 'Your device is ready to use!';
      case _PairingPhase.error:
        return 'Check that the device is in pairing mode and try again.';
    }
  }
}

// ── Pairing phases ──
enum _PairingPhase { scanning, found, pairing, success, error }

// ── Radar rings painter (concentric pulsing circles) ──
class _RadarRingsPainter extends CustomPainter {
  final double progress;
  final Color color;

  _RadarRingsPainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius = size.width / 2;

    // Draw 3 expanding rings at different phases
    for (int i = 0; i < 3; i++) {
      final ringProgress = (progress + i * 0.33) % 1.0;
      final radius = maxRadius * ringProgress;
      final opacity = (1.0 - ringProgress) * 0.3;

      if (opacity > 0) {
        final paint = Paint()
          ..color = color.withOpacity(opacity)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.0;
        canvas.drawCircle(center, radius, paint);
      }
    }

    // Static grid circles
    for (int i = 1; i <= 3; i++) {
      final paint = Paint()
        ..color = color.withOpacity(0.08)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0;
      canvas.drawCircle(center, maxRadius * i / 3, paint);
    }

    // Cross lines
    final linePaint = Paint()
      ..color = color.withOpacity(0.06)
      ..strokeWidth = 1.0;
    canvas.drawLine(
        Offset(0, size.height / 2), Offset(size.width, size.height / 2), linePaint);
    canvas.drawLine(
        Offset(size.width / 2, 0), Offset(size.width / 2, size.height), linePaint);
  }

  @override
  bool shouldRepaint(covariant _RadarRingsPainter old) =>
      old.progress != progress;
}

// ── Radar sweep painter (rotating gradient line) ──
class _RadarSweepPainter extends CustomPainter {
  final Color color;

  _RadarSweepPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;

    // Draw a gradient sweep from center going up
    final sweepPaint = Paint()
      ..shader = SweepGradient(
        startAngle: -0.15,
        endAngle: 0.0,
        colors: [
          color.withOpacity(0.0),
          color.withOpacity(0.15),
        ],
        transform: const GradientRotation(-pi / 2),
      ).createShader(Rect.fromCircle(center: center, radius: radius));

    canvas.drawCircle(center, radius, sweepPaint);

    // Draw the leading line
    final linePaint = Paint()
      ..color = color.withOpacity(0.6)
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(center, Offset(center.dx, center.dy - radius), linePaint);
  }

  @override
  bool shouldRepaint(covariant _RadarSweepPainter old) => false;
}
