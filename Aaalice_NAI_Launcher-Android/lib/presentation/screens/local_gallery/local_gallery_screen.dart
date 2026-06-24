import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:file_picker/file_picker.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nai_launcher/core/utils/localization_extension.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/constants/api_constants.dart';
import '../../../core/constants/storage_keys.dart';
import '../../../core/enums/precise_ref_type.dart';
import '../../../core/shortcuts/default_shortcuts.dart';
import '../../../core/utils/app_logger.dart';
import '../../../data/models/gallery/nai_image_metadata.dart';
import '../../../core/utils/nai_prompt_formatter.dart';
import '../../../core/utils/permission_utils.dart';
import '../../../core/utils/sd_to_nai_converter.dart';
import '../../../core/utils/zip_utils.dart';
import '../../../data/models/character/character_prompt.dart' as char;
import '../../../data/models/gallery/gallery_category.dart';
import '../../../data/models/gallery/local_image_record.dart';
import '../../../data/services/image_metadata_service.dart';
import '../../widgets/metadata/metadata_import_dialog.dart';
import '../../../data/repositories/gallery_folder_repository.dart';
import '../../providers/bulk_operation_provider.dart';
import '../../providers/character_prompt_provider.dart';
import '../../providers/collection_provider.dart';
import '../../providers/gallery_category_provider.dart';
import '../../providers/gallery_folder_provider.dart';
import '../../providers/image_generation_provider.dart';
import '../../providers/local_gallery_provider.dart';
import '../../providers/gallery_scan_progress_provider.dart';
import '../../providers/reverse_prompt_provider.dart';
import '../../router/app_router.dart';
import '../../services/image_workflow_launcher.dart';
import '../../utils/asset_protection_guard.dart';
import '../../../core/utils/file_explorer_utils.dart';
import '../../utils/krita_send_helper.dart';
import '../../utils/metadata_import_applier.dart';
import '../../utils/prompt_preset_import_utils.dart'; // 👈 原作者新增的导入
import '../../providers/selection_mode_provider.dart';
import '../../widgets/bulk_metadata_edit_dialog.dart';
import '../../widgets/collection_select_dialog.dart';
import '../../widgets/common/app_toast.dart';
import '../../widgets/common/pagination_bar.dart';
import '../../widgets/common/themed_confirm_dialog.dart';
import '../../widgets/common/themed_input_dialog.dart';
import '../../widgets/gallery/gallery_category_tree_view.dart';
import '../../widgets/gallery/gallery_content_view.dart';
import '../../widgets/gallery/gallery_state_views.dart';
import '../../widgets/gallery/image_send_destination_dialog.dart';
import '../../widgets/gallery/local_gallery_toolbar.dart';
import '../../widgets/gallery_filter_panel.dart';
import '../../widgets/grouped_grid_view.dart'
    show GroupedGridViewState, ImageDateGroup;
import '../../widgets/shortcuts/shortcut_aware_widget.dart';

/// 本地画廊屏幕
class LocalGalleryScreen extends ConsumerStatefulWidget {
  const LocalGalleryScreen({super.key});

  @override
  ConsumerState<LocalGalleryScreen> createState() => _LocalGalleryScreenState();
}

class _LocalGalleryScreenState extends ConsumerState<LocalGalleryScreen> {
  // 【手机端专属】：用于精确控制 Scaffold 的抽屉状态
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  
  final GlobalKey<GroupedGridViewState> _groupedGridViewKey =
      GlobalKey<GroupedGridViewState>();
  final FocusNode _shortcutsFocusNode = FocusNode();

  final bool _use3DCardView = true;
  bool _showCategoryPanel = true;
  AppLifecycleListener? _lifecycleListener;

  // 防抖计时器，防止频繁触发刷新
  Timer? _refreshDebounceTimer;

  // 上次刷新时间，用于限制刷新频率
  DateTime? _lastRefreshTime;

  // 最小刷新间隔（毫秒）
  static const int _minRefreshIntervalMs = 5000; // 5秒

  late final Map<String, VoidCallback> _shortcuts = {
    ShortcutIds.previousPage: _goToPreviousPage,
    ShortcutIds.nextPage: _goToNextPage,
    ShortcutIds.refreshGallery: _refreshGallery,
    ShortcutIds.focusSearch: _focusSearch,
    ShortcutIds.enterSelectionMode: _enterSelectionMode,
    ShortcutIds.openFilterPanel: () => showGalleryFilterPanel(context),
    ShortcutIds.clearFilter: _clearFilters,
    ShortcutIds.toggleCategoryPanel: _toggleCategoryPanel,
    ShortcutIds.jumpToDate: _jumpToDate,
    ShortcutIds.openFolder: _openGalleryFolder,
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _checkPermissionsAndScan();
      await _showFirstTimeTip();
      await _autoRefresh();
    });

    _lifecycleListener = AppLifecycleListener(
      onResume: () {
        Future.delayed(const Duration(milliseconds: 500), () {
          if (mounted) {
            _autoRefresh().catchError((e, stack) {
              AppLogger.e('Auto refresh on resume failed', e, stack,
                  'LocalGalleryScreen');
            });
          }
        });
      },
    );
  }

  /// 构建手机端专属的文件夹按钮 (🚀 移除高斯模糊，大幅提升滚动帧率)
  Widget _buildMobileFolderButton(BuildContext context, ThemeData theme) {
    return Container(
      decoration: BoxDecoration(
        // 💡 改为 90% 不透明度的纯色，去掉高斯模糊，GPU 零压力
        color: theme.colorScheme.surface.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: theme.colorScheme.outline.withValues(alpha: 0.3),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 8,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: IconButton(
        icon: const Icon(Icons.folder_open_rounded),
        color: theme.colorScheme.primary, // 💡 换成主题色，更醒目
        tooltip: '分类文件夹',
        onPressed: () => Scaffold.of(context).openDrawer(),
      ),
    );
  }

  @override
  void dispose() {
    _refreshDebounceTimer?.cancel();
    _lifecycleListener?.dispose();
    _shortcutsFocusNode.dispose();
    super.dispose();
  }

  void _goToPreviousPage() {
    final state = ref.read(localGalleryNotifierProvider);
    if (state.currentPage > 0) {
      ref
          .read(localGalleryNotifierProvider.notifier)
          .loadPage(state.currentPage - 1);
    }
  }

  void _goToNextPage() {
    final state = ref.read(localGalleryNotifierProvider);
    if (state.currentPage < state.totalPages - 1) {
      ref
          .read(localGalleryNotifierProvider.notifier)
          .loadPage(state.currentPage + 1);
    }
  }

  void _refreshGallery() {
    ref.read(localGalleryNotifierProvider.notifier).refresh();
  }

  void _focusSearch() {
    final focusNode = FocusManager.instance.primaryFocus;
    focusNode?.unfocus();
    Future.delayed(const Duration(milliseconds: 50), () {
      FocusManager.instance.primaryFocus?.requestFocus();
    });
  }

  void _enterSelectionMode() {
    ref.read(localGallerySelectionNotifierProvider.notifier).enter();
  }

  void _clearFilters() {
    ref.read(localGalleryNotifierProvider.notifier).clearAllFilters();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(localGalleryNotifierProvider);
    final bulkOpState = ref.watch(bulkOperationNotifierProvider);
    final categoryState = ref.watch(galleryCategoryNotifierProvider);
    final screenWidth = MediaQuery.of(context).size.width;
    final theme = Theme.of(context);
    final isMobile = screenWidth <= 800;

    final contentWidth =
        _showCategoryPanel && !isMobile ? screenWidth - 250 : screenWidth;
    final columns = (contentWidth / 200).floor().clamp(2, 8);
    final itemWidth = contentWidth / columns;

    final scaffoldBody = Scaffold(
      key: _scaffoldKey,
      drawer: isMobile ? Drawer(
        child: SafeArea(
          child: _buildCategoryPanel(theme, state, categoryState),
        ),
      ) : null,
      body: Row(
        children: [
          if (_showCategoryPanel && !isMobile)
            _buildCategoryPanel(theme, state, categoryState),
          Expanded(
            child: Column(
              children: [
                _buildToolbarOrSelectionBar(state, bulkOpState),
                Expanded(child: _buildBody(state, columns, itemWidth)),
                if (!state.isIndexing &&
                    state.filteredFiles.isNotEmpty &&
                    state.totalPages > 0)
                  Stack(
                    alignment: Alignment.centerLeft,
                    children: [
                      // 1. 恢复这根贯穿全屏的长线（补齐左侧文件夹上方的空缺）
                      Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        child: Container(
                          height: 1,
                          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.2),
                        ),
                      ),
                      
                      // 2. 完美的滑动分页栏：既撑满宽度（不断线），又可以横向滑动（不越界）
                      Padding(
                        padding: const EdgeInsets.only(left: 65.0),
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            return SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: ConstrainedBox(
                                // 🌟 核心魔法：强制最小宽度为屏幕剩余宽度，不让自带的短线缩水！
                                constraints: BoxConstraints(
                                  minWidth: constraints.maxWidth,
                                ),
                                child: PaginationBar(
                                  currentPage: state.currentPage,
                                  totalPages: state.totalPages,
                                  totalItems: state.filteredCount,
                                  itemsPerPage: state.pageSize,
                                  onPageChanged: (p) => ref
                                      .read(localGalleryNotifierProvider.notifier)
                                      .loadPage(p),
                                  onItemsPerPageChanged: (size) => ref
                                      .read(localGalleryNotifierProvider.notifier)
                                      .setPageSize(size),
                                  showItemsPerPage: !isMobile, 
                                  showTotalInfo: true,
                                  compact: contentWidth < 600,
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                      
                      // 3. 原汁原味的左侧文件夹按钮
                      if (isMobile)
                        Padding(
                          padding: const EdgeInsets.only(left: 12.0),
                          child: Builder(
                            builder: (context) => _buildMobileFolderButton(context, theme),
                          ),
                        ),
                    ],
                  )
                else if (isMobile)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.all(12.0),
                      child: Builder(
                        builder: (context) => _buildMobileFolderButton(context, theme),
                      ),
                    ),
                  ),             
              ],
            ),
          ),
        ],
      ),
    );

    if (isMobile) {
      return PageShortcuts(
        contextType: ShortcutContext.gallery,
        shortcuts: _shortcuts,
        child: scaffoldBody,
      );
    }

    return PageShortcuts(
      contextType: ShortcutContext.gallery,
      shortcuts: _shortcuts,
      child: KeyboardListener(
        focusNode: _shortcutsFocusNode,
        autofocus: true,
        onKeyEvent: (event) => _handleKeyEvent(event, bulkOpState),
        child: scaffoldBody,
      ),
    );
  }
  
  Widget _buildCategoryPanel(
    ThemeData theme,
    LocalGalleryState state,
    GalleryCategoryState categoryState,
  ) {
    return Container(
      width: 250,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: Border(
          right: BorderSide(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
            width: 1,
          ),
        ),
      ),
      child: Column(
        children: [
          _buildCategoryPanelHeader(theme),
          Divider(
            height: 1,
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
          ),
          Expanded(
            child: FutureBuilder<int>(
              future: ref
                  .read(localGalleryNotifierProvider.notifier)
                  .getTotalFavoriteCount(),
              builder: (context, snapshot) {
                return GalleryCategoryTreeView(
                  categories: categoryState.categories,
                  totalImageCount: state.allFiles.length,
                  favoriteCount: snapshot.data ?? 0,
                  selectedCategoryId: categoryState.selectedCategoryId,
                  onCategorySelected: _handleCategorySelected,
                  onCategoryRename: (id, newName) => ref
                      .read(galleryCategoryNotifierProvider.notifier)
                      .renameCategory(id, newName),
                  onCategoryDelete: _handleCategoryDelete,
                  onAddSubCategory: _handleAddSubCategory,
                  onCategoryMove: (categoryId, newParentId) => ref
                      .read(galleryCategoryNotifierProvider.notifier)
                      .moveCategory(categoryId, newParentId),
                  onCategoryReorder: (parentId, oldIndex, newIndex) => ref
                      .read(galleryCategoryNotifierProvider.notifier)
                      .reorderCategories(parentId, oldIndex, newIndex),
                  onImageDrop: (imagePath, categoryId) =>
                      _handleImageDrop(imagePath, categoryId!),
                  onSyncWithFileSystem: _handleSyncWithFileSystem,
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCategoryPanelHeader(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      constraints: const BoxConstraints(minHeight: 62),
      child: Row(
        children: [
          Icon(
            Icons.folder_outlined,
            size: 20,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '分类',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          FilledButton.tonalIcon(
            onPressed: _createCategory,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('新建', style: TextStyle(fontSize: 13)),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _createCategory() async {
    final name = await ThemedInputDialog.show(
      context: context,
      title: '新建分类',
      hintText: '请输入分类名称',
      confirmText: '创建',
      cancelText: '取消',
    );
    if (name != null && name.isNotEmpty) {
      await ref
          .read(galleryCategoryNotifierProvider.notifier)
          .createCategory(name, parentId: null);
    }
  }

  void _handleCategorySelected(String? id) {
    ref.read(galleryCategoryNotifierProvider.notifier).selectCategory(id);

    final categoryState = ref.read(galleryCategoryNotifierProvider);
    final category = id != null ? categoryState.categories.findById(id) : null;

    if (id == 'favorites') {
      ref.read(localGalleryNotifierProvider.notifier).setShowFavoritesOnly(true);
    } else if (id != null && category != null) {
      ref.read(localGalleryNotifierProvider.notifier).setShowFavoritesOnly(false);
      ref.read(localGalleryNotifierProvider.notifier).setSelectedCategory(
            id,
            category.folderPath,
          );
    } else {
      ref.read(localGalleryNotifierProvider.notifier).setShowFavoritesOnly(false);
      ref.read(localGalleryNotifierProvider.notifier).setSelectedCategory(null, null);
    }

    if (_scaffoldKey.currentState?.isDrawerOpen == true) {
      _scaffoldKey.currentState?.closeDrawer();
    }
  }

  Future<void> _handleCategoryDelete(String id) async {
    final confirmed = await ThemedConfirmDialog.show(
      context: context,
      title: '确认删除',
      content: '确定要删除此分类吗？\n警告：对应的物理文件夹及其内部的残留文件(包含子分类)将被一并强制删除！',
      confirmText: '删除',
      cancelText: '取消',
      type: ThemedConfirmDialogType.danger,
      icon: Icons.delete_outline,
    );
    if (confirmed) {
      final protected = await AssetProtectionGuard.confirmDangerousAction(
        context: context,
        ref: ref,
        title: '保护模式：确认删除分类',
        content: '将永久删除此分类及本地硬盘上的真实文件夹。请再次确认。',
        confirmText: '强制删除',
        icon: Icons.delete_outline,
      );
      if (!protected || !mounted) return;
      
      final success = await ref
          .read(galleryCategoryNotifierProvider.notifier)
          // 👇 修复：增加 recursive: true，强制连同内部残留的隐藏文件一起删掉
          .deleteCategory(id, deleteFolder: true, recursive: true);
          
      if (mounted) {
        if (success) {
          AppToast.success(context, '分类及文件夹已彻底删除');
        } else {
          AppToast.error(context, '删除失败，请检查文件夹是否被其他程序占用');
        }
      }
    }
  }
    
  Future<void> _handleAddSubCategory(String? parentId) async {
    final name = await ThemedInputDialog.show(
      context: context,
      title: parentId == null ? '新建分类' : '新建子分类',
      hintText: '请输入分类名称',
      confirmText: '创建',
      cancelText: '取消',
    );
    if (name != null && name.isNotEmpty) {
      await ref
          .read(galleryCategoryNotifierProvider.notifier)
          .createCategory(name, parentId: parentId);
    }
  }

  Future<void> _handleImageDrop(String imagePath, String categoryId) async {
    final protected = await AssetProtectionGuard.confirmDangerousAction(
      context: context,
      ref: ref,
      title: '保护模式：确认移动图片',
      content: '将把图片移动到目标分类文件夹。请确认不是误拖拽。',
      confirmText: '确认移动',
      icon: Icons.drive_file_move_outline,
    );
    if (!protected || !mounted) return;

    final newPath = await ref
        .read(galleryCategoryNotifierProvider.notifier)
        .moveImageToCategory(imagePath, categoryId);
    if (newPath != null) {
      ref.read(localGalleryNotifierProvider.notifier).refresh();
      if (mounted) AppToast.success(context, '图片已移动到分类');
    }
  }

  Future<void> _handleSyncWithFileSystem() async {
    await ref
        .read(galleryCategoryNotifierProvider.notifier)
        .syncWithFileSystem();
    if (mounted) AppToast.success(context, '分类已与文件夹同步');
  }

  Future<void> _autoRefresh() async {
    _refreshDebounceTimer?.cancel();

    _refreshDebounceTimer = Timer(const Duration(milliseconds: 500), () async {
      if (!mounted) return;

      final router = GoRouter.of(context);
      final currentPath = router.routeInformationProvider.value.uri.path;
      if (currentPath != '/local-gallery') {
        AppLogger.d(
            '[AutoRefresh] Skipped: not on local gallery page (current: $currentPath)',
            'LocalGalleryScreen');
        return;
      }

      final now = DateTime.now();
      if (_lastRefreshTime != null) {
        final elapsed = now.difference(_lastRefreshTime!).inMilliseconds;
        if (elapsed < _minRefreshIntervalMs) {
          return;
        }
      }

      final scanState = ref.read(galleryScanProgressProvider);
      if (scanState.isScanning) return;

      AppLogger.i('[AutoRefresh] Executing auto refresh', 'LocalGalleryScreen');
      _lastRefreshTime = now;

      await ref.read(localGalleryNotifierProvider.notifier).refresh();
      await ref
          .read(galleryCategoryNotifierProvider.notifier)
          .syncWithFileSystem();
    });
  }

  Widget _buildToolbarOrSelectionBar(
    LocalGalleryState state,
    BulkOperationState bulkOpState,
  ) {
    return LocalGalleryToolbar(
      onRefresh: () =>
          ref.read(localGalleryNotifierProvider.notifier).refresh(),
      onEnterSelectionMode: () =>
          ref.read(localGallerySelectionNotifierProvider.notifier).enter(),
      canUndo: bulkOpState.canUndo,
      canRedo: bulkOpState.canRedo,
      onUndo: bulkOpState.canUndo
          ? () => ref.read(bulkOperationNotifierProvider.notifier).undo()
          : null,
      onRedo: bulkOpState.canRedo
          ? () => ref.read(bulkOperationNotifierProvider.notifier).redo()
          : null,
      groupedGridViewKey: _groupedGridViewKey,
      onAddToCollection: _addSelectedToCollection,
      onDeleteSelected: _deleteSelectedImages,
      onPackSelected: _packSelectedImages,
      onEditMetadata: _editSelectedMetadata,
      onMoveToFolder: _moveSelectedToFolder,
      showCategoryPanel: _showCategoryPanel,
      onOpenFolder: () => _openGalleryFolder(),
    );
  }

  Widget _buildBody(LocalGalleryState state, int columns, double itemWidth) {
    if (state.error != null) {
      return GalleryErrorView(
        error: state.error,
        onRetry: () =>
            ref.read(localGalleryNotifierProvider.notifier).refresh(),
      );
    }

    if (state.isLoading && state.allFiles.isEmpty) {
      return const GalleryLoadingView();
    }

    if (state.allFiles.isEmpty) {
      return const GalleryEmptyView();
    }

    return GalleryContentView(
      use3DCardView: _use3DCardView,
      columns: columns,
      itemWidth: itemWidth,
      groupedGridViewKey: _groupedGridViewKey,
      onReuseMetadata: _reuseMetadata,
      onSendToImg2Img: _sendToImg2Img,
      onSendToVibeTransfer: _sendToVibeTransfer,         // 👈 新增这行
      onSendToPreciseReference: _sendToPreciseReference, // 👈 新增这行
      onContextMenu: (record, position) =>
          _showImageContextMenu(record, position),
    ); 
  }

  void _handleKeyEvent(KeyEvent event, BulkOperationState bulkOpState) {
    if (event is! KeyDownEvent) return;

    final isCtrlPressed = HardwareKeyboard.instance.isControlPressed;
    if (!isCtrlPressed) return;

    if (event.logicalKey == LogicalKeyboardKey.keyZ) {
      if (HardwareKeyboard.instance.isShiftPressed) {
        if (bulkOpState.canRedo) _redo();
      } else {
        if (bulkOpState.canUndo) _undo();
      }
    } else if (event.logicalKey == LogicalKeyboardKey.keyY &&
        bulkOpState.canRedo) {
      _redo();
    }
  }

  Future<void> _checkPermissionsAndScan() async {
    final hasPermission = await PermissionUtils.checkGalleryPermission();

    if (!hasPermission) {
      final granted = await PermissionUtils.requestGalleryPermission();
      if (!granted && mounted) {
        _showPermissionDeniedDialog();
        return;
      }
    }

    if (mounted) {
      await ref.read(localGalleryNotifierProvider.notifier).initialize();
      await ref.read(collectionNotifierProvider.notifier).initialize();
      _showFirstTimeIndexTipIfNeeded();
    }
  }

  void _showFirstTimeIndexTipIfNeeded() {
    final state = ref.read(localGalleryNotifierProvider);
    if (state.firstTimeIndexMessage != null && mounted) {
      Future.delayed(const Duration(milliseconds: 500), () {
        if (mounted) AppToast.info(context, state.firstTimeIndexMessage!);
      });
    }
  }

  void _showPermissionDeniedDialog() async {
    final confirmed = await ThemedConfirmDialog.show(
      context: context,
      title: context.l10n.localGallery_permissionRequiredTitle,
      content: context.l10n.localGallery_permissionRequiredContent,
      confirmText: context.l10n.localGallery_openSettings,
      cancelText: context.l10n.common_cancel,
      type: ThemedConfirmDialogType.warning,
      icon: Icons.folder_off_outlined,
    );

    if (confirmed) PermissionUtils.openAppSettings();
  }

  Future<void> _showFirstTimeTip() async {
    final prefs = await SharedPreferences.getInstance();
    final hasSeenTip =
        prefs.getBool(StorageKeys.hasSeenLocalGalleryTip) ?? false;

    if (hasSeenTip || !mounted) return;

    await prefs.setBool(StorageKeys.hasSeenLocalGalleryTip, true);
    await Future.delayed(const Duration(milliseconds: 500));

    if (!mounted) return;

    await ThemedConfirmDialog.showInfo(
      context: context,
      title: context.l10n.localGallery_firstTimeTipTitle,
      content: context.l10n.localGallery_firstTimeTipContent,
      confirmText: context.l10n.localGallery_gotIt,
      icon: Icons.lightbulb_outline,
    );
  }

  Future<void> _openGalleryFolder() async {
    try {
      final rootPath = await GalleryFolderRepository.instance.getRootPath();
      if (rootPath == null || rootPath.isEmpty) {
        if (mounted) AppToast.info(context, '未设置保存目录');
        return;
      }

      final dir = Directory(rootPath);
      if (!await dir.exists()) {
        if (mounted) AppToast.info(context, '文件夹不存在');
        return;
      }

      if (Platform.isWindows) {
        await Process.start('explorer', [rootPath]);
      } else if (Platform.isMacOS) {
        await Process.start('open', [rootPath]);
      } else if (Platform.isLinux) {
        await Process.start('xdg-open', [rootPath]);
      }
    } catch (e) {
      if (mounted) AppToast.error(context, '打开文件夹失败: $e');
    }
  }

  Future<void> _undo() async {
    await ref.read(bulkOperationNotifierProvider.notifier).undo();
    await ref.read(localGalleryNotifierProvider.notifier).refresh();
    if (mounted) AppToast.info(context, context.l10n.localGallery_undone);
  }

  Future<void> _redo() async {
    await ref.read(bulkOperationNotifierProvider.notifier).redo();
    await ref.read(localGalleryNotifierProvider.notifier).refresh();
    if (mounted) AppToast.info(context, context.l10n.localGallery_redone);
  }

  Future<void> _deleteSelectedImages() async {
    final selectionState = ref.read(localGallerySelectionNotifierProvider);
    final l10n = context.l10n;

    final service =
        await ref.read(localGalleryNotifierProvider.notifier).getService();
    final selectedImages = await service.getRecordsByPaths(
      selectionState.selectedIds.toList(),
    );

    if (selectedImages.isEmpty) return;

    final confirmed = await ThemedConfirmDialog.show(
      context: context,
      title: l10n.localGallery_confirmBulkDelete,
      content:
          l10n.localGallery_confirmBulkDeleteContent(selectedImages.length),
      confirmText: l10n.common_delete,
      cancelText: l10n.common_cancel,
      type: ThemedConfirmDialogType.danger,
      icon: Icons.delete_forever_outlined,
    );

    if (!confirmed || !mounted) return;

    final protected = await AssetProtectionGuard.confirmDangerousAction(
      context: context,
      ref: ref,
      title: '保护模式：再次确认删除',
      content: '将永久删除 ${selectedImages.length} 张本地图片文件。此操作无法撤销。',
      confirmText: l10n.common_delete,
      icon: Icons.delete_forever_outlined,
    );
    if (!protected || !mounted) return;

    final deletedImages = <LocalImageRecord>[];
    for (final image in selectedImages) {
      try {
        final file = File(image.path);
        if (await file.exists()) {
          await file.delete();
          deletedImages.add(image);
        }
      } catch (e) {
        // Skip failed deletions
      }
    }

    ref.read(localGallerySelectionNotifierProvider.notifier).exit();
    await ref.read(localGalleryNotifierProvider.notifier).refresh();

    if (mounted && deletedImages.isNotEmpty) {
      AppToast.success(
        context,
        context.l10n.localGallery_deletedImages(deletedImages.length),
      );
    }
  }

  Future<void> _packSelectedImages() async {
    final selectionState = ref.read(localGallerySelectionNotifierProvider);

    final service = await ref.read(localGalleryNotifierProvider.notifier).getService();
    final selectedImages = await service.getRecordsByPaths(
      selectionState.selectedIds.toList(),
    );

    if (selectedImages.isEmpty || !mounted) return;

    final defaultName = 'images_${DateTime.now().millisecondsSinceEpoch}';
    
    // 【手机端特供】：如果是单张图片导出，直接读取 Bytes 传给移动端
    if (selectedImages.length == 1) {
      try {
        final imageFile = File(selectedImages.first.path);
        final imageBytes = await imageFile.readAsBytes();
        final ext = path.extension(imageFile.path).replaceAll('.', '');
        
        final savePath = await FilePicker.platform.saveFile(
          dialogTitle: '导出图片',
          fileName: 'image_${DateTime.now().millisecondsSinceEpoch}.$ext',
          type: FileType.image,
          bytes: imageBytes,
        );

        if (savePath != null && savePath.isNotEmpty && (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
          final requestedPath = savePath;
          final finalPath = AssetProtectionGuard.shouldPreventOverwrite(ref)
              ? await AssetProtectionGuard.resolveNonOverwritingPath(requestedPath)
              : requestedPath;
          await File(finalPath).writeAsBytes(imageBytes);
        }
        
        if (mounted && savePath != null) {
          AppToast.success(context, '图片导出成功');
          ref.read(localGallerySelectionNotifierProvider.notifier).exit();
        }
      } catch (e) {
        if (mounted) AppToast.error(context, '导出失败: $e');
      }
      return;
    }

    AppToast.info(context, '正在打包 ${selectedImages.length} 张图片...');
    
    try {
      final tempDir = await getTemporaryDirectory();
      final tempZipPath = path.join(tempDir.path, '$defaultName.zip');
      
      final imagePaths = selectedImages.map((img) => img.path).toList();
      final success = await ZipUtils.createZipFromImages(imagePaths, tempZipPath);

      if (!success) {
        if (mounted) AppToast.error(context, '打包失败');
        return;
      }

      final zipFile = File(tempZipPath);
      final zipBytes = await zipFile.readAsBytes();

      final savePath = await FilePicker.platform.saveFile(
        dialogTitle: '保存压缩包',
        fileName: '$defaultName.zip',
        type: FileType.custom,
        allowedExtensions: ['zip'],
        bytes: zipBytes, 
      );

      if (savePath != null && savePath.isNotEmpty && (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
        final requestedPath = savePath.endsWith('.zip') ? savePath : '$savePath.zip';
        final finalPath = AssetProtectionGuard.shouldPreventOverwrite(ref)
            ? await AssetProtectionGuard.resolveNonOverwritingPath(requestedPath)
            : requestedPath;
        await File(finalPath).writeAsBytes(zipBytes);
      }

      if (await zipFile.exists()) {
        await zipFile.delete();
      }

      if (mounted && savePath != null) {
        AppToast.success(context, '已打包导出 ${selectedImages.length} 张图片');
        ref.read(localGallerySelectionNotifierProvider.notifier).exit();
      }
    } catch (e) {
      if (mounted) AppToast.error(context, '导出失败: $e');
    }
  }

  Future<void> _editSelectedMetadata() async {
    final selectionState = ref.read(localGallerySelectionNotifierProvider);
    if (selectionState.selectedIds.isEmpty || !mounted) return;
    showBulkMetadataEditDialog(context);
  }

  Future<void> _moveSelectedToFolder() async {
    final selectionState = ref.read(localGallerySelectionNotifierProvider);
    final categoryState = ref.read(galleryCategoryNotifierProvider);
    final l10n = context.l10n;

    final service =
        await ref.read(localGalleryNotifierProvider.notifier).getService();
    final selectedImages = await service.getRecordsByPaths(
      selectionState.selectedIds.toList(),
    );

    if (selectedImages.isEmpty) return;

    final categories = categoryState.categories;

    // 弹窗让用户选择要移动到哪个分类
    final selectedCategoryId = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('移动图片'),
        content: SizedBox(
          width: 300,
          child: ListView.builder(
            shrinkWrap: true,
            // 👇 修复 1：长度加 1，给根目录留位置
            itemCount: categories.length + 1, 
            itemBuilder: (context, index) {
              // 👇 修复 2：在列表最顶部固定显示一个“移出分类”的选项
              if (index == 0) {
                return ListTile(
                  leading: const Icon(Icons.photo_library_outlined),
                  title: const Text('全部图片 (移出分类)'),
                  onTap: () => Navigator.of(context).pop('root_directory'),
                );
              }
              final category = categories[index - 1];
              return ListTile(
                leading: const Icon(Icons.folder),
                title: Text(category.displayName),
                subtitle: Text('包含 ${category.imageCount} 张图片'),
                onTap: () => Navigator.of(context).pop(category.id),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(context.l10n.common_cancel),
          ),
        ],
      ),
    );

    if (selectedCategoryId == null || !mounted) return;

    // 👇 修复 3：判断是否是移回根目录（null 代表根目录）
    final isMovingToRoot = selectedCategoryId == 'root_directory';
    final targetCategoryId = isMovingToRoot ? null : selectedCategoryId;

    final protected = await AssetProtectionGuard.confirmDangerousAction(
      context: context,
      ref: ref,
      title: '保护模式：确认批量移动',
      content: isMovingToRoot 
          ? '将把 ${selectedImages.length} 张图片移出分类，放回根目录。请确认不是误操作。'
          : '将移动 ${selectedImages.length} 张本地图片文件到目标分类。请确认不是误操作。',
      confirmText: '确认移动',
      icon: Icons.drive_file_move_outline,
    );
    if (!protected || !mounted) return;

    final imagePaths = selectedImages.map((img) => img.path).toList();
    int movedCount = 0;

    for (final path in imagePaths) {
      final newPath = await ref
          .read(galleryCategoryNotifierProvider.notifier)
          .moveImageToCategory(path, targetCategoryId); // 传入 null 即可移回根目录
      if (newPath != null) movedCount++;
    }

    if (mounted) {
      if (movedCount > 0) {
        AppToast.info(
            context, context.l10n.localGallery_movedImages(movedCount));
        ref.read(localGallerySelectionNotifierProvider.notifier).exit();
        ref.read(localGalleryNotifierProvider.notifier).refresh();
      } else {
        AppToast.info(context, context.l10n.localGallery_moveImagesFailed);
      }
    }
  }

  Future<void> _addSelectedToCollection() async {
    final selectionState = ref.read(localGallerySelectionNotifierProvider);

    final service =
        await ref.read(localGalleryNotifierProvider.notifier).getService();
    final selectedImages = await service.getRecordsByPaths(
      selectionState.selectedIds.toList(),
    );

    if (selectedImages.isEmpty || !mounted) return;

    final result = await CollectionSelectDialog.show(
      context,
      theme: Theme.of(context),
    );

    if (result == null) return;

    final imagePaths = selectedImages.map((img) => img.path).toList();
    final addedCount = await ref
        .read(collectionNotifierProvider.notifier)
        .addImagesToCollection(result.collectionId, imagePaths);

    if (mounted) {
      if (addedCount > 0) {
        AppToast.success(
          context,
          context.l10n.localGallery_addedToCollection(
            addedCount,
            result.collectionName,
          ),
        );
        ref.read(localGallerySelectionNotifierProvider.notifier).exit();
      } else {
        AppToast.info(context, context.l10n.localGallery_addToCollectionFailed);
      }
    }
  }

  Future<void> _reuseMetadata(LocalImageRecord record) async {
    try {
      // 【核心修复】：明确声明类型，使用单例深度读取，找回丢失的 Seed (保留手机端特有逻辑)
      NaiImageMetadata? metadata = await ImageMetadataService().getMetadataImmediate(record.path);
      metadata ??= record.metadata;

      if (metadata == null || !metadata.hasData) {
        AppToast.warning(context, context.l10n.localGallery_noMetadata);
        return;
      }

      final options =
          await MetadataImportDialog.show(context, metadata: metadata);
      if (options == null || !mounted) return;

      final paramsNotifier =
          ref.read(generationParamsNotifierProvider.notifier);

      // 安全获取角色提示词列表（防止 null）
      final characterPrompts = metadata.characterPrompts;
      final hasCharacters = characterPrompts.isNotEmpty;

      if (options.importCharacterPrompts && hasCharacters) {
        ref.read(characterPromptNotifierProvider.notifier).clearAllCharacters();
      }

      var appliedCount = 0;

      final currentModel = ref.read(generationParamsNotifierProvider).model;
      // 👇 原作者重构：使用统一的 MetadataImportApplier
      appliedCount += MetadataImportApplier.applyPromptAndGenerationParams(
        metadata: metadata,
        options: options,
        currentModel: currentModel,
        target: MetadataImportTarget(
          updatePrompt: (value) =>
              paramsNotifier.updatePrompt(_formatPrompt(value)),
          updateNegativePrompt: (value) =>
              paramsNotifier.updateNegativePrompt(_formatPrompt(value)),
          updateSeed: paramsNotifier.updateSeed,
          updateSteps: paramsNotifier.updateSteps,
          updateScale: paramsNotifier.updateScale,
          updateSize: paramsNotifier.updateSize,
          updateSampler: paramsNotifier.updateSampler,
          updateModel: paramsNotifier.updateModel,
          updateSmea: paramsNotifier.updateSmea,
          updateSmeaDyn: paramsNotifier.updateSmeaDyn,
          updateVarietyPlus: paramsNotifier.updateVarietyPlus,
          updateNoiseSchedule: paramsNotifier.updateNoiseSchedule,
          updateCfgRescale: paramsNotifier.updateCfgRescale,
          updateQualityToggle: (value) {
            paramsNotifier.updateQualityToggle(value);
            applyImportedQualityToggle(ref.read, value);
          },
          updateUcPreset: (value) {
            paramsNotifier.updateUcPreset(value);
            applyImportedUcPreset(ref.read, value);
          },
        ),
      );

      if (options.importCharacterPrompts && hasCharacters) {
        _applyCharacterPrompts(metadata);
        appliedCount++;
      }

      if (!mounted) return;

      if (appliedCount > 0) {
        AppToast.info(
          context,
          context.l10n.metadataImport_appliedToMain(appliedCount),
        );
      } else {
        AppToast.warning(context, context.l10n.metadataImport_noParamsSelected);
      }
    } catch (e, stack) {
      AppLogger.e('导入参数失败', e, stack, 'LocalGallery');
      if (mounted) {
        AppToast.error(
          context,
          context.l10n.localGallery_importParamsFailed('$e'),
        );
      }
    }
  }

  String _formatPrompt(String prompt) {
    return NaiPromptFormatter.format(SdToNaiConverter.convert(prompt));
  }

  String _resolveImportedNegativePrompt(
    NaiImageMetadata metadata, {
    required bool importUcPreset,
  }) {
    // 👇 原作者优化：使用 displayNegativePrompt 替代 negativePrompt
    final baseNegative = metadata.displayNegativePrompt;
    if (!importUcPreset || metadata.ucPreset == null) {
      return baseNegative;
    }

    final model =
        metadata.model ?? ref.read(generationParamsNotifierProvider).model;
    return UcPresets.stripPresetByInt(
      baseNegative,
      model,
      metadata.ucPreset!,
    );
  }

  // 👇 原作者优化：将 void 改为返回 int，用于精确统计导入了多少个参数
  int _applyParam<T>(bool shouldApply, T? value, void Function(T) updater) {
    if (shouldApply && value != null) {
      updater(value);
      return 1;
    }
    return 0;
  }
  
  void _applyCharacterPrompts(NaiImageMetadata metadata) {
    final characterNotifier =
        ref.read(characterPromptNotifierProvider.notifier);
    final characters = <char.CharacterPrompt>[];

    final characterPrompts = metadata.characterPrompts;
    final characterNegativePrompts = metadata.characterNegativePrompts;

    for (var i = 0; i < characterPrompts.length; i++) {
      final prompt = _formatPrompt(characterPrompts[i]);
      var negPrompt = i < characterNegativePrompts.length
          ? characterNegativePrompts[i]
          : '';
      if (negPrompt.isNotEmpty) negPrompt = _formatPrompt(negPrompt);

      characters.add(
        char.CharacterPrompt.create(
          name: 'Character ${i + 1}',
          gender: _inferGenderFromPrompt(prompt),
          prompt: prompt,
          negativePrompt: negPrompt,
        ),
      );
    }
    characterNotifier.replaceAll(characters);
  }

  char.CharacterGender _inferGenderFromPrompt(String prompt) {
    final lowerPrompt = prompt.toLowerCase();
    if (lowerPrompt.contains('1girl') ||
        lowerPrompt.contains('girl,') ||
        lowerPrompt.startsWith('girl')) {
      return char.CharacterGender.female;
    } else if (lowerPrompt.contains('1boy') ||
        lowerPrompt.contains('boy,') ||
        lowerPrompt.startsWith('boy')) {
      return char.CharacterGender.male;
    }
    return char.CharacterGender.other;
  }

  Future<void> _sendToImg2Img(LocalImageRecord record) async {
    try {
      final file = File(record.path);
      if (!await file.exists()) {
        if (mounted) AppToast.info(context, '图片文件不存在');
        return;
      }

      final imageBytes = await file.readAsBytes();
      ImageWorkflowLauncher.openImageToImage(ref, imageBytes);

      if (mounted) {
        context.go(AppRoutes.home);
        AppToast.success(context, '图片已发送到图生图');
      }
    } catch (e) {
      if (mounted) AppToast.error(context, '发送失败: $e');
    }
  }

  Future<void> _sendToVibeTransfer(LocalImageRecord record) async {
    try {
      final vibeData = record.vibeData;
      if (vibeData == null) {
        if (mounted) AppToast.warning(context, '此图片不包含 Vibe 数据');
        return;
      }

      final paramsNotifier =
          ref.read(generationParamsNotifierProvider.notifier);
      paramsNotifier.addVibeReferences([vibeData]);

      if (mounted) {
        AppToast.success(context, 'Vibe "${vibeData.displayName}" 已添加到生成参数');
      }
    } catch (e) {
      if (mounted) AppToast.error(context, '添加 Vibe 失败: $e');
    }
  }

  Future<void> _sendToPreciseReference(LocalImageRecord record) async {
    try {
      final file = File(record.path);
      if (!await file.exists()) {
        if (mounted) AppToast.info(context, '图片文件不存在');
        return;
      }

      final imageBytes = await file.readAsBytes();

      await ref
          .read(generationParamsNotifierProvider.notifier)
          .addPreciseReferenceFromImage(
            imageBytes,
            type: PreciseRefType.character, // 默认角色参考
            strength: 1.0,
            fidelity: 1.0,
          );

      if (mounted) {
        AppToast.success(context, '图片已添加到精准参考');
      }
    } catch (e) {
      if (mounted) AppToast.error(context, '添加失败: $e');
    }
  }

  Future<void> _sendToReversePrompt(LocalImageRecord record) async {
    try {
      final file = File(record.path);
      if (!await file.exists()) {
        if (mounted) AppToast.info(context, '图片文件不存在');
        return;
      }

      await ref
          .read(reversePromptProvider.notifier)
          .addImage(await file.readAsBytes(), name: path.basename(record.path));

      if (mounted) {
        context.go(AppRoutes.home);
        AppToast.success(context, '图片已发送到反推模块');
      }
    } catch (e) {
      if (mounted) AppToast.error(context, '发送失败: $e');
    }
  }

  Future<void> _sendToKrita(LocalImageRecord record) async {
    try {
      final file = File(record.path);
      if (!await file.exists()) {
        if (mounted) {
          AppToast.info(context, context.l10n.localGallery_imageFileMissing);
        }
        return;
      }

      final imageBytes = await file.readAsBytes();
      if (!mounted) return;
      KritaSendHelper.sendImageBytes(
        context,
        ref,
        imageBytes,
        name: path.basename(record.path),
      );
    } catch (e) {
      if (mounted) {
        AppToast.error(
          context,
          context.l10n.localGallery_sendToKritaFailed('$e'),
        );
      }
    }
  }

  Future<void> _showSendDestinationDialog(LocalImageRecord record) async {
    final destination = await ImageSendDestinationDialog.show(context, record);
    if (destination == null || !mounted) return;

    switch (destination) {
      case SendDestination.img2img:
        await _sendToImg2Img(record);
      case SendDestination.reversePrompt:
        await _sendToReversePrompt(record);
      case SendDestination.vibeTransfer:
        await _sendToVibeTransfer(record);
      case SendDestination.krita:
        await _sendToKrita(record);
    }
  }

  Future<void> _showImageContextMenu(
    LocalImageRecord record,
    Offset position,
  ) async {
    final metadata = record.metadata;

    final value = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx + 1,
        position.dy + 1,
      ),
      items: [
        const PopupMenuItem(
          value: 'send_to',
          child: Row(
            children: [
              Icon(Icons.send, size: 18),
              SizedBox(width: 8),
              Text('发送到...'),
            ],
          ),
        ),
        const PopupMenuDivider(),
        if (metadata?.prompt.isNotEmpty == true)
          const PopupMenuItem(
            value: 'copy_prompt',
            child: Row(
              children: [
                Icon(Icons.content_copy, size: 18),
                SizedBox(width: 8),
                Text('复制 Prompt'),
              ],
            ),
          ),
        if (metadata?.seed != null)
          const PopupMenuItem(
            value: 'copy_seed',
            child: Row(
              children: [
                Icon(Icons.tag, size: 18),
                SizedBox(width: 8),
                Text('复制 Seed'),
              ],
            ),
          ),
        const PopupMenuItem(
          value: 'open_folder',
          child: Row(
            children: [
              Icon(Icons.folder_open, size: 18),
              SizedBox(width: 8),
              Text('在文件夹中显示'),
            ],
          ),
        ),
        const PopupMenuItem(
          value: 'delete',
          child: Row(
            children: [
              Icon(Icons.delete_outline, size: 18, color: Colors.red),
              SizedBox(width: 8),
              Text('删除', style: TextStyle(color: Colors.red)),
            ],
          ),
        ),
      ],
    );

    if (value == null || !context.mounted) return;

    switch (value) {
      case 'send_to':
        await _showSendDestinationDialog(record);
      case 'copy_prompt':
        if (metadata?.fullPrompt.isNotEmpty == true) {
          await Clipboard.setData(ClipboardData(text: metadata!.fullPrompt));
          if (mounted) AppToast.success(context, 'Prompt 已复制');
        }
      case 'copy_seed':
        if (metadata?.seed != null) {
          await Clipboard.setData(
              ClipboardData(text: metadata!.seed.toString()));
          if (mounted) AppToast.success(context, 'Seed 已复制');
        }
      case 'open_folder':
        await _openFileInFolder(record.path);
      case 'delete':
        await _confirmDeleteImage(record);
    }
  }

  Future<void> _openFileInFolder(String filePath) async {
    try {
      await FileExplorerUtils.revealFile(filePath);
    } catch (e) {
      if (mounted) {
        AppToast.error(
          context,
          context.l10n.localGallery_cannotOpenFolder('$e'),
        );
      }
    }
  }
  
  Future<void> _confirmDeleteImage(LocalImageRecord record) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认删除'),
        content: Text(
          '确定要删除图片「${path.basename(record.path)}」吗？\n\n此操作无法撤销。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            child: const Text('删除'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      final protected = await AssetProtectionGuard.confirmDangerousAction(
        context: context,
        ref: ref,
        title: '保护模式：再次确认删除',
        content: '将永久删除图片「${path.basename(record.path)}」。此操作无法撤销。',
        confirmText: '确认删除',
        icon: Icons.delete_outline,
      );
      if (!protected || !mounted) return;
      try {
        final file = File(record.path);
        if (await file.exists()) {
          await file.delete();
          await ref.read(localGalleryNotifierProvider.notifier).refresh();
          if (mounted) AppToast.success(context, '图片已删除');
        }
      } catch (e) {
        if (mounted) AppToast.error(context, '删除失败: $e');
      }
    }
  }

  void _toggleCategoryPanel() {
    setState(() => _showCategoryPanel = !_showCategoryPanel);
  }

  Future<void> _jumpToDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: DateTime(2020),
      lastDate: now,
      builder: (pickerContext, child) => Theme(
        data: Theme.of(pickerContext).copyWith(
          dialogTheme: DialogThemeData(
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
        ),
        child: child!,
      ),
    );

    if (picked == null || !mounted) return;

    final notifier = ref.read(localGalleryNotifierProvider.notifier);
    final currentState = ref.read(localGalleryNotifierProvider);
    if (!currentState.isGroupedView) await notifier.setGroupedView(true);

    await Future.delayed(const Duration(milliseconds: 300));
    if (!mounted) return;

    // Calculate date differences for grouping
    final today = DateTime(now.year, now.month, now.day);
    final selectedDate = DateTime(picked.year, picked.month, picked.day);
    final daysDiff = today.difference(selectedDate).inDays;

    late final ImageDateGroup targetGroup;
    if (daysDiff == 0) {
      targetGroup = ImageDateGroup.today;
    } else if (daysDiff == 1) {
      targetGroup = ImageDateGroup.yesterday;
    } else if (daysDiff < today.weekday) {
      targetGroup = ImageDateGroup.thisWeek;
    } else {
      targetGroup = ImageDateGroup.earlier;
    }

    _groupedGridViewKey.currentState?.scrollToGroup(targetGroup);

    if (context.mounted) {
      AppToast.info(context,
          '已跳转到 ${picked.year}-${picked.month.toString().padLeft(2, '0')}');
    }
  }
}