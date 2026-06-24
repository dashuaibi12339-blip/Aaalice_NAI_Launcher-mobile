import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nai_launcher/core/utils/localization_extension.dart'; // 👈 保留新版的国际化支持
import 'package:path_provider/path_provider.dart';

import '../../../../core/shortcuts/shortcuts.dart';
import '../../../../core/utils/app_logger.dart';
import '../../../../core/utils/image_share_sanitizer.dart';
import '../../../../core/utils/window_focus_tracker.dart';
import '../../../../data/models/metadata/metadata_import_options.dart';
import '../../../providers/share_image_settings_provider.dart';
import '../../shortcuts/shortcuts.dart';
import '../app_toast.dart';
import '../../metadata/metadata_import_dialog.dart';
import 'components/detail_image_page.dart';
import 'components/detail_metadata_panel.dart';
import 'components/detail_thumbnail_bar.dart';
import 'components/detail_top_bar.dart';
import 'image_detail_data.dart';

/// 图像详情查看器回调函数
class ImageDetailCallbacks {
  final void Function(ImageDetailData image)? onFavoriteToggle;
  final void Function(ImageDetailData image, MetadataImportOptions options)? onReuseMetadata;
  final Future<void> Function(ImageDetailData image)? onSave;
  final Future<void> Function(ImageDetailData image)? onCopyImage;
  
  // 🌟 提取原作者的新功能回调
  final Future<void> Function(ImageDetailData image)? onSendToImg2Img;
  final Future<void> Function(ImageDetailData image)? onSendToReversePrompt;

  const ImageDetailCallbacks({
    this.onFavoriteToggle,
    this.onReuseMetadata,
    this.onSave,
    this.onCopyImage,
    this.onSendToImg2Img,
    this.onSendToReversePrompt,
  });
}

class ImageDetailViewer extends ConsumerStatefulWidget {
  final List<ImageDetailData> images;
  final int initialIndex;
  final bool showMetadataPanel;
  final bool showThumbnails;
  final ImageDetailCallbacks? callbacks;
  final String? heroTagPrefix;

  const ImageDetailViewer({
    super.key,
    required this.images,
    this.initialIndex = 0,
    this.showMetadataPanel = true,
    this.showThumbnails = true,
    this.callbacks,
    this.heroTagPrefix,
  });

  static Future<void> show(
    BuildContext context, {
    required List<ImageDetailData> images,
    int initialIndex = 0,
    bool showMetadataPanel = true,
    bool showThumbnails = true,
    ImageDetailCallbacks? callbacks,
    String? heroTagPrefix,
  }) {
    final isWindows = Platform.isWindows;
    final transitionDuration = isWindows ? Duration.zero : const Duration(milliseconds: 300);
    final reverseTransitionDuration = isWindows ? Duration.zero : const Duration(milliseconds: 250);

    return Navigator.of(context).push(
      PageRouteBuilder(
        opaque: isWindows,
        barrierColor: Colors.black,
        allowSnapshotting: !isWindows,
        transitionDuration: transitionDuration,
        reverseTransitionDuration: reverseTransitionDuration,
        pageBuilder: (context, animation, secondaryAnimation) {
          final viewer = ImageDetailViewer(
            images: images,
            initialIndex: initialIndex,
            showMetadataPanel: showMetadataPanel,
            showThumbnails: showThumbnails,
            callbacks: callbacks,
            heroTagPrefix: heroTagPrefix,
          );
          if (isWindows) return viewer;
          return FadeTransition(
            opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
            child: viewer,
          );
        },
      ),
    );
  }

  static Future<void> showSingle(
    BuildContext context, {
    required ImageDetailData image,
    bool showMetadataPanel = true,
    ImageDetailCallbacks? callbacks,
    String? heroTag,
  }) {
    return show(
      context,
      images: [image],
      initialIndex: 0,
      showMetadataPanel: showMetadataPanel,
      showThumbnails: false,
      callbacks: callbacks,
      heroTagPrefix: heroTag,
    );
  }

  @override
  ConsumerState<ImageDetailViewer> createState() => _ImageDetailViewerState();
}

class _ImageDetailViewerState extends ConsumerState<ImageDetailViewer> {
  static const Duration _windowsEscFocusCooldown = Duration(milliseconds: 1200);
  static const Duration _windowsEscBounceCooldown = Duration(seconds: 4);
  static const Duration _closeRequestThrottle = Duration(milliseconds: 700);

  late PageController _pageController;
  late ScrollController _thumbnailController;
  late int _currentIndex;
  final bool _showControls = true;
  final _focusNode = FocusNode();
  final Map<int, TransformationController> _transformationControllers = {};
  
  bool _isClosing = false;
  DateTime? _lastCloseRequestedAt;
  bool? _localFavorite; // 🌟 手机端保留：用于收藏按钮的瞬间反馈

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: _currentIndex);
    _thumbnailController = ScrollController();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToThumbnail(_currentIndex, animate: false);
      _focusNode.requestFocus();
    });
  }

  void _scrollToThumbnail(int index, {bool animate = true}) {
    if (!_thumbnailController.hasClients) return;
    const thumbnailWidth = 80.0;
    const thumbnailMargin = 8.0;
    const totalWidth = thumbnailWidth + thumbnailMargin;

    final screenWidth = MediaQuery.of(context).size.width;
    final targetOffset = (index * totalWidth) - (screenWidth / 2) + (totalWidth / 2);
    final maxOffset = _thumbnailController.position.maxScrollExtent;
    final offset = targetOffset.clamp(0.0, maxOffset);

    if (animate) {
      _thumbnailController.animateTo(offset, duration: const Duration(milliseconds: 300), curve: Curves.easeInOut);
    } else {
      _thumbnailController.jumpTo(offset);
    }
  }

  void _goToPage(int index) {
    if (index < 0 || index >= widget.images.length) return;
    _pageController.animateToPage(index, duration: const Duration(milliseconds: 300), curve: Curves.easeInOut);
  }

  void _onPageChanged(int index) {
    setState(() {
      _currentIndex = index;
      _localFavorite = null;
    });
    _scrollToThumbnail(index);
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowLeft: _goToPage(_currentIndex - 1); return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowRight: _goToPage(_currentIndex + 1); return KeyEventResult.handled;
      case LogicalKeyboardKey.escape: _handleKeyboardCloseRequest(); return KeyEventResult.handled;
      case LogicalKeyboardKey.home: _goToPage(0); return KeyEventResult.handled;
      case LogicalKeyboardKey.end: _goToPage(widget.images.length - 1); return KeyEventResult.handled;
      default: return KeyEventResult.ignored;
    }
  }

  void _handleKeyboardCloseRequest() {
    if (_shouldSuppressEscCloseOnWindows()) return;
    _requestClose('keyboard-escape');
  }

  bool _shouldSuppressEscCloseOnWindows() {
    if (!Platform.isWindows) return false;
    if (WindowFocusTracker.isWithinCooldown(_windowsEscFocusCooldown)) return true;
    return WindowFocusTracker.hadRecentFocusBounce(maxSinceFocus: _windowsEscBounceCooldown);
  }

  void _requestClose(String reason) {
    if (!mounted || _isClosing) return;
    final now = DateTime.now();
    final lastCloseAt = _lastCloseRequestedAt;
    if (lastCloseAt != null && now.difference(lastCloseAt) <= _closeRequestThrottle) return;
    _lastCloseRequestedAt = now;

    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return;

    _isClosing = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.of(context).maybePop().whenComplete(() {
        if (mounted) _isClosing = false;
      });
    });
  }

  ImageDetailData get _currentImage => widget.images[_currentIndex];

  TransformationController get _currentTransformController {
    if (!_transformationControllers.containsKey(_currentIndex)) {
      _transformationControllers[_currentIndex] = TransformationController();
    }
    return _transformationControllers[_currentIndex]!;
  }

  void _zoomIn() {
    final controller = _currentTransformController;
    final currentScale = controller.value.getMaxScaleOnAxis();
    final newScale = (currentScale * 1.2).clamp(0.5, 4.0);
    final screenSize = MediaQuery.of(context).size;
    final centerX = screenSize.width / 2;
    final centerY = screenSize.height / 2;
    final matrix = Matrix4.identity()
      ..translate(centerX - centerX * newScale, centerY - centerY * newScale)
      ..scale(newScale);
    controller.value = matrix;
  }

  void _zoomOut() {
    final controller = _currentTransformController;
    final currentScale = controller.value.getMaxScaleOnAxis();
    final newScale = (currentScale / 1.2).clamp(0.5, 4.0);
    final screenSize = MediaQuery.of(context).size;
    final centerX = screenSize.width / 2;
    final centerY = screenSize.height / 2;
    final matrix = Matrix4.identity()
      ..translate(centerX - centerX * newScale, centerY - centerY * newScale)
      ..scale(newScale);
    controller.value = matrix;
  }

  void _resetZoom() => _currentTransformController.value = Matrix4.identity();
  void _toggleFullscreen() => _requestClose('toggle-fullscreen');

  void _toggleFavorite() {
    setState(() => _localFavorite = !(_localFavorite ?? _currentImage.isFavorite));
    if (widget.callbacks?.onFavoriteToggle != null) {
      widget.callbacks!.onFavoriteToggle!(_currentImage);
    }
  }

  void _copyPrompt() {
    final metadata = _currentImage.metadata;
    final prompt = metadata?.prompt;
    if (prompt != null && prompt.isNotEmpty) {
      Clipboard.setData(ClipboardData(text: prompt));
      if (context.mounted) AppToast.success(context, context.l10n.toast_imagePromptCopied);
    } else {
      if (context.mounted) AppToast.warning(context, context.l10n.toast_imageHasNoPrompt);
    }
  }
  
  void _reuseGalleryParams() {
    if (widget.callbacks?.onReuseMetadata != null) _handleReuseMetadata(context);
  }

  void _deleteImage() {
    if (context.mounted) AppToast.info(context, context.l10n.toast_useDeleteButton);
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final isDesktop = screenWidth > 800;

    final shortcuts = <String, VoidCallback>{
      ShortcutIds.previousImage: () => _goToPage(_currentIndex - 1),
      ShortcutIds.nextImage: () => _goToPage(_currentIndex + 1),
      ShortcutIds.zoomIn: _zoomIn,
      ShortcutIds.zoomOut: _zoomOut,
      ShortcutIds.resetZoom: _resetZoom,
      ShortcutIds.toggleFullscreen: _toggleFullscreen,
      ShortcutIds.closeViewer: _handleKeyboardCloseRequest,
      ShortcutIds.toggleFavorite: _toggleFavorite,
      ShortcutIds.copyPrompt: _copyPrompt,
      ShortcutIds.reuseGalleryParams: _reuseGalleryParams,
      ShortcutIds.deleteImage: _deleteImage,
    };

    return PageShortcuts(
      contextType: ShortcutContext.viewer,
      shortcuts: shortcuts,
      child: Focus(
        focusNode: _focusNode,
        onKeyEvent: _handleKeyEvent,
        child: Scaffold(
          backgroundColor: Colors.black,
          body: isDesktop && widget.showMetadataPanel
              ? Row(
                  children: [
                    Expanded(child: _buildMainContent()),
                    DetailMetadataPanel(currentImage: _currentImage, initialExpanded: true),
                  ],
                )
              : _buildMainContent(),
        ),
      ),
    );
  }

  Widget _buildMainContent() {
    final showThumbnails = widget.showThumbnails && widget.images.length > 1;
    final isMobile = MediaQuery.of(context).size.width <= 800;

    return Stack(
      children: [
        PageView.builder(
          controller: _pageController,
          itemCount: widget.images.length,
          onPageChanged: _onPageChanged,
          itemBuilder: (context, index) {
            final data = widget.images[index];
            final heroTag = widget.heroTagPrefix != null && index == _currentIndex
                    ? '${widget.heroTagPrefix}_${data.identifier}' : null;
            if (!_transformationControllers.containsKey(index)) {
              _transformationControllers[index] = TransformationController();
            }
            return DetailImagePage(
              data: data,
              heroTag: heroTag,
              transformationController: _transformationControllers[index],
            );
          },
        ),

        AnimatedPositioned(
          duration: const Duration(milliseconds: 200),
          top: _showControls ? 0 : -100,
          left: 0,
          right: 0,
          // 🌟 恢复：这里判断是手机端，渲染你专属的 _buildMobileTopBar
          child: isMobile ? _buildMobileTopBar(context) : DetailTopBar(
            currentIndex: _currentIndex,
            totalImages: widget.images.length,
            currentImage: _currentImage,
            onClose: () => _requestClose('top-bar-close'),
            onReuseMetadata: widget.callbacks?.onReuseMetadata != null
                ? () => _handleReuseMetadata(context) : null,
            onFavoriteToggle: widget.callbacks?.onFavoriteToggle != null
                ? () => widget.callbacks!.onFavoriteToggle!(_currentImage) : null,
            onSave: widget.callbacks?.onSave != null
                ? () => widget.callbacks!.onSave!(_currentImage) : null,
            onCopyImage: () => _copyImageToClipboard(context),
            // 🌟 补全新增功能回调
            onSendToImg2Img: widget.callbacks?.onSendToImg2Img != null
                ? () => widget.callbacks!.onSendToImg2Img!(_currentImage) : null,
            onSendToReversePrompt: widget.callbacks?.onSendToReversePrompt != null
                ? () => widget.callbacks!.onSendToReversePrompt!(_currentImage) : null,
          ),
        ),

        if (showThumbnails)
          AnimatedPositioned(
            duration: const Duration(milliseconds: 200),
            bottom: _showControls ? 0 : -140,
            left: 0,
            right: 0,
            child: _buildBottomBar(),
          ),

        if (_showControls && widget.images.length > 1) ...[
          if (_currentIndex > 0)
            Positioned(
              left: 16, top: 0, bottom: 0,
              child: Center(child: _NavigationButton(icon: Icons.chevron_left, onPressed: () => _goToPage(_currentIndex - 1))),
            ),
          if (_currentIndex < widget.images.length - 1)
            Positioned(
              right: 16, top: 0, bottom: 0,
              child: Center(child: _NavigationButton(icon: Icons.chevron_right, onPressed: () => _goToPage(_currentIndex + 1))),
            ),
        ],
      ],
    );
  }

  /// 🌟 恢复：手机端专属顶部栏，集成菜单
  Widget _buildMobileTopBar(BuildContext context) {
    return Container(
      padding: EdgeInsets.only(
        top: MediaQuery.of(context).padding.top + 8,
        bottom: 16, left: 8, right: 8,
      ),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black87, Colors.transparent],
        ),
      ),
      child: Row(
        children: [
          IconButton(icon: const Icon(Icons.close, color: Colors.white), onPressed: () => _requestClose('mobile-close')),
          const SizedBox(width: 8),
          Text('${_currentIndex + 1} / ${widget.images.length}', style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500)),
          const Spacer(),
          IconButton(icon: const Icon(Icons.info_outline, color: Colors.white), onPressed: () => _showMobileMetadataBottomSheet(context)),
          if (widget.callbacks?.onFavoriteToggle != null)
            IconButton(
              icon: Icon(
                (_localFavorite ?? _currentImage.isFavorite) ? Icons.favorite : Icons.favorite_border,
                color: (_localFavorite ?? _currentImage.isFavorite) ? Colors.red : Colors.white,
              ),
              onPressed: _toggleFavorite,
            ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, color: Colors.white),
            color: Theme.of(context).colorScheme.surfaceContainerHigh,
            onSelected: (value) {
              if (value == 'reuse') _handleReuseMetadata(context);
              else if (value == 'copy_prompt') _copyPrompt();
              else if (value == 'copy_image') _copyImageToClipboard(context);
              else if (value == 'img2img') widget.callbacks?.onSendToImg2Img?.call(_currentImage);
              else if (value == 'reverse_prompt') widget.callbacks?.onSendToReversePrompt?.call(_currentImage);
            },
            itemBuilder: (context) => [
              if (widget.callbacks?.onReuseMetadata != null)
                const PopupMenuItem(value: 'reuse', child: Text('套用参数')),
              const PopupMenuItem(value: 'copy_prompt', child: Text('复制提示词')),
              const PopupMenuItem(value: 'copy_image', child: Text('复制图片')),
              if (widget.callbacks?.onSendToImg2Img != null)
                const PopupMenuItem(value: 'img2img', child: Text('发送到图生图')),
              if (widget.callbacks?.onSendToReversePrompt != null)
                const PopupMenuItem(value: 'reverse_prompt', child: Text('发送到反推模块')),
            ],
          ),
        ],
      ),
    );
  }

  /// 🌟 恢复：手机端底部参数面板弹窗
  void _showMobileMetadataBottomSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        height: MediaQuery.of(context).size.height * 0.7,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          children: [
            Container(
              margin: const EdgeInsets.symmetric(vertical: 12),
              width: 40, height: 4,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Expanded(
              child: DetailMetadataPanel(currentImage: _currentImage, initialExpanded: true),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomBar() {
    final metadata = _currentImage.metadata;
    return Container(
      height: 140,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          // 🌟 更新为 Flutter 3.27 语法
          colors: [Colors.black.withValues(alpha: 0.8), Colors.transparent],
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (metadata != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: _buildMetadataInfo(metadata),
            ),
          DetailThumbnailBar(
            images: widget.images,
            currentIndex: _currentIndex,
            scrollController: _thumbnailController,
            onTap: _goToPage,
          ),
        ],
      ),
    );
  }

  Widget _buildMetadataInfo(dynamic metadata) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (metadata.seed != null) _buildInfoChip('Seed: ${metadata.seed}'),
          if (metadata.steps != null) _buildInfoChip('${metadata.steps} steps'),
          if (metadata.scale != null) _buildInfoChip('CFG: ${metadata.scale}'),
          if (metadata.sampler != null) _buildInfoChip(metadata.displaySampler),
          if (metadata.width != null && metadata.height != null)
            _buildInfoChip('${metadata.width}×${metadata.height}'),
        ],
      ),
    );
  }

  Widget _buildInfoChip(String text) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.15), // 🌟 Flutter 3.27 语法
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 12)),
    );
  }

  Future<void> _copyImageToClipboard(BuildContext context) async {
    // 🌟 恢复：手机端拦截保护，防止崩溃
    if (Platform.isAndroid || Platform.isIOS || Platform.operatingSystem == 'ohos') {
      if (context.mounted) AppToast.info(context, '移动端请使用"保存"功能或图库分享');
      return;
    }

    final l10n = context.l10n;
    File? tempFile;
    try {
      final imageBytes = await _currentImage.getImageBytes();
      final fileName = _currentImage.fileInfo?.fileName ?? 'shared.png';
      
      final stripMetadata = ref.read(shareImageSettingsProvider).effectiveStripMetadataForCopyAndDrag;
      final shareImage = await ImageShareSanitizer.prepareForCopyOrDrag(
        imageBytes, fileName: fileName, stripMetadata: stripMetadata,
      );

      final tempDir = await getTemporaryDirectory();
      tempFile = File('${tempDir.path}/NAI_${DateTime.now().millisecondsSinceEpoch}_${shareImage.fileName}');
      await tempFile.writeAsBytes(shareImage.bytes, flush: true);

      if (!await tempFile.exists()) throw Exception(l10n.toast_tempFileCreateFailed);

      final result = await Process.run('powershell', [
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command',
        'Add-Type -AssemblyName System.Windows.Forms; Add-Type -AssemblyName System.Drawing; \$image = [System.Drawing.Image]::FromFile("${tempFile.path}"); [System.Windows.Forms.Clipboard]::SetImage(\$image); \$image.Dispose();',
      ]);

      if (result.exitCode != 0) {
        throw Exception(l10n.toast_powershellCommandFailed(result.exitCode, result.stderr.toString()));
      }

      await Future.delayed(const Duration(milliseconds: 500));
      if (context.mounted) AppToast.success(context, l10n.image_copiedToClipboard);
    } catch (e) {
      if (context.mounted) AppToast.error(context, l10n.image_copyFailed(e.toString()));
    } finally {
      if (tempFile != null && await tempFile.exists()) {
        try { await tempFile.delete(); } catch (_) {}
      }
    }
  }

  Future<void> _handleReuseMetadata(BuildContext context) async {
    final metadata = _currentImage.metadata;
    if (metadata == null || !metadata.hasData) {
      AppToast.warning(context, context.l10n.toast_imageHasNoMetadata);
      return;
    }

    final options = await MetadataImportDialog.show(context, metadata: metadata);
    if (options == null || !context.mounted) return;

    // 🌟 恢复：手机端双重弹窗修复保留，先关大图再回调
    _requestClose('reuse-metadata');
    Future.delayed(const Duration(milliseconds: 50), () {
      widget.callbacks?.onReuseMetadata?.call(_currentImage, options);
    });
  }
  
  @override
  void dispose() {
    for (final controller in _transformationControllers.values) {
      controller.dispose();
    }
    _transformationControllers.clear();
    _pageController.dispose();
    _thumbnailController.dispose();
    _focusNode.dispose();
    super.dispose();
  }
}

class _NavigationButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onPressed;

  const _NavigationButton({required this.icon, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.3), // 🌟 Flutter 3.27 语法
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Icon(icon, color: Colors.white, size: 32),
        ),
      ),
    );
  }
}