import 'package:flutter/material.dart';

/// Bottom sheet to choose pairing mode before navigating to the pairing screen.
/// Returns the selected mode: 'ble', 'wifi', or null if cancelled.
Future<String?> showAddDeviceBottomSheet(BuildContext context) {
  print("Inside add device  bootom class");
  return showModalBottomSheet<String>(

    context: context,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) {
      final cs = Theme.of(ctx).colorScheme;
      return Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Handle bar
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 20),
              decoration: BoxDecoration(
                color: cs.onSurfaceVariant.withAlpha(60),
                borderRadius: BorderRadius.circular(2),
              ),
            ),

            Text(
              'Add Device',
              style: Theme.of(ctx).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              'Choose how to pair your device',
              style: Theme.of(ctx).textTheme.bodyMedium?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 24),

            // BLE option
            _PairingOptionCard(
              icon: Icons.bluetooth,
              iconColor: Colors.blue,
              title: 'Bluetooth (BLE)',
              subtitle: 'Smart locks, sensors, BLE-only devices',
              onTap: () => Navigator.pop(ctx, 'ble'),
            ),
            const SizedBox(height: 12),

            // WiFi option
            _PairingOptionCard(
              icon: Icons.wifi,
              iconColor: Colors.green,
              title: 'WiFi',
              subtitle: 'Plugs, lights, cameras (2.4GHz)',
              onTap: () => Navigator.pop(ctx, 'wifi'),
            ),
            const SizedBox(height: 12),

            // Combo option
            _PairingOptionCard(
              icon: Icons.swap_horiz,
              iconColor: Colors.orange,
              title: 'Combo (BLE + WiFi)',
              subtitle: 'Dual-mode devices that use both',
              onTap: () => Navigator.pop(ctx, 'combo'),
            ),
          ],
        ),
      );
    },
  );
}

class _PairingOptionCard extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _PairingOptionCard({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      color: cs.surfaceContainerHighest,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        leading: CircleAvatar(
          backgroundColor: iconColor.withAlpha(30),
          child: Icon(icon, color: iconColor),
        ),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(subtitle, style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12)),
        trailing: Icon(Icons.chevron_right, color: cs.onSurfaceVariant),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        onTap: onTap,
      ),
    );
  }
}
