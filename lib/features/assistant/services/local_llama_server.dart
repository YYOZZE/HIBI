import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// 本机 llama-server。全体同事默认共用这一条 OpenAI 兼容接口。
class LocalLlamaDefaults {
  static const baseUrl = 'http://127.0.0.1:11434/v1';
  static const modelAlias = 'qwen2.5-3b';
  static const apiKey = 'local';
  static const port = 11434;
  static const exeRelative = 'qwen-run/llama/bin/llama-server.exe';
  static const modelRelative =
      'models/Qwen2.5-3B-Instruct-GGUF/qwen2.5-3b-instruct-q4_k_m.gguf';
}

class LocalLlamaPaths {
  const LocalLlamaPaths({
    this.exePath = '',
    this.modelPath = '',
    this.port = LocalLlamaDefaults.port,
  });

  final String exePath;
  final String modelPath;
  final int port;

  String get baseUrl => 'http://127.0.0.1:$port/v1';
}

class LocalLlamaServer {
  LocalLlamaServer._();

  static const _prefsKey = 'hibi_local_llama_paths_v1';

  static final ValueNotifier<String> status = ValueNotifier<String>('未启动');
  static Future<void>? _inflight;
  static Process? _owned;

  static Future<LocalLlamaPaths> loadPaths() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null || raw.isEmpty) return const LocalLlamaPaths();
    try {
      final map = jsonDecode(raw);
      if (map is Map) {
        final port = int.tryParse('${map['port'] ?? ''}') ?? LocalLlamaDefaults.port;
        return LocalLlamaPaths(
          exePath: (map['exe'] ?? '').toString(),
          modelPath: (map['model'] ?? '').toString(),
          port: port <= 0 ? LocalLlamaDefaults.port : port,
        );
      }
    } catch (_) {}
    return const LocalLlamaPaths();
  }

  static Future<void> savePaths(LocalLlamaPaths paths) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      jsonEncode({
        'exe': paths.exePath.trim(),
        'model': paths.modelPath.trim(),
        'port': paths.port,
      }),
    );
  }

  static Future<void> ensureRunning() {
    final current = _inflight;
    if (current != null) return current;
    final fut = _ensure();
    _inflight = fut;
    return fut.whenComplete(() {
      if (identical(_inflight, fut)) _inflight = null;
    });
  }

  static Future<void> _ensure() async {
    final paths = await loadPaths();
    if (await _isReady(paths.port)) {
      status.value = '本地模型已在 ${paths.baseUrl}';
      return;
    }
    final existing = _owned;
    if (existing != null && await _stillRunning(existing)) {
      await _waitReady(paths.port, existing, null);
      return;
    }
    _owned = null;

    final exe = _resolveExe(paths.exePath);
    final model = _resolveModel(paths.modelPath);
    if (exe == null || model == null) {
      const msg = '未找到本地模型。请将 llama-server 放在 ${LocalLlamaDefaults.exeRelative}，'
          '权重放在 ${LocalLlamaDefaults.modelRelative}（相对项目根目录），'
          '或在「设置 → 同事接口」填写绝对路径。';
      status.value = msg;
      throw Exception(msg);
    }

    status.value = '正在启动本地模型…';
    final err = StringBuffer();
    final proc = await _start(exe, model, paths.port, err: err);
    _owned = proc;
    await _waitReady(paths.port, proc, err);
  }

  static Future<Process> _start(
    String exe,
    String model,
    int port, {
    required StringBuffer err,
  }) async {
    // 与「启动本地模型.bat」一致：CPU、别名 qwen2.5-3b、端口 11434。
    final args = <String>[
      '-m',
      model,
      '--host',
      '127.0.0.1',
      '--port',
      '$port',
      '-c',
      '8192',
      '-t',
      '8',
      '-ngl',
      '0',
      '--alias',
      LocalLlamaDefaults.modelAlias,
    ];
    final proc = await Process.start(
      exe,
      args,
      workingDirectory: File(exe).parent.path,
      mode: ProcessStartMode.normal,
    );
    proc.stderr.transform(utf8.decoder).listen((s) {
      if (err.length < 4000) err.write(s);
      debugPrint('[llama] $s');
    });
    proc.stdout.transform(utf8.decoder).listen((s) => debugPrint('[llama] $s'));
    return proc;
  }

  static Future<void> _waitReady(int port, Process proc, StringBuffer? err) async {
    final deadline = DateTime.now().add(const Duration(seconds: 90));
    while (DateTime.now().isBefore(deadline)) {
      if (await _isReady(port)) {
        status.value = '本地模型已就绪';
        return;
      }
      if (!await _stillRunning(proc)) {
        final tail = err?.toString().trim() ?? '';
        final msg = tail.isEmpty ? 'llama-server 已退出' : 'llama-server 已退出：$tail';
        status.value = msg;
        _owned = null;
        throw Exception(msg);
      }
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    const msg = '本地模型启动超时。请确认显卡/内存足够，或稍后在同事接口里重试。';
    status.value = msg;
    throw Exception(msg);
  }

  static Future<bool> _stillRunning(Process proc) async {
    final code = await proc.exitCode.timeout(
      const Duration(milliseconds: 80),
      onTimeout: () => -1,
    );
    return code < 0;
  }

  static Future<bool> _isReady(int port) async {
    final base = 'http://127.0.0.1:$port';
    try {
      final health = await http
          .get(Uri.parse('$base/health'))
          .timeout(const Duration(seconds: 2));
      if (health.statusCode == 200) return true;
    } catch (_) {}
    try {
      final models = await http
          .get(Uri.parse('$base/v1/models'))
          .timeout(const Duration(seconds: 2));
      return models.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  static String? _resolveExe(String override) {
    final custom = override.trim();
    if (custom.isNotEmpty && File(custom).existsSync()) return custom;
    final root = _findProjectRoot();
    if (root == null) return null;
    final file = File(_join(root, LocalLlamaDefaults.exeRelative));
    return file.existsSync() ? file.path : null;
  }

  static String? _resolveModel(String override) {
    final custom = override.trim();
    if (custom.isNotEmpty && File(custom).existsSync()) return custom;
    final root = _findProjectRoot();
    if (root == null) return null;
    final file = File(_join(root, LocalLlamaDefaults.modelRelative));
    return file.existsSync() ? file.path : null;
  }

  static String? _findProjectRoot() {
    final home = Platform.environment['USERPROFILE'] ?? '';
    final starts = <String>[
      if (home.isNotEmpty) '$home\\Desktop\\微-豆studio\\AI_HUMEN',
      Directory.current.path,
      File(Platform.resolvedExecutable).parent.path,
    ];
    for (final start in starts) {
      var dir = Directory(start);
      for (var i = 0; i < 8; i++) {
        final exe = File(_join(dir.path, LocalLlamaDefaults.exeRelative));
        final model = File(_join(dir.path, LocalLlamaDefaults.modelRelative));
        if (exe.existsSync() || model.existsSync()) return dir.path;
        final parent = dir.parent;
        if (parent.path == dir.path) break;
        dir = parent;
      }
    }
    return null;
  }

  static String _join(String root, String relative) {
    final parts = relative.split('/');
    return ([root, ...parts]).join(Platform.pathSeparator);
  }
}
