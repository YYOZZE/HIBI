import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_windows/webview_windows.dart' as win_wv;

/// 桌面 Chrome UA，降低 GitHub 对 WebView 默认 UA 的拦截概率。
const String _kDesktopChromeUa =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

const String _kAndroidChromeUa =
    'Mozilla/5.0 (Linux; Android 13; Mobile) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36';

const String _kIosSafariUa =
    'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
    'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 '
    'Mobile/15E148 Safari/604.1';

/// 是否支持内嵌 WebView 打开 GitHub Device Flow 验证页。
bool githubDeviceWebViewSupported() =>
    Platform.isWindows || Platform.isAndroid || Platform.isIOS;

/// 打开内嵌 GitHub Device Flow 验证页（方案 B），**不阻塞**调用方。
///
/// - 用户在 GitHub 网页输入账号密码，App 不读取表单。
/// - 外层应继续轮询 token；拿到 token 后对 rootNavigator `maybePop()` 即可关闭本对话框。
/// - 返回 `true` 表示已弹出内嵌页；`false` 表示不支持/无法展示，调用方应外跳系统浏览器。
Future<bool> openGitHubDeviceAuthWebView({
  required BuildContext context,
  required String verificationUri,
  required String userCode,
  VoidCallback? onClosed,
}) async {
  if (!githubDeviceWebViewSupported() || !context.mounted) {
    return false;
  }

  final navigator = Navigator.of(context, rootNavigator: true);

  try {
    if (Platform.isWindows) {
      unawaited(
        showDialog<void>(
          context: context,
          useRootNavigator: true,
          barrierDismissible: false,
          builder: (ctx) => _WindowsGitHubAuthDialog(
            verificationUri: verificationUri,
            userCode: userCode,
          ),
        ).whenComplete(() => onClosed?.call()),
      );
      return true;
    }
    if (Platform.isAndroid || Platform.isIOS) {
      unawaited(
        showDialog<void>(
          context: context,
          useRootNavigator: true,
          barrierDismissible: false,
          builder: (ctx) => _MobileGitHubAuthDialog(
            verificationUri: verificationUri,
            userCode: userCode,
          ),
        ).whenComplete(() => onClosed?.call()),
      );
      return true;
    }
  } catch (e, st) {
    debugPrint('GitHub Device WebView 打开失败: $e\n$st');
    onClosed?.call();
    return false;
  }

  // 未命中平台时清理（理论上不会到这）。
  if (navigator.canPop()) {
    // no-op
  }
  return false;
}

/// 兼容旧调用名：弹出并等待关闭（仅用于「再次打开」按钮）。
Future<bool> showGitHubDeviceAuthWebView({
  required BuildContext context,
  required String verificationUri,
  required String userCode,
}) async {
  if (!githubDeviceWebViewSupported() || !context.mounted) {
    return false;
  }
  try {
    if (Platform.isWindows) {
      await showDialog<void>(
        context: context,
        useRootNavigator: true,
        barrierDismissible: false,
        builder: (ctx) => _WindowsGitHubAuthDialog(
          verificationUri: verificationUri,
          userCode: userCode,
        ),
      );
      return true;
    }
    if (Platform.isAndroid || Platform.isIOS) {
      await showDialog<void>(
        context: context,
        useRootNavigator: true,
        barrierDismissible: false,
        builder: (ctx) => _MobileGitHubAuthDialog(
          verificationUri: verificationUri,
          userCode: userCode,
        ),
      );
      return true;
    }
  } catch (e, st) {
    debugPrint('GitHub Device WebView 打开失败: $e\n$st');
    return false;
  }
  return false;
}

Future<void> _openExternal(String uri) async {
  final parsed = Uri.tryParse(uri);
  if (parsed == null) return;
  await launchUrl(parsed, mode: LaunchMode.externalApplication);
}

Widget _authChrome({
  required BuildContext context,
  required String userCode,
  required String verificationUri,
  required Widget body,
  VoidCallback? onRetryLoad,
}) {
  final theme = Theme.of(context);
  final cs = theme.colorScheme;
  final mq = MediaQuery.of(context);
  final maxH = (mq.size.height * 0.88).clamp(420.0, 900.0);
  final maxW = (mq.size.width * 0.96).clamp(320.0, 960.0);

  return Dialog(
    insetPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
    clipBehavior: Clip.antiAlias,
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxW, maxHeight: maxH),
      child: Column(
        children: [
          Material(
            color: cs.surfaceContainerHighest.withOpacity(0.65),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '在 GitHub 网页登录并授权',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: '关闭',
                        onPressed: () => Navigator.of(context).maybePop(),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                  Text(
                    '请在下方页面使用 GitHub 账号密码登录（密码只在 GitHub 网站输入，希比不会收集）。'
                    '授权完成后此窗口会自动关闭，或可手动关闭。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Text('验证码', style: theme.textTheme.labelMedium),
                      const SizedBox(width: 8),
                      Expanded(
                        child: SelectableText(
                          userCode,
                          style: theme.textTheme.titleLarge?.copyWith(
                            letterSpacing: 2,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () async {
                          await Clipboard.setData(ClipboardData(text: userCode));
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('验证码已复制')),
                          );
                        },
                        icon: const Icon(Icons.copy, size: 16),
                        label: const Text('复制'),
                      ),
                      TextButton.icon(
                        onPressed: () => _openExternal(verificationUri),
                        icon: const Icon(Icons.open_in_browser, size: 16),
                        label: const Text('系统浏览器'),
                      ),
                      if (onRetryLoad != null)
                        IconButton(
                          tooltip: '重新加载',
                          onPressed: onRetryLoad,
                          icon: const Icon(Icons.refresh),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          Expanded(child: body),
        ],
      ),
    ),
  );
}

class _MobileGitHubAuthDialog extends StatefulWidget {
  const _MobileGitHubAuthDialog({
    required this.verificationUri,
    required this.userCode,
  });

  final String verificationUri;
  final String userCode;

  @override
  State<_MobileGitHubAuthDialog> createState() => _MobileGitHubAuthDialogState();
}

class _MobileGitHubAuthDialogState extends State<_MobileGitHubAuthDialog> {
  late final WebViewController _controller;
  var _loading = true;
  String? _blockHint;

  @override
  void initState() {
    super.initState();
    final ua = Platform.isIOS ? _kIosSafariUa : _kAndroidChromeUa;
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(ua)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) {
            if (mounted) setState(() => _loading = true);
          },
          onPageFinished: (url) async {
            if (!mounted) return;
            setState(() => _loading = false);
            await _probeUnsupportedBrowser();
          },
          onWebResourceError: (err) {
            if (!mounted) return;
            setState(() {
              _loading = false;
              _blockHint =
                  '页面加载失败（${err.description}）。可点「系统浏览器」在外部完成登录。';
            });
          },
        ),
      );
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _blockHint = null;
    });
    await _controller.loadRequest(Uri.parse(widget.verificationUri));
  }

  Future<void> _probeUnsupportedBrowser() async {
    try {
      final raw = await _controller.runJavaScriptReturningResult(
        '(function(){var t=(document.body&&document.body.innerText)||""; '
        'return /unsupported browser|browser is not supported|不支持的浏览器/i.test(t) '
        '? "blocked" : "ok";})()',
      );
      final s = raw.toString().toLowerCase();
      if (s.contains('blocked') && mounted) {
        setState(() {
          _blockHint =
              'GitHub 可能限制了内嵌浏览器。请点右上角「系统浏览器」完成登录与授权。';
        });
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return _authChrome(
      context: context,
      userCode: widget.userCode,
      verificationUri: widget.verificationUri,
      onRetryLoad: _load,
      body: Stack(
        fit: StackFit.expand,
        children: [
          WebViewWidget(controller: _controller),
          if (_loading)
            const Align(
              alignment: Alignment.topCenter,
              child: LinearProgressIndicator(minHeight: 2),
            ),
          if (_blockHint != null)
            Align(
              alignment: Alignment.bottomCenter,
              child: Material(
                color: Theme.of(context).colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          _blockHint!,
                          style: TextStyle(
                            color:
                                Theme.of(context).colorScheme.onErrorContainer,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: () => _openExternal(widget.verificationUri),
                        child: const Text('外开'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _WindowsGitHubAuthDialog extends StatefulWidget {
  const _WindowsGitHubAuthDialog({
    required this.verificationUri,
    required this.userCode,
  });

  final String verificationUri;
  final String userCode;

  @override
  State<_WindowsGitHubAuthDialog> createState() =>
      _WindowsGitHubAuthDialogState();
}

class _WindowsGitHubAuthDialogState extends State<_WindowsGitHubAuthDialog> {
  final _controller = win_wv.WebviewController();
  var _ready = false;
  var _loading = true;
  String? _error;
  String? _blockHint;
  StreamSubscription<String>? _urlSub;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      await _controller.initialize();
      await _controller
          .setPopupWindowPolicy(win_wv.WebviewPopupWindowPolicy.sameWindow);
      try {
        await _controller.setUserAgent(_kDesktopChromeUa);
      } catch (e) {
        debugPrint('GitHub WebView setUserAgent 跳过: $e');
      }
      _urlSub = _controller.url.listen((url) {
        if (!mounted) return;
        setState(() => _loading = false);
        _probeUnsupportedFromUrl(url);
      });
      if (!mounted) return;
      setState(() {
        _ready = true;
        _error = null;
      });
      await Future<void>.delayed(const Duration(milliseconds: 280));
      if (!mounted) return;
      await _controller.loadUrl(widget.verificationUri);
    } catch (e, st) {
      debugPrint('Windows GitHub WebView 初始化失败: $e\n$st');
      if (!mounted) return;
      setState(() {
        _error =
            '内嵌浏览器无法启动（$e）。请改用「系统浏览器」完成 GitHub 登录。';
        _ready = false;
        _loading = false;
      });
    }
  }

  void _probeUnsupportedFromUrl(String url) {
    final lower = url.toLowerCase();
    if (lower.contains('unsupported') || lower.contains('error')) {
      setState(() {
        _blockHint =
            '若页面提示不支持当前浏览器，请改用「系统浏览器」完成授权。';
      });
    }
  }

  Future<void> _reload() async {
    if (!_ready) {
      await _init();
      return;
    }
    setState(() {
      _loading = true;
      _blockHint = null;
    });
    try {
      await _controller.loadUrl(widget.verificationUri);
    } catch (e) {
      setState(() => _error = '重新加载失败：$e');
    }
  }

  @override
  void dispose() {
    _urlSub?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    Widget body;
    if (_error != null) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () => _openExternal(widget.verificationUri),
                icon: const Icon(Icons.open_in_browser),
                label: const Text('用系统浏览器打开'),
              ),
              const SizedBox(height: 8),
              TextButton(onPressed: _reload, child: const Text('重试内嵌浏览器')),
            ],
          ),
        ),
      );
    } else if (!_ready) {
      body = const Center(child: CircularProgressIndicator());
    } else {
      body = Stack(
        fit: StackFit.expand,
        children: [
          win_wv.Webview(_controller),
          if (_loading)
            const Align(
              alignment: Alignment.topCenter,
              child: LinearProgressIndicator(minHeight: 2),
            ),
          if (_blockHint != null)
            Align(
              alignment: Alignment.bottomCenter,
              child: Material(
                color: cs.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          _blockHint!,
                          style: TextStyle(color: cs.onErrorContainer),
                        ),
                      ),
                      TextButton(
                        onPressed: () =>
                            _openExternal(widget.verificationUri),
                        child: const Text('外开'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      );
    }

    return _authChrome(
      context: context,
      userCode: widget.userCode,
      verificationUri: widget.verificationUri,
      onRetryLoad: _reload,
      body: body,
    );
  }
}
