import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../../../core/utils/app_logger.dart';
import '../../../../themes/design_tokens.dart';
import '../../../../widgets/common/image_picker_card/_internal/picker_handler.dart';

/// 手机端专属：移除桌面拖拽，仅保留点击按钮更换预览图和缩放功能
class VibePreviewDropZone extends StatefulWidget {
  final Uint8List? imageBytes;
  final ValueChanged<Uint8List>? onThumbnailChanged;
  final VoidCallback? onClose;

  const VibePreviewDropZone({
    super.key,
    this.imageBytes,
    this.onThumbnailChanged,
    this.onClose,
  });

  @override
  State<VibePreviewDropZone> createState() => _VibePreviewDropZoneState();
}

class _VibePreviewDropZoneState extends State<VibePreviewDropZone> {
  final TransformationController _transformationController = TransformationController();

  @override
  void dispose() {
    _transformationController.dispose();
    super.dispose();
  }

  void _resetZoom() {
    _transformationController.value = Matrix4.identity();
  }

  void _zoomIn() {
    final currentScale = _transformationController.value.getMaxScaleOnAxis();
    final newScale = (currentScale * 1.2).clamp(0.5, 4.0);
    _applyScale(newScale);
  }

  void _zoomOut() {
    final currentScale = _transformationController.value.getMaxScaleOnAxis();
    final newScale = (currentScale / 1.2).clamp(0.5, 4.0);
    _applyScale(newScale);
  }

  void _applyScale(double scale) {
    final size = context.size;
    if (size == null) return;
    final centerX = size.width / 2;
    final centerY = size.height / 2;

    final matrix = Matrix4.identity()
      ..translate(centerX - centerX * scale, centerY - centerY * scale)
      ..scale(scale);

    _transformationController.value = matrix;
  }

  Future<void> _pickImage() async {
    final result = await PickerHandler.pickImage(
      onError: (msg) => AppLogger.w(msg, 'VibePreviewDropZone'),
    );
    if (result == null) return;

    final resized = await _resizeImage(result.bytes);
    widget.onThumbnailChanged?.call(resized);
  }

  static Future<Uint8List> _resizeImage(Uint8List bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final image = frame.image;

      final srcW = image.width;
      final srcH = image.height;

      if (srcW <= 512 && srcH <= 512) {
        image.dispose();
        return bytes;
      }

      final scale = 512.0 / (srcW > srcH ? srcW : srcH);
      final dstW = (srcW * scale).round();
      final dstH = (srcH * scale).round();

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(
        recorder,
        Rect.fromLTWH(0, 0, dstW.toDouble(), dstH.toDouble()),
      );
      canvas.drawImageRect(
        image,
        Rect.fromLTWH(0, 0, srcW.toDouble(), srcH.toDouble()),
        Rect.fromLTWH(0, 0, dstW.toDouble(), dstH.toDouble()),
        Paint()..filterQuality = FilterQuality.medium,
      );

      final picture = recorder.endRecording();
      final resized = await picture.toImage(dstW, dstH);
      final byteData = await resized.toByteData(format: ui.ImageByteFormat.png);

      image.dispose();
      resized.dispose();
      picture.dispose();

      return byteData?.buffer.asUint8List() ?? bytes;
    } catch (e) {
      AppLogger.w('Failed to resize image: $e', 'VibePreviewDropZone');
      return bytes;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        GestureDetector(
          onDoubleTap: _resetZoom,
          child: InteractiveViewer(
            transformationController: _transformationController,
            minScale: 0.5,
            maxScale: 4.0,
            child: Center(
              child: widget.imageBytes != null
                  ? Image.memory(
                      widget.imageBytes!,
                      fit: BoxFit.contain,
                      errorBuilder: (_, __, ___) => _buildPlaceholder(),
                    )
                  : _buildPlaceholder(),
            ),
          ),
        ),
        Positioned(
          top: DesignTokens.spacingMd,
          left: DesignTokens.spacingMd,
          child: _buildCircularCloseButton(
            onPressed: widget.onClose ?? () => Navigator.of(context).pop(),
          ),
        ),
        Positioned(
          bottom: DesignTokens.spacingMd,
          right: DesignTokens.spacingMd,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildIconButton(icon: Icons.add, onPressed: _zoomIn, tooltip: '放大'),
              const SizedBox(height: DesignTokens.spacingXs),
              _buildIconButton(icon: Icons.remove, onPressed: _zoomOut, tooltip: '缩小'),
              const SizedBox(height: DesignTokens.spacingXs),
              _buildIconButton(icon: Icons.fit_screen, onPressed: _resetZoom, tooltip: '重置缩放'),
              const SizedBox(height: DesignTokens.spacingMd),
              if (widget.onThumbnailChanged != null)
                _buildIconButton(icon: Icons.image_outlined, onPressed: _pickImage, tooltip: '更换预览图'),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPlaceholder() {
    return const Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.auto_awesome, size: 64, color: Colors.white54),
        SizedBox(height: DesignTokens.spacingMd),
        Text('无预览图像', style: TextStyle(color: Colors.white54, fontSize: 16)),
        SizedBox(height: DesignTokens.spacingXs),
        Text('点击右下角按钮设置预览图', style: TextStyle(color: Colors.white38, fontSize: 13)),
      ],
    );
  }

  Widget _buildIconButton({required IconData icon, required VoidCallback onPressed, required String tooltip}) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.black.withValues(alpha: 0.5),
        borderRadius: DesignTokens.borderRadiusLg,
        child: InkWell(
          onTap: onPressed,
          borderRadius: DesignTokens.borderRadiusLg,
          child: Padding(padding: const EdgeInsets.all(10), child: Icon(icon, color: Colors.white, size: 20)),
        ),
      ),
    );
  }

  Widget _buildCircularCloseButton({required VoidCallback onPressed}) {
    return Tooltip(
      message: '关闭 (Esc)',
      child: Material(
        color: Colors.black.withValues(alpha: 0.5),
        shape: const CircleBorder(),
        child: InkWell(
          onTap: onPressed,
          customBorder: const CircleBorder(),
          child: const Padding(padding: EdgeInsets.all(12), child: Icon(Icons.close, color: Colors.white, size: 24)),
        ),
      ),
    );
  }
}