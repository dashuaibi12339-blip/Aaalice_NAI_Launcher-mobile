import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../utils/app_logger.dart';

/// 资产数据库管理器
class AssetDatabaseManager {
  static final AssetDatabaseManager _instance = AssetDatabaseManager._();
  static AssetDatabaseManager get instance => _instance;
  
  AssetDatabaseManager._();
  
  static const String translationDb = 'translation.db';
  static const String cooccurrenceDb = 'cooccurrence.db';
  
  String? _translationDbPath;
  String? _cooccurrenceDbPath;
  
  String get translationDbPath {
    if (_translationDbPath == null) throw StateError('Not initialized');
    return _translationDbPath!;
  }
  
  String get cooccurrenceDbPath {
    if (_cooccurrenceDbPath == null) throw StateError('Not initialized');
    return _cooccurrenceDbPath!;
  }
  
  static Future<void> initialize() async {
    AppLogger.i('Initializing asset databases...', 'AssetDatabaseManager');
    
    final dbDirPath = await getDatabasesPath();
    // 👇 鸿蒙终极破解：强制找到隐藏的 rdb 文件夹！
    String rdbPath = dbDirPath;
    if (!rdbPath.endsWith('rdb')) {
      rdbPath = p.join(rdbPath, 'rdb');
    }
    
    final assetDbDir = Directory(rdbPath);
    if (!await assetDbDir.exists()) {
      await assetDbDir.create(recursive: true);
    }
    
    final transTarget = p.join(assetDbDir.path, translationDb);
    await _copyAssetDatabase(assetPath: 'assets/databases/$translationDb', targetPath: transTarget, name: 'translation');
    _instance._translationDbPath = transTarget;
    
    final coocTarget = p.join(assetDbDir.path, cooccurrenceDb);
    await _copyAssetDatabase(assetPath: 'assets/databases/$cooccurrenceDb', targetPath: coocTarget, name: 'cooccurrence');
    _instance._cooccurrenceDbPath = coocTarget;
    
    AppLogger.i('Asset databases initialized', 'AssetDatabaseManager');
  }
  
  static Future<void> _copyAssetDatabase({
    required String assetPath,
    required String targetPath,
    required String name,
  }) async {
    final targetFile = File(targetPath);
    bool needsCopy = true;
    
    if (await targetFile.exists()) {
      final size = await targetFile.length();
      if (size > 1024 * 10) { // 大于 10KB 才是有效文件
        needsCopy = false;
      } else {
        await targetFile.delete(); // 删掉空壳
      }
    }
    
    if (needsCopy) {
      try {
        final byteData = await rootBundle.load(assetPath);
        final bytes = byteData.buffer.asUint8List();
        await targetFile.writeAsBytes(bytes, flush: true);
      } catch (e) {
        rethrow;
      }
    }
  }
  
  Future<Database> openTranslationDatabase() async {
    return _openReadOnlyDatabase(translationDbPath, 'translation');
  }
  
  Future<Database> openCooccurrenceDatabase() async {
    return _openReadOnlyDatabase(cooccurrenceDbPath, 'cooccurrence');
  }
  
  Future<Database> _openReadOnlyDatabase(String path, String name) async {
    // 👇 鸿蒙终极破解：只传纯文件名，绕过华为绝对路径 Bug！
    final dbName = p.basename(path); 
    AppLogger.i('Opening $name database with relative name: $dbName', 'AssetDatabaseManager');
    
    return await databaseFactory.openDatabase(
      dbName, // 绝不传绝对路径！
      options: OpenDatabaseOptions(
        readOnly: false, // 必须为 false，防止 WAL 崩溃
        singleInstance: false,
      ),
    );
  }
  
  Future<bool> checkDatabasesExist() async {
    return await File(translationDbPath).exists() && await File(cooccurrenceDbPath).exists();
  }
  
  Future<Map<String, dynamic>> getDatabaseInfo() async {
    Future<Map<String, dynamic>> getFileInfo(String path) async {
      final file = File(path);
      final exists = await file.exists();
      return {
        'path': path,
        'exists': exists,
        'size': exists ? await file.length() : 0,
      };
    }
    return {
      'translation': await getFileInfo(translationDbPath),
      'cooccurrence': await getFileInfo(cooccurrenceDbPath),
    };
  }
}