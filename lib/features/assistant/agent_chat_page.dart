import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart' show OpenFilex, ResultType;
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

import '../../app/app_theme_extension.dart';
import '../../app/frosted_background.dart';
import '../../app/theme_notifier.dart';
import '../auth/services/auth_repository.dart';
import '../auth/services/user_sync_scheduler.dart';
import 'models/agent.dart';
import 'models/chat_attachment.dart';
import 'models/chat_message.dart';
import 'models/mind_topic_ref.dart';
import 'services/assistant_api.dart';
import 'services/assistant_repository.dart';
import 'services/asr_service.dart';
import 'services/asr_stream_service.dart';
import 'services/chat_attachment_picker.dart';
import 'services/chat_session_service.dart';

/// 单个智能体的文字对话页（一体式输入条 + 消息气泡）
/// 长按气泡：复制 / 删除本条 / 进入多选；多选模式下可批量删除
class AgentChatPage extends StatefulWidget {
  const AgentChatPage({
    super.key,
    required this.agent,
    required this.repository,
    required this.api,
    required this.onAgentUpdated,
    this.currentMindNodeId,
    this.mindProjectTitle,
    this.initialTopicRef,
  });

  final Agent agent;
  final AssistantRepository repository;
  final AssistantApi api;
  final VoidCallback onAgentUpdated;
  /// 当前思维节点（项目）id，从白板进入时传入，供工具调用使用
  final String? currentMindNodeId;
  /// 思维导图项目标题（与 [currentMindNodeId] 一起构成话题引用）
  final String? mindProjectTitle;
  /// 显式话题引用（优先于 currentMindNodeId + mindProjectTitle）
  final MindTopicRef? initialTopicRef;

  @override
  State<AgentChatPage> createState() => _AgentChatPageState();
}

class _AgentChatPageState extends State<AgentChatPage> with SingleTickerProviderStateMixin {
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final ChatSessionService _session = ChatSessionService.instance;
  final ChatAttachmentPicker _attachmentPicker = ChatAttachmentPicker();
  List<ChatMessage> _messages = [];
  bool _loading = false;
  int _queueDepth = 0;
  bool _selectionMode = false;
  final Set<String> _selectedIds = {};
  bool _voiceInputMode = false;
  bool _asrConfigured = false;
  bool _isRecording = false;
  bool _recordingStarted = false;
  bool _recordingCancel = false;
  DateTime? _recordingStartTime;
  final AsrService _asrService = AsrService();
  final AsrStreamService _asrStreamService = AsrStreamService();
  final AudioRecorder _audioRecorder = AudioRecorder();
  StreamSubscription<Uint8List>? _recordingStreamSub;
  StreamSubscription<Uint8List>? _armedMicSub;
  String _streamPreviewText = '';
  String? _lastAsrError;
  Timer? _recordingTimer;
  /// 上划取消：true 时松手不发送
  bool _holdToTalkWillCancel = false;
  /// 正在准备录音（浮层已显示，等待权限/启动）
  bool _holdToTalkPreparing = false;
  /// 当前环境不支持语音时仍显示浮层，松手时提示
  bool _holdToTalkUnsupported = false;
  /// 按住时的起始全局 Y（用于判断上划取消）
  double? _holdToTalkStartGlobalY;
  static const double _cancelZoneDy = 56.0;
  late AnimationController _waveController;

  // 语音模式预热：进入语音模式就提前打开麦克风流并缓冲少量音频，按下瞬间即可把句首送入 ASR
  bool _voiceArmed = false;
  final List<Uint8List> _micRingBuffer = <Uint8List>[];
  int _micRingBytes = 0;
  static const int _micRingMaxBytes = 96000; // ~3s @ 16kHz mono PCM16

  MindTopicRef? _topicRef;
  final List<ChatAttachment> _pendingAttachments = [];

  @override
  void initState() {
    super.initState();
    _topicRef = widget.initialTopicRef ??
        ((widget.currentMindNodeId != null &&
                widget.currentMindNodeId!.trim().isNotEmpty)
            ? MindTopicRef(
                projectId: widget.currentMindNodeId!.trim(),
                projectTitle: (widget.mindProjectTitle ?? '').trim(),
              )
            : null);
    UserSyncScheduler.syncEpoch.addListener(_onSyncEpoch);
    final agentId = widget.agent.id;
    _loading = _session.isLoading(agentId);
    _queueDepth = _session.queueDepth(agentId);
    _session.loadingOf(agentId).addListener(_onSessionChanged);
    _session.revisionOf(agentId).addListener(_onSessionChanged);
    _session.queueDepthOf(agentId).addListener(_onSessionChanged);
    _waveController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _loadMessages();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkAsrConfig();
      _preWarmAsrRecording();
    });
  }

  void _onSessionChanged() {
    if (!mounted) return;
    setState(() {
      _loading = _session.isLoading(widget.agent.id);
      _queueDepth = _session.queueDepth(widget.agent.id);
      _messages = widget.repository.getMessages(widget.agent.id).toList();
    });
    _scrollToEnd();
  }

  /// 与参考项目一致：首帧后探测录音能力，不主动弹系统权限框
  Future<void> _preWarmAsrRecording() async {
    try {
      await _audioRecorder.hasPermission();
    } catch (_) {}
  }

  /// 桌面端（Windows/macOS/Linux）：语音用点击开始/结束；移动端用长按说话
  bool get _isDesktop =>
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.linux;

  Future<void> _checkAsrConfig() async {
    final configured = await _asrService.isConfigured();
    if (mounted) setState(() => _asrConfigured = configured);
  }

  Future<void> _ensureAsrReadyOrHint() async {
    await _checkAsrConfig();
    if (_asrConfigured) return;
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('请先在「设置 → 智能体配置」填写并启用语音识别（ASR）'),
        duration: Duration(seconds: 3),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _loadMessages() async {
    // 1) 先立刻展示本地缓存，避免打开空白
    await widget.repository.loadMessages(widget.agent.id, force: true);
    if (mounted) {
      setState(() {
        _messages = widget.repository.getMessages(widget.agent.id).toList();
        _loading = _session.isLoading(widget.agent.id);
      });
      _scrollToEnd();
    }

    // 进行中的发送任务：勿用云端列表覆盖本地待回复消息
    if (_session.isLoading(widget.agent.id)) return;

    // 2) 登录态后台拉取云端，成功后再合并刷新（失败保留本地）
    final token = AuthRepository.instance.currentUser?.token;
    if (token == null || token.isEmpty) return;

    try {
      final convId = await widget.api.getOrCreateConversationId(
        agentId: widget.agent.id,
        title: widget.agent.name,
        token: token,
      );
      if (convId == null || convId.isEmpty) return;
      if (_session.isLoading(widget.agent.id)) return;
      final res = await widget.api.listConversationMessages(
        conversationId: convId,
        limit: 80,
        token: token,
      );
      if (res.messages.isEmpty) return;
      if (_session.isLoading(widget.agent.id)) return;

      final serverMsgs = <ChatMessage>[];
      for (final m in res.messages) {
        final role = m['role']?.toString() ?? 'user';
        final content = m['content']?.toString() ?? '';
        final sid = m['id']?.toString() ?? '';
        final ts = m['created_at'];
        DateTime? dt;
        if (ts is num) {
          dt = DateTime.fromMillisecondsSinceEpoch((ts * 1000).round());
        }
        if (content.trim().isEmpty) continue;
        serverMsgs.add(
          ChatMessage(
            role: role,
            content: content,
            timestamp: dt,
            id: sid.isNotEmpty ? 'srv_$sid' : null,
          ),
        );
      }
      if (serverMsgs.isEmpty) return;

      final local = widget.repository.getMessages(widget.agent.id);
      final localPending = local.where((m) => !m.id.startsWith('srv_')).toList();
      final byId = <String, ChatMessage>{};
      for (final m in serverMsgs) {
        byId[m.id] = m;
      }
      for (final m in localPending) {
        byId.putIfAbsent(m.id, () => m);
      }
      final merged = byId.values.toList()
        ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
      await widget.repository.replaceMessages(widget.agent.id, merged);
      if (mounted && !_session.isLoading(widget.agent.id)) {
        setState(() {
          _messages = widget.repository.getMessages(widget.agent.id).toList();
        });
        _scrollToEnd();
      }
    } catch (_) {
      // 后端不可达时保持本地已展示的记录
    }
  }

  void _onSyncEpoch() {
    // 方案 B：聊天历史以服务端为准；同步 epoch 触发时直接重新拉取会话消息并刷新 UI。
    unawaited(_loadMessages());
  }

  void _refreshMessages() {
    setState(() => _messages = widget.repository.getMessages(widget.agent.id).toList());
  }

  @override
  void dispose() {
    UserSyncScheduler.syncEpoch.removeListener(_onSyncEpoch);
    final agentId = widget.agent.id;
    _session.loadingOf(agentId).removeListener(_onSessionChanged);
    _session.revisionOf(agentId).removeListener(_onSessionChanged);
    _session.queueDepthOf(agentId).removeListener(_onSessionChanged);
    _recordingTimer?.cancel();
    _recordingStreamSub?.cancel();
    _armedMicSub?.cancel();
    // 仅清理 ASR；进行中的聊天请求由 ChatSessionService 托管，dispose 不 cancel
    unawaited(_asrStreamService.stopAndGetFinal(cancel: true));
    _waveController.dispose();
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _enqueueMicRing(Uint8List chunk) {
    while (_micRingBytes + chunk.length > _micRingMaxBytes && _micRingBuffer.isNotEmpty) {
      final removed = _micRingBuffer.removeAt(0);
      _micRingBytes -= removed.length;
    }
    if (_micRingBytes + chunk.length <= _micRingMaxBytes) {
      _micRingBuffer.add(chunk);
      _micRingBytes += chunk.length;
    }
  }

  void _flushMicRingToAsr() {
    if (_micRingBuffer.isEmpty) return;
    for (final c in _micRingBuffer) {
      _asrStreamService.sendAudio(c);
    }
    _micRingBuffer.clear();
    _micRingBytes = 0;
  }

  Future<void> _armVoiceInputIfNeeded() async {
    // 常驻策略：只要切到语音模式就预热麦克风（环形缓冲），并在 ASR 可用时预连 WS。
    if (_voiceArmed || !_voiceInputMode) return;
    _voiceArmed = true;
    _micRingBuffer.clear();
    _micRingBytes = 0;
    // 1) 预热 ASR WS：连接与 ready 等待可能要几百毫秒，提前做掉（未配置则跳过）
    if (_asrConfigured) {
      unawaited(_asrStreamService.start(onPartial: (text) {
        if (!mounted) return;
        if (_isRecording) setState(() => _streamPreviewText = text);
      }));
    }
    // 2) 预热麦克风：进入语音模式即开流并缓冲，按下瞬间 flush 到 ASR
    try {
      if (!_isDesktop) {
        if (await _audioRecorder.hasPermission() != true) {
          // 不在预热阶段弹权限框；按下再请求
          _voiceArmed = false;
          return;
        }
      }
      final stream = await _audioRecorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
        ),
      );
      await _armedMicSub?.cancel();
      _armedMicSub = stream.listen((chunk) {
        if (_isRecording) {
          _asrStreamService.sendAudio(chunk);
        } else {
          _enqueueMicRing(chunk);
        }
      });
    } catch (_) {
      _voiceArmed = false;
    }
  }

  Future<void> _disarmVoiceInput() async {
    _voiceArmed = false;
    _micRingBuffer.clear();
    _micRingBytes = 0;
    await _armedMicSub?.cancel();
    _armedMicSub = null;
    try {
      await _audioRecorder.stop();
    } catch (_) {}
    try {
      await _asrStreamService.stopAndGetFinal(cancel: true);
    } catch (_) {}
  }

  Future<void> _toggleVoiceMode() async {
    final next = !_voiceInputMode;
    if (next) {
      await _ensureAsrReadyOrHint();
      if (!_asrConfigured) return;
    }
    setState(() => _voiceInputMode = next);
    if (next) {
      await _armVoiceInputIfNeeded();
    } else {
      await _disarmVoiceInput();
    }
  }

  void _exitSelectionMode() {
    setState(() {
      _selectionMode = false;
      _selectedIds.clear();
    });
  }

  void _toggleSelect(String id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
      } else {
        _selectedIds.add(id);
      }
    });
  }

  Future<void> _copyText(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已复制到剪贴板'), duration: Duration(seconds: 2)),
      );
    }
  }

  Future<void> _confirmDeleteSingle(ChatMessage msg) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(ctx).colorScheme.surfaceContainerHigh,
        surfaceTintColor: Colors.transparent,
        title: const Text('删除消息'),
        content: const Text('确定删除这条对话？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      widget.repository.removeMessageById(widget.agent.id, msg.id);
      _refreshMessages();
    }
  }

  Future<void> _deleteSelected() async {
    if (_selectedIds.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(ctx).colorScheme.surfaceContainerHigh,
        surfaceTintColor: Colors.transparent,
        title: const Text('删除选中消息'),
        content: Text('确定删除已选的 ${_selectedIds.length} 条对话？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      widget.repository.removeMessagesByIds(widget.agent.id, Set<String>.from(_selectedIds));
      _exitSelectionMode();
      _refreshMessages();
    }
  }

  void _showMessageActions(ChatMessage msg) {
    final colorScheme = Theme.of(context).colorScheme;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: colorScheme.surfaceContainerHigh,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.copy_rounded),
              title: const Text('复制文字'),
              onTap: () {
                Navigator.pop(ctx);
                _copyText(msg.content);
              },
            ),
            ListTile(
              leading: const Icon(Icons.checklist_rounded),
              title: const Text('多选'),
              subtitle: const Text('选择多条后批量删除'),
              onTap: () {
                Navigator.pop(ctx);
                setState(() {
                  _selectionMode = true;
                  _selectedIds.add(msg.id);
                });
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline_rounded, color: colorScheme.error),
              title: Text('删除本条', style: TextStyle(color: colorScheme.error)),
              onTap: () {
                Navigator.pop(ctx);
                _confirmDeleteSingle(msg);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _send() async {
    final text = _inputController.text.trim();
    final atts = List<ChatAttachment>.from(_pendingAttachments);
    _inputController.clear();
    setState(() => _pendingAttachments.clear());
    await _sendText(text, attachments: atts);
  }

  Future<void> _sendText(
    String rawText, {
    List<ChatAttachment> attachments = const [],
  }) async {
    final text = rawText.trim();
    if (text.isEmpty && attachments.isEmpty) return;

    // 思考中也可入队；Session 按时间顺序处理
    await _session.send(
      agent: widget.agent,
      repository: widget.repository,
      api: widget.api,
      userText: text,
      topicRef: _topicRef,
      attachments: attachments,
    );
  }

  void _interruptThinking() {
    final ok = _session.cancelCurrent(widget.agent.id);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('当前没有可打断的请求'),
          duration: Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _showAttachMenu() async {
    final colorScheme = Theme.of(context).colorScheme;
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: colorScheme.surfaceContainerHigh,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('相册'),
              onTap: () => Navigator.pop(ctx, 'gallery'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: Text(_isDesktop ? '选择图片' : '拍照'),
              onTap: () => Navigator.pop(ctx, 'camera'),
            ),
            ListTile(
              leading: const Icon(Icons.videocam_outlined),
              title: Text(_isDesktop ? '选择视频' : '拍视频'),
              onTap: () => Navigator.pop(ctx, 'video'),
            ),
            ListTile(
              leading: const Icon(Icons.attach_file_rounded),
              title: const Text('文件'),
              subtitle: const Text('PDF / Markdown / Word / Excel / 图片等'),
              onTap: () => Navigator.pop(ctx, 'file'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    try {
      List<ChatAttachment> picked = [];
      switch (choice) {
        case 'gallery':
          picked = await _attachmentPicker.pickFromGallery();
          break;
        case 'camera':
          final one = await _attachmentPicker.takePhoto();
          if (one != null) picked = [one];
          break;
        case 'video':
          final one = await _attachmentPicker.takeVideo();
          if (one != null) picked = [one];
          break;
        case 'file':
          picked = await _attachmentPicker.pickDocuments();
          break;
      }
      if (!mounted || picked.isEmpty) return;
      setState(() {
        for (final a in picked) {
          if (a.kind == ChatAttachmentKind.unsupported) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('${a.name}：${a.previewHint ?? '不支持'}'),
                behavior: SnackBarBehavior.floating,
              ),
            );
            continue;
          }
          if (_pendingAttachments.length >= ChatAttachmentPicker.maxAttachments) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('最多添加 6 个附件'),
                behavior: SnackBarBehavior.floating,
              ),
            );
            break;
          }
          _pendingAttachments.add(a);
        }
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('选择附件失败: $e'), behavior: SnackBarBehavior.floating),
        );
      }
    }
  }

  void _removeAttachment(String id) {
    setState(() => _pendingAttachments.removeWhere((a) => a.id == id));
  }

  void _clearTopicRef() {
    setState(() => _topicRef = null);
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  static const double _cancelSlideThreshold = 50;

  void _onHoldToTalkPanStart(DragStartDetails details) {
    if (_loading) return;
    if (!_asrConfigured) {
      unawaited(_ensureAsrReadyOrHint());
      return;
    }
    _holdToTalkStartGlobalY = details.globalPosition.dy;
    _holdToTalkUnsupported = false;
    setState(() {
      _isRecording = true;
      _recordingStarted = false;
      _recordingCancel = false;
      _holdToTalkPreparing = true;
      _streamPreviewText = '';
    });
    // 立即开始：不再延迟 60ms；麦克风与 ASR WebSocket 并行，句首音频在 ready 前由 AsrStreamService 缓冲。
    unawaited(() async {
      bool ok = false;
      if (_isDesktop) {
        ok = true;
      } else if (await _audioRecorder.hasPermission() != true) {
        final status = await Permission.microphone.request();
        ok = status.isGranted;
      } else {
        ok = true;
      }
      if (!mounted) return;
      if (!ok) {
        setState(() {
          _holdToTalkPreparing = false;
          _holdToTalkUnsupported = true;
        });
        return;
      }
      await _startRecording();
      if (mounted) setState(() => _holdToTalkPreparing = false);
    }());
  }

  // Pointer 版：按下即开始（不等 pan 手势识别），提升语音转文字起步速度与“句首不丢”体验
  void _onHoldToTalkPointerDown(PointerDownEvent event) {
    if (_loading) return;
    if (!_asrConfigured) {
      unawaited(_ensureAsrReadyOrHint());
      return;
    }
    _holdToTalkStartGlobalY = event.position.dy;
    _holdToTalkUnsupported = false;
    setState(() {
      _isRecording = true;
      _recordingStarted = false;
      _recordingCancel = false;
      _holdToTalkPreparing = true;
      _streamPreviewText = '';
    });
    unawaited(() async {
      bool ok = false;
      if (_isDesktop) {
        ok = true;
      } else if (await _audioRecorder.hasPermission() != true) {
        final status = await Permission.microphone.request();
        ok = status.isGranted;
      } else {
        ok = true;
      }
      if (!mounted) return;
      if (!ok) {
        setState(() {
          _holdToTalkPreparing = false;
          _holdToTalkUnsupported = true;
        });
        return;
      }
      // 若已预热麦克风/WS：按下即 flush 环形缓冲（覆盖句首），无需再 startStream
      if (_voiceArmed && _armedMicSub != null) {
        await _asrStreamService.start(onPartial: (text) {
          if (!mounted) return;
          if (_isRecording) setState(() => _streamPreviewText = text);
        });
        _flushMicRingToAsr();
        if (mounted) {
          setState(() {
            _recordingStarted = true;
            _recordingStartTime = DateTime.now();
          });
        }
      } else {
        await _startRecording();
      }
      if (mounted) setState(() => _holdToTalkPreparing = false);
    }());
  }

  void _onHoldToTalkPointerMove(PointerMoveEvent event) {
    if (!_isRecording || _holdToTalkStartGlobalY == null) return;
    final globalY = event.position.dy;
    final startY = _holdToTalkStartGlobalY!;
    final willCancel = globalY < startY - _cancelZoneDy;
    if (willCancel != _holdToTalkWillCancel) {
      setState(() => _holdToTalkWillCancel = willCancel);
    }
  }

  void _onHoldToTalkPointerUp(PointerUpEvent event) async {
    if (!_isRecording) return;
    final wasUnsupported = _holdToTalkUnsupported;
    final willCancel = _holdToTalkWillCancel;
    setState(() {
      _isRecording = false;
      _holdToTalkWillCancel = false;
    });
    if (wasUnsupported) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('请检查麦克风权限后重试'),
            behavior: SnackBarBehavior.floating,
            duration: Duration(seconds: 3),
          ),
        );
      }
      setState(() => _holdToTalkPreparing = false);
      return;
    }
    await _finishHoldToTalk(cancel: willCancel);
  }

  void _onHoldToTalkPointerCancel(PointerCancelEvent event) {
    if (_isRecording) {
      _finishHoldToTalk(cancel: true);
      setState(() {
        _isRecording = false;
        _holdToTalkWillCancel = false;
        _holdToTalkUnsupported = false;
        _holdToTalkPreparing = false;
      });
    }
  }

  void _onHoldToTalkPanUpdate(DragUpdateDetails details) {
    if (!_isRecording || _holdToTalkStartGlobalY == null) return;
    final globalY = details.globalPosition.dy;
    final startY = _holdToTalkStartGlobalY!;
    final willCancel = globalY < startY - _cancelZoneDy;
    if (willCancel != _holdToTalkWillCancel) {
      setState(() => _holdToTalkWillCancel = willCancel);
    }
  }

  void _onHoldToTalkPanEnd(DragEndDetails details) async {
    if (!_isRecording) return;
    final wasUnsupported = _holdToTalkUnsupported;
    final willCancel = _holdToTalkWillCancel;
    setState(() {
      _isRecording = false;
      _holdToTalkWillCancel = false;
    });
    if (wasUnsupported) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('请检查麦克风权限后重试'),
            behavior: SnackBarBehavior.floating,
            duration: Duration(seconds: 3),
          ),
        );
      }
      setState(() => _holdToTalkPreparing = false);
      return;
    }
    await _finishHoldToTalk(cancel: willCancel);
  }

  void _onHoldToTalkPanCancel() {
    if (_isRecording) {
      _finishHoldToTalk(cancel: true);
      setState(() {
        _isRecording = false;
        _holdToTalkWillCancel = false;
        _holdToTalkUnsupported = false;
        _holdToTalkPreparing = false;
      });
    }
  }

  /// 松手后：结束录音，若未取消则识别并发送
  Future<void> _finishHoldToTalk({required bool cancel}) async {
    final started = _recordingStarted;
    final startedAt = _recordingStartTime;
    _recordingTimer?.cancel();
    _recordingTimer = null;
    setState(() {
      _recordingStarted = false;
      _recordingStartTime = null;
    });
    // 语音模式预热线程：麦克风流常驻（_armedMicSub），仅结束本次 ASR；若此处 stop 麦克风，第二次按住无音频 →「流式识别未返回文本」
    await _recordingStreamSub?.cancel();
    _recordingStreamSub = null;
    final keepArmedMicRunning = _voiceArmed && _armedMicSub != null;
    if (!keepArmedMicRunning) {
      try {
        await _audioRecorder.stop();
      } catch (_) {}
    }
    try {
      if (cancel) {
        await _asrStreamService.stopAndGetFinal(cancel: true);
        return;
      }
      if (!started) {
        await _asrStreamService.stopAndGetFinal(cancel: true);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('录音太短，请重试')),
          );
        }
        return;
      }
      try {
        if (startedAt != null) {
          final heldMs = DateTime.now().difference(startedAt).inMilliseconds;
          if (heldMs < 350) {
            await _asrStreamService.stopAndGetFinal(cancel: true);
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('录音太短，请重试')),
              );
            }
            return;
          }
        }
        final text = await _asrStreamService.stopAndGetFinal(cancel: false);
        debugPrint(
          '[ASR-UI] holdToTalk done len=${text.trim().length} err=${_asrStreamService.lastError ?? ''}',
        );
        if (text.isEmpty) {
          _lastAsrError = _asrStreamService.lastError ?? '流式识别未返回文本';
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(_lastAsrError ?? '未识别到文字，请重试')),
            );
          }
          return;
        }
        if (!mounted) return;
      await _sendText(text);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('语音识别失败: $e')),
          );
        }
      }
    } finally {
      if (mounted) setState(() => _streamPreviewText = '');
    }
  }

  void _onVoiceLongPressStart() {
    if (_loading) return;
    if (!_asrConfigured) {
      unawaited(_ensureAsrReadyOrHint());
      return;
    }
    setState(() {
      _isRecording = true;
      _recordingStarted = false;
      _recordingCancel = false;
      _recordingStartTime = DateTime.now();
      _streamPreviewText = '';
    });
    _recordingTimer?.cancel();
    _recordingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _isRecording) setState(() {});
    });
    _startRecording();
  }

  void _onVoiceLongPressMove(LongPressMoveUpdateDetails details) {
    if (!_isRecording) return;
    if (details.localPosition.dy < -_cancelSlideThreshold) {
      setState(() => _recordingCancel = true);
    } else {
      setState(() => _recordingCancel = false);
    }
  }

  Future<void> _startRecording() async {
    if (!_isDesktop) {
      if (await _audioRecorder.hasPermission() != true) {
        final status = await Permission.microphone.request();
        if (!status.isGranted && mounted) {
          setState(() => _isRecording = false);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('需要麦克风权限才能语音输入')),
          );
          return;
        }
      }
    } else {
      try {
        await _audioRecorder.hasPermission();
      } catch (_) {}
    }
    try {
      _lastAsrError = null;
      // WebSocket 建链与麦克风并行：避免「先等 ready 再开麦」丢掉句首；ready 前音频由 AsrStreamService 缓冲。
      final results = await Future.wait<Object?>([
        _audioRecorder.startStream(
          const RecordConfig(
            encoder: AudioEncoder.pcm16bits,
            sampleRate: 16000,
            numChannels: 1,
          ),
        ),
        _asrStreamService.start(
          onPartial: (text) {
            if (!mounted) return;
            setState(() => _streamPreviewText = text);
          },
        ),
      ]);
      final stream = results[0]! as Stream<Uint8List>;
      final streamOk = results[1]! as bool;
      if (!streamOk) {
        _lastAsrError = _asrStreamService.lastError ?? 'ASR 流式通道建立失败';
        try {
          await _audioRecorder.stop();
        } catch (_) {}
        if (mounted) {
          setState(() {
            _isRecording = false;
            _recordingStarted = false;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(_lastAsrError!)),
          );
        }
        return;
      }
      _recordingStreamSub = stream.listen((chunk) {
        _asrStreamService.sendAudio(chunk);
      });
      if (mounted) {
        setState(() {
          _recordingStarted = true;
          _recordingStartTime = DateTime.now();
        });
      } else {
        _recordingStarted = true;
      }
    } catch (e) {
      try {
        await _audioRecorder.stop();
      } catch (_) {}
      if (mounted) {
        setState(() {
          _isRecording = false;
          _recordingStarted = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('录音失败: $e')),
        );
      }
      try {
        await _asrStreamService.stopAndGetFinal(cancel: true);
      } catch (_) {}
    }
  }

  Future<void> _onVoiceLongPressEnd() async {
    if (!_isRecording) return;
    final cancel = _recordingCancel;
    setState(() => _isRecording = false);
    await _finishHoldToTalk(cancel: cancel);
  }

  /// 录音浮层：底部大半圆毛玻璃 + 松手发送/上划取消文案 + 竖条波形
  Widget _buildRecordingOverlay() {
    final theme = Theme.of(context);
    final look = _AsrOverlayLook.resolve(context);
    final bottomPadding = MediaQuery.of(context).padding.bottom;
    final screenWidth = MediaQuery.of(context).size.width;
    const overlayHeight = 236.0;
    final arcRise = (screenWidth * 0.18).clamp(56.0, 120.0).toDouble();
    return Positioned.fill(
      child: IgnorePointer(
        child: Stack(
          children: [
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      look.topShadeA,
                      look.topShadeB,
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: overlayHeight + bottomPadding,
              child: ClipPath(
                clipper: _FrostedSemiCircleClipper(
                  arcRise: arcRise,
                  arcStartY: 62.0,
                ),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                  child: Stack(
                    children: [
                      Container(
                        width: double.infinity,
                        height: overlayHeight + bottomPadding,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: look.panelGradient,
                            stops: look.panelStops,
                          ),
                        ),
                      ),
                      Positioned.fill(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: RadialGradient(
                              center: const Alignment(0, -0.25),
                              radius: 0.95,
                              colors: [
                                look.panelSheen,
                                Colors.transparent,
                              ],
                              stops: const [0.0, 1.0],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            SafeArea(
              top: false,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  const Spacer(),
                  Builder(
                    builder: (context) {
                      final mainLine = _holdToTalkPreparing
                          ? '准备中...'
                          : _holdToTalkUnsupported
                              ? '当前环境暂不支持语音，松手查看说明'
                              : _holdToTalkWillCancel
                                  ? '松开取消'
                                  : (_streamPreviewText.trim().isNotEmpty
                                      ? _streamPreviewText.trim()
                                      : '正在实时识别，请继续说话…');
                      final showLive =
                          !_holdToTalkPreparing && !_holdToTalkUnsupported && !_holdToTalkWillCancel;
                      final preview = _streamPreviewText.trim();
                      final useScroll = showLive && preview.isNotEmpty;
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (useScroll)
                              ConstrainedBox(
                                constraints: const BoxConstraints(maxHeight: 120),
                                child: SingleChildScrollView(
                                  child: SelectableText(
                                    preview,
                                    textAlign: TextAlign.center,
                                    style: theme.textTheme.bodyLarge?.copyWith(
                                      color: look.mainText,
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                      height: 1.35,
                                      shadows: look.mainTextShadows,
                                    ),
                                  ),
                                ),
                              )
                            else
                              Text(
                                mainLine,
                                textAlign: TextAlign.center,
                                maxLines: 4,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodyLarge?.copyWith(
                                  color: look.mainText,
                                  fontWeight: FontWeight.w600,
                                  height: 1.35,
                                  shadows: look.mainTextShadows,
                                ),
                              ),
                            if (showLive) ...[
                              const SizedBox(height: 8),
                              Text(
                                '松开发送 · 上划取消',
                                textAlign: TextAlign.center,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: look.subText,
                                  fontWeight: FontWeight.w500,
                                  shadows: look.subtleTextShadows,
                                ),
                              ),
                            ],
                          ],
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 20),
                  Center(
                    child: AnimatedBuilder(
                      animation: _waveController,
                      builder: (context, _) {
                        return CustomPaint(
                          size: Size(
                            MediaQuery.of(context).size.width * 0.85,
                            48,
                          ),
                          painter: _RecordingWavePainter(
                            phase: _waveController.value * math.pi * 2,
                            accentColor: look.waveAccent,
                          ),
                        );
                      },
                    ),
                  ),
                  SizedBox(height: bottomPadding + 32),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Theme.of(context).appBarTheme.backgroundColor,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: _selectionMode
            ? IconButton(
                icon: const Icon(Icons.close),
                onPressed: _exitSelectionMode,
                tooltip: '取消',
              )
            : null,
        automaticallyImplyLeading: !_selectionMode,
        title: _selectionMode
            ? Text('已选 ${_selectedIds.length} 条')
            : Text(widget.agent.name),
        actions: _selectionMode
            ? [
                TextButton(
                  onPressed: _selectedIds.isEmpty ? null : _deleteSelected,
                  child: Text(
                    '删除',
                    style: TextStyle(
                      color: _selectedIds.isEmpty ? colorScheme.onSurfaceVariant : colorScheme.error,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ),
              ]
            : null,
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          const FrostedBackground(),
          Column(
            children: [
              SizedBox(height: MediaQuery.of(context).padding.top + kToolbarHeight),
              Expanded(
                child: ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  itemCount: _messages.length + (_loading ? 1 : 0),
                  itemBuilder: (context, index) {
                    if (index == _messages.length) {
                      final queueHint =
                          _queueDepth > 0 ? ' · 排队 $_queueDepth 条' : '';
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Row(
                          children: [
                            CircleAvatar(
                              radius: 16,
                              backgroundColor: colorScheme.primaryContainer,
                              child: SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: colorScheme.onPrimaryContainer,
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                '正在思考…$queueHint',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                            TextButton.icon(
                              onPressed: _interruptThinking,
                              icon: Icon(
                                Icons.stop_circle_outlined,
                                size: 18,
                                color: colorScheme.error,
                              ),
                              label: Text(
                                '打断',
                                style: TextStyle(
                                  color: colorScheme.error,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              style: TextButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    }
                    final msg = _messages[index];
                    final selected = _selectedIds.contains(msg.id);
                    return _MessageBubble(
                      message: msg,
                      selectionMode: _selectionMode,
                      selected: selected,
                      onLongPress: () => _showMessageActions(msg),
                      onTap: _selectionMode ? () => _toggleSelect(msg.id) : null,
                    );
                  },
                ),
              ),
              if (!_selectionMode) ...[
                if (_topicRef != null || _pendingAttachments.isNotEmpty)
                  _ComposerContextStrip(
                    topicRef: _topicRef,
                    attachments: _pendingAttachments,
                    onClearTopic: _clearTopicRef,
                    onRemoveAttachment: _removeAttachment,
                  ),
                _ChatInputBar(
                  inputController: _inputController,
                  loading: _loading,
                  hasPendingAttachments: _pendingAttachments.isNotEmpty,
                  onSend: _send,
                  onAttach: _showAttachMenu,
                  voiceInputMode: _voiceInputMode,
                  asrConfigured: _asrConfigured,
                  isDesktop: _isDesktop,
                  isRecording: _isRecording,
                  onToggleVoice: _toggleVoiceMode,
                  onVoiceLongPressStart: _onVoiceLongPressStart,
                  onVoiceLongPressMove: _onVoiceLongPressMove,
                  onVoiceLongPressEnd: _onVoiceLongPressEnd,
                  onHoldToTalkPanStart: _onHoldToTalkPanStart,
                  onHoldToTalkPanUpdate: _onHoldToTalkPanUpdate,
                  onHoldToTalkPanEnd: _onHoldToTalkPanEnd,
                  onHoldToTalkPanCancel: _onHoldToTalkPanCancel,
                  onHoldToTalkPointerDown: _onHoldToTalkPointerDown,
                  onHoldToTalkPointerMove: _onHoldToTalkPointerMove,
                  onHoldToTalkPointerUp: _onHoldToTalkPointerUp,
                  onHoldToTalkPointerCancel: _onHoldToTalkPointerCancel,
                ),
              ],
            ],
          ),
          if (_isRecording) _buildRecordingOverlay(),
        ],
      ),
    );
  }
}

class _ComposerContextStrip extends StatelessWidget {
  const _ComposerContextStrip({
    required this.topicRef,
    required this.attachments,
    required this.onClearTopic,
    required this.onRemoveAttachment,
  });

  final MindTopicRef? topicRef;
  final List<ChatAttachment> attachments;
  final VoidCallback onClearTopic;
  final void Function(String id) onRemoveAttachment;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (topicRef != null)
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
              decoration: BoxDecoration(
                color: cs.primary.withOpacity(0.08),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: cs.outline.withOpacity(0.14)),
              ),
              child: Row(
                children: [
                  Icon(Icons.account_tree_outlined, size: 16, color: cs.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '话题引用 · ${topicRef!.displayLabel}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: cs.onSurface,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: onClearTopic,
                    tooltip: '关闭引用',
                    icon: Icon(
                      Icons.close_rounded,
                      size: 16,
                      color: cs.onSurfaceVariant,
                    ),
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  ),
                ],
              ),
            ),
          if (attachments.isNotEmpty)
            SizedBox(
              height: 64,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: attachments.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (context, i) {
                  final a = attachments[i];
                  return _AttachmentChip(
                    attachment: a,
                    onRemove: () => onRemoveAttachment(a.id),
                    onOpen: () => _openLocalPath(
                      context,
                      a.path,
                      fallbackBytes: a.bytes,
                      mime: a.mime,
                      name: a.name,
                      isImage: a.isImage,
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _AttachmentChip extends StatelessWidget {
  const _AttachmentChip({
    required this.attachment,
    required this.onRemove,
    this.onOpen,
  });

  final ChatAttachment attachment;
  final VoidCallback onRemove;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    Widget thumb;
    if (attachment.isImage &&
        (attachment.bytes != null ||
            (attachment.path != null && File(attachment.path!).existsSync()))) {
      final bytes = attachment.bytes;
      thumb = ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: bytes != null
            ? Image.memory(bytes, width: 48, height: 48, fit: BoxFit.cover)
            : Image.file(
                File(attachment.path!),
                width: 48,
                height: 48,
                fit: BoxFit.cover,
              ),
      );
    } else {
      IconData icon = Icons.insert_drive_file_outlined;
      if (attachment.isVideo) icon = Icons.videocam_outlined;
      if (attachment.kind == ChatAttachmentKind.textDoc ||
          attachment.kind == ChatAttachmentKind.binaryDoc) {
        icon = Icons.description_outlined;
      }
      thumb = Container(
        width: 48,
        height: 48,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: cs.onSurface.withOpacity(0.06),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, size: 20, color: cs.onSurfaceVariant),
      );
    }
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onOpen,
            borderRadius: BorderRadius.circular(12),
            child: Container(
              width: 132,
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: cs.onSurface.withOpacity(0.05),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: cs.outline.withOpacity(0.14)),
              ),
              child: Row(
                children: [
                  thumb,
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          attachment.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelMedium,
                        ),
                        Text(
                          attachment.previewHint ?? '点击打开',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        Positioned(
          right: -4,
          top: -4,
          child: Material(
            color: cs.errorContainer,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onRemove,
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: Icon(Icons.close, size: 14, color: cs.onErrorContainer),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

Future<void> _openLocalPath(
  BuildContext context,
  String? path, {
  Uint8List? fallbackBytes,
  String? mime,
  String? name,
  bool isImage = false,
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final p = path?.trim() ?? '';
  if (p.isNotEmpty && await File(p).exists()) {
    final result = await OpenFilex.open(p);
    if (result.type == ResultType.done) return;
    if (isImage && context.mounted) {
      await _showImagePreviewDialog(
        context,
        path: p,
        bytes: fallbackBytes,
        title: name ?? '图片',
      );
      return;
    }
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          result.message.isNotEmpty ? result.message : '无法打开该文件',
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
    return;
  }
  if (isImage && fallbackBytes != null && fallbackBytes.isNotEmpty && context.mounted) {
    await _showImagePreviewDialog(
      context,
      bytes: fallbackBytes,
      title: name ?? '图片',
    );
    return;
  }
  messenger?.showSnackBar(
    const SnackBar(
      content: Text('文件已不可用（可能已被清理）'),
      behavior: SnackBarBehavior.floating,
    ),
  );
}

Future<void> _showImagePreviewDialog(
  BuildContext context, {
  String? path,
  Uint8List? bytes,
  required String title,
}) async {
  await showDialog<void>(
    context: context,
    builder: (ctx) {
      Widget image;
      if (bytes != null) {
        image = InteractiveViewer(child: Image.memory(bytes));
      } else if (path != null && File(path).existsSync()) {
        image = InteractiveViewer(child: Image.file(File(path)));
      } else {
        image = const Center(child: Text('无法预览'));
      }
      return Dialog(
        insetPadding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(ctx).textTheme.titleSmall,
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(ctx),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(ctx).size.height * 0.7,
                maxWidth: MediaQuery.of(ctx).size.width,
              ),
              child: image,
            ),
            const SizedBox(height: 12),
          ],
        ),
      );
    },
  );
}

class _ChatInputBar extends StatelessWidget {
  const _ChatInputBar({
    required this.inputController,
    required this.loading,
    required this.hasPendingAttachments,
    required this.onSend,
    this.onAttach,
    required this.voiceInputMode,
    required this.asrConfigured,
    required this.isDesktop,
    required this.isRecording,
    required this.onToggleVoice,
    required this.onVoiceLongPressStart,
    required this.onVoiceLongPressMove,
    required this.onVoiceLongPressEnd,
    this.onHoldToTalkPanStart,
    this.onHoldToTalkPanUpdate,
    this.onHoldToTalkPanEnd,
    this.onHoldToTalkPanCancel,
    this.onHoldToTalkPointerDown,
    this.onHoldToTalkPointerMove,
    this.onHoldToTalkPointerUp,
    this.onHoldToTalkPointerCancel,
  });

  final TextEditingController inputController;
  final bool loading;
  final bool hasPendingAttachments;
  final VoidCallback onSend;
  final VoidCallback? onAttach;
  final bool voiceInputMode;
  final bool asrConfigured;
  final bool isDesktop;
  final bool isRecording;
  final VoidCallback onToggleVoice;
  final VoidCallback onVoiceLongPressStart;
  final void Function(LongPressMoveUpdateDetails) onVoiceLongPressMove;
  final VoidCallback onVoiceLongPressEnd;
  final void Function(DragStartDetails)? onHoldToTalkPanStart;
  final void Function(DragUpdateDetails)? onHoldToTalkPanUpdate;
  final void Function(DragEndDetails)? onHoldToTalkPanEnd;
  final VoidCallback? onHoldToTalkPanCancel;
  final void Function(PointerDownEvent)? onHoldToTalkPointerDown;
  final void Function(PointerMoveEvent)? onHoldToTalkPointerMove;
  final void Function(PointerUpEvent)? onHoldToTalkPointerUp;
  final void Function(PointerCancelEvent)? onHoldToTalkPointerCancel;

  static const double _shellRadius = 22;
  static const double _actionSize = 38;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final ext = theme.extension<HibiThemeExtension>();
    final astral = ext?.themeId == AppThemeId.astralPhantasm;
    final isDark = theme.brightness == Brightness.dark;
    final shellFill = isDark
        ? Color.alphaBlend(
            Colors.white.withOpacity(0.10),
            colorScheme.surfaceContainerHighest,
          )
        : Color.alphaBlend(
            Colors.white.withOpacity(0.92),
            colorScheme.surface,
          );

    return Material(
      color: colorScheme.surface.withOpacity(isDark ? 0.92 : 0.96),
      elevation: 0,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: colorScheme.outline.withOpacity(0.28)),
          ),
        ),
        child: SafeArea(
          top: false,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: shellFill,
              borderRadius: BorderRadius.circular(astral ? 24 : _shellRadius),
              border: Border.all(
                color: isRecording
                    ? colorScheme.primary.withOpacity(0.7)
                    : colorScheme.outline.withOpacity(isDark ? 0.45 : 0.35),
                width: isRecording ? 1.4 : 1.1,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(isDark ? 0.28 : 0.06),
                  blurRadius: 16,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(6, 5, 6, 5),
              child: voiceInputMode
                  ? _buildVoiceInput(context, theme, colorScheme)
                  : _buildTextInput(context, theme, colorScheme),
            ),
          ),
        ),
      ),
    );
  }

  Widget _ghostIcon({
    required IconData icon,
    required String tooltip,
    VoidCallback? onPressed,
    required ColorScheme colorScheme,
  }) {
    final enabled = onPressed != null;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: colorScheme.onSurface.withOpacity(enabled ? 0.08 : 0.04),
        shape: const CircleBorder(),
        child: InkWell(
          onTap: onPressed,
          customBorder: const CircleBorder(),
          child: SizedBox(
            width: _actionSize,
            height: _actionSize,
            child: Icon(
              icon,
              size: 22,
              color: colorScheme.onSurface.withOpacity(enabled ? 0.92 : 0.35),
            ),
          ),
        ),
      ),
    );
  }

  Widget _primaryAction({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
    required ColorScheme colorScheme,
    required bool emphasized,
  }) {
    final enabled = onPressed != null;
    final bg = emphasized && enabled
        ? colorScheme.primary
        : colorScheme.onSurface.withOpacity(enabled ? 0.12 : 0.06);
    final fg = emphasized && enabled
        ? colorScheme.onPrimary
        : colorScheme.onSurface.withOpacity(enabled ? 0.9 : 0.38);
    return Tooltip(
      message: tooltip,
      child: Material(
        color: bg,
        shape: const CircleBorder(),
        child: InkWell(
          onTap: onPressed,
          customBorder: const CircleBorder(),
          child: SizedBox(
            width: _actionSize,
            height: _actionSize,
            child: Icon(icon, size: 20, color: fg),
          ),
        ),
      ),
    );
  }

  Widget _buildVoiceInput(
    BuildContext context,
    ThemeData theme,
    ColorScheme colorScheme,
  ) {
    final usePointer = onHoldToTalkPointerDown != null &&
        onHoldToTalkPointerMove != null &&
        onHoldToTalkPointerUp != null &&
        onHoldToTalkPointerCancel != null;
    final holdChild = Container(
      height: 44,
      alignment: Alignment.center,
      child: AnimatedDefaultTextStyle(
        duration: const Duration(milliseconds: 160),
        style: (theme.textTheme.bodyMedium ?? const TextStyle()).copyWith(
          color: isRecording ? colorScheme.primary : colorScheme.onSurfaceVariant,
          fontWeight: isRecording ? FontWeight.w600 : FontWeight.w500,
          letterSpacing: 0.2,
        ),
        child: Text(isRecording ? '松开发送 · 上滑取消' : '按住 说话'),
      ),
    );

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _ghostIcon(
          icon: Icons.keyboard_rounded,
          tooltip: '切换到键盘输入',
          onPressed: onToggleVoice,
          colorScheme: colorScheme,
        ),
        Expanded(
          child: usePointer
              ? Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: onHoldToTalkPointerDown,
                  onPointerMove: onHoldToTalkPointerMove,
                  onPointerUp: onHoldToTalkPointerUp,
                  onPointerCancel: onHoldToTalkPointerCancel,
                  child: holdChild,
                )
              : GestureDetector(
                  onLongPressStart: (_) => onVoiceLongPressStart(),
                  onLongPressMoveUpdate: (details) =>
                      onVoiceLongPressMove(details),
                  onLongPressEnd: (_) => onVoiceLongPressEnd(),
                  child: holdChild,
                ),
        ),
      ],
    );
  }

  Widget _buildTextInput(
    BuildContext context,
    ThemeData theme,
    ColorScheme colorScheme,
  ) {
    return ListenableBuilder(
      listenable: inputController,
      builder: (context, _) {
        final hasText = inputController.text.trim().isNotEmpty;
        // 思考中仍可发送，消息进入队列
        final canSend = hasText || hasPendingAttachments;

        return Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            _ghostIcon(
              icon: Icons.add_rounded,
              tooltip: loading ? '添加附件（将排队发送）' : '添加附件',
              onPressed: onAttach,
              colorScheme: colorScheme,
            ),
            const SizedBox(width: 4),
            Expanded(
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 38),
                child: TextField(
                  controller: inputController,
                  maxLines: 5,
                  minLines: 1,
                  textAlignVertical: TextAlignVertical.center,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: colorScheme.onSurface,
                    height: 1.35,
                  ),
                  decoration: InputDecoration(
                    hintText: '发消息或点右侧麦克风…',
                    hintStyle: theme.textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant.withOpacity(0.62),
                    ),
                    isDense: true,
                    filled: false,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    errorBorder: InputBorder.none,
                    disabledBorder: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 10,
                    ),
                  ),
                  onSubmitted: (_) {
                    if (canSend) onSend();
                  },
                ),
              ),
            ),
            const SizedBox(width: 4),
            _primaryAction(
              icon: Icons.mic_rounded,
              tooltip: asrConfigured
                  ? '语音输入（按住说话）'
                  : '语音输入（请先在智能体配置中填写 ASR）',
              onPressed: onToggleVoice,
              colorScheme: colorScheme,
              emphasized: false,
            ),
            const SizedBox(width: 6),
            _primaryAction(
              icon: Icons.arrow_upward_rounded,
              tooltip: loading ? '排队发送' : '发送',
              onPressed: canSend ? onSend : null,
              colorScheme: colorScheme,
              emphasized: canSend,
            ),
          ],
        );
      },
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    this.selectionMode = false,
    this.selected = false,
    this.onLongPress,
    this.onTap,
  });

  final ChatMessage message;
  final bool selectionMode;
  final bool selected;
  final VoidCallback? onLongPress;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isUser = message.isUser;
    final onFg = isUser ? colorScheme.onPrimary : colorScheme.onSurface;
    final onFgMuted = onFg.withOpacity(0.78);

    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (message.topicLabel != null && message.topicLabel!.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.account_tree_outlined, size: 14, color: onFgMuted),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    message.topicLabel!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: onFgMuted,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        if (message.attachments.isNotEmpty)
          Padding(
            padding: EdgeInsets.only(
              bottom: message.content.trim().isEmpty ? 0 : 8,
            ),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final a in message.attachments)
                  _MessageAttachmentTile(
                    attachment: a,
                    isUser: isUser,
                    onOpen: () => _openLocalPath(
                      context,
                      a.path,
                      name: a.name,
                      mime: a.mime,
                      isImage: a.isImage,
                    ),
                  ),
              ],
            ),
          ),
        if (message.content.trim().isNotEmpty)
          // 多选模式用普通 Text，避免与勾选手势冲突；日常支持划选/复制
          selectionMode
              ? Text(
                  message.content,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: onFg,
                    height: 1.4,
                  ),
                )
              : SelectableText(
                  message.content,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: onFg,
                    height: 1.4,
                  ),
                ),
      ],
    );

    Widget bubble = Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: isUser
            ? colorScheme.primary.withOpacity(0.9)
            : colorScheme.surfaceContainerHighest.withOpacity(0.6),
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(6),
          topRight: const Radius.circular(6),
          bottomLeft: Radius.circular(isUser ? 6 : 4),
          bottomRight: Radius.circular(isUser ? 4 : 6),
        ),
        border: Border.all(
          color: selected
              ? colorScheme.primary
              : colorScheme.outline.withOpacity(0.2),
          width: selected ? 2 : 0.5,
        ),
      ),
      child: body,
    );

    // 多选点选：包一层 InkWell；长按菜单挂在外层，避免挡住文字划选
    if (onTap != null) {
      bubble = InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: bubble,
      );
    } else if (onLongPress != null) {
      bubble = GestureDetector(
        onLongPress: onLongPress,
        behavior: HitTestBehavior.deferToChild,
        child: bubble,
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        mainAxisAlignment:
            isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (selectionMode) ...[
            Padding(
              padding: const EdgeInsets.only(right: 8, top: 10),
              child: Icon(
                selected ? Icons.check_circle : Icons.circle_outlined,
                color: selected
                    ? colorScheme.primary
                    : colorScheme.onSurfaceVariant,
                size: 22,
              ),
            ),
          ],
          if (!isUser && !selectionMode)
            CircleAvatar(
              radius: 18,
              backgroundColor: colorScheme.primary.withOpacity(0.6),
              child: Icon(
                Icons.smart_toy_rounded,
                size: 20,
                color: colorScheme.onPrimary,
              ),
            ),
          if (!isUser && !selectionMode) const SizedBox(width: 10),
          Flexible(child: bubble),
          if (isUser && !selectionMode) const SizedBox(width: 10),
          if (isUser && !selectionMode)
            CircleAvatar(
              radius: 18,
              backgroundColor: colorScheme.primary.withOpacity(0.9),
              child: Icon(
                Icons.person_rounded,
                size: 20,
                color: colorScheme.onPrimary,
              ),
            ),
        ],
      ),
    );
  }
}

class _MessageAttachmentTile extends StatelessWidget {
  const _MessageAttachmentTile({
    required this.attachment,
    required this.isUser,
    required this.onOpen,
  });

  final ChatMessageAttachment attachment;
  final bool isUser;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final fg = isUser ? cs.onPrimary : cs.onSurface;
    final muted = fg.withOpacity(0.8);
    final path = attachment.path?.trim() ?? '';
    final hasFile = path.isNotEmpty && File(path).existsSync();

    Widget thumb;
    if (attachment.isImage && hasFile) {
      thumb = ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Image.file(
          File(path),
          width: 148,
          height: 110,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _filePlaceholder(
            icon: Icons.broken_image_outlined,
            fg: muted,
          ),
        ),
      );
    } else {
      IconData icon = Icons.insert_drive_file_outlined;
      if (attachment.isVideo) icon = Icons.videocam_outlined;
      if (attachment.kind == 'textDoc' || attachment.kind == 'binaryDoc') {
        icon = Icons.description_outlined;
      }
      if (attachment.isImage) icon = Icons.image_outlined;
      thumb = _filePlaceholder(icon: icon, fg: muted, wide: true);
    }

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onOpen,
        borderRadius: BorderRadius.circular(12),
        child: Ink(
          decoration: BoxDecoration(
            color: fg.withOpacity(0.08),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: fg.withOpacity(0.14)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              thumb,
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      hasFile ? Icons.open_in_new_rounded : Icons.link_off_rounded,
                      size: 12,
                      color: muted,
                    ),
                    const SizedBox(width: 4),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 120),
                      child: Text(
                        attachment.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: fg,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _filePlaceholder({
    required IconData icon,
    required Color fg,
    bool wide = false,
  }) {
    return Container(
      width: wide ? 148 : 56,
      height: wide ? 72 : 56,
      alignment: Alignment.center,
      child: Icon(icon, size: 28, color: fg),
    );
  }
}

/// 录音浮层配色：与 [FrostedBackground] 各主题（星界 / 地界 / CyberPunk 等）对齐
class _AsrOverlayLook {
  const _AsrOverlayLook({
    required this.topShadeA,
    required this.topShadeB,
    required this.panelGradient,
    required this.panelStops,
    required this.panelSheen,
    required this.mainText,
    required this.subText,
    required this.mainTextShadows,
    required this.subtleTextShadows,
    required this.waveAccent,
  });

  final Color topShadeA;
  final Color topShadeB;
  final List<Color> panelGradient;
  final List<double>? panelStops;
  final Color panelSheen;
  final Color mainText;
  final Color subText;
  final List<Shadow> mainTextShadows;
  final List<Shadow> subtleTextShadows;
  final Color waveAccent;

  static const List<Shadow> _cosmicMainShadow = [
    Shadow(color: Color(0x88001828), blurRadius: 14, offset: Offset(0, 2)),
    Shadow(color: Color(0x55000000), blurRadius: 8, offset: Offset(0, 1)),
  ];

  static _AsrOverlayLook resolve(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final ext = theme.extension<HibiThemeExtension>();
    final id = ext?.themeId;
    final b = theme.brightness;

    switch (id) {
      case AppThemeId.astral:
      case AppThemeId.astralPhantasm:
        return _astralFamily();
      case AppThemeId.earthrealm:
        return _earthrealm();
      case AppThemeId.cyberpunk:
        return _cyberpunk();
      case AppThemeId.dreamy:
      case AppThemeId.dreamyNight:
        return _dreamy(b);
      case null:
      case AppThemeId.hibi:
      case AppThemeId.dark:
      case AppThemeId.light:
      case AppThemeId.spring2027:
      default:
        return _fromColorScheme(cs, b);
    }
  }

  /// 星界 / 星界·幻：青绿地平线 + 冰白字 + 浅青声波（与截图一致）
  static _AsrOverlayLook _astralFamily() {
    return _AsrOverlayLook(
      topShadeA: const Color(0xFF020510).withOpacity(0.42),
      topShadeB: const Color(0xFF0A1430).withOpacity(0.55),
      panelGradient: [
        const Color(0xFF3FD8E5).withOpacity(0.58),
        const Color(0xFF0F7F8F).withOpacity(0.94),
        const Color(0xFF064550).withOpacity(0.97),
      ],
      panelStops: const [0.0, 0.42, 1.0],
      panelSheen: const Color(0xFFB8FBFF).withOpacity(0.24),
      mainText: const Color(0xFFF2FDFF),
      subText: const Color(0xFFB8ECF5).withOpacity(0.88),
      mainTextShadows: _cosmicMainShadow,
      subtleTextShadows: [
        Shadow(color: const Color(0xFF001820).withOpacity(0.72), blurRadius: 8, offset: const Offset(0, 1)),
      ],
      waveAccent: const Color(0xFFB8F5FF),
    );
  }

  static _AsrOverlayLook _earthrealm() {
    return _AsrOverlayLook(
      topShadeA: const Color(0xFF020818).withOpacity(0.44),
      topShadeB: const Color(0xFF081C38).withOpacity(0.56),
      panelGradient: [
        const Color(0xFF4CB8FF).withOpacity(0.48),
        const Color(0xFF1568A8).withOpacity(0.92),
        const Color(0xFF0A3D62).withOpacity(0.96),
      ],
      panelStops: const [0.0, 0.44, 1.0],
      panelSheen: const Color(0xFF9FD8FF).withOpacity(0.2),
      mainText: const Color(0xFFF0F8FF),
      subText: const Color(0xFFB0D8F8).withOpacity(0.86),
      mainTextShadows: _cosmicMainShadow,
      subtleTextShadows: [
        Shadow(color: const Color(0xFF001428).withOpacity(0.7), blurRadius: 8, offset: const Offset(0, 1)),
      ],
      waveAccent: const Color(0xFF9FD8FF),
    );
  }

  static _AsrOverlayLook _cyberpunk() {
    return _AsrOverlayLook(
      topShadeA: const Color(0xFF050008).withOpacity(0.52),
      topShadeB: const Color(0xFF12081A).withOpacity(0.6),
      panelGradient: [
        const Color(0xFF00FFD5).withOpacity(0.38),
        const Color(0xFF6B1A8C).withOpacity(0.82),
        const Color(0xFF12082A).withOpacity(0.95),
      ],
      panelStops: const [0.0, 0.45, 1.0],
      panelSheen: const Color(0xFFFF00AA).withOpacity(0.14),
      mainText: const Color(0xFFE8F8FF),
      subText: const Color(0xFF7EE0D5).withOpacity(0.85),
      mainTextShadows: const [
        Shadow(color: Color(0x99000000), blurRadius: 12, offset: Offset(0, 2)),
        Shadow(color: Color(0xFF00FFD5), blurRadius: 18, offset: Offset(0, 0)),
      ],
      subtleTextShadows: [
        Shadow(color: const Color(0xFF000510).withOpacity(0.75), blurRadius: 6, offset: const Offset(0, 1)),
      ],
      waveAccent: const Color(0xFF00FFC8),
    );
  }

  static _AsrOverlayLook _dreamy(Brightness b) {
    final isDark = b == Brightness.dark;
    return _AsrOverlayLook(
      topShadeA: const Color(0xFF120818).withOpacity(isDark ? 0.4 : 0.18),
      topShadeB: const Color(0xFF281838).withOpacity(isDark ? 0.52 : 0.22),
      panelGradient: [
        const Color(0xFFE8A8FF).withOpacity(isDark ? 0.42 : 0.35),
        const Color(0xFF8B4DA8).withOpacity(isDark ? 0.88 : 0.72),
        const Color(0xFF4A2860).withOpacity(isDark ? 0.94 : 0.78),
      ],
      panelStops: const [0.0, 0.44, 1.0],
      panelSheen: const Color(0xFFFFE8FF).withOpacity(0.18),
      mainText: const Color(0xFFFFF5FF),
      subText: const Color(0xFFE8C8F0).withOpacity(0.82),
      mainTextShadows: _cosmicMainShadow,
      subtleTextShadows: [
        Shadow(color: Colors.black.withOpacity(0.45), blurRadius: 8, offset: const Offset(0, 1)),
      ],
      waveAccent: const Color(0xFFFFB8F0),
    );
  }

  static _AsrOverlayLook _fromColorScheme(ColorScheme cs, Brightness b) {
    final isDark = b == Brightness.dark;
    final primary = cs.primary;
    final panelMid = Color.lerp(primary, cs.surface, isDark ? 0.72 : 0.58)!;
    final panelDeep = Color.lerp(primary, cs.surface, isDark ? 0.58 : 0.46)!;
    return _AsrOverlayLook(
      topShadeA: cs.scrim.withOpacity(isDark ? 0.26 : 0.12),
      topShadeB: cs.scrim.withOpacity(isDark ? 0.34 : 0.2),
      panelGradient: [
        primary.withOpacity(isDark ? 0.52 : 0.42),
        panelMid.withOpacity(isDark ? 0.92 : 0.82),
        panelDeep.withOpacity(isDark ? 0.95 : 0.86),
      ],
      panelStops: const [0.0, 0.44, 1.0],
      panelSheen: Colors.white.withOpacity(isDark ? 0.18 : 0.12),
      mainText: cs.onSurface.withOpacity(0.96),
      subText: cs.onSurface.withOpacity(0.62),
      mainTextShadows: isDark
          ? [
              Shadow(color: Colors.black.withOpacity(0.45), blurRadius: 10, offset: const Offset(0, 1)),
            ]
          : const [],
      subtleTextShadows: isDark
          ? [
              Shadow(color: Colors.black.withOpacity(0.35), blurRadius: 6, offset: const Offset(0, 1)),
            ]
          : const [],
      waveAccent: primary,
    );
  }
}

/// 大半圆毛玻璃裁剪：顶部为向上凸起的圆弧，底部贴屏
class _FrostedSemiCircleClipper extends CustomClipper<Path> {
  _FrostedSemiCircleClipper({required this.arcRise, required this.arcStartY});

  final double arcRise;
  final double arcStartY;

  @override
  Path getClip(Size size) {
    final path = Path();
    path.moveTo(0, size.height);
    path.lineTo(0, arcStartY);
    path.quadraticBezierTo(
      size.width / 2,
      arcStartY - arcRise,
      size.width,
      arcStartY,
    );
    path.lineTo(size.width, size.height);
    path.close();
    return path;
  }

  @override
  bool shouldReclip(covariant CustomClipper<Path> oldDelegate) => false;
}

/// 录音浮层声波：竖条电平，与主题色一致
class _RecordingWavePainter extends CustomPainter {
  _RecordingWavePainter({required this.phase, required this.accentColor});

  final double phase;
  final Color accentColor;

  static const int _barCount = 55;
  static const double _minHeight = 6.0;
  static const double _maxHeight = 34.0;

  @override
  void paint(Canvas canvas, Size size) {
    final barWidth = (size.width / _barCount).clamp(1.5, 6.0) * 0.18;
    final gap = (size.width - barWidth * _barCount) / (_barCount + 1);
    final centerY = size.height / 2;
    const amp = (_maxHeight - _minHeight) / 2;
    const base = (_maxHeight + _minHeight) / 2;

    final barGradient = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        accentColor.withOpacity(0.75),
        Colors.white.withOpacity(0.9),
        accentColor.withOpacity(0.7),
      ],
      stops: const [0.0, 0.5, 1.0],
    );
    final rect = Offset.zero & size;
    final paint = Paint()
      ..shader = barGradient.createShader(rect)
      ..isAntiAlias = true;

    for (int i = 0; i < _barCount; i++) {
      final t = phase + i * 0.38;
      final h = (base + amp * math.sin(t)).clamp(_minHeight, _maxHeight);
      final left = gap + i * (barWidth + gap);
      final rrect = RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(left + barWidth / 2, centerY),
          width: barWidth,
          height: h,
        ),
        Radius.circular(barWidth / 2),
      );
      canvas.drawRRect(rrect, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _RecordingWavePainter oldDelegate) {
    return oldDelegate.phase != phase || oldDelegate.accentColor != accentColor;
  }
}
