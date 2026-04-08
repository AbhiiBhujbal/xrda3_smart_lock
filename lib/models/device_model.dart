/// Typed model for a discovered BLE device during pairing.
class DiscoveredDevice {
  final String uuid;
  final String productId;
  final String? name;
  final int? deviceType;
  final String? address;
  final int? flag;
  final String configType;
  final String? bleType;

  DiscoveredDevice({
    required this.uuid,
    required this.productId,
    this.name,
    this.deviceType,
    this.address,
    this.flag,
    this.configType = '',
    this.bleType,
  });

  factory DiscoveredDevice.fromMap(Map<String, dynamic> map) {
    return DiscoveredDevice(
      uuid: map['uuid']?.toString() ?? '',
      productId: map['productId']?.toString() ?? '',
      name: map['name']?.toString(),
      deviceType: map['deviceType'] as int?,
      address: map['address']?.toString(),
      flag: map['flag'] as int?,
      configType: map['configType']?.toString() ?? '',
      bleType: map['bleType']?.toString(),
    );
  }

  bool get isValid => uuid.isNotEmpty && productId.isNotEmpty;
  bool get requiresWifi => configType.contains('wifi');

  Map<String, dynamic> toMap() => {
        'uuid': uuid,
        'productId': productId,
        'name': name,
        'deviceType': deviceType,
        'address': address,
        'flag': flag,
        'configType': configType,
        'bleType': bleType,
      };
}

/// Typed model for a Tuya home device.
class TuyaDevice {
  final String devId;
  final String name;
  final bool isOnline;
  final String? category;
  final String? productId;
  final String? iconUrl;
  final Map<String, dynamic> dps;

  TuyaDevice({
    required this.devId,
    required this.name,
    this.isOnline = false,
    this.category,
    this.productId,
    this.iconUrl,
    this.dps = const {},
  });

  factory TuyaDevice.fromMap(Map<String, dynamic> map) {
    return TuyaDevice(
      devId: map['devId']?.toString() ?? map['id']?.toString() ?? '',
      name: map['name']?.toString() ?? 'Device',
      isOnline: map['isOnline'] == true,
      category: map['category']?.toString(),
      productId: map['productId']?.toString(),
      iconUrl: map['iconUrl']?.toString(),
      dps: map['dps'] is Map
          ? Map<String, dynamic>.from(map['dps'] as Map)
          : {},
    );
  }

  bool get isLock {
    final cat = category?.toLowerCase() ?? '';
    return cat == 'ms' || cat == 'jtmspro' || cat.contains('lock') ||
        name.toLowerCase().contains('lock');
  }

  bool get isCamera {
    final cat = category?.toLowerCase() ?? '';
    return cat == 'sp' || cat.contains('camera');
  }
}

/// Typed model for a Tuya home.
class TuyaHome {
  final int homeId;
  final String name;
  final String? geoName;
  final double latitude;
  final double longitude;

  TuyaHome({
    required this.homeId,
    required this.name,
    this.geoName,
    this.latitude = 0.0,
    this.longitude = 0.0,
  });

  factory TuyaHome.fromMap(Map<String, dynamic> map) {
    return TuyaHome(
      homeId: map['homeId'] as int? ?? map['id'] as int? ?? 0,
      name: map['name']?.toString() ?? 'Home',
      geoName: map['geoName']?.toString(),
      latitude: (map['latitude'] as num?)?.toDouble() ?? 0.0,
      longitude: (map['longitude'] as num?)?.toDouble() ?? 0.0,
    );
  }
}
