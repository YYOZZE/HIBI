import '../../config/api_config.dart';
import '../auth/services/auth_repository.dart';
import 'payment_service.dart';

/// 订阅权限统一判断：用于功能入口拦截和云同步开关。
class SubscriptionAccessService {
  SubscriptionAccessService._();

  static const String dataServicePlanId = 'data_service';
  static const String assistantServicePlanId = 'assistant_service';
  static const String themeServicePlanId = 'theme_service';
  static const String proMaxPlanId = 'pro_max';
  static const String proMax1tbPlanId = 'pro_max_1tb';
  /// 全功能试用（与后端 `trial_all` 一致）
  static const String trialAllPlanId = 'trial_all';

  static const Duration _cacheTtl = Duration(seconds: 20);
  static String? _cachedToken;
  static UserEntitlements? _cachedEntitlements;
  static DateTime? _cachedAt;
  static Future<UserEntitlements?>? _inFlight;

  static void invalidateCache() {
    _cachedToken = null;
    _cachedAt = null;
    _cachedEntitlements = null;
    _inFlight = null;
  }

  static bool _isCacheFresh() {
    final at = _cachedAt;
    if (at == null) return false;
    return DateTime.now().difference(at) <= _cacheTtl;
  }

  static Future<UserEntitlements?> fetchEntitlements({
    bool forceRefresh = false,
  }) async {
    final user = AuthRepository.instance.currentUser;
    if (user == null || user.token.startsWith('mock_') || !ApiConfig.isAuthApiConfigured) {
      return null;
    }
    final requestToken = user.token;
    if (_cachedToken != user.token) {
      invalidateCache();
      _cachedToken = user.token;
    }
    if (!forceRefresh && _isCacheFresh()) {
      return _cachedEntitlements;
    }
    final inflight = _inFlight;
    if (inflight != null) return inflight;
    final future = PaymentService.fetchMyEntitlements(requestToken);
    _inFlight = future;
    final value = await future;
    if (AuthRepository.instance.currentUser?.token != requestToken) {
      return null;
    }
    _cachedToken = requestToken;
    _cachedEntitlements = value;
    _cachedAt = DateTime.now();
    _inFlight = null;
    return value;
  }

  static bool hasPlanInEntitlements(UserEntitlements? e, String planId) {
    if (e == null) return false;
    // 试用生效期间，后端已将 basic_plans 扩为三项；此处兼容旧缓存
    if (e.trialActive && !e.hasPro()) {
      if (planId == dataServicePlanId ||
          planId == assistantServicePlanId ||
          planId == themeServicePlanId) {
        return true;
      }
    }
    switch (planId) {
      case dataServicePlanId:
      case assistantServicePlanId:
      case themeServicePlanId:
        return e.hasPro() || e.hasBasicPlan(planId);
      case proMaxPlanId:
        return e.pro == proMaxPlanId || e.pro == proMax1tbPlanId;
      case proMax1tbPlanId:
        return e.pro == proMax1tbPlanId;
      case trialAllPlanId:
        return e.trialActive;
      default:
        return e.hasPlan(planId);
    }
  }

  static Future<bool> hasPlanAccess(
    String planId, {
    bool forceRefresh = false,
  }) async {
    final e = await fetchEntitlements(forceRefresh: forceRefresh);
    return hasPlanInEntitlements(e, planId);
  }

  static Future<bool> hasDataSyncAccess({bool forceRefresh = false}) {
    return hasPlanAccess(dataServicePlanId, forceRefresh: forceRefresh);
  }

  /// 助理功能已对全部用户放开，不再校验助理服务订阅（套餐本身保留，供历史订单与增值服务页展示）。
  static Future<bool> hasAssistantChatAccess({bool forceRefresh = false}) async {
    return true;
  }

  static Future<bool> hasThemeSettingsAccess({bool forceRefresh = false}) async {
    return true;
  }
}
