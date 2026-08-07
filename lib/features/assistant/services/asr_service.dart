import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../../config/api_config.dart';

/// 调用后端 /api/asr（豆包 ASR）上传 WAV，返回识别文本。
class AsrService {
  AsrService({String? baseUrl}) : _baseUrl = (baseUrl ?? ApiConfig.assistantApiBaseUrl).trim();

  final String _baseUrl;

  String get _configUrl => '$_baseUrl/api/asr/config';
  String get _asrUrl => '$_baseUrl/api/asr';

  /// 是否已配置语音识别（后端 ASR_APP_KEY / ASR_ACCESS_KEY）
  Future<bool> isConfigured() async {
    if (_baseUrl.isEmpty) return false;
    try {
      final res = await http.get(Uri.parse(_configUrl)).timeout(const Duration(seconds: 6));
      if (res.statusCode != 200) return false;
      final data = jsonDecode(res.body) as Map<String, dynamic>?;
      return data?['configured'] == true || data?['enabled'] == true;
    } catch (_) {
      return false;
    }
  }

  /// 上传 WAV 字节，返回识别文本；失败抛异常
  Future<String> recognizeFromWavBytes(List<int> wavBytes) async {
    if (_baseUrl.isEmpty) throw Exception('未配置后端地址');
    final request = http.MultipartRequest('POST', Uri.parse(_asrUrl));
    request.files.add(http.MultipartFile.fromBytes(
      'file',
      wavBytes,
      filename: 'voice.wav',
    ));
    final streamed = await request.send().timeout(const Duration(seconds: 35));
    final res = await http.Response.fromStream(streamed);
    if (res.statusCode != 200) {
      String msg = res.body;
      try {
        final data = jsonDecode(res.body) as Map<String, dynamic>?;
        msg = data?['message']?.toString() ?? msg;
      } catch (_) {}
      throw Exception(msg);
    }
    final data = jsonDecode(res.body) as Map<String, dynamic>?;
    final text = data?['text']?.toString() ?? '';
    return text.trim();
  }
}
