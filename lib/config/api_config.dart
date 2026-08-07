/// 希比 HIBI 后端 API 配置
///
/// 账户接口与智能体接口可指向同一服务或不同服务，按部署情况配置。
class ApiConfig {
  ApiConfig._();

  /// 智能体对话后端地址（不含路径，如 http://192.168.1.100:7860）
  static const String assistantApiBaseUrl = 'http://121.41.6.21:7861';

  /// 账户与同步接口与智能体可同服：设成与 assistantApiBaseUrl 相同即可（同一进程内 FastAPI 提供 /api/chat + /api/auth + /api/sync）
  /// 须为 **完整基址**：`http(s)://主机名或IP:端口`，**不要**带路径。图形认证等接口的绝对地址由此拼接，例如：
  /// `authApiBaseUrl` + `/api/auth/captcha/sdk.js`
  /// 留空则注册邀请码与同步不生效，仍为本地 Mock
  static const String authApiBaseUrl = 'http://121.41.6.21:7861';

  /// 是否已配置智能体后端
  static bool get isAssistantApiConfigured =>
      assistantApiBaseUrl.isNotEmpty &&
      assistantApiBaseUrl != 'YOUR_SERVER_URL';

  /// 是否已配置账户后端（留空则 Mock）
  static bool get isAuthApiConfigured =>
      authApiBaseUrl.isNotEmpty && authApiBaseUrl != 'YOUR_AUTH_SERVER_URL';
}
