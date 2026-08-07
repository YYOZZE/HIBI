import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../../config/api_config.dart';

typedef AsrTextCallback = void Function(String text);

/// 豆包 ASR 流式识别：通过 WebSocket 与后端 `/api/asr/stream` 通信。
/// 行为对齐参考项目 `Flutter_he_buddy_002_mobile` 的 `asr_stream_service.dart`。
class AsrStreamService {
  WebSocket? _ws;
  StreamSubscription? _wsSub;
  Completer<String>? _doneCompleter;
  String _lastPartial = '';
  String _finalText = '';
  String? _lastError;
  int _sentChunks = 0;
  int _sentBytes = 0;
  bool _ready = false;
  AsrTextCallback? _onPartial;
  /// 服务端返回 `ready` 之前，先采到的麦克风数据暂存于此，避免「等握手完才开始录音」丢掉句首。
  final List<Uint8List> _preReadyBuffer = <Uint8List>[];
  int _preReadyBytes = 0;
  static const int _maxPreReadyBytes = 128000; // ~4s @ 16kHz mono PCM16

  String? get lastError => _lastError;

  Future<bool> start({AsrTextCallback? onPartial}) async {
    // 必须先关掉上一轮 WS（含语音模式预热、重复 start），否则旧连接仍收包会错乱 completer，表现为第二次识别无文本。
    await _safeClose();
    final wsBase = _toWsUrl(ApiConfig.assistantApiBaseUrl.trim());
    if (wsBase.isEmpty) {
      _lastError = '未配置后端地址';
      return false;
    }
    _onPartial = onPartial;
    _lastPartial = '';
    _finalText = '';
    _lastError = null;
    _sentChunks = 0;
    _sentBytes = 0;
    _ready = false;
    _preReadyBuffer.clear();
    _preReadyBytes = 0;
    _doneCompleter = Completer<String>();
    try {
      final url = '$wsBase/api/asr/stream';
      debugPrint('[ASR-STREAM] connect => $url');
      _ws = await WebSocket.connect(url);
      _wsSub = _ws!.listen(_onEvent, onError: _onError, onDone: _onClosed);
      // 不阻塞等待 ready：与麦克风 startStream 并行时，句首音频由 sendAudio 缓冲至 ready 后顺序发出。
      debugPrint('[ASR-STREAM] ws connected (await server ready via buffer)');
      return true;
    } catch (e) {
      _lastError ??= 'ASR 流式通道连接失败: $e';
      debugPrint('[ASR-STREAM] start fail: $_lastError');
      await _safeClose();
      return false;
    }
  }

  void _enqueuePreReady(Uint8List chunk) {
    while (_preReadyBytes + chunk.length > _maxPreReadyBytes && _preReadyBuffer.isNotEmpty) {
      final removed = _preReadyBuffer.removeAt(0);
      _preReadyBytes -= removed.length;
    }
    if (_preReadyBytes + chunk.length <= _maxPreReadyBytes) {
      _preReadyBuffer.add(chunk);
      _preReadyBytes += chunk.length;
    }
  }

  void _flushPreReady() {
    if (_ws == null || !_ready) return;
    for (final c in _preReadyBuffer) {
      _sentChunks += 1;
      _sentBytes += c.length;
      _ws!.add(c);
    }
    if (_preReadyBuffer.isNotEmpty) {
      debugPrint('[ASR-STREAM] flushed pre-ready chunks=${_preReadyBuffer.length} bytes=$_preReadyBytes');
    }
    _preReadyBuffer.clear();
    _preReadyBytes = 0;
  }

  void sendAudio(Uint8List chunk) {
    if (_ws == null || chunk.isEmpty) return;
    if (!_ready) {
      _enqueuePreReady(chunk);
      return;
    }
    _sentChunks += 1;
    _sentBytes += chunk.length;
    if (_sentChunks % 10 == 0) {
      debugPrint('[ASR-STREAM] sent chunks=$_sentChunks bytes=$_sentBytes');
    }
    _ws!.add(chunk);
  }

  /// 等待服务端 `done`；超时需覆盖后端 ASR 收尾（含豆包侧排队），不宜过短。
  Future<String> stopAndGetFinal({required bool cancel}) async {
    try {
      if (_ws != null) {
        debugPrint('[ASR-STREAM] stop cancel=$cancel chunks=$_sentChunks bytes=$_sentBytes');
        _ws!.add(jsonEncode({'event': cancel ? 'cancel' : 'end'}));
      }
      final text = await _doneCompleter!.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () => _finalText.isNotEmpty ? _finalText : _lastPartial,
      );
      debugPrint('[ASR-STREAM] done textLen=${text.trim().length} err=${_lastError ?? ''}');
      await _safeClose();
      return (cancel ? '' : text).trim();
    } catch (e) {
      debugPrint('[ASR-STREAM] stop fail err=${_lastError ?? e.toString()}');
      await _safeClose();
      return '';
    }
  }

  void _onEvent(dynamic event) {
    if (event is! String) return;
    try {
      final data = jsonDecode(event) as Map<String, dynamic>;
      final type = data['event']?.toString() ?? '';
      final text = (data['text']?.toString() ?? '').trim();
      if (type == 'ready') {
        _ready = true;
        debugPrint('[ASR-STREAM] event=ready');
        _flushPreReady();
        return;
      }
      if (type == 'partial') {
        if (text.isNotEmpty) {
          _lastPartial = text;
          debugPrint('[ASR-STREAM] event=partial len=${text.length}');
          _onPartial?.call(text);
        }
        return;
      }
      if (type == 'final') {
        if (text.isNotEmpty) {
          _lastPartial = text;
          _finalText = text;
          debugPrint('[ASR-STREAM] event=final len=${text.length}');
          _onPartial?.call(text);
        }
        return;
      }
      if (type == 'done') {
        debugPrint('[ASR-STREAM] event=done len=${text.length}');
        final done = text.isNotEmpty ? text : (_finalText.isNotEmpty ? _finalText : _lastPartial);
        if (!(_doneCompleter?.isCompleted ?? true)) {
          _doneCompleter!.complete(done);
        }
        return;
      }
      if (type == 'error') {
        _lastError = text.isNotEmpty ? text : (data['message']?.toString() ?? 'ASR 流式服务错误');
        debugPrint('[ASR-STREAM] event=error msg=$_lastError');
        if (!(_doneCompleter?.isCompleted ?? true)) {
          _doneCompleter!.complete(_finalText.isNotEmpty ? _finalText : _lastPartial);
        }
      }
    } catch (_) {}
  }

  void _onError(Object _) {
    _lastError ??= 'ASR 流式连接异常';
    debugPrint('[ASR-STREAM] socket onError $_lastError');
    _preReadyBuffer.clear();
    _preReadyBytes = 0;
    if (!(_doneCompleter?.isCompleted ?? true)) {
      _doneCompleter!.complete(_finalText.isNotEmpty ? _finalText : _lastPartial);
    }
  }

  void _onClosed() {
    debugPrint('[ASR-STREAM] socket onClosed ready=$_ready');
    if (!_ready) {
      _lastError ??= 'ASR 流式连接已关闭';
    }
    _preReadyBuffer.clear();
    _preReadyBytes = 0;
    if (!(_doneCompleter?.isCompleted ?? true)) {
      _doneCompleter!.complete(_finalText.isNotEmpty ? _finalText : _lastPartial);
    }
  }

  Future<void> _safeClose() async {
    await _wsSub?.cancel();
    _wsSub = null;
    try {
      await _ws?.close();
    } catch (_) {}
    _ws = null;
    _ready = false;
    _preReadyBuffer.clear();
    _preReadyBytes = 0;
  }

  String _toWsUrl(String baseUrl) {
    if (baseUrl.isEmpty) return '';
    if (baseUrl.startsWith('https://')) {
      return 'wss://${baseUrl.substring('https://'.length)}';
    }
    if (baseUrl.startsWith('http://')) {
      return 'ws://${baseUrl.substring('http://'.length)}';
    }
    if (baseUrl.startsWith('ws://') || baseUrl.startsWith('wss://')) {
      return baseUrl;
    }
    return 'ws://$baseUrl';
  }
}
