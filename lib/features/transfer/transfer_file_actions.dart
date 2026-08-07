import 'dart:io';

import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart' show OpenFilex, ResultType;
import 'package:permission_handler/permission_handler.dart';

import 'transfer_file_browser_page.dart';
import 'transfer_save_path.dart';

/// 传输相关文件的打开、浏览与类型判断。
class TransferFileActions {
  TransferFileActions._();

  static const Set<String> _openableExtensions = {
    'apk',
    'pdf',
    'doc',
    'docx',
    'xls',
    'xlsx',
    'ppt',
    'pptx',
    'txt',
    'md',
    'csv',
    'json',
    'xml',
    'html',
    'htm',
    'jpg',
    'jpeg',
    'png',
    'gif',
    'webp',
    'bmp',
    'svg',
    'mp3',
    'wav',
    'm4a',
    'aac',
    'flac',
    'mp4',
    'mkv',
    'avi',
    'mov',
    'webm',
    'zip',
    'rar',
    '7z',
  };

  static bool isLikelyOpenable(String path) {
    final ext = _extension(path);
    return ext.isNotEmpty && _openableExtensions.contains(ext);
  }

  static String _extension(String path) {
    final name = path.split(RegExp(r'[/\\]')).last;
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot >= name.length - 1) return '';
    return name.substring(dot + 1).toLowerCase();
  }

  static String formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  static IconData iconForPath(String path, {required bool isDirectory}) {
    if (isDirectory) return Icons.folder_outlined;
    final ext = _extension(path);
    switch (ext) {
      case 'apk':
        return Icons.android_outlined;
      case 'pdf':
        return Icons.picture_as_pdf_outlined;
      case 'doc':
      case 'docx':
        return Icons.description_outlined;
      case 'xls':
      case 'xlsx':
      case 'csv':
        return Icons.table_chart_outlined;
      case 'ppt':
      case 'pptx':
        return Icons.slideshow_outlined;
      case 'txt':
      case 'md':
      case 'json':
      case 'xml':
      case 'html':
      case 'htm':
        return Icons.article_outlined;
      case 'jpg':
      case 'jpeg':
      case 'png':
      case 'gif':
      case 'webp':
      case 'bmp':
      case 'svg':
        return Icons.image_outlined;
      case 'mp3':
      case 'wav':
      case 'm4a':
      case 'aac':
      case 'flac':
        return Icons.audiotrack_outlined;
      case 'mp4':
      case 'mkv':
      case 'avi':
      case 'mov':
      case 'webm':
        return Icons.movie_outlined;
      case 'zip':
      case 'rar':
      case '7z':
        return Icons.folder_zip_outlined;
      default:
        return Icons.insert_drive_file_outlined;
    }
  }

  /// 尝试用系统/关联应用打开文件；失败则进入内置文件管理器定位该文件。
  static Future<void> openFile(
    BuildContext context,
    String path, {
    bool fallbackToBrowser = true,
  }) async {
    final file = File(path);
    if (!await file.exists()) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('文件不存在，可能已被删除')),
        );
      }
      return;
    }

    if (Platform.isAndroid && path.toLowerCase().endsWith('.apk')) {
      final req = await Permission.requestInstallPackages.request();
      if (!req.isGranted) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('需要「安装未知应用」权限才能打开 APK')),
          );
        }
        if (fallbackToBrowser && context.mounted) {
          await openSaveLocation(context, highlightFile: path);
        }
        return;
      }
    }

    final result = await OpenFilex.open(path);
    if (result.type == ResultType.done) {
      return;
    }

    if (fallbackToBrowser && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.type == ResultType.noAppToOpen
                ? '没有可打开此文件的应用，已在文件管理中定位'
                : (result.message.isNotEmpty
                    ? result.message
                    : '无法直接打开，已在文件管理中定位'),
          ),
        ),
      );
      await openSaveLocation(context, highlightFile: path);
    }
  }

  /// 打开保存位置：桌面用资源管理器；移动端进入内置文件管理器。
  static Future<void> openSaveLocation(
    BuildContext context, {
    String? highlightFile,
    String? directoryPath,
  }) async {
    String dirPath = directoryPath ?? '';
    if (dirPath.isEmpty) {
      if (highlightFile != null && highlightFile.isNotEmpty) {
        dirPath = File(highlightFile).parent.path;
      } else {
        dirPath = (await TransferSavePath.getSaveDirectory()).path;
      }
    }

    if (Platform.isWindows) {
      try {
        if (highlightFile != null &&
            highlightFile.isNotEmpty &&
            await File(highlightFile).exists()) {
          await Process.run('explorer.exe', ['/select,', highlightFile],
              runInShell: true);
        } else {
          await Process.run('explorer.exe', [dirPath], runInShell: true);
        }
        return;
      } catch (_) {}
    } else if (Platform.isMacOS) {
      try {
        await Process.run('open', [dirPath], runInShell: true);
        return;
      } catch (_) {}
    } else if (Platform.isLinux) {
      try {
        await Process.run('xdg-open', [dirPath], runInShell: true);
        return;
      } catch (_) {}
    }

    if (!context.mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => TransferFileBrowserPage(
          initialDirectory: dirPath,
          highlightFile: highlightFile,
        ),
      ),
    );
  }

  static Future<void> openReceivedFilesManager(BuildContext context) async {
    final dir = await TransferSavePath.getSaveDirectory();
    if (!context.mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => TransferFileBrowserPage(initialDirectory: dir.path),
      ),
    );
  }
}
