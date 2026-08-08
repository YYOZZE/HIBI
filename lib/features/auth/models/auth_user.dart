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
  /// 登录账号：`github:<login>` / `local:<id>` 等
  final String phoneOrEmail;
  /// 展示用昵称，可选
  final String? nickname;
  /// 头像地址（可为 http(s) URL 或本地文件路径）
  final String? avatarUrl;
  /// 访问令牌：GitHub OAuth access token，或本地会话标记 `local_…`
  final String token;
  /// GitHub 用户名（login）
  final String? githubLogin;
  /// `github` | `local` | `legacy` | `mock`
  final String authProvider;

  bool get isLocal =>
      authProvider == 'local' ||
      token.startsWith('local_') ||
      phoneOrEmail.startsWith('local:');

  bool get isGitHub =>
      !isLocal &&
      (authProvider == 'github' ||
          (githubLogin != null && githubLogin!.trim().isNotEmpty));

  String get displayName {
    if (nickname?.trim().isNotEmpty == true) return nickname!;
    if (githubLogin != null && githubLogin!.trim().isNotEmpty) {
      return githubLogin!;
    }
    if (isLocal) return '本地账号';
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
