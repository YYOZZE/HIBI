import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jideshi_hibi/features/assistant/services/doubao_sauc_protocol.dart';

void main() {
  group('DoubaoSaucProtocol', () {
    test('鉴权头含 App-Key / Access-Key / Resource-Id', () {
      final h = DoubaoSaucProtocol.buildAuthHeaders(
        appId: '1234567890',
        accessToken: 'token-abc',
        resourceId: 'volc.bigasr.sauc.duration',
      );
      expect(h['X-Api-App-Key'], '1234567890');
      expect(h['X-Api-Access-Key'], 'token-abc');
      expect(h['X-Api-Resource-Id'], 'volc.bigasr.sauc.duration');
      expect(h['X-Api-Request-Id'], isNotEmpty);
    });

    test('full client request 可编码且 header 合法', () {
      final frame = DoubaoSaucProtocol.newFullClientRequest(seq: 1);
      expect(frame.length, greaterThan(20));
      expect(frame[0] >> 4, DoubaoSaucProtocol.protocolVersionV1);
      expect(frame[1] >> 4, DoubaoSaucProtocol.msgClientFullRequest);
    });

    test('audio-only 收尾包使用负序号 flag', () {
      final frame = DoubaoSaucProtocol.newAudioOnlyRequest(
        seq: 3,
        pcm: Uint8List.fromList([0, 1, 2, 3]),
        isLast: true,
      );
      expect(frame[1] >> 4, DoubaoSaucProtocol.msgClientAudioOnly);
      expect(
        frame[1] & 0x0f,
        DoubaoSaucProtocol.flagNegWithSequence,
      );
    });

    test('extractText 解析嵌套 result', () {
      final text = DoubaoSaucProtocol.extractText({
        'result': {
          'text': '你好世界',
        },
      });
      expect(text, '你好世界');
    });
  });
}
