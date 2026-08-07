// ignore_for_file: avoid_web_libraries_in_flutter

import 'dart:async';
import 'dart:html' as html;
import 'dart:js';
import 'package:flutter/widgets.dart';

import 'graph_captcha_types.dart';

class GraphCaptchaService {
  static bool get isSupported => true;

  static Future<void> _ensureSdkLoaded(String? sdkUrl) async {
    if (context.hasProperty('initAlicom4')) return;
    final url = (sdkUrl ?? '').trim();
    if (url.isEmpty) {
      throw Exception('未配置图形认证 SDK 地址');
    }
    final c = Completer<void>();
    final script = html.ScriptElement()
      ..src = url
      ..async = true;
    script.onLoad.listen((_) => c.complete());
    script.onError.listen((_) {
      if (!c.isCompleted) c.completeError(Exception('图形认证 SDK 加载失败'));
    });
    html.document.head?.append(script);
    await c.future.timeout(const Duration(seconds: 10));
    if (!context.hasProperty('initAlicom4')) {
      throw Exception('图形认证 SDK 初始化函数不存在');
    }
  }

  static Future<GraphCaptchaResult?> verify({
    required String appId,
    String? sdkUrl,
    BuildContext? buildContext,
    String captchaPlatform = 'web',
  }) async {
    final id = appId.trim();
    if (id.isEmpty) throw Exception('图形认证 appId 为空');
    await _ensureSdkLoaded(sdkUrl);
    final completer = Completer<GraphCaptchaResult?>();

    // 必须使用 dart:js 的全局 context，勿与 [BuildContext] 参数同名（会遮蔽 js context）
    context.callMethod('initAlicom4', [
      JsObject.jsify({'captchaId': id, 'product': 'bind', 'https': true}),
      (dynamic captchaObj) {
        if (captchaObj == null) {
          if (!completer.isCompleted) {
            completer.completeError(Exception('图形认证初始化失败'));
          }
          return;
        }
        void finishFail([String? reason]) {
          if (!completer.isCompleted) {
            completer.completeError(Exception(reason ?? '图形认证未通过'));
          }
        }

        captchaObj?.callMethod('onNextReady', [
          () {
            captchaObj?.callMethod('showCaptcha');
          },
        ]);
        captchaObj?.callMethod('onSuccess', [
          () {
            try {
              final v = captchaObj?.callMethod('getValidate');
              if (v == null) {
                finishFail('图形认证结果为空');
                return;
              }
              final lotNumber = (v['lot_number'] ?? '').toString();
              final captchaOutput = (v['captcha_output'] ?? '').toString();
              final passToken = (v['pass_token'] ?? '').toString();
              final genTime = (v['gen_time'] ?? '').toString();
              if (lotNumber.isEmpty ||
                  captchaOutput.isEmpty ||
                  passToken.isEmpty ||
                  genTime.isEmpty) {
                finishFail('图形认证参数不完整');
                return;
              }
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
            } catch (_) {
              finishFail('图形认证解析失败');
            }
          },
        ]);
        captchaObj?.callMethod('onClose', [() => finishFail('用户取消图形认证')]);
        captchaObj?.callMethod('onFail', [(_) => finishFail('图形认证失败')]);
        captchaObj?.callMethod('onError', [(_) => finishFail('图形认证异常')]);
      },
    ]);

    return completer.future.timeout(const Duration(seconds: 90));
  }
}
