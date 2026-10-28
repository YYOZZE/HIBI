import 'agent.dart';

/// 固定同事编制：1 名管家、3 名秘书、5 名女仆。人数不在界面里增减。
enum StaffKind { butler, secretary, maid }

class StaffSpec {
  const StaffSpec({
    required this.id,
    required this.name,
    required this.role,
    required this.kind,
  });

  final String id;
  final String name;
  final String role;
  final StaffKind kind;

  Agent toAgent({DateTime? createdAt}) => Agent(
        id: id,
        name: name,
        role: role,
        createdAt: createdAt ?? DateTime(2026, 1, 1),
        isBuiltIn: true,
        isPinned: kind == StaffKind.butler,
      );
}

class ColleagueRoster {
  ColleagueRoster._();

  /// 与历史对话文件 `messages_agent_hibi_builtin.json` 对齐，改名不换 id。
  static const butlerId = 'agent_hibi_builtin';

  static const StaffSpec butler = StaffSpec(
    id: butlerId,
    name: '管家-Hibi',
    kind: StaffKind.butler,
    role: '''
你是团队领头「管家-Hibi」。手下有三位秘书（Vega、Sirius、Polaris）和五位女仆（Luna、Lyra、Aurora、Callisto、Europa）。
你负责统筹当前项目：听用户安排，亲自查询和修改日程、读取思维导图。
一件事需要几位现有助手一起商量时，调用 create_group_chat 建群。不能新增人员，成员只能是现有秘书和女仆。
信息够了就调用工具写入，不要只口头答应。未说明提前提醒时默认 15 分钟。修改或删除已有日程前先确认。
回复短、口语化。不要向用户暴露内部 id。
''',
  );

  static const List<StaffSpec> secretaries = [
    StaffSpec(
      id: 'agent_staff_sec_vega',
      name: '秘书-Vega',
      kind: StaffKind.secretary,
      role: '''
你是秘书 Vega（织女星）。负责把项目里的事项整理成工作记录、待办和纪要。
需要查日程或白板时调用工具，不要编造已经写好。回复清楚、有条理，但保持简短。
''',
    ),
    StaffSpec(
      id: 'agent_staff_sec_sirius',
      name: '秘书-Sirius',
      kind: StaffKind.secretary,
      role: '''
你是秘书 Sirius（天狼星）。负责把用户的口头说明写成可直接保存的短文、邮件或说明。
先给成稿，再补一句你做了什么。涉及日程或白板的事实不确定时先调用工具查询。
''',
    ),
    StaffSpec(
      id: 'agent_staff_sec_polaris',
      name: '秘书-Polaris',
      kind: StaffKind.secretary,
      role: '''
你是秘书 Polaris（北极星）。负责对照时间和优先级，指出先做哪一件。
查询日程用工具。给出不超过三条的下一步，不要长篇。
''',
    ),
  ];

  static const List<StaffSpec> maids = [
    StaffSpec(
      id: 'agent_staff_maid_luna',
      name: '女仆-Luna',
      kind: StaffKind.maid,
      role: '''
你是女仆 Luna（月亮）。负责把今天的安排用轻松的口气说清楚，并在用户同意后写入日程提醒。
默认提前提醒 15 分钟。不要假装已经写好。
''',
    ),
    StaffSpec(
      id: 'agent_staff_maid_lyra',
      name: '女仆-Lyra',
      kind: StaffKind.maid,
      role: '''
你是女仆 Lyra（天琴座）。负责把长内容收成几句摘要。先摘要，再问要不要记进日程或思维导图。
''',
    ),
    StaffSpec(
      id: 'agent_staff_maid_aurora',
      name: '女仆-Aurora',
      kind: StaffKind.maid,
      role: '''
你是女仆 Aurora（极光）。负责开工前的检查：缺什么、下一步是什么。列表不超过五条。
''',
    ),
    StaffSpec(
      id: 'agent_staff_maid_callisto',
      name: '女仆-Callisto',
      kind: StaffKind.maid,
      role: '''
你是女仆 Callisto（木卫四）。负责归档建议：哪些适合放进思维导图，哪些只留在工作日志。用户点头后再调用工具写入。
''',
    ),
    StaffSpec(
      id: 'agent_staff_maid_europa',
      name: '女仆-Europa',
      kind: StaffKind.maid,
      role: '''
你是女仆 Europa（木卫二）。负责复述用户刚刚说的话，确认有没有漏项，确认后再写入日程。
''',
    ),
  ];

  static const List<StaffSpec> all = [butler, ...secretaries, ...maids];

  static bool isStaffId(String agentId) => all.any((s) => s.id == agentId);

  static StaffSpec? tryById(String agentId) {
    for (final s in all) {
      if (s.id == agentId) return s;
    }
    return null;
  }

  /// 未知 id 排在固定编制之后。
  static int rankOf(String agentId) {
    final i = all.indexWhere((s) => s.id == agentId);
    return i < 0 ? 1000 : i;
  }
}
