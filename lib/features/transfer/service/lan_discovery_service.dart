import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../models/transfer_device.dart';
import '../transfer_save_path.dart';

/// HIBI 局域网发现服务。
///
/// 同时兼容当前 62637 系列、早期版本 52637 系列及用户自定义端口；
/// 发现请求既广播也要求对端单播回复，以改善 Android/Windows 非对称发现。
class LanDiscoveryService {
  LanDiscoveryService({
    this.deviceName = '希比-2023',
    this.deviceType = 'HIBI',
    this.platformTagOverride,
  });

  final String deviceName;
  final String deviceType;
  final String? platformTagOverride;

  static const int discoveryPort = 62637;
  static const List<int> discoveryPortFallbacks = [62637, 62638, 62639];
  static const List<int> legacyDiscoveryPorts = [52637, 52638, 52639];
  static const String protocolName = 'hibi-transfer';
  static const int protocolVersion = 3;

  List<int> _configuredPorts = List<int>.from(discoveryPortFallbacks);
  final List<RawDatagramSocket> _sockets = [];
  int? _serverPort;
  int? _boundPort;
  String? _deviceId;
  Timer? _broadcastTimer;
  List<InternetAddress> _subnetBroadcasts = [];

  final StreamController<TransferDevice> _deviceController =
      StreamController<TransferDevice>.broadcast();
  final StreamController<Object> _errorController =
      StreamController<Object>.broadcast();

  Stream<TransferDevice> get devices => _deviceController.stream;
  Stream<Object> get errors => _errorController.stream;
  int? get boundPort => _boundPort;

  List<int> get _targetPorts {
    final result = <int>[];
    for (final port in [
      ..._configuredPorts,
      ...discoveryPortFallbacks,
      ...legacyDiscoveryPorts,
    ]) {
      if (port > 0 && port <= 65535 && !result.contains(port)) result.add(port);
    }
    return result;
  }

  static Future<void> _ensureAndroidBroadcastReception() async {
    if (!Platform.isAndroid) return;
    try {
      await const MethodChannel('hibi/network')
          .invokeMethod<bool>('acquireMulticastLock');
    } catch (_) {
      // 部分旧安装包没有原生通道；UDP 仍可继续尝试，保持跨版本兼容。
    }
  }

  /// 返回常见私网的 /24 定向广播，同时保留较宽网段广播作为兼容兜底。
  static Future<List<InternetAddress>> _getSubnetBroadcastAddresses() async {
    final values = <String>{};
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          final parts = address.address.split('.');
          if (parts.length != 4) continue;
          final a = int.tryParse(parts[0]);
          final b = int.tryParse(parts[1]);
          final c = int.tryParse(parts[2]);
          if (a == null || b == null || c == null) continue;
          if (a == 10) {
            values.add('10.$b.$c.255');
            values.add('10.$b.255.255');
            values.add('10.255.255.255');
          } else if (a == 172 && b >= 16 && b <= 31) {
            values.add('172.$b.$c.255');
            values.add('172.$b.255.255');
          } else if (a == 192 && b == 168) {
            values.add('192.168.$c.255');
          }
        }
      }
    } catch (_) {}
    return values.map(InternetAddress.new).toList();
  }

  Future<RawDatagramSocket?> _bindFirstAvailable(List<int> ports) async {
    for (final port in ports) {
      if (_sockets.any((socket) => socket.port == port)) return null;
      try {
        final socket = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4,
          port,
          reuseAddress: true,
        );
        socket.broadcastEnabled = true;
        socket.listen((event) => _onSocketEvent(socket, event));
        _sockets.add(socket);
        return socket;
      } catch (error) {
        // 继续尝试同一端口族的下一个兼容端口。
      }
    }
    return null;
  }

  Future<void> start(
    int serverPort, {
    List<int>? fallbackPorts,
  }) async {
    if (_sockets.isNotEmpty) return;
    await _ensureAndroidBroadcastReception();
    _serverPort = serverPort;
    _boundPort = null;
    _configuredPorts = fallbackPorts != null && fallbackPorts.isNotEmpty
        ? List<int>.from(fallbackPorts)
        : List<int>.from(discoveryPortFallbacks);
    _deviceId = await TransferSavePath.getOrCreateDeviceId();
    _subnetBroadcasts = await _getSubnetBroadcastAddresses();

    final primary = await _bindFirstAvailable(_configuredPorts);
    if (primary != null) _boundPort = primary.port;

    // 自定义端口仍额外监听一个当前默认端口；所有新版本额外监听一个早期端口。
    if (!_configuredPorts.any(discoveryPortFallbacks.contains)) {
      final currentCompatibility =
          await _bindFirstAvailable(discoveryPortFallbacks);
      _boundPort ??= currentCompatibility?.port;
    }
    final legacyCompatibility = await _bindFirstAvailable(legacyDiscoveryPorts);
    _boundPort ??= legacyCompatibility?.port;

    if (_sockets.isEmpty) {
      _errorController.add(StateError('无法绑定任何兼容发现端口'));
      return;
    }

    _broadcastTimer =
        Timer.periodic(const Duration(seconds: 2), (_) => _broadcastInfo());
    _broadcastInfo();
    _broadcastDiscoveryRequest();
  }

  String get _platformTag {
    if (platformTagOverride != null && platformTagOverride!.isNotEmpty) {
      return platformTagOverride!;
    }
    if (Platform.isWindows) return 'windows';
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    return 'unknown';
  }

  Map<String, dynamic> _devicePayload() => {
        'request': false,
        'protocol': protocolName,
        'protocol_version': protocolVersion,
        'min_protocol_version': 1,
        'device_name': deviceName,
        'device_type': deviceType,
        'port': _serverPort ?? 0,
        'platform': _platformTag,
        if (_deviceId != null) 'device_id': _deviceId,
      };

  void _sendToAllNetworks(List<int> data) {
    if (_sockets.isEmpty) return;
    final addresses = <InternetAddress>[
      InternetAddress('255.255.255.255'),
      ..._subnetBroadcasts,
    ];
    for (final socket in _sockets) {
      for (final port in _targetPorts) {
        for (final address in addresses) {
          try {
            socket.send(data, address, port);
          } catch (_) {}
        }
      }
    }
  }

  void _broadcastInfo() {
    _sendToAllNetworks(utf8.encode(jsonEncode(_devicePayload())));
  }

  void _broadcastDiscoveryRequest() {
    _sendToAllNetworks(utf8.encode(jsonEncode({
      'request': true,
      'protocol': protocolName,
      'protocol_version': protocolVersion,
      'reply_port': _boundPort,
      if (_deviceId != null) 'device_id': _deviceId,
    })));
  }

  Future<void> refresh() async {
    if (_sockets.isEmpty) return;
    _subnetBroadcasts = await _getSubnetBroadcastAddresses();
    // 短间隔重复探测可抵抗 Wi-Fi 节能和 UDP 丢包，又不会进行全网段扫描。
    _broadcastDiscoveryRequest();
    await Future<void>.delayed(const Duration(milliseconds: 240));
    _broadcastDiscoveryRequest();
    await Future<void>.delayed(const Duration(milliseconds: 520));
    _broadcastDiscoveryRequest();
  }

  void _replyDirect(Datagram datagram, Map<String, dynamic> request) {
    if (_sockets.isEmpty) return;
    final rawReplyPort = request['reply_port'];
    final replyPort = _parsePort(rawReplyPort) ?? datagram.port;
    if (replyPort <= 0 || replyPort > 65535) return;
    try {
      _sockets.first.send(
        utf8.encode(jsonEncode(_devicePayload())),
        datagram.address,
        replyPort,
      );
    } catch (_) {}
  }

  int? _parsePort(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }

  void _onSocketEvent(RawDatagramSocket socket, RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    Datagram? datagram;
    while ((datagram = socket.receive()) != null) {
      final packet = datagram!;
      try {
        final decoded = jsonDecode(utf8.decode(packet.data));
        if (decoded is! Map<String, dynamic>) continue;
        if (decoded['request'] == true) {
          _replyDirect(packet, decoded);
          _broadcastInfo();
          continue;
        }

        final name = decoded['device_name'] ?? decoded['name'];
        final port = _parsePort(decoded['port'] ?? decoded['receive_port']);
        if (name == null || port == null || port <= 0 || port > 65535) {
          continue;
        }
        final deviceId = decoded['device_id']?.toString();
        if (deviceId != null && deviceId.isNotEmpty && deviceId == _deviceId) {
          continue;
        }
        _deviceController.add(TransferDevice(
          name: name.toString(),
          type: decoded['device_type']?.toString() ?? 'unknown',
          address: packet.address.address,
          port: port,
          platform: decoded['platform']?.toString(),
          deviceId: deviceId,
          protocolVersion: _parsePort(decoded['protocol_version']),
          lastSeen: DateTime.now(),
        ));
      } catch (_) {
        // 忽略同端口上的非 HIBI UDP 数据，保持与旧版本及其他局域网服务共存。
      }
    }
  }

  void stop() {
    _broadcastTimer?.cancel();
    _broadcastTimer = null;
    for (final socket in _sockets) {
      socket.close();
    }
    _sockets.clear();
    _boundPort = null;
  }

  void dispose() {
    stop();
    _deviceController.close();
    _errorController.close();
  }
}
