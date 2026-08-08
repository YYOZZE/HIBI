import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/frosted_background.dart';
import '../../config/github_oauth_config.dart';
import 'services/auth_repository.dart';
import 'services/github_oauth_service.dart';
import 'widgets/github_device_webview.dart';

enum _LoginStep {
  idle,
  requestCode,
  awaitAuth,
  checkStar,
  done,
}

/// GitHub Device Flow 登录 + Star 门禁（文案精简；默认内嵌 WebView）。
class GitHubLoginPage extends StatefulWidget {
  const GitHubLoginPage({super.key, this.embedded = false});

  final bool embedded;

  @override
  State<GitHubLoginPage> createState() => _GitHubLoginPageState();
}

class _GitHubLoginPageState extends State<GitHubLoginPage> {
  final _oauth = GitHubOAuthService.instance;

  bool _busy = false;
  bool _cancelled = false;
  int _flowGen = 0;
  String? _userCode;
  String? _verificationUri;
  String? _error;
  String? _status;
  bool _needStar = false;
  String? _pendingToken;
  String? _pendingLogin;
  _LoginStep _step = _LoginStep.idle;
  bool _webviewOpen = false;
  bool _reopeningWeb = false;
  GitHubDeviceCode? _activeDevice;
  GitHubDeviceWebViewController? _webController;
  Timer? _slowRequestTimer;
  bool _showSlowHint = false;

  /// 已拿到设备码、正在等用户点 Authorize（poll 仍在跑）。
  bool get _awaitingUserAuth =>
      _step == _LoginStep.awaitAuth && _activeDevice != null;

  /// 关闭内嵌窗后仍可再开；窗已开则不必重复点。
  bool get _canOpenAuthPage =>
      !_webviewOpen &&
      !_reopeningWeb &&
      (_activeDevice != null || _userCode != null) &&
      (_awaitingUserAuth || !_busy);

  /// 等待授权时也允许切本地账号（会取消本轮 GitHub poll）。
  bool get _canEnterLocal => !_busy || _awaitingUserAuth;

  /// 系统浏览器备用：空闲可发起；等待授权时可打开同一次验证 URL。
  bool get _canOpenSystemBrowser => !_busy || _awaitingUserAuth;

  @override
  void initState() {
    super.initState();
    _syncFromAuthGate();
  }

  /// 冷启动 / 升级后：已授权未 Star → 直接显示 Star 引导（不进主壳）。
  void _syncFromAuthGate() {
    final auth = AuthRepository.instance;
    if (auth.accessState != AppAccessState.githubNeedStar) return;
    final u = auth.currentUser!;
    _needStar = true;
    _pendingToken = u.token;
    _pendingLogin = u.githubLogin;
    _step = _LoginStep.checkStar;
    _status = '请 Star 后继续';
  }

  @override
  void dispose() {
    _cancelled = true;
    _slowRequestTimer?.cancel();
    _disposeWebController();
    super.dispose();
  }

  void _disposeWebController() {
    _webController?.dispose();
    _webController = null;
    _webviewOpen = false;
  }

  void _armSlowHint() {
    _slowRequestTimer?.cancel();
    _showSlowHint = false;
    _slowRequestTimer = Timer(const Duration(seconds: 6), () {
      if (!mounted || !_busy || _step != _LoginStep.requestCode) return;
      setState(() => _showSlowHint = true);
    });
  }

  void _clearSlowHint() {
    _slowRequestTimer?.cancel();
    _slowRequestTimer = null;
    _showSlowHint = false;
  }

  void _cancelCurrentFlow() {
    _cancelled = true;
    _flowGen++;
    _clearSlowHint();
    if (_webviewOpen && mounted) {
      Navigator.of(context, rootNavigator: true).maybePop();
    }
    _disposeWebController();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _step = _LoginStep.idle;
      _status = null;
      _error = '已取消';
      _userCode = null;
      _verificationUri = null;
      _activeDevice = null;
    });
  }

  /// 关闭 Dialog ≠ 结束 Device Flow：清「已打开」锁，保留同轮码，poll 继续。
  void _onAuthDialogClosed() {
    debugPrint(
      'GitHub auth: dialog closed; keep session user_code=$_userCode '
      'webviewOpen→false',
    );
    // Dialog 内原生 WebView 已销毁；协调器一并丢掉，便于下次干净再开。
    _webController?.dispose();
    _webController = null;
    if (!mounted) return;
    setState(() {
      _webviewOpen = false;
      if (_awaitingUserAuth) {
        _status = '授权窗口已关闭，可点「打开授权页」继续（验证码不变）';
        _error = null;
      }
    });
  }

  Future<bool> _openEmbeddedAuth(String openUrl, String userCode) async {
    if (!mounted || !githubDeviceWebViewSupported()) return false;
    if (_webviewOpen && _webController != null) {
      _webController!.navigationLocked = false;
      _webController!.goToDeviceVerification(
        userCode,
        verificationUri: openUrl,
      );
      return true;
    }

    // 上次关闭后可能残留控制器：先清掉再新建，避免状态锁死。
    if (_webController != null) {
      _webController!.dispose();
      _webController = null;
    }

    final controller = GitHubDeviceWebViewController(
      initialUrl: openUrl,
      userCode: userCode,
      onAuthSucceeded: () {
        if (!mounted) return;
        setState(() {
          _status = '授权成功，正在确认…';
          _error = null;
        });
      },
      onRetryDeviceCode: () {
        unawaited(_startDeviceFlow());
      },
    );
    _webController = controller;
    controller.lastVerificationUri = openUrl;
    controller.navigationLocked = false;
    controller.phase.value = GitHubDeviceWebPhase.verifying;
    controller.statusMessage.value = '请在下方完成授权';
    final presented = await openGitHubDeviceAuthWebView(
      context: context,
      controller: controller,
      onClosed: _onAuthDialogClosed,
    );
    if (mounted) {
      setState(() {
        _webviewOpen = presented;
        if (presented && _awaitingUserAuth) {
          _status = '请在窗口内完成授权';
        }
      });
    }
    debugPrint(
      'GitHub auth: open embedded presented=$presented code=$userCode',
    );
    return presented;
  }

  /// 复用当前 device 会话再弹内嵌窗；无会话则重新申请设备码。
  Future<void> _reopenAuthSurface() async {
    if (_reopeningWeb || _webviewOpen) return;
    _reopeningWeb = true;
    try {
      final session = _activeDevice;
      var uri = session?.bestVerificationUri ?? _verificationUri;
      var code = session?.userCode ?? _userCode;

      if (uri == null || code == null) {
        debugPrint('GitHub auth: reopen without session → request new code');
        await _startDeviceFlow();
        return;
      }

      debugPrint('GitHub auth: reopen same session user_code=$code');
      if (mounted) {
        setState(() {
          _error = null;
          _status = '正在打开授权页…';
        });
      }
      final opened = await _openEmbeddedAuth(uri, code);
      if (!opened && mounted) {
        setState(() {
          _status = '无法打开内嵌授权页，请再试或点「重新登录」';
          _error = null;
        });
      }
    } finally {
      _reopeningWeb = false;
    }
  }

  /// 备用：用系统浏览器打开同一次 Device Flow 验证 URL；App 继续 poll。
  /// 尚无设备码时先申请再打开（不取消内嵌主路径能力）。
  Future<void> _openSystemBrowserAuth() async {
    if (_busy && !_awaitingUserAuth) return;

    final session = _activeDevice;
    final uri = session?.bestVerificationUri ?? _verificationUri;
    if (uri != null &&
        uri.isNotEmpty &&
        (session != null || (_userCode != null && _userCode!.isNotEmpty))) {
      debugPrint(
        'GitHub auth: system browser same session '
        'user_code=${session?.userCode ?? _userCode} url=$uri',
      );
      if (mounted) {
        setState(() {
          _error = null;
          _status = '正在打开系统浏览器…';
        });
      }
      final ok = await _oauth.openVerificationPage(uri);
      if (!mounted) return;
      setState(() {
        _status = ok ? '请在系统浏览器中完成授权' : '无法打开系统浏览器';
        _error = ok ? null : '请检查是否允许外部浏览器，或改用内嵌授权';
      });
      return;
    }

    debugPrint('GitHub auth: system browser without session → request code');
    await _startDeviceFlow(openSystemBrowser: true);
  }

  Future<void> _startDeviceFlow({bool openSystemBrowser = false}) async {
    _cancelled = true;
    final myGen = ++_flowGen;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    if (!mounted || myGen != _flowGen) return;

    if (_webviewOpen && mounted) {
      Navigator.of(context, rootNavigator: true).maybePop();
    }
    _disposeWebController();

    setState(() {
      _busy = true;
      _cancelled = false;
      _error = null;
      _step = _LoginStep.requestCode;
      _status = '正在连接…';
      _userCode = null;
      _verificationUri = null;
      _activeDevice = null;
      _needStar = false;
      _pendingToken = null;
      _pendingLogin = null;
      _showSlowHint = false;
    });
    _armSlowHint();

    try {
      if (!GitHubOAuthConfig.isConfigured) {
        throw const GitHubOAuthException(
          '未配置 GitHub Client ID',
          canRetry: false,
        );
      }

      // 本轮只申请一次；UI / WebView URL / poll 同源。
      final code = await _oauth.requestDeviceCode();
      if (!mounted || _cancelled || myGen != _flowGen) return;
      _clearSlowHint();

      final openUrl = code.bestVerificationUri;
      _activeDevice = code;
      setState(() {
        _userCode = code.userCode;
        _verificationUri = openUrl;
        _step = _LoginStep.awaitAuth;
        _status = '请在窗口内完成授权';
        _error = null;
      });

      debugPrint(
        'Device session gen=$myGen user_code=${code.userCode} openUrl=$openUrl',
      );

      final pollFuture = _oauth.pollAccessToken(
        code,
        shouldCancel: () => _cancelled || !mounted || myGen != _flowGen,
      );

      if (openSystemBrowser) {
        // 备用路径：同一次码用系统浏览器打开；poll 照旧。
        final ok = await _oauth.openVerificationPage(openUrl);
        if (myGen == _flowGen && mounted) {
          setState(() {
            _status = ok
                ? '请在系统浏览器中完成授权'
                : '无法打开系统浏览器，可点「打开授权页」用内嵌';
            _error = ok ? null : '请检查是否允许外部浏览器';
          });
        }
      } else {
        // 主路径：内嵌 WebView；关闭后可点「打开授权页」再开，不自动跳系统浏览器。
        final presented = await _openEmbeddedAuth(openUrl, code.userCode);
        if (!presented && myGen == _flowGen && mounted) {
          setState(() {
            _status = '请点「打开授权页」在内嵌窗口完成授权';
          });
        }
      }

      final token = await pollFuture;
      if (!mounted || _cancelled || myGen != _flowGen) return;

      if (_webviewOpen && mounted) {
        Navigator.of(context, rootNavigator: true).maybePop();
      }
      _disposeWebController();

      setState(() {
        _step = _LoginStep.checkStar;
        _status = '正在检查 Star…';
        _error = null;
      });
      await _finishWithToken(token);
      if (mounted && !_needStar && myGen == _flowGen) {
        setState(() => _step = _LoginStep.done);
      }
    } catch (e) {
      if (!mounted || _cancelled || myGen != _flowGen) return;
      _clearSlowHint();
      setState(() {
        _error = GitHubOAuthService.friendlyError(e);
        _status = null;
        if (_step == _LoginStep.requestCode) {
          _step = _LoginStep.idle;
        }
      });
    } finally {
      _clearSlowHint();
      if (mounted && myGen == _flowGen) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _finishWithToken(String token) async {
    final profile = await _oauth.fetchUser(token);

    // Star 检查失败时仍写入 token（已授权未 Star），绝不标为可进 App
    bool starred;
    try {
      starred = await _oauth.hasStarredRepo(token);
    } catch (e) {
      await AuthRepository.instance.loginWithGitHub(
        accessToken: token,
        profile: profile,
        starred: false,
      );
      if (!mounted) return;
      setState(() {
        _needStar = true;
        _pendingToken = token;
        _pendingLogin = profile.login;
        _step = _LoginStep.checkStar;
        _status = '请 Star 后点「我已 Star」';
        _error = GitHubOAuthService.friendlyError(e);
      });
      return;
    }

    await AuthRepository.instance.loginWithGitHub(
      accessToken: token,
      profile: profile,
      starred: starred,
    );

    if (!starred) {
      if (!mounted) return;
      setState(() {
        _needStar = true;
        _pendingToken = token;
        _pendingLogin = profile.login;
        _step = _LoginStep.checkStar;
        _status = '请 Star 后继续';
        _error = null;
      });
      return;
    }

    if (!mounted) return;
    setState(() {
      _needStar = false;
      _step = _LoginStep.done;
      _status = null;
      _error = null;
    });
    if (!widget.embedded && Navigator.of(context).canPop()) {
      Navigator.of(context).pop(true);
    }
  }

  /// 本地账号进入主壳（不要求 Star；助理不可用）。
  /// 等待 GitHub 授权时也可点：会取消本轮 poll，再 loginAsLocal。
  Future<void> _enterAsLocal() async {
    if (_busy && !_awaitingUserAuth) return;
    debugPrint('GitHub auth: enter as local (cancel device flow if any)');
    _cancelled = true;
    _flowGen++;
    _clearSlowHint();
    if (_webviewOpen && mounted) {
      Navigator.of(context, rootNavigator: true).maybePop();
    }
    _disposeWebController();
    setState(() {
      _busy = true;
      _error = null;
      _status = '正在进入本地账号…';
      _needStar = false;
      _userCode = null;
      _verificationUri = null;
      _activeDevice = null;
      _step = _LoginStep.idle;
    });
    try {
      await AuthRepository.instance.loginAsLocal();
      debugPrint('GitHub auth: loginAsLocal ok → canEnterShell='
          '${AuthRepository.instance.canEnterShell}');
      if (!mounted) return;
      // embedded 门禁靠 currentUserNotifier 切到 MainShell；非 embedded 则 pop。
      if (!widget.embedded && Navigator.of(context).canPop()) {
        Navigator.of(context).pop(true);
      }
    } catch (e, st) {
      debugPrint('GitHub auth: loginAsLocal failed: $e\n$st');
      if (!mounted) return;
      setState(() {
        _error = '无法进入本地账号';
        _status = null;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _recheckStar() async {
    final token =
        _pendingToken ?? AuthRepository.instance.currentUser?.token;
    if (token == null || token.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _status = '检查中…';
    });
    try {
      final starred = await _oauth.hasStarredRepo(token);
      if (!starred) {
        setState(() {
          _error = '仍未 Star，请 Star 后再试';
          _status = null;
        });
        return;
      }
      await _finishWithToken(token);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = GitHubOAuthService.friendlyError(e);
        _status = null;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Stack(
      fit: StackFit.expand,
      children: [
        const FrostedBackground(),
        Scaffold(
          backgroundColor: Colors.transparent,
          appBar: widget.embedded
              ? null
              : AppBar(
                  title: const Text('登录'),
                  backgroundColor: Colors.transparent,
                  surfaceTintColor: Colors.transparent,
                ),
          body: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (widget.embedded) ...[
                        const SizedBox(height: 24),
                        Text(
                          '希比 HIBI',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.headlineMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 20),
                      ],
                      Text(
                        'GitHub 登录',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _needStar
                            ? '还需 Star ${GitHubOAuthConfig.repoFullName}'
                            : '授权后需 Star ${GitHubOAuthConfig.repoFullName}',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 28),
                      if (!_needStar) ...[
                        _StepStrip(
                          step: _step,
                          needStar: _step == _LoginStep.checkStar,
                        ),
                        const SizedBox(height: 24),
                      ],
                      if (_userCode != null && !_needStar) ...[
                        SelectableText(
                          _userCode!,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.displaySmall?.copyWith(
                            letterSpacing: 4,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '网页未预填时可复制粘贴',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            TextButton.icon(
                              onPressed: () async {
                                final text = formatGitHubUserCode(_userCode);
                                await Clipboard.setData(
                                  ClipboardData(text: text),
                                );
                                if (!context.mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text('已复制 $text'),
                                    duration: const Duration(milliseconds: 1600),
                                  ),
                                );
                              },
                              icon: const Icon(Icons.copy, size: 16),
                              label: const Text('复制'),
                            ),
                            TextButton(
                              onPressed: _canOpenAuthPage
                                  ? _reopenAuthSurface
                                  : null,
                              child: Text(
                                _webviewOpen ? '授权页已打开' : '打开授权页',
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                      ],
                      if (_needStar) ...[
                        Text(
                          _pendingLogin == null
                              ? '请先 Star 仓库'
                              : '@$_pendingLogin 尚未 Star',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.titleMedium,
                        ),
                        const SizedBox(height: 12),
                        FilledButton.tonal(
                          onPressed:
                              _busy ? null : () => _oauth.openRepoForStar(),
                          child: const Text('去 Star'),
                        ),
                        const SizedBox(height: 8),
                        FilledButton(
                          onPressed: _busy ? null : _recheckStar,
                          child: const Text('我已 Star'),
                        ),
                        const SizedBox(height: 8),
                        TextButton(
                          onPressed: _busy ? null : _startDeviceFlow,
                          child: const Text('换账号登录'),
                        ),
                        const SizedBox(height: 16),
                      ],
                      if (_status != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Text(
                            _status!,
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: cs.primary,
                            ),
                          ),
                        ),
                      if (_error != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Text(
                            _error!,
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: cs.error,
                            ),
                          ),
                        ),
                      if (_busy && _step == _LoginStep.requestCode) ...[
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 12),
                          child: Center(child: CircularProgressIndicator()),
                        ),
                        if (_showSlowHint) ...[
                          Text(
                            '连接较慢，可取消后重试',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 8),
                          OutlinedButton(
                            onPressed: _cancelCurrentFlow,
                            child: const Text('取消'),
                          ),
                        ],
                      ] else if (_busy &&
                          _step != _LoginStep.awaitAuth &&
                          !_awaitingUserAuth)
                        // 等待用户授权时不转圈卡死：关掉 WebView 后应能点「打开授权页」。
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 12),
                          child: Center(child: CircularProgressIndicator()),
                        ),
                      // 初始页（连接）与后续步骤共用：系统浏览器始终夹在
                      // 「使用 GitHub 登录」与「本地账号进入」之间，不依赖已有设备码。
                      if (!_needStar) ...[
                        FilledButton(
                          onPressed: (_busy && !_awaitingUserAuth)
                              ? null
                              : _startDeviceFlow,
                          child: Text(
                            _error != null
                                ? '重试'
                                : (_userCode == null
                                    ? '使用 GitHub 登录'
                                    : '重新登录'),
                          ),
                        ),
                        const SizedBox(height: 10),
                        OutlinedButton(
                          onPressed: _canOpenSystemBrowser
                              ? _openSystemBrowserAuth
                              : null,
                          child: const Text('用系统浏览器登录'),
                        ),
                        const SizedBox(height: 10),
                        OutlinedButton(
                          onPressed: _canEnterLocal ? _enterAsLocal : null,
                          child: const Text('本地账号进入'),
                        ),
                        Text(
                          '本地可用思维/日程等；助理需 GitHub',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _StepStrip extends StatelessWidget {
  const _StepStrip({required this.step, required this.needStar});

  final _LoginStep step;
  final bool needStar;

  int get _activeIndex {
    switch (step) {
      case _LoginStep.idle:
        return -1;
      case _LoginStep.requestCode:
        return 0;
      case _LoginStep.awaitAuth:
        return 1;
      case _LoginStep.checkStar:
      case _LoginStep.done:
        return 2;
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final labels = ['连接', '授权', needStar ? 'Star' : '完成'];
    final active = _activeIndex;

    return Row(
      children: [
        for (var i = 0; i < labels.length; i++) ...[
          if (i > 0)
            Expanded(
              child: Container(
                height: 2,
                margin: const EdgeInsets.symmetric(horizontal: 4),
                color: i <= active ? cs.primary : cs.outlineVariant,
              ),
            ),
          _StepChip(
            index: i + 1,
            label: labels[i],
            state: i < active
                ? _ChipState.done
                : (i == active ? _ChipState.active : _ChipState.todo),
          ),
        ],
      ],
    );
  }
}

enum _ChipState { todo, active, done }

class _StepChip extends StatelessWidget {
  const _StepChip({
    required this.index,
    required this.label,
    required this.state,
  });

  final int index;
  final String label;
  final _ChipState state;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final Color bg;
    final Color fg;
    switch (state) {
      case _ChipState.done:
        bg = cs.primaryContainer;
        fg = cs.onPrimaryContainer;
      case _ChipState.active:
        bg = cs.primary;
        fg = cs.onPrimary;
      case _ChipState.todo:
        bg = cs.surfaceContainerHighest;
        fg = cs.onSurfaceVariant;
    }
    return Column(
      children: [
        CircleAvatar(
          radius: 14,
          backgroundColor: bg,
          child: state == _ChipState.done
              ? Icon(Icons.check, size: 16, color: fg)
              : Text(
                  '$index',
                  style: TextStyle(
                    color: fg,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: state == _ChipState.active
                    ? cs.primary
                    : cs.onSurfaceVariant,
                fontWeight: state == _ChipState.active
                    ? FontWeight.w700
                    : FontWeight.w500,
              ),
        ),
      ],
    );
  }
}
