import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/app_glass_styles.dart';
import '../../app/app_theme.dart';
import '../../app/frosted_background.dart';
import '../../config/api_config.dart';
import '../auth/services/auth_repository.dart';
import '../auth/services/user_sync_scheduler.dart';
import 'payment_service.dart';
import 'subscription_access_service.dart';

/// 服务增值套餐数据
class ValueAddedPlan {
  const ValueAddedPlan({
    required this.planId,
    required this.name,
    required this.priceLabel,
    required this.description,
    required this.icon,
    this.badge,
    this.isHighlight = false,
  });

  final String planId;
  final String name;
  final String priceLabel;
  final String description;
  final IconData icon;
  final String? badge;
  final bool isHighlight;
}

/// 基础套餐 ID（可单独订阅）
const _basicPlanIds = ['data_service', 'assistant_service', 'theme_service'];
const _payTypeOptions = <({String id, String label, IconData icon})>[
  (id: 'alipay', label: '支付宝', icon: Icons.account_balance_wallet_outlined),
  (id: 'wxpay', label: '微信支付', icon: Icons.wechat_outlined),
  (id: 'bank', label: '网银支付', icon: Icons.account_balance_outlined),
];

/// 服务增值页：套餐列表，价格在描述下方，主流订阅页式布局；拉取权益后展示已订阅/已包含
class ValueAddedPage extends StatefulWidget {
  const ValueAddedPage({super.key});

  @override
  State<ValueAddedPage> createState() => _ValueAddedPageState();

  /// 0 元全功能试用：不选支付方式，下单后立即入账
  static Future<void> activateTrial(BuildContext context, ValueAddedPlan plan, VoidCallback? onPaid) async {
    final user = AuthRepository.instance.currentUser;
    if (user == null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请先登录后再操作')),
        );
      }
      return;
    }
    if (!ApiConfig.isAuthApiConfigured) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('未配置服务，请稍后再试')),
        );
      }
      return;
    }
    final outcome = await PaymentService.createOrderAndGetPayUrl(plan.planId, user.token);
    if (outcome.userMessage != null && outcome.userMessage!.isNotEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(outcome.userMessage!)));
      }
      return;
    }
    final result = outcome.result;
    if (result == null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('领取失败，请稍后再试')),
        );
      }
      return;
    }
    if (result.immediatePaid) {
      SubscriptionAccessService.invalidateCache();
      unawaited(_syncAfterPaymentSuccess());
      onPaid?.call();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已开通试用：${plan.name}')),
        );
      }
      return;
    }
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('试用需使用立即开通，请更新应用或联系支持')),
      );
    }
  }

  /// 点击增值时：登录校验 → 创建订单 → 打开 pay_url；onPaid 可选用于刷新权益
  static Future<void> onValueAdd(BuildContext context, ValueAddedPlan plan, VoidCallback? onPaid) async {
    final user = AuthRepository.instance.currentUser;
    if (user == null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请先登录后再购买')),
        );
      }
      return;
    }
    if (!ApiConfig.isAuthApiConfigured) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('未配置支付服务，请稍后再试')),
        );
      }
      return;
    }
    final payType = await _choosePayType(context);
    if (payType == null || payType.isEmpty) return;
    final outcome = await PaymentService.createOrderAndGetPayUrl(
      plan.planId,
      user.token,
      payType: payType,
    );
    if (outcome.userMessage != null && outcome.userMessage!.isNotEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(outcome.userMessage!)));
      }
      return;
    }
    final result = outcome.result;
    if (result == null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('创建订单失败，请稍后再试')),
        );
      }
      return;
    }
    if (result.immediatePaid) {
      SubscriptionAccessService.invalidateCache();
      unawaited(_syncAfterPaymentSuccess());
      onPaid?.call();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('支付成功，已开通 ${plan.name}')),
        );
      }
      return;
    }
    final uri = Uri.tryParse(result.payUrl);
    if (uri == null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('支付链接无效')),
        );
      }
      return;
    }
    try {
      // 不依赖 canLaunchUrl：Android 11+ 未声明 queries 时 canLaunchUrl 可能误报 false，直接尝试打开
      final launched = await _launchPayUrl(uri);
      if (context.mounted) {
        if (launched) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('请在新打开的页面完成支付，支付完成后返回应用')),
          );
          await _showPostPayCheckDialog(
            context: context,
            orderId: result.orderId,
            token: user.token,
            planName: plan.name,
            onPaid: onPaid,
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('无法打开支付页面，请检查是否已安装浏览器')),
          );
        }
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('无法打开支付页面，请稍后重试')),
        );
      }
    }
  }

  static Future<bool> _launchPayUrl(Uri uri) async {
    final modes = <LaunchMode>[
      LaunchMode.externalApplication,
      if (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS)
        LaunchMode.inAppBrowserView,
      LaunchMode.platformDefault,
    ];
    for (final mode in modes) {
      try {
        if (await launchUrl(uri, mode: mode)) return true;
      } catch (_) {
        // 忽略单次拉起失败，继续尝试下一个模式
      }
    }
    return false;
  }

  static Future<void> _syncAfterPaymentSuccess() async {
    try {
      await UserSyncScheduler.pullAndNotify();
      await UserSyncScheduler.pushNow();
    } catch (_) {}
  }

  static Future<String?> _choosePayType(BuildContext context) async {
    return showDialog<String>(
      context: context,
      barrierColor: Colors.black.withOpacity(0.5),
      builder: (ctx) {
        final theme = Theme.of(ctx);
        final colorScheme = theme.colorScheme;
        return Dialog(
          backgroundColor: colorScheme.surface.withOpacity(0.96),
          surfaceTintColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '选择支付方式',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: colorScheme.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '请选择本次续订使用的支付渠道',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 12),
                ..._payTypeOptions.map((o) {
                  return Padding(
                    padding: EdgeInsets.only(
                      bottom: o.id == _payTypeOptions.last.id ? 0 : 8,
                    ),
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: () => Navigator.of(ctx).pop(o.id),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
                          child: Row(
                            children: [
                              Container(
                                width: 34,
                                height: 34,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: colorScheme.primaryContainer,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Icon(o.icon, color: colorScheme.primary, size: 19),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  o.label,
                                  style: theme.textTheme.titleSmall?.copyWith(
                                    color: colorScheme.onSurface,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                }),
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: Text(
                      '取消',
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  static Future<void> _showPostPayCheckDialog({
    required BuildContext context,
    required String orderId,
    required String token,
    required String planName,
    required VoidCallback? onPaid,
  }) async {
    var checking = false;
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setState) {
            Future<void> checkNow() async {
              if (checking) return;
              setState(() => checking = true);
              final order = await PaymentService.fetchOrderStatus(token, orderId);
              if (!ctx.mounted) return;
              setState(() => checking = false);
              if (order?.isPaid == true) {
                Navigator.of(ctx).pop();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('支付成功，已开通 $planName')),
                  );
                }
                SubscriptionAccessService.invalidateCache();
                unawaited(_syncAfterPaymentSuccess());
                onPaid?.call();
              } else {
                ScaffoldMessenger.of(ctx).showSnackBar(
                  const SnackBar(content: Text('暂未查询到支付成功记录，可能有几秒延迟，请稍后再试')),
                );
              }
            }

            return AlertDialog(
              backgroundColor: Theme.of(ctx).dialogTheme.backgroundColor ?? Theme.of(ctx).colorScheme.surface,
              surfaceTintColor: Colors.transparent,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: Text(
                '支付结果确认',
                style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                  color: Theme.of(ctx).colorScheme.onSurface,
                  fontWeight: FontWeight.w600,
                ),
              ),
              content: Text(
                '支付完成后，请点击“我已支付，查看结果”。系统会自动更新您的订阅状态。',
                style: Theme.of(ctx).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w400,
                  height: 1.45,
                ),
              ),
              actions: [
                TextButton(
                  onPressed: checking ? null : () => Navigator.of(ctx).pop(),
                  child: Text(
                    '稍后查看',
                    style: Theme.of(ctx).textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                FilledButton(
                  onPressed: checking ? null : checkNow,
                  child: Text(
                    checking ? '查询中...' : '我已支付，查看结果',
                    style: Theme.of(ctx).textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

/// 正文/描述统一字重 w400，避免同一句内粗细不一致（含 PRO 等词）。其他页建议同样显式指定 fontWeight。
TextStyle? _bodyStyle(ThemeData theme, ColorScheme colorScheme) {
  return theme.textTheme.bodyLarge?.copyWith(
    color: colorScheme.onSurfaceVariant,
    fontWeight: FontWeight.w400,
  );
}

class _ValueAddedPageState extends State<ValueAddedPage> {
  UserEntitlements? _entitlements;
  PaymentConfigStatus? _payConfig;
  List<PaymentPlanConfig> _planCatalog = const [];
  bool _loading = true;
  Timer? _refreshTimer;

  static const List<ValueAddedPlan> _plans = [
    ValueAddedPlan(
      planId: 'trial_all',
      name: '试用',
      priceLabel: '0 元 / 半年',
      description: '试用全部功能（每账号限一次，到期不可续订）',
      icon: Icons.card_giftcard_outlined,
    ),
    ValueAddedPlan(
      planId: 'data_service',
      name: '数据服务',
      priceLabel: '1 元 / 季',
      description: '三端实时同步，阿里云云备份，数据不丢失',
      icon: Icons.cloud_outlined,
    ),
    ValueAddedPlan(
      planId: 'assistant_service',
      name: '助理服务',
      priceLabel: '2 元 / 季',
      description: '接入主流 AI 模型，体验豆包-pro，智能日程与项目安排',
      icon: Icons.smart_toy_outlined,
    ),
    ValueAddedPlan(
      planId: 'theme_service',
      name: '主题服务',
      priceLabel: '1 元 / 季',
      description: '解锁全部主题，含隐藏开发者主题',
      icon: Icons.palette_outlined,
    ),
    ValueAddedPlan(
      planId: 'pro_max',
      name: 'HIBI-PRO-MAX',
      priceLabel: '12 元 / 年',
      description: '解锁数据服务、助理服务、主题服务全部功能',
      icon: Icons.workspace_premium,
      isHighlight: true,
    ),
    ValueAddedPlan(
      planId: 'pro_max_1tb',
      name: 'HIBI-PRO-MAX-1TB',
      priceLabel: '100 元 / 月',
      description: '解锁全部服务，专享开发者下午茶',
      icon: Icons.diamond_outlined,
      isHighlight: true,
    ),
  ];

  @override
  void initState() {
    super.initState();
    _loadEntitlements();
    _refreshTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (!mounted) return;
      _loadEntitlements();
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadEntitlements() async {
    final configFuture = PaymentService.fetchConfigStatus();
    final catalogFuture = PaymentService.fetchPlanCatalog();
    final config = await configFuture;
    final catalog = await catalogFuture;
    final token = AuthRepository.instance.currentUser?.token;
    if (token == null || !ApiConfig.isAuthApiConfigured) {
      if (mounted) {
        setState(() {
          _entitlements = null;
          _payConfig = config;
          _planCatalog = catalog;
          _loading = false;
        });
      }
      return;
    }
    final e = await PaymentService.fetchMyEntitlements(token);
    if (mounted) {
      setState(() {
        _entitlements = e;
        _payConfig = config;
        _planCatalog = catalog.isNotEmpty ? catalog : (e?.planConfigs ?? const []);
        _loading = false;
      });
    }
  }

  Future<void> _openDeveloperContact() async {
    final uri = Uri.parse('https://buymeacoffee.com/yyozze');
    try {
      final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (mounted && !launched) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('无法打开链接，请检查是否已安装浏览器')),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('无法打开链接')),
        );
      }
    }
  }

  PaymentPlanConfig? _configOf(String planId) {
    for (final p in _planCatalog) {
      if (p.planId == planId) return p;
    }
    return null;
  }

  PlanSubscriptionState? _stateOf(String planId) => _entitlements?.planStates[planId];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: const Text('订阅'),
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          const FrostedBackground(),
          Positioned.fill(
            top: MediaQuery.of(context).padding.top + kToolbarHeight + 8,
            child: ClipRect(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 40),
                children: [
                  AppGlassStyles.section(
                    context,
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    child: Text(
                      '价格与时长实时来自后端配置。订阅默认自动续费；续费失败后进入 3 天宽限，超时将中断订阅。',
                      style: _bodyStyle(theme, colorScheme),
                    ),
                  ),
                  if (_payConfig != null && _payConfig!.ready != true) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: colorScheme.errorContainer.withOpacity(0.7),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.info_outline, size: 18, color: colorScheme.onErrorContainer),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '支付配置未完成（数捷参数未全部生效），当前下单可能跳转到说明页。',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: colorScheme.onErrorContainer,
                                fontWeight: FontWeight.w400,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  if (_entitlements != null && (_entitlements!.hasPro() || _entitlements!.basicPlans.isNotEmpty)) ...[
                    const SizedBox(height: 12),
                    _EntitlementsSummary(entitlements: _entitlements!),
                  ],
                  const SizedBox(height: 24),
                  if (_loading)
                    const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()))
                  else
                    ..._plans.map((plan) => Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: _PlanCard(
                            plan: plan,
                            planConfig: _configOf(plan.planId),
                            planState: _stateOf(plan.planId),
                            entitlements: _entitlements,
                            onRefresh: _loadEntitlements,
                          ),
                        )),
                  const SizedBox(height: 8),
                  AppGlassStyles.section(
                    context,
                    padding: EdgeInsets.zero,
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: _openDeveloperContact,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                          child: Row(
                            children: [
                              Container(
                                width: 44,
                                height: 44,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: colorScheme.surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Icon(
                                  Icons.coffee_outlined,
                                  color: colorScheme.onSurfaceVariant,
                                  size: 24,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  '给作者买杯咖啡',
                                  style: theme.textTheme.bodyLarge?.copyWith(
                                    color: colorScheme.onSurface,
                                    fontWeight: FontWeight.w400,
                                  ),
                                ),
                              ),
                              Icon(
                                Icons.chevron_right,
                                color: colorScheme.onSurfaceVariant,
                                size: 22,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EntitlementsSummary extends StatelessWidget {
  const _EntitlementsSummary({required this.entitlements});

  final UserEntitlements entitlements;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final labels = <String>[];
    if (entitlements.pro == 'pro_max_1tb') {
      labels.add('HIBI-PRO-MAX-1TB');
    } else if (entitlements.pro == 'pro_max') {
      labels.add('HIBI-PRO-MAX');
    }
    if (labels.isEmpty) {
      if (entitlements.basicPlans.contains('data_service')) labels.add('数据服务');
      if (entitlements.basicPlans.contains('assistant_service')) labels.add('助理服务');
      if (entitlements.basicPlans.contains('theme_service')) labels.add('主题服务');
    } else {
      labels.add('含数据/助理/主题');
    }
    if (entitlements.trialActive && entitlements.pro == null) {
      labels.add('全功能试用中');
    }
    if (labels.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer.withOpacity(0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.check_circle_outline, size: 20, color: colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '当前权益：${labels.join('、')}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurface,
                fontWeight: FontWeight.w400,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({
    required this.plan,
    this.planConfig,
    this.planState,
    this.entitlements,
    this.onRefresh,
  });

  final ValueAddedPlan plan;
  final PaymentPlanConfig? planConfig;
  final PlanSubscriptionState? planState;
  final UserEntitlements? entitlements;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isHighlight = plan.isHighlight;
    final cfgDesc = planConfig?.description ?? '';
    final cfgPrice = planConfig?.priceLabel ?? '';
    final displayName = planConfig?.name ?? plan.name;
    final displayDesc = cfgDesc.trim().isNotEmpty
        ? cfgDesc
        : plan.description;
    final displayPrice = cfgPrice.trim().isNotEmpty
        ? cfgPrice
        : plan.priceLabel;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: isHighlight
                ? Border.all(color: AppTheme.logoBlue.withOpacity(0.5), width: 1)
                : null,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.06),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: AppGlassStyles.section(
            context,
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Container(
                            width: 48,
                            height: 48,
                            decoration: BoxDecoration(
                              color: isHighlight
                                  ? colorScheme.primaryContainer
                                  : colorScheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            alignment: Alignment.center,
                            child: Icon(
                              plan.icon,
                              size: 26,
                              color: isHighlight
                                  ? colorScheme.primary
                                  : colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Text(
                              displayName,
                              style: theme.textTheme.titleLarge?.copyWith(
                                color: colorScheme.onSurface,
                                fontWeight: FontWeight.w400,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Text(
                        displayDesc,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                          height: 1.4,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                      const SizedBox(height: 8),
                      _buildStatusLine(theme, colorScheme),
                      const SizedBox(height: 14),
                      Text(
                        displayPrice,
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                _buildPlanButton(context, theme, colorScheme),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildStatusLine(ThemeData theme, ColorScheme colorScheme) {
    final s = planState;
    final statusColor = _statusColor(colorScheme, s?.status);
    final isTrialCard = plan.planId == SubscriptionAccessService.trialAllPlanId;
    if (s == null) {
      final line = isTrialCard
          ? (entitlements?.trialConsumed == true ? '状态：已试用' : '状态：可领取（可与付费订阅并行）')
          : '状态：未订阅';
      return Text(
        line,
        style: theme.textTheme.bodySmall?.copyWith(
          color: statusColor,
          fontWeight: FontWeight.w500,
        ),
      );
    }
    String text;
    switch (s.status) {
      case 'active':
        if (plan.planId == SubscriptionAccessService.trialAllPlanId) {
          text = '状态：试用中 · 剩余${_formatSeconds(s.remainingSeconds)}';
        } else {
          text =
              '状态：订阅中 · 剩余${_formatSeconds(s.remainingSecondsForDisplay)}';
        }
        break;
      case 'trial_expired':
        text = '状态：试用已结束（不可再次试用或续订）';
        break;
      case 'included_by_pro':
        text =
            '状态：已包含于 PRO（可单独续订并独立计时） · 剩余${_formatSeconds(s.remainingSecondsForDisplay)}';
        break;
      case 'grace':
        text = '状态：续费宽限期 · ${_formatSeconds(s.graceRemainingSeconds)}后中断';
        break;
      case 'interrupted':
        text = '状态：已中断（续费失败超 3 天）';
        break;
      default:
        if (isTrialCard) {
          text = entitlements?.trialConsumed == true
              ? '状态：已试用'
              : '状态：可领取（可与付费订阅并行）';
        } else {
          text = '状态：未订阅';
        }
        break;
    }
    return Text(
      text,
      style: theme.textTheme.bodySmall?.copyWith(
        color: statusColor,
        fontWeight: FontWeight.w500,
      ),
    );
  }

  Color _statusColor(ColorScheme colorScheme, String? status) {
    switch (status) {
      case 'active':
      case 'included_by_pro':
        // 用主题次高亮色强调“已生效”状态（区别于主按钮色）。
        return colorScheme.secondary;
      case 'trial_expired':
        return colorScheme.onSurfaceVariant;
      case 'grace':
        return colorScheme.primary;
      case 'interrupted':
        return colorScheme.error;
      default:
        return colorScheme.secondary.withOpacity(0.92);
    }
  }

  String _formatSeconds(int? seconds) {
    if (seconds == null || seconds <= 0) return '0天';
    final days = seconds ~/ 86400;
    final hours = (seconds % 86400) ~/ 3600;
    if (days > 0) return '$days天$hours小时';
    final mins = (seconds % 3600) ~/ 60;
    if (hours > 0) return '$hours小时$mins分钟';
    return '$mins分钟';
  }

  Widget _buildPlanButton(BuildContext context, ThemeData theme, ColorScheme colorScheme) {
    final s = planState;
    final isTrial = plan.planId == SubscriptionAccessService.trialAllPlanId;

    if (isTrial) {
      final trialConsumed = entitlements?.trialConsumed ?? false;
      if (s?.status == 'active') {
        return _disabledButton(theme, colorScheme, '试用中');
      }
      if (s?.status == 'trial_expired' || (trialConsumed && s?.status != 'active')) {
        return _disabledButton(theme, colorScheme, '已试用');
      }
      return _trialActivateButton(context, theme, colorScheme);
    }

    if (s != null) {
      if (s.status == 'active') {
        return _enabledButton(context, theme, colorScheme, '续订');
      }
      if (s.status == 'included_by_pro') {
        if (_basicPlanIds.contains(plan.planId)) {
          // 基础服务被 PRO 包含时，仍允许用户单独续订叠加该服务时长
          return _enabledButton(context, theme, colorScheme, '续订');
        }
        return _disabledButton(theme, colorScheme, '已包含于 PRO');
      }
      if (s.status == 'grace') {
        return _enabledButton(context, theme, colorScheme, '立即续费');
      }
    }

    final hasPro = entitlements?.hasPro() ?? false;
    final isBasic = _basicPlanIds.contains(plan.planId);
    String label;
    bool enabled = true;
    if (entitlements != null) {
      if (isBasic) {
        if (hasPro) {
          label = '续订';
          enabled = true;
        } else if (entitlements!.hasBasicPlan(plan.planId)) {
          label = '续订';
          enabled = true;
        } else {
          label = '订阅';
        }
      } else {
        if (plan.planId == 'pro_max_1tb' && entitlements!.pro == 'pro_max_1tb') {
          label = '续订';
          enabled = true;
        } else if (plan.planId == 'pro_max' && (entitlements!.pro == 'pro_max' || entitlements!.pro == 'pro_max_1tb')) {
          // 全部套餐均支持单独续订；即使用户已有更高档 PRO，也允许本套餐单独续订并独立累计时长。
          label = '续订';
          enabled = true;
        } else {
          label = '订阅';
        }
      }
    } else {
      label = '订阅';
    }
    if (!enabled) {
      return _disabledButton(theme, colorScheme, label);
    }
    return _enabledButton(context, theme, colorScheme, label);
  }

  Widget _disabledButton(ThemeData theme, ColorScheme colorScheme, String label) {
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 28),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      alignment: Alignment.center,
      child: Text(
        label,
        style: theme.textTheme.titleSmall?.copyWith(
          color: colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w400,
        ),
      ),
    );
  }

  Widget _trialActivateButton(BuildContext context, ThemeData theme, ColorScheme colorScheme) {
    return SizedBox(
      height: 52,
      child: FilledButton(
        onPressed: () => ValueAddedPage.activateTrial(context, plan, onRefresh),
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
          minimumSize: const Size(0, 52),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
        child: const Text('试用'),
      ),
    );
  }

  Widget _enabledButton(BuildContext context, ThemeData theme, ColorScheme colorScheme, String label) {
    return SizedBox(
      height: 52,
      child: FilledButton(
        onPressed: () => ValueAddedPage.onValueAdd(context, plan, onRefresh),
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
          minimumSize: const Size(0, 52),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
        child: Text(label),
      ),
    );
  }
}
