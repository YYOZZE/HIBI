import 'dart:io';

import 'package:permission_handler/permission_handler.dart';

/// 应用所需权限：启动时统一申请，避免在使用传输/通知等功能时才弹窗
class AppPermissions {
  AppPermissions._();

  /// 获取当前平台需要请求的权限列表
  static List<Permission> get _permissions {
    if (Platform.isAndroid) {
      return [
        Permission.storage, // 文件传输保存；Android 13+ 下部分场景由 READ_MEDIA_* 覆盖
        Permission.notification, // 日程/提醒通知（Android 13+）
        Permission.microphone, // 语音输入
      ];
    }
    if (Platform.isIOS) {
      return [
        // 本地网络在 Info.plist 已声明，系统在首次访问时弹窗
        // 通知需在系统设置中开启，此处仅做可选请求
        Permission.notification,
      ];
    }
    if (Platform.isWindows) {
      return [
        // Windows 端也统一在启动时触发通知权限请求（由系统处理是否弹提示）。
        Permission.notification,
      ];
    }
    return [];
  }

  /// 启动时请求所有所需权限（不阻塞：请求后即返回，用户可稍后在设置中修改）
  static Future<void> requestAll() async {
    final list = _permissions;
    if (list.isEmpty) return;
    for (final p in list) {
      try {
        final status = await p.status;
        if (status.isDenied || status.isPermanentlyDenied) {
          await p.request();
        }
      } catch (_) {}
    }
  }
}
