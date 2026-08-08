import 'dart:convert';

import 'package:http/http.dart' as http;

/// 客户端直连 OpenAI 兼容 `/chat/completions`（火山方舟 / DeepSeek / Moonshot 等）。
/// 用于：用户已配置自定义 Key，且 HIBI 后端不可达或未登录时的回退路径。
/// 注意：此路径不执行服务端 ABP 工具（日程/白板），仅纯对话。
class OpenAiCompatibleDirectApi {
  OpenAiCompatibleDirectApi({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  /// [baseUrl] 形如 `https://ark.cn-beijing.volces.com/api/v3`（不要带 `/chat/completions`）
  Future<String> chat({
    required String apiKey,
    required String baseUrl,
    required String model,
    required String userMessage,
    List<Map<String, String>>? history,
    String? systemPrompt,
    List<Map<String, dynamic>>? attachments,
  }) async {
    final base = normalizeBaseUrl(baseUrl);
    if (base.isEmpty) {
      throw Exception('Base URL 为空，请在智能体配置中填写（火山方舟示例：https://ark.cn-beijing.volces.com/api/v3）');
    }
    final key = normalizeApiKey(apiKey);
    if (key.isEmpty) {
      throw Exception('API Key 为空');
    }
    final normalizedModel = normalizeModelId(model);
    final mid = normalizedModel.isEmpty ? 'gpt-3.5-turbo' : normalizedModel;
    final url = Uri.parse('$base/chat/completions');

    final messages = <Map<String, dynamic>>[];
    if (systemPrompt != null && systemPrompt.trim().isNotEmpty) {
      messages.add({'role': 'system', 'content': systemPrompt.trim()});
    }
    if (history != null) {
      for (final m in history) {
        final role = (m['role'] ?? '').trim();
        final content = (m['content'] ?? '').trim();
        if ((role == 'user' || role == 'assistant' || role == 'system') &&
            content.isNotEmpty) {
          messages.add({'role': role, 'content': content});
        }
      }
    }
    messages.add({
      'role': 'user',
      'content': _buildUserContent(userMessage, attachments),
    });

    final res = await _client
        .post(
          url,
          headers: {
            'Authorization': 'Bearer $key',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'model': mid,
            'messages': messages,
            'stream': false,
          }),
        )
        .timeout(const Duration(seconds: 90));

    if (res.statusCode != 200) {
      String detail = res.body;
      try {
        final data = jsonDecode(res.body);
        if (data is Map) {
          final err = data['error'];
          if (err is Map) {
            detail = (err['message'] ?? err['code'] ?? detail).toString();
          } else if (data['message'] != null) {
            detail = data['message'].toString();
          }
        }
      } catch (_) {}
      throw Exception(
        '模型接口错误 ${res.statusCode}: ${_friendlyModelHttpError(res.statusCode, detail)}',
      );
    }

    final data = jsonDecode(res.body);
    if (data is! Map) throw Exception('无效响应');
    final choices = data['choices'];
    if (choices is! List || choices.isEmpty) {
      throw Exception('模型无返回内容');
    }
    final msg = (choices.first as Map)['message'];
    if (msg is! Map) throw Exception('无效 message');
    final content = (msg['content'] ?? '').toString().trim();
    // 部分深度思考模型可能把正文放在 reasoning 字段旁；content 为空时兜底
    if (content.isEmpty) {
      final reasoning = (msg['reasoning_content'] ?? msg['reasoning'] ?? '')
          .toString()
          .trim();
      if (reasoning.isNotEmpty) return reasoning;
      throw Exception('模型返回空内容');
    }
    return content;
  }

  /// 有图片时走 OpenAI vision 多段 content；否则纯字符串。
  static dynamic _buildUserContent(
    String userMessage,
    List<Map<String, dynamic>>? attachments,
  ) {
    final textParts = <String>[];
    if (userMessage.trim().isNotEmpty) textParts.add(userMessage.trim());
    final imageParts = <Map<String, dynamic>>[];

    if (attachments != null) {
      for (final a in attachments) {
        final kind = (a['kind'] ?? '').toString();
        final name = (a['name'] ?? 'file').toString();
        final text = (a['text'] ?? '').toString().trim();
        final b64 = (a['data_base64'] ?? '').toString();
        final mime = (a['mime'] ?? 'image/png').toString();
        if (kind == 'image' && b64.isNotEmpty) {
          imageParts.add({
            'type': 'image_url',
            'image_url': {
              'url': 'data:$mime;base64,$b64',
            },
          });
        } else if (text.isNotEmpty) {
          textParts.add('【附件:$name】\n$text');
        } else if (kind == 'binaryDoc' && b64.isNotEmpty) {
          textParts.add('【附件:$name】（直连路径无法解析该二进制文档，请改走后端或粘贴文本）');
        }
      }
    }

    final text = textParts.join('\n\n').trim();
    if (imageParts.isEmpty) {
      return text.isEmpty ? userMessage : text;
    }
    final content = <Map<String, dynamic>>[
      if (text.isNotEmpty) {'type': 'text', 'text': text},
      ...imageParts,
    ];
    if (content.isEmpty) {
      return userMessage;
    }
    return content;
  }

  /// 去掉尾部 `/chat/completions`，统一无末尾斜杠
  static String normalizeBaseUrl(String raw) {
    var u = raw.trim();
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    const suffix = '/chat/completions';
    if (u.toLowerCase().endsWith(suffix)) {
      u = u.substring(0, u.length - suffix.length);
      while (u.endsWith('/')) {
        u = u.substring(0, u.length - 1);
      }
    }
    return u;
  }

  /// 清洗用户粘贴的 API Key：去空白/引号、去掉误带的 `Bearer ` / `Authorization:`。
  /// 避免方舟返回 401「The API key format is incorrect」。
  static String normalizeApiKey(String raw) {
    var k = raw.trim();
    if (k.isEmpty) return '';

    // 去掉成对或单侧引号（curl -H 整段粘贴常见）
    for (var i = 0; i < 2; i++) {
      if (k.length >= 2) {
        final a = k.codeUnitAt(0);
        final b = k.codeUnitAt(k.length - 1);
        final dq = a == 0x22 && b == 0x22; // "
        final sq = a == 0x27 && b == 0x27; // '
        if (dq || sq) {
          k = k.substring(1, k.length - 1).trim();
          continue;
        }
      }
      break;
    }
    if ((k.startsWith('"') || k.startsWith("'")) && k.length > 1) {
      k = k.substring(1).trim();
    }
    if ((k.endsWith('"') || k.endsWith("'")) && k.length > 1) {
      k = k.substring(0, k.length - 1).trim();
    }

    // Authorization: Bearer xxx / Bearer xxx
    final lower = k.toLowerCase();
    if (lower.startsWith('authorization:')) {
      k = k.substring('authorization:'.length).trim();
    }
    if (k.toLowerCase().startsWith('bearer ')) {
      k = k.substring(7).trim();
    }

    // 去掉内部空白/换行（从多行 curl 误选）
    k = k.replaceAll(RegExp(r'\s+'), '');
    return k;
  }

  /// 模型 ID：去空白与包围引号
  static String normalizeModelId(String raw) {
    var m = raw.trim();
    if (m.length >= 2) {
      final a = m.codeUnitAt(0);
      final b = m.codeUnitAt(m.length - 1);
      if ((a == 0x22 && b == 0x22) || (a == 0x27 && b == 0x27)) {
        m = m.substring(1, m.length - 1).trim();
      }
    }
    return m;
  }

  static String _friendlyModelHttpError(int statusCode, String detail) {
    final d = detail.trim();
    final low = d.toLowerCase();
    if (statusCode == 401 ||
        low.contains('api key format') ||
        low.contains('incorrect api key') ||
        low.contains('invalid_api_key') ||
        low.contains('authentication')) {
      return '$d\n提示：请只填密钥本身（火山以 ark- 开头），不要带 Bearer/引号；'
          'Base URL 用 https://ark.cn-beijing.volces.com/api/v3，'
          '并在智能体配置中选中对应提供商后保存。';
    }
    return d;
  }

  /// 是否为连不上 HIBI 后端一类的网络错误（可尝试客户端直连回退）
  static bool isBackendNetworkFailure(Object e) {
    final s = e.toString().toLowerCase();
    return s.contains('socketexception') ||
        s.contains('timeout') ||
        s.contains('failed host lookup') ||
        s.contains('connection refused') ||
        s.contains('connection reset') ||
        s.contains('network is unreachable') ||
        s.contains('semaphore timeout') ||
        s.contains('clientexception');
  }
}
