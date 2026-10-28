import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../app/app_glass_styles.dart';
import '../../app/frosted_background.dart';
import '../assistant/models/colleague_roster.dart';
import '../assistant/services/colleague_endpoint_store.dart';
import '../assistant/services/local_llama_server.dart';

/// 为每位同事单独指定接口。保存后对话记录保留，下一条消息走新接口并带上历史。
class ColleagueApiPage extends StatefulWidget {
  const ColleagueApiPage({super.key});

  @override
  State<ColleagueApiPage> createState() => _ColleagueApiPageState();
}

class _ColleagueApiPageState extends State<ColleagueApiPage> {
  bool _loading = true;
  bool _saving = false;
  final _exe = TextEditingController();
  final _modelPath = TextEditingController();
  final _port = TextEditingController(text: '${LocalLlamaDefaults.port}');
  final Map<String, _Slot> _slots = {};

  @override
  void initState() {
    super.initState();
    for (final s in ColleagueRoster.all) {
      _slots[s.id] = _Slot();
    }
    unawaited(_load());
  }

  @override
  void dispose() {
    _exe.dispose();
    _modelPath.dispose();
    _port.dispose();
    for (final s in _slots.values) {
      s.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final paths = await LocalLlamaServer.loadPaths();
    final all = await ColleagueEndpointStore.loadAll();
    if (!mounted) return;
    _exe.text = paths.exePath;
    _modelPath.text = paths.modelPath;
    _port.text = '${paths.port}';
    for (final spec in ColleagueRoster.all) {
      final ep = all[spec.id] ?? const ColleagueEndpoint();
      final slot = _slots[spec.id]!;
      slot.mode = ep.mode;
      slot.apiKey.text = ep.apiKey;
      slot.baseUrl.text = ep.baseUrl;
      slot.model.text = ep.model;
    }
    setState(() => _loading = false);
  }

  Future<void> _pickFile(TextEditingController target, {List<String>? extensions}) async {
    final result = await FilePicker.platform.pickFiles(
      type: extensions == null ? FileType.any : FileType.custom,
      allowedExtensions: extensions,
    );
    final path = result?.files.single.path;
    if (path == null || path.isEmpty || !mounted) return;
    setState(() => target.text = path);
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final port = int.tryParse(_port.text.trim()) ?? LocalLlamaDefaults.port;
      await LocalLlamaServer.savePaths(
        LocalLlamaPaths(
          exePath: _exe.text.trim(),
          modelPath: _modelPath.text.trim(),
          port: port <= 0 ? LocalLlamaDefaults.port : port,
        ),
      );
      final map = <String, ColleagueEndpoint>{};
      var anyLocal = false;
      for (final spec in ColleagueRoster.all) {
        final slot = _slots[spec.id]!;
        if (slot.mode == ColleagueApiMode.local) anyLocal = true;
        map[spec.id] = ColleagueEndpoint(
          mode: slot.mode,
          apiKey: slot.apiKey.text.trim(),
          baseUrl: slot.baseUrl.text.trim(),
          model: slot.model.text.trim(),
        );
      }
      await ColleagueEndpointStore.saveAll(map);
      if (anyLocal) {
        unawaited(LocalLlamaServer.ensureRunning().catchError((Object _) {}));
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('已保存。各同事的对话都还在，下次发送会带上已有记录，并改用新接口。'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _probe() async {
    final port = int.tryParse(_port.text.trim()) ?? LocalLlamaDefaults.port;
    await LocalLlamaServer.savePaths(
      LocalLlamaPaths(
        exePath: _exe.text.trim(),
        modelPath: _modelPath.text.trim(),
        port: port <= 0 ? LocalLlamaDefaults.port : port,
      ),
    );
    try {
      await LocalLlamaServer.ensureRunning();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(LocalLlamaServer.status.value)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('同事接口'),
        actions: [
          TextButton(
            onPressed: _saving || _loading ? null : _save,
            child: Text(_saving ? '保存中' : '保存'),
          ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          const FrostedBackground(),
          if (_loading)
            const Center(child: CircularProgressIndicator())
          else
            ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: [
                AppGlassStyles.section(
                  context,
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('本地 Qwen', style: theme.textTheme.titleSmall),
                      const SizedBox(height: 6),
                      Text(
                        '默认全体同事走本机 llama-server。留空则自动查找 ${LocalLlamaDefaults.exeRelative} 与 ${LocalLlamaDefaults.modelRelative}。',
                        style: theme.textTheme.bodySmall,
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _exe,
                        decoration: InputDecoration(
                          labelText: 'llama-server.exe',
                          suffixIcon: IconButton(
                            tooltip: '浏览',
                            onPressed: () => _pickFile(_exe),
                            icon: const Icon(Icons.folder_open),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _modelPath,
                        decoration: InputDecoration(
                          labelText: '模型 .gguf',
                          suffixIcon: IconButton(
                            tooltip: '浏览',
                            onPressed: () => _pickFile(_modelPath, extensions: const ['gguf']),
                            icon: const Icon(Icons.folder_open),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _port,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: '端口'),
                      ),
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: OutlinedButton(
                          onPressed: _probe,
                          child: const Text('启动 / 检测本地模型'),
                        ),
                      ),
                      ValueListenableBuilder<String>(
                        valueListenable: LocalLlamaServer.status,
                        builder: (context, value, _) => Text(
                          value,
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                for (final spec in ColleagueRoster.all) ...[
                  _colleagueCard(theme, spec),
                  const SizedBox(height: 10),
                ],
              ],
            ),
        ],
      ),
    );
  }

  Widget _colleagueCard(ThemeData theme, StaffSpec spec) {
    final slot = _slots[spec.id]!;
    return AppGlassStyles.section(
      context,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(spec.name, style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ChoiceChip(
                label: const Text('本地 Qwen'),
                selected: slot.mode == ColleagueApiMode.local,
                onSelected: (_) => setState(() => slot.mode = ColleagueApiMode.local),
              ),
              ChoiceChip(
                label: const Text('跟随全局'),
                selected: slot.mode == ColleagueApiMode.inherit,
                onSelected: (_) => setState(() => slot.mode = ColleagueApiMode.inherit),
              ),
              ChoiceChip(
                label: const Text('单独指定'),
                selected: slot.mode == ColleagueApiMode.custom,
                onSelected: (_) => setState(() => slot.mode = ColleagueApiMode.custom),
              ),
            ],
          ),
          if (slot.mode == ColleagueApiMode.custom) ...[
            const SizedBox(height: 8),
            TextField(
              controller: slot.apiKey,
              decoration: const InputDecoration(labelText: 'API Key'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: slot.baseUrl,
              decoration: const InputDecoration(
                labelText: 'Base URL',
                hintText: 'https://host/v1',
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: slot.model,
              decoration: const InputDecoration(labelText: '模型名'),
            ),
          ],
          if (slot.mode == ColleagueApiMode.inherit)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '使用「智能体配置」里当前选中的火山或 OpenAI 兼容接口。',
                style: theme.textTheme.bodySmall,
              ),
            ),
        ],
      ),
    );
  }
}

class _Slot {
  ColleagueApiMode mode = ColleagueApiMode.local;
  final apiKey = TextEditingController();
  final baseUrl = TextEditingController();
  final model = TextEditingController();

  void dispose() {
    apiKey.dispose();
    baseUrl.dispose();
    model.dispose();
  }
}
