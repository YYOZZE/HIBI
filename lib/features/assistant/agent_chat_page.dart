import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

import '../../app/app_theme_extension.dart';
import '../../app/frosted_background.dart';
import '../../app/theme_notifier.dart';
import '../../config/api_config.dart';
import '../auth/services/auth_repository.dart';
import '../auth/services/user_sync_service.dart';
import '../auth/services/user_sync_scheduler.dart';
import '../profile/subscription_access_service.dart';
import '../profile/value_added_page.dart';
import '../mind/services/mind_repository.dart';
import '../schedule/schedule_event_store.dart';
import 'models/agent.dart';
import 'models/chat_message.dart';
import 'services/assistant_api.dart';
import 'services/assistant_repository.dart';
import 'services/asr_service.dart';
import 'services/asr_stream_service.dart';

/// 单个智能体的文字对话页（豆包式：消息气泡 + 底部输入）
/// 长按气泡：复制 / 删除本条 / 进入多选；多选模式下可批量删除
class AgentChatPage extends StatefulWidget {
  const AgentChatPage({
    super.key,
    required this.agent,
    required this.repository,
    required this.api,
    required this.onAgentUpdated,
    this.currentMindNodeId,
  });

  final Agent agent;
  final AssistantRepository repository;
  final AssistantApi api;
  final VoidCallback onAgentUpdated;
  /// 当前思维节点（项目）id，从白板进入时传入，供工具调用使用
  final String? currentMindNodeId;

  @override
  State<AgentChatPage> createState() => _AgentChatPageState();
}

class _AgentChatPageState extends State<AgentChatPage> with SingleTickerProviderStateMixin {
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  List<ChatMessage> _messages = [];
  bool _loading = false;
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

  @override
  void initState() {
    super.initState();
    UserSyncScheduler.syncEpoch.addListener(_onSyncEpoch);
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

  Future<void> _loadMessages() async {
    // 登录态优先从后端拉取“真实历史”（方案 B）；未登录或失败则回落本地缓存
    final token = AuthRepository.instance.currentUser?.token;
    if (token != null && token.isNotEmpty) {
      try {
        final convId = await widget.api.getOrCreateConversationId(
          agentId: widget.agent.id,
          title: widget.agent.name,
          token: token,
        );
        if (convId != null && convId.isNotEmpty) {
          final res = await widget.api.listConversationMessages(
            conversationId: convId,
            limit: 80,
            token: token,
          );
          // 写入本地仓库做缓存（以 srv_ 前缀避免与本地 id 冲突）
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
            widget.repository.addMessage(
              widget.agent.id,
              ChatMessage(
                role: role,
                content: content,
                timestamp: dt,
                id: sid.isNotEmpty ? 'srv_$sid' : null,
              ),
            );
          }
        }
      } catch (_) {}
    }
    await widget.repository.loadMessages(widget.agent.id);
    if (mounted) {
      setState(() => _messages = widget.repository.getMessages(widget.agent.id).toList());
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
    _recordingTimer?.cancel();
    _recordingStreamSub?.cancel();
    _armedMicSub?.cancel();
    _asrStreamService.stopAndGetFinal(cancel: true);
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

  Future<void> _showAssistantSubscriptionRequired() async {
    if (!mounted) return;
    final goSubscribe = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return AlertDialog(
          backgroundColor: theme.dialogTheme.backgroundColor ?? theme.colorScheme.surface,
          surfaceTintColor: Colors.transparent,
          title: const Text('需要助理服务订阅'),
          content: const Text('你当前未开通助理服务，订阅后即可与智能体连续对话。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('稍后再说'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('去订阅'),
            ),
          ],
        );
      },
    );
    if (goSubscribe == true && mounted) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const ValueAddedPage()),
      );
    }
  }

  Future<void> _send() async {
    final text = _inputController.text.trim();
    _inputController.clear();
    await _sendText(text);
  }

  Future<void> _sendText(String rawText) async {
    final text = rawText.trim();
    if (text.isEmpty || _loading) return;
    final canChat = await SubscriptionAccessService.hasAssistantChatAccess();
    if (!mounted) return;
    if (!canChat) {
      await _showAssistantSubscriptionRequired();
      return;
    }

    final userMsg = ChatMessage(role: 'user', content: text);
    widget.repository.addMessage(widget.agent.id, userMsg);
    setState(() {
      _messages = widget.repository.getMessages(widget.agent.id).toList();
      _loading = true;
    });
    _scrollToEnd();

    try {
      final history = _messages
          .where((m) => m.id != userMsg.id)
          .map<Map<String, String>>((m) => {'role': m.role, 'content': m.content})
          .toList();
      // 已登录则一律走后端 ABP + 工具（与是否「白板自动创建」无关）；未登录仍用 agent 名称/职能的普通 system prompt
      final token = AuthRepository.instance.currentUser?.token;
      final useBackend = token != null && token.isNotEmpty;
      final mindNodeId = widget.currentMindNodeId ?? widget.agent.mindNodeId;
      final reply = await widget.api.sendMessage(
        agentId: widget.agent.id,
        userMessage: text,
        history: history,
        agentName: widget.agent.name,
        agentRole: widget.agent.role,
        useBackendSystemPrompt: useBackend,
        currentMindNodeId: mindNodeId,
        token: token,
      );
      // 工具在服务端写入日程/白板等：仅同步结构化数据（mind/schedule），避免旧 assistant 同步包覆盖聊天消息。
      if (useBackend) {
        try {
          await UserSyncService(baseUrl: ApiConfig.authApiBaseUrl).pull(
            token,
            bypassSubscriptionCheck: true,
          );
          await MindRepository.instance.reloadFromDisk();
          await ScheduleEventStore.instance.reloadFromDisk();
          UserSyncScheduler.syncEpoch.value++;
        } catch (_) {}
      }
      final assistantMsg = ChatMessage(role: 'assistant', content: reply);
      widget.repository.addMessage(widget.agent.id, assistantMsg);
      if (mounted) {
        setState(() {
          _messages = widget.repository.getMessages(widget.agent.id).toList();
          _loading = false;
        });
        _scrollToEnd();
      }
    } catch (e) {
      final errMsg = ChatMessage(role: 'assistant', content: '请求失败：$e');
      widget.repository.addMessage(widget.agent.id, errMsg);
      if (mounted) {
        setState(() {
          _messages = widget.repository.getMessages(widget.agent.id).toList();
          _loading = false;
        });
        _scrollToEnd();
      }
    }
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('请先配置后端 ASR 后使用语音输入'),
          duration: Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('请先配置后端 ASR 后使用语音输入'),
          duration: Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('请先配置后端 ASR 后使用语音输入'),
          duration: Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
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
                                  fontSize: 15,
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
                            Text(
                              '正在思考…',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: colorScheme.onSurfaceVariant,
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
              if (!_selectionMode)
                _ChatInputBar(
                  inputController: _inputController,
                  loading: _loading,
                  onSend: _send,
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
          ),
          if (_isRecording) _buildRecordingOverlay(),
        ],
      ),
    );
  }
}

class _ChatInputBar extends StatelessWidget {
  const _ChatInputBar({
    required this.inputController,
    required this.loading,
    required this.onSend,
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
  final VoidCallback onSend;
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

  static final _inputBorder = OutlineInputBorder(
    borderRadius: BorderRadius.circular(20),
    borderSide: BorderSide.none,
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
          decoration: BoxDecoration(
            color: colorScheme.surface.withOpacity(0.5),
          ),
          child: SafeArea(
            top: false,
            child: voiceInputMode
                ? _buildVoiceInput(context, theme, colorScheme)
                : _buildTextInput(context, theme, colorScheme),
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
    // 全平台统一：按住说话、松手发送、上划取消
    final usePointer = onHoldToTalkPointerDown != null &&
        onHoldToTalkPointerMove != null &&
        onHoldToTalkPointerUp != null &&
        onHoldToTalkPointerCancel != null;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        IconButton(
          onPressed: loading ? null : onToggleVoice,
          icon: const Icon(Icons.keyboard_rounded, size: 24),
          tooltip: '切换到键盘输入',
        ),
        Expanded(
          // 关键体验：用 Pointer 事件实现“按下即开始”，避免 GestureDetector 的 pan 需等待手势识别（移动阈值）才触发。
          child: usePointer
              ? Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: onHoldToTalkPointerDown,
                  onPointerMove: onHoldToTalkPointerMove,
                  onPointerUp: onHoldToTalkPointerUp,
                  onPointerCancel: onHoldToTalkPointerCancel,
                  child: Container(
                    height: 44,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerHighest.withOpacity(0.5),
                      borderRadius: BorderRadius.circular(22),
                      border: isRecording
                          ? Border.all(
                              color: colorScheme.primary.withOpacity(0.6),
                              width: 1.5,
                            )
                          : null,
                    ),
                    child: Text(
                      isRecording ? '松开发送' : '按住 说话',
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: isRecording
                            ? colorScheme.primary
                            : colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                )
              : GestureDetector(
                  onLongPressStart: (_) => onVoiceLongPressStart(),
                  onLongPressMoveUpdate: (details) => onVoiceLongPressMove(details),
                  onLongPressEnd: (_) => onVoiceLongPressEnd(),
                  child: Container(
                    height: 44,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerHighest.withOpacity(0.5),
                      borderRadius: BorderRadius.circular(22),
                    ),
                    child: Text(
                      '按住 说话',
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
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
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        IconButton.filled(
          onPressed: loading ? null : onToggleVoice,
          icon: Icon(
            voiceInputMode ? Icons.keyboard_rounded : Icons.mic_rounded,
            size: 20,
          ),
          style: IconButton.styleFrom(
            minimumSize: const Size(40, 40),
            padding: EdgeInsets.zero,
          ),
          tooltip: asrConfigured
              ? (voiceInputMode ? '切换到键盘' : '语音输入')
              : '语音输入（需配置）',
        ),
        const SizedBox(width: 6),
        Expanded(
          child: TextField(
            controller: inputController,
            maxLines: 4,
            minLines: 1,
            textAlignVertical: TextAlignVertical.center,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: colorScheme.onSurface,
            ),
            decoration: InputDecoration(
              hintText: '输入消息…',
              hintStyle: theme.textTheme.bodyLarge?.copyWith(
                color: colorScheme.onSurfaceVariant.withOpacity(0.6),
              ),
              isDense: true,
              filled: true,
              fillColor: colorScheme.surfaceContainerHighest.withOpacity(0.4),
              border: _inputBorder,
              enabledBorder: _inputBorder,
              focusedBorder: _inputBorder,
              errorBorder: _inputBorder,
              disabledBorder: _inputBorder,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 12,
              ),
            ),
            onSubmitted: (_) => onSend(),
          ),
        ),
        const SizedBox(width: 6),
        IconButton.filled(
          onPressed: loading ? null : onSend,
          icon: const Icon(Icons.send_rounded, size: 20),
          style: IconButton.styleFrom(
            minimumSize: const Size(40, 40),
            padding: EdgeInsets.zero,
          ),
          tooltip: '发送',
        ),
      ],
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

    Widget bubble = Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
          color: selected ? colorScheme.primary : colorScheme.outline.withOpacity(0.2),
          width: selected ? 2 : 0.5,
        ),
      ),
      child: Text(
        message.content,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: isUser ? colorScheme.onPrimary : colorScheme.onSurface,
          height: 1.4,
        ),
      ),
    );

    if (onLongPress != null || onTap != null) {
      bubble = InkWell(
        onLongPress: onLongPress,
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: bubble,
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        mainAxisAlignment: isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (selectionMode) ...[
            Padding(
              padding: const EdgeInsets.only(right: 8, top: 10),
              child: Icon(
                selected ? Icons.check_circle : Icons.circle_outlined,
                color: selected ? colorScheme.primary : colorScheme.onSurfaceVariant,
                size: 22,
              ),
            ),
          ],
          if (!isUser && !selectionMode)
            CircleAvatar(
              radius: 18,
              backgroundColor: colorScheme.primary.withOpacity(0.6),
              child: Icon(Icons.smart_toy_rounded, size: 20, color: colorScheme.onPrimary),
            ),
          if (!isUser && !selectionMode) const SizedBox(width: 10),
          Flexible(child: bubble),
          if (isUser && !selectionMode) const SizedBox(width: 10),
          if (isUser && !selectionMode)
            CircleAvatar(
              radius: 18,
              backgroundColor: colorScheme.primary.withOpacity(0.9),
              child: Icon(Icons.person_rounded, size: 20, color: colorScheme.onPrimary),
            ),
        ],
      ),
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
