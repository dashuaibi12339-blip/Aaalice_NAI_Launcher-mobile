import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../providers/generation/generation_settings_notifiers.dart';


import '../../../../core/utils/localization_extension.dart';
import '../../../../core/constants/api_constants.dart';
import '../../../../core/utils/comfyui_prompt_parser/pipe_parser.dart';
import '../../../../core/utils/nai_prompt_formatter.dart';
import '../../../../core/utils/sd_to_nai_converter.dart';
import '../../../../data/models/character/character_prompt.dart';
import '../../../../data/models/fixed_tag/fixed_tag_entry.dart';
import '../../../../data/models/prompt/prompt_preset_mode.dart';
import '../../../../data/services/alias_resolver_service.dart';
import '../../../providers/character_prompt_provider.dart';
import '../../../providers/fixed_tags_provider.dart';
import '../../../providers/image_generation_provider.dart';
import '../../../providers/prompt_maximize_provider.dart';
import '../../../providers/prompt_token_counter_provider.dart'; // 👈 [新功能] Token计数
import '../../../providers/quality_preset_provider.dart';
import '../../../providers/queue_execution_provider.dart';
import '../../../providers/uc_preset_provider.dart';
import '../../../widgets/autocomplete/autocomplete.dart';
import '../../../widgets/common/app_toast.dart';
import '../../../widgets/prompt/unified/unified_prompt_input.dart';
import '../../../widgets/prompt/unified/unified_prompt_config.dart';
import '../../../widgets/prompt/nai_syntax_controller.dart';
import '../../../widgets/prompt/prompt_token_count_bar.dart'; // 👈 [新功能] Token计数UI
import '../../../widgets/prompt/quality_tags_selector.dart';
import '../../../widgets/prompt/random_mode_selector.dart';
import '../../../widgets/prompt/toolbar/toolbar.dart';
import '../../../widgets/prompt/uc_preset_selector.dart';
import '../../../widgets/character/character_prompt_button.dart';
import '../../../widgets/prompt/fixed_tags_button.dart';
import '../../../providers/pending_prompt_provider.dart';
import '../../../prompt_assistant/providers/prompt_assistant_config_provider.dart';
import '../../../prompt_assistant/providers/prompt_assistant_history_provider.dart'; // 👈 [修复] 新版历史记录ID

// 👈 [新功能] 平台判断工具
bool usesRichPromptTypeTooltip(TargetPlatform platform) => platform != TargetPlatform.windows;

/// Prompt 输入组件 (带自动补全)
class PromptInputWidget extends ConsumerStatefulWidget {
  final bool compact;
  final VoidCallback? onToggleMaximize;
  final bool isMaximized;

  const PromptInputWidget({
    super.key,
    this.compact = false,
    this.onToggleMaximize,
    this.isMaximized = false,
  });

  @override
  ConsumerState<PromptInputWidget> createState() => _PromptInputWidgetState();
}

class _PromptInputWidgetState extends ConsumerState<PromptInputWidget> {
  late final NaiSyntaxController _promptController;
  late final NaiSyntaxController _negativeController;
  final _promptFocusNode = FocusNode();
  final _negativeFocusNode = FocusNode();

  // 正面/负面切换
  bool _isNegativeMode = false;

  @override
  void initState() {
    super.initState();
    final params = ref.read(generationParamsNotifierProvider);

    // 使用 NAI 语法高亮控制器
    _promptController = NaiSyntaxController(text: params.prompt);
    _negativeController = NaiSyntaxController(text: params.negativePrompt);

    _promptFocusNode.addListener(_onPromptFocusChanged);
    _negativeFocusNode.addListener(_onNegativeFocusChanged);

    // 检查并消费待填充提示词（从画廊发送）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _consumePendingPrompt();
    });
  }

  /// 消费待填充提示词（从画廊或词库发送）
  void _consumePendingPrompt() {
    final pendingState = ref.read(pendingPromptNotifierProvider);
    if (pendingState.prompt == null && pendingState.negativePrompt == null) {
      return;
    }

    // 消费待填充提示词
    final consumed = ref.read(pendingPromptNotifierProvider.notifier).consume();

    // 根据目标类型分别处理
    final targetType = consumed.targetType;

    if (consumed.prompt != null && consumed.prompt!.isNotEmpty) {
      // 自动进行语法转换（SD→NAI + 格式化）
      var prompt = consumed.prompt!;
      prompt = SdToNaiConverter.convert(prompt);
      prompt = NaiPromptFormatter.format(prompt);

      switch (targetType) {
        case SendTargetType.smartDecompose:
          // 智能分解：解析竖线格式，分别发送到主提示词和角色
          _applySmartDecompose(prompt);
          break;
        case SendTargetType.replaceCharacter:
          // 替换角色提示词：清空现有角色，添加新角色
          _applyToCharacterPrompt(prompt, clearExisting: true);
          break;
        case SendTargetType.appendCharacter:
          // 追加角色提示词：保留现有角色，添加新角色
          _applyToCharacterPrompt(prompt, clearExisting: false);
          break;
        case SendTargetType.mainPrompt:
        default:
          // 发送到主提示词（默认行为）
          _applyToMainPrompt(prompt);
          break;
      }
    }

    // 填充负向提示词（仅发送到主提示词时）
    if (targetType == null || targetType == SendTargetType.mainPrompt) {
      if (consumed.negativePrompt != null &&
          consumed.negativePrompt!.isNotEmpty) {
        // 自动进行语法转换（SD→NAI + 格式化）
        var negativePrompt = consumed.negativePrompt!;
        negativePrompt = SdToNaiConverter.convert(negativePrompt);
        negativePrompt = NaiPromptFormatter.format(negativePrompt);

        _negativeController.text = negativePrompt;
        ref
            .read(generationParamsNotifierProvider.notifier)
            .updateNegativePrompt(negativePrompt);
      }
    }

    // 触发 UI 更新
    if (mounted) setState(() {});
  }

  /// 应用到主提示词
  void _applyToMainPrompt(String prompt) {
    _promptController.text = prompt;
    ref.read(generationParamsNotifierProvider.notifier).updatePrompt(prompt);
  }

  /// 应用到角色提示词
  void _applyToCharacterPrompt(String prompt, {required bool clearExisting}) {
    final characterNotifier =
        ref.read(characterPromptNotifierProvider.notifier);

    // 如果需要清空现有角色
    if (clearExisting) {
      characterNotifier.clearAllCharacters();
    }

    // 检测是否为竖线格式
    if (PipeParser.isPipeFormat(prompt)) {
      // 解析竖线格式，分别添加每个角色
      final result = PipeParser.parse(prompt);
      // 添加主提示词中的内容作为第一个角色（如果存在）
      if (result.globalPrompt.isNotEmpty) {
        characterNotifier.addCharacter(
          _inferGender(result.globalPrompt),
          prompt: result.globalPrompt,
        );
      }
      // 添加解析出的角色
      for (final char in result.characters) {
        if (char.prompt.isNotEmpty) {
          // 将解析出的 ParsedPosition 转换为底层的 CharacterPosition
          CharacterPosition? pos;
          if (char.position != null) {
            pos = CharacterPosition(
              mode: CharacterPositionMode.custom,
              column: char.position!.x,
              row: char.position!.y,
            );
          }

          characterNotifier.addCharacter(
            char.inferredGender ?? CharacterGender.other,
            prompt: char.prompt,
            negativePrompt: char.negativePrompt, // 👈 传入原生负面词
            customPosition: pos,                 // 👈 传入原生坐标对象
          );
        }
      }

    } else {
      // 非竖线格式，直接添加为单个角色
      characterNotifier.addCharacter(
        _inferGender(prompt),
        prompt: prompt,
      );
    }

    // 显示提示
    if (mounted) {
      final message = clearExisting
          ? '已替换角色提示词'
          : '已追加角色提示词 (${ref.read(characterPromptNotifierProvider).characters.length}个角色)';
      AppToast.success(context, message);
    }
  }

  /// 推断提示词的性别
  CharacterGender _inferGender(String prompt) {
    final lowerPrompt = prompt.toLowerCase();
    if (lowerPrompt.contains('1boy') ||
        lowerPrompt.contains('2boys') ||
        lowerPrompt.contains('male')) {
      return CharacterGender.male;
    } else if (lowerPrompt.contains('1girl') ||
        lowerPrompt.contains('2girls') ||
        lowerPrompt.contains('female')) {
      return CharacterGender.female;
    }
    return CharacterGender.other;
  }

  /// 智能分解竖线格式并应用到对应位置
  void _applySmartDecompose(String prompt) {
    final characterNotifier =
        ref.read(characterPromptNotifierProvider.notifier);

    // 解析竖线格式
    final result = PipeParser.parse(prompt);

    // 应用到主提示词
    if (result.globalPrompt.isNotEmpty) {
      _applyToMainPrompt(result.globalPrompt);
    }

    // 清空现有角色并添加解析出的角色
    characterNotifier.clearAllCharacters();
    for (final char in result.characters) {
      if (char.prompt.isNotEmpty) {
        // 将解析出的 ParsedPosition 转换为底层的 CharacterPosition
        CharacterPosition? pos;
        if (char.position != null) {
          pos = CharacterPosition(
            mode: CharacterPositionMode.custom,
            column: char.position!.x,
            row: char.position!.y,
          );
        }

        characterNotifier.addCharacter(
          char.inferredGender ?? CharacterGender.other,
          prompt: char.prompt,
          negativePrompt: char.negativePrompt,
          customPosition: pos,
        );
      }
    }

    // 显示提示
    if (mounted) {
      final charCount = result.characters.length;
      final message = charCount > 0 ? '已分解：主提示词 + $charCount个角色' : '已应用到主提示词';
      AppToast.success(context, message);
    }
  }

  @override
  void dispose() {
    _promptFocusNode.removeListener(_onPromptFocusChanged);
    _negativeFocusNode.removeListener(_onNegativeFocusChanged);
    _promptController.dispose();
    _negativeController.dispose();
    _promptFocusNode.dispose();
    _negativeFocusNode.dispose();
    super.dispose();
  }

  void _onPromptFocusChanged() {
    setState(() {});

    // 当失去焦点时，必须延迟一帧执行，否则会引发焦点死循环导致卡死！
    if (!_promptFocusNode.hasFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        
        try {
          final enableMultiCharParse = ref.read(multiCharParseSettingsProvider);
          if (!enableMultiCharParse) return;

          final rawText = _promptController.text;
          
          // 👈 1. 使用原作者升级后的解析器检测是否符合 | 格式
          if (!PipeParser.isPipeFormat(rawText)) return;
          
          // 👈 2. 解析提示词
          final parsedResult = PipeParser.parse(rawText);

          if (parsedResult.characters.isNotEmpty) {
            // 1. 替换主输入框为基础词 (globalPrompt)
            _promptController.text = parsedResult.globalPrompt;
            ref.read(generationParamsNotifierProvider.notifier).updatePrompt(parsedResult.globalPrompt);

            // 2. 对拆分出来的角色词手动应用格式化
            final enableSdConvert = ref.read(sdSyntaxAutoConvertSettingsProvider);
            final enableAutoFormat = ref.read(autoFormatPromptSettingsProvider);

            String optimizeText(String t) {
              String res = t;
              if (enableSdConvert) res = SdToNaiConverter.convert(res);
              if (enableAutoFormat) res = NaiPromptFormatter.format(res);
              return res;
            }

            final charNotifier = ref.read(characterPromptNotifierProvider.notifier);
            charNotifier.clearAllCharacters();

            // 3. 填入面板
            for (var charData in parsedResult.characters) {
              // 将解析出的 ParsedPosition 转换为底层的 CharacterPosition
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
        } catch (e) {
          debugPrint('静默拆分失败: $e');
        }
      });
    }
  }
      
  void _onNegativeFocusChanged() {
    // Focus 状态变化时触发重建
    setState(() {});
  }
  
  /// 从 Provider 同步提示词到本地状态
  void _syncPromptFromProvider(String prompt) {
    // 避免循环触发：只在内容不同时更新
    if (_promptController.text != prompt) {
      _promptController.text = prompt;
    }
  }

  /// 从 Provider 同步负向提示词到本地状态
  void _syncNegativeFromProvider(String negativePrompt) {
    if (_negativeController.text != negativePrompt) {
      _negativeController.text = negativePrompt;
    }
  }

  /// 生成随机提示词
  Future<void> _generateRandomPrompt() async {
    try {
      // 使用统一的随机提示词生成并应用方法
      await ref
          .read(imageGenerationNotifierProvider.notifier)
          .generateAndApplyRandomPrompt();

      // 检查是否有角色被生成（用于 Toast 提示）
      final characterConfig = ref.read(characterPromptNotifierProvider);
      final hasCharacters = characterConfig.characters
          .any((c) => c.enabled && c.prompt.isNotEmpty);

      if (hasCharacters && mounted) {
        final count = characterConfig.characters
            .where((c) => c.enabled && c.prompt.isNotEmpty)
            .length;
        AppToast.success(
          context,
          context.l10n.tagLibrary_generatedCharacters(count.toString()),
        );
      }
    } catch (e) {
      if (mounted) {
        AppToast.error(
          context,
          context.l10n.tagLibrary_generateFailed(e.toString()),
        );
      }
    }
  }

  /// 显示随机模式选择
  void _showRandomModeSelector() {
    RandomModeBottomSheet.show(context);
  }

  void _clearPrompt() {
    _promptController.clear();
    ref.read(generationParamsNotifierProvider.notifier).updatePrompt('');
    // 同时清空角色提示词
    ref.read(characterPromptNotifierProvider.notifier).clearAllCharacters();
  }

  void _openAssistantQuickSettings() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return Consumer(
          builder: (context, ref, _) {
            final config = ref.watch(promptAssistantConfigProvider);
            final notifier = ref.read(promptAssistantConfigProvider.notifier);
            return SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SwitchListTile(
                    title: const Text('启用提示词助手'),
                    value: config.enabled,
                    onChanged: notifier.setEnabled,
                  ),
                  SwitchListTile(
                    title: const Text('桌面右下角浮层'),
                    value: config.desktopOverlayEnabled,
                    onChanged: notifier.setDesktopOverlayEnabled,
                  ),
                  // 👈 【核心修复】：删除了导致报错的 streamOutput，因为原作者在底层把它移除了！
                ],
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    ref.listen(
        generationParamsNotifierProvider.select(
          (params) => (
            prompt: params.prompt,
            negativePrompt: params.negativePrompt,
          ),
        ), (previous, next) {
      bool isQueueActive = false;
      try {
        final queueState = ref.read(queueExecutionNotifierProvider);
        isQueueActive = queueState.isRunning || queueState.isReady;
      } catch (e) {
      }

      if (!isQueueActive) {
        if (previous?.prompt != next.prompt) {
          if (_promptController.text != next.prompt) {
            _promptController.text = next.prompt;
          }
        }
        if (previous?.negativePrompt != next.negativePrompt) {
          if (_negativeController.text != next.negativePrompt) {
            _negativeController.text = next.negativePrompt;
          }
        }
      }
    });
    
    ref.listen(hasPendingPromptProvider, (previous, next) {
      if (next == true) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _consumePendingPrompt();
        });
      }
    });

    final highlightEnabled = ref.watch(highlightEmphasisSettingsProvider);
    _promptController.highlightEnabled = highlightEnabled;
    _negativeController.highlightEnabled = highlightEnabled;

    if (widget.compact) {
      return _buildCompactLayout(theme);
    }

    return _buildFullLayout(theme);
  }
  
  Widget _buildFullLayout(ThemeData theme) {
    // 👈 [新功能] 获取当前使用的 Token 数量
    final tokenUsage = ref.watch(
      promptTokenUsageProvider(
        _isNegativeMode
            ? PromptTokenCountTarget.negative
            : PromptTokenCountTarget.positive,
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildTopBar(theme),
        const SizedBox(height: 8),
        Expanded(
          child: _isNegativeMode
              ? _buildTextNegativeInput(theme)
              : _buildTextPromptInput(theme),
        ),
        // 👈 [新功能] 在输入框底部显示 Token 进度条
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Builder(
            builder: (context) {
              // 🌟 核心魔法：使用 valueOrNull，在计算新 Token 的十几毫秒内，
              // 它会继续保留并显示上一次的旧数据，绝对不会闪烁！
              final usage = tokenUsage.valueOrNull;
              
              if (usage == null) {
                return const SizedBox.shrink();
              }
              
              return PromptTokenCountBar(usage: usage);
            },
          ),
        ),     
      ],
    );
  }

  Widget _buildTopBar(ThemeData theme) {
    final promptCount = _promptController.text
        .split(',')
        .where((s) => s.trim().isNotEmpty)
        .length;
    final negativeCount = _negativeController.text
        .split(',')
        .where((s) => s.trim().isNotEmpty)
        .length;

    // 👈 [性能优化] 使用 select 只监听 model 变化
    final model = ref.watch(
      generationParamsNotifierProvider.select((params) => params.model),
    );

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _buildPromptTypeSwitch(theme, promptCount, negativeCount),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const FixedTagsButton(),
            QualityTagsSelector(model: model),
            UcPresetSelector(model: model),
            const CharacterPromptButton(),
            PromptEditorToolbar(
              config: PromptEditorToolbarConfig.mainEditor,
              onRandomPressed: _generateRandomPrompt,
              onRandomLongPressed: _showRandomModeSelector,
              onFullscreenPressed: widget.onToggleMaximize ??
                  () => ref
                      .read(promptMaximizeNotifierProvider.notifier)
                      .toggle(),
              onClearPressed: _isNegativeMode ? _clearNegative : _clearPrompt,
              onSettingsPressed: () => _showSettingsMenu(context, theme),
            ),
          ],
        ),
      ],
    );
  }

  void _showSettingsMenu(BuildContext context, ThemeData theme) {
    final enableAutocomplete = ref.read(autocompleteSettingsProvider);
    final enableAutoFormat = ref.read(autoFormatPromptSettingsProvider);
    final enableHighlight = ref.read(highlightEmphasisSettingsProvider);
    final enableSdSyntaxAutoConvert =
        ref.read(sdSyntaxAutoConvertSettingsProvider);
    final enableCooccurrence = ref.read(cooccurrenceSettingsProvider);
    
    // 👈 [新增] 读取多人提示词智能拆分设置
    final enableMultiCharParse = ref.read(multiCharParseSettingsProvider);

    final position = PromptEditorToolbar.getSettingsButtonPosition(context);
    if (position == null) return;

    showMenu<String>(
      context: context,
      position: position,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      items: [
        _buildSettingsMenuItem(
          value: 'autocomplete',
          isEnabled: enableAutocomplete,
          title: context.l10n.prompt_smartAutocomplete,
          subtitle: context.l10n.prompt_smartAutocompleteSubtitle,
          theme: theme,
        ),
        _buildSettingsMenuItem(
          value: 'auto_format',
          isEnabled: enableAutoFormat,
          title: context.l10n.prompt_autoFormat,
          subtitle: context.l10n.prompt_autoFormatSubtitle,
          theme: theme,
        ),
        _buildSettingsMenuItem(
          value: 'highlight',
          isEnabled: enableHighlight,
          title: context.l10n.prompt_highlightEmphasis,
          subtitle: context.l10n.prompt_highlightEmphasisSubtitle,
          theme: theme,
        ),
        _buildSettingsMenuItem(
          value: 'sd_syntax_convert',
          isEnabled: enableSdSyntaxAutoConvert,
          title: context.l10n.prompt_sdSyntaxAutoConvert,
          subtitle: context.l10n.prompt_sdSyntaxAutoConvertSubtitle,
          theme: theme,
        ),
        _buildSettingsMenuItem(
          value: 'cooccurrence',
          isEnabled: enableCooccurrence,
          title: context.l10n.prompt_cooccurrenceRecommendation,
          subtitle: context.l10n.prompt_cooccurrenceRecommendationSubtitle,
          theme: theme,
        ),
        // 👈 [新增] 多人提示词智能拆分菜单项
        _buildSettingsMenuItem(
          value: 'multi_char_parse',
          isEnabled: enableMultiCharParse,
          title: '多人提示词智能拆分',
          subtitle: '输入特殊格式时，自动拆分至多角色面板',
          theme: theme,
        ),
      ],
    ).then(_handleSettingsMenuResult);
  }

  Widget _buildPromptTypeSwitch(
    ThemeData theme,
    int promptCount,
    int negativeCount,
  ) {
    final fixedTagsState = ref.watch(fixedTagsNotifierProvider);
    final enabledPrefixes = fixedTagsState.enabledPrefixes;
    final enabledSuffixes = fixedTagsState.enabledSuffixes;
    // 👈 合并原作者新功能：获取负向固定词
    final negativeEnabledPrefixes = fixedTagsState.negativeEnabledPrefixes;
    final negativeEnabledSuffixes = fixedTagsState.negativeEnabledSuffixes;

    final qualityState = ref.watch(qualityPresetNotifierProvider);
    final model = ref.watch(
      generationParamsNotifierProvider.select((params) => params.model),
    );
    final qualityContent = ref
        .watch(qualityPresetNotifierProvider.notifier)
        .getEffectiveContent(model);

    // 👈 合并原作者新功能：使用全新的 UC Preset 获取方式
    ref.watch(ucPresetNotifierProvider);
    final ucPresetContent = ref
            .watch(ucPresetNotifierProvider.notifier)
            .getEffectiveContent(model) ??
        '';

    final characterConfig = ref.watch(characterPromptNotifierProvider);
    final aliasResolver = ref.read(aliasResolverServiceProvider.notifier);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _PromptTypeButton(
          icon: Icons.auto_awesome,
          label: context.l10n.prompt_positive,
          count: promptCount,
          isSelected: !_isNegativeMode,
          color: theme.colorScheme.primary,
          onTap: () => setState(() => _isNegativeMode = false),
          tooltipBuilder: (theme) => _PositivePromptTooltip(
            theme: theme,
            userPrompt: _promptController.text,
            prefixes: enabledPrefixes,
            suffixes: enabledSuffixes,
            qualityMode: qualityState.mode,
            qualityContent: qualityContent,
            characters: characterConfig.characters,
            globalAiChoice: characterConfig.globalAiChoice,
            l10n: context.l10n,
            aliasResolver: aliasResolver,
          ),
        ),
        const SizedBox(width: 8),
        _PromptTypeButton(
          icon: Icons.block,
          label: context.l10n.prompt_negative,
          count: negativeCount,
          isSelected: _isNegativeMode,
          color: theme.colorScheme.error,
          onTap: () => setState(() => _isNegativeMode = true),
          tooltipBuilder: (theme) => _NegativePromptTooltip(
            theme: theme,
            userNegativePrompt: _negativeController.text,
            // 👈 合并原作者新功能：传入负向固定词
            prefixes: negativeEnabledPrefixes,
            suffixes: negativeEnabledSuffixes,
            ucPresetContent: ucPresetContent,
            l10n: context.l10n,
            aliasResolver: aliasResolver,
          ),
        ),
      ],
    );
  }

  void _clearNegative() {
    _negativeController.clear();
    ref
        .read(generationParamsNotifierProvider.notifier)
        .updateNegativePrompt('');
  }

  Widget _buildTextPromptInput(ThemeData theme) {
    final enableAutocomplete = ref.watch(autocompleteSettingsProvider);
    final enableAutoFormat = ref.watch(autoFormatPromptSettingsProvider);
    final enableHighlight = ref.watch(highlightEmphasisSettingsProvider);
    final enableSdSyntaxAutoConvert = ref.watch(sdSyntaxAutoConvertSettingsProvider);
    
    // 👈 1. 新增：读取智能拆分开关状态
    final enableMultiCharParse = ref.watch(multiCharParseSettingsProvider); 

    return UnifiedPromptInput(
      key: const ValueKey('generation_prompt_positive_input'),
      controller: _promptController,
      focusNode: _promptFocusNode,
      sessionId: PromptHistorySessionIds.generationPrompt,
      onOpenAssistantSettings: _openAssistantQuickSettings,
      config: UnifiedPromptConfig(
        enableSyntaxHighlight: enableHighlight,
        enableAutocomplete: enableAutocomplete,
        enableAutoFormat: enableAutoFormat,
        enableSdSyntaxAutoConvert: enableSdSyntaxAutoConvert,
        
        // 👈 2. 修改：开启智能拆分时，关闭原作者的弹窗；关闭智能拆分时，开启弹窗
        enableComfyuiImport: !enableMultiCharParse, 
        
        autocompleteConfig: const AutocompleteConfig(
          maxSuggestions: 20,
          showTranslation: true,
          showCategory: true,
          showCount: true,
          autoInsertComma: true,
        ),
        hintText: enableAutocomplete
            ? context.l10n.prompt_describeImageWithHint
            : context.l10n.prompt_describeImage,
      ),
      decoration: const InputDecoration(
        contentPadding: EdgeInsets.all(12),
      ),
      maxLines: null,
      expands: true,
      onComfyuiImport: (globalPrompt, characters) async {
        // 👈 核心修复：延迟 50 毫秒，让弹窗动画彻底关闭，避开 UI 渲染死锁！
        await Future.delayed(const Duration(milliseconds: 50));
        if (!mounted) return;

        final enableSdConvert = ref.read(sdSyntaxAutoConvertSettingsProvider);
        final enableAutoFormat = ref.read(autoFormatPromptSettingsProvider);

        String optimizeText(String t) {
          if (t.trim().isEmpty) return t; // 拦截空字符串保护
          String res = t;
          if (enableSdConvert) res = SdToNaiConverter.convert(res);
          if (enableAutoFormat) res = NaiPromptFormatter.format(res);
          return res;
        }

        final formattedGlobal = optimizeText(globalPrompt);
        
        // 安全遍历构建新角色列表
        final newChars = characters.map((c) => c.copyWith(
          prompt: optimizeText(c.prompt),
          negativePrompt: optimizeText(c.negativePrompt),
        )).toList();

        ref.read(characterPromptNotifierProvider.notifier).clearAll();
        ref.read(characterPromptNotifierProvider.notifier).replaceAll(newChars);
        ref.read(generationParamsNotifierProvider.notifier).updatePrompt(formattedGlobal);
        
        AppToast.success(context, '已导入 ${characters.length} 个角色');
      },
      onChanged: (value) {
        ref.read(generationParamsNotifierProvider.notifier).updatePrompt(value);
      },
    );
  }

  PopupMenuItem<String> _buildSettingsMenuItem({
    required String value,
    required bool isEnabled,
    required String title,
    required String subtitle,
    required ThemeData theme,
  }) {
    return PopupMenuItem<String>(
      value: value,
      child: Row(
        children: [
          Icon(
            isEnabled ? Icons.check_box : Icons.check_box_outline_blank,
            size: 20,
            color: isEnabled ? theme.colorScheme.primary : null,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title),
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _handleSettingsMenuResult(String? value) {
    switch (value) {
      case 'autocomplete':
        ref.read(autocompleteSettingsProvider.notifier).toggle();
      case 'auto_format':
        ref.read(autoFormatPromptSettingsProvider.notifier).toggle();
      case 'highlight':
        ref.read(highlightEmphasisSettingsProvider.notifier).toggle();
      case 'sd_syntax_convert':
        ref.read(sdSyntaxAutoConvertSettingsProvider.notifier).toggle();
      case 'cooccurrence':
        ref.read(cooccurrenceSettingsProvider.notifier).toggle();
      // 👈 [新增] 处理智能拆分开关的点击
      case 'multi_char_parse':
        ref.read(multiCharParseSettingsProvider.notifier).toggle();
    }
  }
  
  Widget _buildTextNegativeInput(ThemeData theme) {
    final enableAutocomplete = ref.watch(autocompleteSettingsProvider);
    final enableAutoFormat = ref.watch(autoFormatPromptSettingsProvider);
    final enableHighlight = ref.watch(highlightEmphasisSettingsProvider);
    final enableSdSyntaxAutoConvert =
        ref.watch(sdSyntaxAutoConvertSettingsProvider);
    return UnifiedPromptInput(
      key: const ValueKey('generation_prompt_negative_input'),
      controller: _negativeController,
      focusNode: _negativeFocusNode,
      sessionId: PromptHistorySessionIds.generationNegative, // 👈 [修复] 替换为新版枚举ID
      onOpenAssistantSettings: _openAssistantQuickSettings,
      config: UnifiedPromptConfig(
        enableSyntaxHighlight: enableHighlight,
        enableAutocomplete: enableAutocomplete,
        enableAutoFormat: enableAutoFormat,
        enableSdSyntaxAutoConvert: enableSdSyntaxAutoConvert,
        enableComfyuiImport: false,
        autocompleteConfig: const AutocompleteConfig(
          maxSuggestions: 15,
          showTranslation: true,
          showCategory: false,
          autoInsertComma: true,
        ),
        hintText: context.l10n.prompt_unwantedContent,
      ),
      decoration: const InputDecoration(
        contentPadding: EdgeInsets.all(12),
      ),
      maxLines: null,
      expands: true,
      onChanged: (value) {
        ref
            .read(generationParamsNotifierProvider.notifier)
            .updateNegativePrompt(value);
      },
    );
  }

  Widget _buildCompactLayout(ThemeData theme) {
    final enableHighlight = ref.watch(highlightEmphasisSettingsProvider);
    final enableAutocomplete = ref.watch(autocompleteSettingsProvider);
    
    // 👇 1. 核心修复：补上遗漏的两个开关读取
    final enableAutoFormat = ref.watch(autoFormatPromptSettingsProvider);
    final enableSdSyntaxAutoConvert = ref.watch(sdSyntaxAutoConvertSettingsProvider);
    
    // 👈 读取智能拆分开关状态
    final enableMultiCharParse = ref.watch(multiCharParseSettingsProvider);

    return UnifiedPromptInput(
      controller: _promptController,
      focusNode: _promptFocusNode,
      sessionId: PromptHistorySessionIds.generationPrompt,
      onOpenAssistantSettings: _openAssistantQuickSettings,
      config: UnifiedPromptConfig(
        enableSyntaxHighlight: enableHighlight,
        enableAutocomplete: enableAutocomplete,
        
        // 👇 2. 核心修复：把开关状态传给底层组件，打破强制格式化！
        enableAutoFormat: enableAutoFormat,
        enableSdSyntaxAutoConvert: enableSdSyntaxAutoConvert,
        
        // 反向绑定弹窗开关
        enableComfyuiImport: !enableMultiCharParse,
        
        autocompleteConfig: const AutocompleteConfig(
          maxSuggestions: 15,
          showTranslation: true,
          autoInsertComma: true,
        ),
        hintText: context.l10n.prompt_inputPrompt,
      ),
      
      decoration: const InputDecoration(
        contentPadding: EdgeInsets.all(12), // 纯净的内边距，没有任何死角
      ),
      maxLines: null,
      expands: true,
      onComfyuiImport: (globalPrompt, characters) async {
        // 👈 核心修复：延迟 50 毫秒，让弹窗动画彻底关闭，避开 UI 渲染死锁！
        await Future.delayed(const Duration(milliseconds: 50));
        if (!mounted) return;

        final enableSdConvert = ref.read(sdSyntaxAutoConvertSettingsProvider);
        final enableAutoFormat = ref.read(autoFormatPromptSettingsProvider);

        String optimizeText(String t) {
          if (t.trim().isEmpty) return t; // 拦截空字符串保护
          String res = t;
          if (enableSdConvert) res = SdToNaiConverter.convert(res);
          if (enableAutoFormat) res = NaiPromptFormatter.format(res);
          return res;
        }

        final formattedGlobal = optimizeText(globalPrompt);
        
        // 安全遍历构建新角色列表
        final newChars = characters.map((c) => c.copyWith(
          prompt: optimizeText(c.prompt),
          negativePrompt: optimizeText(c.negativePrompt),
        )).toList();

        ref.read(characterPromptNotifierProvider.notifier).clearAll();
        ref.read(characterPromptNotifierProvider.notifier).replaceAll(newChars);
        ref.read(generationParamsNotifierProvider.notifier).updatePrompt(formattedGlobal);
        
        AppToast.success(context, '已导入 ${characters.length} 个角色');
      },
      onChanged: (value) {
        ref.read(generationParamsNotifierProvider.notifier).updatePrompt(value);
      },
    );
  }
}

/// 正面提示词悬浮提示内容
class _PositivePromptTooltip extends StatelessWidget {
  final ThemeData theme;
  final String userPrompt;
  final List<FixedTagEntry> prefixes;
  final List<FixedTagEntry> suffixes;
  final PromptPresetMode qualityMode;
  final String? qualityContent;
  final List<CharacterPrompt> characters;
  final bool globalAiChoice;
  final dynamic l10n;
  final AliasResolverService aliasResolver;

  const _PositivePromptTooltip({
    required this.theme,
    required this.userPrompt,
    required this.prefixes,
    required this.suffixes,
    required this.qualityMode,
    required this.qualityContent,
    required this.characters,
    required this.globalAiChoice,
    required this.l10n,
    required this.aliasResolver,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = theme.brightness == Brightness.dark;
    final hasPrefixes = prefixes.isNotEmpty;
    final hasSuffixes = suffixes.isNotEmpty;
    final hasQuality = qualityContent != null && qualityContent!.isNotEmpty;
    final enabledCharacters =
        characters.where((c) => c.enabled && c.prompt.isNotEmpty).toList();
    final hasCharacters = enabledCharacters.isNotEmpty;

    // 构建最终生效的完整提示词
    final effectivePrompt = _buildEffectivePrompt();

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 顶部统计标题
        _buildHeader(isDark),

        const SizedBox(height: 10),

        // 固定词（前缀）- 解析别名
        if (hasPrefixes) ...[
          _buildSection(
            icon: Icons.arrow_forward_rounded,
            label: l10n.fixedTags_prefix,
            color: theme.colorScheme.primary,
            content: prefixes
                .map((e) => aliasResolver.resolveAliases(e.content))
                .join(', '),
            isDark: isDark,
          ),
          const SizedBox(height: 8),
        ],

        // 用户输入 - 解析别名
        if (userPrompt.trim().isNotEmpty) ...[
          _buildSection(
            icon: Icons.edit_rounded,
            label: l10n.prompt_mainPositive,
            color: theme.colorScheme.secondary,
            content: aliasResolver.resolveAliases(userPrompt.trim()),
            isDark: isDark,
          ),
          const SizedBox(height: 8),
        ],

        // 质量词
        if (hasQuality) ...[
          _buildSection(
            icon: Icons.star_rounded,
            label: l10n.qualityTags_positive,
            color: Colors.amber,
            content: qualityContent!,
            isDark: isDark,
          ),
          const SizedBox(height: 8),
        ],

        // 多角色提示词
        if (hasCharacters) ...[
          _buildCharacterSection(
            enabledCharacters,
            isDark,
          ),
          const SizedBox(height: 8),
        ],

        // 固定词（后缀）- 解析别名
        if (hasSuffixes) ...[
          _buildSection(
            icon: Icons.arrow_back_rounded,
            label: l10n.fixedTags_suffix,
            color: theme.colorScheme.tertiary,
            content: suffixes
                .map((e) => aliasResolver.resolveAliases(e.content))
                .join(', '),
            isDark: isDark,
          ),
          const SizedBox(height: 8),
        ],

        // 分隔线
        Container(
          margin: const EdgeInsets.symmetric(vertical: 6),
          height: 1,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                Colors.transparent,
                theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
                Colors.transparent,
              ],
            ),
          ),
        ),

        // 最终生效提示词
        _buildFinalPromptSection(effectivePrompt, isDark),
      ],
    );
  }

  Widget _buildHeader(bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            theme.colorScheme.primary.withValues(alpha: isDark ? 0.2 : 0.1),
            theme.colorScheme.primary.withValues(alpha: isDark ? 0.1 : 0.05),
          ],
        ),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.2),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.auto_awesome,
            size: 14,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 6),
          Text(
            l10n.prompt_positivePrompt,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.primary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSection({
    required IconData icon,
    required String label,
    required Color color,
    required String content,
    required bool isDark,
  }) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: isDark
            ? theme.colorScheme.surfaceContainerHigh.withValues(alpha: 0.4)
            : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 3,
                height: 14,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [color, color.withValues(alpha: 0.4)],
                  ),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 6),
              Icon(icon, size: 12, color: color),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 120),
            child: ScrollbarTheme(
              data: ScrollbarThemeData(
                thumbVisibility: WidgetStateProperty.all(true),
                thickness: WidgetStateProperty.all(4),
              ),
              child: SingleChildScrollView(
                child: Text(
                  content,
                  style: TextStyle(
                    fontSize: 11,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.8),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFinalPromptSection(String prompt, bool isDark) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            theme.colorScheme.primaryContainer.withValues(alpha: isDark ? 0.3 : 0.4),
            theme.colorScheme.secondaryContainer
                .withValues(alpha: isDark ? 0.2 : 0.3),
          ],
        ),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.2),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(
                Icons.output_rounded,
                size: 12,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 6),
              Text(
                l10n.prompt_finalPrompt,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.primary,
                ),
              ),
              const Spacer(),
              // 复制按钮
              _CopyIconButton(
                content: prompt,
                color: theme.colorScheme.primary,
              ),
            ],
          ),
          const SizedBox(height: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 150),
            child: ScrollbarTheme(
              data: ScrollbarThemeData(
                thumbVisibility: WidgetStateProperty.all(true),
                thickness: WidgetStateProperty.all(4),
              ),
              child: SingleChildScrollView(
                child: Text(
                  prompt,
                  style: TextStyle(
                    fontSize: 11,
                    color: theme.colorScheme.onSurface,
                    height: 1.4,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _buildEffectivePrompt() {
    final parts = <String>[];

    // 前缀
    for (final p in prefixes) {
      if (p.content.trim().isNotEmpty) {
        parts.add(aliasResolver.resolveAliases(p.content.trim()));
      }
    }

    // 用户输入（解析别名）
    if (userPrompt.trim().isNotEmpty) {
      parts.add(aliasResolver.resolveAliases(userPrompt.trim()));
    }

    // 质量词
    if (qualityContent != null && qualityContent!.isNotEmpty) {
      parts.add(qualityContent!);
    }

    // 多角色提示词
    final enabledCharacters =
        characters.where((c) => c.enabled && c.prompt.isNotEmpty);
    for (final character in enabledCharacters) {
      parts.add(character.toNaiPrompt(useAiPosition: globalAiChoice));
    }

    // 后缀
    for (final s in suffixes) {
      if (s.content.trim().isNotEmpty) {
        parts.add(aliasResolver.resolveAliases(s.content.trim()));
      }
    }

    return parts.join(', ');
  }

  Widget _buildCharacterSection(
    List<CharacterPrompt> enabledCharacters,
    bool isDark,
  ) {
    const color = Colors.teal;
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: isDark
            ? theme.colorScheme.surfaceContainerHigh.withValues(alpha: 0.4)
            : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 3,
                height: 14,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [color, color.withValues(alpha: 0.4)],
                  ),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 6),
              const Icon(Icons.people_rounded, size: 12, color: color),
              const SizedBox(width: 4),
              Text(
                l10n.prompt_characterPrompts,
                style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  '${enabledCharacters.length}',
                  style: const TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w600,
                    color: color,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 120),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: enabledCharacters.map((character) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          character.gender == CharacterGender.female
                              ? Icons.female
                              : character.gender == CharacterGender.male
                                  ? Icons.male
                                  : Icons.person,
                          size: 11,
                          color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            '${character.name}: ${character.toNaiPrompt(useAiPosition: globalAiChoice)}',
                            style: TextStyle(
                              fontSize: 10,
                              color:
                                  theme.colorScheme.onSurface.withValues(alpha: 0.8),
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 负面提示词悬浮提示内容
class _NegativePromptTooltip extends StatelessWidget {
  final ThemeData theme;
  final String userNegativePrompt;
  final List<FixedTagEntry> prefixes;
  final List<FixedTagEntry> suffixes;
  final String ucPresetContent;
  final dynamic l10n;
  final AliasResolverService aliasResolver;

  const _NegativePromptTooltip({
    required this.theme,
    required this.userNegativePrompt,
    required this.prefixes,
    required this.suffixes,
    required this.ucPresetContent,
    required this.l10n,
    required this.aliasResolver,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = theme.brightness == Brightness.dark;
    final hasUserInput = userNegativePrompt.trim().isNotEmpty;
    final hasPrefixes = prefixes.isNotEmpty;
    final hasSuffixes = suffixes.isNotEmpty;
    final hasPreset = ucPresetContent.isNotEmpty;

    // 构建最终生效的完整负面提示词
    final effectiveNegative = _buildEffectiveNegative();

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 顶部标题
        _buildHeader(isDark),

        const SizedBox(height: 10),

        // UC预设
        if (hasPreset) ...[
          _buildSection(
            icon: Icons.shield_rounded,
            label: l10n.qualityTags_negative,
            color: theme.colorScheme.error,
            content: ucPresetContent,
            isDark: isDark,
          ),
          const SizedBox(height: 8),
        ],

        // 负向固定词（前缀）- 解析别名
        if (hasPrefixes) ...[
          _buildSection(
            icon: Icons.arrow_forward_rounded,
            label: '负向固定词前缀',
            color: theme.colorScheme.error,
            content: prefixes
                .map((entry) => aliasResolver.resolveAliases(entry.content))
                .join(', '),
            isDark: isDark,
          ),
          const SizedBox(height: 8),
        ],

        // 用户输入 - 解析别名
        if (hasUserInput) ...[
          _buildSection(
            icon: Icons.edit_rounded,
            label: l10n.prompt_mainNegative,
            color: theme.colorScheme.tertiary,
            content: aliasResolver.resolveAliases(userNegativePrompt.trim()),
            isDark: isDark,
          ),
          const SizedBox(height: 8),
        ],

        // 负向固定词（后缀）- 解析别名
        if (hasSuffixes) ...[
          _buildSection(
            icon: Icons.arrow_back_rounded,
            label: '负向固定词后缀',
            color: theme.colorScheme.tertiary,
            content: suffixes
                .map((entry) => aliasResolver.resolveAliases(entry.content))
                .join(', '),
            isDark: isDark,
          ),
          const SizedBox(height: 8),
        ],

        // 分隔线
        Container(
          margin: const EdgeInsets.symmetric(vertical: 6),
          height: 1,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                Colors.transparent,
                theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
                Colors.transparent,
              ],
            ),
          ),
        ),

        // 最终生效负面提示词
        _buildFinalSection(effectiveNegative, isDark),
      ],
    );
  }

  Widget _buildHeader(bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            theme.colorScheme.error.withValues(alpha: isDark ? 0.2 : 0.1),
            theme.colorScheme.error.withValues(alpha: isDark ? 0.1 : 0.05),
          ],
        ),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: theme.colorScheme.error.withValues(alpha: 0.2),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.block,
            size: 14,
            color: theme.colorScheme.error,
          ),
          const SizedBox(width: 6),
          Text(
            l10n.prompt_negativePrompt,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.error,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSection({
    required IconData icon,
    required String label,
    required Color color,
    required String content,
    required bool isDark,
  }) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: isDark
            ? theme.colorScheme.surfaceContainerHigh.withValues(alpha: 0.4)
            : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 3,
                height: 14,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [color, color.withValues(alpha: 0.4)],
                  ),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 6),
              Icon(icon, size: 12, color: color),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 120),
            child: ScrollbarTheme(
              data: ScrollbarThemeData(
                thumbVisibility: WidgetStateProperty.all(true),
                thickness: WidgetStateProperty.all(4),
              ),
              child: SingleChildScrollView(
                child: Text(
                  content,
                  style: TextStyle(
                    fontSize: 11,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.8),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFinalSection(String prompt, bool isDark) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            theme.colorScheme.errorContainer.withValues(alpha: isDark ? 0.3 : 0.4),
            theme.colorScheme.surfaceContainerHighest
                .withValues(alpha: isDark ? 0.2 : 0.3),
          ],
        ),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: theme.colorScheme.error.withValues(alpha: 0.2),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(
                Icons.output_rounded,
                size: 12,
                color: theme.colorScheme.error,
              ),
              const SizedBox(width: 6),
              Text(
                l10n.prompt_finalNegative,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.error,
                ),
              ),
              const Spacer(),
              // 复制按钮
              if (prompt.isNotEmpty)
                _CopyIconButton(
                  content: prompt,
                  color: theme.colorScheme.error,
                ),
            ],
          ),
          const SizedBox(height: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 150),
            child: ScrollbarTheme(
              data: ScrollbarThemeData(
                thumbVisibility: WidgetStateProperty.all(true),
                thickness: WidgetStateProperty.all(4),
              ),
              child: SingleChildScrollView(
                child: Text(
                  prompt.isEmpty ? '-' : prompt,
                  style: TextStyle(
                    fontSize: 11,
                    color: theme.colorScheme.onSurface,
                    height: 1.4,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _buildEffectiveNegative() {
    final parts = <String>[];

    // UC预设
    if (ucPresetContent.isNotEmpty) {
      parts.add(ucPresetContent);
    }

    // 用户输入（解析别名）
    for (final prefix in prefixes) {
      if (prefix.content.trim().isNotEmpty) {
        parts.add(aliasResolver.resolveAliases(prefix.content.trim()));
      }
    }

    if (userNegativePrompt.trim().isNotEmpty) {
      parts.add(aliasResolver.resolveAliases(userNegativePrompt.trim()));
    }

    for (final suffix in suffixes) {
      if (suffix.content.trim().isNotEmpty) {
        parts.add(aliasResolver.resolveAliases(suffix.content.trim()));
      }
    }

    return parts.join(', ');
  }
}

/// 提示词类型切换按钮
class _PromptTypeButton extends StatefulWidget {
  final IconData icon;
  final String label;
  final int count;
  final bool isSelected;
  final Color color;
  final VoidCallback onTap;
  final Widget Function(ThemeData theme)? tooltipBuilder;

  const _PromptTypeButton({
    required this.icon,
    required this.label,
    required this.count,
    required this.isSelected,
    required this.color,
    required this.onTap,
    this.tooltipBuilder,
  });

  @override
  State<_PromptTypeButton> createState() => _PromptTypeButtonState();
}

class _PromptTypeButtonState extends State<_PromptTypeButton>
    with SingleTickerProviderStateMixin {
  bool _isHovering = false;
  late AnimationController _animController;
  late Animation<double> _scaleAnim;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 150),
    );
    _scaleAnim = Tween<double>(begin: 1.0, end: 0.95).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final useRichTooltip = usesRichPromptTypeTooltip(theme.platform); // 👈 [新功能] 适配新版Tooltip

    final button = MouseRegion(
      onEnter: (_) => setState(() => _isHovering = true),
      onExit: (_) => setState(() => _isHovering = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTapDown: (_) => _animController.forward(),
        onTapUp: (_) {
          _animController.reverse();
          widget.onTap();
        },
        onTapCancel: () => _animController.reverse(),
        child: AnimatedBuilder(
          animation: _scaleAnim,
          builder: (context, child) => Transform.scale(
            scale: _scaleAnim.value,
            child: child,
          ),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              // 选中时使用渐变背景
              gradient: widget.isSelected
                  ? LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        widget.color.withValues(alpha: 0.2),
                        widget.color.withValues(alpha: 0.1),
                      ],
                    )
                  : null,
              color: widget.isSelected
                  ? null
                  : (_isHovering
                      ? theme.colorScheme.surfaceContainerHighest
                      : theme.colorScheme.surfaceContainerHigh),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: widget.isSelected
                    ? widget.color.withValues(alpha: 0.5)
                    : (_isHovering
                        ? theme.colorScheme.outline.withValues(alpha: 0.3)
                        : Colors.transparent),
                width: widget.isSelected ? 1.5 : 1,
              ),
              boxShadow: widget.isSelected
                  ? [
                      BoxShadow(
                        color: widget.color.withValues(alpha: 0.2),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ]
                  : null,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 图标
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: widget.isSelected
                        ? widget.color.withValues(alpha: 0.15)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Icon(
                    widget.icon,
                    size: 16,
                    color: widget.isSelected
                        ? widget.color
                        : theme.colorScheme.onSurface.withValues(alpha: 0.5),
                  ),
                ),
                const SizedBox(width: 8),
                // 文字
                Text(
                  widget.label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight:
                        widget.isSelected ? FontWeight.w600 : FontWeight.w500,
                    color: widget.isSelected
                        ? widget.color
                        : theme.colorScheme.onSurface.withValues(alpha: 0.7),
                    letterSpacing: 0.3,
                  ),
                ),
                // 数量徽章
                if (widget.count > 0) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: widget.isSelected
                          ? widget.color.withValues(alpha: 0.2)
                          : theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      widget.count.toString(),
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: widget.isSelected
                            ? widget.color
                            : theme.colorScheme.onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );

    // 如果有 tooltipBuilder，包裹 Tooltip
    if (widget.tooltipBuilder != null) {
      return Tooltip(
        message: useRichTooltip ? null : widget.label,
        richMessage: useRichTooltip
            ? WidgetSpan(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: widget.tooltipBuilder!(theme),
                ),
              )
            : null,
        preferBelow: true,
        verticalOffset: 20,
        waitDuration: const Duration(milliseconds: 300),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.2),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        padding: const EdgeInsets.all(12),
        child: button,
      );
    }

    return button;
  }
}

/// 复制图标按钮
class _CopyIconButton extends StatefulWidget {
  final String content;
  final Color color;

  const _CopyIconButton({
    required this.content,
    required this.color,
  });

  @override
  State<_CopyIconButton> createState() => _CopyIconButtonState();
}

class _CopyIconButtonState extends State<_CopyIconButton> {
  bool _isHovering = false;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovering = true),
      onExit: (_) => setState(() => _isHovering = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () async {
          await Clipboard.setData(ClipboardData(text: widget.content));
          if (context.mounted) {
            AppToast.success(context, l10n.common_copied);
          }
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: _isHovering
                ? widget.color.withValues(alpha: 0.15)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Icon(
            Icons.copy_rounded,
            size: 14,
            color: _isHovering ? widget.color : widget.color.withValues(alpha: 0.6),
          ),
        ),
      ),
    );
  }
}