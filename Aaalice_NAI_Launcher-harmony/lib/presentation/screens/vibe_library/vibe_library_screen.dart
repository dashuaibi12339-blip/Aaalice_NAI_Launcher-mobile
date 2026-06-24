import 'dart:io';
import 'dart:async';
import 'dart:ui' as ui;

import 'package:nai_launcher/harmony_compat.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/utils/app_logger.dart';
import '../../../core/utils/vibe_file_parser.dart'; // 👈 新增解析器
import '../../../core/utils/vibe_library_path_helper.dart';
import '../../../core/utils/vibe_export_utils.dart';
import '../../../core/utils/vibe_image_embedder.dart';
import '../../../data/models/vibe/vibe_library_category.dart';
import '../../../data/models/vibe/vibe_library_entry.dart';
import '../../../data/models/vibe/vibe_reference.dart';
import '../../../data/services/vibe_import_service.dart';
import '../../providers/generation/generation_params_notifier.dart';
import '../../providers/image_generation_provider.dart';
import '../../providers/selection_mode_provider.dart';
import '../../providers/vibe_library_category_provider.dart';
import '../../providers/vibe_library_provider.dart';
import '../../providers/vibe_library_selection_provider.dart';
import '../../router/app_router.dart';
import '../../widgets/bulk_action_bar.dart';
import '../../widgets/common/app_toast.dart';
import '../../widgets/common/compact_icon_button.dart';
import '../../widgets/common/themed_confirm_dialog.dart';
import '../../widgets/common/themed_input_dialog.dart';
import '../../widgets/common/pro_context_menu.dart';
import '../../widgets/gallery/gallery_state_views.dart';
import '../../../core/shortcuts/shortcut_manager.dart';
import '../../../data/models/vibe/vibe_import_progress.dart';
import '../../../data/services/vibe_library_import_repository_impl.dart';
import '../../../data/services/vibe_library_storage_service.dart'; // 👈 新增存储服务
import 'widgets/category/vibe_category_tree_view.dart';
import 'widgets/menus/vibe_import_menu.dart';
import 'widgets/vibe_library_content_view.dart';
import 'widgets/vibe_library_empty_view.dart';
import 'widgets/vibe_bundle_import_dialog.dart' as bundle_import_dialog;
import 'widgets/vibe_export_dialog_advanced.dart';
import 'widgets/vibe_image_encode_dialog.dart' as encode_dialog;
import 'widgets/vibe_import_naming_dialog.dart' as naming_dialog;

const List<String> _vibeImportImageExtensions = ['png', 'jpg', 'jpeg', 'webp']; // 👈 新增支持格式

/// 手机端专属：移除桌面拖拽，保留按钮导入和剪贴板导入，融合原作者最新存储逻辑
class VibeLibraryScreen extends ConsumerStatefulWidget {
  const VibeLibraryScreen({super.key});

  @override
  ConsumerState<VibeLibraryScreen> createState() => _VibeLibraryScreenState();
}

class _VibeLibraryScreenState extends ConsumerState<VibeLibraryScreen> {
  bool _showCategoryPanel = true;
  final TextEditingController _searchController = TextEditingController();
  Timer? _searchDebounceTimer; // 👈 新增搜索防抖
  bool _isImporting = false;
  bool _isPickingFile = false;
  ImportProgress _importProgress = const ImportProgress();
  DateTime? _lastRefreshTime;
  bool _isRefreshingInBackground = false;

  Set<String>? _reservedImportNames; // 👈 新增命名缓存

  void _beginImportSession() {
    _reservedImportNames = ref.read(vibeLibraryNotifierProvider).entries.map((entry) => entry.name.toLowerCase()).toSet();
  }

  void _endImportSession() {
    _reservedImportNames = null;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(vibeLibraryNotifierProvider.notifier).initialize();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _refreshIfNeededInBackground();
  }

  void _refreshIfNeededInBackground() {
    final now = DateTime.now();
    if (_lastRefreshTime == null || now.difference(_lastRefreshTime!) > const Duration(seconds: 5)) {
      _lastRefreshTime = now;
      if (_isRefreshingInBackground) return;
      _isRefreshingInBackground = true;
      Future.delayed(const Duration(milliseconds: 300), () async {
        if (mounted) {
          try {
            await ref.read(vibeLibraryNotifierProvider.notifier).loadFromCache();
            await ref.read(vibeLibraryNotifierProvider.notifier).syncWithFileSystem();
          } finally {
            _isRefreshingInBackground = false;
          }
        } else {
          _isRefreshingInBackground = false;
        }
      });
    }
  }

  @override
  void dispose() {
    _searchDebounceTimer?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(vibeLibraryNotifierProvider);
    final categoryState = ref.watch(vibeLibraryCategoryNotifierProvider);
    final selectionState = ref.watch(vibeLibrarySelectionNotifierProvider);
    final screenWidth = MediaQuery.of(context).size.width;
    final isMobile = screenWidth <= 800;
    final theme = Theme.of(context);

    final contentWidth = _showCategoryPanel && !isMobile ? screenWidth - 250 : screenWidth;
    final columns = (contentWidth / 200).floor().clamp(2, 8);
    final itemWidth = (contentWidth - 32) / columns;

    return Scaffold(
      drawer: isMobile ? Drawer(
        child: _buildCategoryPanel(theme, state, categoryState, screenWidth),
      ) : null,
      body: Shortcuts(
        shortcuts: <LogicalKeySet, Intent>{
          LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.keyI): const VibeImportIntent(),
          LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.keyE): const VibeExportIntent(),
        },
        child: Actions(
          actions: <Type, Action<Intent>>{
            VibeImportIntent: CallbackAction<VibeImportIntent>(
              onInvoke: (intent) {
                if (!(_isImporting || _isPickingFile)) _importVibes();
                return null;
              },
            ),
            VibeExportIntent: CallbackAction<VibeExportIntent>(
              onInvoke: (intent) {
                if (ref.read(vibeLibraryNotifierProvider).entries.isNotEmpty) _exportVibes();
                return null;
              },
            ),
          },
          child: Stack(
            children: [
              Row(
                children: [
                  if (_showCategoryPanel && !isMobile)
                    _buildCategoryPanel(theme, state, categoryState, screenWidth),
                  Expanded(
                    child: Column(
                      children: [
                        _buildToolbar(state, selectionState, theme, screenWidth),
                        Expanded(child: _buildBody(state, columns, itemWidth, selectionState)),
                        if (!state.isLoading && state.filteredEntries.isNotEmpty && state.totalPages > 0)
                          _buildPaginationBar(state, contentWidth),
                      ],
                    ),
                  ),
                ],
              ),
              if (_isImporting) _buildImportOverlay(theme),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCategoryPanel(ThemeData theme, VibeLibraryState state, VibeLibraryCategoryState categoryState, double screenWidth) {
    return Container(
      width: 250,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: Border(right: BorderSide(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3), width: 1)),
      ),
      child: SafeArea(
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              constraints: const BoxConstraints(minHeight: 62),
              child: Row(
                children: [
                  Icon(Icons.folder_outlined, size: 20, color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  Expanded(child: Text('分类', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600))),
                  FilledButton.tonalIcon(
                    onPressed: () => _showCreateCategoryDialog(context),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('新建', style: TextStyle(fontSize: 13)),
                    style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8)),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3)),
            Expanded(
              child: VibeCategoryTreeView(
                categories: categoryState.categories,
                totalEntryCount: state.entries.length,
                favoriteCount: state.favoriteCount,
                selectedCategoryId: categoryState.selectedCategoryId,
                onCategorySelected: (id) {
                  ref.read(vibeLibraryCategoryNotifierProvider.notifier).selectCategory(id);
                  if (id == 'favorites') {
                    ref.read(vibeLibraryNotifierProvider.notifier).setFavoritesOnly(true);
                  } else {
                    ref.read(vibeLibraryNotifierProvider.notifier).setFavoritesOnly(false);
                    ref.read(vibeLibraryNotifierProvider.notifier).setCategoryFilter(id);
                  }
                  if (screenWidth <= 800 && Navigator.canPop(context)) {
                    Navigator.pop(context);
                  }
                },
                onCategoryRename: (id, newName) async => await ref.read(vibeLibraryCategoryNotifierProvider.notifier).renameCategory(id, newName),
                onCategoryDelete: (id) async {
                  final confirmed = await ThemedConfirmDialog.show(
                    context: context,
                    title: '确认删除',
                    content: '确定要删除此分类吗？分类下的Vibe将被移动到未分类。',
                    confirmText: '删除',
                    cancelText: '取消',
                    type: ThemedConfirmDialogType.danger,
                    icon: Icons.delete_outline,
                  );
                  if (confirmed) await ref.read(vibeLibraryCategoryNotifierProvider.notifier).deleteCategory(id, moveEntriesToParent: true);
                },
                onAddSubCategory: (parentId) async {
                  final name = await ThemedInputDialog.show(
                    context: context, title: parentId == null ? '新建分类' : '新建子分类', hintText: '请输入分类名称', confirmText: '创建', cancelText: '取消',
                  );
                  if (name != null && name.isNotEmpty) await ref.read(vibeLibraryCategoryNotifierProvider.notifier).createCategory(name, parentId: parentId);
                },
                onCategoryMove: (categoryId, newParentId) async => await ref.read(vibeLibraryCategoryNotifierProvider.notifier).moveCategory(categoryId, newParentId),
              ),
            ),
          ],
        ),
      ),
    );
  }
  
  Widget _buildToolbar(VibeLibraryState state, SelectionModeState selectionState, ThemeData theme, double screenWidth) {
    if (selectionState.isActive) return _buildBulkActionBar(state, selectionState, theme);

    return ClipRRect(
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: SafeArea(
          bottom: false,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: theme.brightness == Brightness.dark ? theme.colorScheme.surfaceContainerHigh.withValues(alpha: 0.9) : theme.colorScheme.surface.withValues(alpha: 0.8),
              border: Border(bottom: BorderSide(color: theme.dividerColor.withValues(alpha: theme.brightness == Brightness.dark ? 0.2 : 0.3))),
            ),
            child: Row(
              children: [
                Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Vibe库', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
                    if (!state.isLoading)
                      Text(
                        state.hasFilters ? '${state.filteredCount}/${state.totalCount}' : '${state.totalCount}',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.primary,
                          fontSize: 10,
                        ),
                      ),
                  ],
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ShaderMask(
                    shaderCallback: (Rect bounds) {
                      return LinearGradient(
                        begin: Alignment.centerLeft,
                        end: Alignment.centerRight,
                        colors: [
                          theme.colorScheme.surface,
                          Colors.transparent,
                          Colors.transparent,
                          theme.colorScheme.surface,
                        ],
                        stops: const [0.0, 0.05, 0.95, 1.0],
                      ).createShader(bounds);
                    },
                    blendMode: BlendMode.dstOut,
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(width: 140, child: _buildSearchField(theme, state)),
                          const SizedBox(width: 8),
                          _buildSortButton(theme, state),
                          const SizedBox(width: 4),
                          Builder(
                            builder: (ctx) => CompactIconButton(
                              icon: screenWidth <= 800 ? Icons.folder_outlined : (_showCategoryPanel ? Icons.view_sidebar : Icons.view_sidebar_outlined),
                              label: '分类',
                              tooltip: screenWidth <= 800 ? '打开分类面板' : (_showCategoryPanel ? '隐藏分类面板' : '显示分类面板'),
                              onPressed: () {
                                if (screenWidth <= 800) {
                                  Scaffold.of(ctx).openDrawer();
                                } else {
                                  setState(() => _showCategoryPanel = !_showCategoryPanel);
                                }
                              },
                            ),
                          ),
                          const SizedBox(width: 4),
                          CompactIconButton(
                            icon: Icons.checklist,
                            label: '多选',
                            tooltip: '进入选择模式',
                            onPressed: () => ref.read(vibeLibrarySelectionNotifierProvider.notifier).enter(),
                          ),
                          const SizedBox(width: 4),
                          GestureDetector(
                            onSecondaryTapDown: (details) {
                              if (!(_isImporting || _isPickingFile)) _showImportMenu(details.globalPosition);
                            },
                            child: CompactIconButton(
                              icon: Icons.file_download_outlined,
                              label: '导入',
                              tooltip: '长按或右键查看更多导入选项',
                              isLoading: _isPickingFile,
                              onPressed: (_isImporting || _isPickingFile) ? null : () => _importVibes(),
                            ),
                          ),
                          const SizedBox(width: 4),
                          CompactIconButton(
                            icon: Icons.file_upload_outlined,
                            label: '导出',
                            tooltip: '导出Vibe到文件',
                            onPressed: state.entries.isEmpty ? null : () => _exportVibes(),
                          ),
                          const SizedBox(width: 4),
                          _buildRefreshButton(state, theme),
                        ],
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
  }

  Widget _buildSearchField(ThemeData theme, VibeLibraryState state) {
    return Container(
      height: 36,
      constraints: const BoxConstraints(maxWidth: 300),
      decoration: BoxDecoration(color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4), borderRadius: BorderRadius.circular(18)),
      child: TextField(
        controller: _searchController,
        style: theme.textTheme.bodyMedium,
        decoration: InputDecoration(
          hintText: '搜索...',
          hintStyle: TextStyle(color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5), fontSize: 13),
          prefixIcon: Icon(Icons.search, size: 18, color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6)),
          suffixIcon: _searchController.text.isNotEmpty
              ? IconButton(
                  icon: Icon(Icons.close, size: 16, color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6)),
                  onPressed: () {
                    _searchDebounceTimer?.cancel();
                    _searchController.clear();
                    ref.read(vibeLibraryNotifierProvider.notifier).clearSearch();
                    setState(() {});
                  },
                )
              : null,
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(vertical: 8),
          isDense: true,
        ),
        onChanged: (value) {
          setState(() {});
          _searchDebounceTimer?.cancel();
          _searchDebounceTimer = Timer(const Duration(milliseconds: 250), () {
            if (mounted) ref.read(vibeLibraryNotifierProvider.notifier).setSearchQuery(value);
          });
        },
        onSubmitted: (value) => ref.read(vibeLibraryNotifierProvider.notifier).setSearchQuery(value),
      ),
    );
  }

  Widget _buildSortButton(ThemeData theme, VibeLibraryState state) {
    IconData sortIcon;
    String sortLabel;
    switch (state.sortOrder) {
      case VibeLibrarySortOrder.createdAt: sortIcon = Icons.access_time; sortLabel = '时间'; break;
      case VibeLibrarySortOrder.lastUsed: sortIcon = Icons.history; sortLabel = '最近'; break;
      case VibeLibrarySortOrder.usedCount: sortIcon = Icons.trending_up; sortLabel = '次数'; break;
      case VibeLibrarySortOrder.name: sortIcon = Icons.sort_by_alpha; sortLabel = '名称'; break;
    }
    return PopupMenuButton<VibeLibrarySortOrder>(
      tooltip: '排序方式',
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4), borderRadius: BorderRadius.circular(8)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(sortIcon, size: 16),
            const SizedBox(width: 4),
            Text(sortLabel, style: const TextStyle(fontSize: 12)),
            Icon(state.sortDescending ? Icons.arrow_drop_down : Icons.arrow_drop_up, size: 16),
          ],
        ),
      ),
      itemBuilder: (context) => [
        _buildSortMenuItem(VibeLibrarySortOrder.createdAt, '创建时间', Icons.access_time, state),
        _buildSortMenuItem(VibeLibrarySortOrder.lastUsed, '最近使用', Icons.history, state),
        _buildSortMenuItem(VibeLibrarySortOrder.usedCount, '使用次数', Icons.trending_up, state),
        _buildSortMenuItem(VibeLibrarySortOrder.name, '名称', Icons.sort_by_alpha, state),
      ],
      onSelected: (order) => ref.read(vibeLibraryNotifierProvider.notifier).setSortOrder(order),
    );
  }

  PopupMenuItem<VibeLibrarySortOrder> _buildSortMenuItem(VibeLibrarySortOrder order, String label, IconData icon, VibeLibraryState state) {
    final isSelected = state.sortOrder == order;
    return PopupMenuItem(
      value: order,
      child: Row(
        children: [
          Icon(icon, size: 18, color: isSelected ? Colors.blue : null),
          const SizedBox(width: 8),
          Text(label, style: TextStyle(color: isSelected ? Colors.blue : null, fontWeight: isSelected ? FontWeight.w600 : null)),
          if (isSelected) ...[const Spacer(), Icon(state.sortDescending ? Icons.arrow_downward : Icons.arrow_upward, size: 16, color: Colors.blue)],
        ],
      ),
    );
  }

  Widget _buildRefreshButton(VibeLibraryState state, ThemeData theme) {
    if (state.isLoading) {
      return Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: theme.colorScheme.outline.withValues(alpha: 0.2), width: 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, valueColor: AlwaysStoppedAnimation<Color>(theme.colorScheme.primary))),
            const SizedBox(width: 6),
            Text('加载...', style: theme.textTheme.labelMedium?.copyWith(fontSize: 12, fontWeight: FontWeight.w500, color: theme.colorScheme.onSurfaceVariant)),
          ],
        ),
      );
    }
    return CompactIconButton(icon: Icons.refresh, label: '刷新', tooltip: '刷新Vibe库', onPressed: () => ref.read(vibeLibraryNotifierProvider.notifier).reload(syncFileSystem: true, showLoading: true));
  }

  Widget _buildBulkActionBar(VibeLibraryState state, SelectionModeState selectionState, ThemeData theme) {
    final currentIds = state.currentEntries.map((e) => e.id).toList();
    final isAllSelected = currentIds.isNotEmpty && currentIds.every((id) => selectionState.selectedIds.contains(id));
    return BulkActionBar(
      selectedCount: selectionState.selectedIds.length,
      isAllSelected: isAllSelected,
      onExit: () => ref.read(vibeLibrarySelectionNotifierProvider.notifier).exit(),
      onSelectAll: () {
        if (isAllSelected) ref.read(vibeLibrarySelectionNotifierProvider.notifier).clearSelection();
        else ref.read(vibeLibrarySelectionNotifierProvider.notifier).selectAll(currentIds);
      },
      actions: [
        BulkActionItem(icon: Icons.send, label: '发送', onPressed: () => _batchSendToGeneration(), color: theme.colorScheme.primary),
        BulkActionItem(icon: Icons.drive_file_move_outline, label: '移动', onPressed: () => _showMoveToCategoryDialog(context), color: theme.colorScheme.secondary),
        BulkActionItem(icon: Icons.file_upload_outlined, label: '导出', onPressed: () => _batchExport(), color: theme.colorScheme.secondary),
        BulkActionItem(icon: Icons.favorite_border, label: '收藏', onPressed: () => _batchToggleFavorite(), color: theme.colorScheme.primary),
        BulkActionItem(icon: Icons.delete_outline, label: '删除', onPressed: () => _batchDelete(), color: theme.colorScheme.error, isDanger: true, showDividerBefore: true),
      ],
    );
  }

  Widget _buildBody(VibeLibraryState state, int columns, double itemWidth, SelectionModeState selectionState) {
    if (state.error != null) return GalleryErrorView(error: state.error, onRetry: () => ref.read(vibeLibraryNotifierProvider.notifier).reload());
    if (state.isInitializing && state.entries.isEmpty) return const GalleryLoadingView();
    if (state.entries.isEmpty) return const VibeLibraryEmptyView();
    return VibeLibraryContentView(columns: columns, itemWidth: itemWidth);
  }

  Widget _buildPaginationBar(VibeLibraryState state, double contentWidth) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(color: theme.colorScheme.surfaceContainerLow, border: Border(top: BorderSide(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3)))),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(icon: const Icon(Icons.chevron_left), onPressed: state.currentPage > 0 ? () => ref.read(vibeLibraryNotifierProvider.notifier).loadPreviousPage() : null),
          Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Text('${state.currentPage + 1} / ${state.totalPages} 页', style: theme.textTheme.bodyMedium)),
          IconButton(icon: const Icon(Icons.chevron_right), onPressed: state.currentPage < state.totalPages - 1 ? () => ref.read(vibeLibraryNotifierProvider.notifier).loadNextPage() : null),
          const SizedBox(width: 16),
          Text('每页:', style: theme.textTheme.bodySmall),
          const SizedBox(width: 8),
          DropdownButton<int>(
            value: state.pageSize,
            underline: const SizedBox(),
            items: [20, 50, 100].map((size) => DropdownMenuItem(value: size, child: Text('$size'))).toList(),
            onChanged: (value) { if (value != null) ref.read(vibeLibraryNotifierProvider.notifier).setPageSize(value); },
          ),
          const Spacer(),
          Text('共 ${state.filteredCount} 个', style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }

  Future<void> _showCreateCategoryDialog(BuildContext context) async {
    final name = await ThemedInputDialog.show(context: context, title: '新建分类', hintText: '请输入分类名称', confirmText: '创建', cancelText: '取消');
    if (name != null && name.isNotEmpty) await ref.read(vibeLibraryCategoryNotifierProvider.notifier).createCategory(name);
  }

  Future<void> _showMoveToCategoryDialog(BuildContext context) async {
    final selectionState = ref.read(vibeLibrarySelectionNotifierProvider);
    final categories = ref.read(vibeLibraryCategoryNotifierProvider).categories;
    if (categories.isEmpty) { if (mounted) AppToast.warning(context, '没有可用的分类'); return; }
    final selectedCategory = await showDialog<VibeLibraryCategory>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('移动到分类'),
        content: SizedBox(
          width: 300,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: categories.length + 1,
            itemBuilder: (context, index) {
              if (index == 0) return ListTile(leading: const Icon(Icons.folder_outlined), title: const Text('未分类'), onTap: () => Navigator.of(context).pop(null));
              final category = categories[index - 1];
              return ListTile(leading: const Icon(Icons.folder), title: Text(category.name), onTap: () => Navigator.of(context).pop(category));
            },
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('取消'))],
      ),
    );
    if (selectedCategory == null || !mounted) return;
    final categoryId = selectedCategory.id;
    final ids = selectionState.selectedIds.toList();
    var movedCount = 0;
    for (final id in ids) {
      final result = await ref.read(vibeLibraryNotifierProvider.notifier).updateEntryCategory(id, categoryId);
      if (result != null) movedCount++;
    }
    ref.read(vibeLibrarySelectionNotifierProvider.notifier).exit();
    if (!context.mounted) return;
    AppToast.success(context, '已移动 $movedCount 个Vibe');
  }

  Future<void> _batchToggleFavorite() async {
    final selectionState = ref.read(vibeLibrarySelectionNotifierProvider);
    final ids = selectionState.selectedIds.toList();
    for (final id in ids) await ref.read(vibeLibraryNotifierProvider.notifier).toggleFavorite(id);
    if (mounted) { AppToast.success(context, '收藏状态已更新'); ref.read(vibeLibrarySelectionNotifierProvider.notifier).exit(); }
  }

  // 👈 新增：通过 storage 解析完整数据
  Future<List<VibeLibraryEntry>> _resolveEntriesByIds(List<String> ids) async {
    if (ids.isEmpty) return const [];
    final state = ref.read(vibeLibraryNotifierProvider);
    final entriesById = {for (final entry in state.entries) entry.id: entry};
    final entries = <VibeLibraryEntry>[];
    for (final id in ids) {
      final entry = entriesById[id];
      if (entry != null) entries.add(entry);
    }
    return _resolveEntriesForAction(entries);
  }

  Future<List<VibeLibraryEntry>> _resolveEntriesForAction(List<VibeLibraryEntry> entries) async {
    if (entries.isEmpty) return const [];
    final storage = ref.read(vibeLibraryStorageServiceProvider);
    final resolvedEntries = <VibeLibraryEntry>[];
    for (final entry in entries) {
      resolvedEntries.add(await storage.getEntry(entry.id) ?? entry);
    }
    return resolvedEntries;
  }

  Future<void> _batchSendToGeneration() async {
    final selectionState = ref.read(vibeLibrarySelectionNotifierProvider);
    final selectedIds = selectionState.selectedIds.toList();
    if (selectedIds.isEmpty) return;
    if (selectedIds.length > 16) {
      if (mounted) {
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(title: const Text('数量过多'), content: Text('选中了 ${selectedIds.length} 个，最多只能同时使用16个。'), actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('确定'))]),
        );
      }
      return;
    }
    final selectedEntries = await _resolveEntriesByIds(selectedIds);
    if (selectedEntries.isEmpty) return;
    
    final paramsNotifier = ref.read(generationParamsNotifierProvider.notifier);
    final currentParams = ref.read(generationParamsNotifierProvider);
    final currentVibeCount = currentParams.vibeReferencesV4.length;
    final willExceedLimit = currentVibeCount + selectedEntries.length > 16;
    if (willExceedLimit) {
      if (mounted) {
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(title: const Text('数量过多'), content: Text('当前已有 $currentVibeCount 个，还可以添加 ${16 - currentVibeCount} 个。'), actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('确定'))]),
        );
      }
      return;
    }
    final vibes = selectedEntries.map((e) => e.toVibeReference()).toList();
    paramsNotifier.addVibeReferences(vibes, recordUsage: false);
    if (mounted) AppToast.success(context, '已发送 ${selectedEntries.length} 个Vibe');
    ref.read(vibeLibrarySelectionNotifierProvider.notifier).exit();
    if (mounted) context.go(AppRoutes.home);
  }

  Future<void> _batchExport() async {
    final selectionState = ref.read(vibeLibrarySelectionNotifierProvider);
    final ids = selectionState.selectedIds.toList();
    if (ids.isEmpty) return;
    final selectedEntries = await _resolveEntriesByIds(ids);
    if (selectedEntries.isEmpty) return;
    await _exportVibes(specificEntries: selectedEntries);
    ref.read(vibeLibrarySelectionNotifierProvider.notifier).exit();
  }

  Future<void> _batchDelete() async {
    final selectionState = ref.read(vibeLibrarySelectionNotifierProvider);
    final ids = selectionState.selectedIds.toList();
    final confirmed = await ThemedConfirmDialog.show(
      context: context, title: '确认删除', content: '确定要删除选中的 ${ids.length} 个Vibe吗？', confirmText: '删除', cancelText: '取消', type: ThemedConfirmDialogType.danger, icon: Icons.delete_forever_outlined,
    );
    if (confirmed) {
      await ref.read(vibeLibraryNotifierProvider.notifier).deleteEntries(ids);
      if (mounted) { AppToast.success(context, '已删除 ${ids.length} 个Vibe'); ref.read(vibeLibrarySelectionNotifierProvider.notifier).exit(); }
    }
  }

  void _showImportMenu(Offset position) {
    Navigator.of(context).push(
      ImportMenu(
        position: position,
        items: [
          ProMenuItem(id: 'import_file', label: '从文件导入', icon: Icons.folder_outlined, onTap: () => _importVibes()),
          ProMenuItem(id: 'import_image', label: '从图片导入', icon: Icons.image_outlined, onTap: () => _importVibesFromImage()),
          ProMenuItem(id: 'import_clipboard', label: '从剪贴板导入编码', icon: Icons.content_paste, onTap: () => _importVibesFromClipboard()),
        ],
        onSelect: (_) {},
      ),
    );
  }

  Future<void> _importVibes() async {
    final files = await _pickImportFiles();
    if (files == null || files.isEmpty) return;
    _beginImportSession();
    if (!mounted) { _endImportSession(); return; }
    setState(() => _isImporting = true);
    try {
      final (imageFiles, regularFiles) = await _categorizeFiles(files);
      final currentCategoryId = ref.read(vibeLibraryNotifierProvider).selectedCategoryId;
      final targetCategoryId = (currentCategoryId != null && currentCategoryId != 'favorites') ? currentCategoryId : null;
      final result = await _processImportSources(imageItems: imageFiles, vibeFiles: regularFiles, targetCategoryId: targetCategoryId, onProgress: (current, total, message) { AppLogger.d(message, 'VibeLibrary'); });
      if (!mounted) return;
      setState(() => _isImporting = false);
      await _handleImportResult(result.success, result.fail, skipReload: result.hasEncoding);
    } finally {
      _endImportSession();
      if (mounted && _isImporting) setState(() => _isImporting = false);
    }
  }

  Future<List<PlatformFile>?> _pickImportFiles() async {
    if (!mounted) return null;
    setState(() => _isPickingFile = true);
    try {
      // 💣 【终极破壁】：手机端强制使用 FileType.any，彻底粉碎安卓的类型隔离！
      final isMobile = Platform.isAndroid || Platform.isIOS || Platform.operatingSystem == 'ohos';
      final result = await FilePicker.platform.pickFiles(
        type: isMobile ? FileType.any : FileType.custom,
        allowedExtensions: isMobile 
            ? null 
            : ['naiv4vibe', 'naiv4vibebundle', ..._vibeImportImageExtensions],
        allowMultiple: true, 
        dialogTitle: '选择要导入的 Vibe 文件', 
        withData: false, 
        lockParentWindow: true
      );
      
      if (result == null || result.files.isEmpty) return null;

      // 🛡️ 手动拦截：因为手机端放开了所有文件，这里用代码自己把不支持的后缀踢掉
      if (isMobile) {
        final validExts = ['naiv4vibe', 'naiv4vibebundle', ..._vibeImportImageExtensions];
        final filteredFiles = result.files.where((file) {
          final ext = file.name.split('.').last.toLowerCase();
          return validExts.contains(ext);
        }).toList();
        return filteredFiles;
      }

      return result.files;
    } finally {
      if (mounted) setState(() => _isPickingFile = false);
    }
  }
  
  Future<(List<VibeImageImportItem>, List<PlatformFile>)> _categorizeFiles(List<PlatformFile> files) async {
    final imageFiles = <VibeImageImportItem>[];
    final regularFiles = <PlatformFile>[];
    for (final file in files) {
      final ext = file.extension?.toLowerCase() ?? '';
      if (_vibeImportImageExtensions.contains(ext)) {
        try {
          final bytes = await _readPlatformFileBytes(file);
          imageFiles.add(VibeImageImportItem(source: file.name, bytes: bytes));
        } catch (e) { AppLogger.e('读取图片失败: ${file.name}', e, null, 'VibeLibrary'); }
      } else if (ext == 'naiv4vibe' || ext == 'naiv4vibebundle') {
        regularFiles.add(file);
      }
    }
    return (imageFiles, regularFiles);
  }

  Future<({int success, int fail, bool hasEncoding})> _processImportSources({required List<VibeImageImportItem> imageItems, required List<PlatformFile> vibeFiles, String? targetCategoryId, required ImportProgressCallback onProgress}) async {
    final storage = ref.read(vibeLibraryStorageServiceProvider);
    final repository = VibeLibraryStorageImportRepository(storage);
    final importService = VibeImportService(repository: repository);
    var totalSuccess = 0; var totalFail = 0; var hasEncoding = false;
    final totalCount = imageItems.length + vibeFiles.length;

    for (var i = 0; i < imageItems.length; i++) {
      final imageItem = imageItems[i];
      onProgress(i + 1, totalCount, '导入图片(${i + 1}/${imageItems.length}): ${imageItem.source}');
      final result = await _processSingleImageImport(imageFile: imageItem, targetCategoryId: targetCategoryId, onEncodingTriggered: () => hasEncoding = true);
      if (result == true) totalSuccess++; else if (result == false) totalFail++;
    }

    if (vibeFiles.isNotEmpty) {
      try {
        var applyNamingToAll = false; String? batchNamingBase;
        final result = await importService.importFromFile(
          files: vibeFiles, categoryId: targetCategoryId,
          onProgress: (current, _, message) => onProgress(imageItems.length + current, totalCount, message),
          onNaming: (suggestedName, {required bool isBatch, Uint8List? thumbnail}) async {
            if (!mounted) return null;
            if (isBatch && applyNamingToAll && batchNamingBase != null) return batchNamingBase;
            final namingResult = await naming_dialog.VibeImportNamingDialog.show(context: context, suggestedName: suggestedName, thumbnail: thumbnail, isBatchImport: isBatch);
            if (namingResult == null || namingResult.name.trim().isEmpty) return null;
            if (isBatch && namingResult.applyToAll) { applyNamingToAll = true; batchNamingBase = namingResult.name.trim(); }
            return namingResult.name.trim();
          },
          onBundleOption: (bundleName, vibes) async {
            if (!mounted) return null;
            final bundleResult = await bundle_import_dialog.VibeBundleImportDialog.show(
              context: context, 
              bundleName: bundleName, 
              vibeNames: vibes.map((v) => v.displayName).toList(),
              vibeReferences: vibes, // 👈 核心合并：传入 vibes 引用给弹窗
            );
            if (bundleResult == null) return null;
            switch (bundleResult.option) {
              case bundle_import_dialog.BundleImportOption.keepAsBundle: 
                return BundleImportOption.keepAsBundle(configuredReferences: bundleResult.configuredVibes); // 👈 核心合并：接收修改后的参数
              case bundle_import_dialog.BundleImportOption.split: 
                return BundleImportOption.split(configuredReferences: bundleResult.configuredVibes); // 👈 核心合并
              case bundle_import_dialog.BundleImportOption.importSelected: 
                return BundleImportOption.select(bundleResult.selectedIndices ?? const <int>[], configuredReferences: bundleResult.configuredVibes); // 👈 核心合并
            }
          },       
        );
        totalSuccess += result.successCount; totalFail += result.failCount;
      } catch (e) { totalFail += vibeFiles.length; }
    }
    return (success: totalSuccess, fail: totalFail, hasEncoding: hasEncoding);
  }

  Future<void> _handleImportResult(int totalSuccess, int totalFail, {bool skipReload = false}) async {
    if (totalSuccess == 0 && totalFail == 0) return;
    if (totalSuccess > 0 && !skipReload) await ref.read(vibeLibraryNotifierProvider.notifier).loadFromCache();
    if (!mounted) return;
    if (totalFail == 0) AppToast.success(context, '成功导入 $totalSuccess 个 Vibe');
    else AppToast.warning(context, '导入完成: $totalSuccess 成功, $totalFail 失败');
  }

  Future<Uint8List> _readPlatformFileBytes(PlatformFile file) async {
    if (file.bytes != null) return file.bytes!;
    final path = file.path;
    if (path == null || path.isEmpty) throw ArgumentError('Empty path');
    return File(path).readAsBytes();
  }

  Future<void> _exportVibes({List<VibeLibraryEntry>? specificEntries}) async {
    final state = ref.read(vibeLibraryNotifierProvider);
    final entriesToExport = await _resolveEntriesForAction(specificEntries ?? state.entries);
    if (entriesToExport.isEmpty || !mounted) return;
    await showDialog<void>(context: context, builder: (context) => VibeExportDialogAdvanced(entries: entriesToExport));
  }

  Widget _buildImportOverlay(ThemeData theme) {
    final hasProgress = _importProgress.isActive;
    final progressValue = _importProgress.progress;
    return Positioned.fill(
      child: Container(
        color: Colors.black.withValues(alpha: 0.3),
        child: Center(
          child: Container(
            width: 320, padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
            decoration: BoxDecoration(color: theme.colorScheme.surface, borderRadius: BorderRadius.circular(12), boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 20)]),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(width: 48, height: 48, child: CircularProgressIndicator(strokeWidth: 4, value: progressValue, valueColor: AlwaysStoppedAnimation<Color>(theme.colorScheme.primary))),
                const SizedBox(height: 16), Text('正在导入...', style: theme.textTheme.titleMedium),
                if (hasProgress) ...[const SizedBox(height: 8), Text('${_importProgress.current} / ${_importProgress.total}', style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant))],
                if (_importProgress.message.isNotEmpty) ...[const SizedBox(height: 8), Text(_importProgress.message, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant), maxLines: 2, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center)],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _importVibesFromImage() async {
    if (!mounted) return;
    _beginImportSession();
    setState(() => _isPickingFile = true);
    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: _vibeImportImageExtensions, allowMultiple: true, dialogTitle: '选择包含 Vibe 的图片', withData: false, lockParentWindow: true);
    } finally {
      if (mounted) setState(() => _isPickingFile = false);
    }
    if (!mounted || result == null || result.files.isEmpty) { _endImportSession(); return; }
    setState(() => _isImporting = true);
    final currentCategoryId = ref.read(vibeLibraryNotifierProvider).selectedCategoryId;
    final targetCategoryId = (currentCategoryId != null && currentCategoryId != 'favorites') ? currentCategoryId : null;
    final imageFiles = <VibeImageImportItem>[];
    for (final file in result.files) {
      try {
        final bytes = await _readPlatformFileBytes(file);
        imageFiles.add(VibeImageImportItem(source: file.name, bytes: bytes));
      } catch (e) { AppLogger.e('读取图片文件失败: ${file.name}', e, null, 'VibeLibrary'); }
    }
    var totalSuccess = 0; var totalFail = 0;
    try {
      for (final imageFile in imageFiles) {
        final result = await _processSingleImageImport(imageFile: imageFile, targetCategoryId: targetCategoryId);
        if (result == true) totalSuccess++; else if (result == false) totalFail++;
      }
      if (!mounted) return;
      setState(() => _isImporting = false);
      if (totalSuccess == 0 && totalFail == 0) return;
      if (totalSuccess > 0) await ref.read(vibeLibraryNotifierProvider.notifier).loadFromCache();
      if (mounted) {
        if (totalFail == 0) AppToast.success(context, '成功导入 $totalSuccess 个 Vibe');
        else AppToast.warning(context, '导入完成: $totalSuccess 成功, $totalFail 失败');
      }
    } finally {
      _endImportSession();
      if (mounted && _isImporting) setState(() => _isImporting = false);
    }
  }

  bool _isNoVibeDataError(Object e) {
    return e is NoVibeDataException || e.toString().contains('No naiv4vibe metadata');
  }

  Future<bool?> _processSingleImageImport({required VibeImageImportItem imageFile, String? targetCategoryId, VoidCallback? onEncodingTriggered}) async {
    try {
      final references = await VibeFileParser.parseFile(imageFile.source, imageFile.bytes);
      final shouldEncodeAsRawImage = references.isNotEmpty && references.every((r) => r.sourceType == VibeSourceType.rawImage && r.vibeEncoding.isEmpty);
      if (shouldEncodeAsRawImage) {
        onEncodingTriggered?.call();
        return await _handleImageEncoding(imageFile: imageFile, targetCategoryId: targetCategoryId);
      }
      final encodedReferences = references.where((r) => r.vibeEncoding.isNotEmpty).toList();
      if (encodedReferences.isEmpty) {
        onEncodingTriggered?.call();
        return await _handleImageEncoding(imageFile: imageFile, targetCategoryId: targetCategoryId);
      }
      if (encodedReferences.length > 1) {
        return await _handleBundleImport(imageFile: imageFile, vibes: encodedReferences, targetCategoryId: targetCategoryId);
      }
      return await _saveVibeReference(reference: encodedReferences.first, categoryId: targetCategoryId);
    } on NoVibeDataException {
      onEncodingTriggered?.call();
      return await _handleImageEncoding(imageFile: imageFile, targetCategoryId: targetCategoryId);
    } catch (e) {
      if (_isNoVibeDataError(e)) {
        onEncodingTriggered?.call();
        return await _handleImageEncoding(imageFile: imageFile, targetCategoryId: targetCategoryId);
      }
      return false;
    }
  }

  Future<bool> _saveVibeReference({required VibeReference reference, String? categoryId}) async {
    try {
      final storage = ref.read(vibeLibraryStorageServiceProvider);
      final baseName = reference.displayName.trim().isEmpty ? 'vibe_${DateTime.now().millisecondsSinceEpoch}' : reference.displayName.trim();
      final uniqueName = _generateUniqueName(baseName);
      final entry = VibeLibraryEntry.fromVibeReference(name: uniqueName, vibeData: reference, categoryId: categoryId);
      await storage.saveEntry(entry);
      return true;
    } catch (e) { return false; }
  }

  String _generateUniqueName(String baseName) {
    final existingNames = _reservedImportNames ?? ref.read(vibeLibraryNotifierProvider).entries.map((e) => e.name.toLowerCase()).toSet();
    if (!existingNames.contains(baseName.toLowerCase())) {
      _reservedImportNames?.add(baseName.toLowerCase());
      return baseName;
    }
    var index = 2; var candidateName = '$baseName ($index)';
    while (existingNames.contains(candidateName.toLowerCase())) { index++; candidateName = '$baseName ($index)'; }
    _reservedImportNames?.add(candidateName.toLowerCase());
    return candidateName;
  }

  Future<bool?> _handleBundleImport({required VibeImageImportItem imageFile, required List<VibeReference> vibes, String? targetCategoryId}) async {
    if (!mounted) return null;
    final result = await showDialog<bundle_import_dialog.BundleImportResult>(
      context: context,
      builder: (context) => bundle_import_dialog.VibeBundleImportDialog(
        bundleName: imageFile.source, 
        vibeNames: vibes.map((v) => v.displayName).toList(),
        vibeReferences: vibes, // 👈 核心合并：传入 vibes 引用给弹窗
      ),
    );
    if (result == null) return null;
    
    // 👈 核心合并：使用原作者新增的提取逻辑，获取配置过的新参数
    final selectedVibes = _getSelectedVibesForBundle(result, vibes);
    if (selectedVibes == null) return null;

    if (result.option == bundle_import_dialog.BundleImportOption.keepAsBundle) {
      return await _saveAsBundle(vibes: selectedVibes, bundleName: imageFile.source, categoryId: targetCategoryId);
    }
    var successCount = 0;
    for (final vibe in selectedVibes) {
      final saved = await _saveVibeReference(reference: vibe, categoryId: targetCategoryId);
      if (saved) successCount++;
    }
    return successCount > 0;
  }

  // 👈 核心合并：原作者新增的辅助方法，用于处理 Bundle 中独立配置的 Vibe 参数
  List<VibeReference>? _getSelectedVibesForBundle(
    bundle_import_dialog.BundleImportResult result,
    List<VibeReference> vibes,
  ) {
    final configuredVibes = result.configuredVibes != null &&
            result.configuredVibes!.length == vibes.length
        ? result.configuredVibes!
        : vibes;
    switch (result.option) {
      case bundle_import_dialog.BundleImportOption.keepAsBundle:
      case bundle_import_dialog.BundleImportOption.split:
        return configuredVibes;
      case bundle_import_dialog.BundleImportOption.importSelected:
        final indices = result.selectedIndices;
        if (indices == null || indices.isEmpty) return null;
        return indices
            .where((index) => index >= 0 && index < configuredVibes.length)
            .map((index) => configuredVibes[index])
            .toList();
    }
  }
  
  Future<bool> _saveAsBundle({required List<VibeReference> vibes, required String bundleName, String? categoryId}) async {
    try {
      final storage = ref.read(vibeLibraryStorageServiceProvider);
      final baseName = bundleName.trim().isEmpty ? 'vibe-bundle_${DateTime.now().millisecondsSinceEpoch}' : bundleName.trim();
      final uniqueName = _generateUniqueName(baseName);
      final saved = await storage.saveBundleEntry(vibes, name: uniqueName, categoryId: categoryId);
      return saved.filePath != null;
    } catch (e) { return false; }
  }

  Future<bool?> _handleImageEncoding({required VibeImageImportItem imageFile, String? targetCategoryId}) async {
    if (!mounted) return null;
    final config = await encode_dialog.VibeImageEncodeDialog.show(context: context, imageBytes: imageFile.bytes, fileName: imageFile.source);
    if (config == null) return null;
    while (mounted) {
      final dialogCompleter = Completer<void>(); BuildContext? dialogContext;
      unawaited(showDialog(context: context, barrierDismissible: false, useRootNavigator: true, builder: (ctx) { dialogContext = ctx; dialogCompleter.complete(); return const encode_dialog.VibeImageEncodingDialog(); }));
      await dialogCompleter.future;
      String? encoding; String? errorMessage;
      try {
        final notifier = ref.read(generationParamsNotifierProvider.notifier);
        final params = ref.read(generationParamsNotifierProvider);
        encoding = await notifier.encodeVibeWithCache(imageFile.bytes, model: params.model, informationExtracted: config.infoExtracted, vibeName: config.name).timeout(const Duration(seconds: 30));
      } catch (e) { errorMessage = e.toString(); } finally { if (dialogContext != null && dialogContext!.mounted) Navigator.of(dialogContext!).pop(); }
      if (encoding != null && mounted) {
        return await _saveEncodedVibe(name: config.name, encoding: encoding, imageBytes: imageFile.bytes, strength: config.strength, infoExtracted: config.infoExtracted, categoryId: targetCategoryId);
      }
      if (!mounted) return null;
      final action = await encode_dialog.VibeImageEncodeErrorDialog.show(context: context, fileName: imageFile.source, errorMessage: errorMessage ?? '未知错误');
      if (action == encode_dialog.VibeEncodeErrorAction.skip) return false; else if (action == null) return null;
    }
    return null;
  }

  Future<bool> _saveEncodedVibe({required String name, required String encoding, required Uint8List imageBytes, required double strength, required double infoExtracted, String? categoryId}) async {
    try {
      final storage = ref.read(vibeLibraryStorageServiceProvider);
      final reference = VibeReference(displayName: name, vibeEncoding: encoding, strength: strength, infoExtracted: infoExtracted, sourceType: VibeSourceType.naiv4vibe, thumbnail: imageBytes, rawImageData: imageBytes);
      final entry = VibeLibraryEntry.fromVibeReference(name: name, vibeData: reference, categoryId: categoryId);
      await storage.saveEntry(entry);
      return true;
    } catch (e) { return false; }
  }

  Future<void> _importVibesFromClipboard() async {
    final clipboardData = await Clipboard.getData(Clipboard.kTextPlain);
    final text = clipboardData?.text?.trim();
    if (text == null || text.isEmpty) { if (mounted) AppToast.error(context, '剪贴板为空'); return; }
    _beginImportSession();
    if (!mounted) { _endImportSession(); return; }
    setState(() => _isImporting = true);
    final currentCategoryId = ref.read(vibeLibraryNotifierProvider).selectedCategoryId;
    final targetCategoryId = (currentCategoryId != null && currentCategoryId != 'favorites') ? currentCategoryId : null;
    final storage = ref.read(vibeLibraryStorageServiceProvider);
    final repository = VibeLibraryStorageImportRepository(storage);
    final importService = VibeImportService(repository: repository);
    var totalSuccess = 0; var totalFail = 0;
    try {
      try {
        final result = await importService.importFromEncoding(items: [VibeEncodingImportItem(source: '剪贴板', encoding: text)], categoryId: targetCategoryId, onProgress: (current, total, message) { AppLogger.d(message, 'VibeLibrary'); });
        totalSuccess += result.successCount; totalFail += result.failCount;
      } catch (e) { totalFail++; }
      if (!mounted) return;
      setState(() => _isImporting = false);
      if (totalSuccess == 0 && totalFail == 0) return;
      if (totalSuccess > 0) await ref.read(vibeLibraryNotifierProvider.notifier).loadFromCache();
      if (mounted) {
        if (totalFail == 0) AppToast.success(context, '成功导入 $totalSuccess 个 Vibe');
        else AppToast.warning(context, '导入完成: $totalSuccess 成功, $totalFail 失败');
      }
    } finally {
      _endImportSession();
      if (mounted && _isImporting) setState(() => _isImporting = false);
    }
  }
}