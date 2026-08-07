import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import 'theme_token.dart';
import 'theme_token_builder.dart';

/// 主题 ID：hibi 主题（图三毛玻璃）、暗色主题、亮色主题
enum AppThemeId {
  hibi('hibi', 'hibi主题'),
  dark('dark', '暗色主题'),
  light('light', '亮色主题'),
  spring2027('2027ss', '2027SS'),
  dreamy('dreamy', '梦幻'),
  dreamyNight('dreamy_night', '梦幻·夜'),
  cyberpunk('cyberpunk', 'CyberPunk'),
  astral('astral', '星界'),
  astralPhantasm('astral_phantasm', '星界·幻'),
  earthrealm('earthrealm', '地界');

  const AppThemeId(this.value, this.displayName);
  final String value;
  final String displayName;

  static AppThemeId fromValue(String? v) {
    if (v == 'hibi') return AppThemeId.hibi;
    if (v == 'dark') return AppThemeId.dark;
    if (v == 'light') return AppThemeId.light;
    if (v == '2027ss') return AppThemeId.spring2027;
    if (v == 'dreamy') return AppThemeId.dreamy;
    if (v == 'dreamy_night') return AppThemeId.dreamyNight;
    if (v == 'cyberpunk') return AppThemeId.cyberpunk;
    if (v == 'astral') return AppThemeId.astral;
    if (v == 'astral_phantasm') return AppThemeId.astralPhantasm;
    if (v == 'earthrealm') return AppThemeId.earthrealm;
    // 默认主题：星界（首次启动/无记录时使用）
    return AppThemeId.astral;
  }
}

/// 全局主题状态：持久化到 SharedPreferences，变更时通知重建 MaterialApp
class ThemeNotifier extends ChangeNotifier {
  ThemeNotifier()
      : _themeId = AppThemeId.astral,
        _themeKey = AppThemeId.astral.value {
    _instance = this;
  }

  /// 当前进程内全局实例（由 main.dart 创建注入）
  static ThemeNotifier? _instance;
  static ThemeNotifier? get maybeInstance => _instance;

  static const String _key = 'app_theme_id';
  /// 用户手动选主题的北京日历日（YYYY-MM-DD），与 [ThemePolicyService] 协同
  static const String manualOverrideBeijingDateKey = 'theme_manual_override_beijing_date';
  static const String _customTokenPrefix = 'theme_custom_token__';

  AppThemeId _themeId;
  String _themeKey;
  ThemeData? _dynamicTheme;

  AppThemeId get themeId => _themeId;
  String get themeKey => _themeKey;
  ThemeData? get dynamicTheme => _dynamicTheme;

  /// 应用启动时调用，从本地恢复上次选择
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString(_key);
    final key = (v ?? '').trim();
    if (key.isEmpty) {
      _themeId = AppThemeId.astral;
      _themeKey = _themeId.value;
      _dynamicTheme = null;
      return;
    }
    _themeKey = key;
    final builtIn = AppThemeId.fromValue(key);
    if (builtIn.value == key) {
      _themeId = builtIn;
      _dynamicTheme = null;
      return;
    }
    // custom：尝试读取缓存的 token 并构建 ThemeData
    _themeId = AppThemeId.astral;
    final raw = prefs.getString('$_customTokenPrefix$key') ?? '';
    final token = ThemeToken.tryParse(raw);
    _dynamicTheme = token == null ? null : ThemeTokenBuilder.build(token);
  }

  /// 切换主题。[userInitiated] 为 true 时表示用户在设置页手动选择，当日尊重该选择直至北京次日 0 点。
  Future<void> setThemeId(AppThemeId id, {bool userInitiated = false}) async {
    final prefs = await SharedPreferences.getInstance();
    if (_themeId == id && !userInitiated) return;
    _themeId = id;
    _themeKey = id.value;
    _dynamicTheme = null;
    await prefs.setString(_key, _themeKey);
    if (userInitiated) {
      tz_data.initializeTimeZones();
      final loc = tz.getLocation('Asia/Shanghai');
      final n = tz.TZDateTime.now(loc);
      final ds =
          '${n.year.toString().padLeft(4, '0')}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
      await prefs.setString(manualOverrideBeijingDateKey, ds);
    }
    notifyListeners();
  }

  Future<void> setCustomTheme({
    required String themeKey,
    required String styleCode,
    bool userInitiated = false,
  }) async {
    final k = themeKey.trim();
    if (k.isEmpty) return;
    final token = ThemeToken.tryParse(styleCode);
    if (token == null) return;
    final prefs = await SharedPreferences.getInstance();
    _themeKey = k;
    _themeId = AppThemeId.astral;
    _dynamicTheme = ThemeTokenBuilder.build(token);
    await prefs.setString(_key, _themeKey);
    await prefs.setString('$_customTokenPrefix$_themeKey', styleCode);
    if (userInitiated) {
      tz_data.initializeTimeZones();
      final loc = tz.getLocation('Asia/Shanghai');
      final n = tz.TZDateTime.now(loc);
      final ds =
          '${n.year.toString().padLeft(4, '0')}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
      await prefs.setString(manualOverrideBeijingDateKey, ds);
    }
    notifyListeners();
  }
}
