import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:jideshi_hibi/app/app_theme_extension.dart';
import 'package:jideshi_hibi/app/theme_notifier.dart';
import 'package:jideshi_hibi/features/profile/about_version_page.dart';
import 'package:jideshi_hibi/features/profile/app_update_page.dart';
import 'package:jideshi_hibi/features/profile/services/app_update_service.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// 1x1 透明 PNG：顶替关于页 Logo 等 Image.asset 的资源加载
final Uint8List _transparentPng = Uint8List.fromList(const <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

class _MockAssetBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async {
    // 资产清单需返回合法编码（空清单），图片资源一律返回 1x1 透明 PNG
    if (key.contains('AssetManifest')) {
      return const StandardMessageCodec()
          .encodeMessage(<Object?, Object?>{})!;
    }
    return ByteData.view(_transparentPng.buffer);
  }

  @override
  Future<String> loadString(String key, {bool cache = true}) async => '{}';
}

Map<String, Object?> _releaseJson({String tag = 'HIBI-2023_v9.9.9'}) => {
      'tag_name': tag,
      'html_url': 'https://github.com/YYOZZE/HIBI/releases/tag/$tag',
      'published_at': '2026-08-01T12:00:00Z',
      'body': '## V9.9.9\n\n- 测试更新内容\n',
      'assets': [
        {
          'name': 'Hibi2023_Setup_9.9.9.exe',
          'browser_download_url':
              'https://github.com/YYOZZE/HIBI/releases/download/$tag/Hibi2023_Setup_9.9.9.exe',
          'size': 45 * 1024 * 1024,
        },
      ],
    };

/// body 含中文时必须用字节构造（http.Response(String) 按 latin1 编码会抛异常）
http.Response _jsonResponse(Map<String, Object?> json, [int status = 200]) =>
    http.Response.bytes(utf8.encode(jsonEncode(json)), status);

Widget _wrap(Widget child) => MaterialApp(
      // 纯色背景主题：避免 FrostedBackground 在测试中加载图片资源
      theme: ThemeData(extensions: const [
        HibiThemeExtension(
          themeId: AppThemeId.dark,
          useImageBackground: false,
          solidBackgroundColor: Color(0xFF121212),
        ),
      ]),
      home: DefaultAssetBundle(bundle: _MockAssetBundle(), child: child),
    );

Future<void> _tapCheckButton(WidgetTester tester) async {
  await tester.ensureVisible(find.text('检查更新'));
  await tester.tap(find.text('检查更新'));
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
    AppUpdateService.instance.debugClearActiveDownloadTask();
  });

  testWidgets('进入页面不自动检查更新，显示「尚未检查更新」', (tester) async {
    var hits = 0;
    AppUpdateService.debugCheckHttpGet = (uri, headers) async {
      hits++;
      return _jsonResponse(_releaseJson());
    };
    await tester.pumpWidget(_wrap(const AboutVersionPage()));
    await tester.pumpAndSettle();
    expect(hits, 0, reason: '更新检查仅由用户手动触发，进入页面不得发起请求');
    expect(find.text('尚未检查更新'), findsOneWidget);
    expect(find.text('检查更新'), findsOneWidget);
  });

  testWidgets('手动检查有更新：弹「发现新版本」对话框，稍后可关闭', (tester) async {
    AppUpdateService.debugCheckHttpGet = (uri, headers) async =>
        _jsonResponse(_releaseJson());
    await tester.pumpWidget(_wrap(const AboutVersionPage()));
    await tester.pumpAndSettle();

    await _tapCheckButton(tester);
    await tester.pumpAndSettle();

    // 对话框内容（自定义 Dialog，不透明实底）
    final dialog = find.byType(Dialog);
    expect(dialog, findsOneWidget);
    expect(
      find.descendant(of: dialog, matching: find.text('发现新版本')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: dialog, matching: find.text('V9.9.9')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: dialog, matching: find.textContaining('当前 ')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: dialog, matching: find.text('更新说明')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: dialog, matching: find.text('立即更新')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: dialog, matching: find.text('稍后')),
      findsOneWidget,
    );
    // 状态卡片同步展示更新徽标（页面上也有「立即更新」）
    expect(find.textContaining('发现新版本 V 9.9.9'), findsOneWidget);

    await tester.tap(find.descendant(of: dialog, matching: find.text('稍后')));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
  });

  testWidgets('对话框「立即更新」跳转下载流程页', (tester) async {
    AppUpdateService.debugCheckHttpGet = (uri, headers) async =>
        _jsonResponse(_releaseJson());
    await tester.pumpWidget(_wrap(const AboutVersionPage()));
    await tester.pumpAndSettle();

    await _tapCheckButton(tester);
    await tester.pumpAndSettle();
    final updateButton = find.descendant(
      of: find.byType(Dialog),
      matching: find.widgetWithText(FilledButton, '立即更新'),
    );
    expect(updateButton, findsOneWidget);
    await tester.tap(updateButton);
    await tester.pumpAndSettle();
    expect(find.byType(AppUpdatePage), findsOneWidget);
    expect(find.text('开始下载'), findsOneWidget);
  });

  testWidgets('已是最新：SnackBar 提示「当前已是最新版本」', (tester) async {
    AppUpdateService.debugCheckHttpGet = (uri, headers) async =>
        _jsonResponse(_releaseJson(tag: 'HIBI-2023_v3.0.9'));
    await tester.pumpWidget(_wrap(const AboutVersionPage()));
    await tester.pumpAndSettle();

    await _tapCheckButton(tester);
    await tester.pumpAndSettle();

    expect(find.text('立即更新'), findsNothing);
    // 状态卡片与 SnackBar 都会展示该文案，这里验证 SnackBar 提示
    expect(
      find.descendant(
        of: find.byType(SnackBar),
        matching: find.text('当前已是最新版本'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('403 限流：SnackBar 提示「检查过于频繁，请稍后再试」', (tester) async {
    AppUpdateService.debugCheckHttpGet = (uri, headers) async => http.Response(
          '{"message":"API rate limit exceeded"}',
          403,
          headers: {'x-ratelimit-remaining': '0'},
        );
    await tester.pumpWidget(_wrap(const AboutVersionPage()));
    await tester.pumpAndSettle();

    await _tapCheckButton(tester);
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsNothing);
    expect(find.text('检查过于频繁，请稍后再试'), findsOneWidget);
  });

  testWidgets('网络失败：SnackBar 提示检查网络后重试', (tester) async {
    AppUpdateService.debugCheckHttpGet = (uri, headers) async =>
        throw const SocketException('Failed host lookup: api.github.com');
    await tester.pumpWidget(_wrap(const AboutVersionPage()));
    await tester.pumpAndSettle();

    await _tapCheckButton(tester);
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsNothing);
    expect(find.text('检查失败，请检查网络后重试'), findsOneWidget);
  });

  testWidgets('防连点：检查中按钮禁用，重复点击只发一次请求', (tester) async {
    final gate = Completer<http.Response>();
    var hits = 0;
    AppUpdateService.debugCheckHttpGet = (uri, headers) {
      hits++;
      return gate.future;
    };
    await tester.pumpWidget(_wrap(const AboutVersionPage()));
    await tester.pumpAndSettle();

    await _tapCheckButton(tester);
    expect(find.text('检查中…'), findsOneWidget);
    // OutlinedButton.icon 生成私有子类，find.byType 精确匹配不到，改用谓词
    final button = tester.widget<OutlinedButton>(
      find.byWidgetPredicate((w) => w is OutlinedButton),
    );
    expect(button.onPressed, isNull, reason: '检查中按钮应禁用');

    // 检查未返回时再次点击：守卫挡下，不追加请求
    await tester.tap(find.text('检查中…'));
    await tester.pump();
    expect(hits, 1);

    gate.complete(_jsonResponse(_releaseJson()));
    await tester.pumpAndSettle();
    expect(hits, 1);
    expect(find.byType(Dialog), findsOneWidget);
  });
}
