import 'dart:io' show Platform;

import 'package:flutter/widgets.dart';

import 'graph_captcha_service_desktop.dart' as win_impl;
import 'graph_captcha_service_mobile.dart' as mobile_impl;
import 'graph_captcha_types.dart';

/// 非 Web 平台：`Windows` 使用 WebView2；**Android / iOS** 使用 `webview_flutter` 加载服务端 embed。
class GraphCaptchaService {
  static bool get isSupported =>
      Platform.isWindows || Platform.isAndroid || Platform.isIOS;

  static Future<GraphCaptchaResult?> verify({
    required String appId,
    String? sdkUrl,
    BuildContext? context,
    String captchaPlatform = 'web',
  }) {
    if (Platform.isWindows) {
      return win_impl.GraphCaptchaService.verify(
        appId: appId,
        sdkUrl: sdkUrl,
        context: context,
        captchaPlatform: captchaPlatform,
      );
    }
    if (Platform.isAndroid || Platform.isIOS) {
      return mobile_impl.GraphCaptchaService.verify(
        appId: appId,
        sdkUrl: sdkUrl,
        context: context,
        captchaPlatform: captchaPlatform,
      );
    }
    return Future<GraphCaptchaResult?>.value(null);
  }
}
