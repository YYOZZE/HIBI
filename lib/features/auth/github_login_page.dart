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

  @override
  void dispose() {
    _cancelled = true;
    super.dispose();
  }

  Future<void> _startDeviceFlow() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _cancelled = false;
      _error = null;
      _step = _LoginStep.requestCode;
      _status = '正在向 GitHub 申请设备码…';
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

      final code = await _oauth.requestDeviceCode();
      if (!mounted || _cancelled) return;

      setState(() {
        _userCode = code.userCode;
        _verificationUri = code.bestVerificationUri;
        _step = _LoginStep.awaitAuth;
        _status = '请在网页用 GitHub 账号登录并授权（密码只在 GitHub 网站输入）';
      });

      final pollFuture = _oauth.pollAccessToken(
        code,
        shouldCancel: () => _cancelled || !mounted,
      );

      // 优先内嵌 WebView（不阻塞轮询）；失败则外跳系统浏览器。
      var presented = false;
      if (mounted && githubDeviceWebViewSupported()) {
        presented = await openGitHubDeviceAuthWebView(
          context: context,
          verificationUri: code.bestVerificationUri,
          userCode: code.userCode,
          onClosed: () {
            if (mounted) setState(() => _webviewOpen = false);
          },
        );
        if (mounted) setState(() => _webviewOpen = presented);
      }
      if (!presented) {
        await _oauth.openVerificationPage(code.bestVerificationUri);
        if (mounted) {
          setState(() {
            _status =
                '已打开系统浏览器。请在 GitHub 网页登录、输入验证码并授权；完成后回到本 App。';
          });
        }
      }

      final token = await pollFuture;
      if (!mounted || _cancelled) return;

      // 授权成功：关闭仍打开的内嵌登录页。
      if (_webviewOpen) {
        Navigator.of(context, rootNavigator: true).maybePop();
        _webviewOpen = false;
      }

      setState(() {
        _step = _LoginStep.checkStar;
        _status = '授权成功，正在检查是否已 Star 仓库…';
      });
      await _finishWithToken(token);
      if (mounted && !_needStar) {
        setState(() => _step = _LoginStep.done);
      }
    } catch (e) {
      if (!mounted || _cancelled) return;
      setState(() {
        _error = GitHubOAuthService.friendlyError(e);
        _status = null;
        if (_step == _LoginStep.requestCode) {
          _step = _LoginStep.idle;
        }
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reopenAuthSurface() async {
    final uri = _verificationUri;
    final code = _userCode;
    if (uri == null || code == null) return;
    final opened = await showGitHubDeviceAuthWebView(
      context: context,
      verificationUri: uri,
      userCode: code,
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
                                '若网页未自动填入，请把此码粘贴到 GitHub 验证页',
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
                        Text(
                          '提示：登录需能访问 github.com。若长期超时，请检查网络后重试。',
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
