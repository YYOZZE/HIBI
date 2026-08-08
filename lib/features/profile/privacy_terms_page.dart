import 'package:flutter/material.dart';

import '../../app/app_glass_styles.dart';
import '../../app/frosted_background.dart';
import 'privacy_terms_service.dart';

class PrivacyTermsPage extends StatefulWidget {
  const PrivacyTermsPage({super.key});

  @override
  State<PrivacyTermsPage> createState() => _PrivacyTermsPageState();
}

class _PrivacyTermsPageState extends State<PrivacyTermsPage> {
  PrivacyTermsData? _data;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final data = await PrivacyTermsService.fetchPrivacyTerms();
    if (!mounted) return;
    setState(() {
      _data = data;
      _loading = false;
    });
  }

  String _fmtTime(DateTime? time) {
    if (time == null) return '-';
    String two(int v) => v.toString().padLeft(2, '0');
    return '${time.year}-${two(time.month)}-${two(time.day)} ${two(time.hour)}:${two(time.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final data = _data;
    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: const Text('隐私条款'),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          const FrostedBackground(),
          Positioned.fill(
            top: MediaQuery.of(context).padding.top + kToolbarHeight + 8,
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : ListView(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                    children: [
                      AppGlassStyles.section(
                        context,
                        padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '最近更新时间：${_fmtTime(data?.updatedAt)}',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                            if (data?.fromFallback == true) ...[
                              const SizedBox(height: 4),
                              Text(
                                '当前显示为内置条款（网络不可用或服务未配置）',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                      AppGlassStyles.section(
                        context,
                        child: SelectableText(
                          data?.content ?? '',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: colorScheme.onSurface,
                            height: 1.55,
                          ),
                        ),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
