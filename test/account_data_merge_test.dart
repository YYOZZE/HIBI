import 'package:flutter_test/flutter_test.dart';
import 'package:jideshi_hibi/features/auth/services/sync_merge.dart';

/// 账号目录合并策略与 SyncMerge / LAN 一致的回归用例。
void main() {
  group('account → GitHub merge strategy', () {
    test('mind 按 updatedAt LWW，保留两侧独有节点', () {
      final github = [
        {
          'id': 'a',
          'title': 'gh旧',
          'updatedAt': '2026-01-01T00:00:00.000',
        },
        {
          'id': 'g1',
          'title': '仅GitHub',
          'updatedAt': '2026-08-01T00:00:00.000',
        },
      ];
      final local = [
        {
          'id': 'a',
          'title': 'local新',
          'updatedAt': '2026-08-08T00:00:00.000',
        },
        {
          'id': 'l1',
          'title': '仅本地',
          'updatedAt': '2026-08-08T00:00:00.000',
        },
      ];
      final merged = SyncMerge.mergeMindLists(github, local);
      expect(merged.length, 3);
      final a = merged.cast<Map>().firstWhere((e) => e['id'] == 'a');
      expect(a['title'], 'local新');
      expect(merged.cast<Map>().any((e) => e['id'] == 'l1'), isTrue);
      expect(merged.cast<Map>().any((e) => e['id'] == 'g1'), isTrue);
    });

    test('schedule 按 mtime LWW', () {
      final github = [
        {
          'id': 's1',
          'title': 'gh',
          'updatedAt': '2026-08-01T00:00:00.000',
        },
      ];
      final local = [
        {
          'id': 's1',
          'title': 'local',
          'updatedAt': '2026-08-09T00:00:00.000',
        },
      ];
      final merged = SyncMerge.mergeScheduleListsByMtime(github, local);
      expect((merged.first as Map)['title'], 'local');
    });

    test('assistant：目标 agents 同 id 优先，messages 去重拼接', () {
      final github = {
        'agents': [
          {'id': 'bot', 'name': 'GitHub名', 'role': 'g'},
        ],
        'messages': {
          'bot': [
            {
              'role': 'user',
              'content': 'hi',
              'timestamp': '2026-08-01T00:00:00.000',
            },
          ],
        },
      };
      final local = {
        'agents': [
          {'id': 'bot', 'name': '本地名', 'role': 'l'},
          {'id': 'extra', 'name': '本地新建', 'role': 'x'},
        ],
        'messages': {
          'bot': [
            {
              'role': 'user',
              'content': 'hi',
              'timestamp': '2026-08-01T00:00:00.000',
            },
            {
              'role': 'assistant',
              'content': '本地回复',
              'timestamp': '2026-08-02T00:00:00.000',
            },
          ],
        },
      };
      // 与 AccountDataMergeService / LocalAccountImport 一致：目标作 local 侧
      final merged = SyncMerge.mergeAssistant(github, local);
      final agents = (merged['agents'] as List).cast<Map>();
      final bot = agents.firstWhere((e) => e['id'] == 'bot');
      expect(bot['name'], 'GitHub名');
      expect(agents.any((e) => e['id'] == 'extra'), isTrue);
      final msgs = (merged['messages'] as Map)['bot'] as List;
      expect(msgs.length, 2);
    });
  });
}
