import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nai_launcher/presentation/router/app_router.dart';
import '../../providers/layout_state_provider.dart';
import '../../widgets/queue/floating_queue_button.dart';
import 'widgets/fixed_tags_sidebar.dart';

import '../../widgets/drop/global_drop_handler.dart';
import '../../providers/replication_queue_provider.dart';
import '../../widgets/queue/queue_management_page.dart';
import 'desktop_layout.dart';
import 'mobile_layout.dart';

/// 图像生成页面
class GenerationScreen extends ConsumerWidget {
  const GenerationScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 监听状态
    final queueState = ref.watch(replicationQueueNotifierProvider);
    final isFabClosed = ref.watch(floatingButtonClosedProvider);
    
    final hasPendingTasks = queueState.tasks.isNotEmpty;
    final hasAnyTasks = hasPendingTasks || queueState.completedTasks.isNotEmpty || queueState.failedTasks.isNotEmpty;
    final showFab = hasPendingTasks || (hasAnyTasks && !isFabClosed);

    return GlobalDropHandler(
      child: Stack(
        children: [
          // 底层：原封不动的页面布局
          Positioned.fill(
            child: LayoutBuilder(
              builder: (context, constraints) {
                // 桌面端布局
                if (constraints.maxWidth >= 1000) {
                  return const DesktopGenerationLayout();
                }

                // 手机/平板布局 + 固定标签栏支持
                final layoutState = ref.watch(layoutStateNotifierProvider);
                const mobileLayout = MobileGenerationLayout();
                
                if (!layoutState.fixedTagsSidebarExpanded) {
                  return mobileLayout;
                }

                final maxSidebarWidth = (constraints.maxWidth * 0.45).clamp(240.0, 400.0);
                final sidebarWidth = layoutState.fixedTagsSidebarWidth
                    .clamp(240.0, maxSidebarWidth)
                    .toDouble();

                return Row(
                  children: [
                    const Expanded(child: mobileLayout),
                    Container(
                      width: sidebarWidth,
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surface,
                        border: Border(
                          left: BorderSide(color: Theme.of(context).dividerColor),
                        ),
                      ),
                      child: const FixedTagsSidebar(),
                    ),
                  ],
                );
              },
            ),
          ),
          
          // 顶层：直接接入 PC 同款的顶级可拖拽悬浮球！
          // FloatingQueueButton 内部自带了 Positioned，所以它能在全屏范围内自由飞翔
          if (MediaQuery.of(context).size.width < 1000 && showFab)
            FloatingQueueButton(
              onTap: () {
                // 手机端专属体验：点击后从底部平滑升起管理面板
                showModalBottomSheet(
                  context: context,
                  isScrollControlled: true,
                  useSafeArea: true, 
                  backgroundColor: Theme.of(context).colorScheme.surface, 
                  shape: const RoundedRectangleBorder(
                    borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
                  ),
                  builder: (context) => const QueueManagementPage(),
                );
              },
            ),
        ],
      ),
    );
  }
}