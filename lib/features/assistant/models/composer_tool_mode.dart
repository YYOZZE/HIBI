/// 聊天输入栏底部工具模式（类似豆包快捷能力入口）
enum ComposerToolMode {
  none,
  writeDoc,
  imageGen,
  videoGen,
}

extension ComposerToolModeX on ComposerToolMode {
  String get label {
    switch (this) {
      case ComposerToolMode.none:
        return '';
      case ComposerToolMode.writeDoc:
        return '帮我写作';
      case ComposerToolMode.imageGen:
        return '图像生成';
      case ComposerToolMode.videoGen:
        return '视频生成';
    }
  }

  String get hint {
    switch (this) {
      case ComposerToolMode.none:
        return '发消息…';
      case ComposerToolMode.writeDoc:
        return '描述要写的文档主题、结构与要求…';
      case ComposerToolMode.imageGen:
        return '描述画面、风格、构图与细节…';
      case ComposerToolMode.videoGen:
        return '描述视频主题、镜头与时长…';
    }
  }
}
