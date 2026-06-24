import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';

import 'package:nai_launcher/presentation/providers/generation/generation_params_notifier.dart';
import 'package:nai_launcher/presentation/providers/generation/image_workflow_controller.dart';
import 'package:nai_launcher/presentation/providers/reverse_prompt_provider.dart';
import 'package:nai_launcher/presentation/router/app_router.dart';
// 🚀 新增：引入 Vibe 模型
import 'package:nai_launcher/data/models/vibe/vibe_reference.dart';

class GlobalShareReceiver extends ConsumerStatefulWidget {
  final Widget child;
  const GlobalShareReceiver({super.key, required this.child});

  @override
  ConsumerState<GlobalShareReceiver> createState() => _GlobalShareReceiverState();
}

class _GlobalShareReceiverState extends ConsumerState<GlobalShareReceiver> {
  static const MethodChannel _shareChannel = MethodChannel('com.nai.launcher/share');
  static bool _isProcessingShare = false; 

  @override
  void initState() {
    super.initState();
    _initShareListener();
  }

  void _initShareListener() {
    _shareChannel.setMethodCallHandler((call) async {
      if (call.method == 'onSharedData') {
        final List<dynamic> args = call.arguments;
        _handleSharedData(args.cast<String>());
      }
    });

    _shareChannel.invokeMethod('getPendingShareData').then((data) {
      if (data != null && data is List && data.isNotEmpty) {
        _handleSharedData(data.cast<String>());
      }
    });
  }

  void _handleSharedData(List<String> items) {
    if (items.isEmpty || _isProcessingShare) return; 
    _isProcessingShare = true;
    final item = items.first; 

    int attempts = 0;
    void tryShowDialog() {
      final context = ref.read(appRouterProvider).routerDelegate.navigatorKey.currentContext;
      if (context != null && context.mounted) {
        
        void processTextContent(String text) {
          final cleanText = text.trim();
          final urlRegex = RegExp(r'(https?:\/\/[^\s,\[\]"\}]+)');
          final match = urlRegex.firstMatch(cleanText);
          
          if (match != null) {
            _handleUrlDownload(match.group(0)!, context);
          } else {
            _showTextActionDialog(cleanText, context);
          }
        }

        if (item.startsWith('url:')) {
          _handleUrlDownload(item.substring(4).trim(), context);
        } else if (item.startsWith('text:')) {
          processTextContent(item.substring(5)); 
        } else if (item.startsWith('file:')) {
          final path = item.substring(5);
          final lowerPath = path.toLowerCase();
          if (lowerPath.endsWith('.txt') || lowerPath.endsWith('.md') || lowerPath.endsWith('.json')) {
            try {
              final file = File(path);
              final textContent = file.readAsStringSync();
              file.deleteSync(); 
              processTextContent(textContent); 
            } catch (e) {
              _showResultDialog(context, '读取文本失败: $e', isError: true);
              _isProcessingShare = false;
            }
          } else {
            _showImageActionDialog(path, context);
          }
        }
      } else {
        if (attempts < 50) {
          attempts++;
          Future.delayed(const Duration(milliseconds: 100), tryShowDialog);
        } else {
          debugPrint('GlobalShareReceiver: 无法获取 Navigator Context，放弃弹窗。');
          _isProcessingShare = false;
        }
      }
    }

    tryShowDialog();
  }

  void _showResultDialog(BuildContext context, String message, {bool isError = false}) {
    if (isError) {
      showDialog(
        context: context,
        builder: (c) => AlertDialog(
          title: const Icon(Icons.error, color: Colors.red, size: 48),
          content: Text(message, textAlign: TextAlign.center),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c), child: const Text('确定'))
          ],
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _handleUrlDownload(String url, BuildContext activeCtx) async {
    showDialog(
      context: activeCtx,
      barrierDismissible: false,
      builder: (c) => const Center(
        child: Card(
          child: Padding(
            padding: EdgeInsets.all(20.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text('正在解析并下载图片...'),
              ],
            ),
          ),
        ),
      ),
    );

    try {
      final request = await HttpClient().getUrl(Uri.parse(url)).timeout(const Duration(seconds: 15));
      request.headers.set('User-Agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36');
      request.headers.set('Accept', 'image/webp,image/apng,image/*,*/*;q=0.8');
      
      final response = await request.close();
      final bytes = await consolidateHttpClientResponseBytes(response);

      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/dl_${DateTime.now().millisecondsSinceEpoch}.png');
      await file.writeAsBytes(bytes);

      if (activeCtx.mounted) Navigator.pop(activeCtx); 
      if (activeCtx.mounted) {
        _showImageActionDialog(file.path, activeCtx); 
      } else {
        _isProcessingShare = false;
      }
    } catch (e) {
      if (activeCtx.mounted) Navigator.pop(activeCtx); 
      if (activeCtx.mounted) _showResultDialog(activeCtx, '图片下载失败:\n$e\n\n链接: $url', isError: true);
      _isProcessingShare = false;
    }
  }

  void _showTextActionDialog(String text, BuildContext activeCtx) {
    showModalBottomSheet(
      context: activeCtx,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (bottomSheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.all(16.0),
                child: Text('接收到分享内容', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: Text(text, maxLines: 5, overflow: TextOverflow.ellipsis),
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.send),
                title: const Text('发送到提示词 (Prompt)'),
                onTap: () {
                  Navigator.pop(bottomSheetContext);
                  ref.read(generationParamsNotifierProvider.notifier).updatePrompt(text);
                  _showResultDialog(activeCtx, '已填入提示词');
                  ref.read(appRouterProvider).go(AppRoutes.generation);
                },
              ),
              ListTile(
                leading: const Icon(Icons.copy),
                title: const Text('仅复制到剪贴板'),
                onTap: () {
                  Navigator.pop(bottomSheetContext);
                  Clipboard.setData(ClipboardData(text: text));
                  _showResultDialog(activeCtx, '已复制到剪贴板');
                },
              ),
            ],
          ),
        );
      },
    ).whenComplete(() {
      _isProcessingShare = false; 
    });
  }

  void _showImageActionDialog(String imagePath, BuildContext activeCtx) {
    bool actionTaken = false; 

    showModalBottomSheet(
      context: activeCtx,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (bottomSheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.all(16.0),
                child: Text('接收到分享图片', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              ),
              Container(
                height: 120,
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  image: DecorationImage(image: FileImage(File(imagePath)), fit: BoxFit.contain),
                ),
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.image),
                title: const Text('发送到图生图 (Image to Image)'),
                onTap: () async {
                  actionTaken = true;
                  Navigator.pop(bottomSheetContext);
                  try {
                    final bytes = await File(imagePath).readAsBytes();
                    ref.read(imageWorkflowControllerProvider.notifier).replaceSourceImage(bytes);
                    ref.read(appRouterProvider).go(AppRoutes.generation);
                  } catch (e) {
                    _showResultDialog(activeCtx, '读取分享图片失败: $e', isError: true);
                  }
                },
              ),
              // 🚀 新增：导入为 Vibe 选项
              ListTile(
                leading: const Icon(Icons.auto_awesome),
                title: const Text('作为 Vibe 导入 (Import as Vibe)'),
                onTap: () async {
                  actionTaken = true;
                  Navigator.pop(bottomSheetContext);
                  try {
                    final bytes = await File(imagePath).readAsBytes();
                    // 完美匹配你源码中的 VibeReference 构造函数
                    final vibe = VibeReference(
                      displayName: 'Share_${DateTime.now().millisecondsSinceEpoch % 10000}',
                      vibeEncoding: '',
                      rawImageData: bytes,
                      thumbnail: bytes,
                      strength: 0.6,
                      infoExtracted: 1.0,
                      sourceType: VibeSourceType.rawImage,
                    );
                    ref.read(generationParamsNotifierProvider.notifier).addVibeReference(vibe);
                    ref.read(appRouterProvider).go(AppRoutes.generation);
                  } catch (e) {
                    _showResultDialog(activeCtx, '导入 Vibe 失败: $e', isError: true);
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.document_scanner),
                title: const Text('发送到反推 (Reverse Prompt)'),
                onTap: () async {
                  actionTaken = true;
                  Navigator.pop(bottomSheetContext);
                  try {
                    final bytes = await File(imagePath).readAsBytes();
                    ref.read(reversePromptProvider.notifier).clearImages();
                    ref.read(reversePromptProvider.notifier).addImage(bytes);
                    ref.read(appRouterProvider).go(AppRoutes.generation);
                  } catch (e) {
                    _showResultDialog(activeCtx, '读取分享图片失败: $e', isError: true);
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.save_alt),
                title: const Text('保存到本地画廊'),
                onTap: () async {
                  actionTaken = true;
                  Navigator.pop(bottomSheetContext);
                  try {
                    final dir = await getApplicationDocumentsDirectory();
                    final galleryDir = Directory('${dir.path}/NAI_Launcher/images');
                    if (!galleryDir.existsSync()) {
                      galleryDir.createSync(recursive: true);
                    }
                    final savePath = '${galleryDir.path}/shared_${DateTime.now().millisecondsSinceEpoch}.png';
                    File(imagePath).copySync(savePath);
                    
                    if (activeCtx.mounted) {
                      _showResultDialog(activeCtx, '已成功保存到本地画廊，请刷新画廊查看');
                    }
                  } catch (e) {
                    if (activeCtx.mounted) {
                      _showResultDialog(activeCtx, '保存失败: $e', isError: true);
                    }
                  }
                },
              ),
            ],
          ),
        );
      },
    ).whenComplete(() {
      _isProcessingShare = false; 
      if (!actionTaken) {
        try {
          final file = File(imagePath);
          if (file.existsSync()) file.deleteSync();
        } catch (e) {
          debugPrint('删除临时文件失败: $e');
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}