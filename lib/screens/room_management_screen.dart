import 'package:flutter/material.dart';
import 'package:tuya_flutter_ha_sdk/tuya_flutter_ha_sdk.dart';

class RoomManagementScreen extends StatefulWidget {
  final int homeId;
  const RoomManagementScreen({super.key, required this.homeId});

  @override
  State<RoomManagementScreen> createState() => _RoomManagementScreenState();
}

class _RoomManagementScreenState extends State<RoomManagementScreen> {
  List<dynamic> _rooms = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadRooms();
  }

  Future<void> _loadRooms() async {
    setState(() => _loading = true);
    try {
      final rooms = await TuyaFlutterHaSdk.getRoomList(homeId: widget.homeId);
      setState(() {
        _rooms = rooms ?? [];
        _loading = false;
      });
    } catch (e) {
      _showSnackBar('Failed to load rooms: $e');
      setState(() => _loading = false);
    }
  }

  Future<void> _addRoom() async {
    final name = await _showTextInputDialog('Add Room', 'Room Name');
    if (name == null || name.isEmpty) return;

    try {
      await TuyaFlutterHaSdk.addRoom(homeId: widget.homeId, roomName: name);
      _showSnackBar('Room added');
      _loadRooms();
    } catch (e) {
      _showSnackBar('Failed to add room: $e');
    }
  }

  Future<void> _renameRoom(dynamic room) async {
    final roomId = room['roomId'] ?? room['id'];
    final name = await _showTextInputDialog(
      'Rename Room',
      'New Name',
      initialValue: room['name'] ?? '',
    );
    if (name == null || name.isEmpty) return;

    try {
      await TuyaFlutterHaSdk.updateRoomName(
        homeId: widget.homeId,
        roomId: roomId,
        roomName: name,
      );
      _showSnackBar('Room renamed');
      _loadRooms();
    } catch (e) {
      _showSnackBar('Failed to rename: $e');
    }
  }

  Future<void> _removeRoom(dynamic room) async {
    final roomId = room['roomId'] ?? room['id'];
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove Room'),
        content: Text('Remove "${room['name']}"?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
        ],
      ),
    );
    if (confirm != true) return;

    try {
      await TuyaFlutterHaSdk.removeRoom(homeId: widget.homeId, roomId: roomId);
      _showSnackBar('Room removed');
      _loadRooms();
    } catch (e) {
      _showSnackBar('Failed to remove: $e');
    }
  }

  Future<String?> _showTextInputDialog(
    String title,
    String label, {
    String initialValue = '',
  }) async {
    final controller = TextEditingController(text: initialValue);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(labelText: label),
          autofocus: true,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('OK'),
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
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Room Management')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addRoom,
        icon: const Icon(Icons.add),
        label: const Text('Add Room'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _rooms.isEmpty
              ? const Center(child: Text('No rooms in this home'))
              : RefreshIndicator(
                  onRefresh: _loadRooms,
                  child: ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: _rooms.length,
                    itemBuilder: (context, index) {
                      final room = _rooms[index];
                      return Card(
                        child: ListTile(
                          leading: const CircleAvatar(child: Icon(Icons.meeting_room)),
                          title: Text(room['name'] ?? 'Room'),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.edit),
                                onPressed: () => _renameRoom(room),
                              ),
                              IconButton(
                                icon: const Icon(Icons.delete_outline),
                                onPressed: () => _removeRoom(room),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
    );
  }
}
