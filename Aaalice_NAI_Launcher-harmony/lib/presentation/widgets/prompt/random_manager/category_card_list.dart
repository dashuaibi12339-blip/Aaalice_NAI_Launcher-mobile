import 'dart:convert';
import 'dart:io';
import 'package:file_picker_ohos/file_picker_ohos.dart';
import 'package:flutter/foundation.dart';
import 'package:nai_launcher/presentation/providers/global_library_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
import 'package:nai_launcher/presentation/providers/generation/generation_params_notifier.dart';
import 'package:flutter/material.dart';
import 'package:nai_launcher/data/models/prompt/random_category.dart';
import 'package:nai_launcher/l10n/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../common/app_toast.dart';
import '../../../../data/models/prompt/random_preset.dart';
import '../../../providers/random_preset_provider.dart';
import '../../common/elevated_card.dart';
import 'category_card.dart';

/// 类别卡片垂直列表组件

// ==========================================
// 🌟 顶层函数：在后台多线程处理海量文本的正则与分割
// ==========================================
String _formatLibraryContentInBackground(Map<String, dynamic> args) {
  final text = args['text'] as String;
  final splitMode = args['splitMode'] as int;

  List<String> rawTags = [];
  if (splitMode == 3) {
    final lines = text.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    for (int i = 0; i < lines.length; i++) {
      if (i + 1 < lines.length) {
        final current = lines[i];
        final next = lines[i + 1];
        final currentHasChinese = RegExp(r'[\u4e00-\u9fa5]').hasMatch(current);
        final nextHasChinese = RegExp(r'[\u4e00-\u9fa5]').hasMatch(next);
        if (currentHasChinese && !nextHasChinese) { rawTags.add('$next: $current'); i++; continue; } 
        else if (!currentHasChinese && nextHasChinese) { rawTags.add('$current: $next'); i++; continue; }
      }
      rawTags.add(lines[i]);
    }
  } else if (splitMode == 1) { 
    rawTags = text.split('\n'); 
  } else if (splitMode == 2) { 
    rawTags = text.split(RegExp(r'[,，]')); 
  } else { 
    rawTags = text.split(RegExp(r'[\n,，]')); 
  }

  return rawTags.map((t) => t.trim()).where((t) => t.isNotEmpty).join('\n');
}

/// 用于在仪表盘中显示所有类别卡片（垂直列表布局）
/// 采用 Dimensional Layering 风格设计
class CategoryCardList extends ConsumerWidget {
  const CategoryCardList({
    super.key,
    this.onAddCategory,
  });

  final VoidCallback? onAddCategory;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final presetState = ref.watch(randomPresetNotifierProvider);
    final preset = presetState.selectedPreset;

    if (preset == null) {
      return const Center(child: Text('请选择一个预设'));
    }

    return ElevatedCard(
      elevation: CardElevation.level1,
      enableHoverEffect: false,
      borderRadius: 8,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题栏
          _CategoryHeader(
            preset: preset,
            onAddCategory: onAddCategory,
          ),
          const SizedBox(height: 16),
          // 类别卡片垂直列表
          if (preset.categories.isEmpty)
            const EmptyCategoryPlaceholder()
          else
            Expanded(
              child: ListView.separated(
                clipBehavior: Clip.none,
                itemCount: preset.categories.length,
                separatorBuilder: (context, index) =>
                    const SizedBox(height: 12),
                itemBuilder: (context, index) {
                  final category = preset.categories[index];
                  return CategoryCard(
                    category: category,
                    presetId: preset.id,
                    isPresetDefault: preset.isDefault,
                  );
                },
              ),
            ),  
        ],
      ),
    );
  }
}

/// 类别卡片网格组件
///
/// 用于在仪表盘中显示所有类别卡片
/// 采用 Dimensional Layering 风格设计
class CategoryCardGrid extends ConsumerWidget {
  const CategoryCardGrid({
    super.key,
    this.onAddCategory,
  });

  final VoidCallback? onAddCategory;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final presetState = ref.watch(randomPresetNotifierProvider);
    final preset = presetState.selectedPreset;

    if (preset == null) {
      return const Center(child: Text('请选择一个预设'));
    }

    return ElevatedCard(
      elevation: CardElevation.level1,
      enableHoverEffect: false,
      borderRadius: 8,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题栏
          _CategoryHeader(
            preset: preset,
            onAddCategory: onAddCategory,
          ),
          const SizedBox(height: 16),
          // 类别卡片网格
          if (preset.categories.isEmpty)
            const EmptyCategoryPlaceholder()
          else
            LayoutBuilder(
              builder: (context, constraints) {
                const minCardWidth = 260.0;
                const maxCardWidth = 320.0;
                const spacing = 12.0;

                final availableWidth = constraints.maxWidth;
                final cardsPerRow =
                    ((availableWidth + spacing) / (minCardWidth + spacing))
                        .floor()
                        .clamp(1, 4);
                final cardWidth =
                    (availableWidth - (cardsPerRow - 1) * spacing) /
                        cardsPerRow;
                final finalCardWidth =
                        cardWidth.clamp(minCardWidth, maxCardWidth);

                // 👈 手机窄屏（1列）且是自定义预设，启动长按拖拽列表！
                if (cardsPerRow == 1 && !preset.isDefault) {
                  return ReorderableListView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    buildDefaultDragHandles: false, // 关闭默认的丑把手
                    itemCount: preset.categories.length,
                    proxyDecorator: (child, index, animation) {
                      return Material(
                        elevation: 16,
                        color: Colors.transparent,
                        shadowColor: Theme.of(context).colorScheme.shadow.withValues(alpha: 0.4),
                        borderRadius: BorderRadius.circular(8),
                        child: child,
                      );
                    },
                    onReorder: (oldIndex, newIndex) {
                      if (oldIndex < newIndex) newIndex -= 1;
                      final categories = preset.categories.toList();
                      final item = categories.removeAt(oldIndex);
                      categories.insert(newIndex, item);
                      ref.read(randomPresetNotifierProvider.notifier).updateCategories(categories);
                    },
                    itemBuilder: (context, index) {
                      final category = preset.categories[index];
                      // 🌟 核心魔法：使用 Delayed 监听器，实现长按拖拽，短按透过！
                      return ReorderableDelayedDragStartListener(
                        key: ValueKey(category.id),
                        index: index,
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: CategoryCard(
                            category: category,
                            presetId: preset.id,
                            isPresetDefault: preset.isDefault,
                          ),
                        ),
                      );
                    },
                  );
                }
                // 宽屏多列模式 或 默认只读预设，保持原样渲染 Wrap
                return Wrap(
                  spacing: spacing,
                  runSpacing: spacing,
                  children: preset.categories.map((category) {
                    return SizedBox(
                      width: finalCardWidth,
                      child: CategoryCard(
                        category: category,
                        presetId: preset.id,
                        isPresetDefault: preset.isDefault,
                      ),
                    );
                  }).toList(),
                );
          
              },
            ),
        ],
      ),
    );
  }
}

/// 构建标题栏
class _CategoryHeader extends ConsumerWidget {
  const _CategoryHeader({
    required this.preset,
    required this.onAddCategory,
  });

  final RandomPreset preset;
  final VoidCallback? onAddCategory;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final tagCount = ref.watch(presetTotalTagCountProvider);

    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 12,
      runSpacing: 12,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [colorScheme.primary.withValues(alpha: 0.15), colorScheme.primary.withValues(alpha: 0.05)],
            ),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(color: colorScheme.primary.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(4)),
                child: Icon(Icons.category_outlined, size: 14, color: colorScheme.primary),
              ),
              const SizedBox(width: 8),
              Text(
                l10n.categoryConfiguration,
                style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold, color: colorScheme.primary),
              ),
            ],
          ),
        ),
        CategoryStats(
          categoryCount: preset.categoryCount,
          groupCount: preset.categories.fold(0, (sum, c) => sum + c.groupCount),
          tagCount: tagCount,
        ),
        // 🌟 新增：全局词库管理按钮
        FilledButton.tonalIcon(
          onPressed: () => showDialog(context: context, builder: (c) => const GlobalLibraryManagerDialog()),
          icon: const Icon(Icons.library_books, size: 18),
          label: const Text('全局本地词库'),
          style: FilledButton.styleFrom(backgroundColor: colorScheme.tertiaryContainer, foregroundColor: colorScheme.onTertiaryContainer),
        ),
        
        // 🌟 修复恶性 Bug：如果当前是默认预设（只读），彻底隐藏“新增类别”按钮！
        if (!preset.isDefault)
          AddCategoryButton(
            onPressed: onAddCategory ?? () async {
              final nameController = TextEditingController();
              final name = await showDialog<String>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('新增类别'),
                  content: TextField(controller: nameController, decoration: const InputDecoration(hintText: '输入类别名称 (如: 场景、光影)', border: OutlineInputBorder()), autofocus: true),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
                    FilledButton(onPressed: () => Navigator.pop(context, nameController.text), child: const Text('添加')),
                  ],
                ),
              );

              if (name != null && name.trim().isNotEmpty) {
                final uniqueKey = 'custom_${DateTime.now().millisecondsSinceEpoch}';
                final newCategory = RandomCategory.create(name: name.trim(), key: uniqueKey);
                ref.read(randomPresetNotifierProvider.notifier).addCategory(newCategory);
              }
            },
          ),
      ],
    );
  }
}

// ==========================================
// 🌟 UI：全局词库管理面板
// ==========================================
class GlobalLibraryManagerDialog extends ConsumerStatefulWidget {
  const GlobalLibraryManagerDialog({super.key});
  @override
  ConsumerState<GlobalLibraryManagerDialog> createState() => _GlobalLibraryManagerDialogState();
}

class _GlobalLibraryManagerDialogState extends ConsumerState<GlobalLibraryManagerDialog> {
  void _showAddDialog() {
    final nameController = TextEditingController();
    final contentController = TextEditingController();
    int splitMode = 0; 
    
    String? pickedFilePath;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('新建本地词库'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(labelText: '词库名称 (必填，如: 极品画风)', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('内容:', style: TextStyle(fontWeight: FontWeight.bold)),
                    TextButton.icon(
                      icon: const Icon(Icons.folder_open, size: 18), label: const Text('读取 TXT'),
                      onPressed: () async {
                        try {
                          FilePickerResult? result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['txt']);
                          if (result != null && result.files.single.path != null) {
                            pickedFilePath = result.files.single.path!;
                            
                            // 🌟 核心修复：读取文件，但只截取前 1000 个字符显示在输入框里！
                            String fullText = await File(pickedFilePath!).readAsString();
                            String previewText = fullText;
                            if (fullText.length > 1000) {
                              previewText = '${fullText.substring(0, 1000)}\n\n... [预览已截断，实际包含 ${fullText.split('\n').length} 行数据，请直接点击保存]';
                            }

                            setDialogState(() {
                              contentController.text = previewText;
                            });
                          }
                        } catch (e) {
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('读取文件失败')));
                        }
                      },
                    ),
                  ],
                ),
                TextField(
                  controller: contentController, maxLines: 8,
                  decoration: const InputDecoration(hintText: '在此手动输入或粘贴标签...', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 16),
                const Text('保存前格式化:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                Wrap(
                  spacing: 8, runSpacing: 8,
                  children: [
                    ChoiceChip(label: const Text('智能 (换行+逗号)'), selected: splitMode == 0, onSelected: (val) => setDialogState(() => splitMode = 0)),
                    ChoiceChip(label: const Text('仅换行'), selected: splitMode == 1, onSelected: (val) => setDialogState(() => splitMode = 1)),
                    ChoiceChip(label: const Text('仅逗号'), selected: splitMode == 2, onSelected: (val) => setDialogState(() => splitMode = 2)),
                    ChoiceChip(label: const Text('双行对译'), selected: splitMode == 3, selectedColor: Theme.of(context).colorScheme.tertiaryContainer, onSelected: (val) => setDialogState(() => splitMode = 3)),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
            FilledButton(
              onPressed: () async {
                final name = nameController.text.trim();
                
                if (name.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请输入词库名称！')));
                  return;
                }

                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('正在后台处理海量数据，请稍候...')));

                // 🌟 核心：如果是本地文件，重新读取完整内容去后台处理；如果是手动输入，直接处理输入框内容
                String textToProcess = '';
                if (pickedFilePath != null) {
                  textToProcess = await File(pickedFilePath!).readAsString();
                } else {
                  textToProcess = contentController.text;
                }

                if (textToProcess.trim().isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('内容不能为空！')));
                  return;
                }

                final finalContent = await compute(_formatLibraryContentInBackground, {
                  'text': textToProcess,
                  'splitMode': splitMode,
                });
                
                ref.read(globalLibraryProvider.notifier).saveLibrary(name, finalContent);
                
                if (context.mounted) {
                  Navigator.pop(context);
                  AppToast.success(context, '词库 "$name" 已保存');
                }
              },           
              child: const Text('保存入库'),
            ),
          ],
        )
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final libraries = ref.watch(globalLibraryProvider);
    final theme = Theme.of(context);

    return Dialog(
      child: Container(
        width: 500, height: 600,
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.library_books, color: theme.colorScheme.tertiary),
                const SizedBox(width: 8),
                Text('我的全局词库', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
                const Spacer(),
                IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
              ],
            ),
            const SizedBox(height: 8),
            Text('存放在这里的词库永久保存在本地，点击词库可进行编辑。', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
            const Divider(height: 32),
            Expanded(
              child: libraries.isEmpty
                ? const Center(child: Text('暂无本地词库，点击右下角新建'))
                : ListView.builder(
                    itemCount: libraries.length,
                    itemBuilder: (context, index) {
                      final name = libraries.keys.elementAt(index);
                      final content = libraries[name]!;
                      final tagCount = content.split('\n').where((e) => e.trim().isNotEmpty).length;
                      
                      return Card(
                        margin: const EdgeInsets.only(bottom: 12),
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          // 🌟 核心：点击词库，打开详情编辑器！
                          onTap: () {
                            showDialog(
                              context: context,
                              builder: (context) => GlobalLibraryDetailDialog(libraryName: name),
                            );
                          },
                          child: ListTile(
                            leading: const CircleAvatar(child: Icon(Icons.book)),
                            title: Text(name, style: const TextStyle(fontWeight: FontWeight.bold)),
                            subtitle: Text('约 $tagCount 个标签', style: TextStyle(color: theme.colorScheme.primary)),
                            trailing: IconButton(
                              icon: const Icon(Icons.delete, color: Colors.redAccent),
                              onPressed: () => ref.read(globalLibraryProvider.notifier).deleteLibrary(name),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                FloatingActionButton.extended(
                  onPressed: _showAddDialog,
                  icon: const Icon(Icons.add),
                  label: const Text('新建词库'),
                ),
              ],
            )
          ],
        ),
      ),
    );
  }
}

// ==========================================
// 🌟 UI：全局词库详情编辑器 (完全对标 tag_group_card)
// ==========================================
class GlobalLibraryDetailDialog extends ConsumerStatefulWidget {
  final String libraryName;
  const GlobalLibraryDetailDialog({super.key, required this.libraryName});

  @override
  ConsumerState<GlobalLibraryDetailDialog> createState() => _GlobalLibraryDetailDialogState();
}

class _GlobalLibraryDetailDialogState extends ConsumerState<GlobalLibraryDetailDialog> {
  String _searchQuery = '';

  // 🌟 完美对齐原版：强大的批量导入弹窗（接入后台多线程防卡死）
  void _showImportDialog(List<String> currentTags) {
    final controller = TextEditingController();
    int splitMode = 0; 
    String? pickedFilePath;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            title: const Text('批量导入标签'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('粘贴文本或导入文件:', style: TextStyle(fontSize: 14)),
                      TextButton.icon(
                        icon: const Icon(Icons.folder_open, size: 18),
                        label: const Text('选择 TXT 文件'),
                        onPressed: () async {
                          try {
                            FilePickerResult? result = await FilePicker.platform.pickFiles(
                              type: FileType.custom,
                              allowedExtensions: ['txt'],
                            );
                            if (result != null && result.files.single.path != null) {
                              pickedFilePath = result.files.single.path!;
                              String fullText = await File(pickedFilePath!).readAsString();
                              String previewText = fullText;
                              if (fullText.length > 500) {
                                previewText = '${fullText.substring(0, 500)}\n\n... [预览已截断，实际包含 ${fullText.split('\n').length} 行数据，请直接点击导入]';
                              }
                              setDialogState(() {
                                controller.text = previewText;
                              });
                            }
                          } catch (e) {
                            debugPrint('读取文件失败: $e');
                          }
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: controller,
                    maxLines: 10,
                    decoration: const InputDecoration(
                      hintText: '在此粘贴文本，或点击上方按钮读取 TXT 文件...',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text('分隔方式:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ChoiceChip(label: const Text('智能 (换行+逗号)'), selected: splitMode == 0, onSelected: (val) => setDialogState(() => splitMode = 0)),
                      ChoiceChip(label: const Text('仅换行'), selected: splitMode == 1, onSelected: (val) => setDialogState(() => splitMode = 1)),
                      ChoiceChip(label: const Text('仅逗号'), selected: splitMode == 2, onSelected: (val) => setDialogState(() => splitMode = 2)),
                      ChoiceChip(label: const Text('双行对译 (中文换行英文)'), selected: splitMode == 3, selectedColor: Theme.of(context).colorScheme.tertiaryContainer, onSelected: (val) => setDialogState(() => splitMode = 3)),
                    ],
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () async {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('正在后台处理数据，请稍候...')));
                  
                  String textToProcess = '';
                  if (pickedFilePath != null) {
                    textToProcess = await File(pickedFilePath!).readAsString();
                  } else {
                    textToProcess = controller.text;
                  }

                  if (textToProcess.trim().isEmpty) {
                    Navigator.pop(context);
                    return;
                  }

                  // 丢给后台线程处理，防止 UI 卡死
                  final newContent = await compute(_formatLibraryContentInBackground, {
                    'text': textToProcess,
                    'splitMode': splitMode,
                  });

                  if (newContent.isNotEmpty) {
                    final newTags = List<String>.from(currentTags)..addAll(newContent.split('\n'));
                    ref.read(globalLibraryProvider.notifier).saveLibrary(widget.libraryName, newTags.join('\n'));
                  }
                  
                  if (context.mounted) {
                    Navigator.pop(context);
                  }
                },
                child: const Text('导入'),
              ),
            ],
          );
        }
      ),
    );
  }

  void _showEditTagDialog(String currentTagStr, int index, List<String> currentTags) {
    final controller = TextEditingController(text: currentTagStr);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('编辑标签'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(hintText: '例如: 1girl: 女孩', border: OutlineInputBorder()),
          autofocus: true,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          ElevatedButton(
            onPressed: () {
              final newText = controller.text.trim();
              if (newText.isNotEmpty && newText != currentTagStr) {
                final newTags = List<String>.from(currentTags);
                final realIndex = newTags.indexOf(currentTagStr);
                if (realIndex != -1) {
                  newTags[realIndex] = newText;
                  ref.read(globalLibraryProvider.notifier).saveLibrary(widget.libraryName, newTags.join('\n'));
                }
              }
              Navigator.pop(context);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    
    final content = ref.watch(globalLibraryProvider)[widget.libraryName] ?? '';
    final currentTags = content.split('\n').where((e) => e.trim().isNotEmpty).toList();

    List<String> displayTags = currentTags;
    if (_searchQuery.trim().isNotEmpty) {
      final searchTerms = _searchQuery.split(RegExp(r'[,，]')).map((s) => s.trim().toLowerCase().replaceAll('_', ' ')).where((s) => s.isNotEmpty).toList();
      if (searchTerms.isNotEmpty) {
        displayTags = currentTags.where((t) {
          final normalizedTag = t.toLowerCase().replaceAll('_', ' ');
          return searchTerms.every((term) => normalizedTag.contains(term));
        }).toList();
      }
    }

    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        width: 620, height: 620,
        decoration: BoxDecoration(
          color: colorScheme.surface, borderRadius: BorderRadius.circular(8),
          boxShadow: [BoxShadow(color: colorScheme.shadow.withValues(alpha: 0.16), blurRadius: 24, offset: const Offset(0, 12))],
        ),
        child: Column(
          children: [
            // 标题栏
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              decoration: BoxDecoration(
                gradient: LinearGradient(colors: [colorScheme.tertiaryContainer.withValues(alpha: 0.3), colorScheme.secondaryContainer.withValues(alpha: 0.2)]),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
                border: Border(bottom: BorderSide(color: colorScheme.outlineVariant.withValues(alpha: 0.2))),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(color: colorScheme.tertiary.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
                    child: Icon(Icons.library_books, color: colorScheme.tertiary, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Text('编辑: ${widget.libraryName}', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                  const Spacer(),
                  IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close), iconSize: 20),
                ],
              ),
            ),
            
            // 内容区
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 🌟 完全对齐原版：标题 + 批量导入 + 一键清空
                    Row(
                      children: [
                        Text('标签列表 (${currentTags.length} 个)', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
                        const Spacer(),
                        IconButton(
                          icon: const Icon(Icons.paste, size: 20), 
                          tooltip: '批量导入', 
                          onPressed: () => _showImportDialog(currentTags),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_sweep, size: 20, color: Colors.redAccent), 
                          tooltip: '一键清空',
                          onPressed: () => ref.read(globalLibraryProvider.notifier).saveLibrary(widget.libraryName, ''),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    
                    // 搜索框
                    SizedBox(
                      height: 40,
                      child: TextField(
                        decoration: InputDecoration(
                          hintText: '搜索标签 (支持逗号多词搜索)', prefixIcon: const Icon(Icons.search, size: 18),
                          contentPadding: const EdgeInsets.symmetric(vertical: 0),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                        ),
                        onChanged: (value) => setState(() => _searchQuery = value),
                      ),
                    ),
                    const SizedBox(height: 12),

                    // 标签列表
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(color: colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(8)),
                        child: displayTags.isEmpty
                            ? Center(child: Text('暂无标签', style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant)))
                            : ListView.builder(
                                itemCount: displayTags.length,
                                itemBuilder: (context, index) {
                                  final fullTag = displayTags[index];
                                  
                                  String actualTag = fullTag;
                                  String commentStr = '';
                                  int lastColonIndex = fullTag.lastIndexOf(RegExp(r'[:：]'));
                                  if (lastColonIndex != -1) {
                                    String afterColon = fullTag.substring(lastColonIndex + 1);
                                    if (RegExp(r'[\u4e00-\u9fa5]').hasMatch(afterColon)) {
                                      actualTag = fullTag.substring(0, lastColonIndex).trim();
                                      commentStr = afterColon.trim();
                                    }
                                  }
                                  
                                  return Container(
                                    margin: const EdgeInsets.only(bottom: 6),
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                    decoration: BoxDecoration(
                                      color: colorScheme.surface, borderRadius: BorderRadius.circular(6),
                                      border: Border.all(color: colorScheme.outlineVariant.withValues(alpha: 0.5)),
                                    ),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: SelectableText.rich(
                                            TextSpan(
                                              children: [
                                                TextSpan(text: actualTag, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500)),
                                                if (commentStr.isNotEmpty)
                                                  TextSpan(text: ' $commentStr', style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.outline)),
                                              ],
                                            ),
                                          ),
                                        ),
                                        // 菜单
                                        PopupMenuButton<String>(
                                          icon: const Icon(Icons.more_vert, size: 18),
                                          tooltip: '选项',
                                          padding: EdgeInsets.zero,
                                          constraints: const BoxConstraints(),
                                          itemBuilder: (context) => [
                                            const PopupMenuItem(
                                              value: 'send',
                                              child: Row(children: [Icon(Icons.send, size: 16), SizedBox(width: 8), Text('发送到提示词')]),
                                            ),
                                            const PopupMenuItem(
                                              value: 'copy',
                                              child: Row(children: [Icon(Icons.copy, size: 16), SizedBox(width: 8), Text('复制')]),
                                            ),
                                            const PopupMenuItem(
                                              value: 'edit',
                                              child: Row(children: [Icon(Icons.edit, size: 16), SizedBox(width: 8), Text('编辑')]),
                                            ),
                                          ],
                                          onSelected: (value) {
                                            if (value == 'copy') {
                                              Clipboard.setData(ClipboardData(text: fullTag));
                                              AppToast.success(context, '已复制');
                                            } else if (value == 'edit') {
                                              _showEditTagDialog(fullTag, index, currentTags);
                                            } else if (value == 'send') {
                                              final notifier = ref.read(generationParamsNotifierProvider.notifier);
                                              final currentParams = ref.read(generationParamsNotifierProvider);
                                              final currentPrompt = currentParams.prompt.trim();
                                              final newPrompt = currentPrompt.isEmpty ? actualTag : '$currentPrompt, $actualTag';
                                              notifier.updatePrompt(newPrompt);
                                              AppToast.success(context, '已发送: $actualTag');
                                            }
                                          },
                                        ),
                                        // 删除
                                        IconButton(
                                          icon: const Icon(Icons.close, size: 18), tooltip: '删除',
                                          color: colorScheme.error.withValues(alpha: 0.8), 
                                          padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                                          onPressed: () {
                                            final newTags = List<String>.from(currentTags)..remove(fullTag);
                                            ref.read(globalLibraryProvider.notifier).saveLibrary(widget.libraryName, newTags.join('\n'));
                                          },
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}