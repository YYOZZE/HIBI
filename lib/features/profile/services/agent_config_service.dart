import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../assistant/services/openai_compatible_direct_api.dart';

/// 智能体提供商类型（与配置页区块一一对应）
enum AgentProviderId {
  /// 火山方舟（OpenAI 兼容协议，专用默认 Base URL / 模型提示）
  volcanoArk,
  openaiCompatible,
  anthropic,
  google,
}

extension AgentProviderIdX on AgentProviderId {
  String get storageKey {
    switch (this) {
      case AgentProviderId.volcanoArk:
        return 'volcano_ark';
      case AgentProviderId.openaiCompatible:
        return 'openai_compatible';
      case AgentProviderId.anthropic:
        return 'anthropic';
      case AgentProviderId.google:
        return 'google';
    }
  }

  String get displayName {
    switch (this) {
      case AgentProviderId.volcanoArk:
        return '火山方舟';
      case AgentProviderId.openaiCompatible:
        return 'OpenAI 兼容';
      case AgentProviderId.anthropic:
        return 'Anthropic';
      case AgentProviderId.google:
        return 'Google';
    }
  }

  /// 可走对话链路（服务端透传或客户端直连）的提供商
  bool get supportsChatRelay =>
      this == AgentProviderId.volcanoArk ||
      this == AgentProviderId.openaiCompatible;

  static AgentProviderId? tryParse(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    for (final id in AgentProviderId.values) {
      if (id.name == raw || id.storageKey == raw) return id;
    }
    return null;
  }
}

/// 火山方舟默认接入点（与控制台「快捷 API 接入」一致，不含 /chat/completions）
class VolcanoArkDefaults {
  static const baseUrl = 'https://ark.cn-beijing.volces.com/api/v3';
  /// 占位示例；请换成控制台当前模型/接入点 ID
  static const exampleModel = 'deepseek-v4-flash-ga-260731';
  static const apiKeyHint = 'ark-…（勿带 Bearer）';
}

/// 单个提供商的本地配置（可多填；页面用 selectedProviderId 单选生效）
class AgentProviderConfig {
  const AgentProviderConfig({
    required this.id,
    this.apiKey = '',
    this.baseUrl = '',
    this.model = '',
  });

  final AgentProviderId id;
  final String apiKey;
  final String baseUrl;
  final String model;

  bool get hasApiKey =>
      OpenAiCompatibleDirectApi.normalizeApiKey(apiKey).isNotEmpty;

  /// 实际调用用的 API Key（已去掉 Bearer/引号等粘贴杂质）
  String get effectiveApiKey =>
      OpenAiCompatibleDirectApi.normalizeApiKey(apiKey);

  /// 实际调用用的 Base URL（火山未填时回落默认）
  String get effectiveBaseUrl {
    final raw = baseUrl.trim().isNotEmpty
        ? baseUrl
        : (id == AgentProviderId.volcanoArk ? VolcanoArkDefaults.baseUrl : '');
    return OpenAiCompatibleDirectApi.normalizeBaseUrl(raw);
  }

  /// 实际调用用的模型名（火山未填时用示例模型名，避免空 model 调不通）
  String get effectiveModel {
    final m = OpenAiCompatibleDirectApi.normalizeModelId(model);
    if (m.isNotEmpty) return m;
    if (id == AgentProviderId.volcanoArk) return VolcanoArkDefaults.exampleModel;
    return '';
  }

  AgentProviderConfig copyWith({
    String? apiKey,
    String? baseUrl,
    String? model,
  }) {
    return AgentProviderConfig(
      id: id,
      apiKey: apiKey ?? this.apiKey,
      baseUrl: baseUrl ?? this.baseUrl,
      model: model ?? this.model,
    );
  }

  Map<String, dynamic> toJson() => {
        'api_key': apiKey,
        'base_url': baseUrl,
        'model': model,
        // 兼容旧字段：不再用 per-provider enabled，保留读取
      };

  factory AgentProviderConfig.fromJson(
    AgentProviderId id,
    Map<String, dynamic>? json,
  ) {
    if (json == null) return AgentProviderConfig(id: id);
    return AgentProviderConfig(
      id: id,
      apiKey: OpenAiCompatibleDirectApi.normalizeApiKey(
        (json['api_key'] ?? json['apiKey'] ?? '').toString(),
      ),
      baseUrl: OpenAiCompatibleDirectApi.normalizeBaseUrl(
        (json['base_url'] ?? json['baseUrl'] ?? '').toString(),
      ),
      model: OpenAiCompatibleDirectApi.normalizeModelId(
        (json['model'] ?? '').toString(),
      ),
    );
  }
}

/// 豆包大模型流式语音识别（火山 OpenSpeech）客户端配置。
/// 填写并启用后，经 HIBI 后端 `/api/asr/stream` 透传凭据调用；也可仅依赖服务端 .env。
class AsrClientConfig {
  const AsrClientConfig({
    this.enabled = false,
    this.appId = '',
    this.accessToken = '',
    this.resourceId = AsrClientDefaults.resourceId,
  });

  final bool enabled;
  final String appId;
  final String accessToken;
  final String resourceId;

  bool get hasCredentials =>
      appId.trim().isNotEmpty && accessToken.trim().isNotEmpty;

  /// 启用且凭据齐全时，前端视为「语音可用」（即使服务端未配 ASR）
  bool get isUsable => enabled && hasCredentials;

  String get effectiveResourceId {
    final r = resourceId.trim();
    return r.isEmpty ? AsrClientDefaults.resourceId : r;
  }

  AsrClientConfig copyWith({
    bool? enabled,
    String? appId,
    String? accessToken,
    String? resourceId,
  }) {
    return AsrClientConfig(
      enabled: enabled ?? this.enabled,
      appId: appId ?? this.appId,
      accessToken: accessToken ?? this.accessToken,
      resourceId: resourceId ?? this.resourceId,
    );
  }

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'app_id': appId,
        'access_token': accessToken,
        'resource_id': resourceId,
      };

  factory AsrClientConfig.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const AsrClientConfig();
    return AsrClientConfig(
      enabled: json['enabled'] == true,
      appId: (json['app_id'] ?? json['appId'] ?? '').toString(),
      accessToken: (json['access_token'] ?? json['accessToken'] ?? '').toString(),
      resourceId: (json['resource_id'] ?? json['resourceId'] ?? AsrClientDefaults.resourceId)
          .toString(),
    );
  }
}

class AsrClientDefaults {
  static const resourceId = 'volc.bigasr.sauc.duration';
}

/// 智能体 API 配置：本地 SharedPreferences 持久化。
///
/// 可填写多家提供商，但同一时间只能「选择」一个用于对话调用。
class AgentConfigService {
  AgentConfigService._();

  static const String _prefsKey = 'hibi_agent_provider_configs_v1';
  static const String _selectedKey = 'hibi_agent_selected_provider_v1';
  static const String _asrKey = 'hibi_agent_asr_config_v1';

  /// 读取全部提供商配置
  static Future<Map<AgentProviderId, AgentProviderConfig>> loadAll() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    final Map<String, dynamic> root = {};
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          root.addAll(Map<String, dynamic>.from(decoded));
        }
      } catch (_) {}
    }
    final out = <AgentProviderId, AgentProviderConfig>{};
    for (final id in AgentProviderId.values) {
      final section = root[id.storageKey];
      out[id] = AgentProviderConfig.fromJson(
        id,
        section is Map ? Map<String, dynamic>.from(section) : null,
      );
    }
    return out;
  }

  static Future<AgentProviderConfig> load(AgentProviderId id) async {
    final all = await loadAll();
    return all[id] ?? AgentProviderConfig(id: id);
  }

  /// 当前选中的提供商（可为 null：未选择，走服务端默认）
  static Future<AgentProviderId?> selectedProviderId() async {
    final prefs = await SharedPreferences.getInstance();
    final parsed = AgentProviderIdX.tryParse(prefs.getString(_selectedKey));
    if (parsed != null) return parsed;

    // 兼容旧版：若曾用 enabled=true，迁移为选中第一个启用的
    final raw = prefs.getString(_prefsKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          for (final id in AgentProviderId.values) {
            final section = decoded[id.storageKey];
            if (section is Map && section['enabled'] == true) {
              final key = (section['api_key'] ?? '').toString();
              if (key.isNotEmpty && id.supportsChatRelay) {
                await setSelectedProviderId(id);
                return id;
              }
            }
          }
        }
      } catch (_) {}
    }
    return null;
  }

  static Future<void> setSelectedProviderId(AgentProviderId? id) async {
    final prefs = await SharedPreferences.getInstance();
    if (id == null) {
      await prefs.remove(_selectedKey);
    } else {
      await prefs.setString(_selectedKey, id.name);
    }
  }

  /// 保存单个提供商（合并写入）
  static Future<void> save(AgentProviderConfig config) async {
    final all = await loadAll();
    all[config.id] = _normalizeForPersist(config);
    await _persist(all);
  }

  /// 批量保存配置 + 选中项
  static Future<void> saveAll(
    Map<AgentProviderId, AgentProviderConfig> all, {
    AgentProviderId? selected,
  }) async {
    final normalized = <AgentProviderId, AgentProviderConfig>{};
    for (final e in all.entries) {
      normalized[e.key] = _normalizeForPersist(e.value);
    }
    await _persist(normalized);
    await setSelectedProviderId(selected);
  }

  /// 清除某个提供商的 API Key（保留其它字段）；若正选中则取消选择
  static Future<void> clearApiKey(AgentProviderId id) async {
    final cfg = await load(id);
    await save(cfg.copyWith(apiKey: ''));
    final sel = await selectedProviderId();
    if (sel == id) await setSelectedProviderId(null);
  }

  /// 当前用于对话的活跃配置：仅当「已选择」且有 Key 且支持对话链路时返回。
  static Future<AgentProviderConfig?> activeChatConfig() async {
    final selected = await selectedProviderId();
    if (selected == null || !selected.supportsChatRelay) return null;
    final cfg = await load(selected);
    if (!cfg.hasApiKey) return null;
    return cfg;
  }

  static Future<AsrClientConfig> loadAsrConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_asrKey);
    if (raw == null || raw.isEmpty) return const AsrClientConfig();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return AsrClientConfig.fromJson(Map<String, dynamic>.from(decoded));
      }
    } catch (_) {}
    return const AsrClientConfig();
  }

  static Future<void> saveAsrConfig(AsrClientConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    final normalized = config.copyWith(
      appId: config.appId.trim(),
      accessToken: config.accessToken.trim(),
      resourceId: config.effectiveResourceId,
    );
    await prefs.setString(_asrKey, jsonEncode(normalized.toJson()));
  }

  /// 本地 ASR 可用时返回凭据；否则 null（回退服务端 .env）
  static Future<AsrClientConfig?> activeAsrConfig() async {
    final cfg = await loadAsrConfig();
    if (!cfg.isUsable) return null;
    return cfg;
  }

  static AgentProviderConfig _normalizeForPersist(AgentProviderConfig cfg) {
    return cfg.copyWith(
      apiKey: OpenAiCompatibleDirectApi.normalizeApiKey(cfg.apiKey),
      baseUrl: OpenAiCompatibleDirectApi.normalizeBaseUrl(cfg.baseUrl),
      model: OpenAiCompatibleDirectApi.normalizeModelId(cfg.model),
    );
  }

  static Future<void> _persist(
    Map<AgentProviderId, AgentProviderConfig> all,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final root = <String, dynamic>{};
    for (final id in AgentProviderId.values) {
      final cfg = all[id] ?? AgentProviderConfig(id: id);
      root[id.storageKey] = cfg.toJson();
    }
    await prefs.setString(_prefsKey, jsonEncode(root));
  }
}
