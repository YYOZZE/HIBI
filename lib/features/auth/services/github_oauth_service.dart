import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../config/github_oauth_config.dart';

/// 构造带预填 [userCode] 的 Device 验证页 URL。
///
/// GitHub 支持 `https://github.com/login/device?user_code=XXXX-XXXX`；
/// 若响应已含 `verification_uri_complete` 则优先使用，否则在 [baseUri] 上补齐参数。
String githubDeviceVerificationUri({
  required String userCode,
  String baseUri = 'https://github.com/login/device',
  String? verificationUriComplete,
}) {
  final complete = verificationUriComplete?.trim();
  if (complete != null && complete.isNotEmpty) {
    final parsed = Uri.tryParse(complete);
    if (parsed != null &&
        (parsed.queryParameters['user_code']?.trim().isNotEmpty ?? false)) {
      return complete;
    }
  }
  final code = userCode.trim().toUpperCase();
  final base = Uri.tryParse(
        baseUri.trim().isEmpty ? 'https://github.com/login/device' : baseUri.trim(),
      ) ??
      Uri.parse('https://github.com/login/device');
  final params = Map<String, String>.from(base.queryParameters);
  if (code.isNotEmpty) {
    params['user_code'] = code;
  }
  return base.replace(queryParameters: params).toString();
}

/// Device Flow 第一步返回的设备码信息。
class GitHubDeviceCode {
  const GitHubDeviceCode({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUri,
    required this.expiresIn,
    required this.interval,
    this.verificationUriComplete,
  });

  final String deviceCode;
  final String userCode;
  final String verificationUri;
  /// GitHub 可能返回的「已带 user_code」完整链接，优先用于内嵌 WebView。
  final String? verificationUriComplete;
  final int expiresIn;
  final int interval;

  /// 打开验证页用的最终 URL（与 [userCode]/[deviceCode] 同一次 device/code 响应）。
  /// 优先 API 的 verification_uri_complete，否则为带 user_code 的 verification_uri。
  String get bestVerificationUri {
    final cached = verificationUriComplete?.trim();
    if (cached != null && cached.isNotEmpty) return cached;
    return githubDeviceVerificationUri(
      userCode: userCode,
      baseUri: verificationUri,
    );
  }
}

/// GitHub 用户资料（/user）。
class GitHubUserProfile {
  const GitHubUserProfile({
    required this.id,
    required this.login,
    this.name,
    this.avatarUrl,
  });

  final String id;
  final String login;
  final String? name;
  final String? avatarUrl;
}

/// 面向用户的友好错误（UI 直接展示 [message]，勿再 toString 裸抛）。
class GitHubOAuthException implements Exception {
  const GitHubOAuthException(
    this.message, {
    this.canRetry = true,
    this.isNetwork = false,
  });

  final String message;
  final bool canRetry;
  /// 是否为连通性/超时类错误（UI 可引导代理/VPN 与系统浏览器）。
  final bool isNetwork;

  @override
  String toString() => message;
}

/// access_token 失效 / 被撤销（需重新走网页授权；不是网络抖动）。
class GitHubUnauthorizedException extends GitHubOAuthException {
  const GitHubUnauthorizedException([
    super.message = 'GitHub 授权已失效，请重新登录授权。',
  ]) : super(canRetry: true);
}

/// 无后端 GitHub OAuth Device Flow + Star 校验。
class GitHubOAuthService {
  GitHubOAuthService({
    http.Client? httpClient,
    FlutterSecureStorage? secureStorage,
  })  : _http = httpClient ?? _createHttpClient(),
        _ownsClient = httpClient == null,
        _secure = secureStorage ?? const FlutterSecureStorage();

  static final GitHubOAuthService instance = GitHubOAuthService();

  /// 稳定键名：升级 App 不得变更，否则会读不到旧 token。
  static const String _secureTokenKey = 'hibi_github_oauth_token';

  /// 单次连接超时（过长会让登录页一直转圈）。
  static const Duration connectTimeout = Duration(seconds: 12);

  /// 一般 API 请求超时。
  static const Duration requestTimeout = Duration(seconds: 30);

  /// 申请设备码超时（单独收紧，便于尽快给出「重试」）。
  static const Duration deviceCodeTimeout = Duration(seconds: 22);

  /// 申请设备码最大尝试次数（含首次）。
  static const int deviceCodeMaxAttempts = 2;

  final http.Client _http;
  final bool _ownsClient;
  final FlutterSecureStorage _secure;

  /// 使用环境代理（HTTP(S)_PROXY / ALL_PROXY）；Windows 下若已通过系统/
  /// 终端配置代理变量，Dart HttpClient 即可走代理直连 GitHub。
  ///
  /// 刻意不经第三方「GitHub 加速」反代 OAuth：token 与 device_code 不能交给
  /// 不可信中转，否则破坏 OAuth 安全。
  static http.Client _createHttpClient() {
    final inner = HttpClient()
      ..connectionTimeout = connectTimeout
      ..idleTimeout = const Duration(seconds: 60)
      ..userAgent = 'HIBI-Flutter-App'
      ..findProxy = HttpClient.findProxyFromEnvironment
      ..autoUncompress = true;
    return IOClient(inner);
  }

  void dispose() {
    if (_ownsClient) _http.close();
  }

  /// 请求设备码；失败时抛出 [GitHubOAuthException]。含有限次重试。
  Future<GitHubDeviceCode> requestDeviceCode() async {
    final id = GitHubOAuthConfig.clientId.trim();
    if (id.isEmpty) {
      throw const GitHubOAuthException(
        '未配置 GitHub OAuth Client ID。请确认 OAuth App 已创建并启用 Device Flow。',
        canRetry: false,
      );
    }

    Object? lastError;
    for (var attempt = 1; attempt <= deviceCodeMaxAttempts; attempt++) {
      try {
        final resp = await _postForm(
          Uri.parse('https://github.com/login/device/code'),
          {
            'client_id': id,
            'scope': GitHubOAuthConfig.scopes,
          },
          stepLabel: '申请设备码',
          timeout: deviceCodeTimeout,
        );
        if (resp.statusCode < 200 || resp.statusCode >= 300) {
          throw GitHubOAuthException(
            _httpStatusHint(resp.statusCode, '申请设备码失败', resp.body),
          );
        }
        final map = _decodeJsonMap(resp.body, stepLabel: '申请设备码');
        final deviceCode = map['device_code']?.toString() ?? '';
        final userCode = map['user_code']?.toString() ?? '';
        final uri = map['verification_uri']?.toString() ??
            'https://github.com/login/device';
        final uriComplete = map['verification_uri_complete']?.toString();
        if (deviceCode.isEmpty || userCode.isEmpty) {
          throw const GitHubOAuthException(
            '设备码响应无效，请重试或检查 OAuth App 是否启用 Device Flow。',
          );
        }
        // 只规范化一次：UI / 打开链接 / poll 必须共用这份结果，禁止后续再申请新码拼旧链接。
        final openUrl = githubDeviceVerificationUri(
          userCode: userCode,
          baseUri: uri,
          verificationUriComplete: uriComplete,
        );
        debugPrint(
          'GitHub device/code ok: user_code=$userCode '
          'device=${deviceCode.substring(0, 8)}… openUrl=$openUrl '
          'api_complete=${uriComplete ?? "(none)"}',
        );
        return GitHubDeviceCode(
          deviceCode: deviceCode,
          userCode: userCode.trim().toUpperCase(),
          verificationUri: uri,
          verificationUriComplete: openUrl,
          expiresIn: (map['expires_in'] as num?)?.toInt() ?? 900,
          interval: (map['interval'] as num?)?.toInt() ?? 5,
        );
      } catch (e) {
        lastError = e;
        final canRetryNetwork =
            e is GitHubOAuthException && e.isNetwork && e.canRetry;
        if (!canRetryNetwork) rethrow;
        if (attempt < deviceCodeMaxAttempts) {
          debugPrint('申请设备码第 $attempt 次失败，准备重试: $e');
          await Future<void>.delayed(Duration(seconds: attempt * 2));
          continue;
        }
      }
    }
    if (lastError is GitHubOAuthException) throw lastError;
    throw _mapNetworkError(lastError ?? 'unknown', '申请设备码');
  }

  /// 打开系统浏览器前往验证页或登录页（内嵌 WebView 失败时的兜底）。
  Future<bool> openVerificationPage(String verificationUri) async {
    final uri = Uri.tryParse(verificationUri);
    if (uri == null) return false;
    return launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  /// 轮询直到拿到 access_token，或超时/拒绝。
  /// [shouldCancel] 返回 true 时中止。
  Future<String> pollAccessToken(
    GitHubDeviceCode code, {
    bool Function()? shouldCancel,
  }) async {
    final id = GitHubOAuthConfig.clientId.trim();
    var interval = Duration(seconds: code.interval.clamp(5, 30));
    final deadline = DateTime.now().add(Duration(seconds: code.expiresIn));

    while (DateTime.now().isBefore(deadline)) {
      if (shouldCancel?.call() == true) {
        throw const GitHubOAuthException('已取消登录', canRetry: true);
      }
      await Future<void>.delayed(interval);
      if (shouldCancel?.call() == true) {
        throw const GitHubOAuthException('已取消登录', canRetry: true);
      }

      http.Response resp;
      try {
        resp = await _postForm(
          Uri.parse('https://github.com/login/oauth/access_token'),
          {
            'client_id': id,
            'device_code': code.deviceCode,
            'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
          },
          stepLabel: '等待授权',
        );
      } on GitHubOAuthException {
        // 轮询期间偶发超时：跳过本轮继续等，避免整段登录失败。
        continue;
      }

      Map<String, dynamic> map;
      try {
        map = _decodeJsonMap(resp.body, stepLabel: '等待授权');
      } catch (_) {
        continue;
      }

      final err = map['error']?.toString();
      if (err == null || err.isEmpty) {
        final token = map['access_token']?.toString() ?? '';
        if (token.isEmpty) {
          throw const GitHubOAuthException('未返回 access_token，请重试。');
        }
        final prefix = token.length >= 8 ? token.substring(0, 8) : token;
        debugPrint(
          'GitHub Device Flow: 已拿到 access_token（前缀 $prefix…，len=${token.length}）',
        );
        return token;
      }
      if (err == 'authorization_pending') {
        continue;
      }
      if (err == 'slow_down') {
        interval += const Duration(seconds: 5);
        continue;
      }
      if (err == 'expired_token') {
        debugPrint(
          'GitHub Device Flow: expired_token device=${code.deviceCode.substring(0, 8)}…',
        );
        throw const GitHubOAuthException('设备码已过期，请重新登录。');
      }
      if (err == 'access_denied') {
        // 仅当 GitHub 对「当前」device_code 明确返回拒绝（用户点了 Cancel）。
        debugPrint(
          'GitHub Device Flow: access_denied device=${code.deviceCode.substring(0, 8)}… '
          'user_code=${code.userCode}',
        );
        throw const GitHubOAuthException(
          '你已在 GitHub 网页上拒绝授权（点了 Cancel）。'
          '若并未点拒绝，请重试登录（可能是上一轮残留）。',
        );
      }
      debugPrint('GitHub Device Flow: unexpected error=$err');
      throw GitHubOAuthException('授权失败：$err');
    }
    throw const GitHubOAuthException('登录等待超时，请重新开始并在时限内完成网页授权。');
  }

  Future<GitHubUserProfile> fetchUser(String accessToken) async {
    final resp = await _getJson(
      Uri.parse('https://api.github.com/user'),
      headers: _apiHeaders(accessToken),
      stepLabel: '获取用户信息',
    );
    if (resp.statusCode == 401 || resp.statusCode == 403) {
      throw const GitHubUnauthorizedException();
    }
    if (resp.statusCode != 200) {
      throw GitHubOAuthException(
        _httpStatusHint(resp.statusCode, '获取 GitHub 用户失败', resp.body),
      );
    }
    final map = _decodeJsonMap(resp.body, stepLabel: '获取用户信息');
    final login = map['login']?.toString() ?? '';
    final id = map['id']?.toString() ?? login;
    if (login.isEmpty) {
      throw const GitHubOAuthException('GitHub 用户名为空，请重试。');
    }
    return GitHubUserProfile(
      id: id,
      login: login,
      name: map['name']?.toString(),
      avatarUrl: map['avatar_url']?.toString(),
    );
  }

  /// `true` = 已 Star；`false` = 未 Star。网络错误抛异常。
  Future<bool> hasStarredRepo(String accessToken) async {
    final uri = Uri.parse(
      'https://api.github.com/user/starred/'
      '${GitHubOAuthConfig.owner}/${GitHubOAuthConfig.repo}',
    );
    final resp = await _getJson(
      uri,
      headers: {
        ..._apiHeaders(accessToken),
        'Accept': 'application/vnd.github+json',
      },
      stepLabel: '检查 Star',
    );
    if (resp.statusCode == 204) {
      debugPrint('GitHub Star 校验: 204 → 已 Star ${GitHubOAuthConfig.repoFullName}');
      return true;
    }
    if (resp.statusCode == 404) {
      debugPrint('GitHub Star 校验: 404 → 未 Star ${GitHubOAuthConfig.repoFullName}');
      return false;
    }
    if (resp.statusCode == 401 || resp.statusCode == 403) {
      throw const GitHubUnauthorizedException();
    }
    throw GitHubOAuthException(
      _httpStatusHint(resp.statusCode, '检查 Star 状态失败', resp.body),
    );
  }

  /// 粗判是否像 GitHub OAuth token（Device Flow 常见 gho_ 前缀）。
  static bool looksLikeGitHubToken(String token) {
    final t = token.trim();
    if (t.isEmpty) return false;
    return t.startsWith('gho_') ||
        t.startsWith('ghu_') ||
        t.startsWith('ghs_') ||
        t.startsWith('github_pat_');
  }

  Future<bool> openRepoForStar() {
    return openVerificationPage(GitHubOAuthConfig.starUrl);
  }

  Future<void> saveTokenSecurely(String token) async {
    try {
      await _secure.write(key: _secureTokenKey, value: token);
    } catch (e) {
      debugPrint('secure_storage write failed: $e');
    }
  }

  Future<String?> readTokenSecurely() async {
    try {
      return await _secure.read(key: _secureTokenKey);
    } catch (e) {
      debugPrint('secure_storage read failed: $e');
      return null;
    }
  }

  Future<void> clearTokenSecurely() async {
    try {
      await _secure.delete(key: _secureTokenKey);
    } catch (_) {}
  }

  Map<String, String> _apiHeaders(String token) => {
        'Authorization': 'Bearer $token',
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        'User-Agent': 'HIBI-Flutter-App',
      };

  Future<http.Response> _postForm(
    Uri uri,
    Map<String, String> body, {
    required String stepLabel,
    Duration? timeout,
  }) async {
    try {
      return await _http
          .post(
            uri,
            headers: {
              'Accept': 'application/json',
              'Content-Type': 'application/x-www-form-urlencoded',
              'User-Agent': 'HIBI-Flutter-App',
            },
            body: body,
          )
          .timeout(timeout ?? requestTimeout);
    } catch (e) {
      throw _mapNetworkError(e, stepLabel);
    }
  }

  Future<http.Response> _getJson(
    Uri uri, {
    required Map<String, String> headers,
    required String stepLabel,
  }) async {
    try {
      return await _http.get(uri, headers: headers).timeout(requestTimeout);
    } catch (e) {
      throw _mapNetworkError(e, stepLabel);
    }
  }

  Map<String, dynamic> _decodeJsonMap(String body, {required String stepLabel}) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
      throw const FormatException('not a map');
    } catch (_) {
      throw GitHubOAuthException('$stepLabel 响应无法解析，请检查网络后重试。');
    }
  }

  GitHubOAuthException _mapNetworkError(Object e, String stepLabel) {
    if (e is GitHubOAuthException) return e;
    if (e is TimeoutException) {
      return GitHubOAuthException(
        '$stepLabel 超时，请重试',
        isNetwork: true,
      );
    }
    if (e is SocketException || e is HandshakeException) {
      return GitHubOAuthException(
        '无法连接 GitHub，请检查网络后重试',
        isNetwork: true,
      );
    }
    if (e is http.ClientException) {
      return GitHubOAuthException(
        '无法连接 GitHub，请重试',
        isNetwork: true,
      );
    }
    final s = e.toString().toLowerCase();
    if (s.contains('timeout') ||
        s.contains('semaphore') ||
        s.contains('failed host lookup') ||
        s.contains('connection')) {
      return const GitHubOAuthException(
        '网络不通，请重试',
        isNetwork: true,
      );
    }
    return GitHubOAuthException('$stepLabel 失败，请重试');
  }

  String _httpStatusHint(int status, String title, String body) {
    if (status == 401 || status == 403) {
      return '$title（$status）。请确认 OAuth App 的 Client ID 正确且已启用 Device Flow。';
    }
    if (status == 404) {
      return '$title（404）。请确认已启用 Device Flow。';
    }
    if (status == 429) {
      return '$title：请求过于频繁，请稍后再试。';
    }
    final snippet = body.length > 160 ? '${body.substring(0, 160)}…' : body;
    return '$title（$status）${snippet.isEmpty ? '' : '：$snippet'}';
  }

  /// 将任意异常转为用户可读中文。
  static String friendlyError(Object e) {
    if (e is GitHubOAuthException) return e.message;
    final s = e.toString().toLowerCase();
    if (s.contains('timeout') || s.contains('semaphore')) {
      return '连接超时，请重试';
    }
    return e
        .toString()
        .replaceFirst('Bad state: ', '')
        .replaceFirst('Exception: ', '')
        .replaceFirst('GitHubOAuthException: ', '');
  }

  static bool isNetworkError(Object e) {
    if (e is GitHubOAuthException) return e.isNetwork;
    final s = e.toString().toLowerCase();
    return s.contains('timeout') ||
        s.contains('semaphore') ||
        s.contains('socket') ||
        s.contains('failed host lookup') ||
        s.contains('connection');
  }
}
