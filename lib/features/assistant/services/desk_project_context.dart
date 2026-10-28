import '../models/colleague_roster.dart';

/// 工作台当前项目。对话请求时读这里，按项目注入进展，不把别的项目带进去。
class DeskProjectContext {
  DeskProjectContext._();

  static String? projectId;
  static String title = '';
  static String progress = '';

  static String promptFor(String agentId) {
    if (title.trim().isEmpty) return '';
    final spec = ColleagueRoster.tryById(agentId);
    final lead = agentId == ColleagueRoster.butlerId;
    final duty = (spec?.role ?? '').trim().split('\n').where((l) => l.trim().isNotEmpty).take(2).join('\n');
    final buf = StringBuffer()
      ..writeln('【层级】管家 > 项目 > 助手。只处理当前项目，不要引用其他项目的聊天或进展。')
      ..writeln('【当前项目】$title');
    if (progress.trim().isNotEmpty) {
      buf.writeln('【项目进展】');
      buf.writeln(progress.trim());
    }
    if (duty.isNotEmpty) {
      buf.writeln(lead ? '【你的位置】你是管家，站在这个项目之上统筹。' : '【你在这个项目里负责】');
      buf.writeln(duty);
    }
    return buf.toString().trim();
  }
}
