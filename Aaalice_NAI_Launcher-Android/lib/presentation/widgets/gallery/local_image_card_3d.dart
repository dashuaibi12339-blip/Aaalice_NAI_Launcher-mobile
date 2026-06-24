import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:share_plus/share_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:image_gallery_saver_plus/image_gallery_saver_plus.dart';

import '../../../core/cache/thumbnail_cache_service.dart';
import '../../../core/utils/app_logger.dart';
import '../../../core/utils/image_share_sanitizer.dart';
import '../../../data/models/gallery/local_image_record.dart';
import '../../../data/services/image_metadata_service.dart';
import '../../../data/services/thumbnail_service.dart';
import '../../providers/share_image_settings_provider.dart';
import '../../services/image_workflow_launcher.dart';
import '../../themes/theme_extension.dart';
import '../common/app_toast.dart';
import '../common/floating_action_buttons.dart';

enum _ImageLoadState { idle, loading, loaded, error }

/// Steam风格本地图片卡片，包含边缘发光、光泽扫过、悬停动画效果
class LocalImageCard3D extends ConsumerStatefulWidget {
  final LocalImageRecord record;
  final double width;
  final double? height;
  final VoidCallback? onTap;
  final VoidCallback? onDoubleTap;
  final VoidCallback? onLongPress;
  final void Function(TapDownDetails)? onSecondaryTapDown;
  final bool isSelected;
  final bool showFavoriteIndicator;
  final VoidCallback? onFavoriteToggle;
  final VoidCallback? onSendToHome;
  final VoidCallback? onSendToImg2Img;
  final VoidCallback? onSendToReversePrompt;
  final VoidCallback? onSendToVibeTransfer;     // 👈 确保有这行
  final VoidCallback? onSendToPreciseReference; // 👈 确保有这行
  final VoidCallback? onDelete;                 // 👈 确保有这行  
  final bool isVisible;
  final int priority;

  /// 可选的拖拽包装器，用于将卡片内容包装在 DragItemWidget 中
  /// 解决 GestureDetector 与拖拽手势冲突的问题
  final Widget Function(Widget child)? dragWrapper;

  const LocalImageCard3D({
    super.key,
    required this.record,
    required this.width,
    this.height,
    this.onTap,
    this.onDoubleTap,
    this.onLongPress,
    this.onSecondaryTapDown,
    this.isSelected = false,
    this.showFavoriteIndicator = true,
    this.onFavoriteToggle,
    this.onSendToHome,
    this.onSendToImg2Img,
    this.onSendToReversePrompt,
    this.onSendToVibeTransfer,     // 👈 确保有这行
    this.onSendToPreciseReference, // 👈 确保有这行
    this.onDelete,                 // 👈 确保有这行   
    this.isVisible = false,
    this.priority = 5,
    this.dragWrapper,
  });

  @override
  ConsumerState<LocalImageCard3D> createState() => _LocalImageCard3DState();
}

class _LocalImageCard3DState extends ConsumerState<LocalImageCard3D>
    with TickerProviderStateMixin, AutomaticKeepAliveClientMixin {
  bool _isHovered = false;
  bool _isPressed = false;
  late AnimationController _glossController;
  late Animation<double> _glossAnimation;
  
  String? _thumbnailPath;
  bool _isHdVisible = false; // 💡 新增：控制是否在视线内渲染高清图
  ThumbnailCacheService? _thumbnailService;
  _ImageLoadState _loadState = _ImageLoadState.idle;
  bool _isLoadingThumbnail = false;

  // ... 下面的 initState 保持不变 ...
  @override
  bool get wantKeepAlive => false;

  @override
  void initState() {
    super.initState();
    _glossController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _glossAnimation = Tween<double>(begin: -1.5, end: 1.5).animate(
      CurvedAnimation(parent: _glossController, curve: Curves.easeInOut),
    );
    _initAndLoadThumbnail();
  }

  // 👇 这个就是你刚才缺失的方法，补回来！
  Future<void> _initAndLoadThumbnail() async {
    _thumbnailService = ThumbnailCacheService.instance;
    await _thumbnailService!.init();
    await _loadThumbnail();
  }

  @override
  void didUpdateWidget(LocalImageCard3D oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.priority != widget.priority ||
        (oldWidget.isVisible != widget.isVisible && widget.isVisible)) {
      if (_thumbnailPath == null && !_isLoadingThumbnail) {
        _loadThumbnail();
      }
    }
    // 💡 删除了之前限制视线的 _isHdVisible 逻辑
  }

  Future<void> _loadThumbnail() async {
    if (_isLoadingThumbnail) return;

    _isLoadingThumbnail = true;
    final path = widget.record.path;
    final fileName = path.split(Platform.pathSeparator).last;

    try {
      setState(() => _loadState = _ImageLoadState.loading);

      final originalFile = File(path);
      if (!await originalFile.exists()) {
        AppLogger.e('[CardLoad] Original file NOT FOUND: $path', 'LocalImageCard3D');
        if (mounted) {
          setState(() => _loadState = _ImageLoadState.error);
        }
        return;
      }

      final existingPath = await _thumbnailService?.getThumbnailPath(path);
      if (existingPath != null && await File(existingPath).exists()) {
        if (mounted) {
          setState(() {
            _thumbnailPath = existingPath;
            _loadState = _ImageLoadState.loaded;
          });
        }
        return;
      }

      final thumbnailService = ThumbnailService.instance;
      await thumbnailService.initialize();
      thumbnailService.updateVisibility(
        path,
        isVisible: widget.isVisible,
        priority: widget.priority,
      );

      final generatedPath = await thumbnailService.getThumbnail(
        path,
        size: ThumbnailSize.small,
        priority: widget.priority,
      );

      if (!mounted || widget.record.path != path) return;

      setState(() {
        _thumbnailPath = generatedPath; 
        _loadState = _ImageLoadState.loaded;
      });
    } catch (e, stack) {
      AppLogger.e('[CardLoad] ERROR: $fileName', e, stack, 'LocalImageCard3D');
      if (mounted) {
        setState(() {
          _loadState = _ImageLoadState.loaded;
        });
      }
    } finally {
      _isLoadingThumbnail = false;
    }
  }

  void _onHoverEnter(PointerEvent event) {
    if (Platform.isAndroid || Platform.isIOS) return; // 手机端彻底屏蔽悬停发光和按钮弹出
    setState(() => _isHovered = true);
    _glossController.forward(from: 0.0);
  }

  void _onHoverExit(PointerEvent event) {
    if (Platform.isAndroid || Platform.isIOS) return; // 手机端彻底屏蔽悬停
    setState(() => _isHovered = false);
  }

  // 👇 硬件级触摸按下：瞬间触发，无视任何滑动冲突
  void _handlePointerDown(PointerDownEvent event) {
    setState(() => _isPressed = true);
    _glossController.forward(from: 0.0); // 触发光泽动画
  }

  // 👇 硬件级触摸抬起或被列表滑动强行打断时：恢复原状
  void _handlePointerUpOrCancel(PointerEvent event) {
    setState(() => _isPressed = false);
  }
  
  // 新增：打开超分放大面板
  Future<void> _openUpscale() async {
    try {
      final bytes = await File(widget.record.path).readAsBytes();
      if (mounted) {
        ImageWorkflowLauncher.openUpscale(ref, bytes);
        AppToast.info(context, '已载入图生图超分面板');
      }
    } catch (e) {
      if (mounted) AppToast.error(context, '读取图像失败: $e');
    }
  }

  // 👇 新增：调用系统原生分享面板
  Future<void> _shareImage() async {
    try {
      final sourceFile = File(widget.record.path);
      if (!await sourceFile.exists()) {
        if (mounted) AppToast.error(context, '文件不存在');
        return;
      }
      await Share.shareXFiles([XFile(widget.record.path)], text: '分享图片');
    } catch (e) {
      if (mounted) AppToast.error(context, '分享失败: $e');
    }
  }

  Future<void> _copyImageToClipboard() async {
    // 移动端直接保存到系统相册
    if (Platform.isAndroid || Platform.isIOS) {
      try {
        final sourceFile = File(widget.record.path);
        if (!await sourceFile.exists()) {
          if (mounted) AppToast.error(context, '文件不存在');
          return;
        }
        final bytes = await sourceFile.readAsBytes();
        final result = await ImageGallerySaverPlus.saveImage(
          bytes,
          quality: 100,
          name: "NAI_${DateTime.now().millisecondsSinceEpoch}",
        );
        if (mounted) {
          if (result['isSuccess'] == true) {
            AppToast.success(context, '已保存到系统相册');
          } else {
            AppToast.error(context, '保存相册失败');
          }
        }
      } catch (e) {
        if (mounted) {
          AppToast.error(context, '保存相册失败: $e');
        }
      }
      return;
    }

    // PC端：原作者更新后的带元数据清理的 PowerShell 复制逻辑
    File? tempFile;
    try {
      final sourceFile = File(widget.record.path);
      if (!await sourceFile.exists()) {
        if (mounted) AppToast.error(context, '文件不存在');
        return;
      }

      final stripMetadata = ref
          .read(shareImageSettingsProvider)
          .effectiveStripMetadataForCopyAndDrag;
      final sourceParts = sourceFile.path.split(RegExp(r'[/\\]'));
      final sourceName =
          sourceParts.isNotEmpty ? sourceParts.last : 'shared.png';
      final originalBytes = await sourceFile.readAsBytes();
      final shareImage = await ImageShareSanitizer.prepareForCopyOrDrag(
        originalBytes,
        fileName: sourceName,
        stripMetadata: stripMetadata,
      );

      final tempDir = await getTemporaryDirectory();
      tempFile = File(
        '${tempDir.path}/NAI_${DateTime.now().millisecondsSinceEpoch}_${shareImage.fileName}',
      );
      await tempFile.writeAsBytes(shareImage.bytes, flush: true);

      const psCommand = r'''
Add-Type -AssemblyName System.Windows.Forms;
Add-Type -AssemblyName System.Drawing;
$image = [System.Drawing.Image]::FromFile("''';
      final result = await Process.run('powershell', [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        '$psCommand${tempFile.path}"); [System.Windows.Forms.Clipboard]::SetImage(\$image); \$image.Dispose();',
      ]);

      if (result.exitCode != 0) throw Exception('PowerShell 命令失败');

      await Future.delayed(const Duration(milliseconds: 500));
      if (mounted) AppToast.success(context, '已复制到剪贴板');
    } catch (e) {
      if (mounted) AppToast.error(context, '复制失败: $e');
    } finally {
      if (tempFile != null && await tempFile.exists()) {
        try {
          await tempFile.delete();
        } catch (_) {}
      }
    }
  }

  (_EffectIntensity, Color) _getEffectConfig(BuildContext context) {
    final theme = Theme.of(context);
    final extension = theme.extension<AppThemeExtension>();

    final intensity = switch ((extension?.enableNeonGlow, extension?.isLightTheme)) {
      (true, _) => (edgeGlow: 1.3, gloss: 1.0),
      (_, true) => (edgeGlow: 0.6, gloss: 1.0),
      _ => (edgeGlow: 1.0, gloss: 0.8),
    };

    final glowColor = extension?.glowColor ?? theme.colorScheme.primary;
    return (_EffectIntensity(edgeGlow: intensity.edgeGlow, gloss: intensity.gloss), glowColor);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    final cardHeight = widget.height ?? widget.width;
    final colorScheme = theme.colorScheme;
    final (intensity, glowColor) = _getEffectConfig(context);
    final isMobile = Platform.isAndroid || Platform.isIOS;
    
    Widget cardContent = GestureDetector(
      onTap: widget.onTap,
      onDoubleTap: widget.onDoubleTap,
      onLongPress: _handleLongPress,
      onSecondaryTapDown: widget.onSecondaryTapDown,
      child: Listener(
        // 👈 核心：使用 Listener 拦截最原始的硬件触摸信号
        onPointerDown: _handlePointerDown,
        onPointerUp: _handlePointerUpOrCancel,
        onPointerCancel: _handlePointerUpOrCancel,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOutCubic,
          // 👈 物理引擎：按压时缩小(0.96)，PC端仅悬停时放大(1.03)，默认(1.0)
          transform: Matrix4.identity()..scale(_isPressed ? 0.96 : (_isHovered && !isMobile ? 1.03 : 1.0)),
          transformAlignment: Alignment.center,
          child: Container(
            width: widget.width,
            height: cardHeight,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: widget.isSelected
                  ? Border.all(color: colorScheme.primary, width: 3)
                  : (_isHovered || _isPressed) // 👈 按压或悬停都显示边框
                      ? Border.all(color: colorScheme.primary.withValues(alpha: 0.3), width: 2)
                      : null,
              boxShadow: [
                BoxShadow(
                  color: (_isHovered || _isPressed)
                      ? Colors.black.withValues(alpha: 0.35)
                      : Colors.black.withValues(alpha: 0.12),
                  blurRadius: (_isHovered || _isPressed) ? 28 : 10,
                  offset: Offset(0, (_isHovered || _isPressed) ? 14 : 4),
                  spreadRadius: (_isHovered || _isPressed) ? 2 : 0,
                ),
                if (_isHovered || _isPressed)
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.15),
                    blurRadius: 40,
                    offset: const Offset(0, 20),
                    spreadRadius: -4,
                  ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _buildImageLayer(),
                  // 👇 按压或悬停时都触发边缘发光
                  if (_isHovered || _isPressed)
                    Positioned.fill(
                      child: TweenAnimationBuilder<double>(
                        tween: Tween(begin: 0.0, end: 1.0),
                        duration: const Duration(milliseconds: 200),
                        curve: Curves.easeOut,
                        builder: (context, value, child) => _EdgeGlowOverlay(
                          glowColor: glowColor,
                          intensity: value * intensity.edgeGlow,
                        ),
                      ),
                    ),
                  // 👇 按压或悬停时都触发光泽扫过
                  if (_isHovered || _isPressed)
                    Positioned.fill(
                      child: RepaintBoundary(
                        child: AnimatedBuilder(
                          animation: _glossAnimation,
                          builder: (context, child) => _GlossOverlay(
                            progress: _glossAnimation.value,
                            intensity: intensity.gloss,
                          ),
                        ),
                      ),
                    ),

                // PC 端显示完整的悬浮操作栏，手机端只显示一个静态红心
                if (!isMobile)
                  Positioned(
                    top: 8,
                    right: 8,
                    child: _buildActionButtons(),
                  )
                else if (widget.record.isFavorite)
                  Positioned(
                    top: 8,
                    right: 8,
                    child: Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.55),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.favorite, color: Colors.red, size: 16),
                    ),
                  ),

                if (widget.isSelected)
                  Positioned(
                    top: 8,
                    left: 8,
                    child: _buildSelectionIndicator(colorScheme),
                  ),
                  
                if (widget.isSelected)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: Container(
                        decoration: BoxDecoration(
                          color: colorScheme.primary.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                  
                if (!isMobile && _isHovered && widget.record.metadata != null)
                  Positioned(
                    bottom: 0,
                    left: 0,
                    right: 0,
                    child: _buildMetadataPreview(theme),
                  ),
              ],
            ),
          ),
        ),
      ), 
    ),  
  );   
    if (widget.dragWrapper != null) {
      cardContent = widget.dragWrapper!(cardContent);
    }

    return MouseRegion(
      onEnter: _onHoverEnter,
      onExit: _onHoverExit,
      cursor: SystemMouseCursors.click,
      child: cardContent,
    );
  }

  Widget _buildImageLayer() => switch (_loadState) {
        _ImageLoadState.error => _buildErrorPlaceholder(),
        _ImageLoadState.loading => _buildLoadingPlaceholder(),
        _ImageLoadState.loaded => _buildProgressiveImage(),
        _ => _buildLoadingPlaceholder(),
      };

  Widget _buildProgressiveImage() {
    final pixelRatio = MediaQuery.of(context).devicePixelRatio;
    
    final thumbCacheWidth = (widget.width * pixelRatio * 0.5).toInt();
    final hdCacheWidth = (widget.width * pixelRatio * 1.5).toInt();

    return Stack(
      fit: StackFit.expand,
      children: [
        // 1. 底层：模糊的缩略图（垫底，防止滑动过快时出现黑块）
        Image.file(
          File(_thumbnailPath ?? widget.record.path),
          fit: BoxFit.cover, 
          cacheWidth: thumbCacheWidth, 
          gaplessPlayback: true,
        ),

        // 2. 顶层：高清原图（🚀 解除视线枷锁，利用 Flutter 底层 CacheExtent 在屏幕外提前预渲染！）
        Image.file(
          File(widget.record.path),
          fit: BoxFit.cover, 
          cacheWidth: hdCacheWidth, 
          gaplessPlayback: true,
          frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
            // 💡 如果在屏幕外就已经预加载完成了，滑入时直接显示高清，没有任何动画和延迟！
            if (wasSynchronouslyLoaded) return child;
            
            // 如果滑得太快，还没预加载完，就用 250ms 的极速淡入，让过渡更加无感
            return AnimatedOpacity(
              opacity: frame == null ? 0 : 1,
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOutCubic,
              child: child,
            );
          },
          errorBuilder: (context, error, stackTrace) => const SizedBox.shrink(),
        ),
      ],
    );
  }

  Widget _buildLoadingPlaceholder() {
    return Container(
      color: Colors.grey[850],
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 32,
              height: 32,
              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.grey[600]),
            ),
            const SizedBox(height: 8),
            Text('加载中...', style: TextStyle(color: Colors.grey[600], fontSize: 11)),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorPlaceholder() {
    return Container(
      color: Colors.red[900]?.withValues(alpha: 0.3),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.broken_image, color: Colors.red[400], size: 40),
            const SizedBox(height: 8),
            Text('加载失败', style: TextStyle(color: Colors.red[300], fontSize: 12)),
            const SizedBox(height: 4),
            TextButton.icon(
              onPressed: _loadThumbnail,
              icon: Icon(Icons.refresh, color: Colors.red[300], size: 16),
              label: Text('重试', style: TextStyle(color: Colors.red[300], fontSize: 11)),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // 👇 下面紧接着你的 _buildActionButtons() 方法，保持不变
  Widget _buildActionButtons() {
    return FloatingActionButtons(
      isVisible: _isHovered,
      buttons: [
        FloatingActionButtonData(
          icon: widget.record.isFavorite ? Icons.favorite : Icons.favorite_border,
          onTap: widget.onFavoriteToggle,
          iconColor: widget.record.isFavorite ? Colors.red : Colors.white,
          visible: widget.onFavoriteToggle != null,
        ),
        FloatingActionButtonData(icon: Icons.copy, onTap: _copyImageToClipboard),
        FloatingActionButtonData(
          icon: Icons.send,
          onTap: () => _showSendToHomeMenu(context),
          visible: widget.onSendToHome != null || widget.onSendToImg2Img != null,
        ),
      ],
    );
  }

  void _showSendToHomeMenu(BuildContext context) {
    final RenderBox? button = context.findRenderObject() as RenderBox?;
    if (button == null) return;

    final offset = button.localToGlobal(Offset.zero);
    final screenSize = MediaQuery.of(context).size;

    const menuWidth = 160.0;
    double left = offset.dx - menuWidth - 8;
    double top = offset.dy;

    if (left < 8) left = offset.dx + button.size.width + 8;
    if (top + 150 > screenSize.height) top = screenSize.height - 150;

    showDialog<void>(
      context: context,
      barrierColor: Colors.transparent,
      useRootNavigator: true,
      builder: (dialogContext) => _SendToHomeMenu(
        position: Offset(left, top),
        onSendToTxt2Img: widget.onSendToHome != null
            ? () {
                Navigator.of(dialogContext).pop();
                widget.onSendToHome!();
              }
            : null,
        onSendToImg2Img: widget.onSendToImg2Img != null
            ? () {
                Navigator.of(dialogContext).pop();
                widget.onSendToImg2Img!();
              }
            : null,
        onUpscale: () {
          Navigator.of(dialogContext).pop();
          _openUpscale();
        },
      ),
    );
  }

  Widget _buildSelectionIndicator(ColorScheme colorScheme) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOutBack,
      builder: (context, value, child) => Transform.scale(scale: value, child: child),
      child: Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          color: colorScheme.primary,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white, width: 2),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.2),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Icon(Icons.check, color: colorScheme.onPrimary, size: 18),
      ),
    );
  }

  Widget _buildMetadataPreview(ThemeData theme) {
    final metadata = widget.record.metadata;
    if (metadata == null) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [
            Colors.black.withValues(alpha: 0.85),
            Colors.black.withValues(alpha: 0.4),
            Colors.transparent,
          ],
          stops: const [0.0, 0.6, 1.0],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (metadata.model != null)
            Text(
              metadata.model!,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          const SizedBox(height: 2),
          Wrap(
            spacing: 4,
            runSpacing: 2,
            children: [
              if (metadata.seed != null) _buildMetadataChip('Seed: ${metadata.seed}'),
              if (metadata.steps != null) _buildMetadataChip('${metadata.steps} steps'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMetadataChip(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 10)),
    );
  }

  @override
  void dispose() {
    _glossController.dispose();
    super.dispose();
  }

  // 处理长按事件
  void _handleLongPress() {
    if (Platform.isAndroid || Platform.isIOS) {
      HapticFeedback.mediumImpact(); // 👈 增加清脆的震动反馈
      _showMobileMenu(context);
    } else {
      widget.onLongPress?.call();
    }
  }
  
  // 手机端专属的长按底部菜单，加入了原作者的新功能
  void _showMobileMenu(BuildContext context) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (dialogContext) => SafeArea(
        // 👇 增加 SingleChildScrollView 防止选项太多在小屏手机上越界报错
        child: SingleChildScrollView( 
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 1. 保存到系统相册
              ListTile(
                leading: const Icon(Icons.photo_library_rounded),
                title: const Text('保存到系统相册'),
                onTap: () {
                  Navigator.pop(dialogContext);
                  _copyImageToClipboard();
                },
              ),
              // 2. 分享图片 (放在保存下面)
              ListTile(
                leading: const Icon(Icons.share_rounded),
                title: const Text('分享图片'),
                onTap: () {
                  Navigator.pop(dialogContext);
                  _shareImage();
                },
              ),           
              if (widget.onFavoriteToggle != null)
                ListTile(
                  leading: Icon(
                    widget.record.isFavorite ? Icons.favorite : Icons.favorite_border,
                    color: widget.record.isFavorite ? Colors.red : null,
                  ),
                  title: Text(widget.record.isFavorite ? '取消收藏' : '收藏'),
                  onTap: () {
                    Navigator.pop(dialogContext);
                    widget.onFavoriteToggle!();
                  },
                ),
              ListTile(
                leading: const Icon(Icons.text_snippet_outlined),
                title: const Text('复制提示词'),
                onTap: () async {
                  Navigator.pop(dialogContext);
                  try {
                    final metadata = await ImageMetadataService().getMetadataImmediate(widget.record.path) 
                                     ?? widget.record.metadata;
                    final prompt = metadata?.fullPrompt ?? '';

                    if (prompt.isNotEmpty) {
                      await Clipboard.setData(ClipboardData(text: prompt));
                      if (mounted) AppToast.success(context, '提示词已复制到剪贴板');
                    } else {
                      if (mounted) AppToast.warning(context, '此图片没有提示词数据');
                    }
                  } catch (e) {
                    if (mounted) AppToast.error(context, '读取提示词失败');
                  }
                },
              ),
              if (widget.onSendToHome != null)
                ListTile(
                  leading: const Icon(Icons.text_fields),
                  title: const Text('发送到文生图 (套用参数)'),
                  onTap: () {
                    Navigator.pop(dialogContext);
                    widget.onSendToHome!();
                  },
                ),
              if (widget.onSendToImg2Img != null)
                ListTile(
                  leading: const Icon(Icons.image),
                  title: const Text('发送到图生图 (载入源图)'),
                  onTap: () {
                    Navigator.pop(dialogContext);
                    widget.onSendToImg2Img!();
                  },
                ),
              if (widget.onSendToReversePrompt != null)
                ListTile(
                  leading: const Icon(Icons.auto_fix_high),
                  title: const Text('发送到反推 (提取提示词)'),
                  onTap: () {
                    Navigator.pop(dialogContext);
                    widget.onSendToReversePrompt!();
                  },
                ),
              if (widget.onSendToVibeTransfer != null)
                ListTile(
                  leading: const Icon(Icons.style),
                  title: const Text('发送到风格迁移 (Vibe)'),
                  onTap: () {
                    Navigator.pop(dialogContext);
                    widget.onSendToVibeTransfer!();
                  },
                ),
              if (widget.onSendToPreciseReference != null)
                ListTile(
                  leading: const Icon(Icons.person_search),
                  title: const Text('发送到精准参考'),
                  onTap: () {
                    Navigator.pop(dialogContext);
                    widget.onSendToPreciseReference!();
                  },
                ),
              ListTile(
                leading: const Icon(Icons.zoom_in),
                title: const Text('超分放大'),            
                onTap: () {
                  Navigator.pop(dialogContext);
                  _openUpscale();
                },
              ),
              if (widget.onDelete != null)
                ListTile(
                  leading: const Icon(Icons.delete_outline, color: Colors.red),
                  title: const Text('删除', style: TextStyle(color: Colors.red)),
                  onTap: () {
                    Navigator.pop(dialogContext);
                    widget.onDelete!();
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EffectIntensity {
  final double edgeGlow;
  final double gloss;

  const _EffectIntensity({required this.edgeGlow, required this.gloss});
}

class _EdgeGlowOverlay extends StatelessWidget {
  final Color glowColor;
  final double intensity;

  const _EdgeGlowOverlay({required this.glowColor, this.intensity = 1.0});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(
        size: Size.infinite,
        painter: _EdgeGlowPainter(glowColor: glowColor, intensity: intensity),
      ),
    );
  }
}

class _EdgeGlowPainter extends CustomPainter {
  final Color glowColor;
  final double intensity;

  _EdgeGlowPainter({required this.glowColor, required this.intensity});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(0, 0, size.width, size.height);
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(12));

    for (int i = 0; i < 3; i++) {
      final inset = (i + 1) * 1.5;
      final innerRRect = RRect.fromRectAndRadius(
        rect.deflate(inset),
        Radius.circular(math.max(0, 12 - inset)),
      );

      final paint = Paint()
        ..color = glowColor.withValues(alpha: 0.12 * intensity * (3 - i) / 3)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, (3 - i) * 2.0);

      canvas.drawRRect(innerRRect, paint);
    }

    final borderPaint = Paint()
      ..color = glowColor.withValues(alpha: 0.25 * intensity)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.0);

    canvas.drawRRect(rrect, borderPaint);
    _drawCornerHighlights(canvas, size);
  }

  void _drawCornerHighlights(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = glowColor.withValues(alpha: 0.3 * intensity)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4.0);

    const radius = 3.0;
    const offset = 16.0;

    final corners = [
      const Offset(offset, offset),
      Offset(size.width - offset, offset),
      Offset(offset, size.height - offset),
      Offset(size.width - offset, size.height - offset),
    ];

    for (final corner in corners) {
      canvas.drawCircle(corner, radius, paint);
    }
  }

  @override
  bool shouldRepaint(_EdgeGlowPainter oldDelegate) {
    return oldDelegate.glowColor != glowColor || oldDelegate.intensity != intensity;
  }
}

class _GlossOverlay extends StatelessWidget {
  final double progress;
  final double intensity;

  const _GlossOverlay({required this.progress, this.intensity = 1.0});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(
        size: Size.infinite,
        painter: _GlossPainter(progress: progress, intensity: intensity),
      ),
    );
  }
}

class _GlossPainter extends CustomPainter {
  final double progress;
  final double intensity;

  _GlossPainter({required this.progress, required this.intensity});

  @override
  void paint(Canvas canvas, Size size) {
    final mainPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Colors.transparent,
          Colors.white.withValues(alpha: 0.06 * intensity),
          Colors.white.withValues(alpha: 0.15 * intensity),
          Colors.white.withValues(alpha: 0.06 * intensity),
          Colors.transparent,
        ],
        stops: const [0.0, 0.35, 0.5, 0.65, 1.0],
      ).createShader(
        Rect.fromLTWH(
          size.width * progress - size.width * 0.5,
          size.height * progress - size.height * 0.5,
          size.width,
          size.height,
        ),
      );

    canvas.drawRect(Offset.zero & size, mainPaint);

    final pearlPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Colors.transparent,
          const Color(0xFFB8E6F5).withValues(alpha: 0.03 * intensity),
          const Color(0xFFFFF5E1).withValues(alpha: 0.05 * intensity),
          const Color(0xFFE6B8F5).withValues(alpha: 0.03 * intensity),
          Colors.transparent,
        ],
        stops: const [0.0, 0.3, 0.5, 0.7, 1.0],
      ).createShader(
        Rect.fromLTWH(
          size.width * progress - size.width * 0.6,
          size.height * progress - size.height * 0.6,
          size.width * 1.2,
          size.height * 1.2,
        ),
      )
      ..blendMode = BlendMode.screen;

    canvas.drawRect(Offset.zero & size, pearlPaint);
  }

  @override
  bool shouldRepaint(_GlossPainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.intensity != intensity;
  }
}

class _SendToHomeMenu extends StatelessWidget {
  final Offset position;
  final VoidCallback? onSendToTxt2Img;
  final VoidCallback? onSendToImg2Img;
  final VoidCallback? onUpscale;

  const _SendToHomeMenu({
    required this.position,
    this.onSendToTxt2Img,
    this.onSendToImg2Img,
    this.onUpscale,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Material(
      type: MaterialType.transparency,
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              onTap: () => Navigator.of(context).pop(),
              behavior: HitTestBehavior.translucent,
              child: Container(color: Colors.transparent),
            ),
          ),
          Positioned(
            left: position.dx,
            top: position.dy,
            child: Container(
              width: 160,
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.2),
                    blurRadius: 16,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildMenuItem(
                    context,
                    icon: Icons.text_fields,
                    label: '文生图',
                    subtitle: '套用参数',
                    onTap: onSendToTxt2Img,
                  ),
                  Divider(height: 1, color: theme.colorScheme.outlineVariant),
                  _buildMenuItem(
                    context,
                    icon: Icons.image,
                    label: '图生图',
                    subtitle: onSendToImg2Img == null ? '不可用' : '载入源图',
                    enabled: onSendToImg2Img != null,
                    onTap: onSendToImg2Img,
                  ),
                  Divider(height: 1, color: theme.colorScheme.outlineVariant),
                  _buildMenuItem(
                    context,
                    icon: Icons.zoom_in,
                    label: '放大',
                    subtitle: '超分放大',
                    onTap: onUpscale,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMenuItem(
    BuildContext context, {
    required IconData icon,
    required String label,
    required String subtitle,
    required VoidCallback? onTap,
    bool enabled = true,
  }) {
    final theme = Theme.of(context);
    final color = enabled ? theme.colorScheme.onSurface : theme.colorScheme.onSurface.withValues(alpha: 0.38);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Icon(
                icon,
                size: 20,
                color: enabled ? theme.colorScheme.primary : theme.colorScheme.onSurface.withValues(alpha: 0.38),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(label, style: theme.textTheme.bodyMedium?.copyWith(color: color, fontWeight: FontWeight.w500)),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: enabled ? theme.colorScheme.onSurfaceVariant : color,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}