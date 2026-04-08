import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

/// Flutter wrapper for native camera two-way talk / intercom APIs.
class CameraTalkService {
  CameraTalkService._();
  static final instance = CameraTalkService._();

  static const _channel = MethodChannel('xrda3_camera/talk');
  static const _doorbellChannel = EventChannel('xrda3_camera/doorbell_events');

  StreamSubscription? _doorbellSub;
  final _doorbellController = StreamController<DoorbellEvent>.broadcast();

  /// Stream of doorbell ring events.
  Stream<DoorbellEvent> get doorbellEvents => _doorbellController.stream;

  /// Start listening for doorbell ring events from native.
  void startListeningDoorbell() {
    _doorbellSub?.cancel();
    _doorbellSub = _doorbellChannel.receiveBroadcastStream().listen(
      (event) {
        if (event is Map) {
          final map = Map<String, dynamic>.from(event);
          if (map['event'] == 'doorbell_ring') {
            _doorbellController.add(DoorbellEvent(
              devId: map['devId']?.toString() ?? '',
              snapshot: map['snapshot']?.toString(),
              timestamp: DateTime.fromMillisecondsSinceEpoch(
                (map['timestamp'] as int?) ?? 0,
              ),
            ));
          }
        }
      },
      onError: (e) => debugPrint('Doorbell event error: $e'),
    );
  }

  /// Check if a device supports two-way talk.
  Future<bool> isTalkSupported(String devId) async {
    try {
      return await _channel.invokeMethod<bool>(
            'isTalkSupported',
            {'devId': devId},
          ) ??
          false;
    } catch (e) {
      debugPrint('isTalkSupported error: $e');
      return false;
    }
  }

  /// Get talk mode: 1 = one-way (push-to-talk), 2 = two-way (full duplex).
  Future<int> getTalkMode(String devId) async {
    try {
      return await _channel.invokeMethod<int>(
            'getTalkMode',
            {'devId': devId},
          ) ??
          1;
    } catch (e) {
      debugPrint('getTalkMode error: $e');
      return 1;
    }
  }

  /// Start two-way audio talk.
  Future<bool> startTalk(String devId) async {
    try {
      return await _channel.invokeMethod<bool>(
            'startTalk',
            {'devId': devId},
          ) ??
          false;
    } catch (e) {
      debugPrint('startTalk error: $e');
      return false;
    }
  }

  /// Stop two-way audio talk.
  Future<bool> stopTalk(String devId) async {
    try {
      return await _channel.invokeMethod<bool>(
            'stopTalk',
            {'devId': devId},
          ) ??
          false;
    } catch (e) {
      debugPrint('stopTalk error: $e');
      return false;
    }
  }

  /// Mute or unmute the camera speaker.
  Future<bool> setMute(String devId, bool mute) async {
    try {
      return await _channel.invokeMethod<bool>(
            'setMute',
            {'devId': devId, 'mute': mute},
          ) ??
          false;
    } catch (e) {
      debugPrint('setMute error: $e');
      return false;
    }
  }

  /// Enable or disable the speaker (audio output).
  Future<bool> enableSpeaker(String devId, bool enable) async {
    try {
      return await _channel.invokeMethod<bool>(
            'enableSpeaker',
            {'devId': devId, 'enable': enable},
          ) ??
          false;
    } catch (e) {
      debugPrint('enableSpeaker error: $e');
      return false;
    }
  }

  /// Destroy the P2P session for a camera.
  Future<void> destroyP2P(String devId) async {
    try {
      await _channel.invokeMethod('destroyP2P', {'devId': devId});
    } catch (e) {
      debugPrint('destroyP2P error: $e');
    }
  }

  void dispose() {
    _doorbellSub?.cancel();
    _doorbellController.close();
  }
}

/// Doorbell ring event from a video doorbell device.
class DoorbellEvent {
  final String devId;
  final String? snapshot;
  final DateTime timestamp;

  DoorbellEvent({
    required this.devId,
    this.snapshot,
    required this.timestamp,
  });
}
