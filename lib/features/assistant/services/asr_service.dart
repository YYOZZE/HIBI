import '../../profile/services/agent_config_service.dart';

/// ASR 可用性检查（豆包流式识别由 [AsrStreamService] App 直连 OpenSpeech）。
class AsrService {
  AsrService();

  /// 仅当「智能体配置」中启用并填写 APP ID / Access Token 时可用。
  Future<bool> isConfigured() async {
    final local = await AgentConfigService.activeAsrConfig();
    return local != null;
  }
}
