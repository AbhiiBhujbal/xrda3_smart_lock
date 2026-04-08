import 'package:flutter/material.dart';

/// Simple location picker dialog that lets users enter coordinates or a place name.
/// For a full OpenStreetMap integration, add flutter_map + latlong2 packages.
/// This lightweight version works without extra dependencies.
class LocationPickerDialog extends StatefulWidget {
  final double initialLat;
  final double initialLng;
  final String initialGeoName;

  const LocationPickerDialog({
    super.key,
    this.initialLat = 0.0,
    this.initialLng = 0.0,
    this.initialGeoName = '',
  });

  @override
  State<LocationPickerDialog> createState() => _LocationPickerDialogState();
}

class _LocationPickerDialogState extends State<LocationPickerDialog> {
  late final TextEditingController _latController;
  late final TextEditingController _lngController;
  late final TextEditingController _geoNameController;

  @override
  void initState() {
    super.initState();
    _latController =
        TextEditingController(text: widget.initialLat.toStringAsFixed(6));
    _lngController =
        TextEditingController(text: widget.initialLng.toStringAsFixed(6));
    _geoNameController = TextEditingController(text: widget.initialGeoName);
  }

  @override
  void dispose() {
    _latController.dispose();
    _lngController.dispose();
    _geoNameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Set Location'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _geoNameController,
              decoration: const InputDecoration(
                labelText: 'Place Name',
                hintText: 'e.g. Mumbai, India',
                prefixIcon: Icon(Icons.place),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _latController,
                    decoration: const InputDecoration(
                      labelText: 'Latitude',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true, signed: true),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _lngController,
                    decoration: const InputDecoration(
                      labelText: 'Longitude',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true, signed: true),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              'Enter your home location for weather and local services.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.pop(context, {
              'latitude': double.tryParse(_latController.text) ?? 0.0,
              'longitude': double.tryParse(_lngController.text) ?? 0.0,
              'geoName': _geoNameController.text,
            });
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// Show the location picker dialog and return the result.
Future<Map<String, dynamic>?> showLocationPicker(
  BuildContext context, {
  double lat = 0.0,
  double lng = 0.0,
  String geoName = '',
}) {
  return showDialog<Map<String, dynamic>>(
    context: context,
    builder: (_) => LocationPickerDialog(
      initialLat: lat,
      initialLng: lng,
      initialGeoName: geoName,
    ),
  );
}
