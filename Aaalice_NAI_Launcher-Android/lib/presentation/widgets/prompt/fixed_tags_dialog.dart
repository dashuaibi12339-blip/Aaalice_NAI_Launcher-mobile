import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:nai_launcher/core/utils/localization_extension.dart';

import '../../../data/models/fixed_tag/fixed_tag_entry.dart';
import '../../../data/models/fixed_tag/fixed_tag_prompt_type.dart';
import '../../../data/models/tag_library/tag_library_entry.dart';
import '../../providers/fixed_tags_provider.dart';
import '../../providers/tag_library_page_provider.dart';
import '../../router/app_router.dart';
import '../common/themed_confirm_dialog.dart';
import '../common/themed_switch.dart';
import 'fixed_tag_edit_dialog.dart';

import '../common/app_toast.dart';
import 'package:nai_launcher/presentation/widgets/common/themed_input.dart';

/// 手机端固定词侧边栏 (原为对话框)
class FixedTagsDialog extends ConsumerStatefulWidget {
  const FixedTagsDialog({super.key});

  @override
  ConsumerState<FixedTagsDialog> createState() => _FixedTagsDialogState();
}

class _FixedTagsDialogState extends ConsumerState<FixedTagsDialog> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fixedTagsState = ref.watch(fixedTagsNotifierProvider);
    final isDark = theme.brightness == Brightness.dark;

    // 剥离 Dialog 外壳，使用全屏 Material 完美贴合右侧抽屉
    return Material(
      color: isDark ? theme.colorScheme.surface : theme.colorScheme.surface,
      elevation: 0,
      child: SafeArea(
        left: false, // 抽屉在右侧，不需要左侧安全区
        child: Column(
          children: [
            // 标题栏
            _buildHeader(theme, isDark),

            // 列表区域 (永远显示上下分段布局，确保“新建”按钮始终可见)
            Expanded(
              child: _buildMobileVerticalLayout(theme, fixedTagsState, isDark),
            ),
            // 底部操作栏
            _buildFooter(theme, isDark),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeData theme, bool isDark) {
    final fixedTagsState = ref.watch(fixedTagsNotifierProvider);
    final enabledCount =
        fixedTagsState.entries.where((entry) => entry.enabled).length;
    final totalCount = fixedTagsState.entries.length;
    final linkCount = fixedTagsState.links.length;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 8, 12),
      decoration: BoxDecoration(
        color: isDark
            ? theme.colorScheme.surfaceContainerHigh.withValues(alpha: 0.5)
            : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        border: Border(
          bottom: BorderSide(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
          ),
        ),
      ),
      child: Row(
        children: [
          // 图标
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: theme.colorScheme.secondary.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              Icons.push_pin_rounded,
              color: theme.colorScheme.secondary,
              size: 18,
            ),
          ),
          const SizedBox(width: 12),
          // 标题与统计
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.l10n.fixedTags_manage,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (totalCount > 0)
                  Text(
                    '已启用 $enabledCount/$totalCount · 联动 $linkCount',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
              ],
            ),
          ),
          // 撤销/重做
          IconButton(
            tooltip: '撤销',
            icon: const Icon(Icons.undo_rounded, size: 20),
            onPressed: fixedTagsState.canUndo
                ? () => ref.read(fixedTagsNotifierProvider.notifier).undo()
                : null,
            visualDensity: VisualDensity.compact,
          ),
          IconButton(
            tooltip: '重做',
            icon: const Icon(Icons.redo_rounded, size: 20),
            onPressed: fixedTagsState.canRedo
                ? () => ref.read(fixedTagsNotifierProvider.notifier).redo()
                : null,
            visualDensity: VisualDensity.compact,
          ),
          const SizedBox(width: 4),
          // 全开/全关
          if (totalCount > 0)
            ThemedSwitch(
              value: enabledCount == totalCount,
              onChanged: (val) => ref
                  .read(fixedTagsNotifierProvider.notifier)
                  .setAllEnabled(val),
              scale: 0.8,
            ),
          const SizedBox(width: 4),
          // 关闭按钮
          IconButton(
            icon: const Icon(Icons.close_rounded),
            onPressed: () => Navigator.of(context).pop(),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(ThemeData theme, bool isDark) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 48),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.push_pin_outlined,
              size: 48,
              color: theme.colorScheme.outline.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 16),
            Text(
              context.l10n.fixedTags_empty,
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '点击下方按钮新建固定词，\n或从词库中导入',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
                height: 1.5,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  /// 手机端专属：上下分段布局
  Widget _buildMobileVerticalLayout(
    ThemeData theme,
    FixedTagsState state,
    bool isDark,
  ) {
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        _buildSection(
          theme: theme,
          title: '正向固定词',
          promptType: FixedTagPromptType.positive,
          entries: state.positiveEntries.sortedByOrder(),
          isDark: isDark,
        ),
        Divider(
          height: 32,
          thickness: 4,
          color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        ),
        _buildSection(
          theme: theme,
          title: '负向固定词',
          promptType: FixedTagPromptType.negative,
          entries: state.negativeEntries.sortedByOrder(),
          isDark: isDark,
        ),
      ],
    );
  }

  Widget _buildSection({
    required ThemeData theme,
    required String title,
    required FixedTagPromptType promptType,
    required List<FixedTagEntry> entries,
    required bool isDark,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 分段标题与操作
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
          child: Row(
            children: [
              Container(
                width: 4,
                height: 14,
                decoration: BoxDecoration(
                  color: promptType == FixedTagPromptType.positive
                      ? theme.colorScheme.primary
                      : theme.colorScheme.error,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                title,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: () =>
                    _showEditDialog(null, initialPromptType: promptType),
                icon: const Icon(Icons.add_rounded, size: 16),
                label: const Text('新建'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
              ),
              TextButton.icon(
                onPressed: () => _showLibraryPicker(theme, promptType),
                icon: const Icon(Icons.playlist_add_rounded, size: 16),
                label: const Text('词库'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
              ),
            ],
          ),
        ),
        // 列表内容
        if (entries.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: Text(
                '暂无$title',
                style: TextStyle(
                  color: theme.colorScheme.outline.withValues(alpha: 0.6),
                  fontSize: 13,
                ),
              ),
            ),
          )
        else
          ReorderableListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(), // 让外层 ListView 统一滑动
            buildDefaultDragHandles: false,
            itemCount: entries.length,
            itemBuilder: (context, index) {
              final entry = entries[index];
              return _FixedTagEntryTile(
                key: ValueKey(entry.id),
                entry: entry,
                index: index,
                isDark: isDark,
                linkAnchor: _buildLinkAnchor(theme, entry), // 拖拽联动的锚点
                onToggleEnabled: () => ref
                    .read(fixedTagsNotifierProvider.notifier)
                    .toggleEnabled(entry.id),
                onEdit: () =>
                    _showEditDialog(entry, initialPromptType: promptType),
                onDelete: () => _showDeleteConfirmation(entry),
              );
            },
            onReorder: (oldIndex, newIndex) {
              ref
                  .read(fixedTagsNotifierProvider.notifier)
                  .reorderWithinPromptType(promptType, oldIndex, newIndex);
            },
          ),
      ],
    );
  }

  /// 构建拖拽联动锚点 (保留了 PC 端的拖拽逻辑，去除了连线)
  Widget _buildLinkAnchor(ThemeData theme, FixedTagEntry entry) {
    final state = ref.watch(fixedTagsNotifierProvider);
    final linkCount = entry.promptType == FixedTagPromptType.positive
        ? state.linkedNegativesOf(entry.id).length
        : state.linkedPositivesOf(entry.id).length;
    final linkedNames = entry.promptType == FixedTagPromptType.positive
        ? state
            .linkedNegativesOf(entry.id)
            .map((entry) => entry.displayName)
            .join(', ')
        : state
            .linkedPositivesOf(entry.id)
            .map((entry) => entry.displayName)
            .join(', ');
    final tooltip = linkCount == 0 ? '拖拽创建联动' : '已联动：$linkedNames';

    final anchorVisual = SizedBox(
      width: 40,
      height: 40,
      child: Center(
        child: GestureDetector(
          onTap: () => _showLinkMenu(entry),
          child: Tooltip(
            message: tooltip,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Icon(
                  Icons.link_rounded,
                  size: 24,
                  color: linkCount > 0
                      ? theme.colorScheme.secondary
                      : theme.colorScheme.outline.withValues(alpha: 0.5),
                ),
                if (linkCount > 0)
                  Positioned(
                    right: -4,
                    top: -4,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.secondary,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        linkCount.toString(),
                        style: TextStyle(
                          fontSize: 8,
                          color: theme.colorScheme.onSecondary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );

    // 正向固定词作为拖拽源
    if (entry.promptType == FixedTagPromptType.positive) {
      return Draggable<String>(
        data: entry.id,
        feedback: Material(
          color: Colors.transparent,
          child: Icon(
            Icons.link_rounded,
            color: theme.colorScheme.secondary,
            size: 32,
          ),
        ),
        childWhenDragging: Opacity(opacity: 0.35, child: anchorVisual),
        child: anchorVisual,
      );
    }

    // 负向固定词作为接收目标
    return DragTarget<String>(
      onWillAcceptWithDetails: (details) {
        final positive = state.entries.cast<FixedTagEntry?>().firstWhere(
              (entry) => entry?.id == details.data,
              orElse: () => null,
            );
        return positive?.promptType == FixedTagPromptType.positive;
      },
      onAcceptWithDetails: (details) {
        ref.read(fixedTagsNotifierProvider.notifier).createLink(
              positiveEntryId: details.data,
              negativeEntryId: entry.id,
            );
        AppToast.success(context, '联动成功');
      },
      builder: (context, candidateData, rejectedData) {
        final isActive = candidateData.isNotEmpty;
        return AnimatedScale(
          scale: isActive ? 1.3 : 1.0,
          duration: const Duration(milliseconds: 120),
          child: anchorVisual,
        );
      },
    );
  }

  void _showLinkMenu(FixedTagEntry entry) {
    final state = ref.read(fixedTagsNotifierProvider);
    final linkedEntries = entry.promptType == FixedTagPromptType.positive
        ? state.linkedNegativesOf(entry.id)
        : state.linkedPositivesOf(entry.id);
    if (linkedEntries.isEmpty) {
      AppToast.info(context, '按住正向固定词的关联图标，往下拖拽到负向固定词即可创建联动');
      return;
    }

    showDialog<void>(
      context: context,
      builder: (context) {
        return SimpleDialog(
          title: const Text('管理联动', style: TextStyle(fontSize: 16)),
          children: [
            for (final linkedEntry in linkedEntries)
              SimpleDialogOption(
                onPressed: () async {
                  Navigator.of(context).pop();
                  if (entry.promptType == FixedTagPromptType.positive) {
                    await ref
                        .read(fixedTagsNotifierProvider.notifier)
                        .removeLinkByPair(
                          positiveEntryId: entry.id,
                          negativeEntryId: linkedEntry.id,
                        );
                  } else {
                    await ref
                        .read(fixedTagsNotifierProvider.notifier)
                        .removeLinkByPair(
                          positiveEntryId: linkedEntry.id,
                          negativeEntryId: entry.id,
                        );
                  }
                },
                child: Row(
                  children: [
                    const Icon(Icons.link_off_rounded, size: 18),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text('取消联动：${linkedEntry.displayName}'),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildFooter(ThemeData theme, bool isDark) {
    final hasEntries = ref.watch(fixedTagsNotifierProvider).entries.isNotEmpty;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: isDark ? theme.colorScheme.surface : theme.colorScheme.surface,
        border: Border(
          top: BorderSide(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            OutlinedButton.icon(
              onPressed: () {
                Navigator.of(context).pop();
                context.go(AppRoutes.tagLibraryPage);
              },
              icon: const Icon(Icons.library_books_outlined, size: 16),
              label: Text(context.l10n.fixedTags_openLibrary),
            ),
            const Spacer(),
            if (hasEntries)
              OutlinedButton.icon(
                onPressed: _showClearAllConfirmation,
                icon: Icon(
                  Icons.delete_sweep_outlined,
                  size: 16,
                  color: theme.colorScheme.error,
                ),
                label: Text(
                  context.l10n.fixedTags_clearAll,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
                style: OutlinedButton.styleFrom(
                  side: BorderSide(
                    color: theme.colorScheme.error.withValues(alpha: 0.5),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _showLibraryPicker(ThemeData theme, FixedTagPromptType promptType) {
    final libraryState = ref.read(tagLibraryPageNotifierProvider);
    final entries = libraryState.entries;

    if (entries.isEmpty) {
      AppToast.info(context, '词库为空，请先添加条目');
      return;
    }

    showDialog(
      context: context,
      builder: (ctx) => _LibraryPickerDialog(
        entries: entries,
        onSelect: (entry) => _addFromLibrary(entry, promptType),
      ),
    );
  }

  Future<void> _addFromLibrary(
    TagLibraryEntry entry,
    FixedTagPromptType promptType,
  ) async {
    await ref.read(fixedTagsNotifierProvider.notifier).addEntry(
          name: entry.name,
          content: entry.content,
          weight: 1.0,
          position: FixedTagPosition.prefix,
          enabled: true,
          promptType: promptType, // 区分正负向
          sourceEntryId: entry.id, // 同步词库ID
          categoryId: entry.categoryId,
        );
  }

  void _showEditDialog(
    FixedTagEntry? entry, {
    FixedTagPromptType initialPromptType = FixedTagPromptType.positive,
  }) async {
    final result = await showDialog<FixedTagEntry>(
      context: context,
      builder: (context) => FixedTagEditDialog(
        entry: entry,
        initialPromptType: initialPromptType,
      ),
    );

    if (result != null) {
      if (entry == null) {
        await ref.read(fixedTagsNotifierProvider.notifier).addEntry(
              name: result.name,
              content: result.content,
              weight: result.weight,
              position: result.position,
              promptType: result.promptType,
              enabled: result.enabled,
            );
      } else {
        await ref.read(fixedTagsNotifierProvider.notifier).updateEntry(result);
      }
    }
  }

  void _showDeleteConfirmation(FixedTagEntry entry) async {
    final confirmed = await ThemedConfirmDialog.show(
      context: context,
      title: context.l10n.fixedTags_deleteTitle,
      content: context.l10n.fixedTags_deleteConfirm(entry.displayName),
      confirmText: context.l10n.common_delete,
      cancelText: context.l10n.common_cancel,
      type: ThemedConfirmDialogType.danger,
      icon: Icons.delete_outline,
    );

    if (confirmed) {
      ref.read(fixedTagsNotifierProvider.notifier).deleteEntry(entry.id);
    }
  }

  void _showClearAllConfirmation() async {
    final entriesCount = ref.read(fixedTagsNotifierProvider).entries.length;

    final confirmed = await ThemedConfirmDialog.show(
      context: context,
      title: context.l10n.fixedTags_clearAllTitle,
      content: context.l10n.fixedTags_clearAllConfirm(entriesCount),
      confirmText: context.l10n.fixedTags_clearAll,
      cancelText: context.l10n.common_cancel,
      type: ThemedConfirmDialogType.danger,
      icon: Icons.delete_sweep_outlined,
    );

    if (confirmed && mounted) {
      ref.read(fixedTagsNotifierProvider.notifier).clearAll();
      AppToast.success(context, context.l10n.fixedTags_clearedSuccess);
    }
  }
}

/// 词库选择对话框 (保持原样，非常适合手机端)
class _LibraryPickerDialog extends StatefulWidget {
  final List<TagLibraryEntry> entries;
  final ValueChanged<TagLibraryEntry> onSelect;

  const _LibraryPickerDialog({
    required this.entries,
    required this.onSelect,
  });

  @override
  State<_LibraryPickerDialog> createState() => _LibraryPickerDialogState();
}

class _LibraryPickerDialogState extends State<_LibraryPickerDialog> {
  String _searchQuery = '';
  final _searchController = TextEditingController();

  List<TagLibraryEntry> get _filteredEntries {
    if (_searchQuery.isEmpty) return widget.entries;
    final query = _searchQuery.toLowerCase();
    return widget.entries.where((e) {
      return e.name.toLowerCase().contains(query) ||
          e.content.toLowerCase().contains(query);
    }).toList();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final filtered = _filteredEntries;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: 420,
          maxHeight: 480,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
              child: Row(
                children: [
                  Icon(
                    Icons.playlist_add_rounded,
                    color: theme.colorScheme.primary,
                    size: 22,
                  ),
                  const SizedBox(width: 10),
                  Text(
                    '从词库添加',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: ThemedInput(
                controller: _searchController,
                decoration: InputDecoration(
                  hintText: '搜索词库条目...',
                  prefixIcon: Icon(
                    Icons.search,
                    size: 20,
                    color: theme.colorScheme.outline,
                  ),
                  isDense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(color: theme.colorScheme.outline),
                  ),
                ),
                style: const TextStyle(fontSize: 13),
                onChanged: (v) => setState(() => _searchQuery = v),
              ),
            ),
            const SizedBox(height: 4),
            Expanded(
              child: filtered.isEmpty
                  ? Center(
                      child: Text(
                        '无匹配结果',
                        style: TextStyle(color: theme.colorScheme.outline),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      itemCount: filtered.length,
                      itemBuilder: (context, index) {
                        final entry = filtered[index];
                        return _LibraryEntryTile(
                          entry: entry,
                          onTap: () {
                            widget.onSelect(entry);
                            Navigator.of(context).pop();
                          },
                        );
                      },
                    ),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}

/// 词库条目选项
class _LibraryEntryTile extends StatelessWidget {
  final TagLibraryEntry entry;
  final VoidCallback onTap;

  const _LibraryEntryTile({required this.entry, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.name.isNotEmpty ? entry.name : entry.content,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (entry.name.isNotEmpty && entry.content.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          entry.content.replaceAll('\n', ' '),
                          style: TextStyle(
                            fontSize: 11,
                            color: theme.colorScheme.outline,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                ),
              ),
              Icon(
                Icons.add_rounded,
                size: 18,
                color: theme.colorScheme.primary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 固定词条目卡片 - 紧凑版
class _FixedTagEntryTile extends StatefulWidget {
  final FixedTagEntry entry;
  final int index;
  final bool isDark;
  final Widget? linkAnchor;
  final VoidCallback onToggleEnabled;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _FixedTagEntryTile({
    super.key,
    required this.entry,
    required this.index,
    required this.isDark,
    this.linkAnchor,
    required this.onToggleEnabled,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  State<_FixedTagEntryTile> createState() => _FixedTagEntryTileState();
}

class _FixedTagEntryTileState extends State<_FixedTagEntryTile> {
  bool _isHovering = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entry = widget.entry;
    final isDark = widget.isDark;

    final posColor =
        entry.isPrefix ? theme.colorScheme.primary : theme.colorScheme.tertiary;
    final disabledOpacity = entry.enabled ? 1.0 : 0.5;

    final hasPositiveAnchor = entry.promptType == FixedTagPromptType.positive &&
        widget.linkAnchor != null;
    final hasNegativeAnchor = entry.promptType == FixedTagPromptType.negative &&
        widget.linkAnchor != null;

    // 🌟 核心修复：将 ReorderableDragStartListener 改为 ReorderableDelayedDragStartListener
    // 这样必须长按卡片才会触发拖拽，平时随便滑动绝对不会误触！
    return ReorderableDelayedDragStartListener(
      index: widget.index,
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovering = true),
        onExit: (_) => setState(() => _isHovering = false),
        child: AnimatedContainer(

          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: entry.enabled
                ? (isDark
                    ? theme.colorScheme.surfaceContainerHigh
                    : theme.colorScheme.surfaceContainerHighest)
                : theme.colorScheme.surfaceContainerLow.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(12),
            boxShadow: entry.enabled
                ? [
                    BoxShadow(
                      color: theme.colorScheme.shadow
                          .withValues(alpha: isDark ? 0.3 : 0.1),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                      spreadRadius: -2,
                    ),
                  ]
                : [],
          ),
          child: Opacity(
            opacity: disabledOpacity,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center, // 👈 强制所有元素垂直绝对居中！
              children: [
                // 1. 负向固定词的接收锚点 (左侧)
                if (hasNegativeAnchor) ...[
                  widget.linkAnchor!,
                  const SizedBox(width: 4),
                ],

                // 2. 启用开关
                ThemedSwitch(
                  value: entry.enabled,
                  onChanged: (_) => widget.onToggleEnabled(),
                  scale: 0.7,
                ),
                const SizedBox(width: 8),

                // 3. 文本与标签区 (占据剩余空间)
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 标题 + 标签 (放在同一行)
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              entry.displayName,
                              style: TextStyle(
                                fontSize: 14, // 稍微放大标题
                                fontWeight: FontWeight.w600,
                                color: entry.enabled
                                    ? theme.colorScheme.onSurface
                                    : theme.colorScheme.onSurface.withValues(alpha: 0.5),
                                decoration: entry.enabled
                                    ? null
                                    : TextDecoration.lineThrough,
                                decorationColor:
                                    theme.colorScheme.outline.withValues(alpha: 0.6),
                              ),
                              overflow: TextOverflow.ellipsis,
                              maxLines: 1,
                            ),
                          ),
                          const SizedBox(width: 6),
                          // 前缀/后缀小标签
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 4, vertical: 2),
                            decoration: BoxDecoration(
                              color: entry.enabled
                                  ? posColor.withValues(alpha: 0.15)
                                  : theme.colorScheme.outline.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              entry.isPrefix
                                  ? context.l10n.fixedTags_prefix
                                  : context.l10n.fixedTags_suffix,
                              style: TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.w600,
                                color: entry.enabled
                                    ? posColor
                                    : theme.colorScheme.outline,
                              ),
                            ),
                          ),
                          // 权重小标签
                          if (entry.weight != 1.0) ...[
                            const SizedBox(width: 4),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 4, vertical: 2),
                              decoration: BoxDecoration(
                                color: entry.enabled
                                    ? theme.colorScheme.secondary
                                        .withValues(alpha: 0.15)
                                    : theme.colorScheme.outline.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                '${entry.weight.toStringAsFixed(1)}x',
                                style: TextStyle(
                                  fontSize: 9,
                                  fontWeight: FontWeight.w600,
                                  color: entry.enabled
                                      ? theme.colorScheme.secondary
                                      : theme.colorScheme.outline,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      // 内容预览
                      if (entry.content.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            entry.content.replaceAll('\n', ' '),
                            style: TextStyle(
                              fontSize: 11,
                              color: entry.enabled
                                  ? theme.colorScheme.outline.withValues(alpha: 0.8)
                                  : theme.colorScheme.outline.withValues(alpha: 0.5),
                              height: 1.2,
                              decoration: entry.enabled
                                  ? null
                                  : TextDecoration.lineThrough,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                  ),
                ),

                // 4. 操作按钮区 (现在它们在同一条水平线上，完美对齐)
                _CompactIconButton(
                  icon: Icons.edit_outlined,
                  onPressed: widget.onEdit,
                  tooltip: context.l10n.common_edit,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  hoverColor: theme.colorScheme.primary,
                ),
                _CompactIconButton(
                  icon: Icons.close_rounded,
                  onPressed: widget.onDelete,
                  tooltip: context.l10n.common_delete,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                  hoverColor: theme.colorScheme.error,
                ),

                // 5. 正向固定词的拖拽源 (右侧)
                if (hasPositiveAnchor) ...[
                  const SizedBox(width: 2),
                  widget.linkAnchor!,
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 紧凑图标按钮
class _CompactIconButton extends StatefulWidget {
  final IconData icon;
  final VoidCallback onPressed;
  final String tooltip;
  final Color color;
  final Color hoverColor;

  const _CompactIconButton({
    required this.icon,
    required this.onPressed,
    required this.tooltip,
    required this.color,
    required this.hoverColor,
  });

  @override
  State<_CompactIconButton> createState() => _CompactIconButtonState();
}

class _CompactIconButtonState extends State<_CompactIconButton> {
  bool _isHovering = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovering = true),
        onExit: (_) => setState(() => _isHovering = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.onPressed,
          child: Padding(
            padding: const EdgeInsets.all(8), // 👈 增加四周的触摸判定范围
            child: Icon(
              widget.icon,
              size: 22, // 👈 放大图标尺寸
              color: _isHovering ? widget.hoverColor : widget.color,
            ),
          ),
        ),
      ),
    );
  }
}