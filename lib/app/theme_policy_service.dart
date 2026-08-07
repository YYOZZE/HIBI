import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import '../config/api_config.dart';
import 'theme_notifier.dart';

/// 静默拉取服务端主题策略（北京时间周历 + 默认主题），与用户当日手动覆盖协同。
class ThemePolicyService {
  ThemePolicyService._();
  static final ThemePolicyService instance = ThemePolicyService._();

  static const _debounce = Duration(seconds: 5);
  DateTime? _lastApplyAt;
  Timer? _midnightTimer;

  /// 服务端标记为隐藏的主题，不在 App 主题列表中展示（与 [refreshAndApply] 同步更新）。
  final ValueNotifier<Set<String>> hiddenThemeIdsNotifier = ValueNotifier<Set<String>>(<String>{});

  /// 当前生效主题的样式代码（从服务端公开接口下发），仅缓存，不一定立即用于渲染。
  static const String effectiveStyleCodeKey = 'theme_effective_style_code';
  static const String effectiveStyleCodeUpdatedAtKey = 'theme_effective_style_code_updated_at';
  static const String policyEtagKey = 'theme_policy_etag';
  static const String policyCacheKey = 'theme_policy_cache_json';

  /// 可选主题目录（内置 + 自定义且可见），用于主题设置页展示。
  final ValueNotifier<List<ThemeCatalogItem>> themeCatalogNotifier =
      ValueNotifier<List<ThemeCatalogItem>>(<ThemeCatalogItem>[]);

  static const String catalogCacheKey = 'theme_catalog_cache_json';

  void _ensureTz() {
    try {
      tz_data.initializeTimeZones();
    } catch (_) {}
  }

  void _scheduleNextBeijingMidnight(ThemeNotifier notifier) {
    _midnightTimer?.cancel();
    _ensureTz();
    final loc = tz.getLocation('Asia/Shanghai');
    final n = tz.TZDateTime.now(loc);
    final nextMidnight = tz.TZDateTime(loc, n.year, n.month, n.day).add(const Duration(days: 1));
    final wait = nextMidnight.difference(n);
    if (wait.inMilliseconds <= 0) return;
    _midnightTimer = Timer(wait, () {
      unawaited(refreshAndApply(notifier, bypassDebounce: true));
    });
  }

  /// 启动、回前台等时机调用：按策略应用主题（无弹窗、失败则保持现状）。
  Future<void> refreshAndApply(ThemeNotifier notifier, {bool bypassDebounce = false}) async {
    if (kIsWeb) return;
    final now = DateTime.now();
    if (!bypassDebounce && _lastApplyAt != null && now.difference(_lastApplyAt!) < _debounce) {
      return;
    }

    final base = ApiConfig.authApiBaseUrl.replaceFirst(RegExp(r'/$'), '');
    if (base.isEmpty || base == 'YOUR_AUTH_SERVER_URL') return;

    try {
      final prefs = await SharedPreferences.getInstance();
      final uri = Uri.parse('$base/api/app/theme_policy');
      final etag = prefs.getString(policyEtagKey);
      final headers = <String, String>{};
      if (etag != null && etag.trim().isNotEmpty) {
        headers['If-None-Match'] = etag;
      }
      final resp = await http.get(uri, headers: headers).timeout(const Duration(seconds: 12));
      Map<String, dynamic>? data;
      if (resp.statusCode == 304) {
        final cached = prefs.getString(policyCacheKey);
        if (cached != null && cached.trim().isNotEmpty) {
          final decoded = jsonDecode(cached);
          if (decoded is Map<String, dynamic>) {
            data = decoded;
          }
        }
      } else if (resp.statusCode == 200) {
        final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
        if (decoded is Map<String, dynamic>) {
          data = decoded;
          await prefs.setString(policyCacheKey, jsonEncode(decoded));
          final newEtag = resp.headers['etag'];
          if (newEtag != null && newEtag.trim().isNotEmpty) {
            await prefs.setString(policyEtagKey, newEtag.trim());
          }
        }
      } else {
        return;
      }
      if (data == null) return;

      final hidden = <String>{};
      final rawHidden = data['hidden_theme_ids'];
      if (rawHidden is List) {
        for (final x in rawHidden) {
          hidden.add(x.toString());
        }
      }
      hiddenThemeIdsNotifier.value = hidden;

      final beijingDate = data['beijing_date']?.toString() ?? '';
      final defaultId = (data['default_theme_id']?.toString() ?? 'astral').trim();
      final effectiveKey = (data['effective_theme_key']?.toString() ?? '').trim();
      final effectiveRaw = data['effective_theme_id']?.toString();
      final effectiveId = (effectiveRaw != null && effectiveRaw.trim().isNotEmpty)
          ? effectiveRaw.trim()
          : defaultId;
      final effectiveStyleCode = data['effective_style_code']?.toString() ?? '';

      final rawCatalog = data['theme_catalog'];
      if (rawCatalog is List) {
        final items = <ThemeCatalogItem>[];
        for (final x in rawCatalog) {
          if (x is! Map) continue;
          final id = x['id']?.toString().trim() ?? '';
          final name = x['name']?.toString().trim() ?? id;
          final applyId = x['apply_theme_id']?.toString().trim() ?? '';
          final styleCode = x['style_code']?.toString() ?? '';
          final kind = x['kind']?.toString().trim() ?? '';
          if (id.isEmpty) continue;
          // custom 可不绑定 apply_theme_id（只要有 style_code）；built_in 必须有 apply_theme_id
          final isCustom = kind == 'custom' || id.startsWith('custom_');
          if (!isCustom && applyId.isEmpty) continue;
          if (isCustom && applyId.isEmpty && styleCode.trim().isEmpty) continue;
          items.add(
            ThemeCatalogItem(
              id: id,
              name: name.isEmpty ? id : name,
              applyThemeId: applyId,
              kind: kind,
              styleCode: styleCode,
            ),
          );
        }
        themeCatalogNotifier.value = items;
        await prefs.setString(catalogCacheKey, jsonEncode(rawCatalog));
      }

      // 缓存样式代码（不要求实时生效；供后续渲染/调试使用）
      await prefs.setString(effectiveStyleCodeKey, effectiveStyleCode);
      final uat = data['updated_at'];
      final updatedAt = uat is num ? uat.toDouble() : 0.0;
      await prefs.setDouble(effectiveStyleCodeUpdatedAtKey, updatedAt);

      final manualDate = prefs.getString(ThemeNotifier.manualOverrideBeijingDateKey);
      if (manualDate != null && manualDate.isNotEmpty && manualDate == beijingDate) {
        _lastApplyAt = DateTime.now();
        _scheduleNextBeijingMidnight(notifier);
        return;
      }

      if (effectiveKey.isNotEmpty && effectiveKey.startsWith('custom_') && effectiveStyleCode.trim().isNotEmpty) {
        await notifier.setCustomTheme(themeKey: effectiveKey, styleCode: effectiveStyleCode);
      } else {
        await notifier.setThemeId(AppThemeId.fromValue(effectiveId));
      }
      _lastApplyAt = DateTime.now();
      _scheduleNextBeijingMidnight(notifier);
    } catch (_) {
      // 静默失败
    }
  }
}

class ThemeCatalogItem {
  const ThemeCatalogItem({
    required this.id,
    required this.name,
    required this.applyThemeId,
    this.kind = '',
    this.styleCode = '',
  });

  final String id;
  final String name;
  /// 客户端实际应用的内置主题 id（对应 [AppThemeId.value]）
  final String applyThemeId;
  /// built_in / custom
  final String kind;
  /// custom 主题的 JSON token（可能为空）
  final String styleCode;
}
