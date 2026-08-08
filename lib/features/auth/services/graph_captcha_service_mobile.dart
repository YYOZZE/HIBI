import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'graph_captcha_embed_url.dart';
import 'graph_captcha_types.dart';
import 'graph_captcha_web_message.dart';

/// 与主流移动 Safari / Chrome 一致，降低阿里云风控或初始化失败概率。
const String _kGraphCaptchaAndroidUa =
    'Mozilla/5.0 (Linux; Android 13; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36';

const String _kGraphCaptchaIosUa =
    'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';

class GraphCaptchaService {
  static bool get isSupported => true;

  static Future<GraphCaptchaResult?> verify({
    required String appId,
    String? sdkUrl,
    BuildContext? context,
    String captchaPlatform = 'android',
  }) async {
    if (context == null) {
      throw Exception('缺少上下文，无法打开图形认证窗口');
    }
    final id = appId.trim();
    final sdk = (sdkUrl ?? '').trim();
    if (id.isEmpty) throw Exception('图形认证 appId 为空');
    if (sdk.isEmpty) throw Exception('未配置图形认证 SDK 地址');

    final platform = captchaPlatform.trim().isEmpty ? 'android' : captchaPlatform.trim();
    final embedUrl = graphCaptchaEmbedPageUrl(appId: id, platform: platform);
    if (embedUrl == null || embedUrl.isEmpty) {
      throw Exception('未配置认证服务基址（ApiConfig.authApiBaseUrl）');
    }

    final navigator = Navigator.of(context, rootNavigator: true);
    final completer = Completer<GraphCaptchaResult?>();
    var gotActivity = false;

    late final WebViewController webController;

    void handleJsMessage(String raw) {
      try {
        final obj = coerceCaptchaWebMessage(raw);
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
            Future.microtask(() {
              try {
                navigator.maybePop();
              } catch (_) {}
            });
          }
        } else if (event == 'error' || event == 'close') {
          final reason = (obj['reason'] ?? '图形认证未通过').toString();
          if (!completer.isCompleted) completer.completeError(Exception(reason));
          Future.microtask(() {
            try {
              navigator.maybePop();
            } catch (_) {}
          });
        }
      } catch (e, st) {
        debugPrint('图形认证 HibiCaptcha 解析失败: $e\n$st');
      }
    }

    final ua = Platform.isIOS ? _kGraphCaptchaIosUa : _kGraphCaptchaAndroidUa;
    webController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(
        'HibiCaptcha',
        onMessageReceived: (JavaScriptMessage message) {
          handleJsMessage(message.message);
        },
      )
      ..setUserAgent(ua)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (NavigationRequest request) {
            return NavigationDecision.navigate;
          },
        ),
      );

    await webController.loadRequest(Uri.parse(embedUrl));

    Timer? startupTimer;
    startupTimer = Timer(const Duration(seconds: 22), () {
      if (!gotActivity && !completer.isCompleted) {
        completer.completeError(
          Exception('图形认证页面无响应（22s）。embed: $embedUrl'),
        );
        Future.microtask(() {
          try {
            navigator.maybePop();
          } catch (_) {}
        });
      }
    });

    if (!context.mounted) {
      startupTimer.cancel();
      return null;
    }

    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        final mq = MediaQuery.of(ctx);
        final maxH = (mq.size.height * 0.68).clamp(360.0, 520.0);
        final maxW = (mq.size.width * 0.92).clamp(280.0, 520.0);
        return Dialog(
          insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
          backgroundColor: Theme.of(ctx).dialogBackgroundColor,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxW, maxHeight: maxH),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 8, 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '图形认证',
                          style: Theme.of(ctx).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                        ),
                      ),
                      IconButton(
                        tooltip: '关闭',
                        onPressed: () {
                          if (!completer.isCompleted) {
                            completer.completeError(Exception('用户取消图形认证'));
                          }
                          Navigator.of(ctx).pop();
                        },
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ClipRRect(
                    borderRadius: const BorderRadius.only(
                      bottomLeft: Radius.circular(12),
                      bottomRight: Radius.circular(12),
                    ),
                    child: WebViewWidget(controller: webController),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );

    startupTimer.cancel();
    if (!completer.isCompleted) return null;
    return completer.future.timeout(const Duration(seconds: 90));
  }
}

