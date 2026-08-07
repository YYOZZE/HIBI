import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/transfer_device.dart';

/// 发送进度回调（0.0～1.0）。
typedef SendProgress = void Function(double progress);

class _SocketLineReader {
  _SocketLineReader(Socket socket)
      : _iterator = StreamIterator<String>(
          socket
              .cast<List<int>>()
              .transform(utf8.decoder)
              .transform(const LineSplitter()),
        );

  final StreamIterator<String> _iterator;

  Future<String> nextLine(
      {Duration timeout = const Duration(seconds: 90)}) async {
    final hasNext = await _iterator.moveNext().timeout(timeout);
    if (!hasNext) {
      throw Exception('连接已关闭，未收到对方确认');
    }
    return _iterator.current.trim().toUpperCase();
  }

  Future<void> cancel() => _iterator.cancel();
}

/// TCP 发送端：发送 JSON 元数据和文件内容。
class TransferClient {
  static const int protocolVersion = 3;

  static String _defaultDeviceName() {
    final isZh = Platform.localeName.toLowerCase().startsWith('zh');
    return isZh ? '希比-2023' : 'hibi-2023';
  }

  static Future<Socket> _connect(TransferDevice device) async {
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final socket = await Socket.connect(
          device.address,
          device.port,
          timeout: const Duration(seconds: 8),
        );
        socket.setOption(SocketOption.tcpNoDelay, true);
        return socket;
      } catch (error) {
        lastError = error;
        if (attempt < 2) {
          await Future<void>.delayed(
            Duration(milliseconds: attempt == 0 ? 350 : 900),
          );
        }
      }
    }
    throw Exception(
      '无法连接 ${device.name}（${device.address}:${device.port}）。'
      '请确认对方应用仍在运行、两台设备处于同一局域网，并允许应用通过防火墙。详情：$lastError',
    );
  }

  /// 发送单个文件到目标设备。
  static Future<void> sendFile(
    TransferDevice device,
    String filePath, {
    String? deviceName,
    String? deviceType,
    SendProgress? onProgress,
  }) async {
    final file = File(filePath);
    if (!await file.exists()) throw Exception('文件不存在');
    final filename = filePath.split(RegExp(r'[/\\]')).last;
    final size = await file.length();
    final meta = {
      'device_name': deviceName ?? _defaultDeviceName(),
      'device_type': deviceType ?? 'hibi-2023',
      'protocol_version': protocolVersion,
      'files': [
        {'filename': filename, 'size': size}
      ],
    };

    final socket = await _connect(device);
    final reader = _SocketLineReader(socket);
    try {
      socket.add(utf8.encode('${jsonEncode(meta)}\n'));
      await socket.flush();
      final decision = await reader.nextLine();
      if (decision != 'ACCEPT') {
        throw Exception(decision == 'REJECT' ? '对方已拒绝接收' : '未获得对方接收确认');
      }

      var sent = 0;
      await for (final chunk in file.openRead()) {
        socket.add(chunk);
        sent += chunk.length;
        // 写入本机 Socket 缓冲区并不代表对方已保存，网络阶段最多显示 98%。
        onProgress
            ?.call(size > 0 ? (sent / size * 0.98).clamp(0.0, 0.98) : 0.98);
      }
      await socket.flush();

      if ((device.protocolVersion ?? 0) >= protocolVersion) {
        onProgress?.call(0.99);
        final completion = await reader.nextLine(
          timeout: const Duration(minutes: 5),
        );
        if (completion != 'DONE') {
          throw Exception('对方未确认文件保存完成');
        }
      }
      onProgress?.call(1.0);
    } finally {
      await reader.cancel();
      socket.destroy();
    }
  }

  /// 发送文本到目标设备。
  static Future<void> sendText(
    TransferDevice device,
    String text, {
    String? deviceName,
    String? deviceType,
  }) async {
    if (text.isEmpty) throw Exception('文本为空');
    final meta = {
      'device_name': deviceName ?? _defaultDeviceName(),
      'device_type': deviceType ?? 'hibi-2023',
      'protocol_version': protocolVersion,
      'text': text,
    };
    final socket = await _connect(device);
    final reader = _SocketLineReader(socket);
    try {
      socket.add(utf8.encode('${jsonEncode(meta)}\n'));
      await socket.flush();
      final decision = await reader.nextLine();
      if (decision != 'ACCEPT') {
        throw Exception(decision == 'REJECT' ? '对方已拒绝接收' : '未获得对方接收确认');
      }
      if ((device.protocolVersion ?? 0) >= protocolVersion) {
        final completion = await reader.nextLine();
        if (completion != 'DONE') throw Exception('对方未确认文本保存完成');
      }
    } finally {
      await reader.cancel();
      socket.destroy();
    }
  }
}
