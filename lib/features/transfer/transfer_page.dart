import 'dart:async';
import 'dart:convert';
import 'dart:io'
    show
        Directory,
        File,
        Platform,
        Process,
        FileSystemEntity,
        FileSystemEntityType;

import 'package:app_settings/app_settings.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/app_glass_styles.dart';
import 'models/transfer_device.dart';
import 'service/lan_discovery_service.dart';
import 'service/transfer_client.dart';
import 'service/transfer_server.dart';
import 'transfer_file_actions.dart';
import 'transfer_port_config.dart';

/// 单条传输记录（发送或接收文件/文本）
class TransferRecord {
  TransferRecord({
    required this.type,
    required this.targetName,
    this.fileName,
    this.textPreview,
    this.localPath,
    required this.at,
    this.isReceive = false,
  });
  final String type; // 'file' | 'text'
  final String targetName;
  final String? fileName;
  final String? textPreview;

  /// 本地文件路径（接收文件/发送源文件）
  final String? localPath;
  final DateTime at;

  /// true 表示本机收到，false 表示本机发出
  final bool isReceive;
}

/// 文件传输页：设备发现、发送文件/文本、接收、传输记录（与 LANDrop 一致，希比样式）
class TransferPage extends StatefulWidget {
  const TransferPage({super.key});

  @override
  State<TransferPage> createState() => _TransferPageState();
}

class _TransferPageState extends State<TransferPage> {
  late final LanDiscoveryService _discovery;
  final TransferServer _server = TransferServer();
  final List<TransferDevice> _devices = [];
  final List<PendingReceive> _pending = [];
  final Set<PendingReceive> _receiving = <PendingReceive>{};
  bool _incomingDialogVisible = false;
  StreamSubscription<TransferDevice>? _devSub;
  StreamSubscription<PendingReceive>? _pendingSub;
  StreamSubscription<Object>? _discoveryErrorSub;
  StreamSubscription<String>? _saveErrorSub;
  final Map<PendingReceive, StreamSubscription<double>> _receiveProgressSubs =
      <PendingReceive, StreamSubscription<double>>{};
  final Map<PendingReceive, double> _receiveProgress =
      <PendingReceive, double>{};
  Timer? _deviceCleanupTimer;
  bool _sending = false;
  double _sendProgress = 0;
  String? _sendError;
  int _sendTabIndex = 0; // 0=发送文件 1=发送文本
  final TextEditingController _textController = TextEditingController();
  final List<String> _queuedSendPaths = [];
  static const String _queuedSendPathsKey = 'transfer_queued_send_paths_v1';
  final List<TransferRecord> _transferHistory = []; // 传输记录
  static const int _maxHistory = 50;
  Object? _discoveryError; // 发现服务启动失败（如端口被占、防火墙）
  bool _draggingFiles = false;
  int _configuredReceivePort = TransferPortConfig.autoReceivePort;
  int _configuredDiscoveryPort = TransferPortConfig.defaultDiscoveryPort;
  List<int> _discoveryFallbackPorts =
      List<int>.from(TransferPortConfig.defaultDiscoveryFallbacks);

  List<int> get _allDiscoveryCompatibilityPorts => <int>{
        ..._discoveryFallbackPorts,
        ...LanDiscoveryService.discoveryPortFallbacks,
        ...LanDiscoveryService.legacyDiscoveryPorts,
      }.toList()
        ..sort();

  String get _firewallRuleCommand {
    return _allDiscoveryCompatibilityPorts
        .map((p) =>
            'netsh advfirewall firewall add rule name="Hibi-UDP-$p-In" dir=in action=allow protocol=udp localport=$p & '
            'netsh advfirewall firewall add rule name="Hibi-UDP-$p-Out" dir=out action=allow protocol=udp localport=$p')
        .join(' & ');
  }

  /// Windows 完整一键修复脚本：允许 UDP 发现端口入出站 + 允许本程序通过防火墙（专用网络）+ 诊断提示
  String get _fullFirewallScript {
    final exe = Platform.resolvedExecutable;
    final ports = _allDiscoveryCompatibilityPorts;
    final rules = <String>[
      '@echo off',
      'chcp 65001 >nul',
      ':: 希比传输 - 一键允许防火墙（请以管理员身份运行 CMD 后粘贴整段执行）',
    ];
    for (final port in ports) {
      rules.add(
          'netsh advfirewall firewall add rule name="Hibi-UDP-$port-In" dir=in action=allow protocol=udp localport=$port');
      rules.add(
          'netsh advfirewall firewall add rule name="Hibi-UDP-$port-Out" dir=out action=allow protocol=udp localport=$port');
    }
    rules.addAll([
      'netsh advfirewall firewall add rule name="Hibi-Transfer-App-In" dir=in action=allow program="$exe" profile=private',
      'netsh advfirewall firewall add rule name="Hibi-Transfer-App-Out" dir=out action=allow program="$exe" profile=private',
      'echo.',
      'echo 已完成。请关闭本窗口后点击应用内「重试发现」或重启应用。',
      'echo 若仍无法发现设备，请以管理员执行：netsh int ipv4 show excludedportrange protocol=udp',
      'pause',
    ]);
    return rules.join('\r\n');
  }

  @override
  void initState() {
    super.initState();
    final isIPad =
        Platform.isIOS && MediaQuery.of(context).size.shortestSide >= 600;
    _discovery =
        LanDiscoveryService(platformTagOverride: isIPad ? 'ipad' : null);
    _devSub = _discovery.devices.listen(
      (d) {
        if (mounted) {
          setState(() {
            final i = d.deviceId != null && d.deviceId!.isNotEmpty
                ? _devices.indexWhere((e) => e.deviceId == d.deviceId)
                : _devices.indexWhere(
                    (e) => e.address == d.address && e.port == d.port);
            if (i >= 0)
              _devices[i] = d;
            else
              _devices.add(d);
          });
        }
      },
      onError: (e, _) {
        if (mounted) setState(() => _discoveryError = e);
      },
    );
    _pendingSub = _server.pendingReceives.listen((p) {
      if (!mounted) return;
      setState(() {
        _pending.add(p);
        _receiveProgress[p] = p.currentProgress;
      });
      _receiveProgressSubs[p] = p.progress.listen(
        (progress) {
          if (mounted && _pending.contains(p)) {
            setState(() => _receiveProgress[p] = progress);
          }
        },
        onError: (Object _) {
          if (mounted && _pending.contains(p)) {
            _removePendingReceiveFromUi(p);
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('发送方已取消或连接已断开')),
            );
          }
        },
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_showNextIncomingTransferDialog());
      });
    });
    _saveErrorSub = _server.saveErrors.listen((msg) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('$msg\n请到 我的 → 设置 → 文件传输默认保存路径 更换为有写入权限的文件夹。'),
            duration: const Duration(seconds: 5),
          ),
        );
      }
    });
    _discoveryErrorSub = _discovery.errors.listen((e) {
      if (mounted) setState(() => _discoveryError = e);
    });
    _deviceCleanupTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted || _devices.isEmpty) return;
      // Android/Windows 在省电或网络切换时可能短暂停止 UDP 广播。
      // 保留 45 秒可避免设备列表每隔几秒闪现/消失，同时仍会清理真正离线设备。
      final cutoff = DateTime.now().subtract(const Duration(seconds: 45));
      final hasExpired =
          _devices.any((device) => device.lastSeen.isBefore(cutoff));
      if (hasExpired) {
        setState(() =>
            _devices.removeWhere((device) => device.lastSeen.isBefore(cutoff)));
      }
    });
    _loadQueuedSendPaths();
    _loadPortConfig().then((_) => _startServices());
  }

  Future<void> _showNextIncomingTransferDialog() async {
    if (!mounted || _incomingDialogVisible) return;
    final waiting = _pending.where((item) => !_receiving.contains(item));
    if (waiting.isEmpty) return;
    final pending = waiting.first;
    _incomingDialogVisible = true;
    try {
      final accepted = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        useRootNavigator: true,
        builder: (dialogContext) {
          final theme = Theme.of(dialogContext);
          final colorScheme = theme.colorScheme;
          final fileSummary = pending.files
              .take(4)
              .map((file) =>
                  '${file['filename']}（${_formatSize((file['size'] as num?)?.toInt() ?? 0)}）')
              .join('\n');
          return AlertDialog(
            icon: Icon(
              pending.isText
                  ? Icons.text_snippet_outlined
                  : Icons.file_download_outlined,
              color: colorScheme.primary,
            ),
            title: const Text('收到传输请求'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                    '${pending.deviceName} 请求发送${pending.isText ? '文本' : '文件'}'),
                const SizedBox(height: 12),
                if (pending.isText)
                  Text(
                    pending.text!.length > 240
                        ? '${pending.text!.substring(0, 240)}…'
                        : pending.text!,
                    maxLines: 6,
                    overflow: TextOverflow.ellipsis,
                  )
                else
                  Text(
                    pending.files.length > 4
                        ? '$fileSummary\n等 ${pending.files.length} 个文件，共 ${_formatSize(pending.totalSize)}'
                        : fileSummary,
                  ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('拒绝'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('确定接收'),
              ),
            ],
          );
        },
      );
      if (accepted == true) {
        // 用户确认后立即关闭弹窗并启动接收；后续请求可继续逐个确认，
        // 不会被一个大文件的传输时长阻塞到发送端超时。
        unawaited(_acceptPendingReceive(pending));
      } else {
        await _rejectPendingReceive(pending);
      }
    } finally {
      _incomingDialogVisible = false;
      if (mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) unawaited(_showNextIncomingTransferDialog());
        });
      }
    }
  }

  Future<void> _rejectPendingReceive(PendingReceive pending) async {
    if (_receiving.contains(pending)) return;
    try {
      await pending.reject();
    } catch (_) {
      // 对方可能已取消或网络已断开，仍应从本地请求列表移除。
    }
    _removePendingReceiveFromUi(pending);
  }

  Future<void> _acceptPendingReceive(PendingReceive pending) async {
    if (!mounted || _receiving.contains(pending)) return;
    setState(() => _receiving.add(pending));
    final deviceName = pending.deviceName;
    final fileName = pending.files.isNotEmpty
        ? pending.files.first['filename']?.toString()
        : null;
    try {
      if (pending.isText && pending.text != null) {
        await Clipboard.setData(ClipboardData(text: pending.text!));
      }
      final localPath = await pending.accept();
      if (!mounted) return;
      setState(() {
        if (pending.isText && pending.text != null) {
          final preview = pending.text!.length > 50
              ? '${pending.text!.substring(0, 50)}…'
              : pending.text!;
          _transferHistory.insert(
            0,
            TransferRecord(
              type: 'text',
              targetName: deviceName,
              textPreview: preview,
              at: DateTime.now(),
              isReceive: true,
            ),
          );
        } else if (fileName != null && localPath != null) {
          _transferHistory.insert(
            0,
            TransferRecord(
              type: 'file',
              targetName: deviceName,
              fileName: fileName,
              localPath: localPath,
              at: DateTime.now(),
              isReceive: true,
            ),
          );
        }
      });
      _removePendingReceiveFromUi(pending);
      if (localPath == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('接收失败，请确认保存目录可写并重试')),
        );
      } else if (pending.isText) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('文本已接收并复制到剪贴板')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已保存：$fileName'),
            action: SnackBarAction(
              label: '打开',
              onPressed: () => TransferFileActions.openFile(context, localPath),
            ),
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        _removePendingReceiveFromUi(pending);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('接收失败：$error')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _receiving.remove(pending));
      } else {
        _receiving.remove(pending);
      }
    }
  }

  void _removePendingReceiveFromUi(PendingReceive pending) {
    final subscription = _receiveProgressSubs.remove(pending);
    if (subscription != null) unawaited(subscription.cancel());
    if (!mounted) return;
    setState(() {
      _pending.remove(pending);
      _receiveProgress.remove(pending);
      _receiving.remove(pending);
    });
  }

  Future<void> _loadQueuedSendPaths() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList(_queuedSendPathsKey) ?? const [];
    if (!mounted) return;
    setState(() {
      _queuedSendPaths
        ..clear()
        ..addAll(saved.where((path) => path.isNotEmpty));
    });
  }

  Future<void> _persistQueuedSendPaths() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_queuedSendPathsKey, _queuedSendPaths);
  }

  Future<void> _addQueuedSendPaths(List<String> paths) async {
    if (!mounted) return;
    setState(() {
      for (final path in paths) {
        if (path.isNotEmpty && !_queuedSendPaths.contains(path)) {
          _queuedSendPaths.add(path);
        }
      }
    });
    await _persistQueuedSendPaths();
  }

  Future<void> _removeQueuedSendPath(String path) async {
    setState(() => _queuedSendPaths.remove(path));
    await _persistQueuedSendPaths();
  }

  Future<void> _sendQueuedFiles() async {
    final existing =
        _queuedSendPaths.where((path) => File(path).existsSync()).toList();
    final missingCount = _queuedSendPaths.length - existing.length;
    if (existing.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('列表中的源文件均已移动或删除，请移除后重新选择')),
      );
      return;
    }
    if (missingCount > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已跳过 $missingCount 个不存在的源文件')),
      );
    }
    await _sendPaths(existing);
  }

  Future<void> _loadPortConfig() async {
    _configuredReceivePort = await TransferPortConfig.getReceivePort();
    _configuredDiscoveryPort = await TransferPortConfig.getDiscoveryPort();
    _discoveryFallbackPorts = await TransferPortConfig.getDiscoveryFallbacks();
  }

  Future<void> _startServices() async {
    try {
      await _server.start(port: _configuredReceivePort);
      final port = _server.port ?? 0;
      await _discovery.start(port, fallbackPorts: _discoveryFallbackPorts);
      if (mounted) setState(() => _discoveryError = null);
    } catch (e) {
      if (mounted) setState(() => _discoveryError = e);
    }
  }

  Future<void> _restartServicesWithNewPorts({
    required int receivePort,
    required int discoveryPort,
  }) async {
    await TransferPortConfig.setReceivePort(receivePort);
    await TransferPortConfig.setDiscoveryPort(discoveryPort);
    _configuredReceivePort = receivePort;
    _configuredDiscoveryPort = discoveryPort;
    _discoveryFallbackPorts = await TransferPortConfig.getDiscoveryFallbacks();
    _server.stop();
    _discovery.stop();
    setState(() {
      _devices.clear();
      _discoveryError = null;
    });
    await _startServices();
  }

  Future<void> _showPortSettingsDialog() async {
    final receiveCtrl = TextEditingController(
      text: _configuredReceivePort <= 0 ? '' : '$_configuredReceivePort',
    );
    final discoveryCtrl =
        TextEditingController(text: '$_configuredDiscoveryPort');
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('端口设置'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: receiveCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: '接收端口',
                  hintText: '留空表示自动分配',
                  helperText: '对方通过此 TCP 端口向你发送文件',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: discoveryCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: '发现端口',
                  helperText: '用于局域网自动发现附近设备（UDP）',
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '修改端口后将重启传输服务。两端发现端口不一致时，可用「通过 IP 发送」。',
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('应用'),
          ),
        ],
      ),
    );
    if (result != true || !mounted) {
      receiveCtrl.dispose();
      discoveryCtrl.dispose();
      return;
    }

    final receiveRaw = receiveCtrl.text.trim();
    final discoveryRaw = discoveryCtrl.text.trim();
    receiveCtrl.dispose();
    discoveryCtrl.dispose();

    final receivePort = receiveRaw.isEmpty
        ? TransferPortConfig.autoReceivePort
        : (int.tryParse(receiveRaw) ?? -1);
    final discoveryPort = int.tryParse(discoveryRaw) ?? -1;

    if (!TransferPortConfig.isValidReceivePort(receivePort)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('接收端口无效，请留空（自动）或填写 1–65535')),
        );
      }
      return;
    }
    if (!TransferPortConfig.isValidPort(discoveryPort)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('发现端口无效，请填写 1–65535')),
        );
      }
      return;
    }

    try {
      await _restartServicesWithNewPorts(
        receivePort: receivePort,
        discoveryPort: discoveryPort,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('端口已更新，传输服务已重启')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('端口应用失败：$e')),
        );
      }
    }
  }

  /// 是否像权限/防火墙类错误（Socket 被禁止等）
  bool _isPermissionOrFirewallError(Object e) {
    final s = e.toString();
    return s.contains('10013') ||
        s.contains('forbidden') ||
        s.contains('access permissions') ||
        s.contains('SocketException') ||
        s.contains('Permission denied');
  }

  /// 打开当前平台网络/防火墙相关设置页
  Future<void> _openNetworkPermissionSettings() async {
    if (Platform.isWindows) {
      try {
        final uri = Uri.parse('ms-settings:windowsdefender-firewall');
        if (await canLaunchUrl(uri)) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
          return;
        }
      } catch (_) {}
      try {
        await Process.run(
          'cmd',
          ['/c', 'start', 'ms-settings:windowsdefender-firewall'],
          runInShell: true,
        );
      } catch (_) {}
    } else if (Platform.isAndroid || Platform.isIOS) {
      try {
        await AppSettings.openAppSettings();
      } catch (_) {}
    }
  }

  /// 重新尝试启动发现服务（一键执行添加规则后可不重启应用，点此重试）
  Future<void> _retryDiscovery() async {
    _discovery.stop();
    setState(() => _discoveryError = null);
    await _discovery.start(_server.port ?? 0,
        fallbackPorts: _discoveryFallbackPorts);
    await Future.delayed(const Duration(milliseconds: 200));
    if (mounted) setState(() {});
  }

  /// 检查发现端口是否在系统保留端口范围内（需管理员 CMD 才能看到完整结果，本处仅尝试运行）
  Future<void> _showExcludedPortDiagnostic() async {
    if (!Platform.isWindows) return;
    try {
      final result = await Process.run(
        'netsh',
        ['int', 'ipv4', 'show', 'excludedportrange', 'protocol=udp'],
        runInShell: false,
      );
      final out = (result.stdout as String?) ?? '';
      final err = (result.stderr as String?) ?? '';
      final ports = _discoveryFallbackPorts;
      final inRangePorts = <int>[];
      for (final m in RegExp(r'(\d+)\s*-\s*(\d+)').allMatches(out)) {
        final low = int.tryParse(m.group(1) ?? '') ?? 0;
        final high = int.tryParse(m.group(2) ?? '') ?? 0;
        for (final port in ports) {
          if (port >= low && port <= high) inRangePorts.add(port);
        }
      }
      if (!mounted) return;
      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('UDP 保留端口范围'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (result.exitCode != 0)
                  Text(
                      '未以管理员运行可能无法查看。请以管理员打开 CMD 执行：\nnetsh int ipv4 show excludedportrange protocol=udp',
                      style: Theme.of(ctx).textTheme.bodySmall),
                if (result.exitCode == 0) ...[
                  Text(
                    inRangePorts.isNotEmpty
                        ? '端口 ${inRangePorts.join('、')} 落在系统保留范围内，应用会尝试使用其他端口。若全部被保留，请重启电脑或关闭 Hyper-V/WSL 后再试。'
                        : '发现端口 ${ports.join('、')} 均未在保留范围内。若仍失败，请确认已「一键执行」并点击「重试发现」。',
                    style: Theme.of(ctx).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 12),
                  SelectableText(
                    out.trim().isEmpty
                        ? (err.trim().isEmpty ? '（无输出）' : err.trim())
                        : out.trim(),
                    style: Theme.of(ctx)
                        .textTheme
                        .labelSmall
                        ?.copyWith(fontFamily: 'Consolas'),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text(
                  '无法运行诊断，请以管理员打开 CMD 执行：netsh int ipv4 show excludedportrange protocol=udp')),
        );
      }
    }
  }

  /// 将防火墙脚本写入临时 bat 并以管理员权限运行（触发 UAC），添加规则后需用户重启应用
  Future<bool> _runFirewallScriptAsAdmin() async {
    if (!Platform.isWindows) return false;
    try {
      final tempDir = Directory.systemTemp;
      final batPath =
          '${tempDir.path}${Platform.pathSeparator}hibi_firewall_discovery.bat';
      final batFile = File(batPath);
      await batFile.writeAsString(_fullFirewallScript, encoding: utf8);
      final escaped = batPath.replaceAll('"', '""');
      final psCommand = 'Start-Process -FilePath "$escaped" -Verb RunAs';
      await Process.run(
        'powershell',
        ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', psCommand],
        runInShell: false,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  String get _permissionHint {
    if (Platform.isWindows) {
      return '多半是电脑防火墙拦住了。请让防火墙放行本应用（专用网络），或放行 UDP 端口 ${LanDiscoveryService.discoveryPort} 的进和出。'
          '若仍不行，用管理员打开 CMD 执行：netsh int ipv4 show excludedportrange protocol=udp，'
          '看该端口是否被系统占用；若是，重启电脑后再试。';
    }
    if (Platform.isAndroid) {
      return '请到 设置 → 应用 → 本应用 → 权限，打开网络、存储等权限。';
    }
    if (Platform.isIOS) {
      return '请到 设置 → 隐私与安全性 → 本地网络，允许本应用访问。';
    }
    return '请检查系统是否允许本应用使用网络。';
  }

  void _showDiscoveryErrorDialog(Object e) {
    if (!mounted) return;
    _discoveryDialogCopied = false;
    _discoveryDialogRunRequested = false;
    final isPermission = _isPermissionOrFirewallError(e);
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('发现服务异常'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                e.toString(),
                style: Theme.of(ctx).textTheme.bodySmall,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 12),
              Text(isPermission ? _permissionHint : '请检查网络或稍后重试。'),
              if (isPermission && Platform.isWindows) ...[
                const SizedBox(height: 12),
                Text(
                  '暂时不用自动发现也行：在传输页点「通过 IP 发送」，输入对方 IP 和接收端口，一样能发文件。',
                  style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                        color: Theme.of(ctx).colorScheme.primary,
                      ),
                ),
                const SizedBox(height: 14),
                Text(
                  '想一键放行防火墙？复制下面整段命令，再以管理员身份打开 CMD，粘贴后回车即可。',
                  style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w400,
                        color: Theme.of(ctx).colorScheme.primary,
                      ),
                ),
                const SizedBox(height: 6),
                Container(
                  width: double.infinity,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: Theme.of(ctx).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: Theme.of(ctx).colorScheme.outline.withOpacity(0.5),
                    ),
                  ),
                  child: SelectableText(
                    _fullFirewallScript,
                    style: Theme.of(ctx).textTheme.labelSmall?.copyWith(
                          fontFamily: 'Consolas',
                          color: Theme.of(ctx).colorScheme.onSurface,
                        ),
                  ),
                ),
                const SizedBox(height: 8),
                StatefulBuilder(
                  builder: (context, setDialogState) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            if (_discoveryDialogCopied)
                              Padding(
                                padding: const EdgeInsets.only(right: 12),
                                child: Text(
                                  '已复制',
                                  style: Theme.of(ctx)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(
                                        color:
                                            Theme.of(ctx).colorScheme.primary,
                                      ),
                                ),
                              )
                            else
                              const SizedBox.shrink(),
                            FilledButton.icon(
                              onPressed: () {
                                Clipboard.setData(
                                    ClipboardData(text: _fullFirewallScript));
                                _discoveryDialogCopied = true;
                                setDialogState(() {});
                              },
                              icon: const Icon(Icons.copy, size: 18),
                              label: const Text('复制命令'),
                            ),
                            const SizedBox(width: 10),
                            FilledButton.icon(
                              onPressed: _discoveryDialogRunRequested
                                  ? null
                                  : () async {
                                      final ok =
                                          await _runFirewallScriptAsAdmin();
                                      if (mounted) {
                                        _discoveryDialogRunRequested = true;
                                        setDialogState(() {});
                                        if (!ok) {
                                          ScaffoldMessenger.of(context)
                                              .showSnackBar(
                                            const SnackBar(
                                                content: Text(
                                                    '启动失败，请改用「复制命令」后手动以管理员运行 CMD 执行')),
                                          );
                                        }
                                      }
                                    },
                              icon: const Icon(Icons.play_arrow, size: 18),
                              label: const Text('一键执行'),
                            ),
                          ],
                        ),
                        if (_discoveryDialogRunRequested) ...[
                          const SizedBox(height: 10),
                          Text(
                            '已请求管理员权限。请在弹出窗口中点击「是」，执行完成后关闭 CMD 窗口并重启本应用。',
                            style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                                  color: Theme.of(ctx).colorScheme.primary,
                                ),
                          ),
                        ],
                      ],
                    );
                  },
                ),
              ],
            ],
          ),
        ),
        actions: [
          if (isPermission)
            FilledButton.icon(
              onPressed: () {
                Navigator.of(ctx).pop();
                _openNetworkPermissionSettings();
              },
              icon: const Icon(Icons.settings, size: 20),
              label: Text(Platform.isWindows ? '打开防火墙设置' : '前往设置'),
            ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  bool _discoveryDialogCopied = false;
  bool _discoveryDialogRunRequested = false;

  @override
  void dispose() {
    _textController.dispose();
    _devSub?.cancel();
    _pendingSub?.cancel();
    _discoveryErrorSub?.cancel();
    _saveErrorSub?.cancel();
    for (final subscription in _receiveProgressSubs.values) {
      subscription.cancel();
    }
    _receiveProgressSubs.clear();
    _deviceCleanupTimer?.cancel();
    _discovery.dispose();
    _server.dispose();
    super.dispose();
  }

  /// 按设备平台返回对应图标（附近设备列表与选择设备弹窗使用）
  static IconData _deviceIcon(TransferDevice d) {
    switch (d.platform?.toLowerCase()) {
      case 'windows':
        return Icons.computer;
      case 'android':
        return Icons.phone_android;
      case 'ios':
        return Icons.phone_iphone;
      case 'ipad':
        return Icons.tablet_mac;
      default:
        return Icons.devices;
    }
  }

  /// 通过手动输入的 IP:端口 发送（发现失败时可用）
  Future<void> _showManualSendDialog() async {
    final ipController = TextEditingController();
    final portController = TextEditingController(text: '');
    final device = await showDialog<TransferDevice>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('通过 IP 发送'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '对方需先打开传输页，并告知你其「本机接收端口」。',
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: ipController,
                decoration: const InputDecoration(
                  labelText: '对方 IP',
                  hintText: '如 192.168.1.100',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.numberWithOptions(decimal: true),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: portController,
                decoration: const InputDecoration(
                  labelText: '对方接收端口',
                  hintText: '对方界面显示的「本机接收端口」',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.number,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                final ip = ipController.text.trim();
                final port = int.tryParse(portController.text.trim());
                if (ip.isEmpty || port == null || port <= 0 || port > 65535) {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                    const SnackBar(content: Text('请输入有效的 IP 与端口（1-65535）')),
                  );
                  return;
                }
                Navigator.of(ctx).pop(TransferDevice(
                  name: '手动 ($ip:$port)',
                  type: 'manual',
                  address: ip,
                  port: port,
                ));
              },
              child: const Text('确定'),
            ),
          ],
        );
      },
    );
    if (device == null || !mounted) return;
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('选择发送方式'),
        content: const Text('向该设备发送文件还是文本？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('file'),
            child: const Text('发送文件'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('text'),
            child: const Text('发送文本'),
          ),
        ],
      ),
    );
    if (action == 'file') _pickAndSendToDevice(device);
    if (action == 'text') _showSendTextDialog(device);
  }

  void _showSendTextDialog(TransferDevice device) {
    final c = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('发送文本'),
        content: TextField(
          controller: c,
          maxLines: 4,
          decoration: const InputDecoration(
            hintText: '输入要发送的文本…',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _sendTextToDevice(device, c.text.trim());
            },
            child: const Text('发送'),
          ),
        ],
      ),
    );
  }

  String _deviceKey(TransferDevice device) =>
      device.deviceId != null && device.deviceId!.isNotEmpty
          ? device.deviceId!
          : '${device.address}:${device.port}';

  Future<TransferDevice?> _chooseTargetDevice({String? sendSummary}) async {
    if (_devices.isEmpty) return null;
    TransferDevice? selected;
    StateSetter? updateDialog;
    final liveSub = _discovery.devices.listen((_) {
      updateDialog?.call(() {
        if (selected != null) {
          final key = _deviceKey(selected!);
          final matches = _devices.where((device) => _deviceKey(device) == key);
          selected = matches.isEmpty ? null : matches.first;
        }
      });
    });
    try {
      return await showDialog<TransferDevice>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setDialogState) {
            updateDialog = setDialogState;
            return AlertDialog(
              title: const Text('选择设备并确认发送'),
              content: SizedBox(
                width: 360,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (sendSummary != null && sendSummary.isNotEmpty) ...[
                      Text(sendSummary,
                          style: Theme.of(ctx).textTheme.bodySmall),
                      const SizedBox(height: 10),
                    ],
                    Row(
                      children: [
                        Expanded(child: Text('已发现 ${_devices.length} 台设备')),
                        TextButton.icon(
                          onPressed: () {
                            unawaited(_discovery.refresh());
                          },
                          icon: const Icon(Icons.refresh, size: 18),
                          label: const Text('实时刷新'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Flexible(
                      child: _devices.isEmpty
                          ? const Padding(
                              padding: EdgeInsets.symmetric(vertical: 24),
                              child: Center(child: Text('正在发现设备，请稍候或点击刷新')),
                            )
                          : ListView.builder(
                              shrinkWrap: true,
                              itemCount: _devices.length,
                              itemBuilder: (_, i) {
                                final device = _devices[i];
                                return RadioListTile<TransferDevice>(
                                  value: device,
                                  groupValue: selected,
                                  onChanged: (value) =>
                                      setDialogState(() => selected = value),
                                  secondary: Icon(_deviceIcon(device)),
                                  title: Text(device.name),
                                  subtitle: Text(
                                      '${device.type} · ${device.address}:${device.port}'),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('取消')),
                FilledButton.icon(
                  onPressed: selected == null
                      ? null
                      : () => Navigator.pop(ctx, selected),
                  icon: const Icon(Icons.send_outlined),
                  label: const Text('确定发送'),
                ),
              ],
            );
          },
        ),
      );
    } finally {
      updateDialog = null;
      await liveSub.cancel();
    }
  }

  Future<void> _showNoDeviceDialog() async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('未发现设备'),
        content: const Text(
          '请确保对方已打开传输页并处于同一局域网。\n\n也可使用「通过 IP 发送」手动输入对方 IP 与接收端口。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('知道了'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _showManualSendDialog();
            },
            child: const Text('通过 IP 发送'),
          ),
        ],
      ),
    );
  }

  Future<List<String>> _collectSendablePaths(List<String> rawPaths) async {
    final out = <String>[];
    for (final path in rawPaths) {
      if (path.isEmpty) continue;
      final type = FileSystemEntity.typeSync(path);
      if (type == FileSystemEntityType.directory) {
        final dir = Directory(path);
        await for (final entity
            in dir.list(recursive: true, followLinks: false)) {
          if (entity is File) out.add(entity.path);
        }
      } else if (type == FileSystemEntityType.file) {
        out.add(path);
      }
    }
    return out;
  }

  bool get _isDesktopTransferDropSupported =>
      !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  Future<void> _onDesktopDropDone(DropDoneDetails detail) async {
    setState(() => _draggingFiles = false);
    if (_sendTabIndex != 0 || _sending) return;
    final raw = <String>[];
    for (final item in detail.files) {
      final p = item.path;
      if (p.isNotEmpty) raw.add(p);
    }
    if (raw.isEmpty) return;
    final paths = await _collectSendablePaths(raw);
    if (paths.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('未找到可发送的文件')),
        );
      }
      return;
    }
    await _addQueuedSendPaths(paths);
    await _sendPaths(paths);
  }

  Future<void> _sendPaths(List<String> paths) async {
    if (paths.isEmpty) return;
    if (_devices.isEmpty) {
      await _showNoDeviceDialog();
      return;
    }
    final summary = paths.length == 1
        ? '准备发送：${paths.first.split(RegExp(r'[/\\]')).last}'
        : '准备发送 ${paths.length} 个文件';
    final chosen = await _chooseTargetDevice(sendSummary: summary);
    if (chosen == null) return;

    setState(() {
      _sending = true;
      _sendProgress = 0;
      _sendError = null;
    });

    var sent = 0;
    try {
      for (var i = 0; i < paths.length; i++) {
        final pathStr = paths[i];
        await TransferClient.sendFile(chosen, pathStr, onProgress: (p) {
          if (!mounted) return;
          final base = paths.length <= 1 ? 0.0 : i / paths.length;
          final span = paths.length <= 1 ? 1.0 : 1.0 / paths.length;
          setState(() => _sendProgress = (base + p * span).clamp(0.0, 1.0));
        });
        sent++;
        if (mounted) {
          setState(() {
            _transferHistory.insert(
                0,
                TransferRecord(
                  type: 'file',
                  targetName: chosen.name,
                  fileName: pathStr.split(RegExp(r'[/\\]')).last,
                  localPath: pathStr,
                  at: DateTime.now(),
                ));
            if (_transferHistory.length > _maxHistory)
              _transferHistory.removeLast();
          });
        }
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(paths.length == 1 ? '已发送' : '已发送 $sent 个文件')),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _sendError = e.toString());
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(sent > 0 ? '部分发送失败: $e（已成功 $sent 个）' : '发送失败: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _pickAndSend() async {
    final result = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (result == null || result.files.isEmpty) return;
    final paths =
        result.files.map((file) => file.path).whereType<String>().toList();
    await _addQueuedSendPaths(paths);
    await _sendPaths(paths);
  }

  Future<void> _pickAndSendToDevice(TransferDevice device,
      [String? path]) async {
    String? filePath = path;
    if (filePath == null) {
      final result = await FilePicker.platform.pickFiles(allowMultiple: false);
      if (result == null ||
          result.files.isEmpty ||
          result.files.single.path == null) return;
      filePath = result.files.single.path;
    }
    if (filePath == null) return;
    final pathStr = filePath;
    await _addQueuedSendPaths([pathStr]);
    final knownDevice =
        _devices.any((item) => _deviceKey(item) == _deviceKey(device));
    if (knownDevice) {
      await _sendPaths([pathStr]);
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认发送'),
        content: Text(
            '将“${pathStr.split(RegExp(r'[/\\]')).last}”发送到 ${device.name}？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('确定发送')),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() {
      _sending = true;
      _sendProgress = 0;
      _sendError = null;
    });
    try {
      await TransferClient.sendFile(device, pathStr, onProgress: (p) {
        if (mounted) setState(() => _sendProgress = p);
      });
      if (mounted) {
        setState(() {
          _transferHistory.insert(
              0,
              TransferRecord(
                type: 'file',
                targetName: device.name,
                fileName: pathStr.split(RegExp(r'[/\\]')).last,
                localPath: pathStr,
                at: DateTime.now(),
              ));
          if (_transferHistory.length > _maxHistory)
            _transferHistory.removeLast();
        });
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('已发送')));
      }
    } catch (e) {
      if (mounted) {
        setState(() => _sendError = e.toString());
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('发送失败: $e')));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _sendText() async {
    final text = _textController.text.trim();
    if (text.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请输入要发送的文本')));
      return;
    }
    if (_devices.isEmpty) {
      if (mounted) {
        showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('未发现设备'),
            content: const Text(
              '请确保对方已打开传输页并处于同一局域网。\n\n也可使用「通过 IP 发送」手动输入对方 IP 与接收端口。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('知道了'),
              ),
              FilledButton(
                onPressed: () {
                  Navigator.of(ctx).pop();
                  _showManualSendDialog();
                },
                child: const Text('通过 IP 发送'),
              ),
            ],
          ),
        );
      }
      return;
    }
    final chosen =
        await _chooseTargetDevice(sendSummary: '准备发送文本 · ${text.length} 个字符');
    if (chosen == null) return;
    _sendTextToDevice(chosen, text);
  }

  Future<void> _sendTextToDevice(TransferDevice device, [String? text]) async {
    final content = text ?? _textController.text.trim();
    if (content.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请输入要发送的文本')));
      return;
    }
    setState(() {
      _sending = true;
      _sendError = null;
    });
    try {
      await TransferClient.sendText(device, content);
      if (mounted) {
        setState(() {
          _transferHistory.insert(
              0,
              TransferRecord(
                type: 'text',
                targetName: device.name,
                textPreview: content.length > 40
                    ? '${content.substring(0, 40)}…'
                    : content,
                at: DateTime.now(),
              ));
          if (_transferHistory.length > _maxHistory)
            _transferHistory.removeLast();
          if (text == null) _textController.clear();
        });
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('文本已发送')));
      }
    } catch (e) {
      if (mounted) {
        setState(() => _sendError = e.toString());
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('发送失败: $e')));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Widget _buildQueuedFiles(ThemeData theme, ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 14),
        Row(
          children: [
            Icon(Icons.playlist_add_check_rounded,
                size: 20, color: colorScheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '待发送文件（${_queuedSendPaths.length}）',
                style: theme.textTheme.titleSmall,
              ),
            ),
            Text(
              '发送后保留',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: colorScheme.onSurfaceVariant),
            ),
          ],
        ),
        const SizedBox(height: 8),
        for (final path in _queuedSendPaths) ...[
          Builder(builder: (context) {
            final file = File(path);
            final exists = file.existsSync();
            String? size;
            if (exists) {
              try {
                size = TransferFileActions.formatSize(file.lengthSync());
              } catch (_) {}
            }
            return Container(
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest.withOpacity(0.38),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: exists
                      ? colorScheme.outline.withOpacity(0.3)
                      : colorScheme.error.withOpacity(0.65),
                ),
              ),
              child: ListTile(
                dense: true,
                leading: Icon(
                  TransferFileActions.iconForPath(path, isDirectory: false),
                  color: exists ? colorScheme.primary : colorScheme.error,
                ),
                title: Text(
                  path.split(RegExp(r'[/\\]')).last,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  exists
                      ? [if (size != null) size, file.parent.path].join(' · ')
                      : '源文件已移动或删除',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: exists
                        ? colorScheme.onSurfaceVariant
                        : colorScheme.error,
                  ),
                ),
                onTap: exists
                    ? () => TransferFileActions.openFile(context, path)
                    : null,
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  color: colorScheme.error,
                  tooltip: '从待发送列表移除',
                  onPressed:
                      _sending ? null : () => _removeQueuedSendPath(path),
                ),
              ),
            );
          }),
        ],
        const SizedBox(height: 2),
        OutlinedButton.icon(
          onPressed: _sending ? null : _sendQueuedFiles,
          icon: const Icon(Icons.send_outlined),
          label: Text('发送列表中的 ${_queuedSendPaths.length} 个文件'),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Theme.of(context).appBarTheme.backgroundColor,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: const Text('传输'),
        actions: [
          IconButton(
            icon: const Icon(Icons.folder_open_outlined),
            onPressed: () =>
                TransferFileActions.openReceivedFilesManager(context),
            tooltip: '接收文件管理',
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
              unawaited(_discovery.refresh());
            },
            tooltip: '刷新设备',
          ),
        ],
      ),
      body: ListView(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: 16 +
              kBottomNavigationBarHeight +
              MediaQuery.of(context).padding.bottom,
        ),
        children: [
          // 发送区域：标签切换 发送文件 / 发送文本
          _wrapDesktopDropTarget(
            AppGlassStyles.section(
              context,
              margin: EdgeInsets.zero,
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SegmentedButton<int>(
                    segments: const [
                      ButtonSegment(
                          value: 0,
                          icon: Icon(Icons.upload_file),
                          label: Text('发送文件')),
                      ButtonSegment(
                          value: 1,
                          icon: Icon(Icons.text_fields),
                          label: Text('发送文本')),
                    ],
                    selected: {_sendTabIndex},
                    onSelectionChanged: (Set<int> s) {
                      setState(() => _sendTabIndex = s.first);
                      _sendError = null;
                    },
                    style: ButtonStyle(
                      visualDensity: VisualDensity.standard,
                      padding: WidgetStateProperty.all(
                          const EdgeInsets.symmetric(
                              vertical: 12, horizontal: 16)),
                    ),
                  ),
                  const SizedBox(height: 20),
                  if (_sendTabIndex == 0) ...[
                    // 拖放热区：约屏高 32%，320–480，方便电脑端瞄准
                    Container(
                      width: double.infinity,
                      height: (MediaQuery.sizeOf(context).height * 0.32)
                          .clamp(320.0, 480.0),
                      alignment: Alignment.center,
                      padding: const EdgeInsets.symmetric(
                          vertical: 36, horizontal: 24),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          width: 2,
                          color: _draggingFiles
                              ? colorScheme.primary
                              : colorScheme.outline.withOpacity(0.4),
                        ),
                        color: _draggingFiles
                            ? colorScheme.primaryContainer.withOpacity(0.28)
                            : colorScheme.surfaceContainerHighest
                                .withOpacity(0.4),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.cloud_upload_outlined,
                            size: 64,
                            color: _draggingFiles
                                ? colorScheme.primary
                                : colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(height: 20),
                          Text(
                            _draggingFiles
                                ? '松开即可发送文件或文件夹'
                                : (_isDesktopTransferDropSupported
                                    ? '可将文件/文件夹拖放到此区域发送（电脑端）'
                                    : '点下方按钮选择文件并发送'),
                            textAlign: TextAlign.center,
                            style: theme.textTheme.titleMedium?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                              height: 1.35,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: _sending ? null : _pickAndSend,
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                      ),
                      icon: _sending
                          ? SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: colorScheme.onPrimary),
                            )
                          : const Icon(Icons.upload_file),
                      label: Text(_sending ? '发送中…' : '选择文件并发送'),
                    ),
                    if (_queuedSendPaths.isNotEmpty)
                      _buildQueuedFiles(theme, colorScheme),
                    if (_sending) ...[
                      const SizedBox(height: 8),
                      LinearProgressIndicator(value: _sendProgress),
                      const SizedBox(height: 4),
                      Text(
                        _sendProgress >= 1
                            ? '对方已保存 100%'
                            : _sendProgress >= 0.99
                                ? '等待对方保存确认…'
                                : '发送中 ${(_sendProgress * 100).round()}%',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: colorScheme.onSurfaceVariant),
                      ),
                    ],
                  ] else ...[
                    SizedBox(
                      height: (MediaQuery.sizeOf(context).height * 0.32)
                          .clamp(320.0, 480.0),
                      child: TextField(
                        controller: _textController,
                        maxLines: null,
                        expands: true,
                        textAlignVertical: TextAlignVertical.top,
                        decoration: InputDecoration(
                          hintText: '输入要发送的文本…',
                          border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8)),
                          filled: true,
                          fillColor: colorScheme.surfaceContainerHighest
                              .withOpacity(0.5),
                          contentPadding: const EdgeInsets.all(16),
                        ),
                        style: theme.textTheme.bodyLarge,
                      ),
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: _sending ? null : _sendText,
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                      ),
                      icon: _sending
                          ? SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: colorScheme.onPrimary),
                            )
                          : const Icon(Icons.send),
                      label: Text(_sending ? '发送中…' : '发送文本'),
                    ),
                  ],
                  if (_sendError != null) ...[
                    const SizedBox(height: 8),
                    Text(_sendError!,
                        style: theme.textTheme.labelMedium
                            ?.copyWith(color: colorScheme.error)),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          // 传输记录
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('传输记录', style: theme.textTheme.titleSmall),
              if (_transferHistory.isNotEmpty)
                TextButton(
                  onPressed: () => setState(() => _transferHistory.clear()),
                  child: const Text('清空'),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (_transferHistory.isEmpty)
            AppGlassStyles.section(
              context,
              padding: const EdgeInsets.all(16),
              child: Text(
                '暂无传输记录',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant.withOpacity(0.95),
                ),
              ),
            )
          else
            AppGlassStyles.section(
              context,
              child: Column(
                children: _transferHistory.take(20).map((r) {
                  return ListTile(
                    leading: Icon(
                      r.type == 'file'
                          ? TransferFileActions.iconForPath(
                              r.localPath ?? r.fileName ?? '',
                              isDirectory: false)
                          : Icons.text_snippet,
                      color: colorScheme.primary,
                    ),
                    title: Text(
                      r.type == 'file' ? (r.fileName ?? '文件') : '文本',
                      style: theme.textTheme.bodyMedium,
                    ),
                    subtitle: Text(
                      r.isReceive
                          ? '← 来自 ${r.targetName}'
                          : '→ ${r.targetName}',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: colorScheme.onSurfaceVariant),
                    ),
                    onTap: r.type == 'file' &&
                            r.localPath != null &&
                            r.localPath!.isNotEmpty
                        ? () =>
                            TransferFileActions.openFile(context, r.localPath!)
                        : null,
                    trailing: r.type == 'file'
                        ? PopupMenuButton<String>(
                            tooltip: '更多',
                            onSelected: (value) async {
                              if (value == 'open_file') {
                                if (r.localPath != null) {
                                  await TransferFileActions.openFile(
                                      context, r.localPath!);
                                }
                              } else if (value == 'delete') {
                                await _deleteRecordAndFile(r);
                              } else if (value == 'open_dir') {
                                await TransferFileActions.openSaveLocation(
                                  context,
                                  highlightFile: r.localPath,
                                );
                              } else if (value == 'save_as') {
                                await _saveRecordAs(r);
                              }
                            },
                            itemBuilder: (ctx) => const [
                              PopupMenuItem(
                                  value: 'open_file', child: Text('打开文件')),
                              PopupMenuItem(
                                  value: 'open_dir', child: Text('打开所在位置')),
                              PopupMenuItem(
                                  value: 'save_as', child: Text('保存到本地')),
                              PopupMenuItem(
                                  value: 'delete', child: Text('删除文件')),
                            ],
                            child: Icon(Icons.more_vert,
                                size: 20, color: colorScheme.outline),
                          )
                        : (r.textPreview != null
                            ? Tooltip(
                                message: r.textPreview!,
                                child: Icon(Icons.info_outline,
                                    size: 18, color: colorScheme.outline),
                              )
                            : null),
                  );
                }).toList(),
              ),
            ),
          const SizedBox(height: 16),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest.withOpacity(0.55),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text('端口信息', style: theme.textTheme.titleSmall),
                    ),
                    TextButton.icon(
                      onPressed: _showPortSettingsDialog,
                      icon: const Icon(Icons.tune, size: 18),
                      label: const Text('设置'),
                    ),
                  ],
                ),
                if (_server.port != null && _server.port! > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      '本机接收端口: ${_server.port}${_configuredReceivePort <= 0 ? '（自动分配）' : '（固定）'}',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: colorScheme.onSurfaceVariant),
                    ),
                  ),
                if (_discovery.boundPort != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      '发现端口: ${_discovery.boundPort}（配置: $_configuredDiscoveryPort）',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: colorScheme.onSurfaceVariant),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    '对方可通过接收端口向你发文件；发现端口用于自动发现附近设备。',
                    style: theme.textTheme.labelMedium,
                  ),
                ),
              ],
            ),
          ),
          // 附近设备
          Text('附近设备', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          if (_discoveryError != null)
            Container(
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest.withOpacity(0.8),
                borderRadius: BorderRadius.circular(12),
                border: Border(
                  left: BorderSide(
                      color: colorScheme.primary.withOpacity(0.6), width: 4),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Icon(Icons.info_outline_rounded,
                            size: 20,
                            color: colorScheme.primary.withOpacity(0.9)),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            '发现服务未启动，无法自动发现附近设备。可使用「通过 IP 发送」或按下方步骤放行防火墙。',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colorScheme.onSurface,
                              height: 1.35,
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: () =>
                              _showDiscoveryErrorDialog(_discoveryError!),
                          child: const Text('详情'),
                        ),
                        FilledButton.tonalIcon(
                          onPressed: () async {
                            await _retryDiscovery();
                            if (mounted && _discoveryError == null) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('发现服务已重新启动')),
                              );
                            }
                          },
                          icon: const Icon(Icons.refresh, size: 18),
                          label: const Text('重试发现'),
                        ),
                      ],
                    ),
                    if (Platform.isWindows) ...[
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            '执行完「一键执行」后请点「重试发现」或重启应用。',
                            style: theme.textTheme.labelMedium,
                          ),
                          FilledButton.icon(
                            onPressed: () async {
                              final ok = await _runFirewallScriptAsAdmin();
                              if (mounted && !ok) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                      content: Text('启动失败，请点「详情」获取完整命令')),
                                );
                              }
                            },
                            icon: const Icon(Icons.play_arrow, size: 16),
                            label: const Text('一键执行'),
                            style: FilledButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 8),
                              minimumSize: Size.zero,
                            ),
                          ),
                          TextButton.icon(
                            onPressed: _showExcludedPortDiagnostic,
                            icon: const Icon(Icons.help_outline, size: 16),
                            label: const Text('检查端口'),
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 8),
                              minimumSize: Size.zero,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          if (_devices.isEmpty)
            AppGlassStyles.section(
              context,
              padding: const EdgeInsets.all(24),
              child: Center(
                child: Column(
                  children: [
                    Icon(Icons.devices_other,
                        size: 48,
                        color: colorScheme.onSurfaceVariant.withOpacity(0.7)),
                    const SizedBox(height: 8),
                    Text(
                      '未发现设备',
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: colorScheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '请确保对方已打开本页并处于同一 WiFi',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant.withOpacity(0.9),
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      Platform.isWindows
                          ? '若无法发现设备，请检查防火墙是否允许本应用（UDP ${_configuredDiscoveryPort}）'
                          : '若无法发现设备，请检查是否已授予网络/本地网络权限',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: colorScheme.onSurfaceVariant.withOpacity(0.85),
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 10),
                    FilledButton.icon(
                      onPressed: _openNetworkPermissionSettings,
                      icon: const Icon(Icons.settings, size: 18),
                      label: Text(Platform.isWindows ? '打开防火墙设置' : '前往设置'),
                      style: FilledButton.styleFrom(
                        backgroundColor: colorScheme.primaryContainer,
                        foregroundColor: colorScheme.onPrimaryContainer,
                      ),
                    ),
                  ],
                ),
              ),
            )
          else ...[
            Text(
              '列表中为对方设备的 IP 与接收端口，两端显示不同属正常',
              style: theme.textTheme.labelMedium?.copyWith(
                color: colorScheme.onSurfaceVariant.withOpacity(0.9),
              ),
            ),
            const SizedBox(height: 4),
            ..._devices.map((d) => AppGlassStyles.listCard(
                  context,
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    leading: Icon(_deviceIcon(d)),
                    title: Text(d.name),
                    subtitle: Text('${d.type} · ${d.address}:${d.port}'),
                  ),
                )),
          ],
          const SizedBox(height: 24),
          // 待接收
          Text('待接收', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          if (_pending.isEmpty)
            AppGlassStyles.section(
              context,
              padding: const EdgeInsets.all(16),
              child: Text(
                '暂无待接收',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant.withOpacity(0.95),
                ),
              ),
            )
          else
            ..._pending.map((p) {
              final isReceiving = _receiving.contains(p);
              final progress = (_receiveProgress[p] ?? p.currentProgress)
                  .clamp(0.0, 1.0)
                  .toDouble();
              return AppGlassStyles.section(
                context,
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          p.isText
                              ? Icons.text_snippet
                              : Icons.insert_drive_file,
                          size: 20,
                          color: colorScheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          p.isText
                              ? '文本来自 ${p.deviceName}'
                              : '来自 ${p.deviceName}',
                          style: theme.textTheme.titleSmall,
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    if (p.isText && p.text != null)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: colorScheme.surfaceContainerHighest
                              .withOpacity(0.4),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          p.text!.length > 200
                              ? '${p.text!.substring(0, 200)}…'
                              : p.text!,
                          style: theme.textTheme.bodySmall,
                          maxLines: 5,
                          overflow: TextOverflow.ellipsis,
                        ),
                      )
                    else
                      ...p.files.map((f) => Text(
                            '${f['filename']} (${_formatSize((f['size'] as num?)?.toInt() ?? 0)})',
                            style: theme.textTheme.bodySmall,
                          )),
                    const SizedBox(height: 8),
                    if (isReceiving && !p.isText && p.totalSize > 0)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            LinearProgressIndicator(value: progress),
                            const SizedBox(height: 4),
                            Text(
                              progress >= 1
                                  ? '已保存 100%'
                                  : progress >= 0.99
                                      ? '正在完成写入…'
                                      : '接收并保存中 ${(progress * 100).round()}%',
                              style: theme.textTheme.bodySmall?.copyWith(
                                  color: colorScheme.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                    if (isReceiving && p.isText)
                      const Row(
                        children: [
                          SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          SizedBox(width: 10),
                          Text('正在接收文本…'),
                        ],
                      )
                    else if (!isReceiving)
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: p.isText
                            ? [
                                TextButton(
                                  onPressed: () => _rejectPendingReceive(p),
                                  child: const Text('拒绝'),
                                ),
                                FilledButton.icon(
                                  onPressed: () => _acceptPendingReceive(p),
                                  icon: const Icon(Icons.copy, size: 18),
                                  label: const Text('接受并复制'),
                                ),
                              ]
                            : [
                                TextButton(
                                  onPressed: () => _rejectPendingReceive(p),
                                  child: const Text('拒绝'),
                                ),
                                FilledButton(
                                  onPressed: () => _acceptPendingReceive(p),
                                  child: const Text('接受'),
                                ),
                              ],
                      ),
                  ],
                ),
              );
            }),
        ],
      ),
    );
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  Future<void> _deleteRecordAndFile(TransferRecord r) async {
    if (r.localPath != null && r.localPath!.isNotEmpty) {
      try {
        final file = File(r.localPath!);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() => _transferHistory.remove(r));
  }

  Widget _wrapDesktopDropTarget(Widget child) {
    if (!_isDesktopTransferDropSupported || _sendTabIndex != 0) return child;
    return DropTarget(
      onDragEntered: (_) => setState(() => _draggingFiles = true),
      onDragExited: (_) => setState(() => _draggingFiles = false),
      onDragDone: _onDesktopDropDone,
      child: child,
    );
  }

  Future<void> _saveRecordAs(TransferRecord r) async {
    if (r.localPath == null || r.localPath!.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('该记录暂无可保存的本地文件')),
        );
      }
      return;
    }
    final src = File(r.localPath!);
    if (!await src.exists()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('源文件不存在，可能已被删除')),
        );
      }
      return;
    }
    final targetPath = await FilePicker.platform.saveFile(
      dialogTitle: '保存到本地',
      fileName: r.fileName ?? src.path.split(RegExp(r'[/\\]')).last,
    );
    if (targetPath == null || targetPath.isEmpty) return;
    try {
      await src.copy(targetPath);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已保存到本地')),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('保存失败')),
        );
      }
    }
  }
}
