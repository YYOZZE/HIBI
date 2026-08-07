import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../config/api_config.dart';

class PaymentPlanConfig {
  const PaymentPlanConfig({
    required this.planId,
    required this.name,
    required this.description,
    required this.amountCents,
    required this.amount,
    required this.priceLabel,
    required this.durationDays,
    required this.isPro,
    required this.isBasic,
    required this.autoRenew,
    required this.graceDaysAfterRenewalFailure,
    this.isTrial = false,
  });

  final String planId;
  final String name;
  final String description;
  final int amountCents;
  final double amount;
  final String priceLabel;
  final int durationDays;
  final bool isPro;
  final bool isBasic;
  final bool autoRenew;
  final int graceDaysAfterRenewalFailure;
  final bool isTrial;
}

class PlanSubscriptionState {
  const PlanSubscriptionState({
    required this.planId,
    required this.status,
    required this.autoRenew,
    this.remainingSeconds,
    this.displayRemainingSeconds,
    this.validUntil,
    this.graceUntil,
    this.graceRemainingSeconds,
    this.includedBy,
    this.renewalOrderId,
    this.renewalPayUrl,
  });

  final String planId;
  final String status; // active / included_by_pro / grace / interrupted / inactive
  final bool autoRenew;
  final int? remainingSeconds;
  /// 展示用剩余秒数：与全功能试用并行时，基础服务为「原剩余 + 试用剩余」（与 [remainingSeconds] 不同，见说明文档）
  final int? displayRemainingSeconds;
  final double? validUntil;
  final double? graceUntil;
  final int? graceRemainingSeconds;
  final String? includedBy;
  final String? renewalOrderId;
  final String? renewalPayUrl;

  /// 界面展示「剩余」时优先使用（与试用叠加后的展示值）
  int? get remainingSecondsForDisplay => displayRemainingSeconds ?? remainingSeconds;
}

/// 当前用户会员权益（PRO 档 + 基础服务列表）
class UserEntitlements {
  const UserEntitlements({
    this.pro,
    this.basicPlans = const [],
    this.proValidUntil,
    this.planConfigs = const [],
    this.planStates = const {},
    this.trialConsumed = false,
    this.trialActive = false,
  });

  final String? pro;
  final List<String> basicPlans;
  final double? proValidUntil;
  final List<PaymentPlanConfig> planConfigs;
  final Map<String, PlanSubscriptionState> planStates;
  /// 是否曾有过试用订单（含已过期），与 [trialActive] 配合用于订阅页展示
  final bool trialConsumed;
  final bool trialActive;

  bool hasPro() => pro != null && pro!.isNotEmpty;
  bool hasBasicPlan(String planId) => basicPlans.contains(planId);
  bool hasPlan(String planId) {
    if (planId == 'pro_max_1tb' || planId == 'pro_max') {
      if (planId == 'pro_max_1tb') return pro == 'pro_max_1tb';
      return pro == 'pro_max' || pro == 'pro_max_1tb';
    }
    if (hasPro()) return basicPlans.contains(planId);
    return basicPlans.contains(planId);
  }
}

/// 创建订单结果
class CreateOrderResult {
  const CreateOrderResult({
    required this.orderId,
    required this.payUrl,
    required this.amount,
    required this.subject,
    this.immediatePaid = false,
  });

  final String orderId;
  final String payUrl;
  final double amount;
  final String subject;
  /// 0 元试用等：服务端已直接入账，无需打开支付页
  final bool immediatePaid;
}

/// 支付订单查询结果
class PaymentOrderInfo {
  const PaymentOrderInfo({
    required this.orderId,
    required this.planId,
    required this.status,
    this.paidAt,
  });

  final String orderId;
  final String planId;
  final String status; // pending / paid
  final double? paidAt;

  bool get isPaid => status.toLowerCase() == 'paid';
}

/// 支付配置状态
class PaymentConfigStatus {
  const PaymentConfigStatus({
    required this.ready,
    required this.raw,
  });

  final bool ready;
  final Map<String, dynamic> raw;
}

/// 服务增值支付：调用后端创建订单并返回支付链接
class PaymentService {
  /// 获取后端套餐目录（真实价格、时长、描述）
  static Future<List<PaymentPlanConfig>> fetchPlanCatalog() async {
    final base = ApiConfig.authApiBaseUrl.replaceFirst(RegExp(r'/$'), '');
    final url = Uri.parse('$base/api/payment/plans');
    try {
      final resp = await _client.get(url);
      if (resp.statusCode != 200) return const [];
      final data = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>?;
      if (data == null) return const [];
      final list = data['plans'];
      if (list is! List) return const [];
      return list
          .whereType<Map>()
          .map((raw) => _parsePlanConfig(raw.cast<String, dynamic>()))
          .whereType<PaymentPlanConfig>()
          .toList();
    } catch (_) {
      return const [];
    }
  }

  PaymentService._();

  static final _client = http.Client();

  /// 创建订单并返回支付 URL；未配置后端或失败返回 null
  /// 创建订单。试用重复申请时 [userMessage] 返回服务端文案。
  static Future<({CreateOrderResult? result, String? userMessage})> createOrderAndGetPayUrl(
    String planId,
    String token, {
    String? payType,
  }) async {
    final base = ApiConfig.authApiBaseUrl.replaceFirst(RegExp(r'/$'), '');
    final url = Uri.parse('$base/api/payment/create_order');
    try {
      final resp = await _client.post(
        url,
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: jsonEncode({
          'plan_id': planId,
          if (payType != null && payType.trim().isNotEmpty) 'pay_type': payType.trim(),
        }),
      );
      final data = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>?;
      if (resp.statusCode == 400) {
        final msg = data?['message']?.toString();
        return (result: null, userMessage: msg);
      }
      if (resp.statusCode != 200) {
        return (result: null, userMessage: null);
      }
      if (data == null) return (result: null, userMessage: null);
      final orderId = data['order_id'] as String?;
      final payUrl = data['pay_url'] as String? ?? '';
      final immediate = data['immediate'] == true || data['status']?.toString() == 'paid';
      if (orderId == null || orderId.isEmpty) {
        return (result: null, userMessage: null);
      }
      if (!immediate && payUrl.isEmpty) {
        return (result: null, userMessage: null);
      }
      final amount = (data['amount'] is num) ? (data['amount'] as num).toDouble() : 0.0;
      final subject = data['subject'] as String? ?? '';
      return (
        result: CreateOrderResult(
          orderId: orderId,
          payUrl: payUrl,
          amount: amount,
          subject: subject,
          immediatePaid: immediate,
        ),
        userMessage: null
      );
    } catch (_) {
      return (result: null, userMessage: null);
    }
  }

  /// 拉取当前用户会员权益；未登录或失败返回 null
  static Future<UserEntitlements?> fetchMyEntitlements(String token) async {
    final base = ApiConfig.authApiBaseUrl.replaceFirst(RegExp(r'/$'), '');
    final url = Uri.parse('$base/api/payment/my_entitlements');
    try {
      final resp = await _client.get(
        url,
        headers: {'Authorization': 'Bearer $token'},
      );
      if (resp.statusCode != 200) return null;
      final data = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>?;
      if (data == null) return null;
      final pro = data['pro'] as String?;
      final basicList = data['basic_plans'];
      final basicPlans = basicList is List
          ? basicList.map((e) => e?.toString() ?? '').where((s) => s.isNotEmpty).toList()
          : <String>[];
      final pvu = data['pro_valid_until'];
      final proValidUntil = pvu is num ? pvu.toDouble() : null;
      final trialConsumed = data['trial_consumed'] == true;
      final trialActive = data['trial_active'] == true;
      final cfgList = data['plan_configs'];
      final planConfigs = cfgList is List
          ? cfgList
              .whereType<Map>()
              .map((raw) => _parsePlanConfig(raw.cast<String, dynamic>()))
              .whereType<PaymentPlanConfig>()
              .toList()
          : const <PaymentPlanConfig>[];
      final states = <String, PlanSubscriptionState>{};
      final stateList = data['plans'];
      if (stateList is List) {
        for (final item in stateList.whereType<Map>()) {
          final parsed = _parsePlanState(item.cast<String, dynamic>());
          if (parsed != null) states[parsed.planId] = parsed;
        }
      }
      return UserEntitlements(
        pro: pro,
        basicPlans: basicPlans,
        proValidUntil: proValidUntil,
        planConfigs: planConfigs,
        planStates: states,
        trialConsumed: trialConsumed,
        trialActive: trialActive,
      );
    } catch (_) {
      return null;
    }
  }

  /// 查询单笔订单状态（需登录）
  static Future<PaymentOrderInfo?> fetchOrderStatus(String token, String orderId) async {
    final base = ApiConfig.authApiBaseUrl.replaceFirst(RegExp(r'/$'), '');
    final url = Uri.parse('$base/api/payment/order/$orderId');
    try {
      final resp = await _client.get(
        url,
        headers: {'Authorization': 'Bearer $token'},
      );
      if (resp.statusCode != 200) return null;
      final data = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>?;
      if (data == null) return null;
      final oid = data['order_id'] as String?;
      final pid = data['plan_id'] as String?;
      final status = data['status'] as String?;
      if (oid == null || pid == null || status == null) return null;
      final paidAtRaw = data['paid_at'];
      final paidAt = paidAtRaw is num ? paidAtRaw.toDouble() : null;
      return PaymentOrderInfo(
        orderId: oid,
        planId: pid,
        status: status,
        paidAt: paidAt,
      );
    } catch (_) {
      return null;
    }
  }

  /// 拉取支付配置状态（无需登录）
  static Future<PaymentConfigStatus?> fetchConfigStatus() async {
    final base = ApiConfig.authApiBaseUrl.replaceFirst(RegExp(r'/$'), '');
    final url = Uri.parse('$base/api/payment/config_status');
    try {
      final resp = await _client.get(url);
      if (resp.statusCode != 200) return null;
      final data = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>?;
      if (data == null) return null;
      final ready = data['ready'] == true;
      return PaymentConfigStatus(ready: ready, raw: data);
    } catch (_) {
      return null;
    }
  }

  static PaymentPlanConfig? _parsePlanConfig(Map<String, dynamic> raw) {
    final planId = raw['plan_id']?.toString();
    final name = raw['name']?.toString();
    if (planId == null || name == null) return null;
    final amountCentsRaw = raw['amount_cents'];
    final amountRaw = raw['amount'];
    final durationRaw = raw['duration_days'];
    final graceRaw = raw['grace_days_after_renewal_failure'];
    return PaymentPlanConfig(
      planId: planId,
      name: name,
      description: raw['description']?.toString() ?? '',
      amountCents: amountCentsRaw is num ? amountCentsRaw.toInt() : 0,
      amount: amountRaw is num ? amountRaw.toDouble() : 0,
      priceLabel: raw['price_label']?.toString() ?? '',
      durationDays: durationRaw is num ? durationRaw.toInt() : 0,
      isPro: raw['is_pro'] == true,
      isBasic: raw['is_basic'] == true,
      autoRenew: raw['auto_renew'] == true,
      graceDaysAfterRenewalFailure: graceRaw is num ? graceRaw.toInt() : 3,
      isTrial: raw['is_trial'] == true,
    );
  }

  static PlanSubscriptionState? _parsePlanState(Map<String, dynamic> raw) {
    final planId = raw['plan_id']?.toString();
    final status = raw['status']?.toString();
    if (planId == null || status == null) return null;
    final remainingRaw = raw['remaining_seconds'];
    final displayRemainRaw = raw['display_remaining_seconds'];
    final validUntilRaw = raw['valid_until'];
    final graceUntilRaw = raw['grace_until'];
    final graceRemainRaw = raw['grace_remaining_seconds'];
    return PlanSubscriptionState(
      planId: planId,
      status: status,
      autoRenew: raw['auto_renew'] == true,
      remainingSeconds: remainingRaw is num ? remainingRaw.toInt() : null,
      displayRemainingSeconds: displayRemainRaw is num ? displayRemainRaw.toInt() : null,
      validUntil: validUntilRaw is num ? validUntilRaw.toDouble() : null,
      graceUntil: graceUntilRaw is num ? graceUntilRaw.toDouble() : null,
      graceRemainingSeconds: graceRemainRaw is num ? graceRemainRaw.toInt() : null,
      includedBy: raw['included_by']?.toString(),
      renewalOrderId: raw['renewal_order_id']?.toString(),
      renewalPayUrl: raw['renewal_pay_url']?.toString(),
    );
  }
}
