import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../transfer_save_path.dart';

class PendingReceive {
  PendingReceive({
    required this.deviceName,
    required this.files,
    required this.totalSize,
    required this.accept,
    required this.reject,
    this.text,
  });

  final String deviceName;
  final List<Map<String, dynamic>> files;
  final int totalSize;
  final Future<String?> Function() accept;
  final Future<void> Function() reject;
  final String? text;

  final StreamController<double> _progressController =
      StreamController<double>.broadcast();
  double _currentProgress = 0;
  bool _progressClosed = false;

  Stream<double> get progress => _progressController.stream;
  double get currentProgress => _currentProgress;

  bool get isText => text != null && text!.isNotEmpty;

  void _updateProgress(double value) {
    if (_progressClosed) return;
    _currentProgress = value.clamp(0.0, 1.0);
    _progressController.add(_currentProgress);
  }

  void _failProgress(Object error) {
    if (_progressClosed) return;
    _progressController.addError(error);
    _closeProgress();
  }

  void _closeProgress() {
    if (_progressClosed) return;
    _progressClosed = true;
    unawaited(_progressController.close());
  }
}

/// TCP 接收服务。新版在用户接受后直接边收边写盘，避免完整文件内存缓存和二次写盘。
class TransferServer {
  TransferServer({String? deviceName, String? deviceType})
      : deviceName = deviceName ?? _defaultDeviceName(),
        deviceType = deviceType ?? 'hibi';

  static const int protocolVersion = 3;

  static String _defaultDeviceName() {
    final isZh = Platform.localeName.toLowerCase().startsWith('zh');
    return isZh ? '希比-2023' : 'hibi-2023';
  }

  final String deviceName;
  final String deviceType;
  ServerSocket? _server;

  final StreamController<PendingReceive> _pendingController =
      StreamController<PendingReceive>.broadcast();
  final StreamController<double> _progressController =
      StreamController<double>.broadcast();
  final StreamController<String> _saveErrorController =
      StreamController<String>.broadcast();

  Stream<PendingReceive> get pendingReceives => _pendingController.stream;
  Stream<double> get progress => _progressController.stream;
  Stream<String> get saveErrors => _saveErrorController.stream;
  int? get port => _server?.port;

  Future<void> start({int port = 0}) async {
    if (_server != null) return;
    try {
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, port);
    } on SocketException {
      if (port == 0) rethrow;
      // 固定端口被占用时退回系统可用端口，并由发现服务广播真实端口。
      // 这样不会因为一次端口冲突导致“能发现旧广播但接收服务未启动”。
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    }
    _server!.listen(
      _onConnection,
      onError: (Object error) => _saveErrorController.add('接收服务异常：$error'),
      cancelOnError: false,
    );
  }

  void _onConnection(Socket socket) {
    socket.setOption(SocketOption.tcpNoDelay, true);
    final headerBuffer = <int>[];
    final earlyBodyChunks = <Uint8List>[];
    final result = Completer<String?>();
    StreamSubscription<List<int>>? subscription;
    IOSink? output;
    String? outputPath;
    int expectedSize = 0;
    int receivedSize = 0;
    int senderProtocol = 1;
    bool headerParsed = false;
    bool accepted = false;
    bool rejected = false;
    bool finishing = false;
    PendingReceive? pendingRequest;

    void reportProgress(double value) {
      _progressController.add(value);
      pendingRequest?._updateProgress(value);
    }

    Future<void> failReceive(Object error) async {
      if (finishing) return;
      finishing = true;
      try {
        await output?.flush();
        await output?.close();
      } catch (_) {}
      if (outputPath != null) {
        try {
          await File(outputPath!).delete();
        } catch (_) {}
      }
      _saveErrorController.add('接收文件失败：$error');
      pendingRequest?._failProgress(error);
      if (!result.isCompleted) result.complete(null);
      socket.destroy();
    }

    Future<void> finishReceive() async {
      if (finishing || rejected || !accepted) return;
      if (receivedSize < expectedSize) return;
      finishing = true;
      try {
        await output?.flush();
        await output?.close();
        reportProgress(1.0);
        if (senderProtocol >= protocolVersion) {
          socket.add(utf8.encode('DONE\n'));
          await socket.flush();
        }
        if (!result.isCompleted) result.complete(outputPath);
        pendingRequest?._closeProgress();
      } catch (error) {
        finishing = false;
        await failReceive(error);
        return;
      }
      socket.destroy();
    }

    void writeBody(List<int> data) {
      if (data.isEmpty || finishing || rejected) return;
      if (!accepted || output == null) {
        // 正常 HIBI 发送端会等待 ACCEPT，因此这里只有极少量旧协议抢发数据。
        final remaining = math.max(
            0,
            expectedSize -
                receivedSize -
                earlyBodyChunks.fold<int>(
                    0, (sum, chunk) => sum + chunk.length));
        if (remaining > 0) {
          earlyBodyChunks.add(
            Uint8List.fromList(
                data.take(math.min(data.length, remaining)).toList()),
          );
        }
        return;
      }
      final remaining = expectedSize - receivedSize;
      if (remaining <= 0) return;
      final length = math.min(data.length, remaining);
      output!.add(length == data.length ? data : data.sublist(0, length));
      receivedSize += length;
      if (expectedSize > 0) {
        // 99% 以前表示网络/写盘进行中；只有 flush/close 完成后才发布 100%。
        reportProgress(
          math.min(receivedSize / expectedSize, 0.99),
        );
      }
      if (receivedSize >= expectedSize) unawaited(finishReceive());
    }

    subscription = socket.listen(
      (data) {
        if (headerParsed) {
          writeBody(data);
          return;
        }
        headerBuffer.addAll(data);
        final newline = headerBuffer.indexOf(0x0a);
        if (newline < 0) {
          if (headerBuffer.length > 1024 * 1024) socket.destroy();
          return;
        }
        headerParsed = true;
        try {
          final json = jsonDecode(utf8.decode(headerBuffer.sublist(0, newline)))
              as Map<String, dynamic>;
          final fromName = json['device_name']?.toString() ?? '未知设备';
          senderProtocol = (json['protocol_version'] as num?)?.toInt() ?? 1;
          final textContent = json['text'] as String?;
          if (textContent != null && textContent.isNotEmpty) {
            pendingRequest = PendingReceive(
              deviceName: fromName,
              files: const [],
              totalSize: 0,
              text: textContent,
              accept: () async {
                socket.add(utf8.encode('ACCEPT\n'));
                await socket.flush();
                final path = await _acceptText(textContent);
                if (senderProtocol >= protocolVersion) {
                  socket.add(utf8.encode('DONE\n'));
                  await socket.flush();
                }
                pendingRequest?._updateProgress(1.0);
                pendingRequest?._closeProgress();
                socket.destroy();
                return path;
              },
              reject: () async {
                socket.add(utf8.encode('REJECT\n'));
                await socket.flush();
                pendingRequest?._closeProgress();
                socket.destroy();
              },
            );
            _pendingController.add(pendingRequest!);
            return;
          }

          final filesJson = json['files'] as List<dynamic>? ?? const [];
          final files = <Map<String, dynamic>>[];
          for (final value in filesJson) {
            if (value is! Map) continue;
            final filename = value['filename']?.toString() ?? 'file';
            final size = (value['size'] as num?)?.toInt() ?? 0;
            files.add({'filename': filename, 'size': size});
            expectedSize += size;
          }
          if (files.isEmpty || expectedSize < 0) {
            socket.destroy();
            return;
          }

          final rest = headerBuffer.sublist(newline + 1);
          if (rest.isNotEmpty) writeBody(rest);
          pendingRequest = PendingReceive(
            deviceName: fromName,
            files: files,
            totalSize: expectedSize,
            accept: () async {
              if (accepted) return result.future;
              accepted = true;
              try {
                final saveDir = await TransferSavePath.getSaveDirectory();
                final filename = files.first['filename']?.toString() ?? 'file';
                final target = await _reserveAvailableFile(saveDir, filename);
                outputPath = target.path;
                output = target.openWrite(mode: FileMode.writeOnly);
                reportProgress(0.0);
                for (final chunk in earlyBodyChunks) {
                  writeBody(chunk);
                }
                earlyBodyChunks.clear();
                socket.add(utf8.encode('ACCEPT\n'));
                await socket.flush();
                if (expectedSize == 0) unawaited(finishReceive());
                return result.future;
              } catch (error) {
                await failReceive(error);
                return null;
              }
            },
            reject: () async {
              rejected = true;
              socket.add(utf8.encode('REJECT\n'));
              await socket.flush();
              await subscription?.cancel();
              if (!result.isCompleted) result.complete(null);
              pendingRequest?._closeProgress();
              socket.destroy();
            },
          );
          _pendingController.add(pendingRequest!);
        } catch (_) {
          socket.destroy();
        }
      },
      onDone: () {
        if (accepted && receivedSize >= expectedSize) {
          unawaited(finishReceive());
        } else if (accepted && !finishing) {
          unawaited(failReceive('连接提前关闭（$receivedSize/$expectedSize 字节）'));
        } else if (!accepted && pendingRequest != null) {
          pendingRequest!._failProgress('发送方已取消传输请求');
        }
      },
      onError: (Object error) {
        if (accepted && !finishing) unawaited(failReceive(error));
      },
      cancelOnError: false,
    );
  }

  Future<String?> _acceptText(String textContent) async {
    try {
      final saveDir = await TransferSavePath.getSaveDirectory();
      final name = '收到文本_${DateTime.now().millisecondsSinceEpoch}.txt';
      final file = await _reserveAvailableFile(saveDir, name);
      await file.writeAsString(textContent, encoding: utf8, flush: true);
      return file.path;
    } catch (error) {
      _saveErrorController.add('保存文本失败：$error');
      return null;
    }
  }

  /// 以 exclusive create 原子占用目标名，避免并发同名传输互相覆盖。
  Future<File> _reserveAvailableFile(
      Directory directory, String rawName) async {
    var safeName = rawName
        .split(RegExp(r'[/\\]'))
        .last
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    if (safeName.isEmpty || safeName == '.' || safeName == '..') {
      safeName = 'file';
    }
    final dot = safeName.lastIndexOf('.');
    final stem = dot > 0 ? safeName.substring(0, dot) : safeName;
    final extension = dot > 0 ? safeName.substring(dot) : '';
    for (var index = 0; index < 100000; index++) {
      final candidateName = index == 0 ? safeName : '$stem ($index)$extension';
      final file =
          File('${directory.path}${Platform.pathSeparator}$candidateName');
      if (await Directory(file.path).exists()) continue;
      try {
        return await file.create(exclusive: true);
      } on FileSystemException {
        // 同名文件刚被另一个接收任务占用，继续尝试下一个编号。
      }
    }
    throw const FileSystemException('无法生成可用的同名文件编号');
  }

  void stop() {
    _server?.close();
    _server = null;
  }

  void dispose() {
    stop();
    _pendingController.close();
    _progressController.close();
    _saveErrorController.close();
  }
}
