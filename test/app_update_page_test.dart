import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jideshi_hibi/app/app_theme_extension.dart';
import 'package:jideshi_hibi/app/theme_notifier.dart';
import 'package:jideshi_hibi/features/profile/app_update_page.dart';
import 'package:jideshi_hibi/features/profile/services/app_update_service.dart';
// 仅测试使用的桩实现，避免为此修改 pubspec.yaml
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.tempPath);

  final String tempPath;

  @override
  Future<String?> getTemporaryPath() async => tempPath;
}

/// 闸门式下载服务器：先发 256KB 让客户端进入下载中，随后停住，
/// 由测试调用 [open] 放行剩余数据。用于确定性模拟「下载中退出页面」。
class _GatedDownloadServer {
  HttpServer? _server;
  Completer<void>? _gate;

  final int totalBytes = 2 * 1024 * 1024;
  static const int _headBytes = 256 * 1024;

  Future<Uri> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen((request) async {
      final response = request.response;
      response.headers.set(HttpHeaders.contentLengthHeader, totalBytes);
      try {
        response.add(List<int>.filled(_headBytes, 7));
        await response.flush();
        final gate = _gate = Completer<void>();
        await gate.future;
        var sent = _headBytes;
        while (sent < totalBytes) {
          final n =
              (sent + 65536 <= totalBytes) ? 65536 : totalBytes - sent;
          response.add(List<int>.filled(n, sent % 251));
          sent += n;
          await response.flush();
        }
        await response.close();
      } catch (_) {
        // 客户端中断
      }
    });
    return Uri.parse('http://127.0.0.1:${server.port}/Hibi2023_Setup_9.9.9.exe');
  }

  void open() => _gate?.complete();

  Future<void> dispose() async {
    await _server?.close(force: true);
  }
}

AppUpdateStatus _statusFor(String url, int size) => AppUpdateStatus(
      currentVersion: '3.0.16',
      currentBuildNumber: '46',
      manifest: const AppUpdateManifest(
        latestVersion: '9.9.9',
        releaseNotes: '测试更新内容',
        urls: {},
        sizes: {},
        releasePageUrl: 'https://github.com/YYOZZE/HIBI/releases',
      ),
      updateAvailable: true,
      downloadUrlForPlatform: url,
      assetSizeForPlatform: size,
    );

Widget _wrap(Widget child) => MaterialApp(
      // 纯色背景主题：避免 FrostedBackground 在测试中加载图片资源
      theme: ThemeData(extensions: const [
        HibiThemeExtension(
          themeId: AppThemeId.dark,
          useImageBackground: false,
          solidBackgroundColor: Color(0xFF121212),
        ),
      ]),
      home: child,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    HttpOverrides.global = null;
    AppUpdateDownloadTask.debugDisableKeepAlive = true;
    AppUpdateDownloadTask.debugMaxAutoRetries = 0;
    AppUpdateDownloadTask.debugProbeCandidates = false;
  });

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('hibi_update_page_test_');
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir.path);
    AppUpdateDownloadTask.debugDisableKeepAlive = true;
    AppUpdateDownloadTask.debugMaxAutoRetries = 0;
    AppUpdateDownloadTask.debugProbeCandidates = false;
  });

  tearDown(() async {
    AppUpdateService.instance.debugClearActiveDownloadTask();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  testWidgets('下载中退出更新页：后台续传不取消，重进恢复进度展示', (tester) async {
    final server = _GatedDownloadServer();
    addTearDown(server.dispose);

    await tester.runAsync(() async {
      // 服务器必须在 runAsync 真实异步域内启动：
      // 否则 listen 回调落在 FakeAsync zone，flush 续体被伪微任务队列卡住
      final url = await server.start();
      final status = _statusFor(url.toString(), server.totalBytes);
      await tester.pumpWidget(_wrap(AppUpdatePage(status: status)));
      await tester.pump();
      expect(find.text('开始下载'), findsOneWidget);

      // 与页面 initState 复用同一任务句柄
      final task =
          AppUpdateService.instance.createDownloadTask(url.toString());
      expect(task.progressNotifier.value.state, AppUpdateDownloadState.idle);

      await tester.ensureVisible(find.text('开始下载'));
      await tester.tap(find.text('开始下载'));
      await tester.pump();

      // 进入下载中并收到首批 256KB（服务器闸门关闭，停在此处）
      await _waitFor(
          () =>
              task.progressNotifier.value.state ==
                  AppUpdateDownloadState.downloading &&
              task.progressNotifier.value.downloadedBytes > 0,
          onTimeout: () =>
              'state=${task.progressNotifier.value.state} '
              'bytes=${task.progressNotifier.value.downloadedBytes} '
              'msg=${task.progressNotifier.value.message}');
      await tester.pump();
      expect(find.text('下载中...'), findsOneWidget);

      // 退出更新页：任务应保持下载中（后台续传，不被取消）；
      // 若存在 setState-after-dispose，Flutter 框架会抛异常使本用例失败
      await tester.pumpWidget(_wrap(const Scaffold(body: Text('其他页面'))));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(task.progressNotifier.value.state,
          AppUpdateDownloadState.downloading,
          reason: '页面退出不应取消进行中的下载');

      // 重新进入：复用同一任务，恢复实时进度展示
      await tester.pumpWidget(_wrap(AppUpdatePage(status: status)));
      await tester.pump();
      expect(find.text('下载中...'), findsOneWidget);
      expect(find.textContaining('/ 2.00MB'), findsOneWidget,
          reason: '重进后应展示已下载进度而非回到「准备下载」');

      // 放行剩余数据 → 完成 → 显示安装入口
      server.open();
      await _waitFor(() =>
          task.progressNotifier.value.state ==
          AppUpdateDownloadState.completed);
      await tester.pump();
      expect(find.text('下载完成'), findsOneWidget);
      expect(find.text('安装'), findsOneWidget);
      expect(find.text('2.00MB / 2.00MB（100%）'), findsOneWidget);
    });
  });
}

Future<void> _waitFor(bool Function() condition,
    {Duration timeout = const Duration(seconds: 10),
    String Function()? onTimeout}) async {
  final sw = Stopwatch()..start();
  while (!condition()) {
    if (sw.elapsed > timeout) {
      fail('等待条件超时${onTimeout != null ? '：${onTimeout()}' : ''}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
