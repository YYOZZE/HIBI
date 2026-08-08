import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_win_floating/webview_win_floating.dart';

import '../services/github_oauth_service.dart';

/// 规范为 `XXXX-XXXX`（完整 user_code），供复制与填入共用。
String formatGitHubUserCode(String? code) {
  if (code == null) return '';
  final digits = code.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
  if (digits.length == 8) {
    return '${digits.substring(0, 4)}-${digits.substring(4)}';
  }
  return code.trim().toUpperCase();
}

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
/// 注意：已登录用户打开此页会落到首页/仓库，**不能**当作 Device 授权入口。
const String kGitHubLoginUrl = 'https://github.com/login';

/// Device Flow 验证页（有码后导航至此；请用 [githubDeviceVerificationUri] 带上 user_code）。
const String kGitHubDeviceUrl = 'https://github.com/login/device';

/// 等待设备码期间的占位页（避免已登录用户被晾在仓库首页误以为已完成）。
const String kGitHubAuthWaitingUrl = 'about:blank';

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

/// 已进入最终 Authorize / confirmation，禁止再强制 loadUrl 打断表单提交。
bool _isAuthorizeConfirmationUrl(String? url) {
  if (url == null || url.isEmpty) return false;
  final u = url.toLowerCase();
  return u.contains('/login/device/confirmation') ||
      u.contains('/login/oauth/authorize') ||
      u.contains('authorize?');
}

/// Device 验证码输入页（Authorize your device / OTP），非 confirmation/success。
bool _isDeviceCodeEntryUrl(String? url) {
  if (url == null || url.isEmpty) return false;
  final u = url.toLowerCase();
  if (!u.contains('/login/device')) return false;
  if (_isAuthorizeConfirmationUrl(u)) return false;
  if (u.contains('/login/device/success')) return false;
  if (u.contains('device_authorization_complete')) return false;
  return true;
}

/// 将同一次会话的 user_code 填入 GitHub 分段/OTP 框（不导航、不点按钮）。
///
/// 返回值：`filled:*` 成功；`skip:*` 非目标页或无可填控件。
String _jsFillDeviceUserCode(String userCode) {
  final encoded = jsonEncode(formatGitHubUserCode(userCode));
  return '''
(function(){
  var raw = $encoded;
  if (!raw) return 'skip:empty';
  var digits = String(raw).toUpperCase().replace(/[^A-Z0-9]/g, '');
  if (digits.length !== 8) return 'skip:bad_len';
  var formatted = digits.slice(0, 4) + '-' + digits.slice(4);

  var path = (location.pathname || '').toLowerCase();
  if (path.indexOf('/login/device') < 0) return 'skip:not_device';
  if (path.indexOf('/confirmation') >= 0 || path.indexOf('/success') >= 0) {
    return 'skip:not_entry';
  }

  var blob = ((document.title || '') + ' ' +
    ((document.body && (document.body.innerText || document.body.textContent)) || ''))
    .toLowerCase().replace(/\\s+/g, ' ');
  if (/couldn.?t find anything|entered the user code incorrectly/.test(blob)) {
    return 'skip:invalid_page';
  }
  if (/congratulations|you.?re all set|device is now connected/.test(blob)) {
    return 'skip:success';
  }
  var looksEntry = /authorize your device/.test(blob) ||
    /enter the code displayed on your device/.test(blob) ||
    /user code/.test(blob);
  var inputs = Array.prototype.slice.call(
    document.querySelectorAll('input:not([type=hidden]):not([type=submit]):not([type=checkbox]):not([type=password])')
  ).filter(function(el){
    if (el.disabled) return false;
    var t = (el.type || 'text').toLowerCase();
    return t === 'text' || t === 'tel' || t === 'number' || t === 'search' || t === '';
  });
  if (!looksEntry && inputs.length === 0) return 'skip:not_entry';

  function setVal(el, val) {
    try { el.focus(); } catch (e) {}
    try {
      var proto = window.HTMLInputElement && HTMLInputElement.prototype;
      var desc = proto && Object.getOwnPropertyDescriptor(proto, 'value');
      if (desc && desc.set) desc.set.call(el, val);
      else el.value = val;
    } catch (e2) {
      el.value = val;
    }
    try {
      el.dispatchEvent(new InputEvent('input', {
        bubbles: true, cancelable: true, data: val, inputType: 'insertFromPaste'
      }));
    } catch (e3) {
      el.dispatchEvent(new Event('input', { bubbles: true }));
    }
    el.dispatchEvent(new Event('change', { bubbles: true }));
    try {
      el.dispatchEvent(new KeyboardEvent('keyup', { bubbles: true }));
    } catch (e4) {}
  }

  function alreadyFilled() {
    if (inputs.length === 1) {
      var v = (inputs[0].value || '').toUpperCase().replace(/[^A-Z0-9]/g, '');
      return v === digits;
    }
    var segs = inputs.filter(function(el){ return el.maxLength === 1; });
    if (segs.length >= 8) {
      var got = segs.slice(0, 8).map(function(el){
        return (el.value || '').toUpperCase();
      }).join('').replace(/[^A-Z0-9]/g, '');
      return got === digits;
    }
    return false;
  }
  if (alreadyFilled()) return 'filled:already';

  var singleSel = [
    'input[name="user_code"]',
    'input#user-code',
    'input#user_code',
    'input[autocomplete="one-time-code"]',
    'input[id*="user-code"]',
    'input[id*="user_code"]',
    'input[name="otp"]'
  ];
  for (var i = 0; i < singleSel.length; i++) {
    var one = document.querySelector(singleSel[i]);
    if (!one || one.disabled) continue;
    var ml = one.maxLength;
    if (ml > 0 && ml < 8) continue;
    setVal(one, formatted);
    try {
      one.focus();
      document.execCommand('selectAll', false, null);
      document.execCommand('insertText', false, formatted);
    } catch (e5) {}
    return 'filled:single';
  }

  var segs = inputs.filter(function(el){ return el.maxLength === 1; });
  if (segs.length >= 8) {
    segs = segs.slice(0, 8);
    for (var j = 0; j < 8; j++) setVal(segs[j], digits.charAt(j));
    try { segs[0].focus(); } catch (e6) {}
    return 'filled:segments';
  }

  if (inputs.length === 1) {
    var el = inputs[0];
    setVal(el, formatted);
    try {
      el.focus();
      document.execCommand('selectAll', false, null);
      if (document.execCommand('insertText', false, formatted)) {
        return 'filled:insertText';
      }
      if (document.execCommand('paste')) return 'filled:paste';
    } catch (e7) {}
    return 'filled:form_single';
  }

  if (inputs.length >= 8) {
    for (var k = 0; k < 8; k++) setVal(inputs[k], digits.charAt(k));
    return 'filled:form_segments';
  }

  if (inputs.length > 0) {
    var first = inputs[0];
    first.focus();
    try {
      if (document.execCommand('insertText', false, formatted)) {
        return 'filled:insertText_first';
      }
    } catch (e8) {}
    setVal(first, formatted);
    return 'filled:first_fallback';
  }

  return 'skip:no_input';
})()
''';
}

/// 强制表单/链接在本窗提交，避免 WebView2 NewWindowHandled 吞掉 POST。
String _jsForceSameWindowSubmit() {
  return r'''
(function(){
  function forceSelf(){
    try {
      document.querySelectorAll('form').forEach(function(f){
        f.setAttribute('target','_self');
        try { f.target = '_self'; } catch(e){}
      });
      document.querySelectorAll('[target="_blank"], [formtarget="_blank"]').forEach(function(el){
        if (el.hasAttribute('formtarget')) el.setAttribute('formtarget','_self');
        else el.setAttribute('target','_self');
      });
    } catch(e){}
  }
  forceSelf();
  if (!window.__hibiAuthClickHook) {
    window.__hibiAuthClickHook = true;
    window.__hibiLastClick = '';
    document.addEventListener('click', function(e){
      forceSelf();
      var btn = e.target && e.target.closest
        ? e.target.closest('button, input[type=submit], a')
        : null;
      if (!btn) return;
      var label = ((btn.innerText || btn.value || '') + '').trim().slice(0, 80);
      window.__hibiLastClick = label + ' @' + Date.now();
      var lower = label.toLowerCase();
      if (lower.indexOf('authorize') >= 0 && lower.indexOf('cancel') < 0) {
        var form = btn.form || (btn.closest && btn.closest('form'));
        if (form) {
          form.setAttribute('target','_self');
          try { form.target = '_self'; } catch(err){}
        }
      }
    }, true);
  }
  return 'ok';
})()
''';
}

/// 仅探测授权是否成功；**不做**自动填码 / 自动点按钮（避免码错乱与误点 Cancel）。
String _jsProbeAuthOutcome() {
  return '''
(function(){
  try {
    var t = ((document.title || '') + ' ' +
      ((document.body && (document.body.innerText || document.body.textContent)) || ''))
      .toLowerCase();
    if (/congratulations|you.?re all set|device is now connected|授权成功|已连接/.test(t)) {
      return 'success';
    }
    if (/couldn.?t find anything|entered the user code incorrectly/.test(t)) {
      return 'code_invalid';
    }
    if (/authorize hibi|authorize application/.test(t) &&
        !/authorize your device/.test(t)) {
      return 'authorize';
    }
    return 'pending';
  } catch (e) {
    return 'pending';
  }
})()
''';
}

/// 内嵌页阶段：等待设备码 / 已进入验证授权 / 申请失败。
enum GitHubDeviceWebPhase {
  waitingForCode,
  verifying,
  failed,
}

/// 控制内嵌 GitHub 登录 WebView：先占位等待设备码，码就绪后强制跳转验证页。
class GitHubDeviceWebViewController {
  GitHubDeviceWebViewController({
    this.initialUrl = kGitHubAuthWaitingUrl,
    String? userCode,
    this.onAuthSucceeded,
    this.onAuthorizePageReached,
    this.onRetryDeviceCode,
  })  : url = ValueNotifier<String>(initialUrl),
        userCode = ValueNotifier<String?>(
          (userCode == null || userCode.isEmpty)
              ? null
              : formatGitHubUserCode(userCode),
        ),
        navigationEpoch = ValueNotifier<int>(0),
        phase = ValueNotifier<GitHubDeviceWebPhase>(
          (userCode == null || userCode.isEmpty)
              ? GitHubDeviceWebPhase.waitingForCode
              : GitHubDeviceWebPhase.verifying,
        ),
        statusMessage = ValueNotifier<String?>(
          (userCode == null || userCode.isEmpty)
              ? '正在申请设备码，请稍候…拿到后会自动打开授权页'
              : null,
        ),
        errorMessage = ValueNotifier<String?>(null);

  final String initialUrl;
  final ValueNotifier<String> url;
  final ValueNotifier<String?> userCode;
  /// 递增以强制 WebView 重新 load（即使 URL 字符串相同）。
  final ValueNotifier<int> navigationEpoch;
  final ValueNotifier<GitHubDeviceWebPhase> phase;
  final ValueNotifier<String?> statusMessage;
  final ValueNotifier<String?> errorMessage;

  /// GitHub 页面已显示授权成功文案时回调（轮询 token 仍由外层负责）。
  final VoidCallback? onAuthSucceeded;

  /// 到达最终 Authorize 确认页。
  final VoidCallback? onAuthorizePageReached;

  /// 申请设备码失败后，内嵌页「重试」按钮回调。
  final VoidCallback? onRetryDeviceCode;

  /// 最近一次目标验证页（用于从仓库等错误页拉回）。
  String? lastVerificationUri;

  bool _successNotified = false;
  bool _authorizePageNotified = false;
  /// 已到 confirmation / Authorize：禁止外层再强制 loadUrl。
  bool navigationLocked = false;

  /// 已成功注入到输入页的 user_code（同码只注入一次，避免反复 loadUrl/填码打乱）。
  String? injectedUserCode;

  /// 防止 pageFinished 并发触发多次注入。
  bool injectInFlight = false;

  void navigateTo(String nextUrl, {bool force = false}) {
    if (nextUrl.isEmpty) return;
    if (navigationLocked && force) {
      debugPrint('GitHub WebView navigate ignored (locked): $nextUrl');
      return;
    }
    if (nextUrl == url.value) {
      if (force) navigationEpoch.value++;
      return;
    }
    url.value = nextUrl;
    if (force) navigationEpoch.value++;
  }

  void setUserCode(String? code) {
    final next = (code == null || code.isEmpty)
        ? null
        : formatGitHubUserCode(code);
    if (userCode.value != next) {
      injectedUserCode = null;
    }
    userCode.value = next;
  }

  void setWaitingForCode({String? message}) {
    phase.value = GitHubDeviceWebPhase.waitingForCode;
    errorMessage.value = null;
    statusMessage.value =
        message ?? '正在申请设备码，请稍候…拿到后会自动打开授权页';
    setUserCode(null);
    lastVerificationUri = null;
    injectedUserCode = null;
    navigationLocked = false;
    _authorizePageNotified = false;
    navigateTo(kGitHubAuthWaitingUrl, force: true);
  }

  bool get shouldInjectUserCode {
    final code = userCode.value;
    if (code == null || code.isEmpty) return false;
    if (navigationLocked) return false;
    if (injectInFlight) return false;
    return injectedUserCode != code;
  }

  void markUserCodeInjected(String code) {
    final formatted = formatGitHubUserCode(code);
    if (formatted.isEmpty) return;
    injectedUserCode = formatted;
  }

  void setDeviceCodeFailed(String message) {
    phase.value = GitHubDeviceWebPhase.failed;
    errorMessage.value = message;
    statusMessage.value = null;
  }

  /// 打开**同一次** device/code 给出的验证 URL（勿再拼码、勿二次申请）。
  /// 优先传入的 `verification_uri_complete`（含 user_code=）；到达输入页后再 JS 填一次。
  void goToDeviceVerification(String userCode, {String? verificationUri}) {
    setUserCode(userCode);
    final formatted = formatGitHubUserCode(userCode);
    final raw = verificationUri?.trim();
    final target = (raw != null &&
            raw.isNotEmpty &&
            raw.contains('user_code='))
        ? raw
        : githubDeviceVerificationUri(
            userCode: formatted,
            baseUri: raw ?? kGitHubDeviceUrl,
          );
    lastVerificationUri = target;
    _authorizePageNotified = false;
    // 本次导航对应新文档：允许在输入页再 JS 填一次（仍不二次 loadUrl 拼码）。
    injectedUserCode = null;
    navigationLocked = false;
    phase.value = GitHubDeviceWebPhase.verifying;
    errorMessage.value = null;
    statusMessage.value = '请在下方完成 Continue → Authorize';
    navigateTo(target, force: true);
  }

  /// 仅做成功/确认页探测；**禁止**再 loadUrl 拉回。
  void ensureOnVerificationPage({String? currentUrl}) {
    if (navigationLocked) return;
    final cur = currentUrl ?? url.value;
    if (_isAuthorizeConfirmationUrl(cur)) {
      navigationLocked = true;
      notifyAuthorizePageReached();
    }
  }

  void notifyAuthorizePageReached() {
    if (_authorizePageNotified) return;
    _authorizePageNotified = true;
    navigationLocked = true;
    statusMessage.value = '请点击绿色 Authorize';
    debugPrint('GitHub auth: Authorize page reached (embedded only)');
    onAuthorizePageReached?.call();
  }

  void notifyAuthSucceeded() {
    if (_successNotified) return;
    _successNotified = true;
    debugPrint('GitHub auth: success page detected');
    onAuthSucceeded?.call();
  }

  void dispose() {
    url.dispose();
    userCode.dispose();
    navigationEpoch.dispose();
    phase.dispose();
    statusMessage.dispose();
    errorMessage.dispose();
  }
}

/// 是否支持内嵌 WebView 打开 GitHub 登录/验证页。
bool githubDeviceWebViewSupported() =>
    Platform.isWindows || Platform.isAndroid || Platform.isIOS;

/// 打开内嵌 GitHub 登录页（方案 B），**不阻塞**调用方。
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
  controller.goToDeviceVerification(userCode, verificationUri: verificationUri);
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

void _closeAuthDialog(BuildContext context) {
  if (!context.mounted) return;
  Navigator.of(context, rootNavigator: true).maybePop();
}

Widget _authChrome({
  required BuildContext context,
  required GitHubDeviceWebViewController controller,
  required Widget body,
  VoidCallback? onRetryLoad,
}) {
  final theme = Theme.of(context);
  final cs = theme.colorScheme;
  final mq = MediaQuery.of(context);
  final maxH = (mq.size.height * 0.94).clamp(480.0, 1200.0);
  final maxW = (mq.size.width * 0.96).clamp(320.0, 1100.0);

  return Dialog(
    insetPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
    clipBehavior: Clip.antiAlias,
    child: SizedBox(
      width: maxW,
      height: maxH,
      child: Column(
        children: [
          Material(
            color: cs.surfaceContainerHighest.withOpacity(0.65),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 4, 2, 6),
              child: ValueListenableBuilder<GitHubDeviceWebPhase>(
                valueListenable: controller.phase,
                builder: (context, phase, _) {
                  return ValueListenableBuilder<String?>(
                    valueListenable: controller.userCode,
                    builder: (context, userCode, _) {
                      return ValueListenableBuilder<String?>(
                        valueListenable: controller.statusMessage,
                        builder: (context, status, _) {
                          return ValueListenableBuilder<String?>(
                            valueListenable: controller.errorMessage,
                            builder: (context, error, _) {
                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          'GitHub 授权（点下方 Authorize）',
                                          style: theme.textTheme.titleSmall
                                              ?.copyWith(
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                      IconButton(
                                        tooltip: '关闭',
                                        visualDensity: VisualDensity.compact,
                                        onPressed: () =>
                                            Navigator.of(context).maybePop(),
                                        icon: const Icon(Icons.close),
                                      ),
                                    ],
                                  ),
                                  Row(
                                    children: [
                                      Text(
                                        '验证码',
                                        style: theme.textTheme.labelMedium,
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: userCode == null
                                            ? Text(
                                                phase ==
                                                        GitHubDeviceWebPhase
                                                            .failed
                                                    ? '设备码申请失败'
                                                    : (status ??
                                                        '正在申请设备码…'),
                                                style: theme.textTheme.bodySmall
                                                    ?.copyWith(
                                                  color: phase ==
                                                          GitHubDeviceWebPhase
                                                              .failed
                                                      ? cs.error
                                                      : cs.onSurfaceVariant,
                                                ),
                                              )
                                            : SelectableText(
                                                userCode,
                                                style: theme
                                                    .textTheme.titleMedium
                                                    ?.copyWith(
                                                  letterSpacing: 2,
                                                  fontWeight: FontWeight.w800,
                                                ),
                                              ),
                                      ),
                                      if (userCode != null)
                                        _CopyUserCodeButton(userCode: userCode),
                                      if (onRetryLoad != null)
                                        IconButton(
                                          tooltip: '重新加载',
                                          visualDensity: VisualDensity.compact,
                                          onPressed: onRetryLoad,
                                          icon: const Icon(Icons.refresh),
                                        ),
                                    ],
                                  ),
                                  if (error != null) ...[
                                    Text(
                                      error,
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(color: cs.error),
                                    ),
                                    if (controller.onRetryDeviceCode != null)
                                      Align(
                                        alignment: Alignment.centerLeft,
                                        child: TextButton(
                                          onPressed:
                                              controller.onRetryDeviceCode,
                                          child: const Text('重试申请设备码'),
                                        ),
                                      ),
                                  ] else if (status != null) ...[
                                    Text(
                                      status,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style:
                                          theme.textTheme.bodySmall?.copyWith(
                                        color: userCode == null
                                            ? cs.onSurfaceVariant
                                            : cs.primary,
                                      ),
                                    ),
                                  ],
                                ],
                              );
                            },
                          );
                        },
                      );
                    },
                  );
                },
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

/// 顶栏「复制」：写入完整 `XXXX-XXXX`，旁侧轻提示（避免 SnackBar 被浮层 WebView 挡住）。
class _CopyUserCodeButton extends StatefulWidget {
  const _CopyUserCodeButton({required this.userCode});

  final String userCode;

  @override
  State<_CopyUserCodeButton> createState() => _CopyUserCodeButtonState();
}

class _CopyUserCodeButtonState extends State<_CopyUserCodeButton> {
  var _copied = false;
  Timer? _hideTip;

  @override
  void dispose() {
    _hideTip?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    final text = formatGitHubUserCode(widget.userCode);
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    setState(() => _copied = true);
    _hideTip?.cancel();
    _hideTip = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _copied = false);
    });
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(
      SnackBar(
        content: Text('已复制 $text'),
        duration: const Duration(milliseconds: 1600),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_copied) ...[
          Text(
            '已复制',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: cs.primary,
                  fontWeight: FontWeight.w600,
                ),
          ),
          const SizedBox(width: 2),
        ],
        IconButton(
          tooltip: '复制完整验证码',
          visualDensity: VisualDensity.compact,
          onPressed: _copy,
          icon: Icon(
            _copied ? Icons.check : Icons.copy,
            size: 18,
            color: _copied ? cs.primary : null,
          ),
        ),
      ],
    );
  }
}

/// 在确认的 device 输入页，用同一次会话码 JS 填入一次（含短延迟重试等 DOM）。
Future<void> _tryInjectUserCodeOnce({
  required GitHubDeviceWebViewController controller,
  required String pageUrl,
  required Future<Object?> Function(String js) runJs,
  required bool Function() isMounted,
}) async {
  if (!isMounted()) return;
  if (!_isDeviceCodeEntryUrl(pageUrl)) return;
  if (!controller.shouldInjectUserCode) return;

  final code = controller.userCode.value;
  if (code == null || code.isEmpty) return;
  final formatted = formatGitHubUserCode(code);

  controller.injectInFlight = true;
  try {
    // 同步到系统剪贴板，便于用户在框内 Ctrl+V（若站点拦截则靠下方分发）。
    try {
      await Clipboard.setData(ClipboardData(text: formatted));
    } catch (_) {}

    for (var attempt = 0; attempt < 3; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(Duration(milliseconds: 350 * attempt));
      }
      if (!isMounted()) return;
      if (formatGitHubUserCode(controller.userCode.value) != formatted) return;
      if (controller.injectedUserCode == formatted) return;
      if (controller.navigationLocked) return;

      try {
        final raw = await runJs(_jsFillDeviceUserCode(formatted));
        final s = raw.toString().replaceAll('"', '').toLowerCase();
        debugPrint('GitHub WebView fill user_code attempt=$attempt → $s');
        if (s.contains('filled')) {
          controller.markUserCodeInjected(formatted);
          return;
        }
        if (s.contains('skip:invalid_page') ||
            s.contains('skip:success') ||
            s.contains('skip:not_entry') ||
            s.contains('skip:not_device') ||
            s.contains('skip:bad_len')) {
          return;
        }
        // skip:no_input → 短延迟再试（等 React 挂载分段框）
      } catch (e) {
        debugPrint('GitHub WebView fill user_code failed: $e');
      }
    }
  } finally {
    controller.injectInFlight = false;
  }
}

Widget _waitingOverlay(BuildContext context, {required String message}) {
  final cs = Theme.of(context).colorScheme;
  return ColoredBox(
    color: cs.surface.withOpacity(0.92),
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ],
        ),
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
            if ((_loadedUrl ?? '').startsWith('about:')) return;
            setState(() {
              _loading = false;
              _blockHint = '页面加载失败（${err.description}）。请检查网络后重试。';
            });
          },
        ),
      );
    widget.controller.url.addListener(_onUrlChanged);
    widget.controller.navigationEpoch.addListener(_onEpochChanged);
    widget.controller.userCode.addListener(_onUserCodeChanged);
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

  void _onUserCodeChanged() {
    final code = widget.controller.userCode.value;
    if (code != null && code.isNotEmpty) {
      widget.controller.ensureOnVerificationPage(currentUrl: _loadedUrl);
    }
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
    try {
      await _controller.runJavaScript(_jsForceSameWindowSubmit());
    } catch (_) {}
    widget.controller.ensureOnVerificationPage(currentUrl: url);
    if (_looksLikeDeviceAuthSuccess(url: url)) {
      _handleSuccess();
      return;
    }
    if (_isDeviceCodeEntryUrl(url) && widget.controller.shouldInjectUserCode) {
      await _tryInjectUserCodeOnce(
        controller: widget.controller,
        pageUrl: url,
        runJs: _controller.runJavaScriptReturningResult,
        isMounted: () => mounted,
      );
    }
    await _probePage();
  }

  Future<void> _probePage() async {
    try {
      final raw = await _controller.runJavaScriptReturningResult(
        _jsProbeAuthOutcome(),
      );
      final s = raw.toString().toLowerCase();
      if (s.contains('success')) {
        _handleSuccess();
        return;
      }
      if (s.contains('code_invalid') && mounted) {
        setState(() {
          _blockHint = '网页提示验证码无效。请关闭后重试登录申请新码。';
        });
      }
      if (s == 'authorize' && _isAuthorizeConfirmationUrl(_loadedUrl)) {
        widget.controller.notifyAuthorizePageReached();
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
    widget.controller.userCode.removeListener(_onUserCodeChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _authChrome(
      context: context,
      controller: widget.controller,
      onRetryLoad: () => _load(force: true),
      body: Stack(
        fit: StackFit.expand,
        children: [
          WebViewWidget(controller: _controller),
          if (_loading)
            const Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: IgnorePointer(
                child: LinearProgressIndicator(minHeight: 2),
              ),
            ),
          ValueListenableBuilder<GitHubDeviceWebPhase>(
            valueListenable: widget.controller.phase,
            builder: (context, phase, _) {
              if (phase != GitHubDeviceWebPhase.waitingForCode) {
                return const SizedBox.shrink();
              }
              return ValueListenableBuilder<String?>(
                valueListenable: widget.controller.statusMessage,
                builder: (context, status, _) {
                  return _waitingOverlay(
                    context,
                    message: status ?? '正在申请设备码，请稍候…',
                  );
                },
              );
            },
          ),
          if (_blockHint != null)
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: Material(
                color: Theme.of(context).colorScheme.errorContainer,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  child: Text(
                    _blockHint!,
                    style: TextStyle(
                      color:
                          Theme.of(context).colorScheme.onErrorContainer,
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Windows：使用 webview_win_floating（原生 HWND/WebView2），避免纹理合成点击失灵。
///
/// 资料结论：
/// - jnschulze/webview_windows 离屏纹理 + SendMouseInput 存在焦点/点击问题；
/// - WebView2 NewWindow + Handled 且不设 NewWindow 会吞掉 form POST；
/// - webview_win_floating 原生叠层点击与浏览器一致，且 POST(Content-Type) 不取消导航。
class _WindowsGitHubAuthDialog extends StatefulWidget {
  const _WindowsGitHubAuthDialog({required this.controller});

  final GitHubDeviceWebViewController controller;

  @override
  State<_WindowsGitHubAuthDialog> createState() =>
      _WindowsGitHubAuthDialogState();
}

class _WindowsGitHubAuthDialogState extends State<_WindowsGitHubAuthDialog> {
  late final WinWebViewController _controller;
  var _ready = false;
  var _loading = true;
  String? _error;
  String? _blockHint;
  String? _loadedUrl;
  String? _lastSeenUrl;
  var _closing = false;
  var _syncingFromWebView = false;
  String? _pendingUrl;
  var _pendingForce = false;

  @override
  void initState() {
    super.initState();
    _controller = WinWebViewController();
    widget.controller.url.addListener(_onUrlChanged);
    widget.controller.navigationEpoch.addListener(_onEpochChanged);
    widget.controller.userCode.addListener(_onUserCodeChanged);
    widget.controller.phase.addListener(_onPhaseChanged);
    _init();
  }

  void _onPhaseChanged() {
    final waiting =
        widget.controller.phase.value == GitHubDeviceWebPhase.waitingForCode;
    // floating HWND 盖不住 Flutter 层：等待码时先藏原生层。
    unawaited(_controller.setVisibility(!waiting && _error == null));
  }

  void _onUrlChanged() {
    if (_syncingFromWebView) return;
    if (widget.controller.navigationLocked) return;
    final next = widget.controller.url.value;
    if (!_ready) {
      _pendingUrl = next;
      _pendingForce = true;
      return;
    }
    if (next == _loadedUrl && !_pendingForce) return;
    unawaited(_loadUrl(next, force: true));
  }

  void _onEpochChanged() {
    if (widget.controller.navigationLocked) {
      debugPrint('GitHub WebView epoch ignored (navigation locked)');
      return;
    }
    final next = widget.controller.url.value;
    if (!_ready) {
      _pendingUrl = next;
      _pendingForce = true;
      return;
    }
    unawaited(_loadUrl(next, force: true));
  }

  void _onUserCodeChanged() {
    if (widget.controller.navigationLocked) return;
    final code = widget.controller.userCode.value;
    if (code == null || code.isEmpty) return;
    widget.controller.ensureOnVerificationPage(currentUrl: _lastSeenUrl);
  }

  Future<void> _init() async {
    try {
      // 注意：不设置 onNavigationRequest。
      // webview_win_floating 在有 decision 时会 Cancel + 再 loadUrl(GET)，
      // 可能打断站内跳转；其对 POST(Content-Type) 已放行，无需我们拦截。
      await _controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      await _controller.setUserAgent(_kDesktopChromeUa);
      debugPrint('GitHub WinWebView: UA=desktop Chrome, JS=on, HWND floating');
      await _controller.setNavigationDelegate(
        WinNavigationDelegate(
          onPageStarted: (url) {
            if (!mounted) return;
            debugPrint('GitHub WinWebView pageStarted: $url');
            setState(() => _loading = true);
          },
          onPageFinished: (url) {
            if (!mounted) return;
            debugPrint('GitHub WinWebView pageFinished: $url');
            _onUrlObserved(url);
            unawaited(_afterPageSettled(url));
          },
          onUrlChange: (change) {
            final url = change.url;
            if (url == null || url.isEmpty || !mounted) return;
            debugPrint('GitHub WinWebView urlChange: $url');
            _onUrlObserved(url);
            if (_looksLikeDeviceAuthSuccess(url: url)) {
              _handleSuccess();
            } else if (_isAuthorizeConfirmationUrl(url)) {
              widget.controller.navigationLocked = true;
              widget.controller.notifyAuthorizePageReached();
            }
          },
          onPageTitleChanged: (title) {
            if (!mounted) return;
            debugPrint('GitHub WinWebView title: $title');
            if (_looksLikeDeviceAuthSuccess(
              title: title,
              url: _lastSeenUrl,
            )) {
              _handleSuccess();
            }
          },
          onWebResourceError: (err) {
            if (!mounted) return;
            if ((_loadedUrl ?? '').startsWith('about:')) return;
            debugPrint(
              'GitHub WinWebView error: ${err.description} url=${err.url}',
            );
            setState(() {
              _loading = false;
              _blockHint = '页面资源错误：${err.description}';
            });
          },
        ),
      );
      if (!mounted) return;
      setState(() {
        _ready = true;
        _error = null;
      });
      // 等原生 HWND 附着到布局后再导航。
      await Future<void>.delayed(const Duration(milliseconds: 200));
      if (!mounted) return;
      final target = _pendingUrl ?? widget.controller.url.value;
      _pendingUrl = null;
      _pendingForce = false;
      await _loadUrl(target, force: true);
    } catch (e, st) {
      debugPrint('Windows GitHub WinWebView 初始化失败: $e\n$st');
      if (!mounted) return;
      setState(() {
        _error = '内嵌浏览器无法启动（$e）。请重试。';
        _ready = false;
        _loading = false;
      });
    }
  }

  void _onUrlObserved(String url) {
    _lastSeenUrl = url;
    _loadedUrl = url;
    if (url.isNotEmpty && url != widget.controller.url.value) {
      _syncingFromWebView = true;
      widget.controller.url.value = url;
      _syncingFromWebView = false;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _loadUrl(String uri, {bool force = false}) async {
    if (widget.controller.navigationLocked && force) {
      debugPrint('GitHub WinWebView loadUrl blocked (locked): $uri');
      return;
    }
    if (!force && uri == _loadedUrl && !_loading) return;
    setState(() {
      _loading = true;
      _blockHint = null;
      _loadedUrl = uri;
    });
    try {
      debugPrint('GitHub WinWebView loadUrl: $uri (force=$force)');
      await _controller.loadRequest(Uri.parse(uri));
    } catch (e) {
      if (!mounted) return;
      if (uri.startsWith('about:')) {
        setState(() => _loading = false);
        return;
      }
      setState(() {
        _error = '页面加载失败：$e';
        _loading = false;
      });
    }
  }

  Future<void> _afterPageSettled(String url) async {
    try {
      final hook = await _controller
          .runJavaScriptReturningResult(_jsForceSameWindowSubmit());
      debugPrint('GitHub WinWebView form-hook: $hook');
    } catch (e) {
      debugPrint('GitHub WinWebView form-hook failed: $e');
    }

    widget.controller.ensureOnVerificationPage(currentUrl: url);
    if (_looksLikeDeviceAuthSuccess(url: url)) {
      _handleSuccess();
      return;
    }
    // 仅在当前有效码的输入页 JS 填入一次；禁止为此再 loadUrl。
    if (_isDeviceCodeEntryUrl(url) && widget.controller.shouldInjectUserCode) {
      await _tryInjectUserCodeOnce(
        controller: widget.controller,
        pageUrl: url,
        runJs: _controller.runJavaScriptReturningResult,
        isMounted: () => mounted,
      );
    }
    await _probePageContent();
  }

  Future<void> _probePageContent() async {
    if (!_ready || _closing) return;
    try {
      final click = await _controller.runJavaScriptReturningResult(
        r'''(function(){ return window.__hibiLastClick || ''; })()''',
      );
      final clickStr = click.toString();
      if (clickStr.isNotEmpty && clickStr != 'null') {
        debugPrint('GitHub WinWebView last click: $clickStr');
      }
    } catch (_) {}

    try {
      final meta = await _controller.runJavaScriptReturningResult(
        r'''(function(){
          var t = document.title || '';
          var b = (document.body && (document.body.innerText || '')) || '';
          b = b.replace(/\s+/g, ' ').trim().slice(0, 160);
          var btn = document.querySelector(
            'button[type=submit], input[type=submit], button');
          var btnText = btn
            ? ((btn.innerText || btn.value || '').trim().slice(0,40))
            : '';
          return t + ' | ' + b + ' | btn=' + btnText;
        })()''',
      );
      debugPrint('GitHub WinWebView page: $meta');
      final metaStr = meta.toString().toLowerCase();
      if (_isAuthorizeConfirmationUrl(_lastSeenUrl) ||
          metaStr.contains('authorize hibi-') ||
          (metaStr.contains('authorize hibi') &&
              !metaStr.contains('authorize your device'))) {
        widget.controller.notifyAuthorizePageReached();
      }
    } catch (e) {
      debugPrint('GitHub WinWebView page probe meta failed: $e');
    }

    try {
      final raw =
          await _controller.runJavaScriptReturningResult(_jsProbeAuthOutcome());
      final s = raw.toString().toLowerCase();
      debugPrint('GitHub WinWebView probe result: $s');
      if (s.contains('success')) {
        _handleSuccess();
      } else if (s.contains('code_invalid') && mounted) {
        setState(() {
          _blockHint = '验证码无效，请关闭后重试登录';
        });
      } else if (s.contains('authorize') &&
          _isAuthorizeConfirmationUrl(_lastSeenUrl)) {
        widget.controller.notifyAuthorizePageReached();
      }
    } catch (_) {}
  }

  void _handleSuccess() {
    if (_closing) return;
    _closing = true;
    debugPrint('GitHub WinWebView: auth success → close dialog / poll token');
    widget.controller.notifyAuthSucceeded();
    _closeAuthDialog(context);
  }

  Future<void> _reload() async {
    if (!_ready) {
      await _init();
      return;
    }
    final current = _lastSeenUrl;
    if (widget.controller.navigationLocked &&
        current != null &&
        current.isNotEmpty &&
        !current.startsWith('about:')) {
      // 已在 Authorize：只刷新当前页，勿跳回 device 码页。
      widget.controller.navigationLocked = false;
      await _loadUrl(current, force: true);
      if (_isAuthorizeConfirmationUrl(_lastSeenUrl ?? current)) {
        widget.controller.navigationLocked = true;
      }
      return;
    }
    widget.controller.navigationLocked = false;
    final target = widget.controller.lastVerificationUri ??
        widget.controller.url.value;
    await _loadUrl(target, force: true);
  }

  @override
  void dispose() {
    widget.controller.url.removeListener(_onUrlChanged);
    widget.controller.navigationEpoch.removeListener(_onEpochChanged);
    widget.controller.userCode.removeListener(_onUserCodeChanged);
    widget.controller.phase.removeListener(_onPhaseChanged);
    // 原生 HWND 必须显式隐藏/销毁，否则会浮在 Flutter 上。
    unawaited(() async {
      try {
        await _controller.setVisibility(false);
      } catch (_) {}
      try {
        await _controller.dispose();
      } catch (_) {}
    }());
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
              FilledButton(onPressed: _reload, child: const Text('重试内嵌浏览器')),
            ],
          ),
        ),
      );
    } else if (!_ready) {
      body = const Center(child: CircularProgressIndicator());
    } else {
      // floating HWND：Flutter 叠层盖不住原生 WebView；进度条仅贴顶且 IgnorePointer。
      body = ValueListenableBuilder<GitHubDeviceWebPhase>(
        valueListenable: widget.controller.phase,
        builder: (context, phase, _) {
          final waiting = phase == GitHubDeviceWebPhase.waitingForCode;
          if (waiting) {
            return ValueListenableBuilder<String?>(
              valueListenable: widget.controller.statusMessage,
              builder: (context, status, _) {
                return _waitingOverlay(
                  context,
                  message: status ?? '正在申请设备码，请稍候…',
                );
              },
            );
          }
          return Stack(
            fit: StackFit.expand,
            children: [
              Positioned.fill(child: WinWebViewWidget(controller: _controller)),
              if (_loading)
                const Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: IgnorePointer(
                    child: LinearProgressIndicator(minHeight: 2),
                  ),
                ),
              if (_blockHint != null)
                Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  child: Material(
                    color: cs.errorContainer,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      child: Text(
                        _blockHint!,
                        style: TextStyle(
                          color: cs.onErrorContainer,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ),
                ),
              if (kDebugMode)
                Positioned(
                  right: 4,
                  bottom: 4,
                  child: Material(
                    color: Colors.black54,
                    child: IconButton(
                      tooltip: 'DevTools',
                      icon: const Icon(Icons.bug_report,
                          color: Colors.white, size: 18),
                      onPressed: () => unawaited(_controller.openDevTools()),
                    ),
                  ),
                ),
            ],
          );
        },
      );
    }

    return _authChrome(
      context: context,
      controller: widget.controller,
      onRetryLoad: _reload,
      body: body,
    );
  }
}
