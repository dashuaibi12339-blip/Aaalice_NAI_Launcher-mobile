import 'dart:math' as math;
import 'package:flutter/material.dart';

/// 统一的标签颜色系统
/// 整合分类颜色和特殊标签类型颜色
class PromptTagColors {
  PromptTagColors._();

  // ========== 分类颜色 ==========

  /// 艺术家 - 珊瑚粉
  static const Color artist = Color(0xFFFF6B6B);

  /// 角色 - 翠绿
  static const Color character = Color(0xFF4ECDC4);

  /// 版权 - 紫罗兰
  static const Color copyright = Color(0xFFA855F7);

  /// 通用 - 天蓝
  static const Color general = Color(0xFF60A5FA);

  /// 元数据 - 琥珀
  static const Color meta = Color(0xFFFBBF24);

  // ========== 特殊标签类型颜色 ==========

  /// LORA - 橙色
  static const Color lora = Color(0xFFFF9500);

  /// Embedding - 紫色
  static const Color embedding = Color(0xFF9C27B0);

  /// Wildcard - 绿色
  static const Color wildcard = Color(0xFF4CAF50);

  // ========== 权重指示颜色 ==========

  /// 增强权重 - 橙色
  static const Color weightIncrease = Color(0xFFFF9500);

  /// 减弱权重 - 蓝色
  static const Color weightDecrease = Color(0xFF007AFF);

  /// 根据分类获取颜色
  static Color getByCategory(int category) {
    return switch (category) {
      1 => artist,
      3 => copyright,
      4 => character,
      5 => meta,
      _ => general,
    };
  }

  /// 根据标签文本检测特殊类型并返回颜色
  static Color? getSpecialTypeColor(String text) {
    final lowerText = text.toLowerCase();

    // LORA 检测
    if (lowerText.startsWith('<lora:') || lowerText.contains('lora:')) {
      return lora;
    }

    // Embedding 检测
    if (lowerText.startsWith('<embed:') ||
        lowerText.startsWith('embedding:') ||
        lowerText.contains('ti:')) {
      return embedding;
    }

    // Wildcard 检测
    if (lowerText.contains('__') && lowerText.contains('__')) {
      return wildcard;
    }

    return null;
  }

  /// 获取权重颜色
  static Color getWeightColor(double weight) {
    if (weight > 1.0) return weightIncrease;
    if (weight < 1.0) return weightDecrease;
    return Colors.transparent;
  }

  /// 生成背景色（基于主色的低透明度版本）
  static Color getBackgroundColor(
    Color baseColor, {
    bool isSelected = false,
    bool isEnabled = true,
    required ThemeData theme,
  }) {
    if (!isEnabled) {
      return theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.2);
    }
    return baseColor.withValues(alpha: isSelected ? 0.25 : 0.12);
  }

  /// 生成边框色
  static Color getBorderColor(
    Color baseColor, {
    bool isSelected = false,
    bool isHovered = false,
    bool isEnabled = true,
    required ThemeData theme,
  }) {
    if (!isEnabled) {
      return theme.colorScheme.outline.withValues(alpha: 0.15);
    }
    if (isSelected) return baseColor.withValues(alpha: 0.7);
    if (isHovered) return baseColor.withValues(alpha: 0.5);
    return baseColor.withValues(alpha: 0.25);
  }
}

/// 分类渐变色配置
class CategoryGradient {
  CategoryGradient._();

  // ========== 渐变色定义 (WCAG AA 合规) ==========

  static const LinearGradient general = LinearGradient(
    colors: [Color(0xFF60A5FA), Color(0xFF3B82F6)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient character = LinearGradient(
    colors: [Color(0xFFA855F7), Color(0xFF9333EA)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient copyright = LinearGradient(
    colors: [Color(0xFFF472B6), Color(0xFFEC4899)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient meta = LinearGradient(
    colors: [Color(0xFF22D3EE), Color(0xFF06B6D4)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient artist = LinearGradient(
    colors: [Color(0xFFFB923C), Color(0xFFF97316)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static final Map<int, LinearGradient> _gradientCache = {};

  static LinearGradient getGradientByCategory(int category) {
    if (_gradientCache.containsKey(category)) {
      return _gradientCache[category]!;
    }
    final gradient = switch (category) {
      1 => character,
      2 => copyright,
      3 => meta,
      4 => artist,
      _ => general,
    };
    _gradientCache[category] = gradient;
    return gradient;
  }

  static void clearCache() {
    _gradientCache.clear();
  }

  static Color getGradientStartColor(int category) {
    final gradient = getGradientByCategory(category);
    return gradient.colors.first;
  }

  static Color getGradientEndColor(int category) {
    final gradient = getGradientByCategory(category);
    return gradient.colors.last;
  }

  // 🌟 修复 1：恢复被错误替换的函数名，完美解决所有语法报错！
  static LinearGradient getGradientWithOpacity(
    int category, {
    double opacity = 1.0,
  }) {
    final baseGradient = getGradientByCategory(category);
    return LinearGradient(
      colors: baseGradient.colors
          .map((color) => color.withValues(alpha: opacity))
          .toList(),
      begin: baseGradient.begin,
      end: baseGradient.end,
      stops: baseGradient.stops,
    );
  }

  static LinearGradient getThemedGradient(
    int category, {
    required bool isDark,
  }) {
    final baseGradient = getGradientByCategory(category);
    if (isDark) {
      return LinearGradient(
        colors: baseGradient.colors.map((color) {
          final hsl = HSLColor.fromColor(color);
          return hsl.withLightness((hsl.lightness - 0.5).clamp(0.02, 0.98)).toColor();
        }).toList(),
        begin: baseGradient.begin,
        end: baseGradient.end,
        stops: baseGradient.stops,
      );
    }
    return baseGradient;
  }

  // 🌟 修复 2：使用 Flutter 新版的 .r .g .b 取代废弃的 .red，且由于新版直接返回 0-1 的值，去掉了除以 255 的冗余代码
  static Color getContrastColor(int category) {
    final startColor = getGradientStartColor(category);
    final luminance = 0.299 * startColor.r + 0.587 * startColor.g + 0.114 * startColor.b;
    return luminance > 0.5 ? Colors.black : Colors.white;
  }

  static bool meetsWCAGAA(int category, Color textColor) {
    final startColor = getGradientStartColor(category);
    final luminance1 = _calculateLuminance(startColor);
    final luminance2 = _calculateLuminance(textColor);
    final lighter = luminance1 > luminance2 ? luminance1 : luminance2;
    final darker = luminance1 > luminance2 ? luminance2 : luminance1;
    final contrastRatio = (lighter + 0.05) / (darker + 0.05);
    return contrastRatio >= 4.5;
  }

  // 🌟 修复 3：适配新版色值 API
  static double _calculateLuminance(Color color) {
    final r = _channelToLuminance(color.r);
    final g = _channelToLuminance(color.g);
    final b = _channelToLuminance(color.b);
    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
  }

  static double _channelToLuminance(double channel) {
    return channel <= 0.03928
        ? channel / 12.92
        : math.pow((channel + 0.055) / 1.055, 2.4).toDouble();
  }
}

class WeightColorGradient {
  WeightColorGradient._();

  static List<Color> getIncreaseGradient(int bracketLayers) {
    final intensity = (bracketLayers / 10).clamp(0.0, 1.0);
    return [
      PromptTagColors.weightIncrease.withValues(alpha: 0.1 + intensity * 0.2),
      PromptTagColors.weightIncrease.withValues(alpha: 0.05 + intensity * 0.1),
    ];
  }

  static List<Color> getDecreaseGradient(int bracketLayers) {
    final intensity = (bracketLayers.abs() / 10).clamp(0.0, 1.0);
    return [
      PromptTagColors.weightDecrease.withValues(alpha: 0.1 + intensity * 0.2),
      PromptTagColors.weightDecrease.withValues(alpha: 0.05 + intensity * 0.1),
    ];
  }
}