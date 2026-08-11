import 'package:flutter/foundation.dart';

import '../../../mind/services/mind_repository.dart';
import '../../../profile/services/agent_config_service.dart';
import '../../../schedule/schedule_event_store.dart';
import '../../models/agent.dart';
import '../openai_compatible_direct_api.dart';
import 'client_abp_executor.dart';

/// 固定一小套端侧 tools（日程 + 思维）；每轮全量注入，无意图路由。
List<Map<String, dynamic>> clientAbpTools() => [
      _fn('list_mind_projects', '列出思维项目 id 与标题', {
        'type': 'object',
        'properties': <String, dynamic>{},
      }),
      _fn('get_mind_canvas', '获取指定项目白板方块/连线摘要；当前项目可空 project_name', {
        'type': 'object',
        'properties': {
          'project_name': {'type': 'string'},
        },
      }),
      _fn('get_schedule', '查询日期范围内日程', {
        'type': 'object',
        'properties': {
          'start_date': {'type': 'string', 'description': 'YYYY-MM-DD'},
          'end_date': {'type': 'string', 'description': 'YYYY-MM-DD'},
          'days': {'type': 'integer', 'description': '未指定起止时从今天起天数，默认7'},
        },
      }),
      _fn(
        'create_schedule',
        '创建日程；未传 reminder_minutes 默认$kClientAbpDefaultReminderMinutes',
        {
          'type': 'object',
          'properties': {
            'title': {'type': 'string'},
            'start_time': {'type': 'string', 'description': 'ISO8601'},
            'end_time': {'type': 'string', 'description': 'ISO8601'},
            'is_all_day': {'type': 'boolean'},
            'location': {'type': 'string'},
            'reminder_minutes': {'type': 'integer'},
            'essence': {'type': 'string'},
          },
          'required': ['title', 'start_time', 'end_time'],
        },
      ),
      _fn('update_schedule', '用户明确同意后更新普通日程 evt_', {
        'type': 'object',
        'properties': {
          'event_id': {'type': 'string'},
          'title': {'type': 'string'},
          'start_time': {'type': 'string'},
          'end_time': {'type': 'string'},
          'is_all_day': {'type': 'boolean'},
          'location': {'type': 'string'},
          'reminder_minutes': {'type': 'integer'},
          'essence': {'type': 'string'},
        },
        'required': ['event_id'],
      }),
      _fn('delete_schedule', '用户明确要求后删除普通日程 evt_', {
        'type': 'object',
        'properties': {
          'event_id': {'type': 'string'},
        },
        'required': ['event_id'],
      }),
      _fn('set_block_reminder', '为尚无提醒的白板方块设置提醒', {
        'type': 'object',
        'properties': {
          'project_name': {'type': 'string'},
          'block_id': {'type': 'string'},
          'start_time': {'type': 'string'},
          'end_time': {'type': 'string'},
        },
        'required': ['block_id', 'start_time', 'end_time'],
      }),
    ];

String clientAbpSystemPrompt({
  required String agentName,
  required String agentRole,
  String? currentMindNodeId,
}) {
  final now = DateTime.now();
  final wk = const ['一', '二', '三', '四', '五', '六', '日'][now.weekday - 1];
  final stamp =
      '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} '
      '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
  final buf = StringBuffer()
    ..writeln('你是「$agentName」。')
    ..writeln(agentRole.trim())
    ..writeln()
    ..writeln(
      '【端侧 Skills】工具在 App 本地执行（写本机日程/思维数据）。需要时调用 tools，禁止口头假装已写入。',
    )
    ..writeln(
      '【当前时间 Asia/Shanghai】$stamp，星期$wk。create_schedule 的时间用 ISO8601（含 T）。',
    )
    ..writeln(
      '【严禁幻觉】未收到工具 ok 前，禁止说「已经写好了/已加入日程」。回复口语、简短；勿暴露 evt_/方块 id。',
    );
  if (currentMindNodeId != null && currentMindNodeId.isNotEmpty) {
    buf.writeln('【当前思维项目 id】$currentMindNodeId（用户说「当前项目」时可用）。');
  }
  return buf.toString().trim();
}

Map<String, dynamic> _fn(
  String name,
  String description,
  Map<String, dynamic> parameters,
) =>
    {
      'type': 'function',
      'function': {
        'name': name,
        'description': description,
        'parameters': parameters,
      },
    };

/// 希比助手端侧路径：直连模型 API → function calling → 本地执行 tools。
class ClientAbpRuntime {
  ClientAbpRuntime({
    OpenAiCompatibleDirectApi? api,
    ClientAbpExecutor? executor,
  })  : _api = api ?? OpenAiCompatibleDirectApi(),
        _executor = executor ?? ClientAbpExecutor();

  final OpenAiCompatibleDirectApi _api;
  final ClientAbpExecutor _executor;

  /// 静默预热本地 store（无 UI 进度条）。
  static Future<void> ensureLoaded() async {
    await Future.wait([
      ScheduleEventStore.instance.ensureLoaded(),
      MindRepository.instance.ensureLoaded(),
    ]);
  }

  Future<String> chat({
    required Agent agent,
    required AgentProviderConfig model,
    required String userMessage,
    List<Map<String, String>>? history,
    String? currentMindNodeId,
    List<Map<String, dynamic>>? attachments,
    String? systemExtra,
  }) async {
    await ensureLoaded();

    final tools = clientAbpTools();
    final baseSystem = clientAbpSystemPrompt(
      agentName: agent.name,
      agentRole: agent.role,
      currentMindNodeId: currentMindNodeId,
    );
    final extra = systemExtra?.trim() ?? '';
    final system = extra.isEmpty ? baseSystem : '$baseSystem\n\n$extra';
    debugPrint('[CLIENT-ABP] tools=${tools.length} msgLen=${userMessage.length}');

    return _api.chatWithTools(
      apiKey: model.effectiveApiKey,
      baseUrl: model.effectiveBaseUrl,
      model: model.effectiveModel,
      userMessage: userMessage,
      history: history,
      systemPrompt: system,
      attachments: attachments,
      tools: tools,
      toolChoice: 'auto',
      onToolCall: (name, args) async {
        debugPrint('[CLIENT-ABP] tool=$name args=$args');
        final out = await _executor.execute(
          name,
          args,
          currentMindNodeId: currentMindNodeId,
        );
        debugPrint('[CLIENT-ABP] tool=$name resultLen=${out.length}');
        return out;
      },
    );
  }
}
