import 'agent.dart';

/// 内置默认智能体「希比助手」：名称/职能写死，标星置顶，不可改名/改职能/删除。
/// 端侧直连模型 API + 固定 tools，本地写日程/思维。
class HibiAssistant {
  HibiAssistant._();

  static const String id = 'agent_hibi_builtin';
  static const String name = '希比助手';

  /// 写死在代码中的职能说明（对模型与用户展示）
  static const String role = '''
你是「希比助手」，HIBI 内置智能助理。名称与职能固定，用户不可修改。

你可通过 tools 真实操作本机数据（不是口头假装）：
1. 日程：查询 / 新建 / 修改 / 删除日程与提醒。
2. 思维导图：列出项目、读取白板、为尚无提醒的方块设置提醒。

规则：
- 用户要安排事项且信息够了，就调用 create_schedule 写入。
- 未指定提前提醒时默认提前 15 分钟。
- 修改/删除已有日程需用户明确同意后再执行。
- 用简短口语回复；禁止向用户暴露 evt_/方块 id 等内部标识。
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
