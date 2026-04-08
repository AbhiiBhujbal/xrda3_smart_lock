import 'dart:async';
import 'package:flutter/material.dart';
import 'package:tuya_flutter_ha_sdk/tuya_flutter_ha_sdk.dart';
import '../services/camera_talk_service.dart';
import '../services/permissions_service.dart';

class CameraScreen extends StatefulWidget {
  final int homeId;
  const CameraScreen({super.key, required this.homeId});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  List<Map<String, dynamic>> _cameras = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadCameras();
  }

  Future<void> _loadCameras() async {
    setState(() => _loading = true);
    try {
      final cameras =
          await TuyaFlutterHaSdk.listCameras(homeId: widget.homeId);
      setState(() {
        _cameras = cameras;
        _loading = false;
      });
    } catch (e) {
      _showSnackBar('Failed to load cameras: $e');
      setState(() => _loading = false);
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
      appBar: AppBar(title: const Text('Cameras')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _cameras.isEmpty
              ? const Center(child: Text('No cameras found'))
              : RefreshIndicator(
                  onRefresh: _loadCameras,
                  child: ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: _cameras.length,
                    itemBuilder: (context, index) {
                      final camera = _cameras[index];
                      final devId =
                          camera['devId'] ?? camera['id'] ?? '';
                      final name = camera['name'] ?? 'Camera';

                      return Card(
                        child: ListTile(
                          leading: const CircleAvatar(
                              child: Icon(Icons.videocam)),
                          title: Text(name),
                          subtitle: Text('ID: $devId'),
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => CameraLiveScreen(
                                deviceId: devId,
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

/// Full-featured camera live view with intercom / two-way talk.
class CameraLiveScreen extends StatefulWidget {
  final String deviceId;
  final String deviceName;

  const CameraLiveScreen({
    super.key,
    required this.deviceId,
    required this.deviceName,
  });

  @override
  State<CameraLiveScreen> createState() => _CameraLiveScreenState();
}

class _CameraLiveScreenState extends State<CameraLiveScreen> {
  bool _streaming = false;
  bool _recording = false;
  Map<String, dynamic>? _capabilities;
  List<dynamic> _alerts = [];

  // ── Intercom state ──
  bool _talkSupported = false;
  int _talkMode = 1; // 1=one-way, 2=two-way
  bool _talking = false;
  bool _muted = false;
  bool _speakerOn = true;

  // ── Doorbell ──
  StreamSubscription? _doorbellSub;
  bool _doorbellRinging = false;

  final _talkService = CameraTalkService.instance;

  @override
  void initState() {
    super.initState();
    _loadCapabilities();
    _checkTalkSupport();
    _listenDoorbell();
  }

  Future<void> _loadCapabilities() async {
    try {
      final caps = await TuyaFlutterHaSdk.getCameraCapabilities(
        deviceId: widget.deviceId,
      );
      setState(() => _capabilities = caps);
    } catch (e) {
      debugPrint('Capabilities error: $e');
    }
  }

  Future<void> _checkTalkSupport() async {
    final supported =
        await _talkService.isTalkSupported(widget.deviceId);
    final mode = await _talkService.getTalkMode(widget.deviceId);
    if (mounted) {
      setState(() {
        _talkSupported = supported;
        _talkMode = mode;
      });
    }
  }

  void _listenDoorbell() {
    _talkService.startListeningDoorbell();
    _doorbellSub = _talkService.doorbellEvents.listen((event) {
      if (event.devId == widget.deviceId && mounted) {
        setState(() => _doorbellRinging = true);
        _showDoorbellDialog(event);
      }
    });
  }

  // ── Stream controls ──

  Future<void> _toggleStream() async {
    try {
      if (_streaming) {
        await TuyaFlutterHaSdk.stopLiveStream(
            deviceId: widget.deviceId);
      } else {
        await TuyaFlutterHaSdk.startLiveStream(
            deviceId: widget.deviceId);
      }
      setState(() => _streaming = !_streaming);
    } catch (e) {
      _showSnackBar('Stream error: $e');
    }
  }

  Future<void> _toggleRecording() async {
    try {
      if (_recording) {
        await TuyaFlutterHaSdk.stopSaveVideoToGallery();
      } else {
        await TuyaFlutterHaSdk.saveVideoToGallery(filePath: '');
      }
      setState(() => _recording = !_recording);
      _showSnackBar(
          _recording ? 'Recording started' : 'Recording saved');
    } catch (e) {
      _showSnackBar('Recording error: $e');
    }
  }

  // ── Intercom controls ──

  Future<void> _toggleTalk() async {
    // Request mic permission first
    if (!_talking) {
      final hasPerm = await PermissionsService.instance
          .ensureCameraPermissions(context);
      if (!hasPerm) {
        _showSnackBar('Microphone permission required for intercom');
        return;
      }
    }

    if (_talking) {
      final ok = await _talkService.stopTalk(widget.deviceId);
      if (ok && mounted) setState(() => _talking = false);
    } else {
      final ok = await _talkService.startTalk(widget.deviceId);
      if (ok && mounted) {
        setState(() => _talking = true);
      } else {
        _showSnackBar('Failed to start talk');
      }
    }
  }

  Future<void> _toggleMute() async {
    final ok =
        await _talkService.setMute(widget.deviceId, !_muted);
    if (ok && mounted) setState(() => _muted = !_muted);
  }

  Future<void> _toggleSpeaker() async {
    final ok = await _talkService.enableSpeaker(
        widget.deviceId, !_speakerOn);
    if (ok && mounted) setState(() => _speakerOn = !_speakerOn);
  }

  // ── Doorbell ──

  void _showDoorbellDialog(DoorbellEvent event) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.doorbell, size: 48, color: Colors.orange),
        title: const Text('Doorbell Ringing!'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Someone is at the door'),
            if (event.snapshot != null) ...[
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.network(
                  event.snapshot!,
                  height: 150,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) =>
                      const Icon(Icons.image_not_supported, size: 48),
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              setState(() => _doorbellRinging = false);
            },
            child: const Text('Decline'),
          ),
          FilledButton.icon(
            onPressed: () async {
              Navigator.pop(ctx);
              setState(() => _doorbellRinging = false);
              // Start stream + talk when answering
              if (!_streaming) await _toggleStream();
              if (!_talking) await _toggleTalk();
            },
            icon: const Icon(Icons.call),
            label: const Text('Answer'),
          ),
        ],
      ),
    );
  }

  // ── Alerts ──

  Future<void> _loadAlerts() async {
    try {
      final now = DateTime.now();
      final alerts = await TuyaFlutterHaSdk.getDeviceAlerts(
        deviceId: widget.deviceId,
        year: now.year,
        month: now.month,
      );
      setState(() => _alerts = alerts);
    } catch (e) {
      _showSnackBar('Alerts error: $e');
    }
  }

  Future<void> _showDpConfigs() async {
    try {
      final configs = await TuyaFlutterHaSdk.getDeviceDpConfigs(
        deviceId: widget.deviceId,
      );
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('DP Configs'),
          content: SingleChildScrollView(child: Text('$configs')),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    } catch (e) {
      _showSnackBar('DP config error: $e');
    }
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  void dispose() {
    _doorbellSub?.cancel();
    if (_talking) _talkService.stopTalk(widget.deviceId);
    if (_streaming) {
      TuyaFlutterHaSdk.stopLiveStream(deviceId: widget.deviceId);
    }
    _talkService.destroyP2P(widget.deviceId);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.deviceName),
        actions: [
          if (_doorbellRinging)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Icon(Icons.doorbell, color: Colors.orange, size: 22),
            ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: _showDpConfigs,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── Stream preview ──
          AspectRatio(
            aspectRatio: 16 / 9,
            child: Container(
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Center(
                child: _streaming
                    ? Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.videocam,
                              size: 48, color: Colors.white54),
                          const SizedBox(height: 8),
                          const Text('Live Stream Active',
                              style: TextStyle(color: Colors.white70)),
                          const Text(
                            '(Native view rendered by platform)',
                            style: TextStyle(
                                color: Colors.white38, fontSize: 12),
                          ),
                          if (_talking)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 4),
                                decoration: BoxDecoration(
                                  color: Colors.red.withAlpha(180),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.mic, color: Colors.white,
                                        size: 16),
                                    SizedBox(width: 4),
                                    Text('TALKING',
                                        style: TextStyle(
                                            color: Colors.white,
                                            fontSize: 12,
                                            fontWeight: FontWeight.bold)),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      )
                    : const Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.videocam_off,
                              size: 48, color: Colors.white38),
                          SizedBox(height: 8),
                          Text('Tap Play to start stream',
                              style: TextStyle(color: Colors.white54)),
                        ],
                      ),
              ),
            ),
          ),

          const SizedBox(height: 16),

          // ── Stream controls row ──
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              FilledButton.icon(
                onPressed: _toggleStream,
                icon: Icon(_streaming ? Icons.stop : Icons.play_arrow),
                label: Text(_streaming ? 'Stop' : 'Play'),
                style: FilledButton.styleFrom(
                  backgroundColor:
                      _streaming ? cs.error : cs.primary,
                ),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: _streaming ? _toggleRecording : null,
                icon: Icon(
                  _recording
                      ? Icons.stop_circle
                      : Icons.fiber_manual_record,
                  color: _recording ? Colors.red : null,
                ),
                label: Text(_recording ? 'Stop Rec' : 'Record'),
              ),
            ],
          ),

          const SizedBox(height: 20),

          // ── Intercom / Two-Way Talk Card ──
          if (_talkSupported)
            _buildIntercomCard(cs)
          else
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Icon(Icons.mic_off, color: cs.onSurfaceVariant),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Two-way talk not supported by this device',
                        style: TextStyle(color: cs.onSurfaceVariant),
                      ),
                    ),
                  ],
                ),
              ),
            ),

          const SizedBox(height: 16),

          // ── Capabilities ──
          if (_capabilities != null) ...[
            Text('Capabilities',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text('$_capabilities'),
              ),
            ),
            const SizedBox(height: 16),
          ],

          // ── Alerts ──
          FilledButton.tonal(
            onPressed: _loadAlerts,
            child: const Text('Load Alerts'),
          ),
          if (_alerts.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text('Alerts (${_alerts.length})',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            ..._alerts.take(20).map(
              (alert) => Card(
                child: ListTile(
                  leading: const Icon(Icons.notification_important),
                  title: Text(
                      '${alert['msgTitle'] ?? alert['type'] ?? 'Alert'}'),
                  subtitle:
                      Text('${alert['time'] ?? alert['dateTime'] ?? ''}'),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Intercom card with talk, mute, and speaker controls.
  Widget _buildIntercomCard(ColorScheme cs) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.record_voice_over, color: cs.primary, size: 20),
                const SizedBox(width: 8),
                Text(
                  'Intercom',
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: cs.primaryContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    _talkMode == 2 ? 'Full Duplex' : 'Push to Talk',
                    style: TextStyle(
                      fontSize: 11,
                      color: cs.onPrimaryContainer,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Talk button (large, prominent)
            SizedBox(
              width: double.infinity,
              height: 52,
              child: _talking
                  ? FilledButton.icon(
                      onPressed: _streaming ? _toggleTalk : null,
                      icon: const Icon(Icons.mic_off),
                      label: const Text('Stop Talking'),
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.red,
                        foregroundColor: Colors.white,
                      ),
                    )
                  : FilledButton.icon(
                      onPressed: _streaming ? _toggleTalk : null,
                      icon: const Icon(Icons.mic),
                      label: Text(_talkMode == 2
                          ? 'Start Two-Way Talk'
                          : 'Hold to Talk'),
                      style: FilledButton.styleFrom(
                        backgroundColor: cs.primary,
                      ),
                    ),
            ),

            if (!_streaming)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Start the live stream first to use intercom',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: cs.error),
                ),
              ),

            const SizedBox(height: 12),

            // Audio controls row
            Row(
              children: [
                // Mute button
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _streaming ? _toggleMute : null,
                    icon: Icon(
                      _muted ? Icons.volume_off : Icons.volume_up,
                      size: 18,
                    ),
                    label: Text(_muted ? 'Unmute' : 'Mute'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 42),
                      foregroundColor:
                          _muted ? cs.error : cs.onSurface,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                // Speaker button
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _streaming ? _toggleSpeaker : null,
                    icon: Icon(
                      _speakerOn
                          ? Icons.speaker_phone
                          : Icons.phone_in_talk,
                      size: 18,
                    ),
                    label: Text(
                        _speakerOn ? 'Speaker On' : 'Speaker Off'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 42),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
