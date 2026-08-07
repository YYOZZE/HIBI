import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_windows/webview_windows.dart';

import 'graph_captcha_embed_url.dart';
import 'graph_captcha_types.dart';
import 'graph_captcha_web_message.dart';

/// 与常见桌面 Chrome 一致，避免阿里云/静态资源对 WebView2 默认 UA 限制过严。
const String _kGraphCaptchaDesktopUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

/// WebView2 需先附着到 Flutter 并完成 [Webview] 的首次 [setSize] 后再导航，
/// 否则纹理未就绪时易出现白屏。
///
/// **必须优先 [loadUrl] 打开服务端 `/api/auth/captcha/embed`**（真实 `http(s)` 文档
/// origin）。`NavigateToString` / `loadStringContent` 内联页在 WebView2 下常无正常
/// origin，`ct4.js` 内 jsonp 拉配置会**长期挂起**，表现为一直「正在加载…」且阿里云
/// 无请求。embed 页已在服务端**内联 ct4**，无二次 sdk 请求。
/// 仅当未配置 [ApiConfig.authApiBaseUrl] 或 [loadUrl] 抛错时，才回退随包内联 HTML。
class _GraphCaptchaWebSurface extends StatefulWidget {
  const _GraphCaptchaWebSurface({
    required this.controller,
    this.embedUrl,
    this.fallbackHtml,
  }) : assert(embedUrl != null || fallbackHtml != null);

  final WebviewController controller;
  final String? embedUrl;
  final String? fallbackHtml;

  @override
  State<_GraphCaptchaWebSurface> createState() => _GraphCaptchaWebSurfaceState();
}

class _GraphCaptchaWebSurfaceState extends State<_GraphCaptchaWebSurface> {
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadWhenSurfaceReady());
  }

  Future<void> _loadWhenSurfaceReady() async {
    if (_loaded || !mounted) return;
    await Future<void>.delayed(const Duration(milliseconds: 280));
    if (!mounted) return;
    _loaded = true;
    try {
      await widget.controller.setBackgroundColor(const Color(0xFF0F1220));
      final embed = widget.embedUrl;
      if (embed != null && embed.isNotEmpty) {
        await widget.controller.loadUrl(embed);
        return;
      }
      final fb = widget.fallbackHtml;
      if (fb != null && fb.isNotEmpty) {
        await widget.controller.loadStringContent(fb);
      }
    } catch (e, st) {
      debugPrint('图形认证 导航失败: $e\n$st');
      final fb = widget.fallbackHtml;
      if (fb != null && fb.isNotEmpty && mounted) {
        try {
          await widget.controller.loadStringContent(fb);
        } catch (e2, st2) {
          debugPrint('图形认证 回退 loadStringContent 失败: $e2\n$st2');
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) => Webview(widget.controller);
}

/// Windows 桌面内嵌页须传 `platform=web`，与控制台 **hibi23h52（win 端 H5）** appId 一致。
String _captchaPlatformForDesktop() {
  return 'web';
}

class GraphCaptchaService {
  static bool get isSupported => Platform.isWindows;

  static Future<GraphCaptchaResult?> verify({
    required String appId,
    String? sdkUrl,
    BuildContext? context,
    String captchaPlatform = 'web',
  }) async {
    if (!Platform.isWindows) return null;
    if (context == null) {
      throw Exception('缺少上下文，无法打开图形认证窗口');
    }
    final id = appId.trim();
    final url = (sdkUrl ?? '').trim();
    if (id.isEmpty) throw Exception('图形认证 appId 为空');
    if (url.isEmpty) throw Exception('未配置图形认证 SDK 地址（GRAPH_CAPTCHA_SDK_URL）');

    final navigator = Navigator.of(context, rootNavigator: true);
    final jsCaptchaId = jsonEncode(id);
    final jsSdkUrl = jsonEncode(url);
    String bundledSdk = '';
    try {
      bundledSdk = await rootBundle.loadString('backend_jideshi_hibi_app/static/ct4.js');
    } catch (e, st) {
      bundledSdk = '';
      debugPrint('图形认证 随包 ct4.js 未加载（将尝试服务端 embed）：$e\n$st');
    }
    final jsBundledSdk = jsonEncode(bundledSdk);

    final platform = captchaPlatform.trim().isEmpty ? _captchaPlatformForDesktop() : captchaPlatform.trim();
    final embedUrl = graphCaptchaEmbedPageUrl(appId: id, platform: platform);

    final fallbackHtml = '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width,initial-scale=1" />
</head>
<body style="margin:0;background:#0f1220;color:#fff;font-family:Segoe UI;">
  <div id="hint" style="padding:12px 16px;">正在加载图形认证（离线回退，可能无法通过验证）...</div>
  <script>
    var captchaId = $jsCaptchaId;
    var sdkUrl = $jsSdkUrl;
    var bundledSdk = $jsBundledSdk;
    function send(o){
      try {
        if (window.HibiCaptcha && typeof window.HibiCaptcha.postMessage === 'function') {
          window.HibiCaptcha.postMessage(typeof o === 'string' ? o : JSON.stringify(o));
          return;
        }
        if (window.chrome && window.chrome.webview && typeof window.chrome.webview.postMessage === 'function') {
          window.chrome.webview.postMessage(o);
          return;
        }
        var hb = document.getElementById("hint");
        if (hb) hb.textContent = "图形认证：WebView 未注入 HibiCaptcha 或 chrome.webview。";
      } catch(e) {
        var hb2 = document.getElementById("hint");
        if (hb2) hb2.textContent = "图形认证通信失败: " + (e && e.message ? e.message : e);
      }
    }
    function injectBundledSdk(){
      if (!bundledSdk) {
        send({event:"error", reason:"图形认证 SDK 加载失败: " + sdkUrl});
        return false;
      }
      try{
        var inline = document.createElement("script");
        inline.type = "text/javascript";
        inline.text = bundledSdk;
        document.head.appendChild(inline);
        return true;
      }catch(e){
        send({event:"error", reason:"图形认证本地 SDK 注入失败"});
        return false;
      }
    }
    function initCaptcha(){
      if (typeof initAlicom4 !== "function") {
        send({event:"error", reason:"初始化失败: initAlicom4 is not defined"});
        return;
      }
      try{
        initAlicom4({ captchaId: captchaId, product: "bind", https: true, onError: function(e) {
            var m = (e && e.msg) ? e.msg : "网络或服务错误";
            var hint = "";
            if (typeof m === "string" && m.indexOf("paused") !== -1) {
              hint = " 请到阿里云「图形认证方案管理」将该方案恢复为启用（约 -50105）。";
            }
            send({event:"error", reason: "图形认证(加载阶段): " + m + hint});
          }}, function(captchaObj) {
          captchaObj.onNextReady(function() {
            send({event:"ready"});
            var h = document.getElementById("hint");
            if (h) h.style.display = "none";
            captchaObj.showCaptcha();
          });
          captchaObj.onSuccess(function() {
            var v = captchaObj.getValidate() || {};
            send({
              event: "success",
              lot_number: v.lot_number || "",
              captcha_output: v.captcha_output || "",
              pass_token: v.pass_token || "",
              gen_time: v.gen_time || ""
            });
          });
          captchaObj.onClose(function(){ send({event:"close", reason:"用户取消图形认证"}); });
          captchaObj.onFail(function(){ send({event:"error", reason:"图形认证失败"}); });
          captchaObj.onError(function(e){ send({event:"error", reason:(e && e.msg) ? e.msg : "图形认证异常"}); });
        });
      }catch(e){
        send({event:"error", reason: "初始化失败: " + (e && e.message ? e.message : e)});
      }
    }
    function loadSdkThenInit(){
      if (bundledSdk && bundledSdk.length > 2) {
        if (injectBundledSdk()) { initCaptcha(); return; }
      }
      if (typeof initAlicom4 === "function") {
        initCaptcha();
        return;
      }
      var s = document.createElement("script");
      s.charset = "utf-8";
      s.src = sdkUrl;
      s.onload = function(){ initCaptcha(); };
      s.onerror = function(){
        if (injectBundledSdk()) initCaptcha();
      };
      document.head.appendChild(s);
      setTimeout(function(){
        if (typeof initAlicom4 !== "function") {
          if (injectBundledSdk()) {
            initCaptcha();
            return;
          }
          send({event:"error", reason:"图形认证 SDK 加载超时: " + sdkUrl});
        }
      }, 12000);
    }
    send({event:"boot", source:"inline"});
    try {
      if (window.chrome && window.chrome.webview) {
        Object.defineProperty(Document.prototype, 'hidden', { get: function () { return false; }, configurable: true });
        Object.defineProperty(Document.prototype, 'visibilityState', { get: function () { return 'visible'; }, configurable: true });
      }
    } catch(eShim) {}
    function raf2(fn){ requestAnimationFrame(function(){ requestAnimationFrame(fn); }); }
    raf2(loadSdkThenInit);
  </script>
</body>
</html>
''';

    final controller = WebviewController();
    await controller.initialize();
    // 阿里云验证码可能以新窗口打开；默认策略若拦截则只见「正在加载」、无 UI
    await controller.setPopupWindowPolicy(WebviewPopupWindowPolicy.sameWindow);
    try {
      await controller.setUserAgent(_kGraphCaptchaDesktopUserAgent);
    } catch (e, st) {
      debugPrint('图形认证 setUserAgent 跳过: $e\n$st');
    }

    final completer = Completer<GraphCaptchaResult?>();
    late final StreamSubscription msgSub;
    var gotActivity = false;
    msgSub = controller.webMessage.listen((dynamic message) {
      try {
        final Map<String, dynamic> obj = coerceCaptchaWebMessage(message);
        gotActivity = true;
        final event = (obj['event'] ?? '').toString();
        if (event == 'success') {
          final lotNumber = (obj['lot_number'] ?? '').toString();
          final captchaOutput = (obj['captcha_output'] ?? '').toString();
          final passToken = (obj['pass_token'] ?? '').toString();
          final genTime = (obj['gen_time'] ?? '').toString();
          if (lotNumber.isNotEmpty &&
              captchaOutput.isNotEmpty &&
              passToken.isNotEmpty &&
              genTime.isNotEmpty) {
            if (!completer.isCompleted) {
              completer.complete(
                GraphCaptchaResult(
                  lotNumber: lotNumber,
                  captchaOutput: captchaOutput,
                  passToken: passToken,
                  genTime: genTime,
                ),
              );
            }
            navigator.maybePop();
          }
        } else if (event == 'error' || event == 'close') {
          final reason = (obj['reason'] ?? '图形认证未通过').toString();
          if (!completer.isCompleted) completer.completeError(Exception(reason));
          Future.microtask(() {
            try {
              navigator.maybePop();
            } catch (_) {}
          });
        } else if (event == 'ready' || event == 'boot') {
          // ready：SDK onNextReady；boot：页面脚本已执行、桥接可用。
        }
      } catch (e, st) {
        debugPrint('图形认证 webMessage 解析失败: $e\n$st');
      }
    });
    Timer? startupTimer;
    startupTimer = Timer(const Duration(seconds: 22), () {
      if (!gotActivity && !completer.isCompleted) {
        final source = embedUrl ?? 'inline-fallback-no-embed';
        completer.completeError(
          Exception('图形认证页面无响应（22s）。来源: $source；SDK: $url'),
        );
        Future.microtask(() {
          try {
            navigator.maybePop();
          } catch (_) {}
        });
      }
    });

    if (!context.mounted) {
      await msgSub.cancel();
      controller.dispose();
      return null;
    }

    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('图形认证'),
          content: SizedBox(
            width: 420,
            height: 520,
            child: _GraphCaptchaWebSurface(
              controller: controller,
              embedUrl: embedUrl,
              fallbackHtml: fallbackHtml,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                if (!completer.isCompleted) {
                  completer.completeError(Exception('用户取消图形认证'));
                }
                Navigator.of(ctx).pop();
              },
              child: const Text('取消'),
            ),
          ],
        );
      },
    );

    await msgSub.cancel();
    startupTimer.cancel();
    controller.dispose();
    if (!completer.isCompleted) return null;
    return completer.future.timeout(const Duration(seconds: 90));
  }
}
