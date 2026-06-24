import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nai_launcher/l10n/app_localizations.dart';

// 💡 引入全局分享接收器
import 'package:nai_launcher/core/utils/global_share_receiver.dart';

import 'core/shortcuts/default_shortcuts.dart';
import 'presentation/router/app_router.dart';
import 'presentation/providers/theme_provider.dart';
import 'presentation/providers/font_provider.dart';
import 'presentation/providers/font_scale_provider.dart';
import 'presentation/providers/locale_provider.dart';
import 'presentation/providers/background_refresh_provider.dart';
import 'presentation/providers/queue_execution_provider.dart';
import 'presentation/providers/subscription_provider.dart' hide anlasBalanceProvider;
import 'presentation/themes/app_theme.dart';
import 'presentation/widgets/shortcuts/shortcut_aware_widget.dart';
import 'presentation/widgets/shortcuts/shortcut_help_dialog.dart';

/// 全局副作用挂载层
class AppBootstrapEffects extends ConsumerStatefulWidget {
  final Widget child;
  final ProviderListenable<dynamic>? anlasWatcher;
  final ProviderListenable<dynamic>? backgroundRefresh;

  const AppBootstrapEffects({
    super.key,
    required this.child,
    this.anlasWatcher,
    this.backgroundRefresh,
  });

  @override
  ConsumerState<AppBootstrapEffects> createState() =>
      _AppBootstrapEffectsState();
}

class _AppBootstrapEffectsState extends ConsumerState<AppBootstrapEffects> {
  ProviderSubscription<dynamic>? _anlasWatcherSubscription;
  ProviderSubscription<dynamic>? _backgroundRefreshSubscription;

  @override
  void initState() {
    super.initState();
    _anlasWatcherSubscription = ref.listenManual(
      widget.anlasWatcher ?? anlasBalanceWatcherProvider,
      (_, __) {},
    );
    _backgroundRefreshSubscription = ref.listenManual(
      widget.backgroundRefresh ?? backgroundRefreshNotifierProvider,
      (_, __) {},
    );
  }

  @override
  void dispose() {
    _anlasWatcherSubscription?.close();
    _backgroundRefreshSubscription?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// NAI Launcher 主应用
class NAILauncherApp extends ConsumerWidget {
  const NAILauncherApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeType = ref.watch(themeNotifierProvider);
    final fontType = ref.watch(fontNotifierProvider);
    final fontScale = ref.watch(fontScaleNotifierProvider);
    final locale = ref.watch(localeNotifierProvider);
    final router = ref.watch(appRouterProvider);

    final globalShortcuts = <String, VoidCallback>{
      ShortcutIds.navigateToGeneration: () => router.go(AppRoutes.generation),
      ShortcutIds.navigateToLocalGallery: () => router.go(AppRoutes.localGallery),
      ShortcutIds.navigateToOnlineGallery: () => router.go(AppRoutes.onlineGallery),
      ShortcutIds.navigateToRandomConfig: () => router.go(AppRoutes.promptConfig),
      ShortcutIds.navigateToTagLibrary: () => router.go(AppRoutes.tagLibraryPage),
      ShortcutIds.navigateToStatistics: () => router.go(AppRoutes.statistics),
      ShortcutIds.navigateToSettings: () => router.go(AppRoutes.settings),
      ShortcutIds.navigateToVibeLibrary: () => router.go(AppRoutes.vibeLibrary),
      ShortcutIds.showShortcutHelp: () => ShortcutHelpDialog.show(context),
      ShortcutIds.toggleQueue: () {
        final isVisible = ref.read(queueManagementVisibleProvider);
        ref.read(queueManagementVisibleProvider.notifier).state = !isVisible;
      },
      ShortcutIds.toggleQueuePause: () {
        final executionState = ref.read(queueExecutionNotifierProvider);
        if (executionState.isPaused) {
          ref.read(queueExecutionNotifierProvider.notifier).resume();
        } else if (executionState.isRunning || executionState.isReady) {
          ref.read(queueExecutionNotifierProvider.notifier).pause();
        }
      },
      ShortcutIds.toggleTheme: () {
        ref.read(themeNotifierProvider.notifier).nextTheme();
      },
    };

    return AppBootstrapEffects(
      child: GlobalShortcuts(
        shortcuts: globalShortcuts,
        // 🚀 核心修复：把它放回最外层！与天地同寿，永不销毁！
        child: GlobalShareReceiver(
          child: MaterialApp.router(
            title: 'NAI Launcher',
            debugShowCheckedModeBanner: false,
            theme: AppTheme.getTheme(
              themeType,
              Brightness.light,
              fontConfig: fontType.fontFamily.isEmpty ? null : fontType,
            ),
            darkTheme: AppTheme.getTheme(
              themeType,
              Brightness.dark,
              fontConfig: fontType.fontFamily.isEmpty ? null : fontType,
            ),
            themeMode: ThemeMode.dark,
            locale: locale,
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            routerConfig: router,
            // 恢复纯净的 builder
            builder: (context, child) {
              return MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(fontScale),
                ),
                child: child!,
              );
            },
          ),
        ),
      ),
    );
  }
}