import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../config/api_config.dart';

class PrivacyTermsData {
  const PrivacyTermsData({
    required this.content,
    this.updatedAt,
    this.fromFallback = false,
  });

  final String content;
  final DateTime? updatedAt;
  final bool fromFallback;
}

class PrivacyTermsService {
  PrivacyTermsService._();

  static const String _defaultPrivacyTerms = '''
希比（HIBI）隐私条款

欢迎使用希比。我们重视并保护你的个人信息与数据安全。本条款用于说明我们如何收集、使用、存储和保护你的信息，以及你享有的权利。

一、我们收集的信息
1）账号信息：如手机号/邮箱、昵称、头像等。
2）业务数据：如思维节点、日程、助理历史记录等。
3）设备与日志信息：如登录时间、IP、必要的系统日志。
4）支付信息：如订单号、支付状态、套餐信息（敏感支付凭据由支付机构处理）。

二、信息使用目的
1）提供登录认证、基础功能和订阅服务能力。
2）在你开通对应服务后提供云同步、助理、主题等增值能力。
3）保障系统稳定、安全与风控，处理故障与投诉。
4）用于产品优化和体验改进。

三、数据存储与同步
1）未开通数据服务时，相关记录主要保存在本地设备。
2）开通数据服务或大会员后，相关数据可同步至云端并支持多端使用。
3）我们会采取合理安全措施保护数据，你也应妥善保管账号与设备。

四、信息共享与披露
除法律法规要求或经你明确授权外，我们不会向无关第三方出售你的个人信息。

五、你的权利
你可以查询、更正、删除你的信息，并可通过注销账户停止继续使用相关服务。

六、条款更新
隐私条款会根据法律法规或业务调整进行更新，更新后会在应用内展示。
''';

  static Future<PrivacyTermsData> fetchPrivacyTerms() async {
    if (!ApiConfig.isAuthApiConfigured) {
      return const PrivacyTermsData(content: _defaultPrivacyTerms, fromFallback: true);
    }
    final base = ApiConfig.authApiBaseUrl.replaceFirst(RegExp(r'/$'), '');
    final url = Uri.parse('$base/api/legal/privacy_terms');
    try {
      final resp = await http.get(url).timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) {
        return const PrivacyTermsData(content: _defaultPrivacyTerms, fromFallback: true);
      }
      final data = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>?;
      final content = (data?['content'] ?? '').toString().trim();
      final updatedAtSeconds = data?['updated_at'];
      final updatedAt = updatedAtSeconds is num
          ? DateTime.fromMillisecondsSinceEpoch((updatedAtSeconds * 1000).toInt())
          : null;
      if (content.isEmpty) {
        return const PrivacyTermsData(content: _defaultPrivacyTerms, fromFallback: true);
      }
      return PrivacyTermsData(content: content, updatedAt: updatedAt, fromFallback: false);
    } catch (_) {
      return const PrivacyTermsData(content: _defaultPrivacyTerms, fromFallback: true);
    }
  }
}
