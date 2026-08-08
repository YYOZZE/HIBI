import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_windows/webview_windows.dart' as win_wv;

import '../services/github_oauth_service.dart';

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

/// 点「使用 GitHub 登录」后立刻打开的页面（含账号密码框）。
const String kGitHubLoginUrl = 'https://github.com/login';

/// Device Flow 验证页（有码后导航至此；请用 [githubDeviceVerificationUri] 带上 user_code）。
const String kGitHubDeviceUrl = 'https://github.com/login/device';

bool _looksLikeDeviceAuthSuccess({String? url, String? title, String? body}) {
  final blob = '${url ?? ''} ${title ?? ''} ${body ?? ''}'.toLowerCase();
  // 勿把 /login/oauth/authorize（Authorize 页本身）当成成功。
  if (blob.contains('congratulations') ||
      blob.contains("you're all set") ||
      blob.contains('you are all set') ||
      blob.contains('device is now connected') ||
      blob.contains('your device is now connected') ||
      blob.contains('授权成功')) {
    return true;
  }
  final u = (url ?? '').toLowerCase();
  return u.contains('/login/device/success') ||
      u.contains('device_authorization_complete');
}

String _jsProbeAuthOutcome(String? userCode) {
  final codeLiteral = (userCode ?? '')
      .replaceAll('\\', '\\\\')
      .replaceAll("'", "\\'");
  return '''
(function(){
  try {
    var code = '$codeLiteral';
    var t = ((document.title || '') + ' ' +
      ((document.body && (document.body.innerText || document.body.textContent)) || ''))
      .toLowerCase();
    if (/congratulations|you.?re all set|device is now connected|授权成功|已连接/.test(t)) {
      return 'success';
    }
    if (code) {
      var input = document.querySelector(
        'input[name="user_code"], input#user-code, input[autocomplete="one-time-code"], input[name="code"]'
      );
      if (input) {
        var cur = (input.value || '').replace(/\\s+/g, '').toUpperCase();
        var want = code.replace(/\\s+/g, '').toUpperCase();
        if (!cur || cur !== want) {
          input.focus();
          input.value = code;
          input.dispatchEvent(new Event('input', {bubbles:true}));
          input.dispatchEvent(new Event('change', {bubbles:true}));
        }
      }
    }
    return 'pending';
  } catch (e) {
    return 'pending';
  }
})()
''';
}

/// 控制内嵌 GitHub 登录 WebView：可先开登录页，设备码就绪后再跳转验证页。
class GitHubDeviceWebViewController {
  GitHubDeviceWebViewController({
    this.initialUrl = kGitHubLoginUrl,
    String? userCode,
    this.onAuthSucceeded,
  })  : url = ValueNotifier<String>(initialUrl),
        userCode = ValueNotifier<String?>(userCode),
        navigationEpoch = ValueNotifier<int>(0);

  final String initialUrl;
  final ValueNotifier<String> url;
  final ValueNotifier<String?> userCode;
  /// 递增以强制 WebView 重新 load（即使 URL 字符串相同）。
  final ValueNotifier<int> navigationEpoch;

  /// GitHub 页面已显示授权成功文案时回调（轮询 token 仍由外层负责）。
  final VoidCallback? onAuthSucceeded;

  bool _successNotified = false;

  void navigateTo(String nextUrl, {bool force = false}) {
    if (nextUrl.isEmpty) return;
    if (nextUrl == url.value) {
      if (force) navigationEpoch.value++;
      return;
    }
    url.value = nextUrl;
  }

  void setUserCode(String? code) {
    userCode.value = (code == null || code.isEmpty) ? null : code.trim().toUpperCase();
  }

  /// 设备码到手后跳到带预填码的验证页。
  void goToDeviceVerification(String userCode, {String? verificationUri}) {
    setUserCode(userCode);
    final target = githubDeviceVerificationUri(
      userCode: userCode,
      baseUri: verificationUri ?? kGitHubDeviceUrl,
    );
    navigateTo(target, force: true);
  }

  void notifyAuthSucceeded() {
    if (_successNotified) return;
    _successNotified = true;
    onAuthSucceeded?.call();
  }

  void dispose() {
    url.dispose();
    userCode.dispose();
    navigationEpoch.dispose();
  }
}

/// 是否支持内嵌 WebView 打开 GitHub 登录/验证页。
bool githubDeviceWebViewSupported() =>
    Platform.isWindows || Platform.isAndroid || Platform.isIOS;

/// 打开内嵌 GitHub 登录页（方案 B），**不阻塞**调用方。
///
/// - 默认先打开 [kGitHubLoginUrl]，用户立刻能看到账号密码框。
/// - 外层拿到设备码后可通过 [controller] 跳到带 user_code 的验证页。
/// - 授权成功页检测到后会回调 [GitHubDeviceWebViewController.onAuthSucceeded] 并关闭对话框。
/// - 返回 `true` 表示已弹出内嵌页；`false` 表示不支持/无法展示。
Future<bool> openGitHubDeviceAuthWebView({
  required BuildContext context,
  required GitHubDeviceWebViewController controller,
  VoidCallback? onClosed,
}) async {
  if (!githubDeviceWebViewSupported() || !context.mounted) {
    return false;
  }

  try {
    if (Platform.isWindows) {
      unawaited(
        showDialog<void>(
          context: context,
          useRootNavigator: true,
          barrierDismissible: false,
          builder: (ctx) => _WindowsGitHubAuthDialog(controller: controller),
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
          builder: (ctx) => _MobileGitHubAuthDialog(controller: controller),
        ).whenComplete(() => onClosed?.call()),
      );
      return true;
    }
  } catch (e, st) {
    debugPrint('GitHub Device WebView 打开失败: $e\n$st');
    onClosed?.call();
    return false;
  }
  return false;
}

/// 兼容旧调用：弹出并等待关闭（仅用于「再次打开」按钮）。
Future<bool> showGitHubDeviceAuthWebView({
  required BuildContext context,
  required String verificationUri,
  required String userCode,
}) async {
  if (!githubDeviceWebViewSupported() || !context.mounted) {
    return false;
  }
  final controller = GitHubDeviceWebViewController(
    initialUrl: githubDeviceVerificationUri(
      userCode: userCode,
      baseUri: verificationUri,
    ),
    userCode: userCode,
  );
  try {
    if (Platform.isWindows) {
      await showDialog<void>(
        context: context,
        useRootNavigator: true,
        barrierDismissible: false,
        builder: (ctx) => _WindowsGitHubAuthDialog(controller: controller),
      );
      return true;
    }
    if (Platform.isAndroid || Platform.isIOS) {
      await showDialog<void>(
        context: context,
        useRootNavigator: true,
        barrierDismissible: false,
        builder: (ctx) => _MobileGitHubAuthDialog(controller: controller),
      );
      return true;
    }
  } catch (e, st) {
    debugPrint('GitHub Device WebView 打开失败: $e\n$st');
    return false;
  } finally {
    controller.dispose();
  }
  return false;
}

Future<void> _openExternal(String uri) async {
  final parsed = Uri.tryParse(uri);
  if (parsed == null) return;
  await launchUrl(parsed, mode: LaunchMode.externalApplication);
}

void _closeAuthDialog(BuildContext context) {
  if (!context.mounted) return;
  Navigator.of(context, rootNavigator: true).maybePop();
}

Widget _authChrome({
  required BuildContext context,
  required ValueNotifier<String?> userCodeListenable,
  required ValueNotifier<String> urlListenable,
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
                    '请在下方用 GitHub 账号密码登录并点 Authorize。'
                    '验证码用于把本次网页授权绑定到本 App；一般已自动填入，无需手抄。'
                    '授权成功后此窗口会自动关闭。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 8),
                  ValueListenableBuilder<String?>(
                    valueListenable: userCodeListenable,
                    builder: (context, userCode, _) {
                      return Row(
                        children: [
                          Text('验证码', style: theme.textTheme.labelMedium),
                          const SizedBox(width: 8),
                          Expanded(
                            child: userCode == null
                                ? Text(
                                    '正在申请设备码…登录后会自动跳转验证页',
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: cs.onSurfaceVariant,
                                    ),
                                  )
                                : SelectableText(
                                    userCode,
                                    style: theme.textTheme.titleLarge?.copyWith(
                                      letterSpacing: 2,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                          ),
                          if (userCode != null)
                            TextButton.icon(
                              onPressed: () async {
                                await Clipboard.setData(
                                  ClipboardData(text: userCode),
                                );
                                if (!context.mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('验证码已复制')),
                                );
                              },
                              icon: const Icon(Icons.copy, size: 16),
                              label: const Text('复制'),
                            ),
                          ValueListenableBuilder<String>(
                            valueListenable: urlListenable,
                            builder: (context, url, _) {
                              return TextButton.icon(
                                onPressed: () => _openExternal(url),
                                icon: const Icon(Icons.open_in_browser, size: 16),
                                label: const Text('系统浏览器'),
                              );
                            },
                          ),
                          if (onRetryLoad != null)
                            IconButton(
                              tooltip: '重新加载',
                              onPressed: onRetryLoad,
                              icon: const Icon(Icons.refresh),
                            ),
                        ],
                      );
                    },
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
  const _MobileGitHubAuthDialog({required this.controller});

  final GitHubDeviceWebViewController controller;

  @override
  State<_MobileGitHubAuthDialog> createState() => _MobileGitHubAuthDialogState();
}

class _MobileGitHubAuthDialogState extends State<_MobileGitHubAuthDialog> {
  late final WebViewController _controller;
  var _loading = true;
  String? _blockHint;
  String? _loadedUrl;
  var _closing = false;

  @override
  void initState() {
    super.initState();
    final ua = Platform.isIOS ? _kIosSafariUa : _kAndroidChromeUa;
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(ua)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            // 不拦截 GitHub 站内跳转（login → device → authorize → success）。
            return NavigationDecision.navigate;
          },
          onPageStarted: (_) {
            if (mounted) setState(() => _loading = true);
          },
          onPageFinished: (url) async {
            if (!mounted) return;
            setState(() {
              _loading = false;
              _loadedUrl = url;
            });
            widget.controller.url.value = url;
            await _afterPageSettled(url);
          },
          onWebResourceError: (err) {
            if (!mounted) return;
            setState(() {
              _loading = false;
              _blockHint =
                  '页面加载失败（${err.description}）。可点「系统浏览器」在外部完成登录；'
                  '若长期失败，请检查代理/VPN 后重试。';
            });
          },
        ),
      );
    widget.controller.url.addListener(_onUrlChanged);
    widget.controller.navigationEpoch.addListener(_onEpochChanged);
    _load(uri: widget.controller.url.value);
  }

  void _onUrlChanged() {
    final next = widget.controller.url.value;
    if (next != _loadedUrl) {
      _load(uri: next);
    }
  }

  void _onEpochChanged() {
    _load(uri: widget.controller.url.value, force: true);
  }

  Future<void> _load({String? uri, bool force = false}) async {
    final target = uri ?? widget.controller.url.value;
    if (!force && target == _loadedUrl && !_loading) return;
    setState(() {
      _loading = true;
      _blockHint = null;
      _loadedUrl = target;
    });
    await _controller.loadRequest(Uri.parse(target));
  }

  Future<void> _afterPageSettled(String url) async {
    if (_looksLikeDeviceAuthSuccess(url: url)) {
      _handleSuccess();
      return;
    }
    await _probePage();
  }

  Future<void> _probePage() async {
    try {
      final raw = await _controller.runJavaScriptReturningResult(
        _jsProbeAuthOutcome(widget.controller.userCode.value),
      );
      final s = raw.toString().toLowerCase();
      if (s.contains('success')) {
        _handleSuccess();
        return;
      }
      if (s.contains('blocked') && mounted) {
        setState(() {
          _blockHint =
              'GitHub 可能限制了内嵌浏览器。请点右上角「系统浏览器」完成登录与授权。';
        });
      }
    } catch (_) {}

    try {
      final raw = await _controller.runJavaScriptReturningResult(
        '(function(){var t=(document.body&&document.body.innerText)||""; '
        'return /unsupported browser|browser is not supported|不支持的浏览器/i.test(t) '
        '? "blocked" : "ok";})()',
      );
      if (raw.toString().toLowerCase().contains('blocked') && mounted) {
        setState(() {
          _blockHint =
              'GitHub 可能限制了内嵌浏览器。请点右上角「系统浏览器」完成登录与授权。';
        });
      }
    } catch (_) {}
  }

  void _handleSuccess() {
    if (_closing) return;
    _closing = true;
    widget.controller.notifyAuthSucceeded();
    _closeAuthDialog(context);
  }

  @override
  void dispose() {
    widget.controller.url.removeListener(_onUrlChanged);
    widget.controller.navigationEpoch.removeListener(_onEpochChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _authChrome(
      context: context,
      userCodeListenable: widget.controller.userCode,
      urlListenable: widget.controller.url,
      onRetryLoad: () => _load(force: true),
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
                        onPressed: () =>
                            _openExternal(widget.controller.url.value),
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
  const _WindowsGitHubAuthDialog({required this.controller});

  final GitHubDeviceWebViewController controller;

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
  String? _loadedUrl;
  String? _lastSeenUrl;
  var _closing = false;
  /// 正在把 WebView 站内导航同步到 [controller.url]，勿再触发 loadUrl。
  var _syncingFromWebView = false;
  StreamSubscription<String>? _urlSub;
  StreamSubscription<String>? _titleSub;
  StreamSubscription<win_wv.LoadingState>? _loadingSub;

  @override
  void initState() {
    super.initState();
    widget.controller.url.addListener(_onUrlChanged);
    widget.controller.navigationEpoch.addListener(_onEpochChanged);
    _init();
  }

  void _onUrlChanged() {
    if (_syncingFromWebView) return;
    final next = widget.controller.url.value;
    if (!_ready || next == _loadedUrl) return;
    _loadUrl(next);
  }

  void _onEpochChanged() {
    if (!_ready) return;
    _loadUrl(widget.controller.url.value, force: true);
  }

  Future<void> _init() async {
    try {
      await _controller.initialize();
      // sameWindow：Authorize 等站内跳转不因弹窗策略被吞掉。
      await _controller
          .setPopupWindowPolicy(win_wv.WebviewPopupWindowPolicy.sameWindow);
      try {
        await _controller.setUserAgent(_kDesktopChromeUa);
      } catch (e) {
        debugPrint('GitHub WebView setUserAgent 跳过: $e');
      }
      _urlSub = _controller.url.listen((url) {
        if (!mounted) return;
        _lastSeenUrl = url;
        _loadedUrl = url;
        // 同步外层展示的当前 URL（便于「系统浏览器」打开同一页）。
        // 勿因此再次 loadUrl，否则会打断 Authorize 后的站内跳转。
        if (url.isNotEmpty && url != widget.controller.url.value) {
          _syncingFromWebView = true;
          widget.controller.url.value = url;
          _syncingFromWebView = false;
        }
        setState(() => _loading = false);
        _probeUnsupportedFromUrl(url);
        if (_looksLikeDeviceAuthSuccess(url: url)) {
          _handleSuccess();
          return;
        }
        unawaited(_probePageContent());
      });
      _titleSub = _controller.title.listen((title) {
        if (!mounted) return;
        if (_looksLikeDeviceAuthSuccess(title: title, url: _lastSeenUrl)) {
          _handleSuccess();
        }
      });
      _loadingSub = _controller.loadingState.listen((state) {
        if (!mounted) return;
        if (state == win_wv.LoadingState.loading) {
          setState(() => _loading = true);
        } else if (state == win_wv.LoadingState.navigationCompleted) {
          setState(() => _loading = false);
          unawaited(_probePageContent());
        }
      });
      if (!mounted) return;
      setState(() {
        _ready = true;
        _error = null;
      });
      // WebView2 纹理附着后再导航，降低白屏概率。
      await Future<void>.delayed(const Duration(milliseconds: 280));
      if (!mounted) return;
      await _loadUrl(widget.controller.url.value, force: true);
    } catch (e, st) {
      debugPrint('Windows GitHub WebView 初始化失败: $e\n$st');
      if (!mounted) return;
      setState(() {
        _error =
            '内嵌浏览器无法启动（$e）。请改用「系统浏览器」打开 GitHub 登录页。';
        _ready = false;
        _loading = false;
      });
    }
  }

  Future<void> _loadUrl(String uri, {bool force = false}) async {
    if (!force && uri == _loadedUrl && !_loading) return;
    setState(() {
      _loading = true;
      _blockHint = null;
      _loadedUrl = uri;
    });
    try {
      await _controller.loadUrl(uri);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '页面加载失败：$e。可改用系统浏览器打开。';
        _loading = false;
      });
    }
  }

  void _probeUnsupportedFromUrl(String url) {
    final lower = url.toLowerCase();
    if (lower.contains('unsupported') ||
        (lower.contains('/error') && lower.contains('github.com'))) {
      setState(() {
        _blockHint =
            '若页面提示不支持当前浏览器，请改用「系统浏览器」完成授权。';
      });
    }
  }

  Future<void> _probePageContent() async {
    if (!_ready || _closing) return;
    try {
      final raw = await _controller.executeScript(
        _jsProbeAuthOutcome(widget.controller.userCode.value),
      );
      final s = raw?.toString().toLowerCase() ?? '';
      if (s.contains('success')) {
        _handleSuccess();
      }
    } catch (_) {}
  }

  void _handleSuccess() {
    if (_closing) return;
    _closing = true;
    widget.controller.notifyAuthSucceeded();
    _closeAuthDialog(context);
  }

  Future<void> _reload() async {
    if (!_ready) {
      await _init();
      return;
    }
    await _loadUrl(widget.controller.url.value, force: true);
  }

  @override
  void dispose() {
    widget.controller.url.removeListener(_onUrlChanged);
    widget.controller.navigationEpoch.removeListener(_onEpochChanged);
    _urlSub?.cancel();
    _titleSub?.cancel();
    _loadingSub?.cancel();
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
                onPressed: () => _openExternal(widget.controller.url.value),
                icon: const Icon(Icons.open_in_browser),
                label: const Text('用系统浏览器打开'),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => _openExternal(
                  widget.controller.userCode.value == null
                      ? kGitHubLoginUrl
                      : githubDeviceVerificationUri(
                          userCode: widget.controller.userCode.value!,
                        ),
                ),
                child: const Text('打开 GitHub 验证页'),
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
                            _openExternal(widget.controller.url.value),
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
      userCodeListenable: widget.controller.userCode,
      urlListenable: widget.controller.url,
      onRetryLoad: _reload,
      body: body,
    );
  }
}
