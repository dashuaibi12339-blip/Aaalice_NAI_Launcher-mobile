import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:video_player_media_kit/video_player_media_kit.dart';
import 'package:timeago/timeago.dart' as timeago;

// 鸿蒙强行覆盖的核心插件接口
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:nai_launcher/core/utils/my_shared_prefs.dart';

// 👇 以下全部是你原版的 import，原封不动保留！
import 'core/constants/app_version.dart';
import 'core/constants/storage_keys.dart';
import 'l10n/app_localizations.dart';
import 'l10n/app_localizations_en.dart';
import 'l10n/app_localizations_zh.dart';
import 'core/network/proxy_service.dart';
import 'core/network/system_proxy_http_overrides.dart';
import 'core/shortcuts/shortcut_storage.dart';
import 'core/database/database_manager.dart';
import 'core/services/data_migration_service.dart';
import 'core/utils/app_error_reporter.dart';
import 'core/utils/app_logger.dart';
import 'core/utils/hive_storage_helper.dart';
import 'data/datasources/local/nai_tags_data_source.dart';
import 'data/models/gallery/nai_image_metadata.dart';
import 'data/repositories/collection_repository.dart';
import 'data/repositories/gallery_folder_repository.dart';
import 'core/cache/gallery_cache_manager.dart';
import 'core/cache/tag_cache_service.dart';
import 'data/services/gallery/index.dart'; // 👈 ScanStateManager 在这里！
import 'data/services/image_metadata_service.dart';
import 'data/services/metadata/isolate_metadata_service.dart';
import 'data/services/search_index_service.dart';
import 'data/services/temp_image_service.dart';
import 'data/services/thumbnail_service.dart';
import 'presentation/providers/data_source_cache_provider.dart';
import 'presentation/providers/online_gallery_blacklist_provider.dart';
import 'presentation/screens/splash/app_bootstrap.dart';

void main() {
  final bootstrap = runZonedGuarded<Future<void>>(
    _bootstrapApplication,
    (error, stackTrace) {
      print('🔥 [全局错误拦截] $error');
    },
  );
  if (bootstrap != null) {
    unawaited(bootstrap);
  }
}

Future<void> _bootstrapApplication() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // 1. 欺骗 UI 层，画出安卓风格，解决红屏 (💡 必须加上 if 判断，仅限调试期使用！)
  if (kDebugMode) {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
  }

  // 2. 欺骗路径插件，防止底层 C++ 崩溃
  PathProviderPlatform.instance = HarmonyOSPathProvider();
  
  // 3. 替换安全存储底层
  FlutterSecureStoragePlatform.instance = HarmonySecureStorage();
  FlutterSecureStorage.setMockInitialValues({});

  // 4. 欺骗包信息插件
  PackageInfo.setMockInitialValues(
    appName: 'NAI Launcher',
    packageName: 'com.example.nai_launcher',
    version: '1.0.0 (HarmonyOS)',
    buildNumber: '1',
    buildSignature: 'harmony',
  );
  SharedPreferences.setMockInitialValues({});

  AppErrorReporter.installGlobalHandlers();
  SemanticsBinding.instance.ensureSemantics();

  await AppVersion.initialize();
  await AppLogger.initialize(isTestEnvironment: false, enableFileLogging: false);
  print('🚀 Application starting on HarmonyOS');

  PaintingBinding.instance.imageCache.maximumSize = 500;
  PaintingBinding.instance.imageCache.maximumSizeBytes = 200 << 20;

  try {
    await HiveStorageHelper.instance.init();
  } catch (e) {
    Hive.init('/data/storage/el2/base/files'); 
  }

  if (!Hive.isAdapterRegistered(24)) Hive.registerAdapter(NaiImageMetadataAdapter());
  if (!Hive.isAdapterRegistered(25)) Hive.registerAdapter(CharacterPromptInfoAdapter());

  try {
    await DataMigrationService.instance.migrateAll();
  } catch (e) {}

  final container = ProviderContainer();

  // 撕掉伪装，让真实的报错直接抛出来！
  try {
    final manager = await DatabaseManager.initialize();
    await manager.initialized;

    // 👇 原作者新增：词库数据库自愈检查
    final stats = await manager.getStatistics();
    final tableStats = stats['tables'] as Map<String, int>? ?? {};
    final translationCount = tableStats['translations'] ?? 0;
    final cooccurrenceCount = tableStats['cooccurrences'] ?? 0;

    if (translationCount == 0 || cooccurrenceCount == 0) {
      print('⚠️ 核心数据缺失，执行恢复..');
      await manager.recover();
    }
    print('✅ 数据库初始化完成');
  } catch (e, stack) {
    print('❌ 数据库初始化失败: $e');
  }

  try {
    await Hive.openBox(StorageKeys.settingsBox);
    final settingsBox = Hive.box(StorageKeys.settingsBox);
    
    // 👇 【核心修复】：强行注入鸿蒙专属图片保存路径！
    settingsBox.put('gallery_root_path', '/data/storage/el2/base/files/NAI_Launcher/Images');

    final fileLoggingEnabled = settingsBox.get(StorageKeys.fileLoggingEnabled, defaultValue: false) == true;
    await AppLogger.setFileLoggingEnabled(fileLoggingEnabled);

    await Hive.openBox(StorageKeys.historyBox);
    await Hive.openBox(StorageKeys.tagCacheBox);
    await Hive.openBox(StorageKeys.galleryBox);
    await Hive.openBox(StorageKeys.localFavoritesBox);
    await Hive.openBox(StorageKeys.tagsBox);
    await Hive.openBox(StorageKeys.searchIndexBox);
    await Hive.openBox(StorageKeys.statisticsCacheBox);
    await Hive.openBox(StorageKeys.collectionsBox);
    await Hive.openBox(StorageKeys.replicationQueueBox);
    await Hive.openBox(StorageKeys.queueExecutionStateBox);
  } catch (e) {
    print('⚠️ Hive Box 打开失败: $e');
  }

  try { await ImageMetadataService().initialize(); } catch (e) {}
  Future.microtask(() async { try { await L2CacheCleaner().checkAndClean(); } catch (e) {} });

  try {
    await ThumbnailService.instance.initialize();
    await CollectionRepository.instance.initialize();
    await ScanStateManager.instance.initialize();
    await IsolateMetadataService.instance.initialize();
    
    final searchIndexService = SearchIndexService();
    await searchIndexService.init();

    final tagCacheService = TagCacheService();
    await tagCacheService.init();
  } catch (e) {}

  try { await ShortcutStorage().init(); } catch (e) {}

  timeago.setLocaleMessages('zh', timeago.ZhCnMessages());
  timeago.setLocaleMessages('zh_CN', timeago.ZhCnMessages());

  Future.microtask(() async { try { await TempImageService().cleanupOldTempFiles(); } catch (e) {} });

   // 👇 原作者新增：后台加载词库与画廊黑名单
  Future.microtask(() async {
    try {
      await container.read(naiTagsDataSourceProvider).loadData();
    } catch (e) {}
  });

  Future.delayed(const Duration(seconds: 5), () async {
    try {
      final notifier = container.read(danbooruTagsCacheNotifierProvider.notifier);
      await notifier.checkAndSyncArtists();
    } catch (e) {}
  });

  Future.delayed(const Duration(seconds: 8), () async {
    try {
      await container.read(onlineGalleryBlacklistNotifierProvider.notifier).syncOnStartup();
    } catch (e) {}
  });
 
   
  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const AppBootstrap(),
    ),
  );
}

/// ====================================================================
/// 🚀 鸿蒙专属路径适配器 (纯 Dart 实现，无需 C++ 原生代码)
/// ====================================================================
class HarmonyOSPathProvider extends PathProviderPlatform {
  static const String _harmonyBaseDir = '/data/storage/el2/base/files';
  static const String _harmonyCacheDir = '/data/storage/el2/base/cache';

  @override
  Future<String?> getTemporaryPath() async => _harmonyCacheDir;
  @override
  Future<String?> getApplicationSupportPath() async => _harmonyBaseDir;
  @override
  Future<String?> getLibraryPath() async => _harmonyBaseDir;
  @override
  Future<String?> getApplicationDocumentsPath() async => _harmonyBaseDir;
  @override
  Future<String?> getExternalStoragePath() async => _harmonyBaseDir;
  @override
  Future<List<String>?> getExternalCachePaths() async => [_harmonyCacheDir];
  @override
  Future<List<String>?> getExternalStoragePaths({StorageDirectory? type}) async => [_harmonyBaseDir];
  @override
  Future<String?> getDownloadsPath() async => _harmonyBaseDir;
}

/// ====================================================================
/// 🚀 鸿蒙专属安全存储拦截器 (纯内存/普通文件替代方案)
/// ====================================================================
class HarmonySecureStorage extends FlutterSecureStoragePlatform {
  final Map<String, String> _cache = {};

  @override
  Future<String?> read({required String key, required Map<String, String> options}) async => _cache[key];

  @override
  Future<void> write({required String key, required String value, required Map<String, String> options}) async => _cache[key] = value;

  @override
  Future<void> delete({required String key, required Map<String, String> options}) async => _cache.remove(key);

  @override
  Future<void> deleteAll({required Map<String, String> options}) async => _cache.clear();

  @override
  Future<Map<String, String>> readAll({required Map<String, String> options}) async => Map.from(_cache);

  @override
  Future<bool> containsKey({required String key, required Map<String, String> options}) async => _cache.containsKey(key);
}