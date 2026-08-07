import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jideshi_hibi/features/transfer/models/transfer_device.dart';
import 'package:jideshi_hibi/features/transfer/service/transfer_client.dart';
import 'package:jideshi_hibi/features/transfer/service/transfer_server.dart';
import 'package:jideshi_hibi/features/transfer/transfer_save_path.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('固定接收端口被占用时自动回退到可用端口', () async {
    final blocker = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    final server = TransferServer(deviceName: 'receiver');
    try {
      await server.start(port: blocker.port);
      expect(server.port, isNotNull);
      expect(server.port, isNot(blocker.port));
    } finally {
      server.dispose();
      await blocker.close();
    }
  });

  test('传输落盘完成后才到 100%，同名文件自动追加编号', () async {
    SharedPreferences.setMockInitialValues({});
    final temp = await Directory.systemTemp.createTemp('hibi_transfer_test_');
    final sourceDir = Directory('${temp.path}${Platform.pathSeparator}source');
    final targetDir = Directory('${temp.path}${Platform.pathSeparator}target');
    await sourceDir.create();
    await targetDir.create();
    await TransferSavePath.setPath(targetDir.path);

    final source = File('${sourceDir.path}${Platform.pathSeparator}demo.bin');
    final bytes = List<int>.generate(256 * 1024, (index) => index % 251);
    await source.writeAsBytes(bytes, flush: true);

    final server = TransferServer(deviceName: 'receiver');
    await server.start(port: 0);
    final savedPaths = <String>[];
    final receiveSubscription = server.pendingReceives.listen((pending) async {
      final path = await pending.accept();
      if (path != null) savedPaths.add(path);
    });
    final device = TransferDevice(
      name: 'receiver',
      type: 'hibi',
      address: InternetAddress.loopbackIPv4.address,
      port: server.port!,
      protocolVersion: TransferServer.protocolVersion,
    );

    try {
      for (var sendIndex = 0; sendIndex < 2; sendIndex++) {
        final progress = <double>[];
        await TransferClient.sendFile(
          device,
          source.path,
          onProgress: progress.add,
        );
        expect(progress.last, 1.0);
        expect(progress.where((value) => value >= 1.0), hasLength(1));
        for (var wait = 0;
            wait < 50 && savedPaths.length < sendIndex + 1;
            wait++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(savedPaths, hasLength(sendIndex + 1));
        final saved = File(savedPaths.last);
        expect(await saved.exists(), isTrue);
        expect(await saved.readAsBytes(), bytes);
      }

      expect(
        savedPaths.map((path) => path.split(Platform.pathSeparator).last),
        ['demo.bin', 'demo (1).bin'],
      );
    } finally {
      await receiveSubscription.cancel();
      server.dispose();
      await temp.delete(recursive: true);
    }
  });
}
