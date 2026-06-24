import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import '../core/editor_state.dart';
import '../core/input_handler.dart';
import 'layer_painter.dart';
import 'stroke_preview_painter.dart'; // 🌟 新增：引入笔画预览组件

/// 编辑器画布组件
/// 处理绑制、手势和键盘交互
class EditorCanvas extends StatefulWidget {
  final EditorState state;
  final bool suppressSelectionOverlay;
  final bool showTransparentCanvasBackground; // 🌟 新增：透明背景参数
  final bool Function(Offset localPosition)? shouldSuppressPointerInput; // 🌟 新增：输入拦截回调

  const EditorCanvas({
    super.key,
    required this.state,
    this.suppressSelectionOverlay = false,
    this.showTransparentCanvasBackground = false, // 🌟 新增
    this.shouldSuppressPointerInput, // 🌟 新增
  });

  @override
  State<EditorCanvas> createState() => _EditorCanvasState();
}

class _EditorCanvasState extends State<EditorCanvas>
    with SingleTickerProviderStateMixin {
  /// 输入处理器
  late InputHandler _inputHandler;

  /// 选区动画控制器
  late AnimationController _selectionAnimationController;

  /// 焦点节点
  final FocusNode _focusNode = FocusNode();

  // ==========================================
  // 🌟 终极防误触：多指追踪 + 容差滑动 + 完美中断回退
  // ==========================================
  final Set<int> _activePointers = {};
  bool _isDrawing = false;

  Timer? _touchDelayTimer;
  PointerDownEvent? _pendingDownEvent;
  final List<PointerMoveEvent> _pendingMoves = [];

  // 🌟 新增：记录正在画画的那根手指，为了在双指落下时完美中断线条
  int? _drawingPointerId;
  Offset? _lastDrawingPosition;

  // 🌟 新增：合并自PC版，记录被外部UI拦截的手指
  final Set<int> _suppressedPointers = <int>{};

  static const double _kTouchSlop = 8.0;
  
  void _commitDrawing() {
    if (_pendingDownEvent != null && _activePointers.length == 1) {
      _isDrawing = true;
      _drawingPointerId = _pendingDownEvent!.pointer;
      _lastDrawingPosition = _pendingDownEvent!.position;
      
      _inputHandler.handlePointerDown(_pendingDownEvent!);
      for (var move in _pendingMoves) {
        _inputHandler.handlePointerMove(move);
        _lastDrawingPosition = move.position;
      }
      _pendingDownEvent = null;
      _pendingMoves.clear();
    }
  }

  void _onPointerDown(PointerDownEvent event) {
    // 🌟 合并PC版逻辑：如果点在特定区域（如悬浮UI），直接拦截并忽略
    if ((event.buttons & kPrimaryButton) != 0 &&
        (widget.shouldSuppressPointerInput?.call(event.localPosition) ?? false)) {
      _suppressedPointers.add(event.pointer);
      widget.state.cancelStroke();
      return;
    }

    _activePointers.add(event.pointer);

    if (_activePointers.length == 1) {
      _pendingDownEvent = event;
      _pendingMoves.clear();
      // 250ms 黄金窗口期
      _touchDelayTimer = Timer(const Duration(milliseconds: 250), () {
        _commitDrawing();
      });
    } else if (_activePointers.length > 1) {
      // 第二根手指落下了！
      _touchDelayTimer?.cancel();
      _pendingDownEvent = null;
      _pendingMoves.clear();

      if (_isDrawing) {
        _isDrawing = false;
        // 🌟 核心修复：发送【第一根手指】的抬起事件，完美闭合当前线条！
        _inputHandler.handlePointerUp(PointerUpEvent(
          pointer: _drawingPointerId ?? event.pointer,
          position: _lastDrawingPosition ?? event.position,
        ));
        _drawingPointerId = null;
      }
    }
  }

  void _onPointerMove(PointerMoveEvent event) {
    // 🌟 合并PC版逻辑：拦截被忽略的手指
    if (_suppressedPointers.contains(event.pointer)) return;

    if (_activePointers.length > 1) return;

    if (_pendingDownEvent != null) {
      final distance = (event.position - _pendingDownEvent!.position).distance;
      if (distance > _kTouchSlop) {
        _touchDelayTimer?.cancel();
        _commitDrawing();
        _inputHandler.handlePointerMove(event);
        _lastDrawingPosition = event.position;
      } else {
        _pendingMoves.add(event);
      }
    } else if (_isDrawing && event.pointer == _drawingPointerId) {
      _inputHandler.handlePointerMove(event);
      _lastDrawingPosition = event.position;
    }
  }

  void _onPointerUp(PointerUpEvent event) {
    // 🌟 合并PC版逻辑：释放被忽略的手指
    if (_suppressedPointers.remove(event.pointer)) return;

    _activePointers.remove(event.pointer);

    if (_pendingDownEvent != null && _pendingDownEvent!.pointer == event.pointer) {
      _touchDelayTimer?.cancel();
      _commitDrawing();
    }

    if (_isDrawing && event.pointer == _drawingPointerId) {
      _isDrawing = false;
      _inputHandler.handlePointerUp(event);
      _drawingPointerId = null;
    }
  }

  void _onPointerCancel(PointerCancelEvent event) {
    // 🌟 合并PC版逻辑：释放被忽略的手指
    if (_suppressedPointers.remove(event.pointer)) return;

    _activePointers.remove(event.pointer);
    _touchDelayTimer?.cancel();
    _pendingDownEvent = null;
    _pendingMoves.clear();

    if (_isDrawing && event.pointer == _drawingPointerId) {
      _isDrawing = false;
      _inputHandler.handlePointerUp(PointerUpEvent(
        pointer: event.pointer,
        position: event.position,
      ));
      _drawingPointerId = null;
    }
  }


  @override
  void initState() {
    super.initState();

    // 初始化输入处理器
    _inputHandler = InputHandler(
      state: widget.state,
      focusNode: _focusNode,
      onStateChanged: () => setState(() {}),
    );

    // 初始化选区动画
    _selectionAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    )..repeat();

    // 添加硬件键盘监听
    HardwareKeyboard.instance.addHandler(_inputHandler.handleHardwareKey);
  }

  @override
  void dispose() {
    _touchDelayTimer?.cancel(); // 🌟 换成新名字
    HardwareKeyboard.instance.removeHandler(_inputHandler.handleHardwareKey);
    _selectionAnimationController.dispose();
    _focusNode.dispose();
    super.dispose();
  }
    
  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _inputHandler.handleKeyEvent,
      child: Listener(
        onPointerSignal: _inputHandler.handlePointerSignal,
        onPointerHover: _inputHandler.handlePointerHover,
        
        // 🌟 核心替换：接管这里的触摸事件，接入熔断机制！
        onPointerDown: _onPointerDown,
        onPointerUp: _onPointerUp,
        onPointerMove: _onPointerMove,
        onPointerCancel: _onPointerCancel, // 新增取消事件防异常
        
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          dragStartBehavior: DragStartBehavior.down,
          onScaleStart: _inputHandler.handleScaleStart,

          onScaleUpdate: _inputHandler.handleScaleUpdate,
          onScaleEnd: _inputHandler.handleScaleEnd,
          child: MouseRegion(
            cursor: _inputHandler.getCursor(),
            onExit: _inputHandler.handleMouseExit,
            child: LayoutBuilder(
              builder: (context, constraints) {
                // 更新视口尺寸
                widget.state.canvasController.setViewportSize(
                  Size(constraints.maxWidth, constraints.maxHeight),
                );

                // 使用 toolNotifier 监听工具切换（轻量级，不触发画布重绘）
                // renderNotifier 由 CustomPainter 内部监听
                return ValueListenableBuilder<String?>(
                  valueListenable: widget.state.toolNotifier,
                  builder: (context, toolId, _) {
                    // Alt 模式或拾色器工具时都显示拾色器界面
                    final isColorPicker = toolId == 'color_picker' ||
                        _inputHandler.keyboard.isAltPressed;
                    final cursorPosition = _inputHandler.cursorPosition;

                    return ClipRect(
                      child: Stack(
                        children: [
                          // 背景 - 独立重绘区域（静态内容）
                          Positioned.fill(
                            child: RepaintBoundary(
                              child: Container(
                                color: Colors.grey.shade800,
                              ),
                            ),
                          ),

                          // 图层绘制 - 不使用 RepaintBoundary 以避免缓存问题
                          Positioned.fill(
                            child: CustomPaint(
                              painter: LayerPainter(
                                state: widget.state,
                                showTransparentCanvasBackground: widget.showTransparentCanvasBackground, // 🌟 传入透明背景参数
                              ),
                            ),
                          ),

                          // 🌟 新增PC版优化：当前笔画预览 - 仅实时预览，不写入图层数据
                          Positioned.fill(
                            child: RepaintBoundary(
                              child: CustomPaint(
                                painter: StrokePreviewPainter(
                                  state: widget.state,
                                ),
                                willChange: true,
                              ),
                            ),
                          ),
                          
                          // 选区绘制 - 独立重绘区域（有动画，频繁更新）
                          Positioned.fill(
                            child: RepaintBoundary(
                              child: CustomPaint(
                                painter: SelectionPainter(
                                  state: widget.state,
                                  animation: _selectionAnimationController,
                                  suppressSelectionOverlay:
                                      widget.suppressSelectionOverlay,
                                ),
                              ),
                            ),
                          ),

                          // 光标绘制 - 高频更新，不使用 RepaintBoundary
                          // Alt 模式下不显示笔刷光标（显示系统精确光标）
                          if (cursorPosition != null && !isColorPicker)
                            Positioned.fill(
                              child: CustomPaint(
                                painter: CursorPainter(
                                  state: widget.state,
                                  cursorPosition: cursorPosition,
                                ),
                                willChange: true,
                              ),
                            ),

                          // 拾色器预览
                          if (isColorPicker) ..._buildColorPickerOverlayList(),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  /// 构建拾色器预览覆盖层列表
  List<Widget> _buildColorPickerOverlayList() {
    final tool = widget.state.currentTool;
    if (tool == null) return const [];

    final cursor = tool.buildCursor(
      widget.state,
      screenCursorPosition: _inputHandler.cursorPosition,
    );
    if (cursor == null) return const [];

    return [cursor];
  }
}
