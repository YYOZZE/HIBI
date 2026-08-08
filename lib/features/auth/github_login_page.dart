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

/// GitHub Device Flow 登录 + 必须 Star 仓库门禁页。
class GitHubLoginPage extends StatefulWidget {
  const GitHubLoginPage({super.key, this.embedded = false});

  /// 作为启动门禁嵌入时为 true（无返回按钮）。
  final bool embedded;

  @override
  State<GitHubLoginPage> createState() => _GitHubLoginPageState();
}

class _GitHubLoginPageState extends State<GitHubLoginPage> {
  final _oauth = GitHubOAuthService.instance;

  bool _busy = false;
  bool _cancelled = false;
  String? _userCode;
  String? _verificationUri;
  String? _error;
  String? _status;
  bool _needStar = false;
  String? _pendingToken;
  String? _pendingLogin;
  _LoginStep _step = _LoginStep.idle;
  bool _webviewOpen = false;
  bool _lastErrorNetwork = false;
  GitHubDeviceWebViewController? _webController;

  @override
  void initState() {
    super.initState();
    // 本地已有 GitHub 会话但未过 Star：只引导 Star，勿再走网页输密码。
    final u = AuthRepository.instance.currentUser;
    if (u != null &&
        u.isGitHub &&
        u.token.isNotEmpty &&
        !AuthRepository.instance.githubAccessGrantedNotifier.value) {
      _needStar = true;
      _pendingToken = u.token;
      _pendingLogin = u.githubLogin;
      _step = _LoginStep.checkStar;
      _status = '已恢复本地登录。请 Star 仓库后点「我已 Star」继续（无需再输入密码）。';
    }
  }

  @override
  void dispose() {
    _cancelled = true;
    _disposeWebController();
    super.dispose();
  }

  void _disposeWebController() {
    _webController?.dispose();
    _webController = null;
    _webviewOpen = false;
  }

  void _onWebAuthSucceeded() {
    if (!mounted) return;
    setState(() {
      _status = '已检测到 GitHub 授权成功，正在确认并继续…';
      _error = null;
    });
  }

  /// 尽快打开内嵌登录页（账号密码框在 GitHub 网页），与申请设备码并行。
  Future<bool> _ensureWebViewOpen({String? initialUrl}) async {
    if (!mounted) return false;
    if (_webviewOpen && _webController != null) {
      if (initialUrl != null) {
        _webController!.navigateTo(initialUrl, force: true);
      }
      return true;
    }
    if (!githubDeviceWebViewSupported()) return false;

    // 复用尚未关闭的控制器；否则新建。登录流程结束前不 dispose，
    // 以便申请码返回后仍能跳转验证页；授权成功后由 WebView 自行关窗。
    final controller = _webController ??
        GitHubDeviceWebViewController(
          initialUrl: initialUrl ?? kGitHubLoginUrl,
          userCode: _userCode,
          onAuthSucceeded: _onWebAuthSucceeded,
        );
    _webController = controller;
    if (initialUrl != null) controller.navigateTo(initialUrl, force: true);

    final presented = await openGitHubDeviceAuthWebView(
      context: context,
      controller: controller,
      onClosed: () {
        if (mounted) setState(() => _webviewOpen = false);
      },
    );
    if (mounted) setState(() => _webviewOpen = presented);
    return presented;
  }

  Future<void> _openSystemBrowserFallback() async {
    final uri = _verificationUri ?? kGitHubLoginUrl;
    await _oauth.openVerificationPage(uri);
    if (!mounted) return;
    setState(() {
      _status = _verificationUri == null
          ? '已在系统浏览器打开 GitHub 登录页。请登录后回到本 App 点「重试登录」完成授权。'
          : '已打开系统浏览器。请在 GitHub 网页登录、输入验证码并授权；完成后回到本 App。';
    });
  }

  Future<void> _startDeviceFlow() async {
    if (_busy) return;
    // 重新开始：关掉旧内嵌页，避免沿用已标记成功的控制器。
    if (_webviewOpen && mounted) {
      Navigator.of(context, rootNavigator: true).maybePop();
    }
    _disposeWebController();
    setState(() {
      _busy = true;
      _cancelled = false;
      _error = null;
      _lastErrorNetwork = false;
      _step = _LoginStep.requestCode;
      _status = '正在打开 GitHub 登录页，并申请设备码…';
      _userCode = null;
      _verificationUri = null;
      _needStar = false;
      _pendingToken = null;
      _pendingLogin = null;
    });
    try {
      if (!GitHubOAuthConfig.isConfigured) {
        throw const GitHubOAuthException(
          '未配置 GITHUB_CLIENT_ID。请在 GitHub 创建 OAuth App（务必启用 Device Flow），'
          '然后填写 lib/config/github_oauth_config.dart 或使用 '
          '--dart-define=GITHUB_CLIENT_ID=... 构建。',
          canRetry: false,
        );
      }

      // UX：先开内嵌 WebView 到登录页，用户立刻看到账号密码框；
      // Device Flow 申请码与之并行，避免「只见失败、不见登录页」。
      var presented = false;
      if (mounted && githubDeviceWebViewSupported()) {
        presented = await _ensureWebViewOpen(initialUrl: kGitHubLoginUrl);
      }
      if (!presented) {
        // 内嵌不可用时立刻外开登录页，仍尽量让用户到达密码框。
        await _oauth.openVerificationPage(kGitHubLoginUrl);
        if (mounted) {
          setState(() {
            _status = '已在系统浏览器打开 GitHub 登录页；正在申请设备码…';
          });
        }
      } else if (mounted) {
        setState(() {
          _status = '请在网页输入 GitHub 账号密码；同时正在申请设备码…';
        });
      }

      final code = await _oauth.requestDeviceCode();
      if (!mounted || _cancelled) return;

      setState(() {
        _userCode = code.userCode;
        _verificationUri = code.bestVerificationUri;
        _step = _LoginStep.awaitAuth;
        _status =
            '验证码已自动填入验证页。请登录（如需）并点 Authorize；完成后会自动继续。';
      });

      // 码一到手立刻跳到带 user_code 的验证页（勿停在裸 login）。
      _webController?.goToDeviceVerification(
        code.userCode,
        verificationUri: code.bestVerificationUri,
      );

      final pollFuture = _oauth.pollAccessToken(
        code,
        shouldCancel: () => _cancelled || !mounted,
      );

      // 若此前未能打开内嵌页，再试一次验证页；仍失败则外开。
      if (!presented && mounted && githubDeviceWebViewSupported()) {
        presented = await _ensureWebViewOpen(
          initialUrl: code.bestVerificationUri,
        );
        _webController?.goToDeviceVerification(
          code.userCode,
          verificationUri: code.bestVerificationUri,
        );
        if (mounted) setState(() => _webviewOpen = presented);
      }
      if (!presented) {
        await _oauth.openVerificationPage(code.bestVerificationUri);
        if (mounted) {
          setState(() {
            _status =
                '已打开系统浏览器（验证码已在链接中预填）。请登录并点 Authorize；完成后回到本 App。';
          });
        }
      }

      final token = await pollFuture;
      if (!mounted || _cancelled) return;

      // 授权成功：关闭仍打开的内嵌登录页，进入 Star 检查。
      if (_webviewOpen && mounted) {
        Navigator.of(context, rootNavigator: true).maybePop();
      }
      _disposeWebController();

      setState(() {
        _step = _LoginStep.checkStar;
        _status = '授权成功，正在检查是否已 Star 仓库…';
        _error = null;
      });
      await _finishWithToken(token);
      if (mounted && !_needStar) {
        setState(() => _step = _LoginStep.done);
      }
    } catch (e) {
      if (!mounted || _cancelled) return;
      setState(() {
        _error = GitHubOAuthService.friendlyError(e);
        _lastErrorNetwork = GitHubOAuthService.isNetworkError(e);
        _status = null;
        if (_step == _LoginStep.requestCode) {
          _step = _LoginStep.idle;
        }
      });
      // 网络失败时仍尽量让用户到达 GitHub 登录页（WebView 可能已开；否则外开）。
      if (_lastErrorNetwork && !_webviewOpen) {
        await _openSystemBrowserFallback();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reopenAuthSurface() async {
    final code = _userCode;
    final uri = code == null
        ? (_verificationUri ?? kGitHubLoginUrl)
        : githubDeviceVerificationUri(
            userCode: code,
            baseUri: _verificationUri ?? kGitHubDeviceUrl,
          );
    if (_webviewOpen && _webController != null) {
      if (code != null) {
        _webController!.goToDeviceVerification(code, verificationUri: uri);
      } else {
        _webController!.navigateTo(uri, force: true);
      }
      return;
    }
    final opened = await showGitHubDeviceAuthWebView(
      context: context,
      verificationUri: uri,
      userCode: code ?? '——',
    );
    if (!opened) {
      await _oauth.openVerificationPage(uri);
    }
  }

  Future<void> _finishWithToken(String token) async {
    final profile = await _oauth.fetchUser(token);
    final starred = await _oauth.hasStarredRepo(token);
    if (!starred) {
      if (!mounted) return;
      setState(() {
        _needStar = true;
        _pendingToken = token;
        _pendingLogin = profile.login;
        _step = _LoginStep.checkStar;
        _status = '请先 Star 仓库 ${GitHubOAuthConfig.repoFullName} 后再继续';
        _error = null;
      });
      return;
    }
    await AuthRepository.instance.loginWithGitHub(
      accessToken: token,
      profile: profile,
      starred: true,
    );
    if (!mounted) return;
    if (!widget.embedded && Navigator.of(context).canPop()) {
      Navigator.of(context).pop(true);
    }
  }

  Future<void> _recheckStar() async {
    final token = _pendingToken;
    if (token == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _step = _LoginStep.checkStar;
      _status = '正在重新检查 Star…';
    });
    try {
      final starred = await _oauth.hasStarredRepo(token);
      if (!starred) {
        setState(() {
          _error = '仍未检测到 Star。请打开仓库页面点击 Star 后重试。';
          _status = null;
        });
        return;
      }
      await _finishWithToken(token);
      if (mounted) setState(() => _step = _LoginStep.done);
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
                  title: const Text('GitHub 登录'),
                  backgroundColor: Colors.transparent,
                  surfaceTintColor: Colors.transparent,
                ),
          body: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (widget.embedded) ...[
                        const SizedBox(height: 16),
                        Text(
                          '希比 HIBI',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.headlineMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 8),
                      ],
                      Text(
                        '用 GitHub 账号登录',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        '点「使用 GitHub 登录」后，会在 App 内打开 GitHub 网页；'
                        '请在网页输入账号密码并授权。希比不会收集你的 GitHub 密码。',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: cs.onSurfaceVariant,
                          height: 1.35,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '登录一次后，授权信息会保存在本机；升级 App 一般无需再输入密码'
                        '（除非授权过期、你撤销了授权，或取消了仓库 Star）。',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant,
                          height: 1.35,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '仓库：${GitHubOAuthConfig.repoFullName}（需 Star 后才能使用）',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.labelLarge,
                      ),
                      const SizedBox(height: 20),
                      _StepStrip(step: _step, needStar: _needStar || _step == _LoginStep.checkStar),
                      const SizedBox(height: 20),
                      if (_userCode != null) ...[
                        Container(
                          padding: const EdgeInsets.symmetric(
                            vertical: 16,
                            horizontal: 12,
                          ),
                          decoration: BoxDecoration(
                            color: cs.surfaceContainerHighest.withOpacity(0.55),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Column(
                            children: [
                              Text('设备验证码', style: theme.textTheme.titleSmall),
                              const SizedBox(height: 8),
                              SelectableText(
                                _userCode!,
                                textAlign: TextAlign.center,
                                style: theme.textTheme.displaySmall?.copyWith(
                                  letterSpacing: 4,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '用于把本次网页授权绑定到本 App；一般已自动填入，无需手抄。'
                                '若网页未预填，可点下方复制后粘贴。',
                                textAlign: TextAlign.center,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: cs.onSurfaceVariant,
                                ),
                              ),
                              const SizedBox(height: 12),
                              Wrap(
                                alignment: WrapAlignment.center,
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  OutlinedButton.icon(
                                    onPressed: () async {
                                      await Clipboard.setData(
                                        ClipboardData(text: _userCode!),
                                      );
                                      if (!context.mounted) return;
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(content: Text('验证码已复制')),
                                      );
                                    },
                                    icon: const Icon(Icons.copy, size: 18),
                                    label: const Text('复制验证码'),
                                  ),
                                  OutlinedButton.icon(
                                    onPressed: _verificationUri == null
                                        ? null
                                        : _reopenAuthSurface,
                                    icon: const Icon(Icons.web, size: 18),
                                    label: const Text('打开登录页'),
                                  ),
                                  OutlinedButton.icon(
                                    onPressed: _verificationUri == null
                                        ? null
                                        : () => _oauth.openVerificationPage(
                                              _verificationUri!,
                                            ),
                                    icon: const Icon(Icons.open_in_browser, size: 18),
                                    label: const Text('系统浏览器'),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],
                      if (_needStar) ...[
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Text(
                                  '还需 Star 仓库',
                                  style: theme.textTheme.titleMedium,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  _pendingLogin == null
                                      ? '请为 ${GitHubOAuthConfig.repoFullName} 点 Star，然后点「我已 Star」。'
                                      : '账号 @$_pendingLogin 尚未 Star '
                                          '${GitHubOAuthConfig.repoFullName}。\n'
                                          '未 Star 无法使用本应用。',
                                  style: theme.textTheme.bodyMedium,
                                ),
                                const SizedBox(height: 12),
                                FilledButton.tonalIcon(
                                  onPressed: _busy
                                      ? null
                                      : () => _oauth.openRepoForStar(),
                                  icon: const Icon(Icons.star_border),
                                  label: const Text('打开仓库去 Star'),
                                ),
                                const SizedBox(height: 8),
                                FilledButton.icon(
                                  onPressed: _busy ? null : _recheckStar,
                                  icon: const Icon(Icons.refresh),
                                  label: const Text('我已 Star，重新检查'),
                                ),
                              ],
                            ),
                          ),
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
                          child: Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: cs.errorContainer.withOpacity(0.55),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              _error!,
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: cs.onErrorContainer,
                              ),
                            ),
                          ),
                        ),
                      if (_busy)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 16),
                          child: Center(child: CircularProgressIndicator()),
                        ),
                      if (!_needStar)
                        FilledButton.icon(
                          onPressed: _busy ? null : _startDeviceFlow,
                          icon: const Icon(Icons.login),
                          label: Text(
                            _userCode == null
                                ? '使用 GitHub 登录'
                                : (_error != null ? '重试登录' : '重新开始登录'),
                          ),
                        ),
                      if (_error != null && !_needStar) ...[
                        const SizedBox(height: 8),
                        OutlinedButton.icon(
                          onPressed: _busy ? null : _openSystemBrowserFallback,
                          icon: const Icon(Icons.open_in_browser),
                          label: const Text('在系统浏览器打开 GitHub'),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _lastErrorNetwork
                              ? '提示：需能访问 github.com / api.github.com。'
                                  '出现超时或 semaphore timeout 时，请检查代理/VPN，'
                                  '或先用上方按钮在系统浏览器打开登录页。'
                              : '提示：登录需能访问 github.com。若长期失败，请检查网络或 OAuth App 是否启用 Device Flow。',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                      const SizedBox(height: 16),
                      Text(
                        '正确流程：点登录 → 在 App 内（或系统浏览器）打开的 GitHub 网页输入账号密码并授权 → '
                        '回到希比继续 → Star 仓库后即可使用。\n'
                        '本应用无自建账号服务器：身份即你的 GitHub 账号；数据默认保存在本机。',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant,
                          height: 1.4,
                        ),
                      ),
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
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final labels = ['申请设备码', '网页授权', needStar ? '检查 Star' : '检查 Star'];
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
                color: state == _ChipState.active ? cs.primary : cs.onSurfaceVariant,
                fontWeight:
                    state == _ChipState.active ? FontWeight.w700 : FontWeight.w500,
              ),
        ),
      ],
    );
  }
}
