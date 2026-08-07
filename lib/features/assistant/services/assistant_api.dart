/// 助理对话 API 抽象接口（对接 backend_jideshi_hibi_app 或占位）
abstract class AssistantApi {
  /// 发送用户消息，返回助手回复。
  /// [agentName] / [agentRole] 用于后端生成智能体 system prompt。
  /// [useBackendSystemPrompt] 为 true 时使用后端 ABP system prompt 并支持工具调用，需 [token]。
  /// 客户端在**用户已登录**（有有效 token）时对任意智能体均应置为 true；未登录则置 false，后端仅按 [agentName]/[agentRole] 组普通 system prompt（无 tools）。
  /// [currentMindNodeId] 当前思维节点 id，供 get_mind_canvas 等使用。
  Future<String> sendMessage({
    required String agentId,
    required String userMessage,
    List<Map<String, String>>? history,
    String? agentName,
    String? agentRole,
    bool useBackendSystemPrompt = false,
    String? currentMindNodeId,
    String? token,
  });

  /// 方案 B：获取/创建当前登录用户在该 agent 下的会话 id。
  Future<String?> getOrCreateConversationId({
    required String agentId,
    String? title,
    String? token,
  }) async {
    return null;
  }

  /// 方案 B：分页拉取会话消息（按 id 游标）。
  Future<({List<Map<String, dynamic>> messages, String? nextBeforeId})> listConversationMessages({
    required String conversationId,
    String? beforeId,
    int limit = 50,
    String? token,
  }) async {
    return (messages: const <Map<String, dynamic>>[], nextBeforeId: null);
  }
}

/// 占位实现：未接入时返回提示；接入后替换为 HttpAssistantApi
class PlaceholderAssistantApi implements AssistantApi {
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
    await Future.delayed(const Duration(milliseconds: 400));
    return '接口未接入，敬请期待。\n\n后续将在此接入云服务器与豆包 API，实现真实对话。';
  }

  @override
  Future<String?> getOrCreateConversationId({
    required String agentId,
    String? title,
    String? token,
  }) async {
    return null;
  }

  @override
  Future<({List<Map<String, dynamic>> messages, String? nextBeforeId})> listConversationMessages({
    required String conversationId,
    String? beforeId,
    int limit = 50,
    String? token,
  }) async {
    return (messages: const <Map<String, dynamic>>[], nextBeforeId: null);
  }
}
