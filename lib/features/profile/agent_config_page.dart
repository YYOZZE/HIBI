import 'package:flutter/material.dart';

import '../../app/app_glass_styles.dart';
import '../../app/frosted_background.dart';
import 'services/agent_config_service.dart';

/// 智能体配置页：可填写多家 API，但同一时间只能选择一个用于调用。
class AgentConfigPage extends StatefulWidget {
  const AgentConfigPage({super.key});

  @override
  State<AgentConfigPage> createState() => _AgentConfigPageState();
}

class _AgentConfigPageState extends State<AgentConfigPage> {
  bool _loading = true;
  bool _saving = false;
  AgentProviderId? _selected;
  final Map<AgentProviderId, _ProviderEditors> _editors = {};

  bool _asrEnabled = false;
  bool _asrTokenObscure = true;
  bool _asrTokenEditing = false;
  String _asrSavedToken = '';
  late final TextEditingController _asrAppIdController;
  late final TextEditingController _asrTokenController;
  late final TextEditingController _asrResourceController;
  late final FocusNode _asrTokenFocus;

  static const _masked = _ProviderEditors.maskedPlaceholder;

  @override
  void initState() {
    super.initState();
    _asrAppIdController = TextEditingController();
    _asrTokenController = TextEditingController();
    _asrResourceController = TextEditingController(
      text: AsrClientDefaults.resourceId,
    );
    _asrTokenFocus = FocusNode()
      ..addListener(() {
        if (_asrTokenFocus.hasFocus &&
            _asrTokenController.text == _masked &&
            _asrSavedToken.isNotEmpty) {
          _asrTokenController.clear();
          setState(() => _asrTokenEditing = true);
        }
      });
    _load();
  }

  @override
  void dispose() {
    for (final e in _editors.values) {
      e.dispose();
    }
    _asrAppIdController.dispose();
    _asrTokenController.dispose();
    _asrResourceController.dispose();
    _asrTokenFocus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final all = await AgentConfigService.loadAll();
    final selected = await AgentConfigService.selectedProviderId();
    final asr = await AgentConfigService.loadAsrConfig();
    if (!mounted) return;
    for (final id in AgentProviderId.values) {
      final cfg = all[id] ?? AgentProviderConfig(id: id);
      _editors[id]?.dispose();
      _editors[id] = _ProviderEditors.fromConfig(cfg);
      if (id == AgentProviderId.volcanoArk &&
          _editors[id]!.baseUrlController.text.trim().isEmpty) {
        _editors[id]!.baseUrlController.text = VolcanoArkDefaults.baseUrl;
      }
    }
    _asrEnabled = asr.enabled;
    _asrSavedToken = asr.accessToken;
    _asrAppIdController.text = asr.appId;
    _asrTokenController.text =
        asr.accessToken.isNotEmpty ? _masked : '';
    _asrTokenEditing = false;
    _asrResourceController.text = asr.effectiveResourceId;
    setState(() {
      _selected = selected;
      _loading = false;
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final map = <AgentProviderId, AgentProviderConfig>{};
      for (final id in AgentProviderId.values) {
        final ed = _editors[id]!;
        var key = ed.keyController.text.trim();
        if (key.isEmpty || key == _ProviderEditors.maskedPlaceholder) {
          key = ed.savedApiKey;
        }
        map[id] = AgentProviderConfig(
          id: id,
          apiKey: key,
          baseUrl: ed.baseUrlController.text.trim(),
          model: ed.modelController.text.trim(),
        );
      }
      // 若选中的提供商无 Key，自动取消选择
      AgentProviderId? sel = _selected;
      if (sel != null) {
        final k = map[sel]?.apiKey ?? '';
        if (k.isEmpty || !sel.supportsChatRelay) sel = null;
      }
      await AgentConfigService.saveAll(map, selected: sel);

      var asrToken = _asrTokenController.text.trim();
      if (asrToken.isEmpty || asrToken == _masked) {
        asrToken = _asrSavedToken;
      }
      final asr = AsrClientConfig(
        enabled: _asrEnabled,
        appId: _asrAppIdController.text.trim(),
        accessToken: asrToken,
        resourceId: _asrResourceController.text.trim().isEmpty
            ? AsrClientDefaults.resourceId
            : _asrResourceController.text.trim(),
      );
      await AgentConfigService.saveAsrConfig(asr);

      await _load();
      if (mounted) {
        final asrHint = asr.isUsable
            ? '；语音 ASR 已启用'
            : (_asrEnabled ? '；语音 ASR 已勾选但凭据不完整' : '');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              sel == null
                  ? '已保存（未选择对话模型，将使用服务端默认）$asrHint'
                  : '已保存，当前对话：${sel.displayName}$asrHint',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _selectProvider(AgentProviderId? id) {
    setState(() => _selected = id);
  }

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
        title: const Text('智能体配置'),
        actions: [
          TextButton(
            onPressed: _loading || _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('保存'),
          ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          const FrostedBackground(),
          Positioned.fill(
            top: MediaQuery.of(context).padding.top + kToolbarHeight + 8,
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : ListView(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
                    children: [
                      Text(
                        '可同时填写多家提供商的 Key，但同一时间只能选择一种方式用于助理调用。'
                        '后端在线时优先经服务端（可保留日程/思维导图 Skills）；后端连不上时自动直连所选模型。',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 12),
                      _capabilityNote(context),
                      const SizedBox(height: 8),
                      RadioListTile<AgentProviderId?>(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: Text(
                          '不使用自定义 API（服务端默认）',
                          style: theme.textTheme.bodyMedium,
                        ),
                        value: null,
                        groupValue: _selected,
                        onChanged: _selectProvider,
                      ),
                      const SizedBox(height: 8),
                      _buildProviderCard(
                        context,
                        id: AgentProviderId.volcanoArk,
                        title: '火山方舟',
                        description:
                            '火山引擎 Ark「快捷 API 接入」。'
                            'Key 只填 ark-… 本身；Base URL 勿带 /chat/completions。',
                        showBaseUrl: true,
                        showModel: true,
                        apiKeyHint: VolcanoArkDefaults.apiKeyHint,
                        baseUrlHint: VolcanoArkDefaults.baseUrl,
                        modelHint: VolcanoArkDefaults.exampleModel,
                      ),
                      const SizedBox(height: 12),
                      _buildProviderCard(
                        context,
                        id: AgentProviderId.openaiCompatible,
                        title: 'OpenAI 兼容',
                        description:
                            '适用于 Kimi/Moonshot、OpenAI、DeepSeek 等。'
                            'Kimi 填 Moonshot Base URL 与模型名。',
                        showBaseUrl: true,
                        showModel: true,
                        apiKeyHint: 'sk-…（Moonshot/Kimi 控制台 Key）',
                        baseUrlHint: 'https://api.moonshot.cn/v1',
                        modelHint: 'kimi-k2.5 或 moonshot-v1-8k',
                      ),
                      const SizedBox(height: 12),
                      _buildProviderCard(
                        context,
                        id: AgentProviderId.anthropic,
                        title: 'Anthropic',
                        description: '可本地保存；当前对话链路暂未打通，无法选为调用方式。',
                        showBaseUrl: true,
                        showModel: false,
                        apiKeyHint: 'sk-ant-…',
                        baseUrlHint: 'https://api.anthropic.com',
                        selectable: false,
                      ),
                      const SizedBox(height: 12),
                      _buildProviderCard(
                        context,
                        id: AgentProviderId.google,
                        title: 'Google',
                        description: '可本地保存；当前对话链路暂未打通，无法选为调用方式。',
                        showBaseUrl: false,
                        showModel: false,
                        apiKeyHint: 'AIza…',
                        selectable: false,
                      ),
                      const SizedBox(height: 16),
                      _buildAsrCard(context),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _capabilityNote(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return AppGlassStyles.section(
      context,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '能力说明',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '· 文本对话：选择火山/OpenAI 兼容后可用\n'
            '· Skills（日程/思维导图）：需登录且后端在线，由希比助手调用\n'
            '· 语音输入：在下方配置豆包 ASR 并启用；App 直连火山识别\n'
            '· 附件：对话气泡可预览并点击打开本地文件',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAsrCard(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return AppGlassStyles.section(
      context,
      padding: const EdgeInsets.fromLTRB(12, 10, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.mic_rounded, size: 20, color: colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '语音识别（ASR）',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (_asrEnabled &&
                  _asrAppIdController.text.trim().isNotEmpty &&
                  (_asrSavedToken.isNotEmpty ||
                      (_asrTokenController.text.trim().isNotEmpty &&
                          _asrTokenController.text != _masked)))
                Text(
                  '已启用',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '火山引擎「豆包大模型流式语音识别」。启用后，助理输入栏麦克风可用；'
            'App 直连 OpenSpeech（不经 HIBI 后端）。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('启用语音输入'),
            subtitle: Text(
              _asrEnabled
                  ? '已开启：需填写 APP ID 与 Access Token'
                  : '关闭时不可用语音输入',
              style: theme.textTheme.labelSmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            value: _asrEnabled,
            onChanged: (v) => setState(() => _asrEnabled = v),
          ),
          TextField(
            controller: _asrAppIdController,
            enabled: _asrEnabled,
            keyboardType: TextInputType.number,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: 'APP ID',
              hintText: '控制台应用 APP ID',
              filled: true,
              fillColor: AppGlassStyles.inputFill(context),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _asrTokenController,
            focusNode: _asrTokenFocus,
            enabled: _asrEnabled,
            obscureText: _asrTokenObscure,
            autocorrect: false,
            enableSuggestions: false,
            onTap: () {
              if (_asrTokenController.text == _masked) {
                _asrTokenController.clear();
                setState(() => _asrTokenEditing = true);
              }
            },
            onChanged: (_) {
              if (!_asrTokenEditing) {
                setState(() => _asrTokenEditing = true);
              }
            },
            decoration: InputDecoration(
              labelText: 'Access Token',
              hintText: _asrSavedToken.isNotEmpty && !_asrTokenEditing
                  ? '点击输入新 Token（已填写）'
                  : '控制台 Access Token（不是 Secret Key）',
              helperText: '来自豆包语音控制台，勿与方舟 ark- API Key 混用',
              filled: true,
              fillColor: AppGlassStyles.inputFill(context),
              suffixIcon: IconButton(
                tooltip: _asrTokenObscure ? '显示' : '隐藏',
                onPressed: () =>
                    setState(() => _asrTokenObscure = !_asrTokenObscure),
                icon: Icon(
                  _asrTokenObscure
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _asrResourceController,
            enabled: _asrEnabled,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: 'Resource ID',
              hintText: AsrClientDefaults.resourceId,
              helperText: '须与控制台开通的能力一致',
              filled: true,
              fillColor: AppGlassStyles.inputFill(context),
            ),
          ),
          if (_asrSavedToken.isNotEmpty) ...[
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () async {
                  final messenger = ScaffoldMessenger.of(context);
                  await AgentConfigService.saveAsrConfig(
                    AsrClientConfig(
                      enabled: false,
                      appId: _asrAppIdController.text.trim(),
                      accessToken: '',
                      resourceId: _asrResourceController.text.trim(),
                    ),
                  );
                  await _load();
                  messenger.showSnackBar(
                    const SnackBar(content: Text('已清除 ASR Access Token')),
                  );
                },
                child: const Text('清除 Token'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildProviderCard(
    BuildContext context, {
    required AgentProviderId id,
    required String title,
    required String description,
    required bool showBaseUrl,
    required bool showModel,
    String apiKeyHint = 'sk-…',
    String? baseUrlHint,
    String? modelHint,
    bool selectable = true,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final ed = _editors[id]!;
    final hasSaved = ed.savedApiKey.isNotEmpty;
    final canSelect = selectable && id.supportsChatRelay;
    final isSelected = _selected == id;

    return AppGlassStyles.section(
      context,
      padding: const EdgeInsets.fromLTRB(12, 8, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (canSelect)
                Radio<AgentProviderId?>(
                  value: id,
                  groupValue: _selected,
                  onChanged: (v) {
                    // 无 Key 时也可先选，保存时再校验；提示用户填 Key
                    _selectProvider(v);
                  },
                )
              else
                const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (isSelected)
                Text(
                  '当前选用',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                )
              else if (hasSaved)
                Text(
                  '已填写',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 12),
            child: Text(
              description,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: ed.keyController,
            focusNode: ed.keyFocusNode,
            obscureText: ed.obscureKey,
            enableInteractiveSelection: true,
            autocorrect: false,
            enableSuggestions: false,
            onTap: () {
              if (ed.keyController.text == _ProviderEditors.maskedPlaceholder) {
                ed.keyController.clear();
                setState(() => ed.keyEditing = true);
              }
            },
            onChanged: (_) {
              if (!ed.keyEditing) setState(() => ed.keyEditing = true);
            },
            decoration: InputDecoration(
              labelText: 'API Key',
              hintText: hasSaved && !ed.keyEditing
                  ? '点击此处输入新 Key（已填写）'
                  : apiKeyHint,
              helperText: id == AgentProviderId.volcanoArk
                  ? '从方舟控制台复制完整 Key；不要带 Bearer、引号或 Authorization:'
                  : '可从 curl 示例中只取密钥本体；误带 Bearer 会自动去掉',
              filled: true,
              fillColor: AppGlassStyles.inputFill(context),
              suffixIcon: IconButton(
                tooltip: ed.obscureKey ? '显示' : '隐藏',
                onPressed: () => setState(() => ed.obscureKey = !ed.obscureKey),
                icon: Icon(
                  ed.obscureKey
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
              ),
            ),
          ),
          if (hasSaved) ...[
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () async {
                  final messenger = ScaffoldMessenger.of(context);
                  final name = id.displayName;
                  await AgentConfigService.clearApiKey(id);
                  if (_selected == id) _selected = null;
                  await _load();
                  if (!mounted) return;
                  messenger.showSnackBar(
                    SnackBar(content: Text('已清除 $name API Key')),
                  );
                },
                child: const Text('清除已保存的 Key'),
              ),
            ),
          ],
          if (showBaseUrl) ...[
            const SizedBox(height: 8),
            TextField(
              controller: ed.baseUrlController,
              enableInteractiveSelection: true,
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(
                labelText: 'Base URL',
                hintText: baseUrlHint ?? 'https://api.openai.com/v1',
                helperText: id == AgentProviderId.volcanoArk
                    ? '勿带 /chat/completions'
                    : '可覆盖默认地址',
                filled: true,
                fillColor: AppGlassStyles.inputFill(context),
              ),
            ),
          ],
          if (showModel) ...[
            const SizedBox(height: 8),
            TextField(
              controller: ed.modelController,
              enableInteractiveSelection: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: '模型 / 接入点 ID',
                hintText: modelHint ?? 'gpt-4o-mini',
                helperText: id == AgentProviderId.volcanoArk
                    ? '填控制台模型 ID 或推理接入点 ep-…'
                    : null,
                filled: true,
                fillColor: AppGlassStyles.inputFill(context),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ProviderEditors {
  _ProviderEditors({
    required this.savedApiKey,
    required this.keyController,
    required this.baseUrlController,
    required this.modelController,
    required this.keyFocusNode,
  });

  static const maskedPlaceholder = '••••••••••••••••';

  bool obscureKey = true;
  bool keyEditing = false;
  final String savedApiKey;
  final TextEditingController keyController;
  final TextEditingController baseUrlController;
  final TextEditingController modelController;
  final FocusNode keyFocusNode;

  void _onKeyFocusChanged() {
    if (keyFocusNode.hasFocus &&
        keyController.text == maskedPlaceholder &&
        savedApiKey.isNotEmpty) {
      keyController.clear();
      keyEditing = true;
    }
  }

  factory _ProviderEditors.fromConfig(AgentProviderConfig cfg) {
    final hasKey = cfg.apiKey.isNotEmpty;
    final base = cfg.baseUrl.trim().isNotEmpty
        ? cfg.baseUrl
        : (cfg.id == AgentProviderId.volcanoArk
            ? VolcanoArkDefaults.baseUrl
            : '');
    final keyFocus = FocusNode();
    final editors = _ProviderEditors(
      savedApiKey: cfg.apiKey,
      keyController: TextEditingController(
        text: hasKey ? maskedPlaceholder : '',
      ),
      baseUrlController: TextEditingController(text: base),
      modelController: TextEditingController(text: cfg.model),
      keyFocusNode: keyFocus,
    );
    keyFocus.addListener(editors._onKeyFocusChanged);
    return editors;
  }

  void dispose() {
    keyFocusNode.removeListener(_onKeyFocusChanged);
    keyFocusNode.dispose();
    keyController.dispose();
    baseUrlController.dispose();
    modelController.dispose();
  }
}
