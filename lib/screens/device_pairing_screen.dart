import 'dart:async';
import 'package:flutter/material.dart';
import 'package:tuya_flutter_ha_sdk/tuya_flutter_ha_sdk.dart';

class DevicePairingScreen extends StatefulWidget {
  final int homeId;
  const DevicePairingScreen({super.key, required this.homeId});

  @override
  State<DevicePairingScreen> createState() => _DevicePairingScreenState();
}

class _DevicePairingScreenState extends State<DevicePairingScreen> {
  // ── Pairing mode ──
  String _mode = 'ble'; // 'ble', 'wifi', 'combo'

  // ── BLE scan state ──
  bool _scanning = false;
  Map<String, dynamic>? _discoveredDevice;

  // ── WiFi fields ──
  final _ssidController = TextEditingController();
  final _wifiPwdController = TextEditingController();
  bool _obscureWifiPwd = true;

  // ── Pairing progress ──
  bool _pairing = false;
  String _status = '';
  StreamSubscription? _pairingEventSub;

  @override
  void initState() {
    super.initState();
    debugPrint("DevicePairingScreen opened | homeId=${widget.homeId}");
    _loadSSID();
    _listenPairingEvents();
  }

  /// Listen to native pairing events from the SDK's EventChannel.
  void _listenPairingEvents() {
    debugPrint("Listening to Tuya pairing events...");
    _pairingEventSub = TuyaFlutterHaSdk.pairingEvents.listen((event) {
      debugPrint('Pairing event: $event');
      final eventType = event['event']?.toString() ?? '';
      debugPrint("Event Type -> $eventType");
      if (eventType == 'onPairingSuccess') {
        final devId = event['deviceId'] ?? event['devId'] ?? '';
        final name = event['name'] ?? 'Device';
        setState(() {
          _pairing = false;
          _status = 'Paired successfully! ($name)';
        });
        _showSnackBar('Device paired: $name');
        // Go back with result after short delay
        Future.delayed(const Duration(seconds: 1), () {
          if (mounted) Navigator.pop(context, devId);
        });
      } else if (eventType == 'onPairingError' ||
          eventType == 'onConfigError') {
        setState(() {
          _pairing = false;
          _status = 'Pairing failed: ${event['message'] ?? 'Unknown error'}';
        });
      } else if (eventType == 'onConfigSent') {
        setState(() => _status = 'Config sent to device, waiting…');
      }
    }, onError: (e) {
      debugPrint('Pairing event error: $e');
    });
  }

  Future<void> _loadSSID() async {
    debugPrint("Fetching current WiFi SSID...");
    try {
      final ssid = await TuyaFlutterHaSdk.getSSID();
      debugPrint("Current SSID -> $ssid");
      if (ssid is String && ssid.isNotEmpty) {
        _ssidController.text = ssid;
      }
    } catch (e) {
      debugPrint('SSID fetch error: $e');
    }
  }

  // ─────────────────────────────────────────────
  // BLE Scan
  // ─────────────────────────────────────────────
  Future<void> _startBleScan() async {
    debugPrint("Starting BLE scan...");
    setState(() {
      _scanning = true;
      _discoveredDevice = null;
      _status = 'Scanning for BLE devices…';
    });

    try {
      final device = await TuyaFlutterHaSdk.discoverDeviceInfo();
      debugPrint("BLE scan result -> $device");
      setState(() {
        _scanning = false;
        _discoveredDevice = device;
        _status = device != null
            ? 'Found: ${device['name'] ?? device['uuid'] ?? 'Unknown'}'
            : 'No device found. Make sure your device is in pairing mode.';
      });
    } catch (e) {
      setState(() {
        _scanning = false;
        _status = 'Scan error: $e';
      });
    }
  }

  // ─────────────────────────────────────────────
  // BLE Pair (pure BLE — typical for smart locks)
  // ─────────────────────────────────────────────
  Future<void> _pairBle() async {
    debugPrint("Starting BLE pairing...");

    if (_discoveredDevice == null) {
      debugPrint("ERROR: No discovered device");
      _showSnackBar('No device discovered. Scan first.');
      return;
    }

    final uuid = _discoveredDevice!['uuid']?.toString() ?? '';
    final productId = _discoveredDevice!['productId']?.toString() ?? '';
    final deviceType = _discoveredDevice!['deviceType'] as int?;
    final address = _discoveredDevice!['address']?.toString();
    final flag = _discoveredDevice!['flag'] as int?;
    final configType = _discoveredDevice!['configType']?.toString() ?? '';
    debugPrint("BLE Device UUID -> $uuid");
    debugPrint("BLE ProductId -> $productId");
    debugPrint("BLE configType -> $configType");
    debugPrint("BLE Device Info -> $_discoveredDevice");
    if (uuid.isEmpty || productId.isEmpty) {
      _showSnackBar('Invalid device info (missing uuid or productId)');
      return;
    }

    // If the device reports configType as wifi, it needs WiFi credentials
    // to complete pairing. Auto-switch to combo mode.
    if (configType.contains('wifi')) {
      debugPrint("Device requires WiFi config — switching to combo mode");
      if (_ssidController.text.isEmpty) {
        setState(() {
          _mode = 'combo';
          _status = 'This device requires WiFi. Switched to Combo mode — '
              'enter your WiFi credentials and tap "Start Combo Pairing".';
        });
        _showSnackBar('This device needs WiFi credentials. Switched to Combo mode.');
        return;
      }
      // WiFi credentials already filled, proceed with combo pairing directly
      _pairCombo();
      return;
    }

    setState(() {
      _pairing = true;
      _status = 'Getting pairing token…';
    });

    try {
      debugPrint("Fetching fresh token for BLE pairing...");
      final token = await TuyaFlutterHaSdk.getToken(homeId: widget.homeId);
      debugPrint("Token received -> $token");

      setState(() => _status = 'Pairing BLE device…');
      debugPrint("Calling TuyaFlutterHaSdk.pairBleDevice()");
      final result = await TuyaFlutterHaSdk.pairBleDevice(
        uuid: uuid,
        productId: productId,
        homeId: widget.homeId,
        deviceType: deviceType,
        address: address,
        flag: flag,
        timeout: 120,
      );
      debugPrint("BLE Pair Result -> $result");
      if (result != null) {
        final devId = result['devId'] ?? result['deviceId'] ?? '';
        final name = result['name'] ?? 'Device';
        setState(() {
          _pairing = false;
          _status = 'Paired! ($name)';
        });
        _showSnackBar('Device paired: $name');
        Future.delayed(const Duration(seconds: 1), () {
          if (mounted) Navigator.pop(context, devId);
        });
      } else {
        // result is null but no error — wait for pairing event
        setState(() => _status = 'Waiting for device activation…');
      }
    } catch (e) {
      setState(() {
        _pairing = false;
        _status = 'BLE pairing failed: $e';
      });
    }
  }

  // ─────────────────────────────────────────────
  // Combo pair (BLE→WiFi for dual-mode devices)
  // ─────────────────────────────────────────────
  Future<void> _pairCombo() async {
    debugPrint("Starting COMBO pairing");
    if (_discoveredDevice == null) {
      _showSnackBar('No device discovered. Scan first.');
      return;
    }
    if (_ssidController.text.isEmpty) {
      _showSnackBar('Please enter WiFi SSID');
      return;
    }
    if (_wifiPwdController.text.isEmpty) {
      _showSnackBar('Please enter WiFi password');
      return;
    }

    final uuid = _discoveredDevice!['uuid']?.toString() ?? '';
    final productId = _discoveredDevice!['productId']?.toString() ?? '';
    final deviceType = _discoveredDevice!['deviceType'] as int?;
    final address = _discoveredDevice!['address']?.toString();
    final flag = _discoveredDevice!['flag'] as int?;
    debugPrint("Device -> $_discoveredDevice");
    debugPrint("SSID -> ${_ssidController.text}");
    setState(() {
      _pairing = true;
      _status = 'Getting token…';
    });

    try {
      debugPrint("Requesting Tuya token...");
      final token = await TuyaFlutterHaSdk.getToken(homeId: widget.homeId);
      debugPrint("Token received -> $token");
      setState(() => _status = 'Starting combo pairing…');
      debugPrint("Starting combo pairing with:");
      debugPrint("UUID -> $uuid");
      debugPrint("ProductId -> $productId");
      debugPrint("HomeId -> ${widget.homeId}");
      debugPrint("SSID -> ${_ssidController.text}");
      debugPrint("Password -> ${_wifiPwdController.text}");
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
      debugPrint("Combo pairing result -> $result");
      if (result != null) {
        final devId = result['devId'] ?? result['deviceId'] ?? '';
        final name = result['name'] ?? 'Device';
        setState(() {
          _pairing = false;
          _status = 'Paired! ($name)';
        });
        _showSnackBar('Device paired: $name');
        Future.delayed(const Duration(seconds: 1), () {
          if (mounted) Navigator.pop(context, devId);
        });
      } else {
        setState(() => _status = 'Config sent, waiting for activation…');
      }
    } catch (e) {
      setState(() {
        _pairing = false;
        _status = 'Combo pairing failed: $e';
      });
    }
  }

  // ─────────────────────────────────────────────
  // WiFi EZ/AP pairing
  // ─────────────────────────────────────────────
  Future<void> _pairWifi() async {
    debugPrint("Starting WiFi pairing");
    debugPrint("SSID -> ${_ssidController.text}");
    debugPrint("Password -> ${_wifiPwdController.text}");
    if (_ssidController.text.isEmpty) {
      _showSnackBar('Please enter WiFi SSID');
      return;
    }

    setState(() {
      _pairing = true;
      _status = 'Getting pairing token…';
    });

    try {
      final token = await TuyaFlutterHaSdk.getToken(homeId: widget.homeId);
      debugPrint("Token received -> $token");
      setState(() => _status = 'Starting WiFi config (EZ mode)…');
      debugPrint("Starting Tuya WiFi config...");
      await TuyaFlutterHaSdk.startConfigWiFi(
        mode: 'EZ',
        ssid: _ssidController.text,
        password: _wifiPwdController.text,
        token: token ?? '',
        timeout: 100,
      );

      setState(() => _status = 'Searching for device… keep device in pairing mode.');
    } catch (e) {
      setState(() {
        _pairing = false;
        _status = 'WiFi pairing failed: $e';
      });
    }
  }

  Future<void> _stopPairing() async {
    debugPrint("Stopping pairing process...");
    try {
      await TuyaFlutterHaSdk.stopConfigWiFi();
    } catch (_) {}
    setState(() {
      _pairing = false;
      _scanning = false;
      _status = 'Pairing cancelled';
    });
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  void dispose() {
    _pairingEventSub?.cancel();
    _ssidController.dispose();
    _wifiPwdController.dispose();
    if (_pairing) TuyaFlutterHaSdk.stopConfigWiFi();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Pair Device')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Mode selector ──
            Text('Pairing Mode',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(
                    value: 'ble',
                    label: Text('BLE'),
                    icon: Icon(Icons.bluetooth)),
                ButtonSegment(
                    value: 'combo',
                    label: Text('Combo'),
                    icon: Icon(Icons.swap_horiz)),
                ButtonSegment(
                    value: 'wifi',
                    label: Text('WiFi'),
                    icon: Icon(Icons.wifi)),
              ],
              selected: {_mode},
              onSelectionChanged: (s) => setState(() => _mode = s.first),
            ),

            const SizedBox(height: 24),

            // ── BLE Scan section (for BLE and Combo modes) ──
            if (_mode == 'ble' || _mode == 'combo') ...[
              Text('Step 1: Scan for Device',
                  style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: OutlinedButton.icon(
                  onPressed: (_scanning || _pairing) ? null : _startBleScan,
                  icon: _scanning
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.bluetooth_searching),
                  label: Text(_scanning ? 'Scanning…' : 'Scan for BLE Devices'),
                ),
              ),

              // ── Discovered device card ──
              if (_discoveredDevice != null) ...[
                const SizedBox(height: 12),
                Card(
                  color: cs.primaryContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.devices, color: cs.onPrimaryContainer),
                            const SizedBox(width: 8),
                            Text('Device Found',
                                style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: cs.onPrimaryContainer)),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                            'Name: ${_discoveredDevice!['name'] ?? 'Unknown'}',
                            style:
                                TextStyle(color: cs.onPrimaryContainer)),
                        Text(
                            'UUID: ${_discoveredDevice!['uuid'] ?? 'N/A'}',
                            style: TextStyle(
                                color: cs.onPrimaryContainer, fontSize: 12)),
                        Text(
                            'Product: ${_discoveredDevice!['productId'] ?? 'N/A'}',
                            style: TextStyle(
                                color: cs.onPrimaryContainer, fontSize: 12)),
                        if (_discoveredDevice!['bleType'] != null)
                          Text(
                              'BLE Type: ${_discoveredDevice!['bleType']}',
                              style: TextStyle(
                                  color: cs.onPrimaryContainer, fontSize: 12)),
                        if (_discoveredDevice!['configType']
                                ?.toString()
                                .contains('wifi') ==
                            true)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              'This device requires WiFi — use Combo mode',
                              style: TextStyle(
                                color: cs.error,
                                fontWeight: FontWeight.bold,
                                fontSize: 12,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 16),
            ],

            // ── WiFi fields (for Combo and WiFi modes) ──
            if (_mode == 'combo' || _mode == 'wifi') ...[
              Text(
                  _mode == 'combo'
                      ? 'Step 2: WiFi Credentials'
                      : 'WiFi Credentials',
                  style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              TextField(
                controller: _ssidController,
                decoration: const InputDecoration(
                  labelText: 'WiFi SSID',
                  prefixIcon: Icon(Icons.wifi),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _wifiPwdController,
                decoration: InputDecoration(
                  labelText: 'WiFi Password',
                  prefixIcon: const Icon(Icons.lock_outline),
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: Icon(_obscureWifiPwd
                        ? Icons.visibility_off
                        : Icons.visibility),
                    onPressed: () =>
                        setState(() => _obscureWifiPwd = !_obscureWifiPwd),
                  ),
                ),
                obscureText: _obscureWifiPwd,
              ),
              const SizedBox(height: 16),
            ],

            // ── Status card ──
            if (_status.isNotEmpty)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      if (_pairing || _scanning)
                        const Padding(
                          padding: EdgeInsets.only(right: 12),
                          child: SizedBox(
                            width: 20,
                            height: 20,
                            child:
                                CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      Expanded(child: Text(_status)),
                    ],
                  ),
                ),
              ),

            const SizedBox(height: 24),

            // ── Action button ──
            SizedBox(
              width: double.infinity,
              height: 48,
              child: _pairing
                  ? OutlinedButton.icon(
                      onPressed: _stopPairing,
                      icon: const Icon(Icons.stop),
                      label: const Text('Stop Pairing'),
                    )
                  : FilledButton.icon(
                      onPressed: _scanning
                          ? null
                          : () {
                              switch (_mode) {
                                case 'ble':
                                  _pairBle();
                                  break;
                                case 'combo':
                                  _pairCombo();
                                  break;
                                case 'wifi':
                                  _pairWifi();
                                  break;
                              }
                            },
                      icon: const Icon(Icons.link),
                      label: Text(_mode == 'ble'
                          ? 'Pair BLE Device'
                          : _mode == 'combo'
                              ? 'Start Combo Pairing'
                              : 'Start WiFi Pairing'),
                    ),
            ),

            const SizedBox(height: 32),

            // ── Instructions ──
            Card(
              color: cs.surfaceContainerHighest,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Instructions',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    if (_mode == 'ble') ...[
                      const Text(
                          '1. Put your device in pairing mode (usually long-press the reset button)'),
                      const SizedBox(height: 4),
                      const Text(
                          '2. Tap "Scan for BLE Devices" to find nearby devices'),
                      const SizedBox(height: 4),
                      const Text(
                          '3. Once found, tap "Pair BLE Device" to connect'),
                      const SizedBox(height: 4),
                      const Text(
                          '⚡ Best for: Smart locks, sensors, BLE-only devices'),
                    ],
                    if (_mode == 'combo') ...[
                      const Text(
                          '1. Put your device in pairing mode'),
                      const SizedBox(height: 4),
                      const Text(
                          '2. Scan to find the device via BLE'),
                      const SizedBox(height: 4),
                      const Text(
                          '3. Enter your home WiFi credentials'),
                      const SizedBox(height: 4),
                      const Text(
                          '4. The device connects via BLE, then switches to WiFi'),
                      const SizedBox(height: 4),
                      const Text(
                          '⚡ Best for: Dual-mode devices (BLE + WiFi)'),
                    ],
                    if (_mode == 'wifi') ...[
                      const Text(
                          '1. Put your device in fast-blink mode (EZ mode)'),
                      const SizedBox(height: 4),
                      const Text(
                          '2. Enter your WiFi credentials'),
                      const SizedBox(height: 4),
                      const Text(
                          '3. Tap "Start WiFi Pairing"'),
                      const SizedBox(height: 4),
                      const Text(
                          '⚠️ Phone must be on 2.4GHz WiFi network'),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
