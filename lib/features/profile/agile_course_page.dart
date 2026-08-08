import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/app_glass_styles.dart';
import '../../app/frosted_background.dart';
import 'agile_course_data.dart';

class AgileCoursePage extends StatefulWidget {
  const AgileCoursePage({super.key});

  @override
  State<AgileCoursePage> createState() => _AgileCoursePageState();
}

class _AgileCoursePageState extends State<AgileCoursePage> {
  static const _progressKey = 'agile_course_completed_v1';
  final Set<String> _completed = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadProgress();
  }

  Future<void> _loadProgress() async {
    final prefs = await SharedPreferences.getInstance();
    _completed.addAll(prefs.getStringList(_progressKey) ?? const []);
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _setCompleted(String id, bool value) async {
    setState(() => value ? _completed.add(id) : _completed.remove(id));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_progressKey, _completed.toList()..sort());
  }

  Future<void> _openLesson(AgileChapter chapter, AgileLesson lesson) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => AgileLessonPage(
          chapter: chapter,
          lesson: lesson,
          completed: _completed.contains(lesson.id),
          onCompletedChanged: (value) => _setCompleted(lesson.id, value),
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  AgileLesson? get _nextLesson {
    for (final lesson in allAgileLessons) {
      if (!_completed.contains(lesson.id)) return lesson;
    }
    return null;
  }

  AgileChapter _chapterFor(AgileLesson lesson) => agileCourseChapters
      .firstWhere((chapter) => chapter.lessons.contains(lesson));

  IconData _chapterIcon(int number) {
    return switch (number) {
      1 => Icons.psychology_alt_outlined,
      2 => Icons.flag_outlined,
      3 => Icons.view_list_outlined,
      4 => Icons.groups_2_outlined,
      5 => Icons.directions_run_outlined,
      6 => Icons.verified_outlined,
      7 => Icons.insights_outlined,
      8 => Icons.rocket_launch_outlined,
      9 => Icons.manage_search_outlined,
      10 => Icons.groups_3_outlined,
      11 => Icons.account_balance_outlined,
      _ => Icons.hub_outlined,
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final total = allAgileLessons.length;
    final progress = total == 0 ? 0.0 : _completed.length / total;
    final next = _nextLesson;

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('敏捷管理课堂'),
        backgroundColor: theme.appBarTheme.backgroundColor,
        surfaceTintColor: Colors.transparent,
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          const FrostedBackground(),
          if (_loading)
            const Center(child: CircularProgressIndicator())
          else
            ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              children: [
                AppGlassStyles.section(
                  context,
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 52,
                            height: 52,
                            decoration: BoxDecoration(
                              color: colors.primaryContainer,
                              borderRadius: BorderRadius.circular(15),
                            ),
                            child: Icon(Icons.loop_rounded,
                                color: colors.onPrimaryContainer, size: 30),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('你的敏捷学习冲刺',
                                    style: theme.textTheme.titleLarge),
                                const SizedBox(height: 4),
                                Text(
                                    '${agileCourseChapters.length} 章 · $total 课 · 建议 6 周完成',
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                        color: colors.onSurfaceVariant)),
                              ],
                            ),
                          ),
                          Text('${(progress * 100).round()}%',
                              style: theme.textTheme.titleLarge?.copyWith(
                                  color: colors.primary,
                                  fontWeight: FontWeight.w700)),
                        ],
                      ),
                      const SizedBox(height: 18),
                      LinearProgressIndicator(
                          value: progress,
                          minHeight: 8,
                          borderRadius: BorderRadius.circular(8)),
                      const SizedBox(height: 12),
                      Text(
                        _completed.length == total
                            ? '全部课程已掌握。请把各课产出整合成一套可在真实项目使用的敏捷项目作战包。'
                            : '从第 9 章起加入案例推演、分步练习、可复制模板、常见误区和情境测验。',
                        style: theme.textTheme.bodyMedium?.copyWith(
                            height: 1.45, color: colors.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                AppGlassStyles.section(
                  context,
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.workspaces_outline, color: colors.primary),
                          const SizedBox(width: 8),
                          Text('贯穿实战：敏捷项目作战包',
                              style: theme.textTheme.titleMedium),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Text(
                        '可使用自己的项目，也可跟随“HIBI 跨设备传输稳定性提升”案例。每课产出会逐步形成：客户问题简报 → 成果路线图 → 待办与发布预测 → 团队工作系统 → 质量风险板 → 投资治理 → 90 天变革计划。',
                        style: theme.textTheme.bodyMedium?.copyWith(
                            color: colors.onSurfaceVariant, height: 1.5),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                AppGlassStyles.section(
                  context,
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('学习看板',
                          style: theme.textTheme.titleMedium),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          _StatusCell(
                              label: '待学习',
                              value: '${total - _completed.length}',
                              color: colors.outline),
                          const SizedBox(width: 8),
                          _StatusCell(
                              label: '进行中',
                              value: next == null ? '0' : '1',
                              color: colors.tertiary),
                          const SizedBox(width: 8),
                          _StatusCell(
                              label: '已掌握',
                              value: '${_completed.length}',
                              color: colors.primary),
                        ],
                      ),
                      if (next != null) ...[
                        const SizedBox(height: 14),
                        Material(
                          color: colors.primaryContainer.withOpacity(0.45),
                          borderRadius: BorderRadius.circular(12),
                          child: ListTile(
                            leading: const Icon(Icons.play_circle_outline),
                            title: Text('继续：${next.title}'),
                            subtitle: Text('${next.duration} 分钟 · ${next.goal}',
                                maxLines: 2, overflow: TextOverflow.ellipsis),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => _openLesson(_chapterFor(next), next),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                Text('课程章节',
                    style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                for (final chapter in agileCourseChapters) ...[
                  _buildChapter(context, chapter),
                  const SizedBox(height: 10),
                ],
                AppGlassStyles.section(
                  context,
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    '课程主题参考所提供目录，并依据敏捷软件开发宣言及十二条原则、The Scrum Guide 2020、The Kanban Guide、Evidence-Based Management，以及精益、极限编程和持续交付的公开实践重新原创编排。案例、练习与模板不复制书籍正文；内容不替代组织制度、合同、合规要求或专业认证教材。',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: colors.onSurfaceVariant, height: 1.5),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildChapter(BuildContext context, AgileChapter chapter) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final done = chapter.lessons
        .where((lesson) => _completed.contains(lesson.id))
        .length;
    return AppGlassStyles.section(
      context,
      padding: EdgeInsets.zero,
      child: ExpansionTile(
        initiallyExpanded:
            done < chapter.lessons.length && (chapter.number == 1 || done > 0),
        leading: Container(
          width: 42,
          height: 42,
          alignment: Alignment.center,
          decoration: BoxDecoration(
              color: colors.primaryContainer,
              borderRadius: BorderRadius.circular(12)),
          child: Icon(_chapterIcon(chapter.number),
              color: colors.onPrimaryContainer),
        ),
        title: Text('${chapter.number}. ${chapter.title}',
            style: theme.textTheme.titleMedium),
        subtitle: Text(
            '${chapter.subtitle}  ·  $done/${chapter.lessons.length}',
            maxLines: 2),
        children: [
          Divider(height: 1, color: colors.outline.withOpacity(0.25)),
          for (var i = 0; i < chapter.lessons.length; i++)
            ListTile(
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
              leading: Icon(
                _completed.contains(chapter.lessons[i].id)
                    ? Icons.check_circle
                    : Icons.radio_button_unchecked,
                color: _completed.contains(chapter.lessons[i].id)
                    ? colors.primary
                    : colors.outline,
              ),
              title: Text(
                  '${chapter.number}.${i + 1} ${chapter.lessons[i].title}'),
              subtitle: Text(
                  '${chapter.lessons[i].duration} 分钟 · ${chapter.lessons[i].goal}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _openLesson(chapter, chapter.lessons[i]),
            ),
        ],
      ),
    );
  }
}

class _StatusCell extends StatelessWidget {
  const _StatusCell(
      {required this.label, required this.value, required this.color});
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
            color: color.withOpacity(0.12),
            borderRadius: BorderRadius.circular(10)),
        child: Column(
          children: [
            Text(value,
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(color: color, fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(label, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

class AgileLessonPage extends StatefulWidget {
  const AgileLessonPage({
    super.key,
    required this.chapter,
    required this.lesson,
    required this.completed,
    required this.onCompletedChanged,
  });

  final AgileChapter chapter;
  final AgileLesson lesson;
  final bool completed;
  final ValueChanged<bool> onCompletedChanged;

  @override
  State<AgileLessonPage> createState() => _AgileLessonPageState();
}

class _AgileLessonPageState extends State<AgileLessonPage> {
  late bool _completed = widget.completed;
  int? _selectedQuizOption;
  bool _quizSubmitted = false;

  bool get _quizPassed {
    final quiz = widget.lesson.quiz;
    return quiz == null ||
        (_quizSubmitted && _selectedQuizOption == quiz.correctIndex);
  }

  Future<void> _toggle() async {
    if (!_completed && !_quizPassed) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先完成本课的知识检验并答对情境题')),
      );
      return;
    }
    final next = !_completed;
    setState(() => _completed = next);
    widget.onCompletedChanged(next);
    if (next && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已加入“已掌握”')));
    }
  }

  Future<void> _copyTemplate(AgileTemplate template) async {
    await Clipboard.setData(
      ClipboardData(text: '${template.title}\n\n${template.content}'),
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('模板已复制，可粘贴到你的项目文档中')),
      );
    }
  }

  void _submitQuiz() {
    if (_selectedQuizOption == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先选择一个答案')),
      );
      return;
    }
    setState(() => _quizSubmitted = true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final lesson = widget.lesson;
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
          title: Text('${widget.chapter.number} · ${widget.chapter.title}')),
      body: Stack(
        fit: StackFit.expand,
        children: [
          const FrostedBackground(),
          ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 110),
            children: [
              AppGlassStyles.section(
                context,
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(lesson.title,
                        style: theme.textTheme.headlineSmall),
                    const SizedBox(height: 8),
                    Row(children: [
                      const Icon(Icons.schedule, size: 18),
                      const SizedBox(width: 6),
                      Text('${lesson.duration} 分钟')
                    ]),
                    const SizedBox(height: 18),
                    const _SectionTitle(
                        icon: Icons.track_changes, title: '学习目标'),
                    const SizedBox(height: 8),
                    Text(lesson.goal,
                        style:
                            theme.textTheme.bodyLarge?.copyWith(height: 1.55)),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              _LessonSection(
                title: '核心讲解',
                icon: Icons.menu_book_outlined,
                child: Column(
                  children: [
                    for (final paragraph in lesson.explanation)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Text(paragraph,
                            style: theme.textTheme.bodyLarge
                                ?.copyWith(height: 1.65)),
                      ),
                  ],
                ),
              ),
              if (lesson.caseStudy != null) ...[
                const SizedBox(height: 12),
                _LessonSection(
                  title: '案例推演',
                  icon: Icons.science_outlined,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        lesson.caseStudy!.title,
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 10),
                      Text('情境',
                          style: theme.textTheme.labelLarge
                              ?.copyWith(color: colors.primary)),
                      const SizedBox(height: 4),
                      Text(lesson.caseStudy!.situation,
                          style:
                              theme.textTheme.bodyLarge?.copyWith(height: 1.6)),
                      const SizedBox(height: 10),
                      Text('决策',
                          style: theme.textTheme.labelLarge
                              ?.copyWith(color: colors.primary)),
                      const SizedBox(height: 4),
                      Text(lesson.caseStudy!.decision,
                          style:
                              theme.textTheme.bodyLarge?.copyWith(height: 1.6)),
                      const SizedBox(height: 10),
                      Text('结果',
                          style: theme.textTheme.labelLarge
                              ?.copyWith(color: colors.primary)),
                      const SizedBox(height: 4),
                      Text(lesson.caseStudy!.outcome,
                          style:
                              theme.textTheme.bodyLarge?.copyWith(height: 1.6)),
                      if (lesson.caseStudy!.reflection.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Text('思考',
                            style: theme.textTheme.labelLarge
                                ?.copyWith(color: colors.primary)),
                        const SizedBox(height: 6),
                        for (final item in lesson.caseStudy!.reflection)
                          _Bullet(text: item, icon: Icons.help_outline_rounded),
                      ],
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 12),
              _LessonSection(
                title: '关键行动',
                icon: Icons.bolt_outlined,
                child: Column(children: [
                  for (final point in lesson.keyPoints) _Bullet(text: point)
                ]),
              ),
              if (lesson.commonPitfalls.isNotEmpty) ...[
                const SizedBox(height: 12),
                _LessonSection(
                  title: '常见误区',
                  icon: Icons.warning_amber_rounded,
                  child: Column(
                    children: [
                      for (final pitfall in lesson.commonPitfalls)
                        _Bullet(text: pitfall, icon: Icons.close_rounded),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 12),
              _LessonSection(
                title: '实战任务',
                icon: Icons.handyman_outlined,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(lesson.practice,
                        style:
                            theme.textTheme.bodyLarge?.copyWith(height: 1.6)),
                    if (lesson.practiceSteps.isNotEmpty) ...[
                      const SizedBox(height: 14),
                      for (var i = 0; i < lesson.practiceSteps.length; i++)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                width: 24,
                                height: 24,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: colors.primaryContainer,
                                  shape: BoxShape.circle,
                                ),
                                child: Text('${i + 1}',
                                    style: theme.textTheme.labelMedium
                                        ?.copyWith(
                                            color: colors.onPrimaryContainer,
                                            fontWeight: FontWeight.w700)),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(lesson.practiceSteps[i],
                                    style: theme.textTheme.bodyLarge
                                        ?.copyWith(height: 1.5)),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ],
                ),
              ),
              if (lesson.template != null) ...[
                const SizedBox(height: 12),
                _LessonSection(
                  title: '可复制模板',
                  icon: Icons.content_copy_outlined,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(lesson.template!.title,
                                style: theme.textTheme.titleMedium),
                          ),
                          TextButton.icon(
                            onPressed: () => _copyTemplate(lesson.template!),
                            icon: const Icon(Icons.copy, size: 18),
                            label: const Text('复制'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color:
                              colors.surfaceContainerHighest.withOpacity(0.45),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: SelectableText(lesson.template!.content,
                            style: theme.textTheme.bodyMedium
                                ?.copyWith(height: 1.55)),
                      ),
                      const SizedBox(height: 12),
                      Text('填写示例',
                          style: theme.textTheme.labelLarge
                              ?.copyWith(color: colors.primary)),
                      const SizedBox(height: 6),
                      Text(lesson.template!.example,
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(height: 1.55)),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 12),
              _LessonSection(
                title: '本课产出',
                icon: Icons.inventory_2_outlined,
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                      color: colors.primaryContainer.withOpacity(0.4),
                      borderRadius: BorderRadius.circular(12)),
                  child: Text(lesson.deliverable,
                      style: theme.textTheme.bodyLarge
                          ?.copyWith(fontWeight: FontWeight.w600)),
                ),
              ),
              const SizedBox(height: 12),
              _LessonSection(
                title: '完成检查',
                icon: Icons.fact_check_outlined,
                child: Column(children: [
                  for (final item in lesson.checklist)
                    _Bullet(text: item, icon: Icons.check_box_outlined)
                ]),
              ),
              if (lesson.quiz != null) ...[
                const SizedBox(height: 12),
                _LessonSection(
                  title: '知识检验',
                  icon: Icons.quiz_outlined,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(lesson.quiz!.question,
                          style: theme.textTheme.bodyLarge
                              ?.copyWith(height: 1.55)),
                      const SizedBox(height: 8),
                      for (var i = 0; i < lesson.quiz!.options.length; i++)
                        RadioListTile<int>(
                          contentPadding: EdgeInsets.zero,
                          value: i,
                          groupValue: _selectedQuizOption,
                          title: Text(lesson.quiz!.options[i]),
                          onChanged: (value) => setState(() {
                            _selectedQuizOption = value;
                            _quizSubmitted = false;
                          }),
                        ),
                      const SizedBox(height: 6),
                      FilledButton.icon(
                        onPressed: _submitQuiz,
                        icon: const Icon(Icons.check_rounded),
                        label: const Text('提交答案'),
                      ),
                      if (_quizSubmitted) ...[
                        const SizedBox(height: 12),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: _quizPassed
                                ? colors.primaryContainer.withOpacity(0.5)
                                : colors.errorContainer.withOpacity(0.65),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            '${_quizPassed ? '回答正确。' : '回答不正确，请重新判断。'}${lesson.quiz!.explanation}',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              height: 1.5,
                              color: _quizPassed
                                  ? colors.onPrimaryContainer
                                  : colors.onErrorContainer,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
              if (lesson.references.isNotEmpty) ...[
                const SizedBox(height: 12),
                _LessonSection(
                  title: '延伸依据',
                  icon: Icons.library_books_outlined,
                  child: Column(
                    children: [
                      for (final reference in lesson.references)
                        _Bullet(
                            text: reference,
                            icon: Icons.bookmark_outline_rounded),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.all(14),
        child: FilledButton.icon(
          onPressed: _toggle,
          icon: Icon(_completed ? Icons.check_circle : Icons.task_alt),
          label: Text(_completed
              ? '已掌握 · 点击重新学习'
              : widget.lesson.quiz != null && !_quizPassed
                  ? '答对情境题后标记为已掌握'
                  : '完成本课并标记为已掌握'),
          style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16)),
        ),
      ),
    );
  }
}

class _LessonSection extends StatelessWidget {
  const _LessonSection(
      {required this.title, required this.icon, required this.child});
  final String title;
  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AppGlassStyles.section(
      context,
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionTitle(icon: icon, title: title),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.icon, required this.title});
  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(icon, size: 21, color: colors.primary),
        const SizedBox(width: 8),
        Text(title,
            style: Theme.of(context).textTheme.titleMedium),
      ],
    );
  }
}

class _Bullet extends StatelessWidget {
  const _Bullet({required this.text, this.icon = Icons.arrow_right_rounded});
  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: colors.primary),
          const SizedBox(width: 8),
          Expanded(
              child: Text(text,
                  style: Theme.of(context)
                      .textTheme
                      .bodyLarge
                      ?.copyWith(height: 1.45))),
        ],
      ),
    );
  }
}
