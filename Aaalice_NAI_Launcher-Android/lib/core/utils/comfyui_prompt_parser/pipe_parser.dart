import '../../../data/models/character/character_prompt.dart';
import 'models/comfyui_parse_result.dart';

/// 竖线及长文本格式解析器
///
/// 完美融合了 NAI Launcher 自定义的两种多角色格式：
/// 模式1: Scene Composition: xxx ; Character 1 Prompt: xxx ; Character 1 UC: xxx
/// 模式2: 全局提示词 | 角色1提示词 | 角色2提示词
class PipeParser {
  // 性别推断模式
  static final _malePattern = RegExp(
    r'\b(1boy|2boys|3boys|boy|male)\b',
    caseSensitive: false,
  );
  static final _femalePattern = RegExp(
    r'\b(1girl|2girls|3girls|girl|female)\b',
    caseSensitive: false,
  );

  /// 检测是否为支持的多角色格式
  static bool isPipeFormat(String input) {
    // 检查模式1
    if (RegExp(r'character[\s_]*\d+[\s_]*prompt[\s_]*:', caseSensitive: false).hasMatch(input)) {
      return true;
    }
    // 检查模式2
    return _splitPipeSegments(input).length > 1;
  }

  /// 核心解析入口 (双模式路由)
  static ComfyuiParseResult parse(String input) {
    if (input.trim().isEmpty) {
      return const ComfyuiParseResult(
        globalPrompt: '',
        characters: [],
        syntaxType: ComfyuiSyntaxType.pipe,
      );
    }

    // ================= 路由 1：尝试解析 Character X Prompt 模式 =================
    if (RegExp(r'character[\s_]*\d+[\s_]*prompt[\s_]*:', caseSensitive: false).hasMatch(input)) {
      final result1 = _parseFormat1(input);
      if (result1 != null) return result1;
    }

    // ================= 路由 2：回退到 | 竖线拆分模式 =================
    return _parseFormat2(input);
  }

  /// 模式 1：解析带有 Character X Prompt: 的长文本格式
  static ComfyuiParseResult? _parseFormat1(String text) {
    final regex = RegExp(r'character[\s_]*\d+[\s_]*prompt[\s_]*:', caseSensitive: false);
    final matches = regex.allMatches(text).toList();
    if (matches.isEmpty) return null;

    // 提取全局词 (Scene Composition)
    String basePrompt = text.substring(0, matches.first.start);
    basePrompt = basePrompt.replaceAll(RegExp(r'scene[\s_]*composition[\s_]*:\s*', caseSensitive: false), '');
    basePrompt = _cleanString(basePrompt);

    // 提取各个角色段落
    List<ParsedCharacter> characters = [];
    for (int i = 0; i < matches.length; i++) {
      int start = matches[i].end;
      int end = (i + 1 < matches.length) ? matches[i + 1].start : text.length;
      String charBlock = text.substring(start, end);
      characters.add(_extractCharacterDataSafe(charBlock));
    }

    if (characters.isEmpty) return null;
    return ComfyuiParseResult(
      globalPrompt: basePrompt,
      characters: characters,
      syntaxType: ComfyuiSyntaxType.pipe,
    );
  }

  /// 模式 2：解析带有 | 的竖线格式 (利用原作者的防误切算法)
  static ComfyuiParseResult _parseFormat2(String text) {
    final parts = _splitPipeSegments(text);
    if (parts.isEmpty) {
      return const ComfyuiParseResult(
        globalPrompt: '',
        characters: [],
        syntaxType: ComfyuiSyntaxType.pipe,
      );
    }

    final globalPrompt = _cleanString(parts[0]);

    // 合并可能被 | 误切断的元数据 (例如 | UC: xxx)
    List<String> mergedParts = [];
    for (int i = 1; i < parts.length; i++) {
      String currentPart = parts[i];
      bool isMetaData = RegExp(
        r'^\s*(?:centers?[\s_]*:|character[\s_]*\d+[\s_]*uc[\s_]*:|(?:^|[^a-zA-Z])uc[\s_]*:)', 
        caseSensitive: false
      ).hasMatch(currentPart);

      if (isMetaData && mergedParts.isNotEmpty) {
        mergedParts[mergedParts.length - 1] = '${mergedParts.last} | $currentPart';
      } else {
        mergedParts.add(currentPart);
      }
    }

    List<ParsedCharacter> characters = [];
    for (final rawBlock in mergedParts) {
      characters.add(_extractCharacterDataSafe(rawBlock));
    }

    return ComfyuiParseResult(
      globalPrompt: globalPrompt,
      characters: characters,
      syntaxType: ComfyuiSyntaxType.pipe,
    );
  }

  /// 统一的字符数据提取器 (精准提取并转换 centers 和 negativePrompt)
  static ParsedCharacter _extractCharacterDataSafe(String block) {
    ParsedPosition? parsedPos;
    String uc = '';
    String prompt = block;

    // 1. 提取并直接转换坐标 (A2 -> x:0.0, y:0.25)
    final centerRegex = RegExp(r'(?:^|[^a-zA-Z])centers?[\s_]*:[\s_]*([A-Za-z0-9]+)', caseSensitive: false);
    final centerMatch = centerRegex.firstMatch(prompt);
    if (centerMatch != null) {
      String center = centerMatch.group(1)!.toUpperCase();
      if (center.length >= 2) {
        int col = center[0].codeUnitAt(0) - 65; // A=0, B=1...
        int row = int.tryParse(center[1]) ?? 1; // 1, 2...
        if (col >= 0 && col <= 4 && row >= 1 && row <= 5) {
          parsedPos = ParsedPosition(x: col / 4.0, y: (row - 1) / 4.0);
        }
      }
      prompt = prompt.replaceRange(centerMatch.start, centerMatch.end, '');
    }

    // 2. 提取负面词 (兼容 Character X UC: 和 UC:)
    final ucRegex = RegExp(r'(?:character[\s_]*\d+[\s_]*uc[\s_]*:|(?:^|[^a-zA-Z])uc[\s_]*:)', caseSensitive: false);
    final ucMatch = ucRegex.firstMatch(prompt);
    if (ucMatch != null) {
      uc = prompt.substring(ucMatch.end);
      prompt = prompt.substring(0, ucMatch.start);
    }

    return ParsedCharacter(
      prompt: _cleanString(prompt),
      inferredGender: _inferGender(prompt),
      position: parsedPos, // 👈 直接塞入原生坐标对象
      negativePrompt: uc.isNotEmpty ? _cleanString(uc) : null, // 👈 塞入负面词
    );
  }

  /// 字符串清理辅助方法
  static String _cleanString(String input) {
    String res = input.replaceAll(';', '').replaceAll('|', '').trim();
    res = res.replaceFirst(RegExp(r'^[,_\s]+'), '');
    res = res.replaceFirst(RegExp(r'[,_\s]+$'), '');
    return res.trim();
  }

  /// 推断角色性别
  static CharacterGender _inferGender(String prompt) {
    final maleMatch = _malePattern.firstMatch(prompt);
    final femaleMatch = _femalePattern.firstMatch(prompt);

    if (maleMatch != null && femaleMatch != null) {
      return maleMatch.start < femaleMatch.start
          ? CharacterGender.male
          : CharacterGender.female;
    }

    if (maleMatch != null) return CharacterGender.male;

    return CharacterGender.female;
  }

  // =========================================================================
  // 下面全部是原作者强大的防误切拆分器，保持原样不动
  // =========================================================================
  static List<String> _splitPipeSegments(String input) {
    final parts = <String>[];
    var start = 0;
    var curlyDepth = 0;
    var squareDepth = 0;
    var parenDepth = 0;
    var inDoubleQuote = false;
    var escaped = false;

    for (var i = 0; i < input.length; i++) {
      final code = input.codeUnitAt(i);

      if (escaped) {
        escaped = false;
        continue;
      }

      if (code == 0x5C) {
        escaped = true;
        continue;
      }

      if (code == 0x22) {
        inDoubleQuote = !inDoubleQuote;
        continue;
      }

      if (inDoubleQuote) continue;

      switch (code) {
        case 0x7B: // {
          curlyDepth++;
          continue;
        case 0x7D: // }
          if (curlyDepth > 0) curlyDepth--;
          continue;
        case 0x5B: // [
          squareDepth++;
          continue;
        case 0x5D: // ]
          if (squareDepth > 0) squareDepth--;
          continue;
        case 0x28: // (
          parenDepth++;
          continue;
        case 0x29: // )
          if (parenDepth > 0) parenDepth--;
          continue;
        case 0x7C: // |
          if (curlyDepth == 0 &&
              squareDepth == 0 &&
              parenDepth == 0 &&
              _isPromptPipeDelimiter(input, i)) {
            final part = input.substring(start, i).trim();
            if (part.isNotEmpty) parts.add(part);
            start = i + 1;
          }
          continue;
      }
    }

    final tail = input.substring(start).trim();
    if (tail.isNotEmpty) parts.add(tail);
    return parts;
  }

  static bool _isPromptPipeDelimiter(String input, int index) {
    if (_isPipeAtLineStart(input, index)) return true;
    if (index == 0 || index == input.length - 1) return false;
    return _isWhitespace(input.codeUnitAt(index - 1)) &&
        _isWhitespace(input.codeUnitAt(index + 1));
  }

  static bool _isPipeAtLineStart(String input, int index) {
    for (var i = index - 1; i >= 0; i--) {
      final code = input.codeUnitAt(i);
      if (code == 0x0A || code == 0x0D) return true;
      if (!_isHorizontalWhitespace(code)) return false;
    }
    return false;
  }

  static bool _isWhitespace(int code) =>
      code == 0x20 || code == 0x09 || code == 0x0A || code == 0x0D;

  static bool _isHorizontalWhitespace(int code) => code == 0x20 || code == 0x09;
}