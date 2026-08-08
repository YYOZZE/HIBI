import 'package:flutter_test/flutter_test.dart';
import 'package:jideshi_hibi/features/assistant/services/client_abp/client_abp_executor.dart';
import 'package:jideshi_hibi/features/assistant/services/client_abp/client_abp_runtime.dart';

void main() {
  group('clientAbpTools', () {
    test('固定小套含日程与思维工具', () {
      final names = clientAbpTools()
          .map((t) => (t['function'] as Map)['name'] as String)
          .toList();
      expect(names, containsAll(['create_schedule', 'get_mind_canvas', 'get_schedule']));
      expect(names.length, 7);
      expect(kClientAbpDefaultReminderMinutes, 15);
    });
  });

  group('clientAbpSystemPrompt', () {
    test('含当前时间与严禁幻觉约束', () {
      final p = clientAbpSystemPrompt(
        agentName: '希比助手',
        agentRole: '测试角色',
      );
      expect(p, contains('希比助手'));
      expect(p, contains('严禁幻觉'));
      expect(p, contains('Asia/Shanghai'));
    });
  });
}
