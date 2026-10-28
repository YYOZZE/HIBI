import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../profile/services/agent_config_service.dart';
import '../models/colleague_roster.dart';
import 'local_llama_server.dart';

/// 每个同事单独的接口。对话记录按同事 id 存放，这里只换调用目标。
enum ColleagueApiMode { local, inherit, custom }

class ColleagueEndpoint {
  const ColleagueEndpoint({
    this.mode = ColleagueApiMode.local,
    this.apiKey = '',
    this.baseUrl = '',
    this.model = '',
  });

  final ColleagueApiMode mode;
  final String apiKey;
  final String baseUrl;
  final String model;

  Map<String, dynamic> toJson() => {
        'mode': mode.name,
        'apiKey': apiKey,
        'baseUrl': baseUrl,
        'model': model,
      };

  static ColleagueEndpoint fromJson(Map<String, dynamic>? json) {
    if (json == null) return const ColleagueEndpoint();
    final modeName = (json['mode'] ?? 'local').toString();
    final mode = ColleagueApiMode.values.firstWhere(
      (m) => m.name == modeName,
      orElse: () => ColleagueApiMode.local,
    );
    return ColleagueEndpoint(
      mode: mode,
      apiKey: (json['apiKey'] ?? '').toString(),
      baseUrl: (json['baseUrl'] ?? '').toString(),
      model: (json['model'] ?? '').toString(),
    );
  }

  String get label {
    switch (mode) {
      case ColleagueApiMode.local:
        return '本地 Qwen';
      case ColleagueApiMode.inherit:
        return '跟随全局配置';
      case ColleagueApiMode.custom:
        return '单独接口';
    }
  }
}

class ColleagueEndpointStore {
  ColleagueEndpointStore._();

  static const _prefsKey = 'hibi_colleague_endpoints_v1';

  static Future<Map<String, ColleagueEndpoint>> loadAll() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    final out = <String, ColleagueEndpoint>{
      for (final s in ColleagueRoster.all) s.id: const ColleagueEndpoint(),
    };
    if (raw == null || raw.isEmpty) return out;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        for (final s in ColleagueRoster.all) {
          final section = decoded[s.id];
          if (section is Map) {
            out[s.id] = ColleagueEndpoint.fromJson(Map<String, dynamic>.from(section));
          }
        }
      }
    } catch (_) {}
    return out;
  }

  static Future<ColleagueEndpoint> load(String agentId) async {
    final all = await loadAll();
    return all[agentId] ?? const ColleagueEndpoint();
  }

  static Future<void> saveAll(Map<String, ColleagueEndpoint> all) async {
    final prefs = await SharedPreferences.getInstance();
    final root = <String, dynamic>{};
    for (final s in ColleagueRoster.all) {
      root[s.id] = (all[s.id] ?? const ColleagueEndpoint()).toJson();
    }
    await prefs.setString(_prefsKey, jsonEncode(root));
  }

  /// 解析成可直接调用的配置。本地模式会先拉起 llama-server。
  /// 不读写对话记录。
  static Future<AgentProviderConfig> resolve(String agentId) async {
    final ep = await load(agentId);
    switch (ep.mode) {
      case ColleagueApiMode.local:
        await LocalLlamaServer.ensureRunning();
        final paths = await LocalLlamaServer.loadPaths();
        final base = ep.baseUrl.trim().isNotEmpty ? ep.baseUrl.trim() : paths.baseUrl;
        final model = ep.model.trim().isNotEmpty
            ? ep.model.trim()
            : LocalLlamaDefaults.modelAlias;
        return AgentProviderConfig(
          id: AgentProviderId.openaiCompatible,
          apiKey: LocalLlamaDefaults.apiKey,
          baseUrl: base,
          model: model,
        );
      case ColleagueApiMode.inherit:
        final global = await AgentConfigService.activeChatConfig();
        if (global == null) {
          throw Exception(
            '「跟随全局配置」还没有可用的 Key。请先在智能体配置里选中火山或 OpenAI 兼容，或改成本地 Qwen / 单独指定。',
          );
        }
        return global;
      case ColleagueApiMode.custom:
        final key = ep.apiKey.trim();
        final base = ep.baseUrl.trim();
        final model = ep.model.trim();
        if (key.isEmpty || base.isEmpty || model.isEmpty) {
          throw Exception('单独接口需要同时填写 API Key、Base URL 和模型名。');
        }
        return AgentProviderConfig(
          id: AgentProviderId.openaiCompatible,
          apiKey: key,
          baseUrl: base,
          model: model,
        );
    }
  }
}
