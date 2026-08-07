import 'dart:convert';

/// 解析 embed 页经 WebView2 / [JavaScriptChannel] 上报的 JSON 对象。
Map<String, dynamic> coerceCaptchaWebMessage(dynamic message) {
  dynamic v = message;
  for (var i = 0; i < 3; i++) {
    if (v is Map) {
      if (v is Map<String, dynamic>) return v;
      return Map<String, dynamic>.from(
        v.map((dynamic k, dynamic val) => MapEntry(k.toString(), val)),
      );
    }
    if (v is String) {
      v = jsonDecode(v);
      continue;
    }
    break;
  }
  throw FormatException('webMessage 无法解析为 Map: ${message.runtimeType}');
}
