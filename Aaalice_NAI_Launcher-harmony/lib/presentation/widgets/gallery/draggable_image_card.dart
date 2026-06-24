import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../../../data/models/gallery/local_image_record.dart';

/// 手机端专属：移除桌面级跨应用拖拽，仅保留纯净 UI 卡片
class DraggableImageCard extends StatelessWidget {
  final LocalImageRecord record;
  final Widget child;
  final bool enabled;
  final Uint8List? previewBytes;
  final bool enableFeedback;
  final double feedbackWidth;
  final String? feedbackHint;
  final double dragOpacity;

  const DraggableImageCard({
    super.key,
    required this.record,
    required this.child,
    this.enabled = true,
    this.previewBytes,
    this.enableFeedback = true,
    this.feedbackWidth = 280,
    this.feedbackHint,
    this.dragOpacity = 0.3,
  });

  static Widget Function(Widget child) createDragWrapper({
    required BuildContext context,
    required LocalImageRecord record,
    Uint8List? previewBytes,
    bool enableFeedback = true,
    double feedbackWidth = 280,
    String? feedbackHint,
    double dragOpacity = 0.3,
  }) {
    return (Widget child) {
      return child; // 手机端直接返回子组件，不需要桌面级拖拽包装
    };
  }

  @override
  Widget build(BuildContext context) {
    return child;
  }
}