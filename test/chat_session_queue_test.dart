import 'package:flutter_test/flutter_test.dart';
import 'package:jideshi_hibi/features/assistant/services/chat_session_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('无进行中请求时 cancelCurrent 返回 false', () {
    final session = ChatSessionService.instance;
    expect(session.cancelCurrent('agent_not_running'), isFalse);
    expect(session.isLoading('agent_not_running'), isFalse);
    expect(session.queueDepth('agent_not_running'), 0);
  });

  test('loading / revision / queueDepth notifier 可订阅', () {
    final session = ChatSessionService.instance;
    const id = 'agent_notifier_smoke';
    expect(session.loadingOf(id).value, isFalse);
    expect(session.revisionOf(id).value, isA<int>());
    expect(session.queueDepthOf(id).value, 0);
  });
}
