import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nai_launcher/presentation/providers/global_library_provider.dart';
import 'package:nai_launcher/presentation/widgets/autocomplete/generic_suggestion_tile.dart';
import '../../../core/utils/alias_parser.dart';
import '../../providers/locale_provider.dart';
import 'autocomplete_controller.dart';
import 'autocomplete_strategy.dart';
import 'autocomplete_utils.dart';
import 'generic_autocomplete_overlay.dart';
import 'strategies/alias_strategy.dart';
import 'strategies/cooccurrence_strategy.dart';
import 'strategies/local_tag_strategy.dart';

/// 自动补全包装器
///
/// 为任意输入组件提供自动补全功能
/// 通过策略模式支持不同的数据源
///
/// 使用示例：
/// ```dart
/// // 本地标签补全
/// AutocompleteWrapper(
///   controller: _controller,
///   strategy: LocalTagStrategy.create(ref, config),
///   child: ThemedInput(controller: _controller),
/// )
///
/// // 本地标签 + 别名补全
/// AutocompleteWrapper(
///   controller: _controller,
///   strategy: CompositeStrategy(
///     strategies: [
///       LocalTagStrategy.create(ref, config),
///       AliasStrategy.create(ref),
///     ],
///     strategySelector: defaultStrategySelector,
///   ),
///   child: ThemedInput(controller: _controller),
/// )
/// ```
class AutocompleteWrapper extends ConsumerStatefulWidget {
  /// 被包装的输入组件
  final Widget child;

  /// 文本控制器
  final TextEditingController controller;

  /// 焦点节点（可选，如果不提供则自动管理）
  final FocusNode? focusNode;

  /// 补全策略（同步）
  final AutocompleteStrategy? strategy;

  /// 异步补全策略（优先于 strategy）
  final Future<AutocompleteStrategy>? asyncStrategy;

  /// 是否启用自动补全
  final bool enabled;

  /// 文本变化回调
  final ValueChanged<String>? onChanged;

  /// 选择补全建议后的回调（传递更新后的完整文本）
  final ValueChanged<String>? onSuggestionSelected;

  /// 文本样式（用于计算光标位置）
  final TextStyle? textStyle;

  /// 内边距（用于计算光标位置）
  final EdgeInsetsGeometry? contentPadding;

  /// 最大行数（用于判断是否为多行输入框）
  final int? maxLines;

  /// 是否扩展填满可用空间
  final bool expands;

  const AutocompleteWrapper({
    super.key,
    required this.child,
    required this.controller,
    this.strategy,
    this.asyncStrategy,
    this.focusNode,
    this.enabled = true,
    this.onChanged,
    this.onSuggestionSelected,
    this.textStyle,
    this.contentPadding,
    this.maxLines,
    this.expands = false,
  }) : assert(strategy != null || asyncStrategy != null, '必须提供 strategy 或 asyncStrategy');

  /// 便捷构造：使用本地标签策略
  factory AutocompleteWrapper.localTag({
    Key? key,
    required Widget child,
    required TextEditingController controller,
    required WidgetRef ref,
    AutocompleteConfig config = const AutocompleteConfig(),
    FocusNode? focusNode,
    bool enabled = true,
    ValueChanged<String>? onChanged,
    ValueChanged<String>? onSuggestionSelected,
    TextStyle? textStyle,
    EdgeInsetsGeometry? contentPadding,
    int? maxLines,
    bool expands = false,
  }) {
    return AutocompleteWrapper(
      key: key,
      controller: controller,
      asyncStrategy: LocalTagStrategy.create(ref, config),
      focusNode: focusNode,
      enabled: enabled,
      onChanged: onChanged,
      onSuggestionSelected: onSuggestionSelected,
      textStyle: textStyle,
      contentPadding: contentPadding,
      maxLines: maxLines,
      expands: expands,
      child: child,
    );
  }

  /// 便捷构造：使用本地标签 + 别名策略
  factory AutocompleteWrapper.withAlias({
    Key? key,
    required Widget child,
    required TextEditingController controller,
    required WidgetRef ref,
    AutocompleteConfig config = const AutocompleteConfig(),
    FocusNode? focusNode,
    bool enabled = true,
    ValueChanged<String>? onChanged,
    ValueChanged<String>? onSuggestionSelected,
    TextStyle? textStyle,
    EdgeInsetsGeometry? contentPadding,
    int? maxLines,
    bool expands = false,
  }) {
    return AutocompleteWrapper(
      key: key,
      controller: controller,
      asyncStrategy: LocalTagStrategy.create(ref, config).then(
        (localTagStrategy) => CompositeStrategy(
          strategies: [
            localTagStrategy,
            AliasStrategy.create(ref),
            GlobalLibraryStrategy(ref), // 🌟 新增：把全局词库策略加进去！
          ],
          strategySelector: defaultStrategySelector,
        ),
      ),
      focusNode: focusNode,
      enabled: enabled,
      onChanged: onChanged,
      onSuggestionSelected: onSuggestionSelected,
      textStyle: textStyle,
      contentPadding: contentPadding,
      maxLines: maxLines,
      expands: expands,
      child: child,
    );
  }

  @override
  ConsumerState<AutocompleteWrapper> createState() =>
      _AutocompleteWrapperState();
}

/// 默认策略选择器
///
/// 策略优先级：
/// 1. 别名模式（<xxx>）- 最高优先级
/// 2. 共现标签推荐（tag, 且后面没有新输入）- 中等优先级
/// 3. 本地标签搜索（用户正在输入）- 默认
AutocompleteStrategy? defaultStrategySelector(
  List<AutocompleteStrategy> strategies,
  String text,
  int cursorPosition,
) {
  // 1. 优先检测别名模式
  final (isTypingAlias, _, _) = AliasParser.detectPartialAlias(text, cursorPosition);
  if (isTypingAlias) {
    return _findStrategyByType<AliasStrategy>(strategies);
  }

  // 🌟 2. 核心新增：检测全局词库模式 (以 @ 触发)
  if (cursorPosition > 0) {
    final beforeCursor = text.substring(0, cursorPosition);
    // 匹配 @ 后面跟着非空格、非逗号的字符
    if (RegExp(r'#([^,，]*)$').hasMatch(beforeCursor)) {
      return _findStrategyByType<GlobalLibraryStrategy>(strategies);
    }
  }

  // 3. 检测共现标签推荐条件
  if (_shouldTriggerCooccurrence(text, cursorPosition)) {
    return _findStrategyByType<CooccurrenceStrategy>(strategies);
  }

  // 4. 默认使用本地标签策略
  return _findStrategyByType<LocalTagStrategy>(strategies) ??
      (strategies.isNotEmpty ? strategies.first : null);
}

/// 按类型查找策略
T? _findStrategyByType<T extends AutocompleteStrategy>(
  List<AutocompleteStrategy> strategies,
) {
  for (final strategy in strategies) {
    if (strategy is T) return strategy;
  }
  return null;
}

/// 检测是否应该触发共现标签推荐
/// 条件：光标前有 "tag," 模式且后面没有新输入
bool _shouldTriggerCooccurrence(String text, int cursorPosition) {
  if (cursorPosition <= 0 || cursorPosition > text.length) {
    return false;
  }

  final beforeCursor = text.substring(0, cursorPosition);
  final lastCommaIndex = _findLastComma(beforeCursor);

  // 必须有逗号才触发
  if (lastCommaIndex < 0) return false;

  // 逗号后到光标前必须为空（只有空白字符）
  final afterComma = beforeCursor.substring(lastCommaIndex + 1);
  if (afterComma.trim().isNotEmpty) return false;

  // 提取逗号前面的标签
  final tag = _extractTagBeforeComma(beforeCursor, lastCommaIndex);
  return tag.length >= 2;
}

/// 查找最后一个逗号位置
int _findLastComma(String text) {
  for (var i = text.length - 1; i >= 0; i--) {
    final char = text[i];
    if (char == ',' || char == '，') return i;
  }
  return -1;
}

/// 提取逗号前的标签文本
String _extractTagBeforeComma(String text, int commaIndex) {
  var prevSeparatorIndex = -1;
  for (var i = commaIndex - 1; i >= 0; i--) {
    final char = text[i];
    if (char == ',' || char == '，' || char == '|') {
      prevSeparatorIndex = i;
      break;
    }
  }

  var tag = text.substring(prevSeparatorIndex + 1, commaIndex).trim();

  // 移除权重语法前缀
  final weightMatch = RegExp(r'^-?(?:\d+\.?\d*|\.\d+)::').firstMatch(tag);
  if (weightMatch != null) {
    tag = tag.substring(weightMatch.end);
  }

  // 移除括号前缀
  return tag.replaceAll(RegExp(r'^[\{\[\(]+'), '').trim();
}

// 🌟 混入 WidgetsBindingObserver 用于监听键盘弹起/收起事件
class _AutocompleteWrapperState extends ConsumerState<AutocompleteWrapper> with WidgetsBindingObserver {
  late FocusNode _focusNode; 
  bool _ownsFocusNode = false;
  bool _showSuggestions = false;
  int _selectedIndex = -1;
  OverlayEntry? _overlayEntry;
  final LayerLink _layerLink = LayerLink();
  final ScrollController _scrollController = ScrollController();

  // 用于防抖隐藏菜单的计时器
  Timer? _hideTimer;

  // 防止键盘事件重复处理（选择建议后短暂忽略键盘事件）
  bool _isSelecting = false;

  // 用于防抖文本变化触发的搜索
  Timer? _searchDebounceTimer;

  // 防抖延迟时间
  static const Duration _searchDebounceDelay = Duration(milliseconds: 50);

  // 异步策略加载
  AutocompleteStrategy? _resolvedStrategy;

  AutocompleteStrategy? get _effectiveStrategy =>
      widget.strategy ?? _resolvedStrategy;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this); // 🌟 注册监听
    _initFocusNode();
    widget.controller.addListener(_onTextChanged);
    _initStrategy();
  }

  void _initStrategy() {
    if (widget.strategy != null) {
      _resolvedStrategy = widget.strategy;
      _resolvedStrategy!.addListener(_onStrategyChanged);
    } else if (widget.asyncStrategy != null) {
      widget.asyncStrategy!.then((strategy) {
        if (mounted) {
          setState(() {
            _resolvedStrategy = strategy;
          });
          strategy.addListener(_onStrategyChanged);
        }
      });
    }
  }

  void _initFocusNode() {
    if (widget.focusNode != null) {
      _focusNode = widget.focusNode!;
    } else {
      _focusNode = FocusNode();
      _ownsFocusNode = true;
    }
    _focusNode.addListener(_onFocusChanged);
  }

  @override
  void didUpdateWidget(AutocompleteWrapper oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onTextChanged);
      widget.controller.addListener(_onTextChanged);
    }
    if (oldWidget.focusNode != widget.focusNode) {
      _focusNode.removeListener(_onFocusChanged);
      if (_ownsFocusNode) {
        _focusNode.dispose();
      }
      _initFocusNode();
    }
    if (oldWidget.strategy != widget.strategy ||
        oldWidget.asyncStrategy != widget.asyncStrategy) {
      oldWidget.strategy?.removeListener(_onStrategyChanged);
      _resolvedStrategy?.removeListener(_onStrategyChanged);
      _initStrategy();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this); // 🌟 注销监听
    _hideTimer?.cancel();
    _searchDebounceTimer?.cancel();
    _removeOverlay();
    _focusNode.removeListener(_onFocusChanged);
    widget.controller.removeListener(_onTextChanged);
    widget.strategy?.removeListener(_onStrategyChanged);
    _resolvedStrategy?.removeListener(_onStrategyChanged);
    _scrollController.dispose();
    if (_ownsFocusNode) {
      _focusNode.dispose();
    }
    super.dispose();
  }

  // 🌟 新增：当键盘弹起或收起（屏幕尺寸变化）时，强制菜单重绘以自适应高度，防止消失！
  @override
  void didChangeMetrics() {
    if (_showSuggestions) {
      _overlayEntry?.markNeedsBuild();
    }
  }

  void _onFocusChanged() {
    if (!_focusNode.hasFocus) {
      // 延迟隐藏，给点击事件处理留出时间
      // 如果点击的是 Overlay 中的建议项，点击事件会在失去焦点后处理
      Future.delayed(const Duration(milliseconds: 150), () {
        if (mounted && !_focusNode.hasFocus) {
          _hideSuggestions();
        }
      });
    }
  }

  void _onTextChanged() {
    if (!widget.enabled) return;

    final text = widget.controller.text;
    final cursorPosition = widget.controller.selection.baseOffset;

    // 检查是否正在进行 IME 组合输入
    final composing = widget.controller.value.composing;
    if (composing.isValid && !composing.isCollapsed) {
      widget.onChanged?.call(text);
      return;
    }

    // 取消之前的防抖计时器
    _searchDebounceTimer?.cancel();

    // 使用防抖延迟搜索，避免快速连续变化（如长按滑动选择文本）时频繁触发
    _searchDebounceTimer = Timer(_searchDebounceDelay, () {
      if (!mounted) return;
      // 委托给策略处理搜索
      _effectiveStrategy?.search(text, cursorPosition);
    });

    widget.onChanged?.call(text);
  }

  void _onStrategyChanged() {
    // 取消之前的隐藏计时器
    if (_hideTimer?.isActive == true) {
      _hideTimer?.cancel();
    }

    final strategy = _effectiveStrategy;
    if (strategy == null) return;

    if (strategy.hasSuggestions) {
      // 有建议时确保取消隐藏计时器
      if (_hideTimer?.isActive == true) {
        _hideTimer?.cancel();
      }
      if (!_showSuggestions) {
        _showSuggestionsOverlay();
      }
      // 确保 selectedIndex 在有效范围内
      final suggestionsLength = strategy.suggestions.length;
      if (_selectedIndex >= suggestionsLength) {
        _selectedIndex = suggestionsLength > 0 ? 0 : -1;
      } else if (_selectedIndex < 0 && suggestionsLength > 0) {
        _selectedIndex = 0;
      }
    } else if (!strategy.isLoading && _showSuggestions) {
      // 延迟隐藏，给策略切换留出时间
      // 如果150ms内又有新建议，取消隐藏
      _hideTimer = Timer(const Duration(milliseconds: 300), () {
        if (mounted && !_effectiveStrategy!.hasSuggestions && _showSuggestions) {
          _hideSuggestions();
        }
      });
    }
    setState(() {});
    _overlayEntry?.markNeedsBuild();
  }

  void _showSuggestionsOverlay() {
    if (_showSuggestions) {
      _overlayEntry?.markNeedsBuild();
      return;
    }

    setState(() {
      _showSuggestions = true;
      _selectedIndex = 0;
    });

    _overlayEntry = _createOverlayEntry();
    Overlay.of(context).insert(_overlayEntry!);
  }

  void _hideSuggestions() {
    if (!_showSuggestions) {
      return;
    }

    // 如果选择建议期间，不要隐藏（避免清空刚加载的共现策略）
    if (_isSelecting) {
      return;
    }

    setState(() {
      _showSuggestions = false;
      _selectedIndex = -1;
    });

    _removeOverlay();
    _effectiveStrategy?.clear();
  }

  void _removeOverlay() {
    _overlayEntry?.remove();
    _overlayEntry = null;
  }

  OverlayEntry _createOverlayEntry() {
    final locale = ref.read(localeNotifierProvider);

    return OverlayEntry(
      builder: (context) {
        final renderBox = this.context.findRenderObject() as RenderBox?;
        if (renderBox == null) {
          return const SizedBox.shrink();
        }
        final size = renderBox.size;

        final isMultiline = widget.expands || (widget.maxLines ?? 1) > 1;
        final cursorOffset = isMultiline
            ? AutocompleteUtils.getCursorOffset(
                context: this.context,
                controller: widget.controller,
                textStyle: widget.textStyle,
                contentPadding: widget.contentPadding,
                maxLines: widget.maxLines,
                expands: widget.expands,
              )
            : null;

        final offset = isMultiline && cursorOffset != null
            ? Offset(
                cursorOffset.dx.clamp(0.0, size.width > 300 ? size.width - 300 : 0.0),
                cursorOffset.dy + 4,
              )
            : Offset(0, size.height + 4);
            
        final strategy = _effectiveStrategy;
        if (strategy == null) {
          return const SizedBox.shrink();
        }
        final suggestions = strategy.suggestions;
        final suggestionsLength = suggestions.length;
        final config = _getConfig();

        // ==========================================
        // 🌟 终极修复：绕过 MediaQuery，直接向底层请求真实的键盘高度！
        // ==========================================
        final globalOffset = renderBox.localToGlobal(Offset.zero);
        final menuTopY = globalOffset.dy + offset.dy; // 菜单顶部的绝对 Y 坐标
        
        // 🌟 获取系统底层的真实屏幕数据（不受 Overlay 隔离影响）
        final view = View.of(context);
        final screenHeight = view.physicalSize.height / view.devicePixelRatio;
        final keyboardHeight = view.viewInsets.bottom / view.devicePixelRatio;
        
        // 可用高度 = 屏幕总高 - 键盘高度 - 菜单起点Y坐标 - 底部8像素安全留白
        // 🌟 最小值必须设为 0.0！这样菜单底部就会被键盘严丝合缝地“顶住”，绝不会插进键盘底下了！
        final maxAvailableHeight = (screenHeight - keyboardHeight - menuTopY - 8.0).clamp(0.0, 400.0);
        // ==========================================

        return Positioned(
          width: size.width.clamp(280.0, 400.0),
          child: CompositedTransformFollower(
            link: _layerLink,
            showWhenUnlinked: false,
            offset: offset,
            child: Listener(
              onPointerSignal: (event) {
                // ... 滚轮逻辑保持不变 ...       
              },
              child: GenericAutocompleteOverlay(
                maxHeight: maxAvailableHeight, // 🌟 传入计算好的自适应高度！
                suggestions: suggestions
                    .map((item) => strategy.toSuggestionData(item))
                    .toList(),
                selectedIndex: _selectedIndex,
                onSelect: (index) {
                  if (index >= 0 && index < suggestions.length) {
                    _selectSuggestion(suggestions[index]);
                  }
                },
                config: config,
                isLoading: strategy.isLoading,
                scrollController: _scrollController,
                languageCode: locale.languageCode,
              ),
            ),
          ),
        );
      },
    );
  }

  /// 获取配置（从策略中提取或使用默认配置）
  AutocompleteConfig _getConfig() {
    final strategy = _effectiveStrategy;
    if (strategy == null) return const AutocompleteConfig();

    if (strategy is LocalTagStrategy) {
      return strategy.config;
    }
    if (strategy is CompositeStrategy) {
      final localTagStrategy = strategy.getStrategy<LocalTagStrategy>();
      if (localTagStrategy != null) {
        return localTagStrategy.config;
      }
    }
    return const AutocompleteConfig();
  }

  void _selectSuggestion(dynamic suggestion) {
    // 防止重复处理
    if (_isSelecting) {
      return;
    }
    _isSelecting = true;

    final strategy = _effectiveStrategy;
    if (strategy == null) {
      _isSelecting = false;
      return;
    }

    final text = widget.controller.text;
    final cursorPosition = widget.controller.selection.baseOffset;

    if (cursorPosition < 0 || cursorPosition > text.length) {
      _isSelecting = false;
      return;
    }

    final (newText, newCursorPosition) = strategy.applySuggestion(
      suggestion,
      text,
      cursorPosition,
    );

    widget.controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: newCursorPosition),
    );

    _hideSuggestions();

    // 通知外部选择了补全建议
    widget.onSuggestionSelected?.call(newText);

    // 延迟重置标志，防止同一键盘事件触发多次
    // 延长到 300ms，确保共现菜单显示后不会立即被选择
    Future.delayed(const Duration(milliseconds: 300), () {
      _isSelecting = false;
    });
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    // 正在选择建议时，忽略键盘事件（防止重复触发）
    if (_isSelecting) {
      return KeyEventResult.handled;
    }

    // 补全菜单未显示时，不阻止任何键
    if (!_showSuggestions) {
      return KeyEventResult.ignored;
    }

    final strategy = _effectiveStrategy;
    if (strategy == null) return KeyEventResult.ignored;

    final suggestions = strategy.suggestions;
    final suggestionsLength = suggestions.length;

    // 没有建议时，不阻止任何键
    if (suggestionsLength == 0) {
      return KeyEventResult.ignored;
    }

    // 只处理 KeyDownEvent 和 KeyRepeatEvent（长按）
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
        setState(() {
          _selectedIndex = (_selectedIndex + 1) % suggestionsLength;
        });
        _overlayEntry?.markNeedsBuild();
        _scrollToSelected();
        return KeyEventResult.handled;
      } else if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
        setState(() {
          _selectedIndex =
              _selectedIndex <= 0 ? suggestionsLength - 1 : _selectedIndex - 1;
        });
        _overlayEntry?.markNeedsBuild();
        _scrollToSelected();
        return KeyEventResult.handled;
      } else if (event.logicalKey == LogicalKeyboardKey.enter ||
          event.logicalKey == LogicalKeyboardKey.tab) {
        if (event is KeyDownEvent &&
            _selectedIndex >= 0 &&
            _selectedIndex < suggestionsLength) {
          _selectSuggestion(suggestions[_selectedIndex]);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      } else if (event.logicalKey == LogicalKeyboardKey.escape) {
        if (event is KeyDownEvent) {
          _hideSuggestions();
        }
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  void _scrollToSelected() {
    if (_selectedIndex < 0) return;
    if (!_scrollController.hasClients) return;

    const itemHeight = 32.0;
    final targetOffset = _selectedIndex * itemHeight;
    final maxOffset = _scrollController.position.maxScrollExtent;

    if (targetOffset < _scrollController.offset) {
      _scrollController.animateTo(
        targetOffset,
        duration: const Duration(milliseconds: 100),
        curve: Curves.easeOut,
      );
    } else if (targetOffset > _scrollController.offset + 200) {
      _scrollController.animateTo(
        (targetOffset - 200).clamp(0.0, maxOffset),
        duration: const Duration(milliseconds: 100),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // 如果未启用自动补全，直接返回子组件
    if (!widget.enabled) {
      return widget.child;
    }

    // 使用 Focus widget 拦截键盘事件
    // 只在补全菜单显示时注册 onKeyEvent，避免干扰系统快捷键（如 Win+V）
    return CompositedTransformTarget(
      link: _layerLink,
      child: Focus(
        skipTraversal: true,
        canRequestFocus: false,
        onKeyEvent: _showSuggestions
            ? (node, event) => _handleKeyEvent(node, event)
            : null,
        child: widget.child,
      ),
    );
  }
}

// ==========================================
// 🌟 新增：全局词库自动补全策略 (# 触发，支持智能分类，修复冒号截断)
// ==========================================
class GlobalLibraryStrategy extends AutocompleteStrategy<(String, String)> {
  final WidgetRef ref;
  List<(String, String)> _suggestions = [];

  List<(String, String)> _cachedTags = [];
  int _lastMapHash = 0;
  int _searchRequestId = 0;

  GlobalLibraryStrategy(this.ref);

  @override
  bool get isLoading => false;

  @override
  bool get hasSuggestions => _suggestions.isNotEmpty;

  @override
  List<(String, String)> get suggestions => _suggestions;

  @override
  void clear() {
    _suggestions = [];
    notifyListeners();
  }

  void _ensureCache() {
    final libraries = ref.read(globalLibraryProvider);
    if (libraries.hashCode != _lastMapHash) {
      _cachedTags = [];
      for (final entry in libraries.entries) {
        final libName = entry.key;
        final tags = entry.value.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty);
        _cachedTags.addAll(tags.map((t) => (t, libName)));
      }
      _lastMapHash = libraries.hashCode;
    }
  }

  int _inferCategory(String libName) {
    final name = libName.toLowerCase();
    if (name.contains('角色') || name.contains('人物') || name.contains('char')) return 1;
    if (name.contains('画师') || name.contains('作者') || name.contains('artist') || name.contains('画风')) return 4;
    if (name.contains('版权') || name.contains('作品') || name.contains('游戏') || name.contains('copy')) return 3;
    if (name.contains('元数据') || name.contains('meta')) return 5;
    return 2; 
  }

  @override
  Future<void> search(String text, int cursorPosition, {bool immediate = false}) async {
    final currentRequestId = ++_searchRequestId;

    if (cursorPosition <= 0 || cursorPosition > text.length) {
      clear();
      return;
    }

    final beforeCursor = text.substring(0, cursorPosition);
    final match = RegExp(r'#([^,，]*)$').firstMatch(beforeCursor);

    if (match == null) {
      clear();
      return;
    }

    final query = match.group(1)!.toLowerCase();

    if (query.length < 2) {
      clear();
      return;
    }

    if (!immediate) {
      await Future.delayed(const Duration(milliseconds: 500));
    }

    if (currentRequestId != _searchRequestId) {
      return;
    }

    _ensureCache();

    final searchTerms = query.split(RegExp(r'[ _]')).where((s) => s.isNotEmpty).toList();

    _suggestions = _cachedTags.where((item) {
      final normalized = item.$1.toLowerCase().replaceAll('_', ' ');
      return searchTerms.every((term) => normalized.contains(term));
    }).take(50).toList();

    notifyListeners();
  }

  @override
  SuggestionData toSuggestionData((String, String) item) {
    final rawTag = item.$1;
    final libName = item.$2;

    final parts = rawTag.split(RegExp(r'[:：]'));
    String commentStr = '';

    // 1. 剥离中文作为注释显示
    if (parts.length > 1) {
      String lastPart = parts.last.trim();
      if (RegExp(r'[\u4e00-\u9fa5]').hasMatch(lastPart)) {
        commentStr = lastPart;
        parts.removeLast();
      }
    }
    
    // 2. 剥离数字权重（直接丢弃，绝对不在补全菜单里显示）
    if (parts.length > 1) {
      String lastPart = parts.last.trim();
      if (int.tryParse(lastPart) != null) {
        parts.removeLast(); 
      }
    }

    String actualTag = parts.join(':').trim();

    if (actualTag.length > 26) {
      actualTag = '${actualTag.substring(0, 23)}...';
    }
    
    if (commentStr.isEmpty) {
      commentStr = '[$libName]';
    } else if (commentStr.length > 15) {
      commentStr = '${commentStr.substring(0, 14)}...';
    }

    return SuggestionData(
      tag: actualTag,
      translation: commentStr,
      category: _inferCategory(libName), 
      count: 0,
    );
  }

  @override
  (String, int) applySuggestion((String, String) item, String text, int cursorPosition) {
    final beforeCursor = text.substring(0, cursorPosition);
    final afterCursor = text.substring(cursorPosition);

    final match = RegExp(r'#([^,，]*)$').firstMatch(beforeCursor);
    if (match == null) return (text, cursorPosition);

    // 🌟 核心：输入到文本框时，剥离中文和权重，只留纯标签
    final parts = item.$1.split(RegExp(r'[:：]'));
    if (parts.length > 1) {
      if (RegExp(r'[\u4e00-\u9fa5]').hasMatch(parts.last.trim())) {
        parts.removeLast();
      }
    }
    if (parts.length > 1) {
      if (int.tryParse(parts.last.trim()) != null) {
        parts.removeLast();
      }
    }
    String actualTag = parts.join(':').trim();

    final newBefore = beforeCursor.substring(0, match.start) + actualTag + ', ';
    return (newBefore + afterCursor, newBefore.length);
  }
}