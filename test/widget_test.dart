import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:jideshi_hibi/features/mind/models/mind_node.dart';
import 'package:jideshi_hibi/features/mind/services/mind_hbm_service.dart';
import 'package:jideshi_hibi/features/profile/agile_course_data.dart';
import 'package:jideshi_hibi/features/transfer/models/transfer_device.dart';
import 'package:jideshi_hibi/features/transfer/service/lan_discovery_service.dart';
import 'package:jideshi_hibi/features/transfer/transfer_port_config.dart';

void main() {
  test('文件传输默认使用 62637 端口及连续回退端口', () {
    expect(TransferPortConfig.defaultDiscoveryPort, 62637);
    expect(TransferPortConfig.defaultDiscoveryFallbacks, [62637, 62638, 62639]);
  });

  test('文件传输端口范围校验正确', () {
    expect(TransferPortConfig.isValidPort(1), isTrue);
    expect(TransferPortConfig.isValidPort(65535), isTrue);
    expect(TransferPortConfig.isValidPort(0), isFalse);
    expect(TransferPortConfig.isValidPort(65536), isFalse);
  });

  test('局域网发现同时兼容当前与早期端口族', () {
    expect(LanDiscoveryService.discoveryPortFallbacks, [62637, 62638, 62639]);
    expect(LanDiscoveryService.legacyDiscoveryPorts, [52637, 52638, 52639]);
  });

  test('同一设备接收端口变化后仍可按设备 ID 实时替换', () {
    final oldDevice = TransferDevice(
      name: 'Android',
      type: 'HIBI-旧版',
      address: '192.168.1.8',
      port: 51000,
      deviceId: 'same-device',
    );
    final refreshedDevice = TransferDevice(
      name: 'Android',
      type: 'HIBI',
      address: '192.168.1.8',
      port: 52000,
      deviceId: 'same-device',
    );
    expect(refreshedDevice, oldDevice);
    expect(refreshedDevice.port, isNot(oldDevice.port));
  });

  test('.hbm 导出包含格式版本和完整节点数据', () {
    final node = MindNode(
      id: 'node_test',
      title: '测试项目',
      essence: '要义',
      canvasItems: [
        {'id': 'block_1', 'type': 'block', 'text': '内容', 'x': 1, 'y': 2},
      ],
    );
    final document = jsonDecode(utf8.decode(MindHbmService.encode(node)))
        as Map<String, dynamic>;
    expect(document['format'], MindHbmService.format);
    expect(document['version'], MindHbmService.formatVersion);
    expect((document['node'] as Map<String, dynamic>)['title'], '测试项目');
    expect(((document['node'] as Map<String, dynamic>)['canvasItems'] as List),
        hasLength(1));
  });

  test('启动参数只消费首个 .hbm 文件', () {
    MindHbmLaunchService.initialize(['--flag', r'C:\docs\demo.hbm']);
    expect(MindHbmLaunchService.takePendingPath(), r'C:\docs\demo.hbm');
    expect(MindHbmLaunchService.takePendingPath(), isNull);
  });

  test('敏捷管理课堂包含 12 章 36 课且进阶课程具备完整实战内容', () {
    expect(agileCourseChapters, hasLength(12));
    expect(allAgileLessons, hasLength(36));
    expect(allAgileLessons.map((lesson) => lesson.id).toSet(), hasLength(36));
    for (final lesson in allAgileLessons) {
      expect(lesson.goal, isNotEmpty);
      expect(lesson.explanation.length, greaterThanOrEqualTo(2));
      expect(lesson.keyPoints.length, greaterThanOrEqualTo(4));
      expect(lesson.checklist.length, greaterThanOrEqualTo(3));
    }
    final advancedLessons = agileCourseChapters
        .where((chapter) => chapter.number >= 9)
        .expand((chapter) => chapter.lessons);
    for (final lesson in advancedLessons) {
      expect(lesson.caseStudy, isNotNull);
      expect(lesson.commonPitfalls.length, greaterThanOrEqualTo(3));
      expect(lesson.practiceSteps.length, greaterThanOrEqualTo(4));
      expect(lesson.template, isNotNull);
      expect(lesson.quiz, isNotNull);
      expect(lesson.quiz!.options.length, greaterThanOrEqualTo(3));
      expect(lesson.quiz!.correctIndex,
          inInclusiveRange(0, lesson.quiz!.options.length - 1));
      expect(lesson.references, isNotEmpty);
    }
  });
}
