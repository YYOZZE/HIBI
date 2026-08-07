import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, kIsWeb;

/// 与后端 `hibi_graph_captcha._normalize_platform`、控制台各端 **appId** 选用规则一致。
///
/// - **web**：Flutter Web；以及 **Windows / macOS / Linux** 桌面（内嵌 WebView 走 H5/「win 端」方案）。
/// - **android / ios**：原生移动构建。
/// - **harmony**：若在独立 OpenHarmony Flutter 中 `defaultTargetPlatform` 出现 `TargetPlatform.ohos`，
///   请在本文件中为该枚举增加 `return 'harmony'`（标准 Windows SDK 可能无此枚举，故用补丁写法避免误编译失败）。
String authCaptchaPlatformForDevice() {
  if (kIsWeb) return 'web';
  if (defaultTargetPlatform == TargetPlatform.iOS) return 'ios';
  if (defaultTargetPlatform == TargetPlatform.android) return 'android';
  // 独立鸿蒙 Flutter：取消下行注释并保证本仓库 SDK 含 `TargetPlatform.ohos`
  // if (defaultTargetPlatform == TargetPlatform.ohos) return 'harmony';
  return 'web';
}
