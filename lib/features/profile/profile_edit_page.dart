import 'dart:io';

import 'package:flutter/material.dart';

import '../../app/app_glass_styles.dart';
import '../../app/frosted_background.dart';
import '../auth/services/auth_repository.dart';

class ProfileEditPage extends StatefulWidget {
  const ProfileEditPage({super.key});

  @override
  State<ProfileEditPage> createState() => _ProfileEditPageState();
}

class _ProfileEditPageState extends State<ProfileEditPage> {
  late final TextEditingController _nicknameController;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final user = AuthRepository.instance.currentUser;
    _nicknameController = TextEditingController(text: user?.nickname ?? '');
  }

  @override
  void dispose() {
    _nicknameController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final nickname = _nicknameController.text.trim();
    if (nickname.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('用户名不能为空')),
      );
      return;
    }
    setState(() => _saving = true);
    await AuthRepository.instance.updateProfile(
      nickname: nickname,
    );
    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('个人资料已保存')),
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final user = AuthRepository.instance.currentUser;
    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: const Text('个人资料'),
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          const FrostedBackground(),
          Positioned.fill(
            top: MediaQuery.of(context).padding.top + kToolbarHeight + 8,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
                  children: [
                    AppGlassStyles.section(
                      context,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
                        child: Column(
                          children: [
                            _avatarWidget(user?.avatarUrl, colorScheme),
                            const SizedBox(height: 12),
                            Text(
                              '头像暂不支持修改',
                              style: theme.textTheme.titleMedium,
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '后续将支持从相册选择并同步头像。',
                              style: theme.textTheme.bodySmall,
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    AppGlassStyles.section(
                      context,
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '用户名',
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: colorScheme.onSurfaceVariant,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const SizedBox(height: 8),
                            TextField(
                              controller: _nicknameController,
                              maxLength: 20,
                              decoration: const InputDecoration(
                                hintText: '请输入用户名',
                                counterText: '',
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),
                    Align(
                      alignment: Alignment.center,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 280, minWidth: 220),
                        child: SizedBox(
                          height: 44,
                          child: FilledButton(
                            onPressed: _saving ? null : _save,
                            child: Text(_saving ? '保存中...' : '保存'),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _avatarWidget(String? avatarUrl, ColorScheme colorScheme) {
    final path = avatarUrl?.trim() ?? '';
    final avatar = Container(
      width: 92,
      height: 92,
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      clipBehavior: Clip.antiAlias,
      child: path.isEmpty
          ? Icon(Icons.person, size: 52, color: colorScheme.onPrimaryContainer)
          : (path.startsWith('http://') || path.startsWith('https://'))
              ? Image.network(
                  path,
                  fit: BoxFit.cover,
                  filterQuality: FilterQuality.medium,
                  gaplessPlayback: true,
                  errorBuilder: (_, __, ___) =>
                      Icon(Icons.person, size: 52, color: colorScheme.onPrimaryContainer),
                )
              : Image.file(
                  File(path),
                  fit: BoxFit.cover,
                  filterQuality: FilterQuality.medium,
                  gaplessPlayback: true,
                  errorBuilder: (_, __, ___) =>
                      Icon(Icons.person, size: 52, color: colorScheme.onPrimaryContainer),
                ),
    );
    return avatar;
  }
}

