import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

/// 局域网同步连接密码：首次自动生成并持久化，可修改/重置。
class LanSyncPasswordStore {
  LanSyncPasswordStore._();

  static const String _prefsKey = 'lan_sync_connection_password';

  /// 去掉易混淆字符（0/O、1/I/L），便于口读与抄写。
  static const String _charset = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';
  static const int passwordLength = 8;

  static Future<String> getOrCreate() async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString(_prefsKey)?.trim() ?? '';
    if (existing.isNotEmpty) return existing;
    final generated = generate();
    await prefs.setString(_prefsKey, generated);
    return generated;
  }

  static Future<void> set(String password) async {
    final trimmed = password.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('连接密码不能为空');
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, trimmed);
  }

  /// 重新随机生成并覆盖本地保存。
  static Future<String> reset() async {
    final generated = generate();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, generated);
    return generated;
  }

  static String generate() {
    final r = Random.secure();
    return List.generate(
      passwordLength,
      (_) => _charset[r.nextInt(_charset.length)],
    ).join();
  }
}
