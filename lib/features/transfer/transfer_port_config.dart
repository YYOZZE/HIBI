import 'package:shared_preferences/shared_preferences.dart';

/// 文件传输端口配置（接收 TCP / 发现 UDP），持久化到 SharedPreferences。
class TransferPortConfig {
  TransferPortConfig._();

  static const int defaultDiscoveryPort = 62637;
  static const List<int> defaultDiscoveryFallbacks = [62637, 62638, 62639];

  /// 0 表示由系统自动分配接收端口。
  static const int autoReceivePort = 0;

  static const String _keyReceivePort = 'transfer_receive_port';
  static const String _keyDiscoveryPort = 'transfer_discovery_port';

  static Future<int> getReceivePort() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_keyReceivePort) ?? autoReceivePort;
  }

  static Future<void> setReceivePort(int port) async {
    final prefs = await SharedPreferences.getInstance();
    if (port <= 0) {
      await prefs.remove(_keyReceivePort);
    } else {
      await prefs.setInt(_keyReceivePort, port);
    }
  }

  static Future<int> getDiscoveryPort() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_keyDiscoveryPort) ?? defaultDiscoveryPort;
  }

  static Future<void> setDiscoveryPort(int port) async {
    final prefs = await SharedPreferences.getInstance();
    if (port == defaultDiscoveryPort) {
      await prefs.remove(_keyDiscoveryPort);
    } else {
      await prefs.setInt(_keyDiscoveryPort, port);
    }
  }

  /// 发现服务绑定与广播时使用的端口列表（主端口 + 回退）。
  static Future<List<int>> getDiscoveryFallbacks() async {
    final primary = await getDiscoveryPort();
    if (primary == defaultDiscoveryPort)
      return List<int>.from(defaultDiscoveryFallbacks);
    final fallbacks = <int>[];
    for (var i = 0; i < 3; i++) {
      final p = primary + i;
      if (p > 65535) break;
      if (!fallbacks.contains(p)) fallbacks.add(p);
    }
    return fallbacks;
  }

  static bool isValidPort(int port) => port >= 1 && port <= 65535;

  static bool isValidReceivePort(int port) =>
      port == autoReceivePort || isValidPort(port);
}
