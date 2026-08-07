import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart' show OpenFilex, ResultType;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../config/api_config.dart';

/// 服务端返回的升级清单（`/api/app/update_manifest`）
class AppUpdateManifest {
  const AppUpdateManifest({
    required this.latestVersion,
    required this.releaseNotes,
    required this.urls,
    this.updatedAt = 0,
  });

  final String latestVersion;
  final String releaseNotes;
  final Map<String, String> urls;
  final double updatedAt;

  static AppUpdateManifest? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final lv = json['latest_version']?.toString().trim() ?? '';
    final notes = json['release_notes']?.toString() ?? '';
    final rawUrls = json['urls'];
    final urls = <String, String>{
      'windows': '',
      'ios': '',
      'android': '',
      'linux': '',
    };
    if (rawUrls is Map) {
      for (final k in urls.keys) {
        final v = rawUrls[k];
        urls[k] = v == null ? '' : v.toString().trim();
      }
    }
    final uat = json['updated_at'];
    final updatedAt = uat is num ? uat.toDouble() : 0.0;
    return AppUpdateManifest(
      latestVersion: lv,
      releaseNotes: notes,
      urls: urls,
      updatedAt: updatedAt,
    );
  }
}

/// 当前设备上的版本与是否有更新
class AppUpdateStatus {
  const AppUpdateStatus({
    required this.currentVersion,
    required this.currentBuildNumber,
    required this.manifest,
    required this.updateAvailable,
    required this.downloadUrlForPlatform,
  });

  final String currentVersion;
  final String currentBuildNumber;
  final AppUpdateManifest manifest;
  final bool updateAvailable;
  /// 当前平台对应的安装包或商店链接；可能为空（仅展示说明）
  final String? downloadUrlForPlatform;
}

/// 拉取升级配置、对比版本号；供「我的」页与更新页使用。
class AppUpdateService {
  AppUpdateService._();
  static final AppUpdateService instance = AppUpdateService._();

  final ValueNotifier<AppUpdateStatus?> statusNotifier = ValueNotifier<AppUpdateStatus?>(null);

  static int compareSemanticVersion(String a, String b) {
    final pa = _versionParts(a);
    final pb = _versionParts(b);
    final len = pa.length > pb.length ? pa.length : pb.length;
    for (var i = 0; i < len; i++) {
      final ca = i < pa.length ? pa[i] : 0;
      final cb = i < pb.length ? pb[i] : 0;
      if (ca != cb) return ca.compareTo(cb);
    }
    return 0;
  }

  static List<int> _versionParts(String raw) {
    final core = raw.split('+').first.trim();
    if (core.isEmpty) return [0];
    return core.split('.').map((e) => int.tryParse(e.trim()) ?? 0).toList();
  }

  String? _urlForThisPlatform(Map<String, String> urls) {
    if (kIsWeb) return null;
    if (Platform.isWindows) return _nonEmpty(urls['windows']);
    if (Platform.isIOS) return _nonEmpty(urls['ios']);
    if (Platform.isAndroid) return _nonEmpty(urls['android']);
    if (Platform.isLinux) return _nonEmpty(urls['linux']);
    return null;
  }

  String? _nonEmpty(String? s) {
    final t = (s ?? '').trim();
    return t.isEmpty ? null : t;
  }

  Future<void> checkSilently() async {
    if (kIsWeb) return;
    try {
      final base = ApiConfig.authApiBaseUrl.replaceFirst(RegExp(r'/$'), '');
      if (base.isEmpty || base == 'YOUR_AUTH_SERVER_URL') return;
      final uri = Uri.parse('$base/api/app/update_manifest');
      final resp = await http.get(uri).timeout(const Duration(seconds: 12));
      if (resp.statusCode != 200) return;
      final data = jsonDecode(utf8.decode(resp.bodyBytes));
      if (data is! Map<String, dynamic>) return;
      final manifest = AppUpdateManifest.fromJson(data);
      if (manifest == null) return;
      final info = await PackageInfo.fromPlatform();
      final cur = info.version.trim();
      final remote = manifest.latestVersion.trim();
      final cmp = remote.isEmpty ? 0 : compareSemanticVersion(remote, cur);
      final hasUpdate = cmp > 0;
      final dl = _urlForThisPlatform(manifest.urls);
      statusNotifier.value = AppUpdateStatus(
        currentVersion: cur,
        currentBuildNumber: info.buildNumber,
        manifest: manifest,
        updateAvailable: hasUpdate,
        downloadUrlForPlatform: dl,
      );
    } catch (_) {
      // 静默失败，不打断启动
    }
  }

  /// 下载直链文件到临时目录并尝试打开（安装包）。
  Future<void> downloadAndOpenInstaller(String httpsUrlOrFilePath) async {
    if (kIsWeb) return;
    final asFile = File(httpsUrlOrFilePath);
    if (await asFile.exists()) {
      // 已下载到本地文件，直接尝试打开安装包
      if (Platform.isAndroid) {
        final req = await Permission.requestInstallPackages.request();
        if (!req.isGranted) {
          throw StateError('需要「安装未知应用」权限才能完成更新');
        }
      }
      final result = await OpenFilex.open(asFile.path);
      if (result.type != ResultType.done && result.type != ResultType.noAppToOpen) {
        throw StateError(result.message.isNotEmpty ? result.message : '无法打开安装文件');
      }
      return;
    }

    final uri = Uri.tryParse(httpsUrlOrFilePath);
    if (uri == null || !uri.hasScheme) {
      throw const FormatException('无效的下载地址');
    }
    if (Platform.isIOS) {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok) throw StateError('无法打开链接');
      return;
    }

    final resp = await http.get(uri).timeout(const Duration(minutes: 30));
    if (resp.statusCode != 200) {
      throw StateError('下载失败 (${resp.statusCode})');
    }
    final dir = await getTemporaryDirectory();
    String name = uri.pathSegments.isNotEmpty ? uri.pathSegments.last : 'update.bin';
    if (!name.contains('.')) {
      if (Platform.isWindows) name = '$name.exe';
      if (Platform.isAndroid) name = '$name.apk';
      if (Platform.isLinux) name = '$name.AppImage';
    }
    final path = '${dir.path}${Platform.pathSeparator}hibi_update_$name';
    final file = File(path);
    await file.writeAsBytes(resp.bodyBytes, flush: true);

    if (Platform.isAndroid) {
      final req = await Permission.requestInstallPackages.request();
      if (!req.isGranted) {
        throw StateError('需要「安装未知应用」权限才能完成更新');
      }
    }

    final result = await OpenFilex.open(file.path);
    if (result.type != ResultType.done && result.type != ResultType.noAppToOpen) {
      throw StateError(result.message.isNotEmpty ? result.message : '无法打开安装文件');
    }
  }

  /// 可暂停/继续/取消的下载任务（Android/Windows/Linux）。
  AppUpdateDownloadTask createDownloadTask(String httpsUrl) {
    return AppUpdateDownloadTask._(httpsUrl);
  }

  /// 仅打开浏览器 / 应用商店（不下载）。
  Future<void> openExternalUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) throw const FormatException('无效链接');
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok) throw StateError('无法打开链接');
  }
}

enum AppUpdateDownloadState { idle, downloading, paused, completed, cancelled, error }

class AppUpdateDownloadProgress {
  const AppUpdateDownloadProgress({
    required this.state,
    this.downloadedBytes = 0,
    this.totalBytes,
    this.speedBytesPerSec,
    this.message,
    this.filePath,
  });

  final AppUpdateDownloadState state;
  final int downloadedBytes;
  final int? totalBytes;
  final int? speedBytesPerSec;
  final String? message;
  final String? filePath;
}

class AppUpdateDownloadTask {
  AppUpdateDownloadTask._(this.url);

  final String url;
  final ValueNotifier<AppUpdateDownloadProgress> progressNotifier =
      ValueNotifier<AppUpdateDownloadProgress>(const AppUpdateDownloadProgress(state: AppUpdateDownloadState.idle));

  HttpClient? _client;
  HttpClientRequest? _req;
  HttpClientResponse? _resp;
  IOSink? _sink;
  File? _file;
  int _downloaded = 0;
  int? _total;
  bool _cancelled = false;
  bool _paused = false;
  DateTime? _lastTickAt;
  int _lastTickBytes = 0;

  Future<void> start() async {
    _cancelled = false;
    _paused = false;
    await _download(fromScratch: true);
  }

  Future<void> pause() async {
    if (progressNotifier.value.state != AppUpdateDownloadState.downloading) return;
    _paused = true;
    await _closeActive();
    progressNotifier.value = AppUpdateDownloadProgress(
      state: AppUpdateDownloadState.paused,
      downloadedBytes: _downloaded,
      totalBytes: _total,
      filePath: _file?.path,
    );
  }

  Future<void> resume() async {
    if (progressNotifier.value.state != AppUpdateDownloadState.paused) return;
    _paused = false;
    await _download(fromScratch: false);
  }

  Future<void> cancel({bool deletePartial = true}) async {
    _cancelled = true;
    await _closeActive();
    if (deletePartial) {
      try {
        await _file?.delete();
      } catch (_) {}
    }
    progressNotifier.value = const AppUpdateDownloadProgress(state: AppUpdateDownloadState.cancelled);
  }

  Future<void> _closeActive() async {
    try {
      await _sink?.flush();
    } catch (_) {}
    try {
      await _sink?.close();
    } catch (_) {}
    _sink = null;
    try {
      _resp?.detachSocket();
    } catch (_) {}
    _resp = null;
    try {
      _req?.abort();
    } catch (_) {}
    _req = null;
    _client?.close(force: true);
    _client = null;
  }

  Future<void> _download({required bool fromScratch}) async {
    if (kIsWeb) return;
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) {
      progressNotifier.value = const AppUpdateDownloadProgress(
        state: AppUpdateDownloadState.error,
        message: '无效的下载地址',
      );
      return;
    }
    if (Platform.isIOS) {
      progressNotifier.value = const AppUpdateDownloadProgress(
        state: AppUpdateDownloadState.error,
        message: 'iOS 请跳转外部链接更新',
      );
      return;
    }

    final dir = await getTemporaryDirectory();
    String name = uri.pathSegments.isNotEmpty ? uri.pathSegments.last : 'update.bin';
    if (!name.contains('.')) {
      if (Platform.isWindows) name = '$name.exe';
      if (Platform.isAndroid) name = '$name.apk';
      if (Platform.isLinux) name = '$name.AppImage';
    }
    final path = '${dir.path}${Platform.pathSeparator}hibi_update_$name';
    _file = File(path);

    if (fromScratch) {
      _downloaded = 0;
      _total = null;
      try {
        if (await _file!.exists()) await _file!.delete();
      } catch (_) {}
    } else {
      try {
        _downloaded = await _file!.length();
      } catch (_) {
        _downloaded = 0;
      }
    }

    progressNotifier.value = AppUpdateDownloadProgress(
      state: AppUpdateDownloadState.downloading,
      downloadedBytes: _downloaded,
      totalBytes: _total,
      filePath: _file!.path,
    );

    _client = HttpClient()..connectionTimeout = const Duration(seconds: 12);
    try {
      _req = await _client!.getUrl(uri);
      if (_downloaded > 0) {
        _req!.headers.set(HttpHeaders.rangeHeader, 'bytes=$_downloaded-');
      }
      _resp = await _req!.close();

      final sc = _resp!.statusCode;
      if (_downloaded > 0 && sc != HttpStatus.partialContent && sc != HttpStatus.ok) {
        throw HttpException('下载失败 ($sc)');
      }
      if (_downloaded == 0 && sc != HttpStatus.ok) {
        throw HttpException('下载失败 ($sc)');
      }

      final contentLen = _resp!.contentLength;
      if (contentLen > 0) {
        _total = _downloaded + contentLen;
      }

      _sink = _file!.openWrite(mode: _downloaded > 0 ? FileMode.append : FileMode.write);
      _lastTickAt = DateTime.now();
      _lastTickBytes = _downloaded;

      await for (final chunk in _resp!) {
        if (_cancelled || _paused) break;
        _sink!.add(chunk);
        _downloaded += chunk.length;

        final now = DateTime.now();
        final dt = now.difference(_lastTickAt!);
        int? speed;
        if (dt.inMilliseconds >= 500) {
          final delta = _downloaded - _lastTickBytes;
          speed = (delta * 1000 ~/ dt.inMilliseconds);
          _lastTickAt = now;
          _lastTickBytes = _downloaded;
        }

        progressNotifier.value = AppUpdateDownloadProgress(
          state: AppUpdateDownloadState.downloading,
          downloadedBytes: _downloaded,
          totalBytes: _total,
          speedBytesPerSec: speed,
          filePath: _file!.path,
        );
      }

      await _sink!.flush();
      await _sink!.close();
      _sink = null;

      if (_cancelled) return;
      if (_paused) return;

      progressNotifier.value = AppUpdateDownloadProgress(
        state: AppUpdateDownloadState.completed,
        downloadedBytes: _downloaded,
        totalBytes: _total,
        filePath: _file!.path,
      );
    } catch (e) {
      await _closeActive();
      progressNotifier.value = AppUpdateDownloadProgress(
        state: AppUpdateDownloadState.error,
        downloadedBytes: _downloaded,
        totalBytes: _total,
        message: e.toString(),
        filePath: _file?.path,
      );
    } finally {
      _client?.close(force: true);
      _client = null;
    }
  }
}
