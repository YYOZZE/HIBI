import 'dart:io';
import 'dart:math';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _keyTransferSavePath = 'transfer_default_save_path';
const String _keyTransferDeviceId = 'transfer_device_id';

/// 文件传输默认保存路径的读写；未设置时使用应用文档目录下的 HIBI_Received
class TransferSavePath {
  TransferSavePath._();

  static Future<String?> getPath() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyTransferSavePath);
  }

  static Future<void> setPath(String? path) async {
    final prefs = await SharedPreferences.getInstance();
    if (path == null || path.isEmpty) {
      await prefs.remove(_keyTransferSavePath);
    } else {
      await prefs.setString(_keyTransferSavePath, path);
    }
  }

  /// 本机设备唯一标识（用于发现去重，同一台设备多网卡只显示一条）
  static Future<String> getOrCreateDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString(_keyTransferDeviceId);
    if (id == null || id.isEmpty) {
      id =
          '${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(0x7FFFFFFF).toRadixString(16)}';
      await prefs.setString(_keyTransferDeviceId, id);
    }
    return id;
  }

  /// 返回接收文件时应使用的保存目录（保证存在）
  static Future<Directory> getSaveDirectory() async {
    final custom = await getPath();
    if (custom != null && custom.isNotEmpty) {
      final dir = Directory(custom);
      if (await dir.exists()) return dir;
      try {
        await dir.create(recursive: true);
        return dir;
      } catch (_) {}
    }
    final appDir = await getApplicationDocumentsDirectory();
    final fallback = Directory('${appDir.path}/HIBI_Received');
    if (!await fallback.exists()) await fallback.create(recursive: true);
    return fallback;
  }
}
