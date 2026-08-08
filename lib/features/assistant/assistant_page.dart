import 'package:flutter/material.dart';

import '../../app/app_glass_styles.dart';
import '../../config/api_config.dart';
import '../auth/login_page.dart';
import '../auth/models/auth_user.dart';
import '../auth/services/auth_repository.dart';
import '../auth/services/user_sync_scheduler.dart';
import '../profile/value_added_page.dart';
import 'models/agent.dart';
import 'models/hibi_assistant.dart';
import 'services/assistant_api.dart';
import 'services/assistant_repository.dart';
import 'services/http_assistant_api.dart';
import 'agent_chat_page.dart';

/// 助理页：智能体列表，创建/重命名/删除，点击进入对话
class AssistantPage extends StatefulWidget {
  const AssistantPage({super.key});

  @override
  State<AssistantPage> createState() => _AssistantPageState();
}

class _AssistantPageState extends State<AssistantPage> {
  final AssistantRepository _repo = AssistantRepository();

  void _onSyncEpoch() {
    _repo.reloadFromDisk().then((_) {
      if (mounted) _refreshAgents();
    });
  }

  late final AssistantApi _api = ApiConfig.isAssistantApiConfigured
      ? HttpAssistantApi(baseUrl: ApiConfig.assistantApiBaseUrl)
      : PlaceholderAssistantApi();
  List<Agent> _agents = [];

  @override
  void initState() {
    super.initState();
    UserSyncScheduler.syncEpoch.addListener(_onSyncEpoch);
    _repo.ensureLoaded().then((_) {
      if (mounted) _refreshAgents();
    });
  }

  @override
  void dispose() {
    UserSyncScheduler.syncEpoch.removeListener(_onSyncEpoch);
    super.dispose();
  }

  void _refreshAgents() {
    setState(() => _agents = _repo.agents);
  }

  void _openSubscriptionPage() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const ValueAddedPage()),
    );
  }

  Future<void> _createAgent() async {
    final result = await showDialog<({String name, String role})>(
      context: context,
      builder: (ctx) {
        final nameController = TextEditingController();
        final roleController = TextEditingController();
        final theme = Theme.of(ctx);
        final hintStyle = theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant.withOpacity(0.65),
        );
        final dialogBg = theme.colorScheme.surfaceContainerHigh;
        return AlertDialog(
          backgroundColor: dialogBg,
          surfaceTintColor: Colors.transparent,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('新建智能体'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: nameController,
                autofocus: true,
                style: theme.textTheme.bodyLarge
                    ?.copyWith(color: theme.colorScheme.onSurface),
                decoration: InputDecoration(
                  hintText: '输入智能体名称',
                  hintStyle: hintStyle,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6)),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                ),
                onSubmitted: (_) => Navigator.of(ctx).pop((
                  name: nameController.text,
                  role: roleController.text,
                )),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: roleController,
                minLines: 3,
                maxLines: 5,
                style: theme.textTheme.bodyLarge
                    ?.copyWith(color: theme.colorScheme.onSurface),
                decoration: InputDecoration(
                  hintText: '输入智能体职能',
                  hintStyle: hintStyle,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6)),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  alignLabelWithHint: true,
                ),
                onSubmitted: (_) => Navigator.of(ctx).pop((
                  name: nameController.text,
                  role: roleController.text,
                )),
              ),
            ],
          ),
          actions: [
            OutlinedButton(
              onPressed: () => Navigator.of(ctx).pop(),
              style: OutlinedButton.styleFrom(
                foregroundColor: theme.colorScheme.onSurface,
                side: BorderSide(
                    color: theme.colorScheme.outline.withOpacity(0.55)),
              ),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop((
                name: nameController.text,
                role: roleController.text,
              )),
              child: const Text('创建'),
            ),
          ],
        );
      },
    );
    if (result != null) {
      await _repo.addAgent(result.name, result.role);
      _refreshAgents();
    }
  }

  Future<void> _renameAgent(Agent agent) async {
    if (!agent.canEditName) return;
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final c = TextEditingController(text: agent.name);
        return AlertDialog(
          backgroundColor: Theme.of(ctx).colorScheme.surfaceContainerHigh,
          surfaceTintColor: Colors.transparent,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('修改名称'),
          content: TextField(
            controller: c,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: '智能体名称',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (v) => Navigator.of(ctx).pop(v),
          ),
          actions: [
            OutlinedButton(
              onPressed: () => Navigator.of(ctx).pop(),
              style: OutlinedButton.styleFrom(
                foregroundColor: Theme.of(ctx).colorScheme.onSurface,
                side: BorderSide(
                    color: Theme.of(ctx).colorScheme.outline.withOpacity(0.55)),
              ),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(c.text),
              child: const Text('保存'),
            ),
          ],
        );
      },
    );
    if (name != null) {
      await _repo.updateAgentName(agent.id, name);
      _refreshAgents();
    }
  }

  Future<void> _editRoleAgent(Agent agent) async {
    if (!agent.canEditRole) return;
    final theme = Theme.of(context);
    final hintStyle = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant.withOpacity(0.65),
    );
    final role = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final roleController = TextEditingController(text: agent.role);
        return AlertDialog(
          backgroundColor: Theme.of(ctx).colorScheme.surfaceContainerHigh,
          surfaceTintColor: Colors.transparent,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('修改职能'),
          content: TextField(
            controller: roleController,
            autofocus: true,
            minLines: 3,
            maxLines: 5,
            style: theme.textTheme.bodyLarge
                ?.copyWith(color: theme.colorScheme.onSurface),
            decoration: InputDecoration(
              hintText: '输入智能体职能',
              hintStyle: hintStyle,
              border:
                  OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              alignLabelWithHint: true,
            ),
            onSubmitted: (v) => Navigator.of(ctx).pop(v),
          ),
          actions: [
            OutlinedButton(
              onPressed: () => Navigator.of(ctx).pop(),
              style: OutlinedButton.styleFrom(
                foregroundColor: Theme.of(ctx).colorScheme.onSurface,
                side: BorderSide(
                    color: Theme.of(ctx).colorScheme.outline.withOpacity(0.55)),
              ),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(roleController.text),
              child: const Text('保存'),
            ),
          ],
        );
      },
    );
    if (role != null) {
      await _repo.updateAgentRole(agent.id, role);
      _refreshAgents();
    }
  }

  Future<void> _deleteAgent(Agent agent) async {
    if (!agent.canDelete) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(ctx).colorScheme.surfaceContainerHigh,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('删除智能体'),
        content: Text('确定删除「${agent.name}」？对话记录将一并清除。'),
        actions: [
          OutlinedButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            style: OutlinedButton.styleFrom(
              foregroundColor: Theme.of(ctx).colorScheme.onSurface,
              side: BorderSide(
                  color: Theme.of(ctx).colorScheme.outline.withOpacity(0.55)),
            ),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await _repo.deleteAgent(agent.id);
      _refreshAgents();
    }
  }

  void _openChat(Agent agent) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (ctx) => AgentChatPage(
          agent: agent,
          repository: _repo,
          api: _api,
          onAgentUpdated: _refreshAgents,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AuthUser?>(
      valueListenable: AuthRepository.instance.currentUserNotifier,
      builder: (context, user, _) {
        if (user == null) {
          return _buildLoginRequired(context);
        }
        return _buildAssistantContent(context);
      },
    );
  }

  /// 未登录时显示：仅登录用户可使用助理
  Widget _buildLoginRequired(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: theme.appBarTheme.backgroundColor,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: const Text('助理'),
        actions: [_buildSubscribeMiniButton(context)],
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.smart_toy_outlined,
                  size: 64, color: colorScheme.outline),
              const SizedBox(height: 20),
              Text(
                '请登录后使用助理功能',
                style: theme.textTheme.titleLarge
                    ?.copyWith(color: colorScheme.onSurface),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Text(
                '本地账户无法使用智能体与对话，登录后可同步并使用助理服务。',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: colorScheme.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(builder: (_) => const LoginPage()),
                  );
                },
                icon: const Icon(Icons.login),
                label: const Text('去登录'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// AppBar 右侧 TextButton 统一样式（新建助理 / 订阅）
  ButtonStyle _appBarActionButtonStyle(BuildContext context) {
    final theme = Theme.of(context);
    return TextButton.styleFrom(
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      textStyle:
          theme.textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w600),
    );
  }

  Widget _buildSubscribeMiniButton(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: TextButton.icon(
        onPressed: _openSubscriptionPage,
        icon: const Icon(Icons.workspace_premium_outlined, size: 18),
        label: const Text('订阅'),
        style: _appBarActionButtonStyle(context),
      ),
    );
  }

  Widget _buildAssistantContent(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Theme.of(context).appBarTheme.backgroundColor,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: const Text('助理'),
        actions: [
          TextButton.icon(
            onPressed: _createAgent,
            icon: const Icon(Icons.smart_toy_outlined, size: 18),
            label: const Text('新建助理'),
            style: _appBarActionButtonStyle(context),
          ),
          _buildSubscribeMiniButton(context),
        ],
      ),
      body: _agents.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.smart_toy_outlined,
                      size: 64, color: colorScheme.outline),
                  const SizedBox(height: 16),
                  Text(
                    '暂无智能体',
                    style: theme.textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '点击标题栏“新建助理”开始创建',
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              itemCount: _agents.length,
              itemBuilder: (context, index) {
                final agent = _agents[index];
                final skillLabels = agent.isBuiltIn
                    ? HibiAssistant.skills.map((s) => s.label).join(' · ')
                    : null;
                return AppGlassStyles.listCard(
                  context,
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: colorScheme.primaryContainer,
                      child: Icon(
                        agent.isBuiltIn
                            ? Icons.auto_awesome
                            : Icons.smart_toy,
                        color: colorScheme.onPrimaryContainer,
                      ),
                    ),
                    title: Row(
                      children: [
                        Flexible(child: Text(agent.name)),
                        if (agent.isPinned) ...[
                          const SizedBox(width: 6),
                          Icon(
                            Icons.star_rounded,
                            size: 18,
                            color: colorScheme.primary,
                          ),
                        ],
                      ],
                    ),
                    subtitle: Text(
                      agent.isBuiltIn
                          ? 'Skills：$skillLabels · 点击进入对话'
                          : (agent.isAutoCreated
                              ? '项目助理 · 点击进入对话'
                              : '点击进入对话'),
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: colorScheme.onSurfaceVariant),
                    ),
                    trailing: agent.isBuiltIn
                        ? Icon(
                            Icons.lock_outline,
                            size: 18,
                            color: colorScheme.onSurfaceVariant,
                          )
                        : PopupMenuButton<String>(
                            icon: const Icon(Icons.more_vert),
                            onSelected: (v) {
                              if (v == 'rename') _renameAgent(agent);
                              if (v == 'editRole') _editRoleAgent(agent);
                              if (v == 'delete') _deleteAgent(agent);
                            },
                            itemBuilder: (_) => [
                              const PopupMenuItem(
                                  value: 'rename', child: Text('修改名称')),
                              if (!agent.isAutoCreated)
                                const PopupMenuItem(
                                    value: 'editRole', child: Text('修改职能')),
                              const PopupMenuItem(
                                  value: 'delete', child: Text('删除')),
                            ],
                          ),
                    onTap: () => _openChat(agent),
                  ),
                );
              },
            ),
    );
  }
}
