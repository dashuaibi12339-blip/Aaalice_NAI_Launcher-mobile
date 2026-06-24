import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '_internal/loading_overlay.dart';
import '_internal/picker_handler.dart';
import '_internal/preview_thumbnail.dart';
import 'image_picker_result.dart';
import 'image_picker_type.dart';

export 'image_picker_result.dart';
export 'image_picker_type.dart';

/// 手机端专属：移除桌面拖拽上传，保留点击选择文件功能
class ImagePickerCard extends StatefulWidget {
  final String label;
  final IconData icon;
  final String? hintText;
  final bool isRequired;
  final bool allowMultiple;
  final ImagePickerType type;
  final List<String>? allowedExtensions;
  final double? width;
  final double height;
  final bool enableGlowEffect;
  final bool enableDragDrop; // 手机端此参数会被忽略
  final Uint8List? selectedImage;
  final String? selectedPath;
  final void Function(Uint8List bytes, String fileName, String? path)? onImageSelected;
  final void Function(List<ImagePickerResult> files)? onMultipleSelected;
  final void Function(String path)? onDirectorySelected;
  final void Function(String error)? onError;
  final VoidCallback? onClear;
  final VoidCallback? onTap;

  const ImagePickerCard({
    super.key,
    required this.label,
    required this.icon,
    this.hintText,
    this.isRequired = false,
    this.allowMultiple = false,
    this.type = ImagePickerType.image,
    this.allowedExtensions,
    this.width,
    this.height = 100,
    this.enableGlowEffect = true,
    this.enableDragDrop = true,
    this.selectedImage,
    this.selectedPath,
    this.onImageSelected,
    this.onMultipleSelected,
    this.onDirectorySelected,
    this.onError,
    this.onClear,
    this.onTap,
  });

  @override
  State<ImagePickerCard> createState() => _ImagePickerCardState();
}

class _ImagePickerCardState extends State<ImagePickerCard> {
  bool _isHovered = false;
  bool _isLoading = false;

  bool get _hasSelection => widget.selectedImage != null || widget.selectedPath != null;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: _isLoading ? SystemMouseCursors.wait : SystemMouseCursors.click,
      child: GestureDetector(
        onTap: _isLoading ? null : _handleTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            border: Border.all(
              color: _getBorderColor(theme),
              width: _isHovered ? 1.5 : 1.0,
            ),
            borderRadius: BorderRadius.circular(12),
            color: _getBackgroundColor(theme),
            boxShadow: _buildBoxShadow(theme),
          ),
          child: Stack(
            children: [
              _buildContent(theme),
              if (_isLoading) const LoadingOverlay(),
              if (_hasSelection && _isHovered && widget.onClear != null) _buildClearButton(theme),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildContent(ThemeData theme) {
    if (_hasSelection) {
      return _buildSelectedContent(theme);
    }
    return _buildDefaultContent(theme);
  }

  Widget _buildDefaultContent(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            widget.icon,
            size: 28,
            color: _isHovered ? theme.colorScheme.primary : theme.colorScheme.onSurface.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 8),
          Text(
            widget.label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: _isHovered ? theme.colorScheme.primary : theme.colorScheme.onSurface.withValues(alpha: 0.6),
            ),
            textAlign: TextAlign.center,
          ),
          if (widget.hintText != null) ...[
            const SizedBox(height: 2),
            Text(
              widget.hintText!,
              style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: 0.4)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSelectedContent(ThemeData theme) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final thumbnailSize = widget.height - 16;
        final showTextInfo = constraints.maxWidth > thumbnailSize + 80;

        if (!showTextInfo) {
          return Center(
            child: PreviewThumbnail(
              imageBytes: widget.selectedImage,
              imagePath: widget.selectedPath,
              fallbackIcon: widget.icon,
              size: constraints.maxWidth.clamp(40, thumbnailSize),
              borderRadius: 8,
            ),
          );
        }

        return Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              PreviewThumbnail(
                imageBytes: widget.selectedImage,
                imagePath: widget.selectedPath,
                fallbackIcon: widget.icon,
                size: thumbnailSize,
                borderRadius: 8,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.label,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (widget.selectedPath != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        _getDisplayPath(widget.selectedPath!),
                        style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildClearButton(ThemeData theme) {
    return Positioned(
      top: 4,
      right: 4,
      child: Material(
        color: theme.colorScheme.surface.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: widget.onClear,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Icon(Icons.close, size: 14, color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      ),
    );
  }

  Future<void> _handleTap() async {
    if (widget.onTap != null) {
      HapticFeedback.selectionClick();
      widget.onTap!();
      return;
    }
    setState(() => _isLoading = true);
    HapticFeedback.selectionClick();
    await Future.delayed(const Duration(milliseconds: 16));

    try {
      switch (widget.type) {
        case ImagePickerType.image:
          await _pickImage();
          break;
        case ImagePickerType.file:
          await _pickFile();
          break;
        case ImagePickerType.directory:
          await _pickDirectory();
          break;
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _pickImage() async {
    if (widget.allowMultiple) {
      final results = await PickerHandler.pickMultipleImages(onError: widget.onError);
      if (results.isNotEmpty) widget.onMultipleSelected?.call(results);
    } else {
      final result = await PickerHandler.pickImage(onError: widget.onError);
      if (result != null) widget.onImageSelected?.call(result.bytes, result.fileName, result.path);
    }
  }

  Future<void> _pickFile() async {
    final extensions = widget.allowedExtensions ?? ['*'];
    final result = await PickerHandler.pickFile(extensions: extensions, allowMultiple: widget.allowMultiple, onError: widget.onError);
    if (result != null) widget.onImageSelected?.call(result.bytes, result.fileName, result.path);
  }

  Future<void> _pickDirectory() async {
    final path = await PickerHandler.pickDirectory(onError: widget.onError);
    if (path != null) widget.onDirectorySelected?.call(path);
  }

  Color _getBorderColor(ThemeData theme) {
    if (_hasSelection) return _isHovered ? theme.colorScheme.primary : theme.colorScheme.primary.withValues(alpha: 0.6);
    return _isHovered ? theme.colorScheme.primary : theme.colorScheme.outline.withValues(alpha: 0.5);
  }

  Color _getBackgroundColor(ThemeData theme) {
    if (_hasSelection) return _isHovered ? theme.colorScheme.primary.withValues(alpha: 0.08) : theme.colorScheme.primary.withValues(alpha: 0.04);
    return _isHovered ? theme.colorScheme.primary.withValues(alpha: 0.05) : Colors.transparent;
  }

  List<BoxShadow>? _buildBoxShadow(ThemeData theme) {
    if (!widget.enableGlowEffect || !_isHovered) return null;
    return [BoxShadow(color: theme.colorScheme.primary.withValues(alpha: 0.15), blurRadius: 20, spreadRadius: 0)];
  }

  String _getDisplayPath(String path) {
    final parts = path.split(Platform.pathSeparator);
    return parts.isNotEmpty ? parts.last : path;
  }
}