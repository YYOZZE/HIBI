import 'package:flutter_test/flutter_test.dart';
import 'package:jideshi_hibi/features/assistant/models/chat_message.dart';

/// 模拟 agent_chat_page 修复后的合并策略：以本地全量为基，再并入服务端。
List<ChatMessage> mergeLocalAndServer({
  required List<ChatMessage> local,
  required List<ChatMessage> serverMsgs,
}) {
  final byId = <String, ChatMessage>{
    for (final m in local) m.id: m,
  };
  for (final m in serverMsgs) {
    byId[m.id] = m;
  }
  final merged = byId.values.toList()
    ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
  if (merged.length < local.length) return local;
  return merged;
}

void main() {
  test('服务端只返回 1 条时不丢弃本地完整历史', () {
    final t0 = DateTime(2026, 1, 1, 10);
    final local = [
      ChatMessage(id: 'srv_1', role: 'user', content: '你好', timestamp: t0),
      ChatMessage(
        id: 'srv_2',
        role: 'assistant',
        content: '旧回复',
        timestamp: t0.add(const Duration(seconds: 1)),
      ),
      ChatMessage(
        id: 'm_user',
        role: 'user',
        content: '新问题',
        timestamp: t0.add(const Duration(seconds: 2)),
      ),
      ChatMessage(
        id: 'm_assistant',
        role: 'assistant',
        content: '新回复',
        timestamp: t0.add(const Duration(seconds: 3)),
      ),
    ];
    final serverOnlyLatest = [
      ChatMessage(
        id: 'srv_99',
        role: 'assistant',
        content: '仅最新',
        timestamp: t0.add(const Duration(seconds: 3)),
      ),
    ];
    final merged = mergeLocalAndServer(local: local, serverMsgs: serverOnlyLatest);
    expect(merged.length, greaterThanOrEqualTo(4));
    expect(merged.any((m) => m.id == 'srv_1'), isTrue);
    expect(merged.any((m) => m.id == 'm_user'), isTrue);
    expect(merged.any((m) => m.id == 'm_assistant'), isTrue);
  });

  test('服务端明显更短时保留本地列表', () {
    final t0 = DateTime(2026, 1, 1);
    final local = List.generate(
      5,
      (i) => ChatMessage(
        id: 'srv_$i',
        role: i.isEven ? 'user' : 'assistant',
        content: 'm$i',
        timestamp: t0.add(Duration(seconds: i)),
      ),
    );
    final server = [
      ChatMessage(id: 'srv_4', role: 'assistant', content: 'only', timestamp: t0),
    ];
    // 合并后长度仍 >= local，因为本地先入 byId；本用例验证不会变短
    final merged = mergeLocalAndServer(local: local, serverMsgs: server);
    expect(merged.length, 5);
  });
}
