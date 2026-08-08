/// 当前登录用户信息
class AuthUser {
  const AuthUser({
    required this.userId,
    required this.phoneOrEmail,
    this.nickname,
    this.avatarUrl,
    required this.token,
    this.githubLogin,
    this.authProvider = 'legacy',
  });

  final String userId;
  /// 登录账号：手机号/邮箱，或 `github:<login>`
  final String phoneOrEmail;
  /// 展示用昵称，可选
  final String? nickname;
  /// 头像地址（可为 http(s) URL 或本地文件路径）
  final String? avatarUrl;
  /// 访问接口用的令牌（后端 Bearer 或 GitHub OAuth access token）
  final String token;
  /// GitHub 用户名（login）
  final String? githubLogin;
  /// `github` | `legacy` | `mock`
  final String authProvider;

  bool get isGitHub =>
      authProvider == 'github' ||
      (githubLogin != null && githubLogin!.trim().isNotEmpty);

  String get displayName {
    if (nickname?.trim().isNotEmpty == true) return nickname!;
    if (githubLogin != null && githubLogin!.trim().isNotEmpty) {
      return githubLogin!;
    }
    return phoneOrEmail;
  }

  AuthUser copyWith({
    String? userId,
    String? phoneOrEmail,
    String? nickname,
    String? avatarUrl,
    String? token,
    String? githubLogin,
    String? authProvider,
  }) {
    return AuthUser(
      userId: userId ?? this.userId,
      phoneOrEmail: phoneOrEmail ?? this.phoneOrEmail,
      nickname: nickname ?? this.nickname,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      token: token ?? this.token,
      githubLogin: githubLogin ?? this.githubLogin,
      authProvider: authProvider ?? this.authProvider,
    );
  }
}
