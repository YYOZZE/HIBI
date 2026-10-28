import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/colleague_roster.dart';
import '../models/project_group.dart';
import '../models/work_log_entry.dart';
import 'colleague_endpoint_store.dart';
import 'openai_compatible_direct_api.dart';
import 'project_group_store.dart';

/// 管家建群，以及群里按人轮流发言。私聊记录不写进这里。
class GroupDiscussion {
  GroupDiscussion._();

  static Future<ProjectGroup> convene({
    required String projectId,
    required String projectTitle,
    required List<WorkLogEntry> logs,
    String? request,
  }) async {
    final cfg = await ColleagueEndpointStore.resolve(ColleagueRoster.butlerId);
    final names = ColleagueRoster.all
        .where((s) => s.kind != StaffKind.butler)
        .map((s) => s.name)
        .join('、');
    final logText = logs.isEmpty
        ? '（还没有工作日志）'
        : logs.reversed.take(6).map((e) => '${e.title} ${e.body}'.trim()).join('\n');
    final reply = await OpenAiCompatibleDirectApi().chat(
      apiKey: cfg.effectiveApiKey,
      baseUrl: cfg.effectiveBaseUrl,
      model: cfg.effectiveModel,
      systemPrompt: '''
${ColleagueRoster.butler.role.trim()}
你现在只决定要不要为当前项目开一间群聊。助手人数是固定的，不能发明新人。
只输出一个 JSON，不要写别的字：
{"create":true,"title":"短标题","purpose":"为什么要讨论","members":["秘书-Vega","女仆-Luna"]}
或不需要时：{"create":false,"reason":"一句话原因"}
members 从这些现有人员里选 2 到 4 位：$names
''',
      userMessage: '项目：$projectTitle\n'
          '${request == null || request.trim().isEmpty ? '' : '用户刚说：${request.trim()}\n'}'
          '最近的工作记录：\n$logText',
    );
    final map = _readJson(reply);
    if (map['create'] != true) {
      final reason = (map['reason'] ?? '管家认为这件事还不用开群').toString();
      throw StateError(reason);
    }
    final members = map['members'];
    final tokens = members is List
        ? members.map((e) => e.toString()).toList()
        : (members ?? '').toString().split(RegExp(r'[,，、\s]+'));
    return ProjectGroupStore.instance.create(
      projectId: projectId,
      title: (map['title'] ?? '项目讨论').toString(),
      purpose: (map['purpose'] ?? '').toString(),
      memberTokens: tokens,
    );
  }

  /// 用户在群里说了一句之后，在场的人按顺序各说一两句。
  static Future<void> round(ProjectGroup group, {String? userText}) async {
    final store = ProjectGroupStore.instance;
    if (userText != null && userText.trim().isNotEmpty) {
      await store.append(
        group.id,
        speakerId: 'user',
        speakerName: '你',
        content: userText.trim(),
      );
    }
    final members = group.memberIds
        .map(ColleagueRoster.tryById)
        .whereType<StaffSpec>()
        .toList();
    try {
      for (final spec in members) {
        ProjectGroupStore.speakingId.value = spec.id;
        final transcript = store
            .messagesOf(group.id)
            .map((m) => '${m.speakerName}：${m.content}')
            .join('\n');
        final cfg = await ColleagueEndpointStore.resolve(spec.id);
        final reply = await OpenAiCompatibleDirectApi().chat(
          apiKey: cfg.effectiveApiKey,
          baseUrl: cfg.effectiveBaseUrl,
          model: cfg.effectiveModel,
          systemPrompt: '''
${spec.role.trim()}
你正在项目群聊「${group.title}」里发言。只代表你自己说一两句，不要替别人说话，不要复述整段记录。
''',
          userMessage: '目前的讨论：\n$transcript\n\n轮到你了。',
        );
        await store.append(
          group.id,
          speakerId: spec.id,
          speakerName: spec.name,
          content: reply,
        );
      }
    } finally {
      ProjectGroupStore.speakingId.value = null;
    }
  }

  static Map<String, dynamic> _readJson(String raw) {
    final text = raw.trim();
    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start < 0 || end <= start) {
      throw StateError('管家没有给出可执行的建群决定');
    }
    final decoded = jsonDecode(text.substring(start, end + 1));
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
    throw StateError('管家没有给出可执行的建群决定');
  }
}

/// 本地 3B 经常不发工具调用，只口头答应。
/// 用户明确要求建群时，由应用编排建群，不依赖模型自己调用工具。
/// 这不是 OpenClaw 的运行时，只借用「管家分派、固定成员进同一间房」这一层。
class GroupOrchestrator {
  GroupOrchestrator._();

  static final opened = ValueNotifier<({String id, String userText})?>(null);

  static bool wantsGroup(String text) {
    final t = text.replaceAll(RegExp(r'\s+'), '');
    const keys = ['建群', '组群', '拉群', '群聊', '开会', '聚在一起', '组一个群', '大家一起'];
    return keys.any(t.contains);
  }

  static Future<ProjectGroup> openForRequest({
    required String projectId,
    required String projectTitle,
    required List<WorkLogEntry> logs,
    required String request,
  }) async {
    try {
      return await GroupDiscussion.convene(
        projectId: projectId,
        projectTitle: projectTitle,
        logs: logs,
        request: request,
      );
    } catch (_) {
      final brief = request.trim();
      final title = brief.length <= 12 ? brief : '${brief.substring(0, 12)}…';
      return ProjectGroupStore.instance.create(
        projectId: projectId,
        title: title.isEmpty ? '项目碰头' : title,
        purpose: brief,
        memberTokens: const ['秘书-Vega', '秘书-Sirius', '女仆-Luna'],
      );
    }
  }
}
