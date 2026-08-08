import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'account_storage_paths.dart';
import 'account_storage_switch.dart';
import 'auth_repository.dart';
import 'sync_merge.dart';

/// prefs：当前 GitHub 账号已明确「跳过」其他账号导入提醒。
/// 完整键：`hibi_account_import_skipped_<sanitize(userId)>`
const String kAccountImportSkippedPrefsPrefix = 'hibi_account_import_skipped_';

/// prefs：已成功将本机其他账号数据合并进该 GitHub 目录。
/// 完整键：`hibi_account_import_merged_<sanitize(userId)>`
const String kAccountImportMergedPrefsPrefix = 'hibi_account_import_merged_';

/// 兼容此前仅 local 方案的 prefs 前缀。
const String _legacySkippedPrefix = 'hibi_local_import_skipped_';
const String _legacyMergedPrefix = 'hibi_local_import_merged_';

/// 将本机 `hibi_accounts/*` 中除当前 GitHub 外的账号目录合并进当前账号。
/// 默认不静默；需用户确认「导入」；源目录保留不删。
class LocalAccountImportService {
  LocalAccountImportService._();

  static bool _promptInFlight = false;

  static String skippedPrefsKey(String userId) =>
      '$kAccountImportSkippedPrefsPrefix${AccountStoragePaths.sanitizeKey(userId)}';

  static String mergedPrefsKey(String userId) =>
      '$kAccountImportMergedPrefsPrefix${AccountStoragePaths.sanitizeKey(userId)}';

  static Future<bool> hasSkipped(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    final key = AccountStoragePaths.sanitizeKey(userId);
    return prefs.getBool(skippedPrefsKey(userId)) == true ||
        prefs.getBool('$_legacySkippedPrefix$key') == true;
  }

  static Future<bool> hasMerged(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    final key = AccountStoragePaths.sanitizeKey(userId);
    return prefs.getBool(mergedPrefsKey(userId)) == true ||
        prefs.getBool('$_legacyMergedPrefix$key') == true;
  }

  static Future<void> markSkipped(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(skippedPrefsKey(userId), true);
  }

  static Future<void> markMerged(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(mergedPrefsKey(userId), true);
  }

  /// 当前 GitHub 目录键；非 GitHub 时返回 null。
  static String? currentGitHubKey() {
    final user = AuthRepository.instance.currentUser;
    if (user == null || !user.isGitHub || user.userId.isEmpty) return null;
    return AccountStoragePaths.sanitizeKey(user.userId);
  }

  /// 枚举本机可导入源目录（排除当前 GitHub），且含实质 mind/schedule/assistant。
  static Future<List<String>> listImportableSourceKeys() async {
    await AccountStoragePaths.migrateLegacyIntoLocalIfNeeded();
    final target = currentGitHubKey();
    if (target == null) return const [];

    final keys = await AccountStoragePaths.listAccountKeys();
    final out = <String>[];
    for (final key in keys) {
      if (key == target) continue;
      if (await _accountHasSubstantialData(key)) out.add(key);
    }
    return out;
  }

  static Future<bool> hasImportableOtherAccountData() async {
    final sources = await listImportableSourceKeys();
    return sources.isNotEmpty;
  }

  /// local 有实质内容，或任意其他非当前 GitHub 目录有实质内容，
  /// 且当前账号尚未 merged / skipped。
  static Future<bool> shouldPromptForCurrentUser() async {
    final auth = AuthRepository.instance;
    if (auth.accessState != AppAccessState.githubOk) return false;
    final user = auth.currentUser;
    if (user == null || !user.isGitHub || user.userId.isEmpty) return false;
    if (await hasMerged(user.userId)) return false;
    if (await hasSkipped(user.userId)) return false;
    return hasImportableOtherAccountData();
  }

  /// GitHub + Star 进主壳后：检测到其他账号未合并数据则弹决策。
  static Future<void> maybeShowPrompt(BuildContext context) async {
    if (_promptInFlight || !context.mounted) return;
    if (!await shouldPromptForCurrentUser()) return;
    if (!context.mounted) return;

    final user = AuthRepository.instance.currentUser;
    if (user == null) return;

    _promptInFlight = true;
    try {
      final action = await showDialog<_ImportDialogAction>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) {
          final theme = Theme.of(ctx);
          return AlertDialog(
            backgroundColor:
                theme.dialogTheme.backgroundColor ?? theme.colorScheme.surface,
            surfaceTintColor: Colors.transparent,
            content: const Text('检测到本机其他账号数据，是否导入到当前 GitHub 账号？'),
            actions: [
              TextButton(
                onPressed: () =>
                    Navigator.of(ctx).pop(_ImportDialogAction.skip),
                child: const Text('跳过'),
              ),
              FilledButton(
                onPressed: () =>
                    Navigator.of(ctx).pop(_ImportDialogAction.import),
                child: const Text('导入'),
              ),
            ],
          );
        },
      );

      if (action == _ImportDialogAction.skip) {
        await markSkipped(user.userId);
        return;
      }
      if (action != _ImportDialogAction.import) return;

      try {
        await importAllOtherAccountsIntoActiveGitHub();
        await markMerged(user.userId);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('已导入本机其他账号数据')),
          );
        }
      } catch (_) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('导入失败')),
          );
        }
      }
    } finally {
      _promptInFlight = false;
    }
  }

  /// 设置页手动入口。
  static Future<void> showManualImport(BuildContext context) async {
    final auth = AuthRepository.instance;
    if (auth.accessState != AppAccessState.githubOk) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请先使用 GitHub 登录')),
        );
      }
      return;
    }
    final sources = await listImportableSourceKeys();
    if (sources.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('没有可导入的其他账号数据')),
        );
      }
      return;
    }
    if (!context.mounted) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return AlertDialog(
          backgroundColor:
              theme.dialogTheme.backgroundColor ?? theme.colorScheme.surface,
          surfaceTintColor: Colors.transparent,
          title: const Text('从本机其他账号导入'),
          content: Text(
            '将把 ${sources.length} 个本机账号目录合并到当前 GitHub 账号。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('导入'),
            ),
          ],
        );
      },
    );
    if (ok != true || !context.mounted) return;

    try {
      await importAllOtherAccountsIntoActiveGitHub();
      final user = auth.currentUser;
      if (user != null) await markMerged(user.userId);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已导入本机其他账号数据')),
        );
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('导入失败')),
        );
      }
    }
  }

  /// 一次合并全部可导入源目录 → 当前 GitHub 目录。
  static Future<void> importAllOtherAccountsIntoActiveGitHub() async {
    final target = currentGitHubKey();
    if (target == null) {
      throw StateError('当前不是 GitHub 账号');
    }
    if (AccountStoragePaths.activeKey != target) {
      throw StateError('活动目录与当前 GitHub 不一致');
    }

    final sources = await listImportableSourceKeys();
    if (sources.isEmpty) return;

    var acc = await _readBundleExact(target);
    for (final src in sources) {
      final bundle = await _readBundleExact(src);
      if (_bundleIsEmpty(bundle)) continue;
      // 源作为 SyncMerge「local」侧：agents 冲突保留源；messages 去重拼接
      // 但「不破坏当前 GitHub」：agents 冲突改为保留目标 → incoming=源, base=acc 时
      // mergeAssistant(local=目标优先) → 用 mergeAssistant(acc.assistant, src.assistant)
      acc = _mergeBundles(base: acc, incoming: bundle);
    }

    await _writeBundle(target, acc);
    await reloadStoresAfterAccountSwitch();
  }

  /// [base] 当前目标累加；[incoming] 源账号。
  /// mind/schedule：LWW；assistant：同 id 保留目标（base），messages 去重追加。
  static Map<String, dynamic> _mergeBundles({
    required Map<String, dynamic> base,
    required Map<String, dynamic> incoming,
  }) {
    final mind = SyncMerge.mergeMindLists(
      base['mind'] as List<dynamic>?,
      incoming['mind'] as List<dynamic>?,
    );
    final schedule = SyncMerge.mergeScheduleListsByMtime(
      base['schedule'] as List<dynamic>?,
      incoming['schedule'] as List<dynamic>?,
    );
    final baseAssist = base['assistant'] is Map
        ? Map<String, dynamic>.from(base['assistant'] as Map)
        : null;
    final inAssist = incoming['assistant'] is Map
        ? Map<String, dynamic>.from(incoming['assistant'] as Map)
        : null;
    // local 侧胜出 → 传入 base 以保留当前 GitHub agents
    final assistant = SyncMerge.mergeAssistant(baseAssist, inAssist);
    return {
      'mind': mind,
      'schedule': schedule,
      'assistant': assistant,
    };
  }

  static Future<bool> _accountHasSubstantialData(String dirName) async {
    final bundle = await _readBundleExact(dirName);
    return !_bundleIsEmpty(bundle);
  }

  static bool _bundleIsEmpty(Map<String, dynamic> bundle) {
    final mind = bundle['mind'];
    final schedule = bundle['schedule'];
    final assistant = bundle['assistant'];
    final mindEmpty = mind is! List || mind.isEmpty;
    final scheduleEmpty = schedule is! List || schedule.isEmpty;
    var assistantEmpty = true;
    if (assistant is Map) {
      final agents = assistant['agents'];
      final messages = assistant['messages'];
      final hasAgents = agents is List && agents.isNotEmpty;
      var hasMsgs = false;
      if (messages is Map) {
        for (final v in messages.values) {
          if (v is List && v.isNotEmpty) {
            hasMsgs = true;
            break;
          }
        }
      }
      assistantEmpty = !hasAgents && !hasMsgs;
    }
    return mindEmpty && scheduleEmpty && assistantEmpty;
  }

  /// 按磁盘目录名读取（不二次 sanitize，避免旧目录名错位）。
  static Future<Map<String, dynamic>> _readBundleExact(String dirName) async {
    final bundle = <String, dynamic>{
      'mind': <dynamic>[],
      'schedule': <dynamic>[],
      'assistant': <String, dynamic>{
        'agents': <dynamic>[],
        'messages': <String, dynamic>{},
      },
    };
    final dir = await AccountStoragePaths.accountDirExact(dirName);
    if (!await dir.exists()) return bundle;
    try {
      final mindFile = File('${dir.path}/hibi_mind_nodes.json');
      if (await mindFile.exists()) {
        final raw = jsonDecode(await mindFile.readAsString());
        if (raw is List) bundle['mind'] = raw;
      }
    } catch (_) {}
    try {
      final scheduleFile = File('${dir.path}/hibi_schedule_events.json');
      if (await scheduleFile.exists()) {
        final raw = jsonDecode(await scheduleFile.readAsString());
        if (raw is List) bundle['schedule'] = raw;
      }
    } catch (_) {}
    try {
      final assistantDir = Directory('${dir.path}/hibi_assistant');
      List<dynamic> agents = [];
      final messages = <String, dynamic>{};
      if (await assistantDir.exists()) {
        final agentsFile = File('${assistantDir.path}/assistant_agents.json');
        if (await agentsFile.exists()) {
          final raw = jsonDecode(await agentsFile.readAsString());
          if (raw is List) agents = raw;
        }
        await for (final ent in assistantDir.list()) {
          if (ent is File &&
              ent.path.contains('messages_') &&
              ent.path.endsWith('.json')) {
            final name = ent.uri.pathSegments.last
                .replaceFirst('messages_', '')
                .replaceFirst('.json', '');
            try {
              messages[name] = jsonDecode(await ent.readAsString());
            } catch (_) {}
          }
        }
      }
      bundle['assistant'] = {'agents': agents, 'messages': messages};
    } catch (_) {}
    return bundle;
  }

  static Future<void> _writeBundle(
    String key,
    Map<String, dynamic> bundle,
  ) async {
    final dir = await AccountStoragePaths.accountDirForKey(key);
    await File('${dir.path}/hibi_mind_nodes.json')
        .writeAsString(jsonEncode(bundle['mind'] ?? []));
    await File('${dir.path}/hibi_schedule_events.json')
        .writeAsString(jsonEncode(bundle['schedule'] ?? []));
    final assistantDir = Directory('${dir.path}/hibi_assistant');
    if (!await assistantDir.exists()) {
      await assistantDir.create(recursive: true);
    }
    final assistant = bundle['assistant'];
    if (assistant is Map) {
      await File('${assistantDir.path}/assistant_agents.json')
          .writeAsString(jsonEncode(assistant['agents'] ?? []));
      final messages = assistant['messages'];
      if (messages is Map) {
        for (final e in messages.entries) {
          await File('${assistantDir.path}/messages_${e.key}.json')
              .writeAsString(jsonEncode(e.value));
        }
      }
    }
  }
}

enum _ImportDialogAction { import, skip }
