/// GitHub OAuth（Device Flow）与 Star 门禁配置。
///
/// 无需自建后端：客户端仅需 OAuth App 的 `client_id`。
///
/// 配置方式（任选其一）：
/// 1. 构建注入：`flutter run --dart-define=GITHUB_CLIENT_ID=Ov23lixxxxxxxx`
/// 2. 修改下方 [defaultClientId] 占位常量（勿提交真实 secret；Device Flow 不需要 secret）
///
/// 在 GitHub → Settings → Developer settings → OAuth Apps 新建应用：
/// - Homepage URL：`https://github.com/YYOZZE/HIBI`
/// - Authorization callback URL：可填 `http://127.0.0.1`（Device Flow 实际不依赖回调）
/// - 启用 Device Flow（若界面有开关）
class GitHubOAuthConfig {
  GitHubOAuthConfig._();

  /// 目标仓库（与 Release 同源）
  static const String owner = 'YYOZZE';
  static const String repo = 'HIBI';
  static const String repoFullName = '$owner/$repo';
  static const String repoUrl = 'https://github.com/$repoFullName';
  static const String starUrl = 'https://github.com/$repoFullName';

  /// Device Flow 所需 scope：读取用户资料 + 查询 starred
  static const String scopes = 'read:user';

  /// OAuth App Client ID（公开标识，非 Secret）。可用 `--dart-define=GITHUB_CLIENT_ID=...` 覆盖。
  static const String defaultClientId = 'Ov23li2nBAmeixFqntqJ';

  static const String clientId = String.fromEnvironment(
    'GITHUB_CLIENT_ID',
    defaultValue: defaultClientId,
  );

  static bool get isConfigured => clientId.trim().isNotEmpty;
}
