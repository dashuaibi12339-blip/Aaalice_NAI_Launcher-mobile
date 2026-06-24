import 'package:flutter/material.dart';
import 'package:nai_launcher/l10n/app_localizations.dart';

import '../../../../../data/models/gallery/gallery_statistics.dart';
import '../../utils/utils.dart';
import '../cards/metric_card.dart';

/// 概览统计行 - 显示总图片数、总大小、收藏
class OverviewStatsRow extends StatelessWidget {
  final GalleryStatistics stats;

  const OverviewStatsRow({
    super.key,
    required this.stats,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;

    // 【修复】：在手机端，把死板的 Row 改成 Column
    // 这样 3 个卡片会上下排列，每个卡片都能占满屏幕宽度，绝对不会再挤爆！
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MetricCard(
          icon: Icons.photo_library_outlined,
          label: l10n.statistics_totalImages,
          value: '${stats.totalImages}',
          iconColor: theme.colorScheme.primary,
          compact: true,
        ),
        const SizedBox(height: 12),
        MetricCard(
          icon: Icons.storage_outlined,
          label: l10n.statistics_totalSize,
          value: StatisticsFormatter.formatBytes(stats.totalSizeBytes),
          iconColor: theme.colorScheme.secondary,
          compact: true,
        ),
        const SizedBox(height: 12),
        MetricCard(
          icon: Icons.favorite_outline,
          label: l10n.statistics_favorites,
          value: '${stats.favoriteCount} (${stats.favoritePercentage.toStringAsFixed(1)}%)',
          iconColor: Colors.red,
          compact: true,
        ),
      ],
    );
  }
}