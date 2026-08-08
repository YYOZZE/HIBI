import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

/// 局域网数据同步设备（与文件传输发现相互独立）。
class LanSyncPeer {
  LanSyncPeer({
    required this.deviceId,
    required this.deviceName,
    required this.accountHint,
    required this.ip,
    required this.httpPort,
    required this.lastSeen,
  });

  final String deviceId;
  final String deviceName;
  final String accountHint;
  final String ip;
  final int httpPort;
  DateTime lastSeen;

  String get displayLabel {
    final acc = accountHint.trim();
    if (acc.isEmpty) return deviceName;
    return '$deviceName（$acc）';
  }
}

/// UDP 广播发现：端口族 62747，协议名 `hibi-lan-sync`。
class LanSyncDiscovery {
  LanSyncDiscovery({
    required this.deviceId,
    required this.deviceName,
    required this.accountHint,
    required this.httpPort,
  });

  final String deviceId;
  final String deviceName;
  final String accountHint;
  final int httpPort;

  static const int discoveryPort = 62747;
  static const List<int> discoveryPortFallbacks = [62747, 62748, 62749];
  static const String protocolName = 'hibi-lan-sync';
  static const int protocolVersion = 1;

  final List<RawDatagramSocket> _sockets = [];
  Timer? _broadcastTimer;
  Timer? _pruneTimer;
  List<InternetAddress> _subnetBroadcasts = [];

  final Map<String, LanSyncPeer> _peers = {};
  final StreamController<List<LanSyncPeer>> _peersController =
      StreamController<List<LanSyncPeer>>.broadcast();
  final StreamController<Object> _errorController =
      StreamController<Object>.broadcast();

  Stream<List<LanSyncPeer>> get peers => _peersController.stream;
  Stream<Object> get errors => _errorController.stream;
  List<LanSyncPeer> get currentPeers =>
      _peers.values.toList()..sort((a, b) => a.deviceName.compareTo(b.deviceName));

  Future<void> start() async {
    await stop();
    await _ensureAndroidBroadcastReception();
    _subnetBroadcasts = await _getSubnetBroadcastAddresses();
    final bound = await _bindFirstAvailable(discoveryPortFallbacks);
    if (bound == null) {
      _errorController.add(StateError('无法绑定局域网同步发现端口'));
      return;
    }
    _broadcastTimer =
        Timer.periodic(const Duration(seconds: 2), (_) => _broadcast());
    _pruneTimer = Timer.periodic(const Duration(seconds: 3), (_) => _prune());
    _broadcast();
  }

  Future<void> stop() async {
    _broadcastTimer?.cancel();
    _broadcastTimer = null;
    _pruneTimer?.cancel();
    _pruneTimer = null;
    for (final s in _sockets) {
      try {
        s.close();
      } catch (_) {}
    }
    _sockets.clear();
    _peers.clear();
    _peersController.add(const []);
  }

  Future<void> dispose() async {
    await stop();
    await _peersController.close();
    await _errorController.close();
  }

  Future<void> _ensureAndroidBroadcastReception() async {
    if (!Platform.isAndroid) return;
    try {
      await const MethodChannel('hibi/network')
          .invokeMethod<bool>('acquireMulticastLock');
    } catch (_) {}
  }

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
          } else if (a == 172 && b >= 16 && b <= 31) {
            values.add('172.$b.$c.255');
          } else if (a == 192 && b == 168) {
            values.add('192.168.$c.255');
          }
        }
      }
    } catch (_) {}
    values.add('255.255.255.255');
    return values.map(InternetAddress.new).toList();
  }

  Future<RawDatagramSocket?> _bindFirstAvailable(List<int> ports) async {
    for (final port in ports) {
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
      } catch (_) {}
    }
    return null;
  }

  void _broadcast() {
    final payload = utf8.encode(jsonEncode({
      'type': protocolName,
      'v': protocolVersion,
      'deviceId': deviceId,
      'deviceName': deviceName,
      'accountHint': accountHint,
      'httpPort': httpPort,
    }));
    for (final socket in _sockets) {
      for (final targetPort in discoveryPortFallbacks) {
        try {
          socket.send(payload, InternetAddress('255.255.255.255'), targetPort);
        } catch (_) {}
        for (final b in _subnetBroadcasts) {
          try {
            socket.send(payload, b, targetPort);
          } catch (_) {}
        }
      }
    }
  }

  void _onSocketEvent(RawDatagramSocket socket, RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final dg = socket.receive();
    if (dg == null) return;
    try {
      final text = utf8.decode(dg.data);
      final data = jsonDecode(text);
      if (data is! Map) return;
      if (data['type']?.toString() != protocolName) return;
      final id = data['deviceId']?.toString() ?? '';
      if (id.isEmpty || id == deviceId) return;
      final name = data['deviceName']?.toString() ?? '希比设备';
      final hint = data['accountHint']?.toString() ?? '';
      final port = (data['httpPort'] is num)
          ? (data['httpPort'] as num).toInt()
          : int.tryParse('${data['httpPort']}') ?? 0;
      if (port <= 0) return;
      final ip = dg.address.address;
      final existing = _peers[id];
      if (existing != null) {
        existing.lastSeen = DateTime.now();
        _peersController.add(currentPeers);
        return;
      }
      _peers[id] = LanSyncPeer(
        deviceId: id,
        deviceName: name,
        accountHint: hint,
        ip: ip,
        httpPort: port,
        lastSeen: DateTime.now(),
      );
      _peersController.add(currentPeers);
    } catch (_) {}
  }

  void _prune() {
    final now = DateTime.now();
    final stale = <String>[];
    for (final e in _peers.entries) {
      if (now.difference(e.value.lastSeen) > const Duration(seconds: 8)) {
        stale.add(e.key);
      }
    }
    if (stale.isEmpty) return;
    for (final k in stale) {
      _peers.remove(k);
    }
    _peersController.add(currentPeers);
  }
}
