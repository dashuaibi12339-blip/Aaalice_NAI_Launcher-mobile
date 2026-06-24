import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

// ==========================================
// 🌟 顶层函数：运行在后台线程，绝不卡顿主 UI
// ==========================================
Map<String, String> _decodeLibraryMap(String data) {
  return Map<String, String>.from(jsonDecode(data));
}

String _encodeLibraryMap(Map<String, String> data) {
  return jsonEncode(data);
}

final globalLibraryProvider = StateNotifierProvider<GlobalLibraryNotifier, Map<String, String>>((ref) {
  return GlobalLibraryNotifier();
});

class GlobalLibraryNotifier extends StateNotifier<Map<String, String>> {
  GlobalLibraryNotifier() : super({}) { _load(); }

  Future<File> _getFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/my_global_library_v2.json');
  }

  Future<void> _load() async {
    try {
      final file = await _getFile();
      if (await file.exists()) {
        final data = await file.readAsString();
        state = await compute(_decodeLibraryMap, data);
      }
    } catch (e) {
      debugPrint('加载词库失败: $e');
    }
  }

  Future<void> saveLibrary(String name, String content) async {
    final newState = {...state, name: content};
    state = newState; // 🌟 立即更新内存，UI瞬间响应！
    
    try {
      final file = await _getFile();
      final jsonStr = await compute(_encodeLibraryMap, newState);
      await file.writeAsString(jsonStr);
    } catch (e) {
      debugPrint('保存词库失败: $e');
    }
  }

  Future<void> deleteLibrary(String name) async {
    final newState = {...state}..remove(name);
    state = newState;
    
    try {
      final file = await _getFile();
      final jsonStr = await compute(_encodeLibraryMap, newState);
      await file.writeAsString(jsonStr);
    } catch (e) {
      debugPrint('删除词库失败: $e');
    }
  }
}