import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _keyGeneratedSavePath = 'hibi_generated_content_save_path_v1';

/// 智能体生成内容（文档 / 图片 / 视频脚本等）的默认保存路径
class GeneratedContentSavePath {
  GeneratedContentSavePath._();

  static Future<String?> getPath() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyGeneratedSavePath);
  }

  static Future<void> setPath(String? path) async {
    final prefs = await SharedPreferences.getInstance();
    if (path == null || path.isEmpty) {
      await prefs.remove(_keyGeneratedSavePath);
    } else {
      await prefs.setString(_keyGeneratedSavePath, path);
    }
  }

  /// 返回应使用的保存目录（保证存在）
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
    final fallback = Directory('${appDir.path}/HIBI_Generated');
    if (!await fallback.exists()) await fallback.create(recursive: true);
    return fallback;
  }

  static Future<String> defaultPathLabel() async {
    final custom = await getPath();
    if (custom != null && custom.isNotEmpty) return custom;
    final appDir = await getApplicationDocumentsDirectory();
    return '${appDir.path}/HIBI_Generated';
  }
}
