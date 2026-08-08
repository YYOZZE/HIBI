import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_glass_styles.dart';
import '../../app/frosted_background.dart';
import 'services/app_clock_offset.dart';
import 'services/lan_sync_discovery.dart';
import 'services/lan_sync_service.dart';

/// 设置 → 局域网数据同步
class LanSyncPage extends StatefulWidget {
  const LanSyncPage({super.key});

  @override
  State<LanSyncPage> createState() => _LanSyncPageState();
}

class _LanSyncPageState extends State<LanSyncPage> {
  final LanSyncService _svc = LanSyncService.instance;
  final TextEditingController _pinController = TextEditingController();
  bool _starting = false;
  bool _busy = false;
  String? _lastResult;

  @override
  void initState() {
    super.initState();
    _svc.inboundNotifier.addListener(_onInbound);
    _svc.statusNotifier.addListener(_onStatus);
    unawaited(_ensureStarted());
  }

  Future<void> _ensureStarted() async {
    if (_svc.isRunning) return;
    setState(() => _starting = true);
    try {
      await _svc.start();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('无法启动同步服务：$e')),
        );
      }
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  void _onInbound() {
    if (!mounted) return;
    setState(() {});
    final inbound = _svc.inboundNotifier.value;
    if (inbound != null) {
      unawaited(_showInboundDialog(inbound));
    }
  }

  void _onStatus() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _svc.inboundNotifier.removeListener(_onInbound);
    _svc.statusNotifier.removeListener(_onStatus);
    _pinController.dispose();
    // 离开页面保持服务运行一小段时间不便；为省资源直接 stop
    unawaited(_svc.stop());
    super.dispose();
  }

  Future<void> _showInboundDialog(LanSyncInboundRequest inbound) async {
    final pinCtrl = TextEditingController();
    final accept = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        final cs = theme.colorScheme;
        return AlertDialog(
          backgroundColor: AppGlassStyles.dialogBackground(ctx),
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('同步申请'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '「${inbound.fromDeviceName}」'
                '${inbound.fromAccountHint.isNotEmpty ? '（${inbound.fromAccountHint}）' : ''}'
                '请求与本机同步思维导图 / 日程 / 智能体数据。',
                style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
              ),
              if (inbound.pinRequired) ...[
                const SizedBox(height: 14),
                Text(
                  '请输入对方设置的配对码',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: pinCtrl,
                  keyboardType: TextInputType.number,
                  obscureText: true,
                  maxLength: 8,
                  decoration: InputDecoration(
                    labelText: '配对码',
                    filled: true,
                    fillColor: AppGlassStyles.inputFill(ctx),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('拒绝'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('同意并同步'),
            ),
          ],
        );
      },
    );
    if (!mounted) {
      pinCtrl.dispose();
      return;
    }
    if (accept == true) {
      setState(() => _busy = true);
      final result = await _svc.acceptInboundWithPin(pinCtrl.text);
      if (mounted) {
        setState(() {
          _busy = false;
          _lastResult = result.message;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(result.message)),
        );
      }
    } else if (accept == false) {
      await _svc.rejectInbound();
    }
    pinCtrl.dispose();
  }

  Future<void> _requestSync(LanSyncPeer peer) async {
    final pin = _pinController.text.trim();
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppGlassStyles.dialogBackground(ctx),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('发起同步'),
        content: Text(
          '向「${peer.displayLabel}」申请同步？\n'
          '双方将先对齐时间，再按修改时间合并思维导图、日程与智能体数据'
          '${pin.isNotEmpty ? '。对方需输入配对码 $pin' : '。'}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('发送申请'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    setState(() {
      _busy = true;
      _lastResult = null;
    });
    final result = await _svc.requestSyncWith(peer, pin: pin.isEmpty ? null : pin);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _lastResult = result.ok
          ? '完成：思维 ${result.mindCount} · 日程 ${result.scheduleCount} · 智能体 ${result.agentCount}'
              '${result.clockOffsetMs != 0 ? ' · 时钟偏移 ${result.clockOffsetMs}ms' : ''}'
          : result.message;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(result.ok ? '同步成功' : result.message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final status = _svc.statusNotifier.value;
    final offset = AppClockOffset.instance.offsetMs;

    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: const Text('局域网数据同步'),
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          const FrostedBackground(),
          Positioned.fill(
            top: MediaQuery.of(context).padding.top + kToolbarHeight + 8,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
              children: [
                AppGlassStyles.section(
                  context,
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '同一 Wi‑Fi / 热点下的希比设备可互相发现。发起方可选配对码，对方同意后先对齐时间，再合并思维导图、日程与智能体（按修改时间，新覆盖旧）。',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: cs.onSurfaceVariant,
                          height: 1.45,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Icon(
                            _svc.isRunning
                                ? Icons.wifi_tethering
                                : Icons.wifi_tethering_off,
                            size: 18,
                            color: _svc.isRunning ? cs.primary : cs.outline,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _starting
                                  ? '正在启动…'
                                  : (status ??
                                      (_svc.isRunning ? '广播中' : '未启动')),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                          ),
                          if (_busy)
                            const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                        ],
                      ),
                      if (offset != 0) ...[
                        const SizedBox(height: 8),
                        Text(
                          '当前应用时钟偏移：${offset > 0 ? '+' : ''}${offset}ms',
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: cs.primary,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                AppGlassStyles.section(
                  context,
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '配对码（可选）',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _pinController,
                        keyboardType: TextInputType.number,
                        obscureText: true,
                        maxLength: 8,
                        enabled: !_busy,
                        decoration: InputDecoration(
                          hintText: '留空则对方确认即可',
                          filled: true,
                          fillColor: AppGlassStyles.inputFill(context),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          counterText: '',
                        ),
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                      ),
                      const SizedBox(height: 4),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  '附近设备',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface,
                  ),
                ),
                const SizedBox(height: 8),
                ValueListenableBuilder<List<LanSyncPeer>>(
                  valueListenable: _svc.peersNotifier,
                  builder: (context, peers, _) {
                    if (peers.isEmpty) {
                      return AppGlassStyles.section(
                        context,
                        padding: const EdgeInsets.all(20),
                        child: Text(
                          '未发现其他设备。请确认双方打开本页、处于同一局域网，并允许本地网络权限。',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: cs.onSurfaceVariant,
                            height: 1.45,
                          ),
                        ),
                      );
                    }
                    return Column(
                      children: [
                        for (final p in peers)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: AppGlassStyles.listCard(
                              context,
                              margin: EdgeInsets.zero,
                              child: ListTile(
                                leading: Icon(
                                  Icons.devices_other_outlined,
                                  color: cs.primary,
                                ),
                                title: Text(p.displayLabel),
                                subtitle: Text('${p.ip}:${p.httpPort}'),
                                trailing: FilledButton(
                                  onPressed: _busy ? null : () => _requestSync(p),
                                  child: const Text('同步'),
                                ),
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),
                if (_lastResult != null) ...[
                  const SizedBox(height: 12),
                  AppGlassStyles.section(
                    context,
                    padding: const EdgeInsets.all(14),
                    child: Text(
                      _lastResult!,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: cs.onSurface,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
