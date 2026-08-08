import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../profile/services/agent_config_service.dart';
import 'doubao_sauc_protocol.dart';

typedef AsrTextCallback = void Function(String text);

/// 豆包 ASR 流式识别：App 直连火山 OpenSpeech（SAUC），不再经 HIBI 后端转发。
class AsrStreamService {
  WebSocket? _ws;
  StreamSubscription? _wsSub;
  Completer<String>? _doneCompleter;
  String _lastPartial = '';
  String _finalText = '';
  String? _lastError;
  int _sentChunks = 0;
  int _sentBytes = 0;
  int _audioSeq = 2;
  bool _ready = false;
  bool _closing = false;
  AsrTextCallback? _onPartial;

  /// 建链/发 full request 完成前的麦克风缓冲，避免丢句首。
  final List<Uint8List> _preReadyBuffer = <Uint8List>[];
  int _preReadyBytes = 0;
  static const int _maxPreReadyBytes = 128000; // ~4s @ 16kHz mono PCM16

  String? get lastError => _lastError;

  Future<bool> start({
    AsrTextCallback? onPartial,
    AsrClientConfig? clientAsr,
  }) async {
    await _safeClose();
    final asr = clientAsr ?? await AgentConfigService.activeAsrConfig();
    if (asr == null || !asr.isUsable) {
      _lastError = '请先在「智能体配置」启用并填写豆包 ASR（APP ID / Access Token）';
      return false;
    }

    _onPartial = onPartial;
    _lastPartial = '';
    _finalText = '';
    _lastError = null;
    _sentChunks = 0;
    _sentBytes = 0;
    _audioSeq = 2;
    _ready = false;
    _closing = false;
    _preReadyBuffer.clear();
    _preReadyBytes = 0;
    _doneCompleter = Completer<String>();

    final headers = DoubaoSaucProtocol.buildAuthHeaders(
      appId: asr.appId,
      accessToken: asr.accessToken,
      resourceId: asr.effectiveResourceId,
    );
    final candidates = <String>[
      DoubaoSaucProtocol.defaultWsUrl,
      DoubaoSaucProtocol.defaultWsUrlAsync,
    ];

    Object? lastErr;
    for (final url in candidates) {
      try {
        debugPrint('[ASR-DIRECT] connect => $url');
        _ws = await WebSocket.connect(url, headers: headers).timeout(
          const Duration(seconds: 20),
        );
        _wsSub = _ws!.listen(
          _onEvent,
          onError: _onError,
          onDone: _onClosed,
          cancelOnError: true,
        );

        // full client request (seq=1)
        final full = DoubaoSaucProtocol.newFullClientRequest(seq: 1);
        _ws!.add(full);
        _ready = true;
        debugPrint('[ASR-DIRECT] full request sent, ready');
        _flushPreReady();
        return true;
      } catch (e) {
        lastErr = e;
        debugPrint('[ASR-DIRECT] connect fail url=$url err=$e');
        await _safeClose(preserveCompleter: true);
      }
    }

    _lastError = 'ASR 直连失败: ${lastErr ?? 'unknown'}';
    if (!(_doneCompleter?.isCompleted ?? true)) {
      _doneCompleter!.complete('');
    }
    await _safeClose();
    return false;
  }

  void _enqueuePreReady(Uint8List chunk) {
    while (_preReadyBytes + chunk.length > _maxPreReadyBytes &&
        _preReadyBuffer.isNotEmpty) {
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
      _sendPcmFrame(c, isLast: false);
    }
    if (_preReadyBuffer.isNotEmpty) {
      debugPrint(
        '[ASR-DIRECT] flushed pre-ready chunks=${_preReadyBuffer.length} bytes=$_preReadyBytes',
      );
    }
    _preReadyBuffer.clear();
    _preReadyBytes = 0;
  }

  void _sendPcmFrame(Uint8List pcm, {required bool isLast}) {
    if (_ws == null || pcm.isEmpty && !isLast) return;
    final seq = _audioSeq;
    if (!isLast) _audioSeq += 1;
    final frame = DoubaoSaucProtocol.newAudioOnlyRequest(
      seq: seq,
      pcm: pcm.isEmpty ? Uint8List(0) : pcm,
      isLast: isLast,
    );
    _ws!.add(frame);
    if (pcm.isNotEmpty) {
      _sentChunks += 1;
      _sentBytes += pcm.length;
    }
  }

  void sendAudio(Uint8List chunk) {
    if (_ws == null || chunk.isEmpty || _closing) return;
    if (!_ready) {
      _enqueuePreReady(chunk);
      return;
    }
    _sendPcmFrame(chunk, isLast: false);
    if (_sentChunks % 10 == 0) {
      debugPrint('[ASR-DIRECT] sent chunks=$_sentChunks bytes=$_sentBytes');
    }
  }

  /// 结束本轮：发送负序号收尾包，等待最终结果。
  Future<String> stopAndGetFinal({required bool cancel}) async {
    final completer = _doneCompleter;
    try {
      _closing = true;
      if (_ws != null && _ready) {
        debugPrint(
          '[ASR-DIRECT] stop cancel=$cancel chunks=$_sentChunks bytes=$_sentBytes',
        );
        try {
          // 收尾：空 PCM + is_last
          _sendPcmFrame(Uint8List(0), isLast: true);
        } catch (_) {}
      }
      if (completer == null) {
        await _safeClose();
        return '';
      }
      if (cancel) {
        if (!completer.isCompleted) completer.complete('');
        await _safeClose();
        return '';
      }
      final text = await completer.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () => _finalText.isNotEmpty ? _finalText : _lastPartial,
      );
      debugPrint(
        '[ASR-DIRECT] done textLen=${text.trim().length} err=${_lastError ?? ''}',
      );
      await _safeClose();
      return text.trim();
    } catch (e) {
      debugPrint('[ASR-DIRECT] stop fail err=${_lastError ?? e.toString()}');
      await _safeClose();
      return '';
    }
  }

  void _onEvent(dynamic event) {
    if (event is! List<int>) return;
    try {
      final resp = DoubaoSaucProtocol.parseResponse(Uint8List.fromList(event));
      final msg = resp.payloadMsg;
      if (resp.isError || (resp.code != 0 && msg != null)) {
        final err = (msg?['message'] ?? msg?['msg'] ?? resp.code).toString();
        _lastError = 'ASR 错误: $err';
        debugPrint('[ASR-DIRECT] error code=${resp.code} msg=$_lastError');
        if (!(_doneCompleter?.isCompleted ?? true)) {
          _doneCompleter!
              .complete(_finalText.isNotEmpty ? _finalText : _lastPartial);
        }
        return;
      }

      final text = DoubaoSaucProtocol.extractText(msg);
      final isFinal =
          resp.isLastPackage || DoubaoSaucProtocol.payloadIsFinal(msg);

      if (text.isNotEmpty) {
        _lastPartial = text;
        if (isFinal) _finalText = text;
        _onPartial?.call(text);
        debugPrint(
          '[ASR-DIRECT] ${isFinal ? 'final' : 'partial'} len=${text.length}',
        );
      }

      if (resp.isLastPackage || (_closing && isFinal && text.isNotEmpty)) {
        if (!(_doneCompleter?.isCompleted ?? true)) {
          final done =
              _finalText.isNotEmpty ? _finalText : (_lastPartial);
          _doneCompleter!.complete(done);
        }
      }
    } catch (e) {
      debugPrint('[ASR-DIRECT] parse fail: $e');
    }
  }

  void _onError(Object e) {
    _lastError ??= 'ASR 直连异常: $e';
    debugPrint('[ASR-DIRECT] socket onError $_lastError');
    _preReadyBuffer.clear();
    _preReadyBytes = 0;
    if (!(_doneCompleter?.isCompleted ?? true)) {
      _doneCompleter!.complete(_finalText.isNotEmpty ? _finalText : _lastPartial);
    }
  }

  void _onClosed() {
    debugPrint('[ASR-DIRECT] socket onClosed ready=$_ready');
    if (!_ready) {
      _lastError ??= 'ASR 直连已关闭';
    }
    _preReadyBuffer.clear();
    _preReadyBytes = 0;
    if (!(_doneCompleter?.isCompleted ?? true)) {
      _doneCompleter!.complete(_finalText.isNotEmpty ? _finalText : _lastPartial);
    }
  }

  Future<void> _safeClose({bool preserveCompleter = false}) async {
    await _wsSub?.cancel();
    _wsSub = null;
    try {
      await _ws?.close();
    } catch (_) {}
    _ws = null;
    _ready = false;
    _closing = false;
    _preReadyBuffer.clear();
    _preReadyBytes = 0;
    if (!preserveCompleter) {
      // completer 由 stop/onEvent 结束；此处不强制 complete 以免竞态
    }
  }
}
