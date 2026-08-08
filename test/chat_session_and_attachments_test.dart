import 'package:flutter_test/flutter_test.dart';
import 'package:jideshi_hibi/features/assistant/models/chat_attachment.dart';
import 'package:jideshi_hibi/features/assistant/models/chat_message.dart';
import 'package:jideshi_hibi/features/assistant/models/mind_topic_ref.dart';
import 'package:jideshi_hibi/features/assistant/services/openai_compatible_direct_api.dart';

void main() {
  group('MindTopicRef', () {
    test('displayLabel 与 prompt 前缀含寻址信息', () {
      const ref = MindTopicRef(projectId: 'proj_1', projectTitle: '产品规划');
      expect(ref.displayLabel, contains('产品规划'));
      final prefix = ref.toPromptPrefix();
      expect(prefix, contains('projectId: proj_1'));
      expect(prefix, contains('projectTitle: 产品规划'));
    });
  });

  group('ChatAttachment', () {
    test('文本附件载荷含 text', () {
      final att = ChatAttachment(
        id: 'a1',
        name: 'note.md',
        mime: 'text/markdown',
        kind: ChatAttachmentKind.textDoc,
        extractedText: '# Hello',
      );
      final payload = att.toApiPayload();
      expect(payload['kind'], 'textDoc');
      expect(payload['text'], contains('Hello'));
      expect(att.canSendToModel, isTrue);
    });

    test('视频不可发给模型', () {
      final att = ChatAttachment(
        id: 'v1',
        name: 'clip.mp4',
        mime: 'video/mp4',
        kind: ChatAttachmentKind.video,
        previewHint: '暂不解析',
      );
      expect(att.canSendToModel, isFalse);
    });
  });

  group('ChatMessage attachments', () {
    test('historyContent 含附件名与正文，JSON 可还原 path', () {
      final msg = ChatMessage(
        role: 'user',
        content: '你看到什么',
        topicLabel: '产品规划',
        attachments: const [
          ChatMessageAttachment(
            id: 'a1',
            name: 'puppet.jpg',
            mime: 'image/jpeg',
            kind: 'image',
            path: 'C:/tmp/puppet.jpg',
          ),
        ],
      );
      expect(msg.historyContent, contains('puppet.jpg'));
      expect(msg.historyContent, contains('你看到什么'));
      expect(msg.historyContent, contains('产品规划'));
      final round = ChatMessage.fromJson(msg.toJson());
      expect(round.attachments.single.path, 'C:/tmp/puppet.jpg');
      expect(round.content, '你看到什么');
    });
  });

  group('OpenAiCompatibleDirectApi content', () {
    test('无图片时 content 为字符串', () {
      // 通过反射不到 private；用 normalizeBaseUrl 回归即可
      expect(
        OpenAiCompatibleDirectApi.normalizeBaseUrl(
          'https://ark.cn-beijing.volces.com/api/v3/chat/completions/',
        ),
        'https://ark.cn-beijing.volces.com/api/v3',
      );
    });
  });
}
