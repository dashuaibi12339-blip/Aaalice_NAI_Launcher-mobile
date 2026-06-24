import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:sqflite/sqflite.dart';

/// 这是一个完美的 SharedPreferences 伪装者！
/// 借用 sqflite 探路，底层使用 Hive 存储，并发安全！
class SharedPreferences {
  static Future<SharedPreferences>? _initFuture;
  static Map<String, Object>? _mockValues; // 🌟 新增：用来暂存初始化的 mock 数据
  final Box _box;

  SharedPreferences._(this._box);

  // 🌟 新增：完美复刻官方的 setMockInitialValues 方法，消灭报错！
  static void setMockInitialValues(Map<String, Object> values) {
    _mockValues = values;
  }

  static Future<SharedPreferences> getInstance() {
    _initFuture ??= _init();
    return _initFuture!;
  }

  static Future<SharedPreferences> _init() async {
    try {
      // 1. 借用 sqflite 获取鸿蒙真实的沙盒路径
      final dbPath = await getDatabasesPath();
      final hivePath = '$dbPath/hive_prefs';
      
      // 2. 确保文件夹存在
      final dir = Directory(hivePath);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      
      // 3. 初始化 Hive
      Hive.init(hivePath);
      final box = await Hive.openBox('harmony_shared_prefs');
      
      // 🌟 新增：如果有 mock 初始数据，在这里强行写入 Hive
      if (_mockValues != null) {
        for (final entry in _mockValues!.entries) {
          await box.put(entry.key, entry.value);
        }
        _mockValues = null; // 写完就清空，防止重复写入
      }
      
      return SharedPreferences._(box);
    } catch (e) {
      debugPrint('SharedPreferences 伪装者初始化惨遭失败: $e');
      rethrow;
    }
  }

  // ================= 完美复刻的 API =================
  String? getString(String key) => _box.get(key);
  int? getInt(String key) => _box.get(key);
  double? getDouble(String key) => _box.get(key);
  bool? getBool(String key) => _box.get(key);
  List<String>? getStringList(String key) => _box.get(key)?.cast<String>();

  Future<bool> setString(String key, String value) async { await _box.put(key, value); return true; }
  Future<bool> setInt(String key, int value) async { await _box.put(key, value); return true; }
  Future<bool> setDouble(String key, double value) async { await _box.put(key, value); return true; }
  Future<bool> setBool(String key, bool value) async { await _box.put(key, value); return true; }
  Future<bool> setStringList(String key, List<String> value) async { await _box.put(key, value); return true; }

  Future<bool> remove(String key) async { await _box.delete(key); return true; }
  Future<bool> clear() async { await _box.clear(); return true; }
  bool containsKey(String key) => _box.containsKey(key);
  Set<String> getKeys() => _box.keys.cast<String>().toSet();
  Future<void> reload() async {} // 留空防报错
}