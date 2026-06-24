import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:share_plus/share_plus.dart'; // 👈 引入分享插件

import '../../core/utils/app_logger.dart';
import '../models/vibe/vibe_export_format.dart';
import '../models/vibe/vibe_library_entry.dart';

part 'vibe_export_service.g.dart';

typedef ExportProgressCallback = void Function({
  required int current,
  required int total,
  required String currentItem,
});

class VibeExportService {
  static const String _tag = 'VibeExport';

  /// 导出为 Bundle 格式 (使用原生分享)
  Future<String?> exportAsBundle(
    List<VibeLibraryEntry> entries, {
    required VibeExportOptions options,
    ExportProgressCallback? onProgress,
  }) async {
    if (entries.isEmpty) return null;

    final stopwatch = Stopwatch()..start();

    try {
      final fileName = _generateFileName(options.fileName, 'vibe-bundle', kNaiv4vibebundleExtension);
      
      // 1. 构建数据并转为二进制
      final bundleData = await _buildBundleData(entries, options, onProgress);
      final jsonString = const JsonEncoder.withIndent('  ').convert(bundleData);
      final bytes = Uint8List.fromList(utf8.encode(jsonString));

      // 2. 写入 App 私有缓存目录（绝对有权限，绝对不是 0B）
      final tempDir = await getTemporaryDirectory();
      final tempFile = File(p.join(tempDir.path, fileName));
      await tempFile.writeAsBytes(bytes, flush: true);

      // 3. 💡 核心：直接呼出系统分享面板！
      await Share.shareXFiles([XFile(tempFile.path)], text: '导出 Vibe Bundle');

      stopwatch.stop();
      AppLogger.i('Bundle shared successfully', _tag);
      return tempFile.path; // 返回路径代表成功
    } catch (e, stackTrace) {
      AppLogger.e('Bundle export failed', e, stackTrace, _tag);
      return null;
    }
  }

  /// 导出为纯编码格式 (txt) (使用原生分享)
  Future<String?> exportAsEncoding(
    List<VibeLibraryEntry> entries, {
    required VibeExportOptions options,
    ExportProgressCallback? onProgress,
  }) async {
    if (entries.isEmpty) return null;

    final stopwatch = Stopwatch()..start();

    try {
      final fileName = _generateFileName(options.fileName, 'vibe-encodings', 'txt');
      final encodingList = <String>[];

      for (var i = 0; i < entries.length; i++) {
        if (entries[i].vibeEncoding.isNotEmpty) {
          encodingList.add(entries[i].vibeEncoding);
        }
      }
      if (encodingList.isEmpty) return null;

      // 1. 转为二进制
      final fileContent = encodingList.join('\n');
      final bytes = Uint8List.fromList(utf8.encode(fileContent));

      // 2. 写入 App 私有缓存目录
      final tempDir = await getTemporaryDirectory();
      final tempFile = File(p.join(tempDir.path, fileName));
      await tempFile.writeAsBytes(bytes, flush: true);

      // 3. 💡 核心：直接呼出系统分享面板！
      await Share.shareXFiles([XFile(tempFile.path)], text: '导出 Vibe 编码');

      stopwatch.stop();
      return tempFile.path;
    } catch (e, stackTrace) {
      AppLogger.e('Encoding export failed', e, stackTrace, _tag);
      return null;
    }
  }

  Future<String?> exportAsEmbeddedImage(VibeLibraryEntry entry, {required VibeExportOptions options}) async {
    return null;
  }

  Future<Map<String, dynamic>> _buildBundleData(
    List<VibeLibraryEntry> entries, VibeExportOptions options, ExportProgressCallback? onProgress,
  ) async {
    final vibeEntries = <Map<String, dynamic>>[];
    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
      onProgress?.call(current: i, total: entries.length, currentItem: entry.displayName);

      final entryData = <String, dynamic>{'name': entry.displayName};
      if (options.includeEncoding && entry.vibeEncoding.isNotEmpty) {
        entryData['encodings'] = {'nai-diffusion-4-full': {'vibe': {'encoding': entry.vibeEncoding}}};
      }
      entryData['importInfo'] = {'strength': entry.strength, 'information_extracted': entry.infoExtracted};
      if (options.includeThumbnail && entry.hasVibeThumbnail) {
        entryData['thumbnail'] = base64Encode(entry.vibeThumbnail!);
      }
      if (entry.rawImageData != null && entry.rawImageData!.isNotEmpty) {
        entryData['image'] = base64Encode(entry.rawImageData!);
      }
      vibeEntries.add(entryData);
    }

    return {
      'identifier': 'novelai-vibe-transfer-bundle',
      'version': options.version,
      'exportedAt': DateTime.now().toIso8601String(),
      'entryCount': entries.length,
      'vibes': vibeEntries,
    };
  }

  String _generateFileName(String? customName, String defaultBaseName, String extension) {
    final timestamp = DateTime.now();
    final formattedTime = '${timestamp.year}${_twoDigits(timestamp.month)}${_twoDigits(timestamp.day)}_'
        '${_twoDigits(timestamp.hour)}${_twoDigits(timestamp.minute)}${_twoDigits(timestamp.second)}';
    final baseName = customName?.trim().isNotEmpty == true ? customName!.trim() : '${defaultBaseName}_$formattedTime';
    return '${_sanitizeFileName(baseName)}.$extension';
  }

  String _sanitizeFileName(String fileName) => fileName.replaceAll(RegExp(r'[<>:"/\|?*]'), '_').replaceAll(RegExp(r'\s+'), ' ').trim();
  String _twoDigits(int n) => n.toString().padLeft(2, '0');
}

@riverpod
VibeExportService vibeExportService(Ref ref) => VibeExportService();