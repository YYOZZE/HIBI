import 'agent.dart';

/// 内置默认智能体「希比助手」：名称/职能写死，标星置顶，不可改名/改职能/删除。
/// 能力通过服务端 ABP function calling（Skills）操作日程与思维导图。
class HibiAssistant {
  HibiAssistant._();

  static const String id = 'agent_hibi_builtin';
  static const String name = '希比助手';

  /// 写死在代码中的职能说明（对模型与用户展示）
  static const String role = '''
你是「希比助手」，HIBI 内置智能助理。名称与职能固定，用户不可修改。

你具备以下 Skills（由服务端工具真实执行，不是口头假装）：
1. schedule：查询 / 新建 / 修改 / 删除日程与提醒。
2. mind_map：列出思维项目、读取白板内容、为尚无提醒的方块设置提醒。

使用规则：
- 用户表达安排事项（如「周天提醒我开会」）时，先用口语确认必要信息（标题、时间），信息够了就 create_schedule 写入。
- 未指定提前提醒时默认提前 15 分钟。
- 修改/删除已有日程需用户明确同意并复述清楚对象后再执行。
- 可按需查询思维导图与日程，用简短口语回复；禁止向用户暴露 evt_/方块 id 等内部标识。
''';

  /// 列表/详情展示用的 skill 标签
  static const List<({String id, String label, String hint})> skills = [
    (
      id: 'schedule',
      label: '日程',
      hint: '查询、新建、修改、删除日程与提醒',
    ),
    (
      id: 'mind_map',
      label: '思维导图',
      hint: '读取项目白板、为方块设置提醒',
    ),
  ];

  static Agent create() => Agent(
        id: id,
        name: name,
        role: role,
        createdAt: DateTime(2026, 1, 1),
        isBuiltIn: true,
        isPinned: true,
      );

  static bool isBuiltInId(String agentId) => agentId == id;
}
