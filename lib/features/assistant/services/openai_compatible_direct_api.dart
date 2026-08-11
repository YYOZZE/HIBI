import 'dart:convert';
import 'dart:typed_data';

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

  /// OpenAI 兼容 function calling；[onToolCall] 在端侧执行工具并返回 JSON 字符串。
  /// 最多 3 轮 tool 循环。无 tools 时退化为普通 [chat]。
  Future<String> chatWithTools({
    required String apiKey,
    required String baseUrl,
    required String model,
    required String userMessage,
    List<Map<String, String>>? history,
    String? systemPrompt,
    List<Map<String, dynamic>>? attachments,
    List<Map<String, dynamic>>? tools,
    String? toolChoice,
    Future<String> Function(String name, Map<String, dynamic> args)? onToolCall,
    int maxRounds = 3,
  }) async {
    if (tools == null || tools.isEmpty || onToolCall == null) {
      return chat(
        apiKey: apiKey,
        baseUrl: baseUrl,
        model: model,
        userMessage: userMessage,
        history: history,
        systemPrompt: systemPrompt,
        attachments: attachments,
      );
    }

    final base = normalizeBaseUrl(baseUrl);
    if (base.isEmpty) {
      throw Exception('Base URL 为空，请在智能体配置中填写');
    }
    final key = normalizeApiKey(apiKey);
    if (key.isEmpty) throw Exception('API Key 为空');
    final mid = normalizeModelId(model);
    final modelId = mid.isEmpty ? 'gpt-3.5-turbo' : mid;
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

    var choice = toolChoice ?? 'auto';
    var lastContent = '';

    for (var round = 0; round < maxRounds; round++) {
      final body = <String, dynamic>{
        'model': modelId,
        'messages': messages,
        'stream': false,
        'tools': tools,
        'tool_choice': choice,
      };
      final res = await _client
          .post(
            url,
            headers: {
              'Authorization': 'Bearer $key',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 120));

      if (res.statusCode != 200) {
        String detail = res.body;
        try {
          final data = jsonDecode(res.body);
          if (data is Map) {
            final err = data['error'];
            if (err is Map) {
              detail = (err['message'] ?? err['code'] ?? detail).toString();
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
      if (content.isNotEmpty) lastContent = content;

      final toolCalls = msg['tool_calls'];
      if (toolCalls is! List || toolCalls.isEmpty) {
        if (lastContent.isNotEmpty) return lastContent;
        final reasoning =
            (msg['reasoning_content'] ?? msg['reasoning'] ?? '').toString().trim();
        if (reasoning.isNotEmpty) return reasoning;
        throw Exception('模型返回空内容');
      }

      messages.add(Map<String, dynamic>.from(msg));
      for (final raw in toolCalls) {
        if (raw is! Map) continue;
        final id = (raw['id'] ?? '').toString();
        final fn = raw['function'];
        if (fn is! Map) continue;
        final name = (fn['name'] ?? '').toString();
        Map<String, dynamic> args = {};
        try {
          final parsed = jsonDecode((fn['arguments'] ?? '{}').toString());
          if (parsed is Map) {
            args = Map<String, dynamic>.from(parsed);
          }
        } catch (_) {}
        final result = await onToolCall(name, args);
        messages.add({
          'role': 'tool',
          'tool_call_id': id,
          'content': result,
        });
      }
      choice = 'auto';
    }
    return lastContent.isNotEmpty ? lastContent : '（工具调用轮次已用尽）';
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

  /// Moonshot/Kimi 等仅提供 Chat Completions，无 `/images/generations`。
  static bool likelySupportsImagesGenerations(String baseUrl) {
    final u = normalizeBaseUrl(baseUrl).toLowerCase();
    if (u.isEmpty) return false;
    if (u.contains('moonshot') || u.contains('kimi.ai') || u.contains('kimi.com')) {
      return false;
    }
    return true;
  }

  /// OpenAI 兼容文生图：`POST {base}/images/generations`。
  /// 成功返回 PNG/JPEG 字节；提供商不支持时抛错由上层回退。
  Future<Uint8List> generateImage({
    required String apiKey,
    required String baseUrl,
    required String prompt,
    String? model,
    String size = '1024x1024',
  }) async {
    final base = normalizeBaseUrl(baseUrl);
    if (base.isEmpty) throw Exception('Base URL 为空');
    final key = normalizeApiKey(apiKey);
    if (key.isEmpty) throw Exception('API Key 为空');
    final url = Uri.parse('$base/images/generations');
    final body = <String, dynamic>{
      'prompt': prompt.trim(),
      'n': 1,
      'size': size,
      'response_format': 'b64_json',
    };
    final mid = normalizeModelId(model ?? '');
    if (mid.isNotEmpty) body['model'] = mid;

    final res = await _client
        .post(
          url,
          headers: {
            'Authorization': 'Bearer $key',
            'Content-Type': 'application/json',
          },
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 120));

    if (res.statusCode != 200) {
      String detail = res.body;
      try {
        final data = jsonDecode(res.body);
        if (data is Map) {
          final err = data['error'];
          if (err is Map) {
            detail = (err['message'] ?? err['code'] ?? detail).toString();
          }
        }
      } catch (_) {}
      throw Exception(
        '图像接口错误 ${res.statusCode}: ${_friendlyModelHttpError(res.statusCode, detail)}',
      );
    }

    final data = jsonDecode(res.body);
    if (data is! Map) throw Exception('无效图像响应');
    final list = data['data'];
    if (list is! List || list.isEmpty) throw Exception('图像接口无返回');
    final first = list.first;
    if (first is! Map) throw Exception('无效图像条目');
    final b64 = (first['b64_json'] ?? '').toString();
    if (b64.isNotEmpty) {
      return base64Decode(b64);
    }
    final imageUrl = (first['url'] ?? '').toString();
    if (imageUrl.isEmpty) throw Exception('图像接口未返回数据');
    final imgRes = await _client
        .get(Uri.parse(imageUrl))
        .timeout(const Duration(seconds: 90));
    if (imgRes.statusCode != 200 || imgRes.bodyBytes.isEmpty) {
      throw Exception('下载生成图像失败 ${imgRes.statusCode}');
    }
    return imgRes.bodyBytes;
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
