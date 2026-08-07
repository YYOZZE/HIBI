import 'package:flutter/widgets.dart';

import 'graph_captcha_types.dart';

class GraphCaptchaService {
  static bool get isSupported => false;

  static Future<GraphCaptchaResult?> verify({
    required String appId,
    String? sdkUrl,
    BuildContext? context,
    String captchaPlatform = 'web',
  }) async {
    return null;
  }
}
