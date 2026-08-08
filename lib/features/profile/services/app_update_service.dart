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

import 'app_update_download_keepalive.dart';

/// 版本更新来源：GitHub 固定仓库的最新 Release。
/// 仓库地址：https://github.com/YYOZZE/HIBI
const String kUpdateGithubRepo = 'YYOZZE/HIBI';
const String kUpdateGithubLatestApi =
    'https://api.github.com/repos/$kUpdateGithubRepo/releases/latest';
const String kUpdateGithubReleasesPage =
    'https://github.com/$kUpdateGithubRepo/releases';

/// GitHub Release 下载加速镜像（URL 前缀代理，按优先级排序）。
///
/// 实测日期 2026-08-08（国内直连环境，curl Range 请求实测返回 206）：
/// `ghproxy.net` 响应快（约 1.6s）；`gh-proxy.com` 可用但响应慢（约 17s）。
/// 同日实测 `ghfast.top`、`mirror.ghproxy.com` 连接超时，未纳入。
/// 公共镜像可用性随时间变化，可按需更新本列表。
///
/// 也可用 `--dart-define=UPDATE_MIRRORS=https://a/,https://b/` 覆盖（逗号分隔，须以 `/` 结尾）。
const List<String> kDownloadMirrors = [
  'https://ghproxy.net/',
  'https://gh-proxy.com/',
];

/// 是否镜像优先。国内默认 true，避免先卡在 GitHub 直连 15s 超时。
/// 海外可 `--dart-define=UPDATE_MIRROR_FIRST=false`。
const bool kUpdateMirrorFirst = bool.fromEnvironment(
  'UPDATE_MIRROR_FIRST',
  defaultValue: true,
);

List<String> _effectiveMirrors() {
  const raw = String.fromEnvironment('UPDATE_MIRRORS', defaultValue: '');
  if (raw.trim().isEmpty) return kDownloadMirrors;
  final list = raw
      .split(',')
      .map((e) => e.trim())
      .where((e) => e.startsWith('http') && e.endsWith('/'))
      .toList();
  return list.isEmpty ? kDownloadMirrors : list;
}

/// 构建下载候选 URL 列表。
///
/// 默认 [mirrorFirst]=true：镜像在前、GitHub 直连垫底，缩短国内首连等待。
/// 仅对 host 为 `github.com` 的链接追加镜像；其他链接原样返回。
List<String> buildDownloadUrlCandidates(
  String originalUrl, {
  bool? mirrorFirst,
}) {
  final uri = Uri.tryParse(originalUrl);
  if (uri == null || uri.host.toLowerCase() != 'github.com') {
    return <String>[originalUrl];
  }
  final mirrors = _effectiveMirrors();
  final mirrored = [for (final m in mirrors) '$m$originalUrl'];
  final preferMirror = mirrorFirst ?? kUpdateMirrorFirst;
  if (preferMirror) {
    return <String>[...mirrored, originalUrl];
  }
  return <String>[originalUrl, ...mirrored];
}

enum AppUpdateCheckResult { updateAvailable, upToDate, failed }

/// 手动检查（「关于版本」页「检测更新」）的细粒度结果：
/// 在静默检查三态的基础上区分失败原因，便于给出针对性提示。
enum AppUpdateManualCheckResult {
  updateAvailable,
  upToDate,
  /// 连接失败 / 超时等网络层错误
  networkFailed,
  /// GitHub API 限流（HTTP 403，未鉴权请求每 IP 每小时 60 次）
  rateLimited,
  /// 其他失败（响应格式异常、无有效版本等）
  failed,
}

/// 升级清单（来自 GitHub 最新 Release）
class AppUpdateManifest {
  const AppUpdateManifest({
    required this.latestVersion,
    required this.releaseNotes,
    required this.urls,
    required this.sizes,
    required this.releasePageUrl,
    this.updatedAt = 0,
  });

  final String latestVersion;
  final String releaseNotes;
  final Map<String, String> urls;
  final Map<String, int> sizes;
  final String releasePageUrl;
  final double updatedAt;

  /// 解析 GitHub Release JSON。
  /// 标签约定 `HIBI-2023_v3.0.2`；附件约定 `Hibi2023_x.y.z.apk`、`Hibi2023_Setup_x.y.z.exe`。
  static AppUpdateManifest? fromGithubRelease(Map<String, dynamic>? json) {
    if (json == null) return null;
    final tag = json['tag_name']?.toString().trim() ?? '';
    // tag 提取不到版本号时回退 name（兼容 tag 被写成纯文字的情况）
    var version = _extractVersion(tag);
    if (version.isEmpty) {
      version = _extractVersion(json['name']?.toString() ?? '');
    }
    if (version.isEmpty) return null;

    final urls = <String, String>{
      'windows': '',
      'ios': '',
      'android': '',
      'linux': '',
    };
    final sizes = <String, int>{};
    final rawAssets = json['assets'];
    if (rawAssets is List) {
      for (final a in rawAssets) {
        if (a is! Map) continue;
        final name = a['name']?.toString().toLowerCase() ?? '';
        final durl = a['browser_download_url']?.toString().trim() ?? '';
        if (durl.isEmpty) continue;
        final sz = a['size'];
        final size = sz is num ? sz.toInt() : 0;
        if (name.endsWith('.apk')) {
          urls['android'] = durl;
          sizes['android'] = size;
        } else if (name.endsWith('.exe')) {
          // 多个 exe 时优先 Setup 安装包
          final prefer = name.contains('setup');
          if (urls['windows']!.isEmpty || prefer) {
            urls['windows'] = durl;
            sizes['windows'] = size;
          }
        } else if (name.endsWith('.appimage') || name.contains('linux')) {
          urls['linux'] = durl;
          sizes['linux'] = size;
        }
      }
    }

    final pageUrl = json['html_url']?.toString().trim() ?? '';
    // iOS 不提供直装包，跳转 Release 页面
    urls['ios'] = pageUrl.isNotEmpty ? pageUrl : kUpdateGithubReleasesPage;

    final body = json['body']?.toString() ?? '';
    final notes = _extractReleaseNotes(body, version);

    double updatedAt = 0;
    final published = json['published_at']?.toString();
    if (published != null) {
      updatedAt =
          (DateTime.tryParse(published)?.millisecondsSinceEpoch ?? 0) / 1000.0;
    }

    return AppUpdateManifest(
      latestVersion: version,
      releaseNotes: notes,
      urls: urls,
      sizes: sizes,
      releasePageUrl:
          pageUrl.isNotEmpty ? pageUrl : kUpdateGithubReleasesPage,
      updatedAt: updatedAt,
    );
  }

  /// 从标签/名称中提取 x.y.z（可带字母后缀），如 `HIBI-2023_v3.0.2` → `3.0.2`
  static String _extractVersion(String raw) {
    final tagged = RegExp(r'_v(\d+\.\d+\.\d+[A-Za-z]?)').firstMatch(raw);
    if (tagged != null) return tagged.group(1)!;
    final matches = RegExp(r'\d+\.\d+\.\d+[A-Za-z]?').allMatches(raw);
    if (matches.isEmpty) return '';
    return matches.last.group(0)!;
  }

  /// Release body 若为整份版本管理文档，仅截取当前版本的小节；
  /// 并去掉 Markdown 标记，便于对话框/页面纯文本展示。
  static String _extractReleaseNotes(String body, String version) {
    final lines = body.split(RegExp(r'\r?\n'));
    final startRe = RegExp('^##\\s+V?${RegExp.escape(version)}\\b',
        caseSensitive: false);
    var start = -1;
    for (var i = 0; i < lines.length; i++) {
      if (startRe.hasMatch(lines[i].trim())) {
        start = i;
        break;
      }
    }
    final List<String> section;
    if (start >= 0) {
      var end = lines.length;
      for (var i = start + 1; i < lines.length; i++) {
        if (lines[i].trimLeft().startsWith('## ')) {
          end = i;
          break;
        }
      }
      section = lines.sublist(start + 1, end);
    } else {
      section = lines;
    }

    final cleaned = <String>[];
    for (final raw in section) {
      final t = raw.trimRight().trimLeft();
      if (t.startsWith('|')) continue; // 表格行不适合纯文本展示
      if (t == '---') continue;
      if (t.startsWith('**发布日期**') || t.startsWith('**版本号**')) continue;
      var line = t.replaceFirst(RegExp(r'^#{1,6}\s*'), '');
      line = line.replaceAll('**', '');
      cleaned.add(line);
    }
    // 压缩连续空行
    final out = <String>[];
    var blank = 0;
    for (final l in cleaned) {
      if (l.trim().isEmpty) {
        blank++;
        if (blank > 1) continue;
      } else {
        blank = 0;
      }
      out.add(l);
    }
    final text = out.join('\n').trim();
    if (text.isEmpty) return '';
    const maxLen = 1200;
    return text.length > maxLen ? '${text.substring(0, maxLen)}…' : text;
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
    required this.assetSizeForPlatform,
  });

  final String currentVersion;
  final String currentBuildNumber;
  final AppUpdateManifest manifest;
  final bool updateAvailable;
  /// 当前平台对应的安装包或商店链接；可能为空（仅展示说明）
  final String? downloadUrlForPlatform;
  /// 当前平台安装包大小（字节）；未知为 null
  final int? assetSizeForPlatform;
}

/// 从 GitHub 最新 Release 拉取版本、对比版本号；供「我的」页与更新页使用。
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
    return core.split('.').map((e) {
      // 兼容字母后缀（如 3.0.2B 中的 "2B" → 2）
      final digits = RegExp(r'^\d+').firstMatch(e.trim())?.group(0);
      return int.tryParse(digits ?? '') ?? 0;
    }).toList();
  }

  static String fmtBytes(int n) {
    const kb = 1024.0;
    const mb = kb * 1024;
    const gb = mb * 1024;
    final v = n.toDouble();
    if (v >= gb) return '${(v / gb).toStringAsFixed(2)}GB';
    if (v >= mb) return '${(v / mb).toStringAsFixed(2)}MB';
    if (v >= kb) return '${(v / kb).toStringAsFixed(0)}KB';
    return '${n}B';
  }

  /// 进度展示用的有效总大小：优先取下载响应的 Content-Length；
  /// 下载尚未开始/响应未给出长度时回退到 manifest 资产大小，避免只显示 0B。
  static int? effectiveTotalBytes(int? responseContentLength, int? manifestAssetSize) {
    if (responseContentLength != null && responseContentLength > 0) {
      return responseContentLength;
    }
    if (manifestAssetSize != null && manifestAssetSize > 0) {
      return manifestAssetSize;
    }
    return null;
  }

  /// 下载进度区的大小文案：
  /// 下载前（尚未下载到字节且未处于下载/暂停/完成态）显示安装包总大小；
  /// 下载中/暂停/完成后显示「已下载 / 总大小（百分比）」；总大小未知时只显示已下载。
  static String formatDownloadSizeText({
    required AppUpdateDownloadState state,
    required int downloadedBytes,
    int? totalBytes,
    int? manifestAssetSize,
  }) {
    final total = effectiveTotalBytes(totalBytes, manifestAssetSize);
    final notStarted = downloadedBytes == 0 &&
        state != AppUpdateDownloadState.downloading &&
        state != AppUpdateDownloadState.paused &&
        state != AppUpdateDownloadState.completed;
    if (notStarted) {
      return total != null ? '更新文件：${fmtBytes(total)}' : '更新文件：大小未知';
    }
    if (total == null) return fmtBytes(downloadedBytes);
    final frac = (downloadedBytes / total).clamp(0.0, 1.0);
    final percent = (frac * 100).toStringAsFixed(0);
    return '${fmtBytes(downloadedBytes)} / ${fmtBytes(total)}（$percent%）';
  }

  String? _urlForThisPlatform(Map<String, String> urls) {
    if (kIsWeb) return null;
    if (Platform.isWindows) return _nonEmpty(urls['windows']);
    if (Platform.isIOS) return _nonEmpty(urls['ios']);
    if (Platform.isAndroid) return _nonEmpty(urls['android']);
    if (Platform.isLinux) return _nonEmpty(urls['linux']);
    return null;
  }

  int? _sizeForThisPlatform(Map<String, int> sizes) {
    if (kIsWeb) return null;
    String? key;
    if (Platform.isWindows) key = 'windows';
    if (Platform.isIOS) key = 'ios';
    if (Platform.isAndroid) key = 'android';
    if (Platform.isLinux) key = 'linux';
    final v = key == null ? null : sizes[key];
    return (v != null && v > 0) ? v : null;
  }

  String? _nonEmpty(String? s) {
    final t = (s ?? '').trim();
    return t.isEmpty ? null : t;
  }

  /// 测试钩子：替换版本检查的 HTTP GET 实现（默认走 package:http）。
  @visibleForTesting
  static Future<http.Response> Function(Uri uri, Map<String, String> headers)?
      debugCheckHttpGet;

  /// 进行中的检查：并发调用（手动检查与静默检查）复用同一次请求，
  /// 避免重复请求与 statusNotifier 交错写入。
  Future<AppUpdateManualCheckResult>? _inFlightCheck;
  Future<AppUpdateCheckResult>? _inFlightSilentlyView;

  /// 静默检查：检索 GitHub 固定仓库的最新 Release 并比对版本号。
  /// 任何失败（网络异常、限流 403、响应异常等）都只返回
  /// [AppUpdateCheckResult.failed]，不区分原因、不写状态、不抛异常。
  Future<AppUpdateCheckResult> checkSilently() {
    if (kIsWeb) return Future.value(AppUpdateCheckResult.failed);
    final inFlight = _inFlightSilentlyView;
    if (inFlight != null) return inFlight;
    late final Future<AppUpdateCheckResult> future;
    future = checkManually().then((detail) {
      return switch (detail) {
        AppUpdateManualCheckResult.updateAvailable =>
          AppUpdateCheckResult.updateAvailable,
        AppUpdateManualCheckResult.upToDate => AppUpdateCheckResult.upToDate,
        _ => AppUpdateCheckResult.failed,
      };
    }).whenComplete(() {
      if (identical(_inFlightSilentlyView, future)) {
        _inFlightSilentlyView = null;
      }
    });
    _inFlightSilentlyView = future;
    return future;
  }

  /// 手动检查（「关于版本」页「检测更新」按钮）：与静默检查共享同一次
  /// 进行中的请求，但返回细粒度结果，便于区分网络失败与限流（403）。
  Future<AppUpdateManualCheckResult> checkManually() {
    if (kIsWeb) return Future.value(AppUpdateManualCheckResult.failed);
    final inFlight = _inFlightCheck;
    if (inFlight != null) return inFlight;
    final future = _doCheck();
    _inFlightCheck = future;
    unawaited(future.whenComplete(() {
      if (identical(_inFlightCheck, future)) _inFlightCheck = null;
    }));
    return future;
  }

  Future<AppUpdateManualCheckResult> _doCheck() async {
    try {
      const headers = {
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'hibi-2023-updater',
      };
      final fetch = debugCheckHttpGet ??
          (Uri uri, Map<String, String> hdrs) => http.get(uri, headers: hdrs);
      final resp = await fetch(Uri.parse(kUpdateGithubLatestApi), headers)
          .timeout(const Duration(seconds: 12));
      if (resp.statusCode == 404) {
        // 仓库尚未发布任何 Release，视为当前已是最新
        return AppUpdateManualCheckResult.upToDate;
      }
      if (resp.statusCode == 403) {
        // GitHub API 限流（未鉴权 60 次/小时/IP）
        return AppUpdateManualCheckResult.rateLimited;
      }
      if (resp.statusCode != 200) return AppUpdateManualCheckResult.failed;
      final data = jsonDecode(utf8.decode(resp.bodyBytes));
      if (data is! Map<String, dynamic>) {
        return AppUpdateManualCheckResult.failed;
      }
      final manifest = AppUpdateManifest.fromGithubRelease(data);
      if (manifest == null) return AppUpdateManualCheckResult.failed;
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
        assetSizeForPlatform: _sizeForThisPlatform(manifest.sizes),
      );
      return hasUpdate
          ? AppUpdateManualCheckResult.updateAvailable
          : AppUpdateManualCheckResult.upToDate;
    } on SocketException {
      return AppUpdateManualCheckResult.networkFailed;
    } on TimeoutException {
      return AppUpdateManualCheckResult.networkFailed;
    } on http.ClientException {
      return AppUpdateManualCheckResult.networkFailed;
    } catch (_) {
      return AppUpdateManualCheckResult.failed;
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

  /// 当前下载任务（按 URL 复用）：更新页退出后下载在后台继续；
  /// 以相同 URL 重新创建时返回原任务以恢复进度展示；
  /// URL 变化（如发布了更新版本）时取消旧任务，避免孤儿下载写盘。
  AppUpdateDownloadTask? _activeDownloadTask;

  /// 可暂停/继续/取消的下载任务（Android/Windows/Linux）。
  AppUpdateDownloadTask createDownloadTask(String httpsUrl) {
    final existing = _activeDownloadTask;
    if (existing != null && existing.url == httpsUrl) return existing;
    if (existing != null) unawaited(existing.cancel());
    final task = AppUpdateDownloadTask._(httpsUrl);
    _activeDownloadTask = task;
    return task;
  }

  /// 测试钩子：清除缓存的下载任务引用。
  @visibleForTesting
  void debugClearActiveDownloadTask() {
    _activeDownloadTask = null;
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

/// 可暂停/继续/取消的流式下载任务（Android/Windows/Linux）。
///
/// 状态机：`idle → downloading → paused → downloading … → completed`；
/// `downloading/paused → cancelled`；`downloading → error`（可再次 start 重试）。
/// `start()` 按候选 URL（直链 → 镜像）依次尝试；连接层失败会切换候选。
/// 传输中断进入 error 时**保留半成品**，重试时带 `Range` 断点续传。
/// 暂停优先用响应流 pause/resume（TCP 背压）；若连接已失效则 Range 续传。
/// 取消会删除临时半成品；Android 下载期间持有 WakeLock 并更新通知栏进度。
class AppUpdateDownloadTask {
  AppUpdateDownloadTask._(this.url);

  final String url;

  /// 连接/响应等待超时；默认缩短为 5s，失败更快切下一候选。测试可覆盖。
  @visibleForTesting
  static Duration debugConnectTimeout = const Duration(seconds: 5);

  /// 传输中断后的自动重试次数（不含首次）。
  @visibleForTesting
  static int debugMaxAutoRetries = 2;

  /// 测试钩子：替换候选 URL 构建逻辑（默认 [buildDownloadUrlCandidates]）。
  @visibleForTesting
  static List<String> Function(String originalUrl) debugBuildUrlCandidates =
      buildDownloadUrlCandidates;

  /// 测试钩子：关闭通知/WakeLock 副作用。
  @visibleForTesting
  static bool debugDisableKeepAlive = false;

  final ValueNotifier<AppUpdateDownloadProgress> progressNotifier =
      ValueNotifier<AppUpdateDownloadProgress>(const AppUpdateDownloadProgress(state: AppUpdateDownloadState.idle));

  HttpClient? _client;
  StreamSubscription<List<int>>? _sub;
  IOSink? _sink;
  File? _file;
  int _downloaded = 0;
  int? _total;
  bool _cancelled = false;
  bool _startInFlight = false;
  bool _resumeFromPartial = false;
  DateTime? _lastTickAt;
  int _lastTickBytes = 0;
  Completer<void>? _runCompleter;
  int _autoRetryLeft = 0;
  DateTime? _lastNotifyAt;
  /// 上次成功建立传输的候选索引；中断续传时优先从此索引起，避免反复卡在慢直连。
  int _preferredCandidateIndex = 0;
  /// 当前正在传输的候选索引（传输失败时可切下一镜像续传）。
  int _activeCandidateIndex = 0;

  AppUpdateDownloadState get state => progressNotifier.value.state;

  void _emit(AppUpdateDownloadState state, {int? speed, String? message}) {
    progressNotifier.value = AppUpdateDownloadProgress(
      state: state,
      downloadedBytes: _downloaded,
      totalBytes: _total,
      speedBytesPerSec: speed,
      message: message,
      filePath: _file?.path,
    );
    _maybePublishKeepAlive(state);
  }

  void _maybePublishKeepAlive(AppUpdateDownloadState state) {
    if (debugDisableKeepAlive || kIsWeb) return;
    final now = DateTime.now();
    final throttle = state == AppUpdateDownloadState.downloading &&
        _lastNotifyAt != null &&
        now.difference(_lastNotifyAt!) < const Duration(milliseconds: 700);
    if (throttle) return;
    _lastNotifyAt = now;
    unawaited(
      AppUpdateDownloadKeepAlive.instance.publishProgress(progressNotifier.value),
    );
  }

  void _finishRun() {
    final c = _runCompleter;
    _runCompleter = null;
    if (c != null && !c.isCompleted) c.complete();
  }

  /// 开始（或出错/取消后重试）下载。
  /// 若存在半成品且状态为 error，将尝试 Range 断点续传。
  /// 重入安全：下载中/暂停中/启动流程进行中的重复调用直接忽略。
  Future<void> start() async {
    if (state == AppUpdateDownloadState.downloading ||
        state == AppUpdateDownloadState.paused ||
        _startInFlight) {
      return;
    }
    _startInFlight = true;
    _autoRetryLeft = debugMaxAutoRetries;
    try {
      await _startInner(resumePreferred: state == AppUpdateDownloadState.error);
    } finally {
      _startInFlight = false;
    }
  }

  Future<void> _startInner({required bool resumePreferred}) async {
    if (kIsWeb) return;
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) {
      _emit(AppUpdateDownloadState.error, message: '无效的下载地址');
      return;
    }
    if (Platform.isIOS) {
      _emit(AppUpdateDownloadState.error, message: 'iOS 请跳转外部链接更新');
      return;
    }
    _cancelled = false;

    try {
      final dir = await getTemporaryDirectory();
      String name =
          uri.pathSegments.isNotEmpty ? uri.pathSegments.last : 'update.bin';
      if (!name.contains('.')) {
        if (Platform.isWindows) name = '$name.exe';
        if (Platform.isAndroid) name = '$name.apk';
        if (Platform.isLinux) name = '$name.AppImage';
      }
      _file = File('${dir.path}${Platform.pathSeparator}hibi_update_$name');
      await _deleteStaleUpdateFiles(dir, keepName: 'hibi_update_$name');
      final exists = await _file!.exists();
      final existingLen = exists ? await _file!.length() : 0;
      _resumeFromPartial = resumePreferred && existingLen > 0;
      if (!_resumeFromPartial) {
        if (exists) await _file!.delete();
        _downloaded = 0;
        _total = null;
      } else {
        _downloaded = existingLen;
      }
    } catch (e) {
      _emit(AppUpdateDownloadState.error, message: '无法创建临时文件：$e');
      return;
    }

    if (!debugDisableKeepAlive) {
      unawaited(AppUpdateDownloadKeepAlive.instance.begin());
    }
    _emit(
      AppUpdateDownloadState.downloading,
      message: _resumeFromPartial ? '正在断点续传…' : null,
    );

    final candidates = debugBuildUrlCandidates(url);
    Object? lastError;
    var sawConnectionError = false;

    // 从上次成功候选起轮转，再扫完整列表，减少国内反复卡在慢源。
    final order = <int>[];
    final start = _preferredCandidateIndex.clamp(0, candidates.length - 1);
    for (var i = start; i < candidates.length; i++) {
      order.add(i);
    }
    for (var i = 0; i < start; i++) {
      order.add(i);
    }

    for (final i in order) {
      if (_cancelled) return;
      final candidateUri = Uri.tryParse(candidates[i]);
      if (candidateUri == null || !candidateUri.hasScheme) continue;
      final isMirror = candidates[i] != url;
      if (i != start && !_resumeFromPartial) {
        _downloaded = 0;
        _total = null;
        _emit(
          AppUpdateDownloadState.downloading,
          message: isMirror ? '正在通过加速源下载…' : '正在直连 GitHub 下载…',
        );
      } else if (i != start && _resumeFromPartial) {
        _emit(
          AppUpdateDownloadState.downloading,
          message: isMirror ? '正在通过加速源续传…' : '正在直连 GitHub 续传…',
        );
      }

      _activeCandidateIndex = i;
      final ok = await _tryCandidate(
        candidateUri,
        onConnectionError: (e) {
          sawConnectionError = true;
          lastError = e;
        },
        onOtherError: (e) {
          lastError = e;
        },
      );
      if (ok) {
        _preferredCandidateIndex = i;
        return;
      }
      if (_cancelled) return;
    }

    if (!_cancelled) {
      _emit(
        AppUpdateDownloadState.error,
        message: _allCandidatesFailedMessage(lastError, sawConnectionError),
      );
      if (!debugDisableKeepAlive) {
        unawaited(AppUpdateDownloadKeepAlive.instance.end(clearNotification: false));
      }
    }
    _finishRun();
  }

  /// 尝试单个候选；成功开始传输并等待结束后返回 true；可继续下一候选返回 false。
  Future<bool> _tryCandidate(
    Uri candidateUri, {
    required void Function(Object e) onConnectionError,
    required void Function(Object e) onOtherError,
  }) async {
    final client = HttpClient()..connectionTimeout = debugConnectTimeout;
    _client = client;
    HttpClientResponse resp;
    final resumeAt = _resumeFromPartial ? _downloaded : 0;
    try {
      final req = await client.getUrl(candidateUri).timeout(debugConnectTimeout);
      if (resumeAt > 0) {
        req.headers.set(HttpHeaders.rangeHeader, 'bytes=$resumeAt-');
      }
      resp = await req.close().timeout(debugConnectTimeout);
    } on TimeoutException catch (e) {
      onConnectionError(e);
      _closeClient(force: true);
      return false;
    } on SocketException catch (e) {
      onConnectionError(e);
      _closeClient(force: true);
      return false;
    } on HandshakeException catch (e) {
      onConnectionError(e);
      _closeClient(force: true);
      return false;
    } catch (e) {
      onOtherError(e);
      _closeClient(force: true);
      return false;
    }

    if (_cancelled) {
      _closeClient(force: true);
      return true;
    }

    final code = resp.statusCode;
    if (resumeAt > 0 && code == HttpStatus.ok) {
      // 服务端忽略 Range：从头覆盖
      _downloaded = 0;
      _total = null;
      _resumeFromPartial = false;
      try {
        if (await _file!.exists()) await _file!.delete();
      } catch (_) {}
    } else if (resumeAt > 0 && code != HttpStatus.partialContent) {
      onOtherError(
        HttpException('服务器返回错误 ($code)', uri: candidateUri),
      );
      _closeClient(force: true);
      return false;
    } else if (resumeAt <= 0 && code != HttpStatus.ok) {
      onOtherError(
        HttpException('服务器返回错误 ($code)', uri: candidateUri),
      );
      _closeClient(force: true);
      return false;
    }

    final contentLen = resp.contentLength;
    if (code == HttpStatus.partialContent) {
      final cr = resp.headers.value(HttpHeaders.contentRangeHeader);
      final m = cr == null
          ? null
          : RegExp(r'bytes\s+(\d+)-(\d+)/(\d+|\*)').firstMatch(cr);
      if (m != null) {
        final totalRaw = m.group(3);
        if (totalRaw != null && totalRaw != '*') {
          _total = int.tryParse(totalRaw);
        }
      } else if (contentLen > 0) {
        _total = resumeAt + contentLen;
      }
    } else if (contentLen > 0) {
      _total = contentLen;
    }

    _sink = _file!.openWrite(
      mode: _downloaded > 0 ? FileMode.append : FileMode.write,
    );
    _lastTickAt = DateTime.now();
    _lastTickBytes = _downloaded;

    final run = Completer<void>();
    _runCompleter = run;
    _sub = resp.listen(
      _onChunk,
      onDone: _onDone,
      onError: _onError,
      cancelOnError: true,
    );
    await run.future;
    return true;
  }

  String _allCandidatesFailedMessage(Object? lastError, bool sawConnectionError) {
    // 出现过连接层失败（域名不可达/超时）：给出代理建议
    if (sawConnectionError) {
      return '网络连接失败：GitHub 下载域名不可达，建议开启代理后重试';
    }
    if (lastError is HttpException) return lastError.message;
    if (lastError != null) return _friendlyError(lastError);
    return '下载失败，请重试';
  }

  void _onChunk(List<int> chunk) {
    if (_cancelled) return;
    _sink?.add(chunk);
    _downloaded += chunk.length;

    final now = DateTime.now();
    final dt = now.difference(_lastTickAt ?? now);
    int? speed;
    if (dt.inMilliseconds >= 500) {
      speed = ((_downloaded - _lastTickBytes) * 1000) ~/ dt.inMilliseconds;
      _lastTickAt = now;
      _lastTickBytes = _downloaded;
    }
    _emit(AppUpdateDownloadState.downloading, speed: speed);
  }

  Future<void> _onDone() async {
    await _closeSink();
    _closeClient();
    if (!_cancelled) {
      final total = _total;
      if (total != null && total > 0 && _downloaded < total) {
        _handleTransferFailure('下载中断，文件不完整，请重试');
      } else {
        _emit(AppUpdateDownloadState.completed);
        if (!debugDisableKeepAlive) {
          unawaited(
            AppUpdateDownloadKeepAlive.instance.end(clearNotification: false),
          );
          unawaited(
            AppUpdateDownloadKeepAlive.instance
                .publishProgress(progressNotifier.value),
          );
        }
      }
    }
    _finishRun();
  }

  Future<void> _onError(Object e) async {
    await _closeSink();
    _closeClient(force: true);
    if (!_cancelled) {
      _handleTransferFailure(_friendlyError(e));
    }
    _finishRun();
  }

  /// 传输中断：保留半成品；若仍有自动重试额度则静默 Range 续传。
  /// 连续失败时推进首选候选索引，避免永远卡在慢直连。
  /// 返回 true 表示已安排自动续传（调用方仍应 `_finishRun` 结束当前流）。
  bool _handleTransferFailure(String message) {
    if (_autoRetryLeft > 0 && !_cancelled && _file != null && _downloaded > 0) {
      _autoRetryLeft--;
      _resumeFromPartial = true;
      // 当前候选传输失败：下次从下一候选开始（含镜像）
      _preferredCandidateIndex = _activeCandidateIndex + 1;
      _emit(
        AppUpdateDownloadState.downloading,
        message: '连接中断，正在切换线路续传（剩 $_autoRetryLeft 次）…',
      );
      unawaited(_autoResumeAfterFailure());
      return true;
    }
    _emit(AppUpdateDownloadState.error, message: message);
    if (!debugDisableKeepAlive) {
      unawaited(AppUpdateDownloadKeepAlive.instance.end(clearNotification: false));
    }
    return false;
  }

  Future<void> _autoResumeAfterFailure() async {
    // 等待当前 start()/listen 栈退出，避免与 _startInFlight 互锁
    await Future<void>.delayed(const Duration(milliseconds: 500));
    if (_cancelled) return;
    if (state != AppUpdateDownloadState.downloading &&
        state != AppUpdateDownloadState.error) {
      return;
    }
    while (_startInFlight) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      if (_cancelled) return;
    }
    _startInFlight = true;
    try {
      await _startInner(resumePreferred: true);
    } finally {
      _startInFlight = false;
    }
  }

  String _friendlyError(Object e) {
    if (e is SocketException) return '网络连接失败，请检查网络后重试';
    if (e is HttpException) return e.message;
    if (e is TimeoutException) return '连接超时，请检查网络后重试';
    return '下载中断，请重试（$e）';
  }

  /// 暂停：挂起响应流订阅（TCP 背压，真暂停，不断开连接）。
  void pause() {
    if (state != AppUpdateDownloadState.downloading) return;
    _sub?.pause();
    _emit(AppUpdateDownloadState.paused);
  }

  /// 继续：恢复被挂起的响应流；若连接已失效则改走 Range 续传。
  void resume() {
    if (state != AppUpdateDownloadState.paused) return;
    final sub = _sub;
    if (sub != null) {
      _emit(AppUpdateDownloadState.downloading);
      try {
        sub.resume();
        return;
      } catch (_) {}
    }
    // 流已失效：Range 重连
    _emit(AppUpdateDownloadState.downloading, message: '正在断点续传…');
    unawaited(_resumeWithRange());
  }

  Future<void> _resumeWithRange() async {
    if (_startInFlight) return;
    _startInFlight = true;
    try {
      await _startInner(resumePreferred: true);
    } finally {
      _startInFlight = false;
    }
  }

  /// 取消：中断订阅与连接，删除临时半成品文件，状态复位为 cancelled。
  Future<void> cancel({bool deletePartial = true}) async {
    if (state != AppUpdateDownloadState.downloading &&
        state != AppUpdateDownloadState.paused) {
      return;
    }
    _cancelled = true;
    _autoRetryLeft = 0;
    final sub = _sub;
    _sub = null;
    if (sub != null) {
      try {
        sub.resume(); // 若处于暂停态，先恢复以便 cancel 立即生效
        await sub.cancel();
      } catch (_) {}
    }
    _closeClient(force: true);
    await _closeSink();
    if (deletePartial) await _deleteFileQuietly();
    _downloaded = 0;
    _total = null;
    progressNotifier.value =
        const AppUpdateDownloadProgress(state: AppUpdateDownloadState.cancelled);
    if (!debugDisableKeepAlive) {
      unawaited(AppUpdateDownloadKeepAlive.instance.end());
    }
    _finishRun();
  }

  Future<void> _deleteFileQuietly() async {
    try {
      final f = _file;
      if (f != null && await f.exists()) await f.delete();
    } catch (_) {}
  }

  static String _baseName(String path) =>
      path.split(RegExp(r'[\\/]')).last;

  /// 删除临时目录中除当前目标外的所有 hibi_update_* 安装包。
  static Future<void> _deleteStaleUpdateFiles(Directory dir,
      {required String keepName}) async {
    try {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        final name = _baseName(entity.path);
        if (name == keepName || !name.startsWith('hibi_update_')) continue;
        try {
          await entity.delete();
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<void> _closeSink() async {
    final sink = _sink;
    _sink = null;
    if (sink == null) return;
    try {
      await sink.flush();
    } catch (_) {}
    try {
      await sink.close();
    } catch (_) {}
  }

  void _closeClient({bool force = false}) {
    final client = _client;
    _client = null;
    try {
      client?.close(force: force);
    } catch (_) {}
  }
}
