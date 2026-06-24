import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:file_picker_ohos/file_picker_ohos.dart' as ohos;

enum FileType { any, media, image, video, audio, custom }

class PlatformFile {
  final String name;
  final String? path;
  final int size;
  final Uint8List? bytes;
  final Stream<List<int>>? readStream;

  PlatformFile({
    required this.name,
    this.path,
    required this.size,
    this.bytes,
    this.readStream,
  });

  String? get extension => name.contains('.') ? name.split('.').last : null;
}

class FilePickerResult {
  final List<PlatformFile> files;
  FilePickerResult(this.files);
}

class FilePicker {
  static final FilePicker platform = FilePicker();

  // 💡 终极修复 1：释放“选文件夹”功能，完美支持批量导出！
  Future<String?> getDirectoryPath({String? dialogTitle, bool lockParentWindow = false, String? initialDirectory}) async {
    String validDir = initialDirectory ?? '';
    
    // 绝对防御：如果 App 没传初始目录，自动补全沙盒目录，防止华为底层崩溃！
    if (validDir.isEmpty) {
      final dir = await getApplicationDocumentsDirectory();
      validDir = dir.path; 
    }

    // 呼出鸿蒙原生“选择文件夹”弹窗
    return await ohos.FilePicker.platform.getDirectoryPath(
      dialogTitle: dialogTitle ?? '选择保存目录',
      initialDirectory: validDir,
    );
  }

  // 💡 终极修复 2：强化“另存为”，支持单文件导出！
  Future<String?> saveFile({
    String? dialogTitle, String? fileName, String? initialDirectory,
    FileType type = FileType.any, List<String>? allowedExtensions,
    bool lockParentWindow = false, Uint8List? bytes,
  }) async {
    String validPath = initialDirectory ?? '';
    File? tempFile;

    // 绝对防御：如果没传初始文件路径，自动在沙盒伪造一个，防止华为底层崩溃！
    if (validPath.isEmpty) {
      final dir = await getTemporaryDirectory();
      final name = fileName ?? 'export_${DateTime.now().millisecondsSinceEpoch}';
      tempFile = File('${dir.path}/$name');
      // 华为底层要求文件必须真实存在
      if (!await tempFile.exists()) {
         await tempFile.writeAsBytes(bytes ?? Uint8List(0));
      }
      validPath = tempFile.path;
    }

    try {
      // 呼出鸿蒙原生“另存为”弹窗
      return await ohos.FilePicker.platform.saveFile(
        dialogTitle: dialogTitle ?? '保存文件',
        fileName: fileName,
        initialDirectory: validPath,
        bytes: bytes,
      );
    } finally {
      // 阅后即焚，绝不留垃圾
      if (tempFile != null && await tempFile.exists()) {
        await tempFile.delete();
      }
    }
  }

  // 💡 终极修复 3：完美导入（保留之前用 Stream 修复乱码的逻辑）
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle, String? initialDirectory, FileType type = FileType.any,
    List<String>? allowedExtensions, bool allowMultiple = false, bool withData = false,
    bool withReadStream = false, bool lockParentWindow = false,
  }) async {
    final result = await ohos.FilePicker.platform.pickFiles(
      type: ohos.FileType.any, // 必须用 any，防止后缀名被灰显
      allowMultiple: allowMultiple,
      withReadStream: true,    // 强行开启底层数据流
      withData: false,         // 严禁底层直接读内存（防止数据损坏乱码）
    );

    if (result == null) return null;

    final processedFiles = <PlatformFile>[];

    for (final file in result.files) {
      Uint8List? finalBytes;
      try {
        if (file.readStream != null) {
          final byteList = <int>[];
          await for (final chunk in file.readStream!) {
            byteList.addAll(chunk);
          }
          finalBytes = Uint8List.fromList(byteList);
        } else if (file.path != null) {
          final f = File(file.path!);
          if (await f.exists()) {
            finalBytes = await f.readAsBytes();
          }
        }
      } catch (e) {
        print('HarmonyOS Stream Error: $e');
      }

      processedFiles.add(PlatformFile(
        name: file.name,
        path: file.path,
        size: finalBytes?.length ?? file.size,
        bytes: finalBytes, // 喂给原 App 纯净无损的数据
        readStream: file.readStream,
      ));
    }

    return FilePickerResult(processedFiles);
  }
}

// 华为分享面板保持不变
class ImageGallerySaverPlus {
  static Future<Map<dynamic, dynamic>> saveImage(Uint8List imageBytes, {int quality = 80, String? name, bool isReturnImagePathOfIOS = false}) async {
    try {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/${name ?? DateTime.now().millisecondsSinceEpoch}.png');
      await file.writeAsBytes(imageBytes);
      await Share.shareXFiles([XFile(file.path)], text: '分享图片');
      return {'isSuccess': true, 'filePath': file.path};
    } catch (e) {
      return {'isSuccess': false, 'errorMessage': e.toString()};
    }
  }

  static Future<Map<dynamic, dynamic>> saveFile(String file, {String? name, bool isReturnPathOfIOS = false}) async {
    try {
      final source = File(file);
      final dir = await getTemporaryDirectory();
      final target = File('${dir.path}/${name ?? source.path.split('/').last}');
      await source.copy(target.path);
      await Share.shareXFiles([XFile(target.path)], text: '分享文件');
      return {'isSuccess': true, 'filePath': target.path};
    } catch (e) {
      return {'isSuccess': false, 'errorMessage': e.toString()};
    }
  }
}