import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// 豆包语音 SAUC WebSocket 二进制协议（对齐官方 demo / 后端 hibi_sauc_protocol.py）。
class DoubaoSaucProtocol {
  DoubaoSaucProtocol._();

  static const int protocolVersionV1 = 0x01;
  static const int msgClientFullRequest = 0x01;
  static const int msgClientAudioOnly = 0x02;
  static const int msgServerFullResponse = 0x09;
  static const int msgServerErrorResponse = 0x0f;

  static const int flagNoSequence = 0x00;
  static const int flagPosSequence = 0x01;
  static const int flagNegSequence = 0x02;
  static const int flagNegWithSequence = 0x03;

  static const int serializationJson = 0x01;
  static const int compressionGzip = 0x01;

  static const String defaultWsUrl =
      'wss://openspeech.bytedance.com/api/v3/sauc/bigmodel';
  static const String defaultWsUrlAsync =
      'wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async';

  static Map<String, dynamic> buildAuthHeaders({
    required String appId,
    required String accessToken,
    required String resourceId,
  }) {
    final reqId = _uuidV4();
    return {
      'X-Api-App-Key': appId.trim(),
      'X-Api-Access-Key': accessToken.trim(),
      'X-Api-Resource-Id': resourceId.trim(),
      'X-Api-Request-Id': reqId,
      // 部分网关需要；与后端可选头一致
      'X-Api-Connect-Id': _uuidV4(),
    };
  }

  static Uint8List newFullClientRequest({
    required int seq,
    int sampleRate = 16000,
    String uid = 'hibi_asr',
    String modelName = 'bigmodel',
  }) {
    final header = _requestHeader(
      messageType: msgClientFullRequest,
      flags: flagPosSequence,
    );
    final payload = <String, dynamic>{
      'user': {'uid': uid},
      'audio': {
        'format': 'pcm',
        'codec': 'raw',
        'rate': sampleRate,
        'bits': 16,
        'channel': 1,
      },
      'request': {
        'model_name': modelName,
        'enable_itn': true,
        'enable_punc': true,
        'enable_ddc': true,
        'show_utterances': true,
        'enable_nonstream': false,
      },
    };
    final compressed = Uint8List.fromList(
      gzip.encode(utf8.encode(jsonEncode(payload))),
    );
    return _frame(header, seq, compressed);
  }

  static Uint8List newAudioOnlyRequest({
    required int seq,
    required Uint8List pcm,
    required bool isLast,
  }) {
    var useSeq = seq;
    final flags = isLast ? flagNegWithSequence : flagPosSequence;
    if (isLast) useSeq = -seq;
    final header = _requestHeader(
      messageType: msgClientAudioOnly,
      flags: flags,
    );
    final compressed = Uint8List.fromList(gzip.encode(pcm));
    return _frame(header, useSeq, compressed);
  }

  static DoubaoSaucResponse parseResponse(Uint8List msg) {
    final out = DoubaoSaucResponse();
    if (msg.length < 4) return out;

    final headerSize = msg[0] & 0x0f;
    final messageType = msg[1] >> 4;
    final flags = msg[1] & 0x0f;
    final serialization = msg[2] >> 4;
    final compression = msg[2] & 0x0f;

    var offset = headerSize * 4;
    if (offset > msg.length) return out;
    var payload = msg.sublist(offset);

    if ((flags & 0x01) != 0) {
      if (payload.length < 4) return out;
      out.payloadSequence = ByteData.sublistView(payload, 0, 4).getInt32(0);
      payload = payload.sublist(4);
    }
    if ((flags & 0x02) != 0) {
      out.isLastPackage = true;
    }
    if ((flags & 0x04) != 0) {
      if (payload.length < 4) return out;
      out.event = ByteData.sublistView(payload, 0, 4).getInt32(0);
      payload = payload.sublist(4);
    }

    if (messageType == msgServerFullResponse) {
      if (payload.length >= 4) {
        out.payloadSize = ByteData.sublistView(payload, 0, 4).getUint32(0);
        payload = payload.sublist(4);
      }
    } else if (messageType == msgServerErrorResponse) {
      out.isError = true;
      if (payload.length >= 8) {
        out.code = ByteData.sublistView(payload, 0, 4).getInt32(0);
        out.payloadSize = ByteData.sublistView(payload, 4, 8).getUint32(0);
        payload = payload.sublist(8);
      }
    }

    if (payload.isEmpty) return out;

    List<int> body = payload;
    if (compression == compressionGzip) {
      try {
        body = gzip.decode(payload);
      } catch (_) {
        return out;
      }
    }

    if (serialization == serializationJson) {
      try {
        final decoded = jsonDecode(utf8.decode(body));
        if (decoded is Map) {
          out.payloadMsg = Map<String, dynamic>.from(decoded);
        }
      } catch (_) {}
    }
    return out;
  }

  static String extractText(Map<String, dynamic>? payload) {
    if (payload == null) return '';
    for (final key in const [
      'asr_text',
      'text',
      'transcript',
      'sentence',
      'content',
      'recognition_text',
      'result_text',
      'utterance',
    ]) {
      final v = payload[key];
      if (v is String && v.trim().isNotEmpty) return v.trim();
    }
    final r = payload['result'];
    if (r is Map) {
      final nested = extractText(Map<String, dynamic>.from(r));
      if (nested.isNotEmpty) return nested;
    }
    if (r is String && r.trim().isNotEmpty) return r.trim();
    if (r is List) {
      final parts = <String>[];
      for (final item in r) {
        if (item is Map) {
          parts.add(extractText(Map<String, dynamic>.from(item)));
        } else if (item is String) {
          parts.add(item);
        }
      }
      final joined = parts.join().trim();
      if (joined.isNotEmpty) return joined;
    }
    final utterances = payload['utterances'] ?? payload['segments'];
    if (utterances is List) {
      final parts = <String>[];
      for (final u in utterances) {
        if (u is Map) {
          parts.add(
            (u['text'] ?? u['content'] ?? '').toString().trim(),
          );
        } else if (u is String) {
          parts.add(u.trim());
        }
      }
      final joined = parts.join().trim();
      if (joined.isNotEmpty) return joined;
    }
    return '';
  }

  static bool payloadIsFinal(Map<String, dynamic>? payload) {
    if (payload == null) return false;
    for (final key in const ['definite', 'is_final', 'final']) {
      final v = payload[key];
      if (v == true) return true;
    }
    final utterances = payload['utterances'];
    if (utterances is List) {
      for (final u in utterances) {
        if (u is Map) {
          for (final key in const ['definite', 'is_final', 'final']) {
            if (u[key] == true) return true;
          }
        }
      }
    }
    return false;
  }

  static Uint8List _requestHeader({
    required int messageType,
    required int flags,
  }) {
    return Uint8List.fromList([
      (protocolVersionV1 << 4) | 1,
      (messageType << 4) | flags,
      (serializationJson << 4) | compressionGzip,
      0x00,
    ]);
  }

  static Uint8List _frame(Uint8List header, int seq, Uint8List compressed) {
    final out = BytesBuilder(copy: false);
    out.add(header);
    final seqBd = ByteData(4)..setInt32(0, seq, Endian.big);
    out.add(seqBd.buffer.asUint8List());
    final sizeBd = ByteData(4)..setUint32(0, compressed.length, Endian.big);
    out.add(sizeBd.buffer.asUint8List());
    out.add(compressed);
    return out.toBytes();
  }

  static String _uuidV4() {
    final r = Random.secure();
    final bytes = List<int>.generate(16, (_) => r.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    String h(int i) => bytes[i].toRadixString(16).padLeft(2, '0');
    return '${h(0)}${h(1)}${h(2)}${h(3)}-'
        '${h(4)}${h(5)}-'
        '${h(6)}${h(7)}-'
        '${h(8)}${h(9)}-'
        '${h(10)}${h(11)}${h(12)}${h(13)}${h(14)}${h(15)}';
  }
}

class DoubaoSaucResponse {
  int code = 0;
  int event = 0;
  bool isError = false;
  bool isLastPackage = false;
  int payloadSequence = 0;
  int payloadSize = 0;
  Map<String, dynamic>? payloadMsg;
}
