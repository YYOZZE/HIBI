import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_glass_styles.dart';
import '../../app/frosted_background.dart';
import '../auth/services/auth_repository.dart';
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
  bool _starting = false;
  bool _busy = false;
  String? _lastResult;
  String? _loginHint;

  @override
  void initState() {
    super.initState();
    _svc.inboundNotifier.addListener(_onInbound);
    _svc.statusNotifier.addListener(_onStatus);
    _svc.passwordNotifier.addListener(_onStatus);
    unawaited(_svc.refreshPasswordDisplay());
    unawaited(_ensureStarted());
  }

  Future<void> _ensureStarted() async {
    if (_svc.isRunning) return;
    final accountId = LanSyncService.resolveAccountId();
    if (accountId == null) {
      if (mounted) {
        setState(() => _loginHint = '请先登录');
      }
      return;
    }
    setState(() {
      _starting = true;
      _loginHint = null;
    });
    try {
      await _svc.start();
    } catch (e) {
      if (mounted) {
        final msg = '$e'.contains('请先登录') ? '请先登录' : '无法启动：$e';
        setState(() => _loginHint = msg.contains('请先登录') ? '请先登录' : null);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg)),
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
    _svc.passwordNotifier.removeListener(_onStatus);
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
        return AlertDialog(
          backgroundColor: AppGlassStyles.dialogBackground(ctx),
          surfaceTintColor: Colors.transparent,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('同步申请'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '「${inbound.fromDeviceName}」'
                '${inbound.fromAccountHint.isNotEmpty ? '（${inbound.fromAccountHint}）' : ''}'
                '请求同步。',
                style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
              ),
              if (inbound.pinRequired) ...[
                const SizedBox(height: 14),
                TextField(
                  controller: pinCtrl,
                  obscureText: true,
                  maxLength: 32,
                  decoration: InputDecoration(
                    labelText: '对方连接密码',
                    filled: true,
                    fillColor: AppGlassStyles.inputFill(ctx),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    counterText: '',
                  ),
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
              child: const Text('同意'),
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

  Future<void> _editPassword() async {
    final ctrl = TextEditingController(text: _svc.connectionPassword);
    final next = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppGlassStyles.dialogBackground(ctx),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('修改连接密码'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 32,
          decoration: InputDecoration(
            hintText: '至少 4 位',
            filled: true,
            fillColor: AppGlassStyles.inputFill(ctx),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            counterText: '',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (next == null || !mounted) return;
    if (next.length < 4) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('密码至少 4 位')),
      );
      return;
    }
    await _svc.setConnectionPassword(next);
    if (mounted) setState(() {});
  }

  Future<void> _resetPassword() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppGlassStyles.dialogBackground(ctx),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('重置连接密码'),
        content: const Text('将随机生成新密码，旧密码立即失效。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('重置'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _svc.resetConnectionPassword();
    if (mounted) {
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已重置')),
      );
    }
  }

  Future<void> _requestSync(LanSyncPeer peer) async {
    if (!LanSyncService.accountsMatch(_svc.accountId, peer.accountId)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('账号不一致')),
      );
      return;
    }
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppGlassStyles.dialogBackground(ctx),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('发起同步'),
        content: Text(
          '向「${peer.displayLabel}」申请同步？\n对方需输入本机连接密码。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('发送'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    setState(() {
      _busy = true;
      _lastResult = null;
    });
    final result = await _svc.requestSyncWith(peer);
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
    final password = _svc.passwordNotifier.value;
    final loggedIn = LanSyncService.resolveAccountId() != null ||
        AuthRepository.instance.currentUser != null;

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
                        '同局域网、同 GitHub 账号的设备可互相同步。对方需输入本机连接密码。',
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
                              _loginHint ??
                                  (_starting
                                      ? '正在启动…'
                                      : (status ??
                                          (_svc.isRunning ? '广播中' : '未启动'))),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: _loginHint != null
                                    ? cs.error
                                    : cs.onSurfaceVariant,
                              ),
                            ),
                          ),
                          if (_busy)
                            const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          if (!_svc.isRunning &&
                              !_starting &&
                              loggedIn &&
                              _loginHint == null)
                            TextButton(
                              onPressed: _ensureStarted,
                              child: const Text('重试'),
                            ),
                        ],
                      ),
                      if (offset != 0) ...[
                        const SizedBox(height: 8),
                        Text(
                          '时钟偏移：${offset > 0 ? '+' : ''}${offset}ms',
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
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '连接密码',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: SelectableText(
                              password.isEmpty ? '—' : password,
                              style: theme.textTheme.titleMedium?.copyWith(
                                letterSpacing: 1.2,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: '复制',
                            onPressed: password.isEmpty
                                ? null
                                : () async {
                                    await Clipboard.setData(
                                      ClipboardData(text: password),
                                    );
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(
                                        const SnackBar(
                                          content: Text('已复制'),
                                        ),
                                      );
                                    }
                                  },
                            icon: const Icon(Icons.copy_outlined, size: 20),
                          ),
                          IconButton(
                            tooltip: '修改',
                            onPressed: _busy ? null : _editPassword,
                            icon: const Icon(Icons.edit_outlined, size: 20),
                          ),
                          IconButton(
                            tooltip: '重置',
                            onPressed: _busy ? null : _resetPassword,
                            icon: const Icon(Icons.refresh, size: 20),
                          ),
                        ],
                      ),
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
                if (_loginHint != null)
                  AppGlassStyles.section(
                    context,
                    padding: const EdgeInsets.all(20),
                    child: Text(
                      _loginHint!,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: cs.error,
                        height: 1.45,
                      ),
                    ),
                  )
                else
                  ValueListenableBuilder<List<LanSyncPeer>>(
                    valueListenable: _svc.peersNotifier,
                    builder: (context, peers, _) {
                      if (peers.isEmpty) {
                        return AppGlassStyles.section(
                          context,
                          padding: const EdgeInsets.all(20),
                          child: Text(
                            '未发现其他设备。请确认双方打开本页并处于同一局域网。',
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
                                    color: LanSyncService.accountsMatch(
                                      _svc.accountId,
                                      p.accountId,
                                    )
                                        ? cs.primary
                                        : cs.outline,
                                  ),
                                  title: Text(p.displayLabel),
                                  subtitle: Text(
                                    LanSyncService.accountsMatch(
                                      _svc.accountId,
                                      p.accountId,
                                    )
                                        ? '${p.ip}:${p.httpPort}'
                                        : '账号不一致 · ${p.ip}',
                                  ),
                                  trailing: FilledButton(
                                    onPressed: _busy
                                        ? null
                                        : () => _requestSync(p),
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
