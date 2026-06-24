import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nai_launcher/data/models/character/character_prompt.dart';
import '../../providers/character_prompt_provider.dart';
import '../../../core/utils/nai_prompt_formatter.dart';
import '../../../core/utils/sd_to_nai_converter.dart';
// 如果下面这行标红，可以尝试换成 import '../../widgets/prompt/unified/unified_prompt_config.dart';
import '../../widgets/prompt/unified/unified_prompt_input.dart';
import '../../../core/utils/comfyui_prompt_parser/pipe_parser.dart';
import '../../providers/random_preset_provider.dart';
import '../../providers/tag_group_sync_provider.dart';
import '../../providers/krita/krita_bridge_notifier.dart';
import '../../../core/utils/localization_extension.dart';
import '../../../data/models/image/image_params.dart';
import '../../../data/models/queue/replication_task.dart';
import '../../providers/replication_queue_provider.dart';
import '../../providers/image_generation_provider.dart';
import '../../providers/prompt_maximize_provider.dart';
import '../../widgets/anlas/anlas_balance_chip.dart';
import '../../widgets/common/themed_divider.dart';
import '../../widgets/common/themed_scaffold.dart';
import '../../widgets/common/themed_button.dart';
import 'widgets/prompt_input.dart';
import 'widgets/image_preview.dart';
import '../../widgets/common/anlas_cost_badge.dart';
// 👇 新增：引入批量设置按钮（如果你的路径不同，请调整这里的路径）
import 'widgets/generation_controls/batch_settings_button.dart';
import 'widgets/parameter_panel.dart';
import 'widgets/history_panel.dart'; // 引入历史面板

import '../../widgets/common/app_toast.dart';
import '../../utils/asset_protection_guard.dart';

/// 移动端单栏布局
class MobileGenerationLayout extends ConsumerStatefulWidget {
  const MobileGenerationLayout({super.key});

  @override
  ConsumerState<MobileGenerationLayout> createState() =>
      _MobileGenerationLayoutState();
}

class _MobileGenerationLayoutState
    extends ConsumerState<MobileGenerationLayout> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  @override
  Widget build(BuildContext context) {
    // 🌟 核心修复：App 启动时全局提前唤醒预设状态和同步状态！
    ref.watch(randomPresetNotifierProvider);
    ref.watch(tagGroupSyncNotifierProvider);

    final generationState = ref.watch(imageGenerationNotifierProvider);
    final params = ref.watch(generationParamsNotifierProvider);
    final kritaBridgeState = ref.watch(kritaBridgeNotifierProvider);
    final isPromptMaximized = ref.watch(promptMaximizeNotifierProvider);
    final theme = Theme.of(context);
    final isLauncherGenerating = generationState.isGenerating;
    final isGenerating = isLauncherGenerating || kritaBridgeState.isBridgeGenerating;

    return ThemedScaffold(
      // 移除了失效的 _scaffoldKey
      appBar: AppBar(
        title: Text(context.l10n.generation_title),
        actions: [
          // 【新增】：清空按钮挪到这里
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: '清空提示词',
            onPressed: () {
              ref.read(generationParamsNotifierProvider.notifier).updatePrompt('');
              ref.read(characterPromptNotifierProvider.notifier).clearAllCharacters();
            },
          ),
          // 【新增】：全屏切换按钮挪到这里，且支持图标状态切换
          IconButton(
            icon: Icon(isPromptMaximized ? Icons.fullscreen_exit : Icons.fullscreen),
            tooltip: context.l10n.tooltip_fullscreenEdit,
            onPressed: () {
              ref.read(promptMaximizeNotifierProvider.notifier).toggle();
            },
          ),
          // 原本的参数设置按钮
          Builder(
            builder: (context) => IconButton(
              icon: const Icon(Icons.tune),
              onPressed: () {
                Scaffold.of(context).openEndDrawer();
              },
              tooltip: context.l10n.generation_paramsSettings,
            ),
          ),
        ],
      ),

      // 左侧抽屉（历史记录）- 移除多余头部，直接裸用 HistoryPanel
      drawer: Drawer(
        width: MediaQuery.of(context).size.width * 0.85,
        child: const SafeArea(
          child: HistoryPanel(),
        ),
      ),
      // 右侧抽屉（参数设置）
      endDrawer: Drawer(
        width: MediaQuery.of(context).size.width * 0.85,
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      context.l10n.generation_paramsSettings,
                      style: theme.textTheme.titleLarge,
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),
              const ThemedDivider(),
              const Expanded(
                child: ParameterPanel(),
              ),
            ],
          ),
        ),
      ),
      // 🚀 核心修复：使用无感观察器替代 GestureDetector
      // 既保留了全局滑动拉出抽屉的功能（避开全面屏返回手势冲突），又彻底消除了输入和滚动的卡顿！
      body: Builder(
        builder: (context) => _GlobalSwipeObserver(
          onSwipeRight: () => Scaffold.of(context).openDrawer(),
          onSwipeLeft: () => Scaffold.of(context).openEndDrawer(),
          child: Column(
            children: [
              // Prompt 输入区
              if (isPromptMaximized)
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    child: PromptInputWidget(
                      isMaximized: isPromptMaximized,
                    ),
                  ),
                )
              else
                Flexible(
                  flex: 1,
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    child: const PromptInputWidget(compact: true),
                  ),
                ),

              // 图像预览区
              if (!isPromptMaximized)
                const Expanded(
                  flex: 2,
                  child: ImagePreviewWidget(),
                ),

              // 生成状态和进度
              if (!isPromptMaximized && generationState.isGenerating)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Column(
                    children: [
                      LinearProgressIndicator(
                        value: generationState.progress,
                        backgroundColor: theme.colorScheme.surfaceContainerHighest,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        context.l10n.generation_progress(
                          (generationState.progress * 100).toInt().toString(),
                        ),
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
            
      // 底部生成按钮
      bottomNavigationBar: SafeArea(
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            border: Border(
              top: BorderSide(
                color: theme.dividerColor,
                width: 1,
              ),
            ),
          ),
          child: Row(
            children: [
              const AnlasBalanceChip(compact: true),
              const SizedBox(width: 8),
              _MobileRandomModeToggle(
                enabled: ref.watch(randomPromptModeProvider),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _MobileGenerateButton(
                  isGenerating: isGenerating,
                  showCancel: isLauncherGenerating,
                  onGenerate: () => _handleGenerate(context, ref, params),
                  onCancel: () => ref
                      .read(imageGenerationNotifierProvider.notifier)
                      .cancel(),
                  // 👇 ====== 绑定长按事件 ====== 👇
                  onLongPress: () => _showBatchSettingsDialog(context, ref), 
                ),
              ),            
            ],         
          ),
        ),
      ),
    );
  }
  
  // 👇 融合了「每次图像数」和「重复请求次数」的终极弹窗
  void _showBatchSettingsDialog(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final l10n = context.l10n;

    showDialog(
      context: context,
      builder: (ctx) {
        // 使用 Consumer 包裹，确保弹窗内部的数据能实时响应变化
        return Consumer(
          builder: (context, ref, child) {
            final currentBatchSize = ref.watch(imagesPerRequestProvider);
            final params = ref.watch(generationParamsNotifierProvider);
            final batchCount = params.nSamples;
            final totalImages = batchCount * currentBatchSize;

            return AlertDialog(
              title: Row(
                children: [
                  Icon(Icons.burst_mode, color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  const Text('批量与次数设置'), 
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // --- 第一部分：每次请求图像数 ---
                  Text(
                    '每次请求图像数 (Batch Size)',
                    style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      for (int i = 1; i <= 4; i++)
                        GestureDetector(
                          onTap: () => ref.read(imagesPerRequestProvider.notifier).set(i),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              color: i == currentBatchSize
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: i == currentBatchSize
                                    ? theme.colorScheme.primary
                                    : theme.colorScheme.outline.withValues(alpha: 0.3),
                                width: 2,
                              ),
                            ),
                            child: Center(
                              child: Text(
                                '$i',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: i == currentBatchSize
                                      ? theme.colorScheme.onPrimary
                                      : theme.colorScheme.onSurface,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  
                  const SizedBox(height: 16),
                  const ThemedDivider(),
                  const SizedBox(height: 16),

                  // --- 第二部分：生成批次 / 自动请求次数 ---
                  Text(
                    '自动重复请求次数 (多次生成)',
                    style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        onPressed: batchCount > 1 
                          // 💡【注意】：如果这里报错找不到 updateNSamples，请把它改成你代码中实际更新次数的方法！
                          // 比如可能是 ref.read(generationParamsNotifierProvider.notifier).setNSamples(batchCount - 1)
                          ? () => ref.read(generationParamsNotifierProvider.notifier).updateNSamples(batchCount - 1) 
                          : null,
                        icon: const Icon(Icons.remove_circle_outline),
                        color: theme.colorScheme.primary,
                        iconSize: 28,
                      ),
                      Container(
                        width: 60,
                        alignment: Alignment.center,
                        child: Text(
                          '$batchCount',
                          style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
                        ),
                      ),
                      IconButton(
                        onPressed: batchCount < 50 
                          ? () => ref.read(generationParamsNotifierProvider.notifier).updateNSamples(batchCount + 1) 
                          : null,
                        icon: const Icon(Icons.add_circle_outline),
                        color: theme.colorScheme.primary,
                        iconSize: 28,
                      ),
                    ],
                  ),

                  const SizedBox(height: 20),
                  
                  // --- 第三部分：公式与警告 ---
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      l10n.batchSize_formula(batchCount, currentBatchSize, totalImages),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),

                  const SizedBox(height: 12),
                  if (currentBatchSize > 1 || batchCount > 1) 
                    Text(
                      l10n.batchSize_costWarning,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                ],
              ),
              actions: [
                // 👇 新增：加入队列功能按钮
                FilledButton.tonalIcon(
                  icon: const Icon(Icons.queue_rounded, size: 18),
                  label: const Text('加入队列'),
                  onPressed: () {
                    // 获取当前输入框里的参数
                    final currentParams = ref.read(generationParamsNotifierProvider);
                    if (currentParams.prompt.trim().isEmpty) {
                      AppToast.info(context, l10n.generation_pleaseInputPrompt);
                      return;
                    }
                    
                    // 创建队列任务并发送
                    final task = ReplicationTask.create(prompt: currentParams.prompt);
                    ref.read(replicationQueueNotifierProvider.notifier).add(task);
                    
                    AppToast.success(context, l10n.queue_taskAdded);
                    Navigator.pop(ctx); // 关闭弹窗
                  },
                ),
                // 原来的关闭按钮
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(l10n.common_close),
                ),
              ],
            );
          },  
        );
      },
    );
  }

  Future<void> _handleGenerate(
    BuildContext context,
    WidgetRef ref,
    ImageParams params,
  ) async {
    if (ref.read(kritaBridgeNotifierProvider).isBridgeGenerating) {
      AppToast.warning(context, context.l10n.toast_kritaBusy);
      return;
    }
    if (params.prompt.isEmpty) {
      AppToast.info(context, context.l10n.generation_pleaseInputPrompt);
      return;
    }

    // 1. 收起键盘。如果当前有焦点，这会触发 prompt_input 里的静默拆分
    FocusScope.of(context).unfocus();

    // 2. 【核心防卡死】：等待 50 毫秒，让可能触发的静默拆分彻底干完活
    await Future.delayed(const Duration(milliseconds: 50));

    // 3. 重新获取最新参数
    // 如果刚才触发了静默拆分，这里拿到的就是纯净的基础词；如果没触发（无焦点），拿到的还是原始长词
    params = ref.read(generationParamsNotifierProvider);

    String optimizedPrompt = params.prompt;
    String optimizedNegative = params.negativePrompt;
    bool isChanged = false;

    try {
      final enableSdConvert = ref.read(sdSyntaxAutoConvertSettingsProvider);
      final enableAutoFormat = ref.read(autoFormatPromptSettingsProvider);
      final enableMultiCharParse = ref.read(multiCharParseSettingsProvider);

      // 4. 【新增：兜底拆分】
      // 如果文本里还有 | 或 Character，说明静默拆分没触发（比如退出全屏后没点输入框），在这里补刀！
      if (enableMultiCharParse) {
        if (PipeParser.isPipeFormat(optimizedPrompt)) {
          final parsedResult = PipeParser.parse(optimizedPrompt);
          if (parsedResult.characters.isNotEmpty) {
            optimizedPrompt = parsedResult.globalPrompt;
            isChanged = true;

            final charNotifier = ref.read(characterPromptNotifierProvider.notifier);
            charNotifier.clearAllCharacters();

            String optimizeText(String t) {
              String res = t;
              if (enableSdConvert) res = SdToNaiConverter.convert(res);
              if (enableAutoFormat) res = NaiPromptFormatter.format(res);
              return res;
            }

            for (var charData in parsedResult.characters) {
              // 将 ParsedPosition 转换为底层的 CharacterPosition
              CharacterPosition? pos;
              if (charData.position != null) {
                pos = CharacterPosition(
                  mode: CharacterPositionMode.custom,
                  column: charData.position!.x,
                  row: charData.position!.y,
                );
              }

              charNotifier.addCharacter(
                charData.inferredGender ?? CharacterGender.other,
                prompt: optimizeText(charData.prompt),
                negativePrompt: charData.negativePrompt != null 
                    ? optimizeText(charData.negativePrompt!) 
                    : null,
                customPosition: pos,
              );
            }
            AppToast.success(context, '已自动拆分 ${parsedResult.characters.length} 个角色');
          }
        }
      }
      
      // 5. 基础格式化（对主提示词）
      if (enableSdConvert) {
        final newPrompt = SdToNaiConverter.convert(optimizedPrompt);
        if (newPrompt != optimizedPrompt) {
          optimizedPrompt = newPrompt;
          isChanged = true;
        }
        final newNeg = SdToNaiConverter.convert(optimizedNegative);
        if (newNeg != optimizedNegative) {
          optimizedNegative = newNeg;
          isChanged = true;
        }
      }

      if (enableAutoFormat) {
        final newPrompt = NaiPromptFormatter.format(optimizedPrompt);
        if (newPrompt != optimizedPrompt) {
          optimizedPrompt = newPrompt;
          isChanged = true;
        }
        final newNeg = NaiPromptFormatter.format(optimizedNegative);
        if (newNeg != optimizedNegative) {
          optimizedNegative = newNeg;
          isChanged = true;
        }
      }
    } catch (e) {
      debugPrint('读取提示词优化设置失败: $e');
    }

    // 6. 同步更新
    if (isChanged) {
      ref.read(generationParamsNotifierProvider.notifier).updatePrompt(optimizedPrompt);
      ref.read(generationParamsNotifierProvider.notifier).updateNegativePrompt(optimizedNegative);
      params = ref.read(generationParamsNotifierProvider);
    }

    // 7. 高额点数消耗确认保护
    final confirmed = await AssetProtectionGuard.confirmHighAnlasCost(
      context: context,
      ref: ref,
    );
    if (!confirmed || !context.mounted) {
      return;
    }

    // 8. 触发生成
    ref.read(imageGenerationNotifierProvider.notifier).generate(params);
  }
}

class _MobileRandomModeToggle extends ConsumerWidget {
  final bool enabled;

  const _MobileRandomModeToggle({required this.enabled});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    return Tooltip(
      message: enabled
          ? context.l10n.randomMode_enabledTip
          : context.l10n.randomMode_disabledTip,
      child: GestureDetector(
        onTap: () {
          ref.read(randomPromptModeProvider.notifier).toggle();
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: enabled
                ? theme.colorScheme.primary.withValues(alpha: 0.15)
                : theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: enabled
                  ? theme.colorScheme.primary.withValues(alpha: 0.5)
                  : theme.colorScheme.outline.withValues(alpha: 0.3),
              width: enabled ? 1.5 : 1,
            ),
          ),
          child: Icon(
            Icons.casino_outlined,
            size: 20,
            color: enabled
                ? theme.colorScheme.primary
                : theme.colorScheme.onSurface.withValues(alpha: 0.5),
          ),
        ),
      ),
    );
  }
}

class _MobileGenerateButton extends ConsumerWidget {
  final bool isGenerating;
  final bool showCancel;
  final VoidCallback onGenerate;
  final VoidCallback onCancel;
  final VoidCallback? onLongPress;

  const _MobileGenerateButton({
    required this.isGenerating,
    required this.showCancel,
    required this.onGenerate,
    required this.onCancel,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final batchSize = ref.watch(imagesPerRequestProvider);
    final batchCount = ref.watch(generationParamsNotifierProvider).nSamples;

    return GestureDetector(
      onLongPress: onLongPress,
      child: ThemedButton(
        onPressed: showCancel ? onCancel : onGenerate,
        icon: showCancel
            ? const Icon(Icons.stop)
            : (isGenerating ? null : const Icon(Icons.auto_awesome)),
        isLoading: isGenerating && !showCancel,
        label: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                isGenerating
                    ? context.l10n.generation_cancelGeneration
                    : context.l10n.generation_generate,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 4),
            AnlasCostBadge(isGenerating: isGenerating),
            
            // 👇 贴心微缩提示：如果设置了批量或重复，精简显示 ×数量 和 ↻次数
            if (!isGenerating && (batchSize > 1 || batchCount > 1)) ...[
              const SizedBox(width: 6),
              Text(
                '${batchSize > 1 ? '×$batchSize ' : ''}${batchCount > 1 ? '↻$batchCount' : ''}'.trim(),
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.onPrimary.withValues(alpha: 0.9),
                ),
              ),
            ],
          ],
        ),
        style: showCancel ? ThemedButtonStyle.outlined : ThemedButtonStyle.filled,
      ),
    );
  }
}

/// 无感全局滑动观察器（彻底替代会导致卡顿的 GestureDetector）
class _GlobalSwipeObserver extends StatefulWidget {
  final Widget child;
  final VoidCallback onSwipeLeft;
  final VoidCallback onSwipeRight;

  const _GlobalSwipeObserver({
    required this.child,
    required this.onSwipeLeft,
    required this.onSwipeRight,
  });

  @override
  State<_GlobalSwipeObserver> createState() => _GlobalSwipeObserverState();
}

class _GlobalSwipeObserverState extends State<_GlobalSwipeObserver> {
  double _startX = 0.0;
  double _startY = 0.0;
  int _startTime = 0;

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (event) {
        _startX = event.position.dx;
        _startY = event.position.dy;
        _startTime = DateTime.now().millisecondsSinceEpoch;
      },
      onPointerUp: (event) {
        final dx = event.position.dx - _startX;
        final dy = event.position.dy - _startY;
        final dt = DateTime.now().millisecondsSinceEpoch - _startTime;

        // 核心算法：滑动时间<400ms(快速甩动)，横向滑动>50像素，且横向位移是纵向的2倍以上(防止上下滑误触)
        if (dt < 400 && dx.abs() > 50 && dx.abs() > dy.abs() * 2) {
          if (dx > 0) {
            widget.onSwipeRight(); // 向右滑动 -> 打开左侧历史记录
          } else {
            widget.onSwipeLeft();  // 向左滑动 -> 打开右侧参数设置
          }
        }
      },
      child: widget.child,
    );
  }
}