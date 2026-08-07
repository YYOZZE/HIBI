import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

import '../models/canvas_item.dart';
import '../models/mind_node.dart';
import 'mind_repository.dart';

/// HIBI 思维节点交换格式（.hbm）。文件内容为带版本号的 UTF-8 JSON。
class MindHbmService {
  MindHbmService._();

  static const String format = 'hibi-mind-node';
  static const int formatVersion = 1;

  static Uint8List encode(MindNode node) {
    final document = <String, dynamic>{
      'format': format,
      'version': formatVersion,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'node': node.toJson(),
    };
    return Uint8List.fromList(utf8.encode(const JsonEncoder.withIndent('  ').convert(document)));
  }

  static Future<String?> exportNode(MindNode node) async {
    final bytes = encode(node);
    final path = await FilePicker.platform.saveFile(
      dialogTitle: '导出思维节点',
      fileName: '${_safeFileName(node.title)}.hbm',
      type: FileType.custom,
      allowedExtensions: const ['hbm'],
      bytes: (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) ? bytes : null,
    );
    if (path == null || path.isEmpty) return null;
    if (!kIsWeb && !(Platform.isAndroid || Platform.isIOS)) {
      await File(_ensureExtension(path)).writeAsBytes(bytes, flush: true);
      return _ensureExtension(path);
    }
    return path;
  }

  static Future<MindNode?> pickAndImport(MindRepository repository) async {
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: '导入思维节点',
      type: FileType.custom,
      allowedExtensions: const ['hbm'],
      allowMultiple: false,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return null;
    final picked = result.files.single;
    final bytes = picked.bytes ??
        (picked.path == null ? null : await File(picked.path!).readAsBytes());
    if (bytes == null) throw const FormatException('无法读取所选文件');
    return importBytes(bytes, repository);
  }

  static Future<MindNode> importPath(String path, MindRepository repository) async {
    if (!path.toLowerCase().endsWith('.hbm')) throw const FormatException('文件扩展名不是 .hbm');
    return importBytes(await File(path).readAsBytes(), repository);
  }

  static Future<MindNode> importBytes(Uint8List bytes, MindRepository repository) async {
    if (bytes.length > 50 * 1024 * 1024) throw const FormatException('文件过大，无法导入');
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, dynamic> || decoded['format'] != format) {
      throw const FormatException('不是有效的 HIBI 思维节点文件');
    }
    final version = (decoded['version'] as num?)?.toInt();
    if (version == null || version < 1 || version > formatVersion) {
      throw FormatException('不支持的 .hbm 格式版本：$version');
    }
    final rawNode = decoded['node'];
    if (rawNode is! Map<String, dynamic>) throw const FormatException('文件缺少思维节点数据');

    // 先用正式模型解析每个元素，阻止损坏或未知类型的数据写入仓库。
    final rawItems = rawNode['canvasItems'];
    if (rawItems is! List) throw const FormatException('画布数据格式不正确');
    for (final item in rawItems) {
      if (item is! Map<String, dynamic>) throw const FormatException('画布元素格式不正确');
      CanvasItem.fromJson(item);
    }

    final now = DateTime.now();
    final stamp = now.microsecondsSinceEpoch.toString();
    final idMap = <String, String>{};
    var index = 0;
    for (final item in rawItems) {
      final oldId = (item as Map<String, dynamic>)['id'];
      if (oldId is! String || oldId.isEmpty || idMap.containsKey(oldId)) {
        throw const FormatException('画布元素 ID 无效或重复');
      }
      idMap[oldId] = 'hbm_${stamp}_${index++}';
    }

    final rebuiltItems = rawItems.map<Map<String, dynamic>>((value) {
      final item = Map<String, dynamic>.from(value as Map<String, dynamic>);
      item['id'] = idMap[item['id']]!;
      for (final key in const ['parentId', 'fromId', 'toId']) {
        final old = item[key];
        if (old is String) item[key] = idMap[old];
      }
      final children = item['childIds'];
      if (children is List) {
        item['childIds'] = children.whereType<String>().map((id) => idMap[id]).whereType<String>().toList();
      }
      return item;
    }).toList();

    final title = (rawNode['title'] as String? ?? '').trim();
    final node = MindNode(
      id: 'node_hbm_$stamp',
      title: title.isEmpty ? '导入的思维节点' : title,
      essence: rawNode['essence'] as String? ?? '',
      isStarred: rawNode['isStarred'] as bool? ?? false,
      canvasItems: rebuiltItems,
      createdAt: now,
      updatedAt: now,
    );
    await repository.addImported(node);
    return node;
  }

  static String _safeFileName(String value) {
    final name = value.trim().replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    return name.isEmpty ? '思维节点' : name;
  }

  static String _ensureExtension(String path) =>
      path.toLowerCase().endsWith('.hbm') ? path : '$path.hbm';
}

/// 保存桌面端启动参数中的待导入文件，由思维页在仓库加载后消费。
class MindHbmLaunchService {
  MindHbmLaunchService._();

  static String? _pendingPath;

  static void initialize(List<String> arguments) {
    for (final argument in arguments) {
      final value = argument.trim().replaceAll(RegExp(r'^"|"$'), '');
      if (value.toLowerCase().endsWith('.hbm')) {
        _pendingPath = value;
        return;
      }
    }
  }

  static String? takePendingPath() {
    final path = _pendingPath;
    _pendingPath = null;
    return path;
  }
}
