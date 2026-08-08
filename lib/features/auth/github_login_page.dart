import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/frosted_background.dart';
import '../../config/github_oauth_config.dart';
import 'services/auth_repository.dart';
import 'services/github_oauth_service.dart';

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
      _status = '正在向 GitHub 申请设备码…';
      _userCode = null;
      _needStar = false;
      _pendingToken = null;
      _pendingLogin = null;
    });
    try {
      if (!GitHubOAuthConfig.isConfigured) {
        throw StateError(
          '未配置 GITHUB_CLIENT_ID。请在 GitHub 创建 OAuth App（启用 Device Flow），'
          '然后用 --dart-define=GITHUB_CLIENT_ID=... 构建，'
          '或填写 lib/config/github_oauth_config.dart。',
        );
      }
      final code = await _oauth.requestDeviceCode();
      if (!mounted) return;
      setState(() {
        _userCode = code.userCode;
        _verificationUri = code.verificationUri;
        _status = '请在浏览器打开验证页，输入下方代码并授权';
      });
      await _oauth.openVerificationPage(code.verificationUri);
      final token = await _oauth.pollAccessToken(
        code,
        shouldCancel: () => _cancelled || !mounted,
      );
      if (!mounted) return;
      setState(() => _status = '授权成功，正在校验仓库 Star…');
      await _finishWithToken(token);
    } catch (e) {
      if (!mounted || _cancelled) return;
      setState(() {
        _error = e.toString().replaceFirst('Bad state: ', '');
        _status = null;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
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
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceFirst('Bad state: ', '');
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
                        const SizedBox(height: 8),
                        Text(
                          '使用 GitHub 账号登录，并 Star 本项目后即可使用',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 28),
                      ],
                      Text(
                        '仓库：${GitHubOAuthConfig.repoFullName}',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.labelLarge,
                      ),
                      const SizedBox(height: 20),
                      if (_userCode != null) ...[
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
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
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
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: _verificationUri == null
                                    ? null
                                    : () => _oauth.openVerificationPage(
                                          _verificationUri!,
                                        ),
                                icon: const Icon(Icons.open_in_browser, size: 18),
                                label: const Text('打开验证页'),
                              ),
                            ),
                          ],
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
                          child: Text(
                            _error!,
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: cs.error,
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
                            _userCode == null ? '使用 GitHub 登录' : '重新开始登录',
                          ),
                        ),
                      const SizedBox(height: 12),
                      Text(
                        '本应用无自建账号服务器：身份即你的 GitHub 账号；'
                        '数据默认保存在本机。',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant,
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
