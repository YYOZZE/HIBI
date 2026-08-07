import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/auth_user.dart';
import 'auth_api.dart';

/// 对接后端账户接口：登录、注册、退出（详见 AUTH_SPEC.md）
class HttpAuthApi implements AuthApi {
  HttpAuthApi({required this.baseUrl}) : assert(baseUrl.isNotEmpty);

  final String baseUrl;

  String get _loginUrl => '$baseUrl/api/auth/login';
  String get _registerUrl => '$baseUrl/api/auth/register';
  String get _logoutUrl => '$baseUrl/api/auth/logout';
  String get _captchaConfigUrl => '$baseUrl/api/auth/captcha_config';
  String get _captchaChallengeUrl => '$baseUrl/api/auth/captcha/challenge';
  String get _captchaChallengeStatusUrl => '$baseUrl/api/auth/captcha/challenge_status';
  String get _captchaVerifyUrl => '$baseUrl/api/auth/captcha/verify';
  String get _profileUrl => '$baseUrl/api/auth/profile';

  @override
  Future<AuthUser?> login(
    String phoneOrEmail,
    String password, {
    String? captchaPlatform,
    String? captchaChallengeId,
    String? lotNumber,
    String? captchaOutput,
    String? passToken,
    String? genTime,
  }) async {
    final res = await http
        .post(
          Uri.parse(_loginUrl),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'phone_or_email': phoneOrEmail.trim(),
            'password': password,
            if (captchaPlatform != null && captchaPlatform.isNotEmpty)
              'captcha_platform': captchaPlatform,
            if (captchaChallengeId != null && captchaChallengeId.isNotEmpty)
              'captcha_challenge_id': captchaChallengeId,
            if (lotNumber != null && lotNumber.isNotEmpty) 'lot_number': lotNumber,
            if (captchaOutput != null && captchaOutput.isNotEmpty) 'captcha_output': captchaOutput,
            if (passToken != null && passToken.isNotEmpty) 'pass_token': passToken,
            if (genTime != null && genTime.isNotEmpty) 'gen_time': genTime,
          }),
        )
        .timeout(const Duration(seconds: 15));
    return _parseAuthResponse(res);
  }

  @override
  Future<AuthUser?> register({
    required String phoneOrEmail,
    required String password,
    String? nickname,
    String? inviteCode,
    String? captchaPlatform,
    String? captchaChallengeId,
    String? lotNumber,
    String? captchaOutput,
    String? passToken,
    String? genTime,
  }) async {
    final res = await http
        .post(
          Uri.parse(_registerUrl),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'phone_or_email': phoneOrEmail.trim(),
            'password': password,
            if (nickname != null && nickname.trim().isNotEmpty) 'nickname': nickname.trim(),
            if (inviteCode != null && inviteCode.trim().isNotEmpty) 'invite_code': inviteCode.trim(),
            if (captchaPlatform != null && captchaPlatform.isNotEmpty)
              'captcha_platform': captchaPlatform,
            if (captchaChallengeId != null && captchaChallengeId.isNotEmpty)
              'captcha_challenge_id': captchaChallengeId,
            if (lotNumber != null && lotNumber.isNotEmpty) 'lot_number': lotNumber,
            if (captchaOutput != null && captchaOutput.isNotEmpty) 'captcha_output': captchaOutput,
            if (passToken != null && passToken.isNotEmpty) 'pass_token': passToken,
            if (genTime != null && genTime.isNotEmpty) 'gen_time': genTime,
          }),
        )
        .timeout(const Duration(seconds: 15));
    return _parseAuthResponse(res);
  }

  @override
  Future<void> logout(String token) async {
    await http
        .post(
          Uri.parse(_logoutUrl),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
          },
        )
        .timeout(const Duration(seconds: 5));
  }

  @override
  Future<Map<String, dynamic>?> getCaptchaConfig({required String platform}) async {
    final res = await http
        .get(Uri.parse('$_captchaConfigUrl?platform=${Uri.encodeQueryComponent(platform)}'))
        .timeout(const Duration(seconds: 8));
    if (res.statusCode != 200) return null;
    try {
      final data = jsonDecode(res.body) as Map<String, dynamic>?;
      return data;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<Map<String, dynamic>?> createCaptchaChallenge({required String platform}) async {
    final res = await http
        .post(
          Uri.parse(_captchaChallengeUrl),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'platform': platform}),
        )
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) return null;
    try {
      return jsonDecode(res.body) as Map<String, dynamic>?;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<Map<String, dynamic>?> getCaptchaChallengeStatus({required String challengeId}) async {
    final res = await http
        .get(
          Uri.parse('$_captchaChallengeStatusUrl?challenge_id=${Uri.encodeQueryComponent(challengeId)}'),
        )
        .timeout(const Duration(seconds: 8));
    if (res.statusCode != 200) return null;
    try {
      return jsonDecode(res.body) as Map<String, dynamic>?;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<bool> verifyCaptchaChallenge({
    required String challengeId,
    required String platform,
    required String lotNumber,
    required String captchaOutput,
    required String passToken,
    required String genTime,
  }) async {
    final res = await http
        .post(
          Uri.parse(_captchaVerifyUrl),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'challenge_id': challengeId,
            'platform': platform,
            'lot_number': lotNumber,
            'captcha_output': captchaOutput,
            'pass_token': passToken,
            'gen_time': genTime,
          }),
        )
        .timeout(const Duration(seconds: 12));
    if (res.statusCode != 200) {
      String msg = res.body;
      try {
        final data = jsonDecode(res.body) as Map<String, dynamic>?;
        msg = data?['message']?.toString() ?? data?['error']?.toString() ?? msg;
      } catch (_) {}
      throw Exception(msg);
    }
    try {
      final data = jsonDecode(res.body) as Map<String, dynamic>?;
      return data?['ok'] == true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<AuthUser?> fetchProfile(String token) async {
    final res = await http
        .get(
          Uri.parse(_profileUrl),
          headers: {'Authorization': 'Bearer $token'},
        )
        .timeout(const Duration(seconds: 10));
    return _parseAuthResponse(res, requireToken: false, fallbackToken: token);
  }

  @override
  Future<AuthUser?> updateProfile(
    String token, {
    String? nickname,
    String? avatarUrl,
  }) async {
    final body = <String, dynamic>{};
    if (nickname != null) body['nickname'] = nickname;
    if (avatarUrl != null) body['avatar_url'] = avatarUrl;
    final res = await http
        .put(
          Uri.parse(_profileUrl),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
          },
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 10));
    return _parseAuthResponse(res, requireToken: false, fallbackToken: token);
  }

  AuthUser? _parseAuthResponse(
    http.Response res, {
    bool requireToken = true,
    String? fallbackToken,
  }) {
    if (res.statusCode != 200) {
      String msg = res.body;
      try {
        final data = jsonDecode(res.body) as Map<String, dynamic>?;
        msg = data?['message']?.toString() ?? data?['error']?.toString() ?? msg;
      } catch (_) {}
      throw Exception(msg);
    }
    final data = jsonDecode(res.body) as Map<String, dynamic>?;
    if (data == null) return null;
    final token = data['token']?.toString() ?? fallbackToken;
    final userId = data['user_id']?.toString() ?? data['userId']?.toString() ?? '';
    final phoneOrEmail = data['phone_or_email']?.toString() ?? data['phoneOrEmail']?.toString() ?? '';
    final nickname = data['nickname']?.toString();
    final avatarUrl = data['avatar_url']?.toString() ?? data['avatarUrl']?.toString();
    if (requireToken && (token == null || token.isEmpty)) return null;
    if (token == null || token.isEmpty) return null;
    return AuthUser(
      userId: userId,
      phoneOrEmail: phoneOrEmail,
      nickname: nickname,
      avatarUrl: avatarUrl,
      token: token,
    );
  }
}
