import '../models/auth_user.dart';

/// 账户相关接口抽象，便于对接真实后端或 Mock
abstract class AuthApi {
  /// 图形认证参数（客户端 SDK 验证成功后返回）
  /// 对应 Alicaptcha：lot_number/captcha_output/pass_token/gen_time
  /// 仅当后端开启图形认证校验时必填。

  /// 登录：返回用户信息与 token，失败抛异常或返回 null（由实现约定）
  Future<AuthUser?> login(
    String phoneOrEmail,
    String password, {
    String? captchaPlatform,
    String? captchaChallengeId,
    String? lotNumber,
    String? captchaOutput,
    String? passToken,
    String? genTime,
  });

  /// 注册：成功返回用户信息与 token
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
  });

  /// 可选：退出时通知服务端使 token 失效（前端仍会清除本地 token）
  Future<void> logout(String token);

  /// 图形认证是否已配置；若已配置，appId 可用于前端初始化图形认证 SDK
  Future<Map<String, dynamic>?> getCaptchaConfig({required String platform});

  /// 创建图形认证挑战（主流流程：前端拉起认证页面，完成后轮询状态）
  Future<Map<String, dynamic>?> createCaptchaChallenge({required String platform});

  /// 查询图形认证挑战状态
  Future<Map<String, dynamic>?> getCaptchaChallengeStatus({required String challengeId});

  /// 上报 SDK 图形认证结果到后端，校验通过后 challenge 才可用于登录/注册
  Future<bool> verifyCaptchaChallenge({
    required String challengeId,
    required String platform,
    required String lotNumber,
    required String captchaOutput,
    required String passToken,
    required String genTime,
  });

  /// 读取当前登录用户资料
  Future<AuthUser?> fetchProfile(String token);

  /// 更新当前登录用户资料（昵称/头像）
  Future<AuthUser?> updateProfile(
    String token, {
    String? nickname,
    String? avatarUrl,
  });
}
