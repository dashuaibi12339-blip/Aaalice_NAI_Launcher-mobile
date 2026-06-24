import 'dart:async'; // 👈 新增
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
// 移除：import 'package:tray_manager/tray_manager.dart';
import 'package:video_player_media_kit/video_player_media_kit.dart';
// 移除：import 'package:window_manager/window_manager.dart';

import 'package:timeago/timeago.dart' as timeago;

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
// 移除：import 'core/services/sqflite_bootstrap_service.dart';
import 'core/utils/app_error_reporter.dart'; // 👈 新增全局错误捕获
import 'core/utils/app_logger.dart';
import 'core/utils/hive_storage_helper.dart';
import 'data/datasources/local/nai_tags_data_source.dart';
import 'data/models/gallery/nai_image_metadata.dart';
import 'data/repositories/collection_repository.dart';
import 'data/repositories/gallery_folder_repository.dart';
import 'core/cache/gallery_cache_manager.dart';

import 'core/cache/tag_cache_service.dart';
import 'data/services/gallery/index.dart';
import 'data/services/image_metadata_service.dart';
import 'data/services/metadata/isolate_metadata_service.dart';
import 'data/services/search_index_service.dart';
import 'data/services/temp_image_service.dart';
import 'data/services/thumbnail_service.dart';
import 'presentation/providers/data_source_cache_provider.dart';
import 'presentation/providers/online_gallery_blacklist_provider.dart';
import 'presentation/screens/splash/app_bootstrap.dart';

AppLocalizations _getLocalizedStrings() {
  final box = Hive.box(StorageKeys.settingsBox);
  final localeCode = box.get(StorageKeys.locale, defaultValue: 'zh') as String;
  if (localeCode == 'en') {
    return AppLocalizationsEn();
  }
  return AppLocalizationsZh();
}

// 工程师注：已注释掉 WindowStateObserver, AppTrayListener, AppWindowListener, setupWindowsWakeUpChannel
// 因为这些在手机端会导致编译错误。

void main() {
  final bootstrap = runZonedGuarded<Future<void>>(
    _bootstrapApplication,
    (error, stackTrace) {
      AppErrorReporter.reportError(
        error,
        stackTrace,
        source: 'runZonedGuarded',
        fatal: true,
      );
    },
  );
  if (bootstrap != null) {
    unawaited(bootstrap);
  }
}

Future<void> _bootstrapApplication() async {
  WidgetsFlutterBinding.ensureInitialized();
  AppErrorReporter.installGlobalHandlers(); // 👈 新增：安装全局错误拦截

  SemanticsBinding.instance.ensureSemantics();

  await AppVersion.initialize(); // 👈 【新增】补上原作者的版本初始化  

  // 👈 更新：支持新的日志初始化参数
  await AppLogger.initialize(
    isTestEnvironment: false,
    enableFileLogging: false,
  );
  AppLogger.i('Application starting on Mobile', 'Main');


  PaintingBinding.instance.imageCache.maximumSize = 500; 
  PaintingBinding.instance.imageCache.maximumSizeBytes = 200 << 20; 

  // 工程师注：手机端不需要特别初始化 Windows 的 VideoPlayerMediaKit
  // VideoPlayerMediaKit.ensureInitialized(windows: true);

  // 工程师注：手机端使用自带的 sqflite，不需要桌面端的 FFI bootstrap
  // await SqfliteBootstrapService.instance.ensureInitialized();

  await HiveStorageHelper.instance.init();

  if (!Hive.isAdapterRegistered(24)) {
    Hive.registerAdapter(NaiImageMetadataAdapter());
  }
  if (!Hive.isAdapterRegistered(25)) {
    Hive.registerAdapter(CharacterPromptInfoAdapter());
  }

  try {
    final migrationResult = await DataMigrationService.instance.migrateAll();
    AppLogger.i('Startup migration result: $migrationResult', 'Main');
  } catch (e) {
    AppLogger.w('Startup migration failed (will continue): $e', 'Main');
  }

  AppLogger.i('等待数据库初始化...', 'Main');
  final container = ProviderContainer();

  try {
    final manager = await DatabaseManager.initialize();
    await manager.initialized;

    final stats = await manager.getStatistics();
    final tableStats = stats['tables'] as Map<String, int>? ?? {};
    final translationCount = tableStats['translations'] ?? 0;
    final cooccurrenceCount = tableStats['cooccurrences'] ?? 0;

    if (translationCount == 0 || cooccurrenceCount == 0) {
      AppLogger.w('核心数据缺失，执行恢复..', 'Main');
      await manager.recover();
    }
    AppLogger.i('数据库初始化完成', 'Main');
  } catch (e, stack) {
    AppLogger.e('数据库初始化失败', e, stack, 'Main');
  }

  await Hive.openBox(StorageKeys.settingsBox);
  
  // 👈 新增：读取并设置文件日志开关
  final settingsBox = Hive.box(StorageKeys.settingsBox);
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
  await ImageMetadataService().initialize();

  Future.microtask(() async {
    try {
      await L2CacheCleaner().checkAndClean();
    } catch (e) {}
  });

  final thumbnailService = ThumbnailService.instance;
  await thumbnailService.initialize();

  await CollectionRepository.instance.initialize();
  await ScanStateManager.instance.initialize();
  await IsolateMetadataService.instance.initialize();
  
  final searchIndexService = SearchIndexService();
  await searchIndexService.init();

  final tagCacheService = TagCacheService();
  await tagCacheService.init();

  Future.microtask(() async {
    try {
      final rootPath = await GalleryFolderRepository.instance.getRootPath();
      if (rootPath != null) {
        await thumbnailService.cleanupNestedThumbs(rootPath);
      }
    } catch (e) {}
  });

  final shortcutStorage = ShortcutStorage();
  await shortcutStorage.init();

  timeago.setLocaleMessages('zh', timeago.ZhCnMessages());
  timeago.setLocaleMessages('zh_CN', timeago.ZhCnMessages());

  Future.microtask(() async {
    try {
      await TempImageService().cleanupOldTempFiles();
    } catch (e) {}
  });

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

  // 工程师注：移除了所有 Platform.isWindows 的窗口和托盘管理代码
  // 工程师注：移除了系统代理配置（手机端通常不需要在应用内强行劫持代理）

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const AppBootstrap(),
    ),
  );
}