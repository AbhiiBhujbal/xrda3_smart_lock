import 'package:flutter/material.dart';
import 'package:tuya_flutter_ha_sdk/tuya_flutter_ha_sdk.dart';

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
      final cameras = await TuyaFlutterHaSdk.listCameras(homeId: widget.homeId);
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
                      final devId = camera['devId'] ?? camera['id'] ?? '';
                      final name = camera['name'] ?? 'Camera';

                      return Card(
                        child: ListTile(
                          leading: const CircleAvatar(child: Icon(Icons.videocam)),
                          title: Text(name),
                          subtitle: Text('ID: $devId'),
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => _CameraLiveScreen(
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

class _CameraLiveScreen extends StatefulWidget {
  final String deviceId;
  final String deviceName;

  const _CameraLiveScreen({
    required this.deviceId,
    required this.deviceName,
  });

  @override
  State<_CameraLiveScreen> createState() => _CameraLiveScreenState();
}

class _CameraLiveScreenState extends State<_CameraLiveScreen> {
  bool _streaming = false;
  bool _recording = false;
  Map<String, dynamic>? _capabilities;
  List<dynamic> _alerts = [];

  @override
  void initState() {
    super.initState();
    _loadCapabilities();
  }

  Future<void> _loadCapabilities() async {
    try {
      final caps = await TuyaFlutterHaSdk.getCameraCapabilities(
        deviceId: widget.deviceId,
      );
      setState(() {
        _capabilities = caps;
      });
    } catch (e) {
      debugPrint('Capabilities error: $e');
    }
  }

  Future<void> _toggleStream() async {
    try {
      if (_streaming) {
        await TuyaFlutterHaSdk.stopLiveStream(deviceId: widget.deviceId);
      } else {
        await TuyaFlutterHaSdk.startLiveStream(deviceId: widget.deviceId);
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
      _showSnackBar(_recording ? 'Recording started' : 'Recording saved');
    } catch (e) {
      _showSnackBar('Recording error: $e');
    }
  }

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
          content: SingleChildScrollView(
            child: Text('$configs'),
          ),
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
    if (_streaming) {
      TuyaFlutterHaSdk.stopLiveStream(deviceId: widget.deviceId);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.deviceName),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: _showDpConfigs,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Stream preview placeholder
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
                          Icon(Icons.videocam, size: 48, color: Colors.white54),
                          const SizedBox(height: 8),
                          Text(
                            'Live Stream Active',
                            style: TextStyle(color: Colors.white70),
                          ),
                          const Text(
                            '(Native view rendered by platform)',
                            style: TextStyle(color: Colors.white38, fontSize: 12),
                          ),
                        ],
                      )
                    : const Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.videocam_off, size: 48, color: Colors.white38),
                          SizedBox(height: 8),
                          Text(
                            'Tap Play to start stream',
                            style: TextStyle(color: Colors.white54),
                          ),
                        ],
                      ),
              ),
            ),
          ),

          const SizedBox(height: 16),

          // Stream controls
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              FilledButton.icon(
                onPressed: _toggleStream,
                icon: Icon(_streaming ? Icons.stop : Icons.play_arrow),
                label: Text(_streaming ? 'Stop' : 'Play'),
                style: FilledButton.styleFrom(
                  backgroundColor: _streaming ? cs.error : cs.primary,
                ),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: _streaming ? _toggleRecording : null,
                icon: Icon(
                  _recording ? Icons.stop_circle : Icons.fiber_manual_record,
                  color: _recording ? Colors.red : null,
                ),
                label: Text(_recording ? 'Stop Rec' : 'Record'),
              ),
            ],
          ),

          const SizedBox(height: 24),

          // Capabilities
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

          // Alerts
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
                  title: Text('${alert['msgTitle'] ?? alert['type'] ?? 'Alert'}'),
                  subtitle: Text('${alert['time'] ?? alert['dateTime'] ?? ''}'),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
