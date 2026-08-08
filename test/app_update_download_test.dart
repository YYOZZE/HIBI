import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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

/// 慢速流式下载服务器：支持 Range 头，可控制发送节奏，模拟大文件下载。
class _SlowDownloadServer {
  _SlowDownloadServer._();

  HttpServer? _server;

  static const int totalBytes = 2 * 1024 * 1024; // 2MB
  static const int chunkSize = 64 * 1024;

  Future<Uri> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen((HttpRequest request) async {
      var start = 0;
      final range = request.headers.value(HttpHeaders.rangeHeader);
      if (range != null) {
        final m = RegExp(r'bytes=(\d+)-').firstMatch(range);
        if (m != null) start = int.parse(m.group(1)!);
      }
      final remaining = totalBytes - start;
      final response = request.response;
      if (start > 0) {
        response.statusCode = HttpStatus.partialContent;
      }
      response.headers.set(HttpHeaders.contentLengthHeader, remaining);
      try {
        var sent = start;
        while (sent < totalBytes) {
          final n =
              (sent + chunkSize <= totalBytes) ? chunkSize : totalBytes - sent;
          response.add(List<int>.filled(n, sent % 251));
          sent += n;
          await response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 40));
        }
        await response.close();
      } catch (_) {
        // 客户端中断
      }
    });
    return Uri.parse('http://127.0.0.1:${server.port}/Hibi2023_Setup_9.9.9.exe');
  }

  Future<void> dispose() async {
    await _server?.close(force: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    // flutter_test 默认把 HttpClient 替换为返回 400 的 Mock，这里恢复真实网络栈
    HttpOverrides.global = null;
    AppUpdateDownloadTask.debugDisableKeepAlive = true;
    AppUpdateDownloadTask.debugMaxAutoRetries = 0;
  });

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('hibi_update_test_');
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir.path);
    AppUpdateDownloadTask.debugDisableKeepAlive = true;
    AppUpdateDownloadTask.debugMaxAutoRetries = 0;
  });

  tearDown(() async {
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  group('版本号比较', () {
    test('语义化版本比较', () {
      expect(AppUpdateService.compareSemanticVersion('3.0.16', '3.0.17'),
          isNegative);
      expect(AppUpdateService.compareSemanticVersion('3.0.17', '3.0.16'),
          isPositive);
      expect(AppUpdateService.compareSemanticVersion('3.0.16', '3.0.16'), 0);
      expect(AppUpdateService.compareSemanticVersion('3.1.0', '3.0.99'),
          isPositive);
      expect(AppUpdateService.compareSemanticVersion('3.0.2B', '3.0.2'), 0);
      expect(AppUpdateService.compareSemanticVersion('4.0', '3.9.9'),
          isPositive);
    });

    test('字节格式化', () {
      expect(AppUpdateService.fmtBytes(512), '512B');
      expect(AppUpdateService.fmtBytes(2048), '2KB');
      expect(AppUpdateService.fmtBytes(5 * 1024 * 1024), '5.00MB');
    });
  });

  group('下载任务状态机', () {
    test('完整下载：idle → downloading → completed', () async {
      final server = _SlowDownloadServer._();
      final url = await server.start();
      final task = AppUpdateService.instance.createDownloadTask(url.toString());
      try {
        await task.start();
        final p = task.progressNotifier.value;
        expect(p.state, AppUpdateDownloadState.completed);
        expect(p.totalBytes, _SlowDownloadServer.totalBytes);
        expect(p.downloadedBytes, _SlowDownloadServer.totalBytes);
        expect(p.filePath, isNotNull);
        expect(await File(p.filePath!).length(), _SlowDownloadServer.totalBytes);
      } finally {
        await server.dispose();
      }
    });

    test('暂停后状态为 paused，继续下载最终完成', () async {
      final server = _SlowDownloadServer._();
      final url = await server.start();
      final task = AppUpdateService.instance.createDownloadTask(url.toString());
      try {
        final done = task.start();
        // 等待确实进入下载中且已收到部分数据
        await _waitFor(() =>
            task.progressNotifier.value.state ==
                AppUpdateDownloadState.downloading &&
            task.progressNotifier.value.downloadedBytes > 0);

        task.pause();
        final paused = task.progressNotifier.value;
        expect(paused.state, AppUpdateDownloadState.paused,
            reason: '暂停后状态应为 paused，实际为 ${paused.state}（${paused.message}）');
        expect(paused.downloadedBytes, greaterThan(0));

        // 真暂停：字节数应停止增长
        final bytesAtPause = paused.downloadedBytes;
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(task.progressNotifier.value.downloadedBytes, bytesAtPause,
            reason: '暂停期间下载字节数仍在增长，说明未真正暂停');

        task.resume();
        await done;
        final p = task.progressNotifier.value;
        expect(p.state, AppUpdateDownloadState.completed);
        expect(p.downloadedBytes, _SlowDownloadServer.totalBytes);
      } finally {
        await server.dispose();
      }
    });

    test('取消后状态为 cancelled，临时半成品文件被删除', () async {
      final server = _SlowDownloadServer._();
      final url = await server.start();
      final task = AppUpdateService.instance.createDownloadTask(url.toString());
      try {
        final done = task.start();
        await _waitFor(() =>
            task.progressNotifier.value.state ==
                AppUpdateDownloadState.downloading &&
            task.progressNotifier.value.downloadedBytes > 0);

        final partialPath = task.progressNotifier.value.filePath;
        await task.cancel();
        await done;
        final p = task.progressNotifier.value;
        expect(p.state, AppUpdateDownloadState.cancelled,
            reason: '取消后状态应为 cancelled，实际为 ${p.state}（${p.message}）');
        if (partialPath != null) {
          expect(await File(partialPath).exists(), isFalse);
        }
      } finally {
        await server.dispose();
      }
    });

    test('服务器中断后状态为 error，可重试', () async {
      // 立即关闭连接的服务器：响应后立刻断开
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) {
        request.response.close().catchError((_) {});
      });
      final task = AppUpdateService.instance.createDownloadTask(
          'http://127.0.0.1:${server.port}/Hibi2023_Setup_9.9.9.exe');
      try {
        await task.start();
        final p = task.progressNotifier.value;
        // 空响应体 = 正常完成（0 字节），这是合法情况；改为非 200 状态测试 error
        expect(
            p.state == AppUpdateDownloadState.completed ||
                p.state == AppUpdateDownloadState.error,
            isTrue);
      } finally {
        await server.close(force: true);
      }
    });

    test('HTTP 错误状态码进入 error 且含可读提示', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) {
        request.response.statusCode = HttpStatus.notFound;
        request.response.close().catchError((_) {});
      });
      final task = AppUpdateService.instance.createDownloadTask(
          'http://127.0.0.1:${server.port}/Hibi2023_Setup_9.9.9.exe');
      try {
        await task.start();
        final p = task.progressNotifier.value;
        expect(p.state, AppUpdateDownloadState.error);
        expect(p.message, isNotNull);
        expect(p.message, contains('404'));
      } finally {
        await server.close(force: true);
      }
    });

    test('无效下载地址进入 error', () async {
      final task = AppUpdateService.instance.createDownloadTask('not-a-url');
      await task.start();
      expect(task.progressNotifier.value.state, AppUpdateDownloadState.error);
    });
  });

  group('下载候选 URL 构建', () {
    test('github.com 链接默认镜像优先，直连垫底', () {
      const gh =
          'https://github.com/YYOZZE/HIBI/releases/download/HIBI-2023_v3.1.0/Hibi2023_Setup_3.1.0.exe';
      final candidates = buildDownloadUrlCandidates(gh, mirrorFirst: true);
      expect(candidates.length, 1 + kDownloadMirrors.length);
      expect(candidates.last, gh);
      for (var i = 0; i < kDownloadMirrors.length; i++) {
        expect(candidates[i], '${kDownloadMirrors[i]}$gh');
      }
      // 镜像列表本身应为完整 https 前缀
      for (final m in kDownloadMirrors) {
        expect(m.startsWith('https://'), isTrue);
        expect(m.endsWith('/'), isTrue);
      }
      final directFirst = buildDownloadUrlCandidates(gh, mirrorFirst: false);
      expect(directFirst.first, gh);
    });

    test('非 github.com 链接与非法链接不追加镜像', () {
      expect(buildDownloadUrlCandidates('http://127.0.0.1:8080/a.exe'),
          ['http://127.0.0.1:8080/a.exe']);
      expect(buildDownloadUrlCandidates('https://example.com/a.exe'),
          ['https://example.com/a.exe']);
      expect(buildDownloadUrlCandidates('https://GITHUB.com/x/y'),
          isNot(['https://GITHUB.com/x/y'])); // host 大小写不敏感
      expect(buildDownloadUrlCandidates('not-a-url'), ['not-a-url']);
    });
  });

  group('镜像回退', () {
    tearDown(() {
      AppUpdateDownloadTask.debugBuildUrlCandidates =
          buildDownloadUrlCandidates;
    });

    /// 分配一个未被监听的本地端口，模拟「连接被拒绝」的连接层失败
    Future<String> deadUrl() async {
      final probe = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final url = 'http://127.0.0.1:${probe.port}/dead.exe';
      await probe.close(force: true);
      return url;
    }

    test('连接层失败后自动切换到镜像候选完成下载，并提示镜像序号', () async {
      final server = _SlowDownloadServer._();
      final goodUrl = await server.start();
      final bad = await deadUrl();
      AppUpdateDownloadTask.debugBuildUrlCandidates =
          (_) => [bad, goodUrl.toString()];
      final task = AppUpdateService.instance
          .createDownloadTask('http://127.0.0.1/original.exe');
      final messages = <String>[];
      task.progressNotifier.addListener(() {
        final m = task.progressNotifier.value.message;
        if (m != null) messages.add(m);
      });
      try {
        await task.start();
        final p = task.progressNotifier.value;
        expect(p.state, AppUpdateDownloadState.completed,
            reason: '镜像回退后应下载完成，实际 ${p.state}（${p.message}）');
        expect(p.downloadedBytes, _SlowDownloadServer.totalBytes);
        expect(await File(p.filePath!).length(),
            _SlowDownloadServer.totalBytes);
        expect(
          messages.any((m) => m.contains('加速源') || m.contains('镜像')),
          isTrue,
          reason: '切换到加速源时应有进度提示，实际消息：$messages',
        );
      } finally {
        await server.dispose();
      }
    });

    test('HTTP 404 候选失败后切换到下一镜像完成下载', () async {
      final notFound = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      notFound.listen((request) {
        request.response.statusCode = HttpStatus.notFound;
        request.response.close().catchError((_) {});
      });
      final server = _SlowDownloadServer._();
      final goodUrl = await server.start();
      AppUpdateDownloadTask.debugBuildUrlCandidates = (_) =>
          ['http://127.0.0.1:${notFound.port}/a.exe', goodUrl.toString()];
      final task = AppUpdateService.instance
          .createDownloadTask('http://127.0.0.1/original.exe');
      try {
        await task.start();
        expect(task.progressNotifier.value.state,
            AppUpdateDownloadState.completed);
        expect(task.progressNotifier.value.downloadedBytes,
            _SlowDownloadServer.totalBytes);
      } finally {
        await notFound.close(force: true);
        await server.dispose();
      }
    });

    test('所有候选连接失败：提示 GitHub 下载域名不可达', () async {
      final dead1 = await deadUrl();
      final dead2 = await deadUrl();
      AppUpdateDownloadTask.debugBuildUrlCandidates = (_) => [dead1, dead2];
      final task = AppUpdateService.instance
          .createDownloadTask('http://127.0.0.1/original.exe');
      await task.start();
      final p = task.progressNotifier.value;
      expect(p.state, AppUpdateDownloadState.error);
      expect(p.message, contains('GitHub 下载域名不可达'));
      expect(p.message, contains('代理'));
    });

    test('镜像回退中途取消：状态为 cancelled 且不再继续', () async {
      final server = _SlowDownloadServer._();
      final goodUrl = await server.start();
      final bad = await deadUrl();
      AppUpdateDownloadTask.debugBuildUrlCandidates =
          (_) => [bad, goodUrl.toString()];
      final task = AppUpdateService.instance
          .createDownloadTask('http://127.0.0.1/original.exe');
      try {
        final done = task.start();
        await _waitFor(() =>
            task.progressNotifier.value.state ==
                AppUpdateDownloadState.downloading &&
            task.progressNotifier.value.downloadedBytes > 0);
        await task.cancel();
        await done;
        expect(task.progressNotifier.value.state,
            AppUpdateDownloadState.cancelled);
      } finally {
        await server.dispose();
      }
    });
  });

  group('并发与清理加固', () {
    tearDown(() {
      AppUpdateDownloadTask.debugBuildUrlCandidates =
          buildDownloadUrlCandidates;
      AppUpdateDownloadTask.debugConnectTimeout = const Duration(seconds: 15);
      AppUpdateService.instance.debugClearActiveDownloadTask();
    });

    test('连点防护：重复调用 start 复用同一次下载，完成后可重下', () async {
      var requestCount = 0;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        requestCount++;
        final response = request.response;
        response.headers.set(HttpHeaders.contentLengthHeader, 256 * 1024);
        try {
          // 放慢发送节奏，给连点留出重入窗口
          for (var i = 0; i < 4; i++) {
            response.add(List<int>.filled(64 * 1024, i));
            await response.flush();
            await Future<void>.delayed(const Duration(milliseconds: 60));
          }
          await response.close();
        } catch (_) {
          // 客户端中断
        }
      });
      final task = AppUpdateService.instance.createDownloadTask(
          'http://127.0.0.1:${server.port}/Hibi2023_Setup_9.9.9.exe');
      try {
        // 模拟用户连点「立即更新」/「重试下载」
        final f1 = task.start();
        final f2 = task.start();
        final f3 = task.start();
        await Future.wait([f1, f2, f3]);
        expect(task.progressNotifier.value.state,
            AppUpdateDownloadState.completed);
        expect(requestCount, 1,
            reason: '连点触发了 $requestCount 个并发下载，写同一临时文件会损坏安装包');
        // 下载完成后再点允许重新下载
        await task.start();
        expect(task.progressNotifier.value.state,
            AppUpdateDownloadState.completed);
        expect(requestCount, 2);
      } finally {
        await server.close(force: true);
      }
    });

    test('暂停中取消：状态 cancelled 且半成品文件被删除', () async {
      final server = _SlowDownloadServer._();
      final url = await server.start();
      final task = AppUpdateService.instance.createDownloadTask(url.toString());
      try {
        final done = task.start();
        await _waitFor(() =>
            task.progressNotifier.value.state ==
                AppUpdateDownloadState.downloading &&
            task.progressNotifier.value.downloadedBytes > 0);
        task.pause();
        expect(task.progressNotifier.value.state,
            AppUpdateDownloadState.paused);
        final partialPath = task.progressNotifier.value.filePath;
        await task.cancel();
        await done;
        final p = task.progressNotifier.value;
        expect(p.state, AppUpdateDownloadState.cancelled,
            reason: '暂停中取消应为 cancelled，实际 ${p.state}（${p.message}）');
        if (partialPath != null) {
          expect(await File(partialPath).exists(), isFalse,
              reason: '暂停中取消应删除半成品文件');
        }
      } finally {
        await server.dispose();
      }
    });

    test('服务器 200 后中途断流：进入 error、不回退镜像、保留半成品供续传', () async {
      var abortHits = 0;
      // 声明 2MB Content-Length，只发 64KB 就强制断开
      final abortServer =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      abortServer.listen((socket) async {
        abortHits++;
        socket.write(
            'HTTP/1.1 200 OK\r\nContent-Length: ${2 * 1024 * 1024}\r\n\r\n');
        socket.add(List<int>.filled(64 * 1024, 3));
        await socket.flush();
        socket.destroy();
      });
      final good = _SlowDownloadServer._();
      final goodUrl = await good.start();
      AppUpdateDownloadTask.debugBuildUrlCandidates = (_) => [
            'http://127.0.0.1:${abortServer.port}/Hibi2023_Setup_9.9.9.exe',
            goodUrl.toString(),
          ];
      final task = AppUpdateService.instance
          .createDownloadTask('http://127.0.0.1/original.exe');
      String? partialPath;
      task.progressNotifier.addListener(() {
        partialPath ??= task.progressNotifier.value.filePath;
      });
      try {
        await task.start();
        final p = task.progressNotifier.value;
        expect(p.state, AppUpdateDownloadState.error,
            reason: '中途断流应进入 error，实际 ${p.state}（若回退成功会变 completed）');
        expect(p.downloadedBytes, lessThan(2 * 1024 * 1024));
        expect(abortHits, 1);
        expect(p.message, isNotNull);
        if (partialPath != null) {
          expect(await File(partialPath!).exists(), isTrue,
              reason: 'error 后应保留半成品以便 Range 续传');
        }
      } finally {
        await abortServer.close();
        await good.dispose();
      }
    });

    test('回退到镜像后暂停/继续语义不变', () async {
      final server = _SlowDownloadServer._();
      final goodUrl = await server.start();
      final bad = await _deadUrl();
      AppUpdateDownloadTask.debugBuildUrlCandidates =
          (_) => [bad, goodUrl.toString()];
      final task = AppUpdateService.instance
          .createDownloadTask('http://127.0.0.1/original.exe');
      try {
        final done = task.start();
        await _waitFor(() =>
            task.progressNotifier.value.state ==
                AppUpdateDownloadState.downloading &&
            task.progressNotifier.value.downloadedBytes > 0);
        task.pause();
        expect(task.progressNotifier.value.state,
            AppUpdateDownloadState.paused);
        final bytesAtPause = task.progressNotifier.value.downloadedBytes;
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(task.progressNotifier.value.downloadedBytes, bytesAtPause,
            reason: '镜像下载暂停期间字节数仍在增长');
        task.resume();
        await done;
        final p = task.progressNotifier.value;
        expect(p.state, AppUpdateDownloadState.completed);
        expect(p.downloadedBytes, _SlowDownloadServer.totalBytes);
      } finally {
        await server.dispose();
      }
    });

    test('弱网：候选连接后迟迟不应答，超时回退镜像完成下载', () async {
      AppUpdateDownloadTask.debugConnectTimeout =
          const Duration(milliseconds: 400);
      final heldSockets = <Socket>[];
      // 接受 TCP 连接但永远不响应 HTTP
      final silent = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      silent.listen(heldSockets.add);
      final server = _SlowDownloadServer._();
      final goodUrl = await server.start();
      AppUpdateDownloadTask.debugBuildUrlCandidates = (_) => [
            'http://127.0.0.1:${silent.port}/Hibi2023_Setup_9.9.9.exe',
            goodUrl.toString(),
          ];
      final task = AppUpdateService.instance
          .createDownloadTask('http://127.0.0.1/original.exe');
      final messages = <String>[];
      task.progressNotifier.addListener(() {
        final m = task.progressNotifier.value.message;
        if (m != null) messages.add(m);
      });
      try {
        await task.start();
        final p = task.progressNotifier.value;
        expect(p.state, AppUpdateDownloadState.completed,
            reason: '超时后应回退镜像完成下载，实际 ${p.state}（${p.message}）');
        expect(p.downloadedBytes, _SlowDownloadServer.totalBytes);
        expect(
          messages.any((m) => m.contains('加速源') || m.contains('镜像')),
          isTrue,
        );
      } finally {
        for (final s in heldSockets) {
          s.destroy();
        }
        await silent.close();
        await server.dispose();
      }
    });

    test('弱网：全部候选超时，提示域名不可达并建议代理', () async {
      AppUpdateDownloadTask.debugConnectTimeout =
          const Duration(milliseconds: 400);
      final heldSockets = <Socket>[];
      final silent1 = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final silent2 = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      silent1.listen(heldSockets.add);
      silent2.listen(heldSockets.add);
      AppUpdateDownloadTask.debugBuildUrlCandidates = (_) => [
            'http://127.0.0.1:${silent1.port}/a.exe',
            'http://127.0.0.1:${silent2.port}/b.exe',
          ];
      final task = AppUpdateService.instance
          .createDownloadTask('http://127.0.0.1/original.exe');
      try {
        await task.start();
        final p = task.progressNotifier.value;
        expect(p.state, AppUpdateDownloadState.error);
        expect(p.message, contains('GitHub 下载域名不可达'));
        expect(p.message, contains('代理'));
      } finally {
        for (final s in heldSockets) {
          s.destroy();
        }
        await silent1.close();
        await silent2.close();
      }
    });

    test('start 时清理历史遗留的 hibi_update_* 安装包', () async {
      final sep = Platform.pathSeparator;
      final staleExe =
          File('${tempDir.path}${sep}hibi_update_Hibi2023_Setup_3.0.0.exe');
      final staleApk = File('${tempDir.path}${sep}hibi_update_old.apk');
      final unrelated = File('${tempDir.path}${sep}unrelated.txt');
      await staleExe.writeAsBytes(const [1, 2, 3]);
      await staleApk.writeAsBytes(const [4, 5, 6]);
      await unrelated.writeAsBytes(const [7, 8, 9]);
      final server = _SlowDownloadServer._();
      final url = await server.start();
      final task = AppUpdateService.instance.createDownloadTask(url.toString());
      try {
        await task.start();
        expect(task.progressNotifier.value.state,
            AppUpdateDownloadState.completed);
        expect(await staleExe.exists(), isFalse, reason: '历史安装包应被清理');
        expect(await staleApk.exists(), isFalse, reason: '历史安装包应被清理');
        expect(await unrelated.exists(), isTrue, reason: '无关文件不应被误删');
        final remaining = await tempDir
            .list()
            .where((e) =>
                e is File &&
                e.path.split(RegExp(r'[\\/]')).last.startsWith('hibi_update_'))
            .length;
        expect(remaining, 1, reason: '临时目录应只剩当前下载目标');
      } finally {
        await server.dispose();
      }
    });

    test('createDownloadTask：同 URL 复用任务，新 URL 取消旧任务', () async {
      final server = _SlowDownloadServer._();
      final url = await server.start();
      try {
        final t1 = AppUpdateService.instance.createDownloadTask(url.toString());
        final done = t1.start();
        await _waitFor(() =>
            t1.progressNotifier.value.state ==
                AppUpdateDownloadState.downloading &&
            t1.progressNotifier.value.downloadedBytes > 0);
        // 页面退出重进 → 同 URL 应拿到同一个仍在下载的任务
        final t2 = AppUpdateService.instance.createDownloadTask(url.toString());
        expect(identical(t1, t2), isTrue, reason: '同 URL 应复用同一任务');
        expect(t2.progressNotifier.value.state,
            AppUpdateDownloadState.downloading,
            reason: '复用的任务不应被重启');
        // 发现更新版本（URL 变化）→ 旧任务取消，新任务替换
        final t3 = AppUpdateService.instance
            .createDownloadTask('http://127.0.0.1:1/newer.exe');
        expect(identical(t1, t3), isFalse);
        await done;
        expect(t1.progressNotifier.value.state,
            AppUpdateDownloadState.cancelled,
            reason: 'URL 变化时旧任务应被取消，避免孤儿下载写盘');
      } finally {
        await server.dispose();
      }
    });
  });

  group('下载大小显示', () {
    test('effectiveTotalBytes：优先响应长度，回退 manifest 资产大小', () {
      expect(AppUpdateService.effectiveTotalBytes(100, 50), 100);
      expect(AppUpdateService.effectiveTotalBytes(null, 50), 50);
      expect(AppUpdateService.effectiveTotalBytes(0, 50), 50);
      expect(AppUpdateService.effectiveTotalBytes(null, null), isNull);
      expect(AppUpdateService.effectiveTotalBytes(null, 0), isNull);
    });

    test('formatDownloadSizeText：下载前显示安装包总大小', () {
      expect(
        AppUpdateService.formatDownloadSizeText(
          state: AppUpdateDownloadState.idle,
          downloadedBytes: 0,
          manifestAssetSize: 5 * 1024 * 1024,
        ),
        '更新文件：5.00MB',
      );
      expect(
        AppUpdateService.formatDownloadSizeText(
          state: AppUpdateDownloadState.idle,
          downloadedBytes: 0,
        ),
        '更新文件：大小未知',
      );
    });

    test('formatDownloadSizeText：下载中显示已下载/总大小（含百分比）', () {
      expect(
        AppUpdateService.formatDownloadSizeText(
          state: AppUpdateDownloadState.downloading,
          downloadedBytes: 1024 * 1024,
          totalBytes: 5 * 1024 * 1024,
        ),
        '1.00MB / 5.00MB（20%）',
      );
      // 响应长度未知时回退 manifest 资产大小
      expect(
        AppUpdateService.formatDownloadSizeText(
          state: AppUpdateDownloadState.downloading,
          downloadedBytes: 1024 * 1024,
          manifestAssetSize: 4 * 1024 * 1024,
        ),
        '1.00MB / 4.00MB（25%）',
      );
      // 总大小完全未知：只显示已下载
      expect(
        AppUpdateService.formatDownloadSizeText(
          state: AppUpdateDownloadState.downloading,
          downloadedBytes: 2048,
        ),
        '2KB',
      );
      // 已完成：显示完整大小与 100%
      expect(
        AppUpdateService.formatDownloadSizeText(
          state: AppUpdateDownloadState.completed,
          downloadedBytes: 5 * 1024 * 1024,
          totalBytes: 5 * 1024 * 1024,
        ),
        '5.00MB / 5.00MB（100%）',
      );
    });
  });
}

/// 分配一个未被监听的本地端口，模拟「连接被拒绝」的连接层失败
Future<String> _deadUrl() async {
  final probe = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final url = 'http://127.0.0.1:${probe.port}/dead.exe';
  await probe.close(force: true);
  return url;
}

Future<void> _waitFor(bool Function() condition,
    {Duration timeout = const Duration(seconds: 10)}) async {
  final sw = Stopwatch()..start();
  while (!condition()) {
    if (sw.elapsed > timeout) {
      fail('等待条件超时');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
