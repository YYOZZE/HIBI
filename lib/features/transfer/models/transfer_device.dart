/// 局域网内发现的设备（与 LANDrop 发现协议一致）
/// [platform] 用于 UI 显示设备图标；[deviceId] 用于去重（同一设备多网卡只显示一条）
class TransferDevice {
  TransferDevice({
    required this.name,
    required this.type,
    required this.address,
    required this.port,
    this.platform,
    this.deviceId,
    this.protocolVersion,
    DateTime? lastSeen,
  }) : lastSeen = lastSeen ?? DateTime.now();

  final String name;
  final String type;
  final String address;
  final int port;

  /// 发送端平台，如 windows / android / ios / ipad，用于显示对应图标
  final String? platform;

  /// 发送端设备唯一 ID，用于同一设备多网卡去重
  final String? deviceId;

  /// 传输协议版本；null 表示旧版/手动设备，按基础兼容模式发送。
  final int? protocolVersion;

  /// 最近一次收到该设备广播的时间，用于自动移除离线设备和避免使用陈旧端口。
  final DateTime lastSeen;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TransferDevice &&
          runtimeType == other.runtimeType &&
          (deviceId != null && other.deviceId == deviceId ||
              (address == other.address && port == other.port));

  @override
  int get hashCode =>
      deviceId != null ? deviceId.hashCode : Object.hash(address, port);
}
