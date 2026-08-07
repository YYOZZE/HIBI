import '../../../config/api_config.dart';

/// 服务端 [GET /api/auth/captcha/embed] 完整 URL（须为真实 http(s) origin，供 WebView 加载）。
String? graphCaptchaEmbedPageUrl({
  required String appId,
  required String platform,
}) {
  final base = ApiConfig.authApiBaseUrl.trim();
  if (base.isEmpty || base == 'YOUR_AUTH_SERVER_URL') return null;
  final b = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
  final q = Uri(queryParameters: {
    'app_id': appId.trim(),
    'platform': platform.trim(),
  }).query;
  return '$b/api/auth/captcha/embed?$q';
}
