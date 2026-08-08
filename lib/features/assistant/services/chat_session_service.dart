import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../../config/api_config.dart';
import '../../auth/services/account_storage_paths.dart';
import '../../auth/services/auth_repository.dart';
import '../../auth/services/user_sync_scheduler.dart';
import '../../profile/services/agent_config_service.dart';
import '../models/agent.dart';
import '../models/chat_attachment.dart';
import '../models/chat_message.dart';
import '../models/hibi_assistant.dart';
import '../models/mind_topic_ref.dart';
import 'assistant_api.dart';
import 'assistant_repository.dart';
import 'client_abp/client_abp_runtime.dart';
import 'openai_compatible_direct_api.dart';

class _QueuedSend {
  _QueuedSend({
    required this.agent,
    required this.repository,
    required this.api,
    required this.userMsgId,
    required this.promptText,
    required this.mindNodeId,
    required this.attachments,
  });

  final Agent agent;
  final AssistantRepository repository;
  final AssistantApi api;
  final String userMsgId;
  final String promptText;
  final String? mindNodeId;
  final List<ChatAttachment> attachments;
}

/// 按 agentId 托管进行中的发送任务与消息队列：
/// 离开对话页不 cancel；思考中可继续入队；支持手动打断当前请求。
class ChatSessionService {
  ChatSessionService._();
  static final ChatSessionService instance = ChatSessionService._();

  final Map<String, ValueNotifier<bool>> _loading = {};
  final Map<String, ValueNotifier<int>> _revision = {};
  final Map<String, ValueNotifier<int>> _queueDepth = {};
  final Map<String, Future<void>> _pump = {};
  final Map<String, List<_QueuedSend>> _queues = {};
  final Map<String, int> _generation = {};
  final Map<String, Completer<void>> _cancelWaiters = {};

  ValueNotifier<bool> loadingOf(String agentId) =>
      _loading.putIfAbsent(agentId, () => ValueNotifier<bool>(false));

  ValueNotifier<int> revisionOf(String agentId) =>
      _revision.putIfAbsent(agentId, () => ValueNotifier<int>(0));

  /// 尚未开始处理的排队条数（不含当前正在思考的一条）。
  ValueNotifier<int> queueDepthOf(String agentId) =>
      _queueDepth.putIfAbsent(agentId, () => ValueNotifier<int>(0));

  bool isLoading(String agentId) => loadingOf(agentId).value;

  int queueDepth(String agentId) => queueDepthOf(agentId).value;

  void _bump(String agentId) {
    revisionOf(agentId).value++;
  }

  void _syncQueueDepth(String agentId) {
    queueDepthOf(agentId).value = _queues[agentId]?.length ?? 0;
  }

  void _setLoading(String agentId, bool v) {
    if (loadingOf(agentId).value != v) {
      loadingOf(agentId).value = v;
    }
  }

  /// 打断当前正在进行的请求；已排队消息仍会按顺序继续处理。
  /// 返回 true 表示已发出打断信号。
  bool cancelCurrent(String agentId) {
    final waiter = _cancelWaiters[agentId];
    if (waiter == null || waiter.isCompleted) return false;
    _generation[agentId] = (_generation[agentId] ?? 0) + 1;
    if (!waiter.isCompleted) waiter.complete();
    return true;
  }

  /// 打断当前请求并清空排队。
  void cancelAll(String agentId) {
    _queues[agentId]?.clear();
    _syncQueueDepth(agentId);
    cancelCurrent(agentId);
  }

  /// 入队一轮对话；思考中也可继续调用，按时间顺序处理。
  Future<void> send({
    required Agent agent,
    required AssistantRepository repository,
    required AssistantApi api,
    required String userText,
    MindTopicRef? topicRef,
    List<ChatAttachment> attachments = const [],
  }) async {
    final agentId = agent.id;
    final trimmed = userText.trim();
    final sendableAtt = attachments.where((a) => a.canSendToModel).toList();
    final videoOnlyNotes = attachments
        .where((a) => a.kind == ChatAttachmentKind.video)
        .map((a) => a.name)
        .toList();

    if (trimmed.isEmpty && sendableAtt.isEmpty) {
      if (videoOnlyNotes.isNotEmpty) {
        await repository.addMessage(
          agentId,
          ChatMessage(
            role: 'assistant',
            content: '已选择视频（${videoOnlyNotes.join('、')}），'
                '当前模型暂不支持解析视频内容。请补充文字说明，或改用图片/文档。',
          ),
        );
        _bump(agentId);
      }
      return;
    }

    final promptBuf = StringBuffer();
    if (topicRef != null) {
      promptBuf.write(topicRef.toPromptPrefix());
    }
    for (final a in sendableAtt) {
      if (a.kind == ChatAttachmentKind.textDoc &&
          (a.extractedText?.trim().isNotEmpty ?? false)) {
        promptBuf.writeln('【附件:${a.name}】');
        promptBuf.writeln(a.extractedText!.trim());
        promptBuf.writeln();
      } else if (a.kind == ChatAttachmentKind.binaryDoc) {
        promptBuf.writeln('【附件:${a.name}】（二进制文档，见 attachments 字段）');
      } else if (a.kind == ChatAttachmentKind.image) {
        promptBuf.writeln('【图片附件:${a.name}】');
      }
    }
    if (videoOnlyNotes.isNotEmpty) {
      promptBuf.writeln(
        '【说明】用户还附带了视频文件：${videoOnlyNotes.join('、')}，'
        '请告知暂无法解析视频，可请用户改用图片或文字描述。',
      );
    }
    if (trimmed.isNotEmpty) {
      promptBuf.writeln(trimmed);
    }
    final promptText = promptBuf.toString().trim();
    if (promptText.isEmpty && sendableAtt.every((a) => !a.isImage)) {
      return;
    }

    final msgId =
        'm_${DateTime.now().microsecondsSinceEpoch}_${trimmed.hashCode.abs()}';
    final persistedAtts = await _persistMessageAttachments(
      agentId: agentId,
      messageId: msgId,
      attachments: attachments,
    );
    final userMsg = ChatMessage(
      id: msgId,
      role: 'user',
      content: trimmed,
      attachments: persistedAtts,
      topicLabel: topicRef?.displayLabel,
    );
    await repository.addMessage(agentId, userMsg);
    _bump(agentId);

    final item = _QueuedSend(
      agent: agent,
      repository: repository,
      api: api,
      userMsgId: userMsg.id,
      promptText: promptText.isEmpty ? trimmed : promptText,
      mindNodeId: topicRef?.projectId ?? agent.mindNodeId,
      attachments: sendableAtt,
    );
    final q = _queues.putIfAbsent(agentId, () => <_QueuedSend>[]);
    q.add(item);
    _syncQueueDepth(agentId);
    _setLoading(agentId, true);
    _bump(agentId);
    _ensurePump(agentId);
  }

  void _ensurePump(String agentId) {
    final existing = _pump[agentId];
    if (existing != null) return;
    late final Future<void> fut;
    fut = _pumpQueue(agentId).whenComplete(() {
      if (identical(_pump[agentId], fut)) {
        _pump.remove(agentId);
      }
      final q = _queues[agentId];
      if (q != null && q.isNotEmpty) {
        // 极端竞态：pump 结束瞬间又有入队
        _ensurePump(agentId);
      } else {
        _setLoading(agentId, false);
        _syncQueueDepth(agentId);
        _bump(agentId);
      }
    });
    _pump[agentId] = fut;
  }

  Future<void> _pumpQueue(String agentId) async {
    while (true) {
      final q = _queues[agentId];
      if (q == null || q.isEmpty) break;
      final item = q.removeAt(0);
      _syncQueueDepth(agentId);
      _setLoading(agentId, true);
      _bump(agentId);
      await _runSend(item);
    }
  }

  Future<void> _runSend(_QueuedSend item) async {
    final agentId = item.agent.id;
    final gen = (_generation[agentId] ?? 0);
    final cancelWaiter = Completer<void>();
    _cancelWaiters[agentId] = cancelWaiter;

    try {
      final history = item.repository
          .getMessages(agentId)
          .where((m) => m.id != item.userMsgId)
          .map<Map<String, String>>(
            (m) => {'role': m.role, 'content': m.historyContent},
          )
          .toList();
      final token = AuthRepository.instance.currentUser?.token;
      final useBackend = token != null && token.isNotEmpty;
      final customModel = await AgentConfigService.activeChatConfig();
      if (_isStale(agentId, gen) || cancelWaiter.isCompleted) {
        await _writeCancelled(item.repository, agentId);
        return;
      }
      final attPayload =
          item.attachments.map((a) => a.toApiPayload()).toList(growable: false);

      final replyFuture = _requestReply(
        api: item.api,
        agent: item.agent,
        text: item.promptText,
        history: history,
        useBackend: useBackend,
        token: token,
        mindNodeId: item.mindNodeId,
        customModel: customModel,
        attachments: attPayload,
      );

      Object? replyOrError;
      var cancelled = false;
      try {
        replyOrError = await Future.any<Object>([
          replyFuture.then<Object>((r) => r),
          cancelWaiter.future.then<Object>((_) {
            cancelled = true;
            return _CancelSentinel();
          }),
        ]);
      } catch (e) {
        if (_isStale(agentId, gen) || cancelled || cancelWaiter.isCompleted) {
          await _writeCancelled(item.repository, agentId);
          return;
        }
        await item.repository.addMessage(
          agentId,
          ChatMessage(role: 'assistant', content: _friendlyChatError(e)),
        );
        _bump(agentId);
        return;
      }

      if (cancelled ||
          replyOrError is _CancelSentinel ||
          _isStale(agentId, gen) ||
          cancelWaiter.isCompleted) {
        await _writeCancelled(item.repository, agentId);
        // 后台请求仍可能完成，结果丢弃
        unawaited(replyFuture.catchError((_) => ''));
        return;
      }

      final reply = replyOrError as String;
      // 端侧 ABP 已写本地日程；若仍走后端 tools，则 pull 合并云端结果。
      if (useBackend && !HibiAssistant.isBuiltInId(agentId)) {
        await UserSyncScheduler.pullAfterAssistantToolUse();
      }
      // 希比助手端侧已写 ScheduleEventStore（eventsNotifier），勿 bump syncEpoch：
      // 会触发聊天页 _loadMessages 的服务端 merge，冲掉本地完整历史。

      if (_isStale(agentId, gen) || cancelWaiter.isCompleted) {
        await _writeCancelled(item.repository, agentId);
        return;
      }

      await item.repository.addMessage(
        agentId,
        ChatMessage(role: 'assistant', content: reply),
      );
      _bump(agentId);
    } catch (e) {
      if (_isStale(agentId, gen) || cancelWaiter.isCompleted) {
        await _writeCancelled(item.repository, agentId);
        return;
      }
      await item.repository.addMessage(
        agentId,
        ChatMessage(role: 'assistant', content: _friendlyChatError(e)),
      );
      _bump(agentId);
    } finally {
      if (identical(_cancelWaiters[agentId], cancelWaiter)) {
        _cancelWaiters.remove(agentId);
      }
    }
  }

  bool _isStale(String agentId, int gen) =>
      (_generation[agentId] ?? 0) != gen;

  Future<void> _writeCancelled(AssistantRepository repository, String agentId) async {
    await repository.addMessage(
      agentId,
      ChatMessage(role: 'assistant', content: '（已打断）'),
    );
    _bump(agentId);
  }

  Future<String> _requestReply({
    required AssistantApi api,
    required Agent agent,
    required String text,
    required List<Map<String, String>> history,
    required bool useBackend,
    required String? token,
    required String? mindNodeId,
    required AgentProviderConfig? customModel,
    required List<Map<String, dynamic>> attachments,
  }) async {
    // 希比助手：端侧直连模型 + 本地 tools，不依赖后端执行工具。
    if (HibiAssistant.isBuiltInId(agent.id)) {
      if (customModel == null || !customModel.hasApiKey) {
        throw Exception(
          '希比助手在 App 端侧运行。请先在「设置 → 智能体配置」填写并选中火山/OpenAI 兼容 API Key。',
        );
      }
      return ClientAbpRuntime().chat(
        agent: agent,
        model: customModel,
        userMessage: text,
        history: history,
        currentMindNodeId: mindNodeId,
        attachments: attachments,
      );
    }

    Future<String> direct() {
      final cfg = customModel!;
      final system = [
        if (agent.name.trim().isNotEmpty) '你是「${agent.name.trim()}」。',
        if (agent.role.trim().isNotEmpty) agent.role.trim(),
      ].join();
      return OpenAiCompatibleDirectApi().chat(
        apiKey: cfg.effectiveApiKey,
        baseUrl: cfg.effectiveBaseUrl,
        model: cfg.effectiveModel,
        userMessage: text,
        history: history,
        systemPrompt: system.isEmpty ? null : system,
        attachments: attachments,
      );
    }

    if (!useBackend) {
      if (customModel != null) return direct();
      return api.sendMessage(
        agentId: agent.id,
        userMessage: text,
        history: history,
        agentName: agent.name,
        agentRole: agent.role,
        useBackendSystemPrompt: false,
        currentMindNodeId: mindNodeId,
        token: token,
        attachments: attachments,
      );
    }

    try {
      return await api.sendMessage(
        agentId: agent.id,
        userMessage: text,
        history: history,
        agentName: agent.name,
        agentRole: agent.role,
        useBackendSystemPrompt: true,
        currentMindNodeId: mindNodeId,
        token: token,
        modelApiKey: customModel?.effectiveApiKey,
        modelBaseUrl: customModel?.effectiveBaseUrl,
        modelId: customModel?.effectiveModel,
        attachments: attachments,
      );
    } catch (e) {
      if (customModel != null &&
          OpenAiCompatibleDirectApi.isBackendNetworkFailure(e)) {
        debugPrint('后端不可达，改用客户端直连模型: $e');
        return await direct();
      }
      rethrow;
    }
  }

  String _friendlyChatError(Object e) {
    if (OpenAiCompatibleDirectApi.isBackendNetworkFailure(e)) {
      return '请求失败：无法连接助理服务（${ApiConfig.assistantApiBaseUrl}）。'
          '请检查网络或服务端状态；若已在「设置 → 智能体配置」启用火山/OpenAI Key，'
          '将自动尝试直连模型。原始错误：$e';
    }
    return '请求失败：$e';
  }

  /// 将附件复制到账号目录，保证消息气泡可预览/打开（原选择路径可能被系统清理）。
  static Future<List<ChatMessageAttachment>> _persistMessageAttachments({
    required String agentId,
    required String messageId,
    required List<ChatAttachment> attachments,
  }) async {
    if (attachments.isEmpty) return const [];
    try {
      final root = await AccountStoragePaths.assistantDir();
      final dir = Directory('${root.path}/chat_files/$agentId/$messageId');
      if (!await dir.exists()) await dir.create(recursive: true);

      final out = <ChatMessageAttachment>[];
      for (var i = 0; i < attachments.length; i++) {
        final a = attachments[i];
        final safeName = _safeFileName(a.name, fallback: 'file_$i');
        String? savedPath;

        final srcPath = a.path?.trim();
        if (srcPath != null &&
            srcPath.isNotEmpty &&
            await File(srcPath).exists()) {
          final dest = File('${dir.path}/$safeName');
          try {
            await File(srcPath).copy(dest.path);
            savedPath = dest.path;
          } catch (_) {
            savedPath = srcPath;
          }
        } else if (a.bytes != null && a.bytes!.isNotEmpty) {
          final dest = File('${dir.path}/$safeName');
          try {
            await dest.writeAsBytes(a.bytes!, flush: true);
            savedPath = dest.path;
          } catch (_) {}
        }

        out.add(
          ChatMessageAttachment(
            id: a.id,
            name: a.name,
            mime: a.mime,
            kind: a.kind.name,
            path: savedPath,
          ),
        );
      }
      return out;
    } catch (e) {
      debugPrint('persist chat attachments failed: $e');
      return attachments
          .map(
            (a) => ChatMessageAttachment(
              id: a.id,
              name: a.name,
              mime: a.mime,
              kind: a.kind.name,
              path: a.path,
            ),
          )
          .toList();
    }
  }

  static String _safeFileName(String raw, {required String fallback}) {
    var name = raw.trim();
    if (name.isEmpty) name = fallback;
    name = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    if (name.length > 80) {
      final dot = name.lastIndexOf('.');
      if (dot > 0 && dot > name.length - 12) {
        final ext = name.substring(dot);
        name = '${name.substring(0, 80 - ext.length)}$ext';
      } else {
        name = name.substring(0, 80);
      }
    }
    return name;
  }
}

class _CancelSentinel {}
