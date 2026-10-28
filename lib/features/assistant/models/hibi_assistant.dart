import 'agent.dart';
import 'colleague_roster.dart';

/// 内置管家「管家-Hibi」：名称/职能写死，标星置顶，不可改名/改职能/删除。
/// id 保持 agent_hibi_builtin，已有对话记录继续沿用。
/// 端侧直连模型 API + 固定 tools，本地写日程/思维。
class HibiAssistant {
  HibiAssistant._();

  static const String id = ColleagueRoster.butlerId;
  static const String name = '管家-Hibi';

  /// 职能与 [ColleagueRoster.butler] 相同。
  static String get role => ColleagueRoster.butler.role;

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
