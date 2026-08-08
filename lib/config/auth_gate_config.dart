/// 启动门禁与局域网账号校验开关。
///
/// V4.0.1：默认 [bypassGitHubLoginGate] = true，打开 App 直接进主壳，助理开放；
/// 局域网同步亦暂不强制双方 GitHub/本地账号一致。
/// GitHub Device Flow / Star 门禁代码与页面**保留未删**，复开时将本开关改为 `false`。
/// 封存说明与复现指南见：`lib/features/auth/AUTH_GITHUB_SEALED.md`。
class AuthGateConfig {
  AuthGateConfig._();

  /// `true`：绕过 GitHub 登录与 Star；无会话时自动本地账号进壳；助理不拦截；
  /// 局域网同步不因 accountId 不一致拒绝（握手仍可携带 accountId）。
  /// `false`：恢复 3.3.x GitHub + Star / 本地双路径门禁，并恢复 LAN 账号一致校验。
  static const bool bypassGitHubLoginGate = true;
}
