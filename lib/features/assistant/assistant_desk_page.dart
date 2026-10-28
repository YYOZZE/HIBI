import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_glass_styles.dart';
import '../../app/frosted_background.dart';
import '../../config/api_config.dart';
import '../auth/github_login_page.dart';
import '../auth/models/auth_user.dart';
import '../auth/services/auth_repository.dart';
import '../mind/mind_canvas_page.dart';
import '../mind/models/mind_node.dart';
import '../mind/services/mind_repository.dart';
import '../schedule/schedule_page.dart';
import 'agent_chat_page.dart';
import 'models/agent.dart';
import 'models/assistant_project.dart';
import 'models/colleague_roster.dart';
import 'models/mind_topic_ref.dart';
import 'models/project_group.dart';
import 'models/work_log_entry.dart';
import 'services/assistant_api.dart';
import 'services/assistant_project_store.dart';
import 'services/assistant_repository.dart';
import 'services/chat_session_service.dart';
import 'services/colleague_endpoint_store.dart';
import 'services/desk_project_context.dart';
import 'services/group_discussion.dart';
import 'services/http_assistant_api.dart';
import 'services/local_llama_server.dart';
import 'services/project_group_store.dart';
import 'widgets/return_to_assistant_button.dart';

enum _MonitorKind { log, chat, group }

/// 助理工作台：左项目、中监视器、右同事。管家 / 思维导图 / 日程在监视器下方。
class AssistantDeskPage extends StatefulWidget {
  const AssistantDeskPage({super.key});

  @override
  State<AssistantDeskPage> createState() => _AssistantDeskPageState();
}

class _AssistantDeskPageState extends State<AssistantDeskPage> {
  final AssistantRepository _repo = AssistantRepository();
  final AssistantProjectStore _store = AssistantProjectStore.instance;
  final ProjectGroupStore _groups = ProjectGroupStore.instance;
  final TextEditingController _groupInput = TextEditingController();
  late final AssistantApi _api = ApiConfig.isAssistantApiConfigured
      ? HttpAssistantApi(baseUrl: ApiConfig.assistantApiBaseUrl)
      : PlaceholderAssistantApi();

  bool _ready = false;
  String? _projectId;
  String? _agentId;
  String? _groupId;
  bool _discussing = false;
  _MonitorKind _monitor = _MonitorKind.log;
  String _endpointLabel = const ColleagueEndpoint(mode: ColleagueApiMode.local).label;

  @override
  void initState() {
    super.initState();
    LocalLlamaServer.status.addListener(_onLlamaStatus);
    _groups.revision.addListener(_onGroupsChanged);
    ProjectGroupStore.speakingId.addListener(_onLlamaStatus);
    GroupOrchestrator.opened.addListener(_onOrchestratedGroup);
    unawaited(_boot());
    unawaited(LocalLlamaServer.ensureRunning().catchError((Object _) {}));
  }

  @override
  void dispose() {
    LocalLlamaServer.status.removeListener(_onLlamaStatus);
    _groups.revision.removeListener(_onGroupsChanged);
    ProjectGroupStore.speakingId.removeListener(_onLlamaStatus);
    GroupOrchestrator.opened.removeListener(_onOrchestratedGroup);
    _groupInput.dispose();
    super.dispose();
  }

  void _onLlamaStatus() {
    if (mounted) setState(() {});
  }

  String? _handledGroupId;

  void _onOrchestratedGroup() {
    final event = GroupOrchestrator.opened.value;
    if (event == null || !mounted || event.id == _handledGroupId) return;
    final group = _groups.find(event.id);
    if (group == null) return;
    _handledGroupId = event.id;
    setState(() {
      _projectId = group.projectId;
      _groupId = group.id;
      _agentId = null;
      _monitor = _MonitorKind.group;
      _discussing = true;
    });
    ProjectGroupStore.focusedProjectId = group.projectId;
    unawaited(() async {
      try {
        await GroupDiscussion.round(group, userText: event.userText);
        await _store.append(
          group.projectId,
          kind: 'system',
          title: '管家建立群聊',
          body: group.title,
        );
      } catch (e) {
        _snack('群聊已建立，发言没有完成：$e');
      } finally {
        if (mounted) setState(() => _discussing = false);
      }
    }());
  }

  void _onGroupsChanged() {
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _boot() async {
    await Future.wait([
      _repo.ensureLoaded(),
      _store.ensureLoaded(),
      _groups.ensureLoaded(),
      MindRepository.instance.ensureLoaded(),
    ]);
    if (!mounted) return;
    setState(() {
      _ready = true;
      _projectId ??= _store.projects.isEmpty ? null : _store.projects.first.id;
    });
    ProjectGroupStore.focusedProjectId = _projectId;
    _publishContext();
  }

  void _publishContext() {
    final project = _project;
    DeskProjectContext.projectId = project?.id;
    DeskProjectContext.title = project?.title ?? '';
    if (project == null) {
      DeskProjectContext.progress = '';
      return;
    }
    final logs = _store.logsOf(project.id).reversed.take(8);
    DeskProjectContext.progress = logs
        .map((e) {
          final body = e.body.trim();
          return body.isEmpty ? e.title : '${e.title}：$body';
        })
        .join('\n');
  }

  AssistantProject? get _project {
    final id = _projectId;
    if (id == null) return null;
    for (final p in _store.projects) {
      if (p.id == id) return p;
    }
    return null;
  }

  Agent? _agentOf(String? id) {
    if (id == null) return null;
    for (final a in _repo.agents) {
      if (a.id == id) return a;
    }
    return ColleagueRoster.tryById(id)?.toAgent();
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _selectProject(String id) async {
    ProjectGroupStore.focusedProjectId = id;
    setState(() {
      _projectId = id;
      _groupId = null;
      if (_monitor != _MonitorKind.chat) {
        _monitor = _MonitorKind.log;
        _agentId = null;
      }
    });
    _publishContext();
  }

  Future<void> _selectAgent(StaffSpec spec) async {
    final label = (await ColleagueEndpointStore.load(spec.id)).label;
    if (!mounted) return;
    setState(() {
      _agentId = spec.id;
      _groupId = null;
      _monitor = _MonitorKind.chat;
      _endpointLabel = label;
    });
    _publishContext();
  }

  void _selectGroup(String id) {
    setState(() {
      _groupId = id;
      _agentId = null;
      _monitor = _MonitorKind.group;
    });
  }

  Future<void> _askButlerForGroup() async {
    final project = _project;
    if (project == null || _discussing) return;
    setState(() => _discussing = true);
    try {
      final group = await GroupDiscussion.convene(
        projectId: project.id,
        projectTitle: project.title,
        logs: _store.logsOf(project.id),
      );
      await _store.append(
        project.id,
        kind: 'system',
        title: '管家建立群聊',
        body: group.title,
      );
      if (!mounted) return;
      setState(() {
        _groupId = group.id;
        _agentId = null;
        _monitor = _MonitorKind.group;
      });
    } catch (e) {
      final text = e.toString().replaceFirst('Bad state: ', '');
      _snack(text);
    } finally {
      if (mounted) setState(() => _discussing = false);
    }
  }

  Future<void> _sendGroup() async {
    final id = _groupId;
    final group = id == null ? null : _groups.find(id);
    final text = _groupInput.text.trim();
    if (group == null || text.isEmpty || _discussing) return;
    _groupInput.clear();
    setState(() => _discussing = true);
    try {
      await GroupDiscussion.round(group, userText: text);
    } catch (e) {
      _snack('群聊讨论没有完成：$e');
    } finally {
      if (mounted) setState(() => _discussing = false);
    }
  }

  Future<void> _createProject() async {
    final title = await _askText(title: '新建项目', hint: '项目名称', initial: '');
    if (title == null) return;
    final p = await _store.addProject(title);
    if (!mounted) return;
    setState(() {
      _projectId = p.id;
      _monitor = _MonitorKind.log;
      _agentId = null;
      _groupId = null;
    });
    ProjectGroupStore.focusedProjectId = p.id;
    _publishContext();
  }

  void _showAgentAcrossProjects(StaffSpec spec) {
    final projects = _store.projects;
    final roleLine = spec.role
        .trim()
        .split('\n')
        .map((l) => l.trim())
        .firstWhere((l) => l.isNotEmpty, orElse: () => spec.name);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            children: [
              Text(spec.name, style: theme.textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(
                '在不同项目里的角色和工作',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              for (final p in projects) ...[
                const Divider(height: 16),
                Text(p.title, style: theme.textTheme.labelLarge),
                const SizedBox(height: 4),
                Text('角色', style: theme.textTheme.labelSmall),
                Text(roleLine, style: theme.textTheme.bodySmall),
                const SizedBox(height: 4),
                Text('工作内容', style: theme.textTheme.labelSmall),
                Text(
                  _workBrief(spec.id, p.id),
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  String _workBrief(String agentId, String projectId) {
    final lines = _store
        .logsOf(projectId)
        .where((e) => e.agentId == agentId)
        .toList();
    if (lines.isEmpty) return '还没有在这个项目留下工作内容。';
    return lines.reversed.take(3).map((e) {
      final body = e.body.trim();
      return body.isEmpty ? e.title : body;
    }).join('；');
  }

  Future<String?> _askText({
    required String title,
    required String hint,
    required String initial,
  }) {
    final c = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: c,
          autofocus: true,
          decoration: InputDecoration(hintText: hint),
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('确定')),
        ],
      ),
    );
  }

  Future<void> _showProjectSettings(AssistantProject project) async {
    await MindRepository.instance.ensureLoaded();
    if (!mounted) return;
    final bound = _store.mindNodeOf(project);
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(ctx).height * 0.72,
            ),
            child: ListView(
              shrinkWrap: true,
              children: [
              ListTile(
                title: Text(project.title, style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text(bound == null ? '未绑定思维导图' : '思维导图：${bound.title}'),
              ),
              ListTile(
                leading: const Icon(Icons.drive_file_rename_outline),
                title: const Text('重命名'),
                onTap: () async {
                  Navigator.pop(ctx);
                  final name = await _askText(
                    title: '重命名项目',
                    hint: '项目名称',
                    initial: project.title,
                  );
                  if (name == null) return;
                  await _store.rename(project.id, name);
                  if (mounted) setState(() {});
                },
              ),
              ListTile(
                leading: const Icon(Icons.account_tree_outlined),
                title: const Text('绑定已有思维导图'),
                onTap: () async {
                  Navigator.pop(ctx);
                  final node = await _pickMindNode();
                  if (node == null) return;
                  await _store.bindMind(
                    project.id,
                    node.id,
                    note: '重新绑定思维导图「${node.title}」',
                  );
                  if (mounted) setState(() {});
                },
              ),
              ListTile(
                leading: const Icon(Icons.add_chart_outlined),
                title: const Text('新建思维导图并绑定'),
                onTap: () async {
                  Navigator.pop(ctx);
                  final node = await MindRepository.instance.add(project.title);
                  await _store.bindMind(
                    project.id,
                    node.id,
                    note: '新建并绑定思维导图',
                  );
                  if (mounted) setState(() {});
                },
              ),
              ListTile(
                leading: const Icon(Icons.link_off),
                title: const Text('解绑思维导图'),
                enabled: project.isBound,
                onTap: project.isBound
                    ? () async {
                        Navigator.pop(ctx);
                        await _store.bindMind(
                          project.id,
                          null,
                          note: '已解绑思维导图',
                        );
                        if (mounted) setState(() {});
                      }
                    : null,
              ),
              ListTile(
                leading: Icon(Icons.delete_outline, color: Theme.of(ctx).colorScheme.error),
                title: Text('删除项目', style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
                subtitle: const Text('不删除已绑定的思维导图'),
                onTap: () async {
                  Navigator.pop(ctx);
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (d) => AlertDialog(
                      title: const Text('删除项目'),
                      content: Text('删除「${project.title}」及其工作日志？思维导图会保留。'),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('取消')),
                        FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('删除')),
                      ],
                    ),
                  );
                  if (ok != true) return;
                  await _store.deleteProject(project.id);
                  if (!mounted) return;
                  setState(() {
                    if (_projectId == project.id) {
                      _projectId = _store.projects.isEmpty ? null : _store.projects.first.id;
                      _monitor = _MonitorKind.log;
                    }
                  });
                },
              ),
              const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<MindNode?> _pickMindNode() async {
    await MindRepository.instance.ensureLoaded();
    final nodes = MindRepository.instance.nodes;
    if (!mounted) return null;
    if (nodes.isEmpty) {
      _snack('还没有思维导图，可以先新建一块');
      return null;
    }
    return showDialog<MindNode>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('选择思维导图'),
        content: SizedBox(
          width: 360,
          height: 320,
          child: ListView(
            children: [
              for (final n in nodes)
                ListTile(
                  title: Text(n.title.trim().isEmpty ? '未命名' : n.title),
                  onTap: () => Navigator.pop(ctx, n),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
        ],
      ),
    );
  }

  Future<void> _openMind() async {
    final project = _project;
    if (project == null) {
      _snack('先在左侧选择一个项目');
      return;
    }
    await MindRepository.instance.ensureLoaded();
    final node = _store.mindNodeOf(project);
    if (node == null) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('未绑定'),
          content: Text('「${project.title}」还没有绑定思维导图。请长按左侧项目进行绑定。'),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
      return;
    }
    if (!mounted) return;
    final opened = node;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AssistantReturnHost(
          child: MindCanvasPage(
            project: opened,
            repository: MindRepository.instance,
            onSaved: () {},
          ),
        ),
      ),
    );
  }

  Future<void> _openSchedule() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const AssistantReturnHost(child: SchedulePage()),
      ),
    );
  }

  Future<void> _addNote() async {
    final project = _project;
    if (project == null) return;
    final text = await _askText(title: '记一笔', hint: '写进这个项目的工作日志', initial: '');
    if (text == null || text.trim().isEmpty) return;
    await _store.append(project.id, kind: 'note', title: '手记', body: text.trim());
    if (mounted) setState(() {});
  }

  Future<void> _onUserSent(String text) async {
    final project = _project;
    final agent = _agentOf(_agentId);
    if (project == null || agent == null || text.trim().isEmpty) return;
    final body = text.trim();
    await _store.append(
      project.id,
      kind: 'chat',
      title: '与 ${agent.name} 对话',
      body: body.length > 80 ? '${body.substring(0, 80)}…' : body,
      agentId: agent.id,
      agentName: agent.name,
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = AuthRepository.instance;
    return ValueListenableBuilder<AuthUser?>(
      valueListenable: auth.currentUserNotifier,
      builder: (context, _, __) {
        return ValueListenableBuilder<bool>(
          valueListenable: auth.githubAccessGrantedNotifier,
          builder: (context, __, ___) {
            if (!auth.canUseAssistant) return _locked(context);
            return _desk(context);
          },
        );
      },
    );
  }

  Widget _locked(BuildContext context) {
    final isLocal = AuthRepository.instance.accessState == AppAccessState.local;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        fit: StackFit.expand,
        children: [
          const FrostedBackground(),
          SafeArea(
            child: Column(
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: IconButton(
                    tooltip: '返回',
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.arrow_back),
                  ),
                ),
                const Spacer(),
                const Icon(Icons.lock_outline, size: 56),
                const SizedBox(height: 12),
                Text(isLocal ? '本地账号无法使用助理' : '需要登录后才能使用助理'),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(builder: (_) => const GitHubLoginPage()),
                    );
                  },
                  child: Text(isLocal ? '用 GitHub 登录' : '去登录'),
                ),
                const Spacer(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _desk(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        fit: StackFit.expand,
        children: [
          const FrostedBackground(),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              child: Column(
                children: [
                  _topBar(theme),
                  const SizedBox(height: 8),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, c) {
                        if (!_ready) {
                          return const Center(child: CircularProgressIndicator());
                        }
                        final wide = c.maxWidth >= 900;
                        if (wide) {
                          return Row(
                            children: [
                              SizedBox(width: 196, child: _projectPane(theme)),
                              const SizedBox(width: 8),
                              Expanded(child: _centerPane(theme)),
                              const SizedBox(width: 8),
                              SizedBox(width: 196, child: _colleaguePane(theme)),
                            ],
                          );
                        }
                        return Column(
                          children: [
                            SizedBox(height: 84, child: _projectPane(theme, horizontal: true)),
                            const SizedBox(height: 8),
                            Expanded(child: _centerPane(theme)),
                            const SizedBox(height: 8),
                            SizedBox(height: 88, child: _colleaguePane(theme, horizontal: true)),
                          ],
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _topBar(ThemeData theme) {
    return Row(
      children: [
        IconButton(
          tooltip: '返回',
          onPressed: () => Navigator.of(context).maybePop(),
          icon: const Icon(Icons.arrow_back),
        ),
        Text('助理', style: theme.textTheme.titleLarge),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            LocalLlamaServer.status.value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }

  Widget _projectPane(ThemeData theme, {bool horizontal = false}) {
    final projects = _store.projects;
    final header = Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('项目', style: theme.textTheme.titleSmall),
              Text(
                '长按可设置绑定',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        IconButton(
          tooltip: '新建项目',
          visualDensity: VisualDensity.compact,
          onPressed: _createProject,
          icon: const Icon(Icons.add, size: 18),
        ),
      ],
    );
    final body = projects.isEmpty
        ? const Center(child: Text('还没有项目'))
        : ListView.builder(
            scrollDirection: horizontal ? Axis.horizontal : Axis.vertical,
            itemCount: projects.length,
            itemBuilder: (context, i) {
              final p = projects[i];
              final selected = p.id == _projectId;
              final mind = _store.mindNodeOf(p);
              final subtitle = !p.isBound
                  ? '未绑定'
                  : (mind == null ? '绑定已失效' : '已绑定');
              return _RosterCard(
                title: p.title,
                meta: subtitle,
                selected: selected,
                bound: p.isBound && mind != null,
                width: horizontal ? 168 : null,
                onTap: () => _selectProject(p.id),
                onLongPress: () => _showProjectSettings(p),
              );
            },
          );
    return AppGlassStyles.section(
      context,
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          Expanded(child: body),
        ],
      ),
    );
  }

  Widget _colleaguePane(ThemeData theme, {bool horizontal = false}) {
    if (horizontal) {
      return AppGlassStyles.section(
        context,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: ListView(
          scrollDirection: Axis.horizontal,
          children: [
            for (final s in ColleagueRoster.secretaries) _colleagueChip(s),
            for (final s in ColleagueRoster.maids) _colleagueChip(s),
          ],
        ),
      );
    }
    return AppGlassStyles.section(
      context,
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      child: ListView(
        children: [
          Text('助手', style: theme.textTheme.labelLarge),
          const SizedBox(height: 2),
          _groupLabel(theme, '秘书'),
          for (final s in ColleagueRoster.secretaries) _colleagueTile(s),
          _groupLabel(theme, '女仆'),
          for (final s in ColleagueRoster.maids) _colleagueTile(s),
          const Padding(
            padding: EdgeInsets.fromLTRB(4, 10, 4, 8),
            child: Divider(height: 1),
          ),
          _groupSection(theme),
        ],
      ),
    );
  }

  Widget _groupSection(ThemeData theme) {
    final project = _project;
    final groups = project == null ? const <ProjectGroup>[] : _groups.groupsFor(project.id);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text('群聊', style: theme.textTheme.labelLarge),
            const Spacer(),
            IconButton(
              tooltip: '请管家按当前项目建群',
              visualDensity: VisualDensity.compact,
              onPressed: project == null || _discussing ? null : _askButlerForGroup,
              icon: const Icon(Icons.forum_outlined, size: 16),
            ),
          ],
        ),
        if (project == null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: Text(
              '选中项目后显示',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          )
        else if (groups.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: Text(
              '还没有。点右侧图标，管家按项目决定要不要建。',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          )
        else
          for (final g in groups)
            _RosterCard(
              title: g.title,
              meta: '${g.memberIds.length}人',
              selected: _monitor == _MonitorKind.group && _groupId == g.id,
              onTap: () => _selectGroup(g.id),
            ),
      ],
    );
  }

  Widget _groupLabel(ThemeData theme, String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant.withOpacity(0.85),
          letterSpacing: 0.6,
        ),
      ),
    );
  }

  Widget _colleagueTile(StaffSpec spec) {
    final selected = _monitor == _MonitorKind.chat && _agentId == spec.id;
    return _RosterCard(
      title: spec.name,
      selected: selected,
      agentId: spec.id,
      onTap: () => _selectAgent(spec),
    );
  }

  Widget _colleagueChip(StaffSpec spec) {
    final selected = _monitor == _MonitorKind.chat && _agentId == spec.id;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(spec.name),
        selected: selected,
        onSelected: (_) => _selectAgent(spec),
      ),
    );
  }

  Widget _centerPane(ThemeData theme) {
    return Column(
      children: [
        Expanded(child: _monitorFrame(theme)),
        const SizedBox(height: 8),
        _jumpBar(theme),
      ],
    );
  }

  Widget _jumpBar(ThemeData theme) {
    final butlerOn = _monitor == _MonitorKind.chat && _agentId == ColleagueRoster.butlerId;
    return SizedBox(
      height: 52,
      child: Row(
        children: [
          Expanded(
            child: _jumpButton(
              theme,
              icon: Icons.support_agent,
              label: ColleagueRoster.butler.name,
              selected: butlerOn,
              onTap: () => _selectAgent(ColleagueRoster.butler),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _jumpButton(
              theme,
              icon: Icons.account_tree_outlined,
              label: '思维导图',
              selected: false,
              onTap: _openMind,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _jumpButton(
              theme,
              icon: Icons.event_note_outlined,
              label: '日程',
              selected: false,
              onTap: _openSchedule,
            ),
          ),
        ],
      ),
    );
  }

  Widget _jumpButton(
    ThemeData theme, {
    required IconData icon,
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final cs = theme.colorScheme;
    final fg = selected ? cs.onSurface : cs.onSurface.withOpacity(0.92);
    return Material(
      color: selected ? cs.primary.withOpacity(0.18) : Colors.white.withOpacity(0.06),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? cs.primary.withOpacity(0.6) : cs.outline.withOpacity(0.38),
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 16, color: fg),
              const SizedBox(height: 2),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontSize: 12,
                    color: fg,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _monitorFrame(ThemeData theme) {
    final cs = theme.colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.28),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outline.withOpacity(0.28)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _monitorHeader(theme),
            const Divider(height: 1),
            Expanded(child: _monitorBody(theme)),
          ],
        ),
      ),
    );
  }

  Widget _monitorHeader(ThemeData theme) {
    final project = _project;
    final agent = _agentOf(_agentId);
    final group = _groupId == null ? null : _groups.find(_groupId!);
    final speaking = ProjectGroupStore.speakingId.value;
    final speakingName = speaking == null ? null : ColleagueRoster.tryById(speaking)?.name;
    final String title;
    final String subtitle;
    if (_monitor == _MonitorKind.group && group != null) {
      title = group.title;
      subtitle = speakingName == null ? '群聊 · ${group.memberIds.length}人' : '$speakingName 正在发言';
    } else if (_monitor == _MonitorKind.chat && agent != null) {
      title = agent.name;
      subtitle = '对话记录 · $_endpointLabel';
    } else {
      title = project?.title ?? '工作日志';
      subtitle = '工作日志';
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
      child: Row(
        children: [
          if (_monitor == _MonitorKind.chat && agent != null) ...[
            _LiveLamp(agentId: agent.id, showing: true, size: 7),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.labelLarge,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  subtitle,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          if (_monitor == _MonitorKind.chat && project != null) ...[
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                project.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            if (agent != null && agent.id != ColleagueRoster.butlerId)
              TextButton(
                onPressed: () {
                  final spec = ColleagueRoster.tryById(agent.id);
                  if (spec != null) _showAgentAcrossProjects(spec);
                },
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text('项目'),
              ),
          ],
          if (_monitor == _MonitorKind.log && project != null)
            IconButton(
              tooltip: '记一笔',
              visualDensity: VisualDensity.compact,
              onPressed: _addNote,
              icon: const Icon(Icons.edit_note, size: 18),
            ),
        ],
      ),
    );
  }

  Widget _monitorBody(ThemeData theme) {
    if (_monitor == _MonitorKind.group) return _groupBody(theme);
    if (_monitor == _MonitorKind.chat) {
      final agent = _agentOf(_agentId);
      if (agent == null) {
        return const Center(child: Text('选择一位同事'));
      }
      final project = _project;
      final node = project == null ? null : _store.mindNodeOf(project);
      final topic = node == null
          ? null
          : MindTopicRef(projectId: node.id, projectTitle: node.title);
      return AgentChatPage(
        key: ValueKey('desk-${agent.id}-${project?.id ?? 'none'}'),
        agent: agent,
        repository: _repo,
        api: _api,
        onAgentUpdated: () {},
        embedded: true,
        projectId: project?.id,
        currentMindNodeId: node?.id,
        mindProjectTitle: node?.title,
        initialTopicRef: topic,
        onUserSent: (text) => unawaited(_onUserSent(text)),
      );
    }
    final project = _project;
    if (project == null) {
      return const Center(child: Text('选择左侧项目，查看它的工作日志'));
    }
    final logs = _store.logsOf(project.id).reversed.toList();
    if (logs.isEmpty) {
      return const Center(child: Text('还没有记录。和同事说的话、绑定思维导图，都会出现在这里。'));
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      itemCount: logs.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, i) => _logTile(theme, logs[i]),
    );
  }

  Widget _groupBody(ThemeData theme) {
    final group = _groupId == null ? null : _groups.find(_groupId!);
    if (group == null) {
      return const Center(child: Text('选择右侧的一间群聊'));
    }
    final messages = _groups.messagesOf(group.id);
    final cs = theme.colorScheme;
    return Column(
      children: [
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            itemCount: messages.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, i) {
              final m = messages[i];
              final mine = m.isUser;
              return Align(
                alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 460),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: mine
                          ? cs.primary.withOpacity(0.18)
                          : Colors.white.withOpacity(0.05),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: cs.outline.withOpacity(0.2)),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            m.speakerName,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(m.content, style: theme.textTheme.bodySmall),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _groupInput,
                  enabled: !_discussing,
                  textInputAction: TextInputAction.send,
                  style: theme.textTheme.bodySmall,
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: '发到这间群聊',
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  ),
                  onSubmitted: (_) => _sendGroup(),
                ),
              ),
              const SizedBox(width: 6),
              IconButton(
                tooltip: '发送',
                onPressed: _discussing ? null : _sendGroup,
                icon: _discussing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.send, size: 18),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _logTile(ThemeData theme, WorkLogEntry entry) {
    final stamp =
        '${entry.at.month.toString().padLeft(2, '0')}-${entry.at.day.toString().padLeft(2, '0')} '
        '${entry.at.hour.toString().padLeft(2, '0')}:${entry.at.minute.toString().padLeft(2, '0')}';
    final cs = theme.colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: cs.surface.withOpacity(0.55),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('$stamp  ${entry.title}', style: theme.textTheme.labelLarge),
            if (entry.body.trim().isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(entry.body, style: theme.textTheme.bodySmall),
            ],
          ],
        ),
      ),
    );
  }
}

/// 左右栏共用的细卡片：左边指示灯，右边名字，可选状态字。
class _RosterCard extends StatelessWidget {
  const _RosterCard({
    required this.title,
    required this.selected,
    required this.onTap,
    this.meta,
    this.agentId,
    this.bound = false,
    this.width,
    this.onLongPress,
  });

  final String title;
  final String? meta;
  final bool selected;
  final String? agentId;
  final bool bound;
  final double? width;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Padding(
      padding: EdgeInsets.only(bottom: 6, right: width == null ? 0 : 8),
      child: SizedBox(
        width: width,
        child: Material(
          color: selected ? cs.primary.withOpacity(0.14) : Colors.white.withOpacity(0.035),
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: onTap,
            onLongPress: onLongPress,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: selected ? cs.primary.withOpacity(0.5) : cs.outline.withOpacity(0.22),
                ),
              ),
              child: Row(
                children: [
                  if (agentId != null)
                    _LiveLamp(agentId: agentId!, showing: selected)
                  else
                    _LampDot(kind: bound ? _LampKind.bound : _LampKind.idle),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: 13,
                        height: 1.15,
                        fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                      ),
                    ),
                  ),
                  if (meta != null) ...[
                    const SizedBox(width: 6),
                    Text(
                      meta!,
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontSize: 10,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

enum _LampKind { idle, showing, working, done, bound }

/// 跟随某个助手的发送状态：工作中呼吸、刚完成闪一下、正在监视器里则常亮。
class _LiveLamp extends StatefulWidget {
  const _LiveLamp({required this.agentId, required this.showing, this.size = 6});

  final String agentId;
  final bool showing;
  final double size;

  @override
  State<_LiveLamp> createState() => _LiveLampState();
}

class _LiveLampState extends State<_LiveLamp> {
  final ChatSessionService _session = ChatSessionService.instance;
  Timer? _doneTimer;
  bool _done = false;
  bool _wasWorking = false;
  bool _wasSpeaking = false;

  @override
  void initState() {
    super.initState();
    _session.loadingOf(widget.agentId).addListener(_onLoading);
    ProjectGroupStore.speakingId.addListener(_onSpeaking);
    _wasWorking = _session.isLoading(widget.agentId);
  }

  @override
  void didUpdateWidget(covariant _LiveLamp oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.agentId != widget.agentId) {
      _session.loadingOf(oldWidget.agentId).removeListener(_onLoading);
      ProjectGroupStore.speakingId.removeListener(_onSpeaking);
      _session.loadingOf(widget.agentId).addListener(_onLoading);
      ProjectGroupStore.speakingId.addListener(_onSpeaking);
      _doneTimer?.cancel();
      _done = false;
      _wasWorking = _session.isLoading(widget.agentId);
    }
  }

  @override
  void dispose() {
    _doneTimer?.cancel();
    _session.loadingOf(widget.agentId).removeListener(_onLoading);
    ProjectGroupStore.speakingId.removeListener(_onSpeaking);
    super.dispose();
  }

  void _onSpeaking() {
    final speaking = ProjectGroupStore.speakingId.value == widget.agentId;
    if (_wasSpeaking && !speaking) {
      _doneTimer?.cancel();
      _done = true;
      _doneTimer = Timer(const Duration(milliseconds: 1600), () {
        if (!mounted) return;
        setState(() => _done = false);
      });
    }
    _wasSpeaking = speaking;
    if (mounted) setState(() {});
  }

  void _onLoading() {
    final working = _session.isLoading(widget.agentId);
    if (_wasWorking && !working) {
      _doneTimer?.cancel();
      _done = true;
      _doneTimer = Timer(const Duration(milliseconds: 1600), () {
        if (!mounted) return;
        setState(() => _done = false);
      });
    }
    _wasWorking = working;
    if (mounted) setState(() {});
  }

  _LampKind get _kind {
    if (_session.isLoading(widget.agentId) ||
        ProjectGroupStore.speakingId.value == widget.agentId) {
      return _LampKind.working;
    }
    if (_done) return _LampKind.done;
    if (widget.showing) return _LampKind.showing;
    return _LampKind.idle;
  }

  @override
  Widget build(BuildContext context) {
    return _LampDot(kind: _kind, size: widget.size);
  }
}

class _LampDot extends StatefulWidget {
  const _LampDot({required this.kind, this.size = 6});

  final _LampKind kind;
  final double size;

  @override
  State<_LampDot> createState() => _LampDotState();
}

class _LampDotState extends State<_LampDot> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 880),
  );

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(covariant _LampDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    final pulse = widget.kind == _LampKind.working || widget.kind == _LampKind.done;
    if (pulse) {
      if (!_pulse.isAnimating) _pulse.repeat(reverse: true);
    } else {
      _pulse.stop();
      _pulse.value = 1;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = switch (widget.kind) {
      _LampKind.idle => Colors.white.withOpacity(0.28),
      _LampKind.showing => const Color(0xFFA5B4FC),
      _LampKind.working => const Color(0xFF38BDF8),
      _LampKind.done => const Color(0xFF4ADE80),
      _LampKind.bound => const Color(0xFF86EFAC),
    };
    final pulsing = widget.kind == _LampKind.working || widget.kind == _LampKind.done;
    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, _) {
        final t = pulsing ? _pulse.value : 0.0;
        final glow = pulsing ? 4 + 6 * t : (widget.kind == _LampKind.showing ? 4.0 : 0.0);
        return Container(
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            color: color.withOpacity(pulsing ? 0.55 + 0.45 * t : 1),
            shape: BoxShape.circle,
            boxShadow: glow == 0
                ? null
                : [
                    BoxShadow(
                      color: color.withOpacity(0.35 + 0.4 * t),
                      blurRadius: glow,
                      spreadRadius: 0.4,
                    ),
                  ],
          ),
        );
      },
    );
  }
}
