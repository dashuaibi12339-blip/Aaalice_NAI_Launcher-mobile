import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/prompt_assistant_models.dart';
import 'prompt_assistant_custom_dialog.dart';

import '../../widgets/common/app_toast.dart';
import '../../../data/models/character/character_prompt.dart';
import '../../../data/models/tag_library/tag_library_entry.dart';
import '../../providers/fixed_tags_provider.dart';
import '../../providers/reverse_prompt_provider.dart';
import '../../providers/tag_library_page_provider.dart';
import '../../widgets/tag_library/tag_library_picker_dialog.dart';
import '../providers/prompt_assistant_config_provider.dart';
import '../providers/prompt_assistant_history_provider.dart';
import '../providers/prompt_assistant_state_provider.dart';
import '../services/prompt_assistant_service.dart';

class PromptAssistantOverlay extends ConsumerStatefulWidget {
  const PromptAssistantOverlay({
    super.key,
    required this.sessionId,
    required this.controller,
    this.onOpenSettings,
    this.enabled = true,
  });

  final String sessionId;
  final TextEditingController controller;
  final VoidCallback? onOpenSettings;
  final bool enabled;

  @override
  ConsumerState<PromptAssistantOverlay> createState() =>
      _PromptAssistantOverlayState();
}

class _PromptAssistantOverlayState extends ConsumerState<PromptAssistantOverlay>
    with SingleTickerProviderStateMixin {
  StreamSubscription? _streamSub;
  late final AnimationController _breathController;

  bool get _isDesktop {
    switch (defaultTargetPlatform) {
      case TargetPlatform.windows:
      case TargetPlatform.macOS:
      case TargetPlatform.linux:
        return true;
      default:
        return false;
    }
  }

  @override
  void initState() {
    super.initState();
    _breathController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _streamSub?.cancel();
    _breathController.dispose();
    super.dispose();
  }

  Future<void> _runTranslate() async {
    final inputText = _assistantInputText();
    await _runAction(
      '翻译中',
      inputText,
      (service, input) => service.translatePrompt(
        input,
        sessionId: widget.sessionId,
      ),
    );
  }

  Future<void> _runOptimize() async {
    final inputText = _assistantInputText();
    await _runAction(
      '优化中',
      inputText,
      (service, input) => service.optimizePrompt(
        input,
        sessionId: widget.sessionId,
      ),
    );
  }

    Future<void> _runCustom() async {
    final inputText = _assistantInputText();
    final provider = _activeProviderForTask(AssistantTaskType.custom);
    final result = await showDialog<PromptAssistantCustomDialogResult>(
      context: context,
      builder: (context) => PromptAssistantCustomDialog(
        currentPrompt: inputText,
        allowImages: provider?.allowImageInput ?? false,
      ),
    );
    if (result == null) {
      return;
    }
    if (result.images.isNotEmpty && provider?.allowImageInput != true) {
      if (mounted) {
        AppToast.warning(context, '当前自定义任务服务商未启用图片输入');
      }
      return;
    }
    await _runCustomAction(inputText, result);
  }

  ProviderConfig? _activeProviderForTask(AssistantTaskType taskType) {
    final config = ref.read(promptAssistantConfigProvider);
    final providerId = config.routing.providerIdFor(taskType);
    final enabledProviders = config.providers.where((p) => p.enabled).toList();
    if (enabledProviders.isEmpty) return null;
    return enabledProviders.cast<ProviderConfig?>().firstWhere(
          (provider) => provider?.id == providerId,
          orElse: () => enabledProviders.first,
        );
  }

  Future<void> _runCustomAction(
    String inputText,
    PromptAssistantCustomDialogResult result,
  ) async {
    final beforeText = widget.controller.text;
    ref
        .read(promptAssistantHistoryProvider.notifier)
        .push(widget.sessionId, beforeText);

    final stateNotifier = ref.read(promptAssistantStateProvider.notifier);
    stateNotifier.startProcessing(widget.sessionId, '自定义处理中');

    final service = ref.read(promptAssistantServiceProvider);
    final buffer = StringBuffer();

    await _streamSub?.cancel();
    _streamSub = service
        .customPrompt(
      inputText,
      sessionId: widget.sessionId,
      userRequest: result.userRequest,
      images: result.images,
    )
        .listen(
      (chunk) {
        if (chunk.done == true) return;
        final delta = chunk.delta as String? ?? '';
        if (delta.isEmpty) return;
        buffer.write(delta);
      },
      onError: (e) {
        stateNotifier.setError(widget.sessionId, e.toString());
        if (mounted) AppToast.error(context, '助手请求失败: $e');
      },
      onDone: () {
        if (buffer.isNotEmpty) {
          final finalText = buffer.toString();
          widget.controller.text = finalText;
          widget.controller.selection =
              TextSelection.collapsed(offset: widget.controller.text.length);
        }
        stateNotifier.finishProcessing(widget.sessionId);
        final afterText = widget.controller.text;
        ref.read(promptAssistantHistoryProvider.notifier).recordExternalChange(
              widget.sessionId,
              before: beforeText,
              after: afterText,
            );
        ref.read(promptAssistantHistoryProvider.notifier).push(
              widget.sessionId,
              afterText,
            );
      },
      cancelOnError: true,
    );
  }

  Future<void> _runCharacterReplace() async {
    final character = await _selectCharacterForReplacement();
    if (character == null) {
      return;
    }

    final inputText = _assistantInputText();
    await _runAction(
      '角色替换中',
      inputText,
      (service, input) => service.replaceCharacterPrompt(
        input,
        sessionId: widget.sessionId,
        characterName: character.name,
        characterPrompt: character.prompt,
      ),
    );
  }

  Future<CharacterPrompt?> _selectCharacterForReplacement() async {
    final character =
        ref.read(reversePromptCharacterProvider.notifier).selectedCharacter;
    if (character != null) {
      return character;
    }
    return await _pickReplacementCharacterFromLibrary();
  }

  Future<CharacterPrompt?> _pickReplacementCharacterFromLibrary() async {
    final entry = await showDialog<TagLibraryEntry>(
      context: context,
      builder: (context) => const TagLibraryPickerDialog(title: '选择替换目标角色'),
    );
    if (entry == null) {
      if (mounted) {
        AppToast.warning(context, '请先在反推角色库中添加有效角色');
      }
      return null;
    }

    ref.read(tagLibraryPageNotifierProvider.notifier).recordUsage(entry.id);
    final character = CharacterPrompt.create(
      name: entry.displayName,
      prompt: entry.content,
      thumbnailPath: entry.thumbnail,
    );
    ref
        .read(reversePromptCharacterProvider.notifier)
        .setReplacementCharacter(character);
    return character;
  }

  Future<void> _runAction(
    String label,
    String inputText,
    Stream<dynamic> Function(PromptAssistantService service, String input)
        builder,
  ) async {
    final text = inputText.trim();
    if (text.isEmpty) {
      if (mounted) AppToast.warning(context, '请输入提示词后再操作');
      return;
    }

    final beforeText = widget.controller.text;
    ref
        .read(promptAssistantHistoryProvider.notifier)
        .push(widget.sessionId, beforeText);

    final stateNotifier = ref.read(promptAssistantStateProvider.notifier);
    stateNotifier.startProcessing(widget.sessionId, label);

    final service = ref.read(promptAssistantServiceProvider);
    final buffer = StringBuffer();

    await _streamSub?.cancel();
    _streamSub = builder(service, text).listen(
      (chunk) {
        if (chunk.done == true) return;
        final delta = chunk.delta as String? ?? '';
        if (delta.isEmpty) return;
        buffer.write(delta);
      },
      onError: (e) {
        stateNotifier.setError(widget.sessionId, e.toString());
        if (mounted) AppToast.error(context, '助手请求失败: $e');
      },
      onDone: () {
        if (buffer.isNotEmpty) {
          final finalText = buffer.toString();
          widget.controller.text = finalText;
          widget.controller.selection =
              TextSelection.collapsed(offset: widget.controller.text.length);
        }
        stateNotifier.finishProcessing(widget.sessionId);
        final afterText = widget.controller.text;
        ref.read(promptAssistantHistoryProvider.notifier).recordExternalChange(
              widget.sessionId,
              before: beforeText,
              after: afterText,
            );
        ref.read(promptAssistantHistoryProvider.notifier).push(
              widget.sessionId,
              afterText,
            );
      },
      cancelOnError: true,
    );
  }

  String _assistantInputText() {
    return ref
        .read(fixedTagsNotifierProvider)
        .stripFromPrompt(widget.controller.text);
  }

  void _undo() {
    final value = ref
        .read(promptAssistantHistoryProvider.notifier)
        .undo(widget.sessionId, widget.controller.text);
    if (value != null) {
      widget.controller.text = value;
      widget.controller.selection =
          TextSelection.collapsed(offset: value.length);
    }
  }

  void _redo() {
    final value = ref
        .read(promptAssistantHistoryProvider.notifier)
        .redo(widget.sessionId, widget.controller.text);
    if (value != null) {
      widget.controller.text = value;
      widget.controller.selection =
          TextSelection.collapsed(offset: value.length);
    }
  }

  void _showHistory() {
    final stack = ref.read(promptAssistantHistoryProvider)[widget.sessionId];
    final history = stack?.history ?? const <String>[];
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return ListView.builder(
          itemCount: history.length,
          itemBuilder: (context, index) {
            final entry = history[history.length - 1 - index];
            return ListTile(
              title: Text(
                entry,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () {
                widget.controller.text = entry;
                widget.controller.selection =
                    TextSelection.collapsed(offset: entry.length);
                Navigator.pop(context);
              },
            );
          },
        );
      },
    );
  }

  void _showMenu([Offset? position]) {
    if (_isDesktop && position != null) {
      showMenu<String>(
        context: context,
        position: RelativeRect.fromLTRB(
          position.dx,
          position.dy,
          position.dx,
          position.dy,
        ),
        items: const [
          PopupMenuItem(value: 'assistant_settings', child: Text('助手设置')),
          PopupMenuItem(value: 'service_settings', child: Text('服务设置')),
          PopupMenuItem(value: 'rule_settings', child: Text('规则设置')),
          PopupMenuDivider(),
          PopupMenuItem(value: 'cancel', child: Text('取消当前任务')),
        ],
      ).then((value) async {
        if (value == 'cancel') {
          await ref.read(promptAssistantServiceProvider).cancelCurrentTask(
                sessionId: widget.sessionId,
              );
          ref
              .read(promptAssistantStateProvider.notifier)
              .finishProcessing(widget.sessionId);
        } else if (value == 'assistant_settings') {
          _showAssistantSettings();
        } else if (value == 'service_settings') {
          _showServiceSettings();
        } else if (value == 'rule_settings') {
          _showRuleSettings();
        }
      });
      return;
    }

    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.settings),
              title: const Text('助手设置'),
              onTap: () {
                Navigator.pop(context);
                _showAssistantSettings(); // 👈 独立弹窗1
              },
            ),
            ListTile(
              leading: const Icon(Icons.cloud),
              title: const Text('服务设置'),
              onTap: () {
                Navigator.pop(context);
                _showServiceSettings(); // 👈 独立弹窗2
              },
            ),
            ListTile(
              leading: const Icon(Icons.rule),
              title: const Text('规则设置'),
              onTap: () {
                Navigator.pop(context);
                _showRuleSettings(); // 👈 独立弹窗3
              },
            ),
            ListTile(
              leading: const Icon(Icons.stop_circle),
              title: const Text('取消当前任务'),
              onTap: () async {
                Navigator.pop(context);
                await ref
                    .read(promptAssistantServiceProvider)
                    .cancelCurrentTask(sessionId: widget.sessionId);
                ref
                    .read(promptAssistantStateProvider.notifier)
                    .finishProcessing(widget.sessionId);
              },
            ),
          ],
        ),
      ),
    );
  }

  // ================= 专属弹窗 1：助手设置 =================
  void _showAssistantSettings() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => Consumer(
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
              ],
            ),
          );
        },
      ),
    );
  }
  
  // ================= 专属弹窗 2：规则设置 =================
  void _showRuleSettings() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => Consumer(
        builder: (context, ref, _) {
          final config = ref.watch(promptAssistantConfigProvider);
          final notifier = ref.read(promptAssistantConfigProvider.notifier);
          final rules = [...config.rules]..sort((a, b) => a.order.compareTo(b.order));
          
          return SafeArea(
            child: DraggableScrollableSheet(
              initialChildSize: 0.6,
              minChildSize: 0.4,
              maxChildSize: 0.9,
              expand: false,
              builder: (context, scrollController) {
                return ListView(
                  controller: scrollController,
                  children: [
                    const Padding(
                      padding: EdgeInsets.all(16.0),
                      child: Text('规则快速切换', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                    ),
                    ...rules.map((rule) => SwitchListTile(
                      title: Text(rule.name),
                      subtitle: Text(
                        rule.content, 
                        maxLines: 1, 
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.outline),
                      ),
                      value: rule.enabled,
                      onChanged: (value) {
                        notifier.upsertRule(rule.copyWith(enabled: value));
                      },
                    )),
                  ],
                );
              },
            ),
          );
        },
      ),
    );
  }

  // ================= 专属弹窗 3：服务设置 =================
  void _showServiceSettings() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => Consumer(
        builder: (context, ref, _) {
          final config = ref.watch(promptAssistantConfigProvider);
          final notifier = ref.read(promptAssistantConfigProvider.notifier);
          final routing = config.routing;
          final providers = config.providers;
          
          // 辅助函数：构建单个任务的路由选择器（支持 Provider 和 Model 联动）
          Widget buildRoutingItem({
            required String title,
            required String currentProviderId,
            required String currentModel,
            required Function(String providerId, String model) onChanged,
          }) {
            // 找到该 provider 下的所有可用模型并去重
            final availableModels = config.models
                .where((m) => m.providerId == currentProviderId)
                .map((m) => m.name)
                .toSet()
                .toList();
                
            // 防止下拉框因为找不到当前值而报错
            if (currentModel.isNotEmpty && !availableModels.contains(currentModel)) {
              availableModels.insert(0, currentModel);
            }
            if (availableModels.isEmpty) {
              availableModels.add('default');
            }

            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 10.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      // 服务商下拉框
                      Expanded(
                        flex: 1,
                        child: DropdownButtonFormField<String>(
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: '服务商',
                            border: OutlineInputBorder(),
                            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          ),
                          value: providers.any((p) => p.id == currentProviderId) 
                              ? currentProviderId 
                              : (providers.isNotEmpty ? providers.first.id : null),
                          items: providers.map((p) => DropdownMenuItem(
                            value: p.id,
                            child: Text(p.name, overflow: TextOverflow.ellipsis),
                          )).toList(),
                          onChanged: (newProviderId) {
                            if (newProviderId != null) {
                              // 切换服务商时，自动默认选中该服务商的第一个模型
                              final newModels = config.models
                                  .where((m) => m.providerId == newProviderId)
                                  .map((m) => m.name)
                                  .toList();
                              final newModel = newModels.isNotEmpty ? newModels.first : 'default';
                              onChanged(newProviderId, newModel);
                            }
                          },
                        ),
                      ),
                      const SizedBox(width: 10),
                      // 模型下拉框
                      Expanded(
                        flex: 1,
                        child: DropdownButtonFormField<String>(
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: '模型',
                            border: OutlineInputBorder(),
                            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          ),
                          value: availableModels.contains(currentModel) ? currentModel : availableModels.first,
                          items: availableModels.map((m) => DropdownMenuItem(
                            value: m,
                            child: Text(m, overflow: TextOverflow.ellipsis),
                          )).toList(),
                          onChanged: (newModel) {
                            if (newModel != null) {
                              onChanged(currentProviderId, newModel);
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          }

          return SafeArea(
            child: DraggableScrollableSheet(
              initialChildSize: 0.7, // 默认占据 70% 屏幕高度
              minChildSize: 0.5,
              maxChildSize: 0.95,
              expand: false,
              builder: (context, scrollController) {
                return ListView(
                  controller: scrollController,
                  children: [
                    const Padding(
                      padding: EdgeInsets.all(16.0),
                      child: Text('任务路由设置', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                    ),
                    buildRoutingItem(
                      title: '✨ 提示词优化',
                      currentProviderId: routing.llmProviderId,
                      currentModel: routing.llmModel,
                      onChanged: (pId, model) => notifier.setRouting(routing.copyWith(llmProviderId: pId, llmModel: model)),
                    ),
                    buildRoutingItem(
                      title: '🌐 提示词翻译',
                      currentProviderId: routing.translateProviderId,
                      currentModel: routing.translateModel,
                      onChanged: (pId, model) => notifier.setRouting(routing.copyWith(translateProviderId: pId, translateModel: model)),
                    ),
                    buildRoutingItem(
                      title: '🔄 角色替换',
                      currentProviderId: routing.characterReplaceProviderId,
                      currentModel: routing.characterReplaceModel,
                      onChanged: (pId, model) => notifier.setRouting(routing.copyWith(characterReplaceProviderId: pId, characterReplaceModel: model)),
                    ),
                    buildRoutingItem(
                      title: '🖼️ 图像反推',
                      currentProviderId: routing.reverseProviderId,
                      currentModel: routing.reverseModel,
                      onChanged: (pId, model) => notifier.setRouting(routing.copyWith(reverseProviderId: pId, reverseModel: model)),
                    ),
                    // 👇 新增：自定义任务的路由设置
                    buildRoutingItem(
                      title: '🛠️ 自定义任务',
                      currentProviderId: routing.customProviderId,
                      currentModel: routing.customModel,
                      onChanged: (pId, model) => notifier.setRouting(routing.copyWith(customProviderId: pId, customModel: model)),
                    ),
                    const Divider(),
                    Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Text(
                        '💡 提示：如需添加新的自定义服务商 (如本地 Ollama) 或配置 API Key，请前往全局【设置】中进行操作。',
                        style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.outline),
                      ),
                    ),
                  ],
                );
              },
            ),
          );
        },
      ),
    );
  }
  
  @override
  Widget build(BuildContext context) {
    final config = ref.watch(promptAssistantConfigProvider);
    if (!widget.enabled || !config.enabled) {
      return const SizedBox.shrink();
    }
    if (_isDesktop && !config.desktopOverlayEnabled) {
      return const SizedBox.shrink();
    }

    final state = ref.watch(
      promptAssistantStateProvider.select(
        (m) => m[widget.sessionId] ?? const PromptAssistantOperationState(),
      ),
    );
    final history = ref.watch(
      promptAssistantHistoryProvider.select(
        (m) => m[widget.sessionId] ?? const PromptHistoryStack(),
      ),
    );
    final notifier = ref.read(promptAssistantStateProvider.notifier);

    final isExpanded = state.expanded;
    final isProcessing = state.processing;

    final child = Focus(
      onKeyEvent: (node, event) {
        if (!_isDesktop || event is! KeyDownEvent) {
          return KeyEventResult.ignored;
        }
        final isCtrl = HardwareKeyboard.instance.isControlPressed;
        final isShift = HardwareKeyboard.instance.isShiftPressed;
        if (isCtrl && isShift && event.logicalKey == LogicalKeyboardKey.keyE) {
          _runOptimize();
          return KeyEventResult.handled;
        }
        if (isCtrl && isShift && event.logicalKey == LogicalKeyboardKey.keyT) {
          _runTranslate();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: MouseRegion(
        onEnter: (_) => notifier.setHovering(widget.sessionId, true),
        onExit: (_) => notifier.setHovering(widget.sessionId, false),
        child: GestureDetector(
          onSecondaryTapDown: _isDesktop
              ? (details) => _showMenu(details.globalPosition)
              : null,
          child: AnimatedBuilder(
            animation: _breathController,
            builder: (context, child) {
              final breath = 0.85 + _breathController.value * 0.15;
              final glowBoost = state.hovering ? 1.35 : 1.0;
              return AnimatedScale(
                duration: const Duration(milliseconds: 140),
                scale: state.hovering ? 1.05 : 1.01,
                child: AnimatedContainer( 
                  duration: const Duration(milliseconds: 160),
                  padding: isExpanded
                      ? EdgeInsets.symmetric(horizontal: _isDesktop ? 6 : 2, vertical: 4)
                      : const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    color: isExpanded
                        ? Theme.of(context)
                            .colorScheme
                            .surfaceContainerHighest
                            .withValues(alpha:  state.hovering ? 0.9 : 0.82)
                        : Theme.of(context)
                            .colorScheme
                            .surface
                            .withValues(alpha:  0.12),
                    borderRadius: BorderRadius.circular(isExpanded ? 12 : 15),
                    boxShadow: [
                      BoxShadow(
                        color: Theme.of(context).colorScheme.primary.withValues(
                              alpha: isExpanded
                                  ? 0.09
                                  : (0.10 * breath * glowBoost),
                            ),
                        blurRadius: isExpanded ? 8 : (10 * breath * glowBoost),
                        spreadRadius: isExpanded ? 0 : 0.2,
                      ),
                    ],
                  ),
                  child: child,
                ),
              );
            },
            // 👇 从这里开始替换 👇
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              reverse: true, // 👈 核心细节：让按钮组始终靠右，操作更顺手
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _miniButton(
                    icon: isExpanded
                        ? Icons.close_rounded
                        : Icons.auto_awesome_rounded,
                    tooltip: isExpanded ? '收起助手' : '展开助手',
                    onPressed: () =>
                        notifier.setExpanded(widget.sessionId, !isExpanded),
                    iconColor: isExpanded
                        ? Theme.of(context).colorScheme.onSurface
                        : Theme.of(context)
                            .colorScheme
                            .onSurface
                            .withValues(alpha:  0.78),
                    iconSize: isExpanded ? 14 : 13,
                    buttonSize: isExpanded ? 24 : 26,
                  ),
                  if (isExpanded) ...[
                    _miniButton(
                      icon: Icons.history,
                      tooltip: '历史',
                      onPressed: _showHistory,
                    ),
                    _miniButton(
                      icon: Icons.undo,
                      tooltip: '撤销',
                      onPressed: history.canUndo ? _undo : null,
                    ),
                    _miniButton(
                      icon: Icons.redo,
                      tooltip: '重做',
                      onPressed: history.canRedo ? _redo : null,
                    ),
                    _miniButton(
                      icon: Icons.translate,
                      tooltip: '翻译',
                      onPressed: isProcessing ? null : _runTranslate,
                    ),
                    _miniButton(
                      icon: Icons.auto_fix_high,
                      tooltip: '优化',
                      onPressed: isProcessing ? null : _runOptimize,
                    ),
                    _miniButton(
                      icon: Icons.tune_rounded,
                      tooltip: '自定义',
                      onPressed: isProcessing ? null : _runCustom,
                    ),
                    _miniButton(
                      icon: Icons.manage_accounts_rounded,
                      tooltip: '角色替换',
                      onPressed: isProcessing ? null : _runCharacterReplace,
                    ),
                    _miniButton(
                      icon: isProcessing ? Icons.stop_circle : Icons.more_horiz,
                      tooltip: isProcessing ? '取消任务' : '菜单',
                      onPressed: isProcessing
                          ? () async {
                              await ref
                                  .read(promptAssistantServiceProvider)
                                  .cancelCurrentTask(
                                    sessionId: widget.sessionId,
                                  );
                              notifier.finishProcessing(widget.sessionId);
                            }
                          : () => _showMenu(),
                    ),
                  ],
                ],
              ),
            ),
            // 👆 到这里替换结束 👆
          ),
        ),
      ),
    );

    return Positioned(
      left: isExpanded ? 8 : null, // 👈 展开时左侧锚定，变得和提示词框一样长
      right: 8,
      bottom: 8,
      child: child,
    );
  }

  Widget _miniButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
    Color? iconColor,
    double iconSize = 14,
    double buttonSize = 24,
  }) {
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 180),
      showDuration: const Duration(milliseconds: 1200),
      verticalOffset: 12,
      preferBelow: false,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha:  0.88),
        borderRadius: BorderRadius.circular(8),
      ),
      textStyle: const TextStyle(
        color: Colors.white,
        fontSize: 12,
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: _isDesktop ? 0 : 0.5),
        child: IconButton(
          constraints: BoxConstraints.tightFor(
            width: _isDesktop ? buttonSize : 28, // 稍微加宽一点，更好按
            height: _isDesktop ? buttonSize : 34, // 高度保持舒适
          ),
          padding: EdgeInsets.zero,
          visualDensity: VisualDensity.compact,
          icon: Icon(icon, size: iconSize, color: iconColor),
          onPressed: onPressed,
        ),
      ),
    );
  }
}
