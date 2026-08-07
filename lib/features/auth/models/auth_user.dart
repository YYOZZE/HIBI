/// 当前登录用户信息（与后端返回一致时可从 JSON 解析）
class AuthUser {
  const AuthUser({
    required this.userId,
    required this.phoneOrEmail,
    this.nickname,
    this.avatarUrl,
    required this.token,
  });

  final String userId;
  /// 登录账号：手机号或邮箱
  final String phoneOrEmail;
  /// 展示用昵称，可选
  final String? nickname;
  /// 头像地址（可为 http(s) URL 或本地文件路径）
  final String? avatarUrl;
  /// 访问接口用的令牌，退出时由前端清除
  final String token;

  String get displayName => nickname?.trim().isNotEmpty == true ? nickname! : phoneOrEmail;

  AuthUser copyWith({
    String? userId,
    String? phoneOrEmail,
    String? nickname,
    String? avatarUrl,
    String? token,
  }) {
    return AuthUser(
      userId: userId ?? this.userId,
      phoneOrEmail: phoneOrEmail ?? this.phoneOrEmail,
      nickname: nickname ?? this.nickname,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      token: token ?? this.token,
    );
  }
}
