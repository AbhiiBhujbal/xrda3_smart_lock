import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

/// Handles runtime permission requests for BLE, Location, and Camera.
class PermissionsService {
  PermissionsService._();
  static final instance = PermissionsService._();

  /// Request BLE permissions (Android 12+: BLUETOOTH_SCAN + BLUETOOTH_CONNECT).
  /// Returns true if all granted.
  Future<bool> ensureBlePermissions(BuildContext context) async {
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();

    final allGranted = statuses.values.every(
      (s) => s.isGranted || s.isLimited,
    );

    if (!allGranted && context.mounted) {
      final denied = statuses.entries
          .where((e) => !e.value.isGranted && !e.value.isLimited)
          .map((e) => e.key.toString().split('.').last)
          .join(', ');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Permissions needed: $denied'),
          action: SnackBarAction(
            label: 'Settings',
            onPressed: openAppSettings,
          ),
        ),
      );
    }

    return allGranted;
  }

  /// Request WiFi scan permissions (location required for WiFi scanning).
  Future<bool> ensureWifiPermissions(BuildContext context) async {
    final status = await Permission.locationWhenInUse.request();

    if (!status.isGranted && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Location permission needed for WiFi scanning'),
          action: SnackBarAction(
            label: 'Settings',
            onPressed: openAppSettings,
          ),
        ),
      );
    }

    return status.isGranted;
  }

  /// Request camera + microphone permissions.
  Future<bool> ensureCameraPermissions(BuildContext context) async {
    final statuses = await [
      Permission.camera,
      Permission.microphone,
    ].request();

    return statuses.values.every((s) => s.isGranted || s.isLimited);
  }
}
