import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:jideshi_hibi/features/profile/services/app_update_service.dart';
import 'package:package_info_plus/package_info_plus.dart';

Map<String, Object?> _asset(String name, int size) => {
      'name': name,
      'browser_download_url':
          'https://github.com/YYOZZE/HIBI/releases/download/HIBI-2023_v3.1.0/$name',
      'size': size,
    };

Map<String, Object?> _releaseJson({
  String tag = 'HIBI-2023_v3.1.0',
  String? name,
  String body = '',
  List<Map<String, Object?>>? assets,
}) =>
    {
      'tag_name': tag,
      if (name != null) 'name': name,
      'html_url': 'https://github.com/YYOZZE/HIBI/releases/tag/$tag',
      'published_at': '2026-08-01T12:00:00Z',
      'body': body,
      'assets': assets ??
          [
            _asset('Hibi2023_3.1.0.apk', 30 * 1024 * 1024),
            _asset('Hibi2023_Portable_3.1.0.exe', 40 * 1024 * 1024),
            _asset('Hibi2023_Setup_3.1.0.exe', 45 * 1024 * 1024),
            _asset('Hibi2023_3.1.0.AppImage', 42 * 1024 * 1024),
          ],
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Release JSON 解析', () {
    test('完整 Release：版本、各平台链接与大小', () {
      final m = AppUpdateManifest.fromGithubRelease(_releaseJson());
      expect(m, isNotNull);
      expect(m!.latestVersion, '3.1.0');
      expect(m.urls['android'], contains('Hibi2023_3.1.0.apk'));
      // 多个 exe 时优先 Setup 安装包
      expect(m.urls['windows'], contains('Setup'));
      expect(m.sizes['windows'], 45 * 1024 * 1024);
      expect(m.urls['linux'], contains('AppImage'));
      // iOS 无直装包，回退 Release 页面
      expect(m.urls['ios'],
          'https://github.com/YYOZZE/HIBI/releases/tag/HIBI-2023_v3.1.0');
      expect(m.updatedAt, greaterThan(0));
    });

    test('字母后缀版本 tag（HIBI-2023_v3.0.2B）', () {
      final m = AppUpdateManifest.fromGithubRelease(
          _releaseJson(tag: 'HIBI-2023_v3.0.2B'));
      expect(m!.latestVersion, '3.0.2B');
    });

    test('空 tag 回退 name 提取版本', () {
      final m = AppUpdateManifest.fromGithubRelease(
          _releaseJson(tag: '', name: 'HIBI-2023_v3.0.5'));
      expect(m!.latestVersion, '3.0.5');
    });

    test('非法 tag（纯文字）回退 name 提取版本', () {
      final m = AppUpdateManifest.fromGithubRelease(
          _releaseJson(tag: 'release-notes', name: 'HIBI-2023_v3.0.5'));
      expect(m, isNotNull,
          reason: 'tag 无版本号时应回退 name，而不是判定检查失败');
      expect(m!.latestVersion, '3.0.5');
    });

    test('tag 与 name 均无版本号 / null JSON 返回 null', () {
      expect(
          AppUpdateManifest.fromGithubRelease(
              _releaseJson(tag: 'foo', name: 'bar')),
          isNull);
      expect(AppUpdateManifest.fromGithubRelease(null), isNull);
    });

    test('Release notes 仅截取当前版本小节并去除 Markdown 标记', () {
      const body = '## V3.1.0\n'
          '\n'
          '**发布日期**：2026-08-01\n'
          '- 新增 **特性甲**\n'
          '- 修复问题乙\n'
          '\n'
          '## V3.0.9\n'
          '\n'
          '- 旧版本内容不应出现\n';
      final m =
          AppUpdateManifest.fromGithubRelease(_releaseJson(body: body));
      expect(m!.releaseNotes, contains('特性甲'));
      expect(m.releaseNotes, contains('修复问题乙'));
      expect(m.releaseNotes, isNot(contains('旧版本内容')));
      expect(m.releaseNotes, isNot(contains('##')));
      expect(m.releaseNotes, isNot(contains('**')));
      expect(m.releaseNotes, isNot(contains('发布日期')));
    });
  });

  group('版本号比较（边界补充）', () {
    test('补丁位按数值比较：3.0.9 < 3.0.16（字符串比较会错）', () {
      expect(AppUpdateService.compareSemanticVersion('3.0.9', '3.0.16'),
          isNegative);
      expect(AppUpdateService.compareSemanticVersion('3.0.16', '3.0.9'),
          isPositive);
    });

    test('build 号（+N）不参与比较', () {
      expect(AppUpdateService.compareSemanticVersion('3.1.0+49', '3.1.0+48'), 0);
      expect(AppUpdateService.compareSemanticVersion('3.1.0+49', '3.0.99'),
          isPositive);
      expect(AppUpdateService.compareSemanticVersion('3.1.0', '3.1.0+49'), 0);
    });

    test('字母后缀与非法输入', () {
      expect(AppUpdateService.compareSemanticVersion('3.0.2B', '3.0.3'),
          isNegative);
      expect(AppUpdateService.compareSemanticVersion('', '3.0.0'), isNegative);
      expect(
          AppUpdateService.compareSemanticVersion('abc', '3.0.0'), isNegative);
    });
  });

  group('checkSilently', () {
    setUp(() {
      PackageInfo.setMockInitialValues(
        appName: 'hibi',
        packageName: 'com.example.hibi',
        version: '3.0.16',
        buildNumber: '46',
        buildSignature: 'test',
      );
    });

    tearDown(() {
      AppUpdateService.debugCheckHttpGet = null;
      AppUpdateService.instance.statusNotifier.value = null;
    });

    test('发现新版本：updateAvailable 并写入 statusNotifier', () async {
      AppUpdateService.debugCheckHttpGet = (uri, headers) async {
        expect(uri.toString(), kUpdateGithubLatestApi);
        return http.Response(jsonEncode(_releaseJson()), 200);
      };
      final result = await AppUpdateService.instance.checkSilently();
      expect(result, AppUpdateCheckResult.updateAvailable);
      final st = AppUpdateService.instance.statusNotifier.value;
      expect(st, isNotNull);
      expect(st!.manifest.latestVersion, '3.1.0');
      expect(st.currentVersion, '3.0.16');
      expect(st.currentBuildNumber, '46');
      expect(st.updateAvailable, isTrue);
      expect(st.downloadUrlForPlatform, isNotNull);
      expect(st.assetSizeForPlatform, isNotNull);
    });

    test('远端版本相同或更旧：upToDate', () async {
      AppUpdateService.debugCheckHttpGet = (uri, headers) async =>
          http.Response(jsonEncode(_releaseJson(tag: 'HIBI-2023_v3.0.9')), 200);
      final result = await AppUpdateService.instance.checkSilently();
      expect(result, AppUpdateCheckResult.upToDate);
      final st = AppUpdateService.instance.statusNotifier.value;
      expect(st, isNotNull);
      expect(st!.updateAvailable, isFalse);
    });

    test('404（仓库尚无 Release）：视为已最新', () async {
      AppUpdateService.debugCheckHttpGet =
          (uri, headers) async => http.Response('Not Found', 404);
      final result = await AppUpdateService.instance.checkSilently();
      expect(result, AppUpdateCheckResult.upToDate);
      expect(AppUpdateService.instance.statusNotifier.value, isNull);
    });

    test('403 限流（X-RateLimit-Remaining: 0）：静默失败、不写状态、不抛异常', () async {
      AppUpdateService.debugCheckHttpGet = (uri, headers) async => http.Response(
            '{"message":"API rate limit exceeded"}',
            403,
            headers: {'x-ratelimit-remaining': '0'},
          );
      final result = await AppUpdateService.instance.checkSilently();
      expect(result, AppUpdateCheckResult.failed);
      // 静默失败：statusNotifier 保持 null，各入口不展示更新提示
      expect(AppUpdateService.instance.statusNotifier.value, isNull);
    });

    test('DNS 失败（SocketException）：静默失败', () async {
      AppUpdateService.debugCheckHttpGet = (uri, headers) async =>
          throw const SocketException('Failed host lookup: api.github.com');
      final result = await AppUpdateService.instance.checkSilently();
      expect(result, AppUpdateCheckResult.failed);
      expect(AppUpdateService.instance.statusNotifier.value, isNull);
    });

    test('非法 JSON 响应：静默失败', () async {
      AppUpdateService.debugCheckHttpGet =
          (uri, headers) async => http.Response('not-a-json', 200);
      final result = await AppUpdateService.instance.checkSilently();
      expect(result, AppUpdateCheckResult.failed);
      expect(AppUpdateService.instance.statusNotifier.value, isNull);
    });

    test('无有效版本的 Release：静默失败', () async {
      AppUpdateService.debugCheckHttpGet = (uri, headers) async => http.Response(
          jsonEncode(_releaseJson(tag: 'foo', name: 'bar')), 200);
      final result = await AppUpdateService.instance.checkSilently();
      expect(result, AppUpdateCheckResult.failed);
      expect(AppUpdateService.instance.statusNotifier.value, isNull);
    });

    test('并发调用复用同一次请求，状态只写入一次', () async {
      var hits = 0;
      AppUpdateService.debugCheckHttpGet = (uri, headers) async {
        hits++;
        await Future<void>.delayed(const Duration(milliseconds: 100));
        return http.Response(jsonEncode(_releaseJson()), 200);
      };
      var notifyCount = 0;
      void listener() => notifyCount++;
      AppUpdateService.instance.statusNotifier.addListener(listener);
      try {
        // 模拟多处并发触发静默检查
        final f1 = AppUpdateService.instance.checkSilently();
        final f2 = AppUpdateService.instance.checkSilently();
        expect(identical(f1, f2), isTrue, reason: '进行中的检查应复用同一 Future');
        final results = await Future.wait([f1, f2]);
        expect(results, [
          AppUpdateCheckResult.updateAvailable,
          AppUpdateCheckResult.updateAvailable,
        ]);
        expect(hits, 1, reason: '并发检查只应发出一次请求');
        expect(notifyCount, 1, reason: 'statusNotifier 应只写入一次，避免状态错乱');
      } finally {
        AppUpdateService.instance.statusNotifier.removeListener(listener);
      }
      // 检查完成后允许再次发起新检查
      await AppUpdateService.instance.checkSilently();
      expect(hits, 2);
    });
  });

  group('checkManually（细粒度结果）', () {
    setUp(() {
      PackageInfo.setMockInitialValues(
        appName: 'hibi',
        packageName: 'com.example.hibi',
        version: '3.0.16',
        buildNumber: '46',
        buildSignature: 'test',
      );
    });

    tearDown(() {
      AppUpdateService.debugCheckHttpGet = null;
      AppUpdateService.instance.statusNotifier.value = null;
    });

    test('发现新版本：updateAvailable 并写入 statusNotifier', () async {
      AppUpdateService.debugCheckHttpGet = (uri, headers) async =>
          http.Response(jsonEncode(_releaseJson()), 200);
      final result = await AppUpdateService.instance.checkManually();
      expect(result, AppUpdateManualCheckResult.updateAvailable);
      final st = AppUpdateService.instance.statusNotifier.value;
      expect(st, isNotNull);
      expect(st!.updateAvailable, isTrue);
      expect(st.manifest.latestVersion, '3.1.0');
    });

    test('远端版本相同或更旧：upToDate', () async {
      AppUpdateService.debugCheckHttpGet = (uri, headers) async =>
          http.Response(jsonEncode(_releaseJson(tag: 'HIBI-2023_v3.0.9')), 200);
      final result = await AppUpdateService.instance.checkManually();
      expect(result, AppUpdateManualCheckResult.upToDate);
    });

    test('403 限流：rateLimited（供 UI 提示「检查过于频繁」）', () async {
      AppUpdateService.debugCheckHttpGet = (uri, headers) async => http.Response(
            '{"message":"API rate limit exceeded"}',
            403,
            headers: {'x-ratelimit-remaining': '0'},
          );
      final result = await AppUpdateService.instance.checkManually();
      expect(result, AppUpdateManualCheckResult.rateLimited);
      expect(AppUpdateService.instance.statusNotifier.value, isNull);
    });

    test('网络层失败（SocketException）：networkFailed', () async {
      AppUpdateService.debugCheckHttpGet = (uri, headers) async =>
          throw const SocketException('Failed host lookup: api.github.com');
      final result = await AppUpdateService.instance.checkManually();
      expect(result, AppUpdateManualCheckResult.networkFailed);
      expect(AppUpdateService.instance.statusNotifier.value, isNull);
    });

    test('其他失败（非法 JSON）：failed', () async {
      AppUpdateService.debugCheckHttpGet =
          (uri, headers) async => http.Response('not-a-json', 200);
      final result = await AppUpdateService.instance.checkManually();
      expect(result, AppUpdateManualCheckResult.failed);
    });

    test('手动与静默检查并发：共享同一次请求，各自拿到对应粒度结果', () async {
      var hits = 0;
      AppUpdateService.debugCheckHttpGet = (uri, headers) async {
        hits++;
        await Future<void>.delayed(const Duration(milliseconds: 100));
        return http.Response(
          '{"message":"API rate limit exceeded"}',
          403,
          headers: {'x-ratelimit-remaining': '0'},
        );
      };
      final silentFuture = AppUpdateService.instance.checkSilently();
      final manualFuture = AppUpdateService.instance.checkManually();
      final results = await Future.wait([silentFuture, manualFuture]);
      expect(hits, 1, reason: '并发检查只应发出一次请求');
      // 静默版语义不变：任何失败都收敛为 failed；手动版保留限流细节
      expect(results[0], AppUpdateCheckResult.failed);
      expect(results[1], AppUpdateManualCheckResult.rateLimited);
    });
  });
}
