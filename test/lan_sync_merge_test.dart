import 'package:flutter_test/flutter_test.dart';
import 'package:jideshi_hibi/features/auth/services/sync_merge.dart';

void main() {
  group('SyncMerge LWW for lan sync', () {
    test('mind 按 updatedAt 保留较新', () {
      final local = [
        {
          'id': 'a',
          'title': '旧',
          'updatedAt': '2026-01-01T00:00:00.000',
        },
      ];
      final remote = [
        {
          'id': 'a',
          'title': '新',
          'updatedAt': '2026-08-01T00:00:00.000',
        },
        {
          'id': 'b',
          'title': '仅远端',
          'updatedAt': '2026-08-01T00:00:00.000',
        },
      ];
      final merged = SyncMerge.mergeMindLists(local, remote);
      expect(merged.length, 2);
      final a = merged.cast<Map>().firstWhere((e) => e['id'] == 'a');
      expect(a['title'], '新');
    });

    test('schedule 按 mtime LWW，旧数据不覆盖新数据', () {
      final local = [
        {
          'id': 's1',
          'title': '本地新',
          'updatedAt': '2026-08-08T12:00:00.000',
          'startTime': '2026-08-08T10:00:00.000',
        },
      ];
      final remote = [
        {
          'id': 's1',
          'title': '远端旧',
          'updatedAt': '2026-08-01T12:00:00.000',
          'startTime': '2026-08-01T10:00:00.000',
        },
      ];
      final merged = SyncMerge.mergeScheduleListsByMtime(local, remote);
      expect(merged.length, 1);
      expect((merged.first as Map)['title'], '本地新');
    });

    test('schedule 无 updatedAt 时回退 startTime', () {
      final a = [
        {
          'id': 's1',
          'title': 'A',
          'startTime': '2026-08-08T10:00:00.000',
        },
      ];
      final b = [
        {
          'id': 's1',
          'title': 'B',
          'startTime': '2026-07-01T10:00:00.000',
        },
      ];
      final merged = SyncMerge.mergeScheduleListsByMtime(a, b);
      expect((merged.first as Map)['title'], 'A');
    });
  });
}
