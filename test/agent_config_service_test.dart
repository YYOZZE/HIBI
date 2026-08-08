import 'package:flutter_test/flutter_test.dart';
import 'package:jideshi_hibi/features/assistant/services/openai_compatible_direct_api.dart';
import 'package:jideshi_hibi/features/profile/services/agent_config_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('AgentConfigService', () {
    test('默认无选中、无活跃配置', () async {
      final all = await AgentConfigService.loadAll();
      for (final id in AgentProviderId.values) {
        expect(all[id]!.apiKey, isEmpty);
      }
      expect(await AgentConfigService.selectedProviderId(), isNull);
      expect(await AgentConfigService.activeChatConfig(), isNull);
    });

    test('填写并选择火山后可作为对话凭据', () async {
      await AgentConfigService.saveAll(
        {
          AgentProviderId.volcanoArk: const AgentProviderConfig(
            id: AgentProviderId.volcanoArk,
            apiKey: 'ark-test-key-12345678',
            model: 'deepseek-v4-flash-ga-260731',
          ),
          AgentProviderId.openaiCompatible:
              const AgentProviderConfig(id: AgentProviderId.openaiCompatible),
          AgentProviderId.anthropic:
              const AgentProviderConfig(id: AgentProviderId.anthropic),
          AgentProviderId.google:
              const AgentProviderConfig(id: AgentProviderId.google),
        },
        selected: AgentProviderId.volcanoArk,
      );
      expect(await AgentConfigService.selectedProviderId(),
          AgentProviderId.volcanoArk);
      final active = await AgentConfigService.activeChatConfig();
      expect(active, isNotNull);
      expect(active!.effectiveBaseUrl, VolcanoArkDefaults.baseUrl);
      expect(active.apiKey, 'ark-test-key-12345678');
    });

    test('只填写不选择时不作为对话凭据', () async {
      await AgentConfigService.save(
        const AgentProviderConfig(
          id: AgentProviderId.openaiCompatible,
          apiKey: 'sk-test-key-123456',
          baseUrl: 'https://api.moonshot.cn/v1',
          model: 'kimi-k2.5',
        ),
      );
      expect(await AgentConfigService.activeChatConfig(), isNull);
    });

    test('选择 OpenAI 兼容后生效', () async {
      await AgentConfigService.saveAll(
        {
          AgentProviderId.volcanoArk:
              const AgentProviderConfig(id: AgentProviderId.volcanoArk),
          AgentProviderId.openaiCompatible: const AgentProviderConfig(
            id: AgentProviderId.openaiCompatible,
            apiKey: 'sk-test-key-123456',
            baseUrl: 'https://api.moonshot.cn/v1',
            model: 'kimi-k2.5',
          ),
          AgentProviderId.anthropic:
              const AgentProviderConfig(id: AgentProviderId.anthropic),
          AgentProviderId.google:
              const AgentProviderConfig(id: AgentProviderId.google),
        },
        selected: AgentProviderId.openaiCompatible,
      );
      final active = await AgentConfigService.activeChatConfig();
      expect(active!.id, AgentProviderId.openaiCompatible);
      expect(active.baseUrl, 'https://api.moonshot.cn/v1');
    });

    test('清除 Key 后取消选择', () async {
      await AgentConfigService.saveAll(
        {
          AgentProviderId.volcanoArk:
              const AgentProviderConfig(id: AgentProviderId.volcanoArk),
          AgentProviderId.openaiCompatible: const AgentProviderConfig(
            id: AgentProviderId.openaiCompatible,
            apiKey: 'sk-to-clear',
            baseUrl: 'https://example.com/v1',
          ),
          AgentProviderId.anthropic:
              const AgentProviderConfig(id: AgentProviderId.anthropic),
          AgentProviderId.google:
              const AgentProviderConfig(id: AgentProviderId.google),
        },
        selected: AgentProviderId.openaiCompatible,
      );
      await AgentConfigService.clearApiKey(AgentProviderId.openaiCompatible);
      expect(await AgentConfigService.selectedProviderId(), isNull);
      expect(await AgentConfigService.activeChatConfig(), isNull);
    });

    test('兼容旧 enabled 字段迁移为选中', () async {
      SharedPreferences.setMockInitialValues({
        'hibi_agent_provider_configs_v1':
            '{"volcano_ark":{"enabled":true,"api_key":"ark-legacy-12345678","base_url":"","model":"m1"},'
            '"openai_compatible":{"enabled":false,"api_key":"","base_url":"","model":""},'
            '"anthropic":{"enabled":false,"api_key":"","base_url":"","model":""},'
            '"google":{"enabled":false,"api_key":"","base_url":"","model":""}}',
      });
      final sel = await AgentConfigService.selectedProviderId();
      expect(sel, AgentProviderId.volcanoArk);
      final active = await AgentConfigService.activeChatConfig();
      expect(active?.apiKey, 'ark-legacy-12345678');
    });
  });

  group('AsrClientConfig', () {
    test('启用且填齐凭据后 isUsable', () async {
      await AgentConfigService.saveAsrConfig(
        const AsrClientConfig(
          enabled: true,
          appId: '1234567890',
          accessToken: 'token-abc',
          resourceId: '',
        ),
      );
      final active = await AgentConfigService.activeAsrConfig();
      expect(active, isNotNull);
      expect(active!.effectiveResourceId, AsrClientDefaults.resourceId);
      expect(active.isUsable, isTrue);
    });

    test('未启用则 activeAsrConfig 为 null', () async {
      await AgentConfigService.saveAsrConfig(
        const AsrClientConfig(
          enabled: false,
          appId: '1234567890',
          accessToken: 'token-abc',
        ),
      );
      expect(await AgentConfigService.activeAsrConfig(), isNull);
    });
  });

  group('OpenAiCompatibleDirectApi', () {
    test('normalizeBaseUrl 去掉 chat/completions 与尾斜杠', () {
      expect(
        OpenAiCompatibleDirectApi.normalizeBaseUrl(
          'https://ark.cn-beijing.volces.com/api/v3/chat/completions',
        ),
        'https://ark.cn-beijing.volces.com/api/v3',
      );
    });

    test('normalizeApiKey 去掉 Bearer/引号/Authorization', () {
      expect(
        OpenAiCompatibleDirectApi.normalizeApiKey(
          'Bearer ark-test-key-00000000-0000-0000-0000-000000000000',
        ),
        'ark-test-key-00000000-0000-0000-0000-000000000000',
      );
      expect(
        OpenAiCompatibleDirectApi.normalizeApiKey(
          '"ark-test-key-00000000-0000-0000-0000-000000000000"',
        ),
        'ark-test-key-00000000-0000-0000-0000-000000000000',
      );
      expect(
        OpenAiCompatibleDirectApi.normalizeApiKey(
          'Authorization: Bearer ark-abc-12345678',
        ),
        'ark-abc-12345678',
      );
      expect(
        OpenAiCompatibleDirectApi.normalizeApiKey('  ark-x y\nz  '),
        'ark-xyz',
      );
    });

    test('normalizeModelId 去掉包围引号', () {
      expect(
        OpenAiCompatibleDirectApi.normalizeModelId(
          '"deepseek-v4-flash-ga-260731"',
        ),
        'deepseek-v4-flash-ga-260731',
      );
    });

    test('保存时清洗误带 Bearer 的火山 Key', () async {
      await AgentConfigService.saveAll(
        {
          AgentProviderId.volcanoArk: const AgentProviderConfig(
            id: AgentProviderId.volcanoArk,
            apiKey: 'Bearer ark-paste-with-bearer-12345678',
            model: '"deepseek-v4-flash-ga-260731"',
          ),
          AgentProviderId.openaiCompatible:
              const AgentProviderConfig(id: AgentProviderId.openaiCompatible),
          AgentProviderId.anthropic:
              const AgentProviderConfig(id: AgentProviderId.anthropic),
          AgentProviderId.google:
              const AgentProviderConfig(id: AgentProviderId.google),
        },
        selected: AgentProviderId.volcanoArk,
      );
      final active = await AgentConfigService.activeChatConfig();
      expect(active!.effectiveApiKey, 'ark-paste-with-bearer-12345678');
      expect(active.effectiveModel, 'deepseek-v4-flash-ga-260731');
    });

    test('识别后端网络失败', () {
      expect(
        OpenAiCompatibleDirectApi.isBackendNetworkFailure(
          Exception(
            'ClientException with SocketException: The semaphore timeout period has expired',
          ),
        ),
        isTrue,
      );
    });
  });
}
