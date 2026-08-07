import 'dart:convert';

import 'package:http/http.dart' as http;

import 'assistant_api.dart';

/// 对接 backend_jideshi_hibi_app 的 /api/chat（部署后配置 baseUrl）
class HttpAssistantApi implements AssistantApi {
  HttpAssistantApi({required this.baseUrl}) : assert(baseUrl.isNotEmpty);

  final String baseUrl;

  String get _chatUrl => '$baseUrl/api/chat';
  String get _conversationUrl => '$baseUrl/api/assistant/conversation';

  @override
  Future<String> sendMessage({
    required String agentId,
    required String userMessage,
    List<Map<String, String>>? history,
    String? agentName,
    String? agentRole,
    bool useBackendSystemPrompt = false,
    String? currentMindNodeId,
    String? token,
  }) async {
    final body = <String, dynamic>{
      'message': userMessage,
      'agent_id': agentId,
      'history': history ?? [],
      if (agentName != null && agentName.isNotEmpty) 'agent_name': agentName,
      if (agentRole != null && agentRole.isNotEmpty) 'agent_role': agentRole,
      if (useBackendSystemPrompt) 'use_backend_system_prompt': true,
      if (currentMindNodeId != null && currentMindNodeId.isNotEmpty)
        'current_mind_node_id': currentMindNodeId,
    };
    final headers = <String, String>{
      'Content-Type': 'application/json',
      if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
    };
    final res = await http
        .post(
          Uri.parse(_chatUrl),
          headers: headers,
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 90));
    if (res.statusCode != 200) {
      String err = res.body;
      try {
        final data = jsonDecode(res.body) as Map<String, dynamic>?;
        err = data?['error']?.toString() ?? err;
      } catch (_) {}
      throw Exception('请求失败: ${res.statusCode} - $err');
    }
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final reply = data['reply']?.toString();
    if (reply == null) throw Exception('无效响应');
    return reply;
  }

  @override
  Future<String?> getOrCreateConversationId({
    required String agentId,
    String? title,
    String? token,
  }) async {
    final uri = Uri.parse(_conversationUrl).replace(queryParameters: {
      'agent_id': agentId,
      if (title != null && title.trim().isNotEmpty) 'title': title.trim(),
    });
    final headers = <String, String>{
      if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
    };
    final res = await http.get(uri, headers: headers).timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) return null;
    try {
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      return data['conversation_id']?.toString();
    } catch (_) {
      return null;
    }
  }

  @override
  Future<({List<Map<String, dynamic>> messages, String? nextBeforeId})> listConversationMessages({
    required String conversationId,
    String? beforeId,
    int limit = 50,
    String? token,
  }) async {
    final uri = Uri.parse('$baseUrl/api/assistant/conversations/$conversationId/messages').replace(
      queryParameters: {
        'limit': limit.clamp(1, 200).toString(),
        if (beforeId != null && beforeId.trim().isNotEmpty) 'before_id': beforeId.trim(),
      },
    );
    final headers = <String, String>{
      if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
    };
    final res = await http.get(uri, headers: headers).timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) return (messages: const <Map<String, dynamic>>[], nextBeforeId: null);
    try {
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final list = (data['messages'] as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      return (messages: list, nextBeforeId: data['next_before_id']?.toString());
    } catch (_) {
      return (messages: const <Map<String, dynamic>>[], nextBeforeId: null);
    }
  }
}
