import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:flutter/services.dart'; // 👈 【新增】必须引入这个才能使用退出 App 的 API

import '../../core/utils/localization_extension.dart';
import '../../core/shortcuts/default_shortcuts.dart';
import '../providers/auth_provider.dart' show authNotifierProvider, AuthStatus;
import '../screens/auth/login_screen.dart';
import '../screens/generation/generation_screen.dart';
import '../screens/local_gallery/local_gallery_screen.dart';
import '../screens/online_gallery/online_gallery_screen.dart';
import '../screens/prompt_config/prompt_config_screen.dart';
import '../screens/settings/settings_screen.dart';
import '../screens/slideshow_screen.dart';
import '../screens/image_comparison_screen.dart';
import '../screens/statistics/statistics_screen.dart';
import '../screens/tag_library_page/tag_library_page_screen.dart';
import '../screens/vibe_library/vibe_library_screen.dart';
import '../widgets/drop/global_drop_handler.dart';
import '../widgets/navigation/main_nav_rail.dart';
import '../widgets/queue/floating_queue_button.dart';
import '../widgets/queue/queue_management_page.dart';

import '../widgets/shortcuts/shortcut_aware_widget.dart';
import '../widgets/shortcuts/shortcut_help_dialog.dart';

part 'app_router.g.dart';

final queueManagementVisibleProvider = StateProvider<bool>((ref) => false);
final floatingButtonClosedProvider = StateProvider<bool>((ref) => false);

final _homeKey = GlobalKey<NavigatorState>(debugLabel: 'home');
final _localGalleryKey = GlobalKey<NavigatorState>(debugLabel: 'localGallery');
final _onlineGalleryKey = GlobalKey<NavigatorState>(debugLabel: 'onlineGallery');
final _settingsKey = GlobalKey<NavigatorState>(debugLabel: 'settings');
final _promptConfigKey = GlobalKey<NavigatorState>(debugLabel: 'promptConfig');
final _statisticsKey = GlobalKey<NavigatorState>(debugLabel: 'statistics');
final _tagLibraryPageKey = GlobalKey<NavigatorState>(debugLabel: 'tagLibraryPage');
final _vibeLibraryKey = GlobalKey<NavigatorState>(debugLabel: 'vibeLibrary');

class AppRoutes {
  AppRoutes._();
  static const String login = '/login';
  static const String home = '/';
  static const String generation = '/generation';
  static const String localGallery = '/local-gallery';
  static const String onlineGallery = '/online-gallery';
  static const String settings = '/settings';
  static const String promptConfig = '/prompt-config';
  static const String slideshow = '/slideshow';
  static const String comparison = '/comparison';
  static const String statistics = '/statistics';
  static const String tagLibraryPage = '/tag-library';
  static const String vibeLibrary = '/vibe-library';
}

@Riverpod(keepAlive: true)
GoRouter appRouter(Ref ref) {
  final authStateNotifier = ValueNotifier<int>(0);

  ref.listen(
    authNotifierProvider.select((value) => value.status),
    (previous, next) {
      authStateNotifier.value++;
    },
  );

  ref.onDispose(() {
    authStateNotifier.dispose();
  });

  return GoRouter(
    initialLocation: AppRoutes.home,
    debugLogDiagnostics: true,
    refreshListenable: authStateNotifier,
    redirect: (context, state) {
      final authState = ref.read(authNotifierProvider);
      final isLoading = authState.status == AuthStatus.loading ||
          authState.status == AuthStatus.initial;
      final isLoggedIn = authState.isAuthenticated;
      final isLoggingIn = state.matchedLocation == AppRoutes.login;

      if (isLoading) return null;
      if (!isLoggedIn && !isLoggingIn) return AppRoutes.login;
      if (isLoggedIn && isLoggingIn) return AppRoutes.home;
      return null;
    },
    routes: [
      GoRoute(
        path: AppRoutes.login,
        name: 'login',
        pageBuilder: (context, state) => _buildFadeSlidePage(
          state: state,
          child: const LoginScreen(),
          slideOffset: const Offset(0.0, 0.05),
        ),
      ),
      StatefulShellRoute(
        navigatorContainerBuilder: (context, navigationShell, children) {
          return MainShell(
            navigationShell: navigationShell,
            children: children,
          );
        },
        builder: (context, state, navigationShell) => navigationShell,
        branches: [
          StatefulShellBranch(
            navigatorKey: _homeKey,
            routes: [
              GoRoute(
                path: AppRoutes.home,
                name: 'home',
                pageBuilder: (context, state) => _buildFadePage(
                  state: state,
                  child: const GenerationScreen(),
                ),
              ),
              GoRoute(
                path: AppRoutes.generation,
                name: 'generation',
                pageBuilder: (context, state) => _buildFadePage(
                  state: state,
                  child: const GenerationScreen(),
                ),
              ),
            ],
          ),
          StatefulShellBranch(
            navigatorKey: _localGalleryKey,
            routes: [
              GoRoute(
                path: AppRoutes.localGallery,
                name: 'localGallery',
                builder: (context, state) => const LocalGalleryScreen(),
                routes: [
                  GoRoute(
                    path: AppRoutes.slideshow,
                    name: 'slideshow',
                    pageBuilder: (context, state) {
                      final initialIndex = int.tryParse(
                            state.uri.queryParameters['initialIndex'] ?? '0',
                          ) ?? 0;
                      return MaterialPage(
                        key: state.pageKey,
                        child: SlideshowScreen(
                          images: const [],
                          initialIndex: initialIndex,
                        ),
                      );
                    },
                  ),
                  GoRoute(
                    path: AppRoutes.comparison,
                    name: 'comparison',
                    pageBuilder: (context, state) {
                      return MaterialPage(
                        key: state.pageKey,
                        child: const ImageComparisonScreen(
                          images: [],
                        ),
                      );
                    },
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            navigatorKey: _onlineGalleryKey,
            routes: [
              GoRoute(
                path: AppRoutes.onlineGallery,
                name: 'onlineGallery',
                builder: (context, state) => const OnlineGalleryScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            navigatorKey: _settingsKey,
            routes: [
              GoRoute(
                path: AppRoutes.settings,
                name: 'settings',
                builder: (context, state) => const SettingsScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            navigatorKey: _promptConfigKey,
            routes: [
              GoRoute(
                path: AppRoutes.promptConfig,
                name: 'promptConfig',
                builder: (context, state) => const PromptConfigScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            navigatorKey: _statisticsKey,
            routes: [
              GoRoute(
                path: AppRoutes.statistics,
                name: 'statistics',
                builder: (context, state) => const StatisticsScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            navigatorKey: _tagLibraryPageKey,
            routes: [
              GoRoute(
                path: AppRoutes.tagLibraryPage,
                name: 'tagLibraryPage',
                builder: (context, state) => const TagLibraryPageScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            navigatorKey: _vibeLibraryKey,
            routes: [
              GoRoute(
                path: AppRoutes.vibeLibrary,
                name: 'vibeLibrary',
                builder: (context, state) => const VibeLibraryScreen(),
              ),
            ],
          ),
        ],
      ),
    ],
    errorBuilder: (context, state) => Scaffold(
      body: Center(
        child: Text('Page not found: ${state.error}'),
      ),
    ),
  );
}

class MainShell extends ConsumerStatefulWidget {
  final StatefulNavigationShell navigationShell;
  final List<Widget> children;

  const MainShell({
    super.key,
    required this.navigationShell,
    required this.children,
  });

  @override
  ConsumerState<MainShell> createState() => _MainShellState();
}

class _MainShellState extends ConsumerState<MainShell> {
  @override
  Widget build(BuildContext context) {
    final currentIndex = widget.navigationShell.currentIndex;

    final contentStack = IndexedStack(
      index: currentIndex,
      children: widget.children.asMap().entries.map((entry) {
        final index = entry.key;
        final child = entry.value;
        final isActive = index == currentIndex;

        if (index == 1 || index == 2 || index == 7) {
          return TickerMode(
            enabled: isActive,
            child: child,
          );
        }
        if (!isActive) return const SizedBox.shrink();
        return child;
      }).toList(),
    );

    final dropEnabledContent = GlobalDropHandler(child: contentStack);

    final globalShortcuts = <String, VoidCallback>{
      ShortcutIds.navigateToGeneration: () => widget.navigationShell.goBranch(0),
      ShortcutIds.navigateToLocalGallery: () => widget.navigationShell.goBranch(2),
      ShortcutIds.navigateToOnlineGallery: () => widget.navigationShell.goBranch(3),
      ShortcutIds.navigateToSettings: () => widget.navigationShell.goBranch(4),
      ShortcutIds.navigateToRandomConfig: () => widget.navigationShell.goBranch(5),
      ShortcutIds.navigateToStatistics: () => widget.navigationShell.goBranch(6),
      ShortcutIds.navigateToTagLibrary: () => widget.navigationShell.goBranch(7),
      ShortcutIds.showShortcutHelp: () => ShortcutHelpDialog.show(context),
      ShortcutIds.toggleQueue: () {
        final isVisible = ref.read(queueManagementVisibleProvider);
        ref.read(queueManagementVisibleProvider.notifier).state = !isVisible;
      },
    };

    final shortcutEnabledContent = ShortcutAwareWidget(
      contextType: ShortcutContext.global,
      shortcuts: globalShortcuts,
      autofocus: true,
      child: dropEnabledContent,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= 800) {
          return DesktopShell(
            navigationShell: widget.navigationShell,
            content: shortcutEnabledContent,
          );
        }
        return MobileShell(
          navigationShell: widget.navigationShell,
          content: shortcutEnabledContent,
        );
      },
    );
  }
}

class DesktopShell extends ConsumerWidget {
  final StatefulNavigationShell navigationShell;
  final Widget content;

  const DesktopShell({
    super.key,
    required this.navigationShell,
    required this.content,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isQueueVisible = ref.watch(queueManagementVisibleProvider);

    return Scaffold(
      // 🌟 【核心修复】：为平板的电脑端布局包裹一层 SafeArea
      // 这样就能完美避开屏幕顶部的状态栏和摄像头刘海！
      body: SafeArea(
        top: true,     // 避开顶部刘海
        bottom: false, // 底部不需要额外边距
        left: true,    // 避开横屏时的左右刘海/挖孔
        right: true,
        child: Row(
          children: [
            MainNavRail(navigationShell: navigationShell),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  return Stack(
                    clipBehavior: Clip.none,
                    children: [
                      content,
                      FloatingQueueButton(
                        onTap: () => ref
                            .read(queueManagementVisibleProvider.notifier)
                            .state = !isQueueVisible,
                        containerSize: Size(constraints.maxWidth, constraints.maxHeight),
                      ),
                      _QueuePanel(
                        isVisible: isQueueVisible,
                        maxWidth: 650,
                        heightFactor: 0.85,
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 手机端专属外壳（增加防误触侧滑退出机制）
class MobileShell extends StatefulWidget {
  final StatefulNavigationShell navigationShell;
  final Widget content;

  const MobileShell({
    super.key,
    required this.navigationShell,
    required this.content,
  });

  @override
  State<MobileShell> createState() => _MobileShellState();
}

class _MobileShellState extends State<MobileShell> {
  // 👈 【新增】：记录上次点击返回的时间
  DateTime? _lastPressedAt;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // 👈 【核心修复】：用 PopScope 包裹 Scaffold 拦截返回手势
    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) {
        if (didPop) return;

        final now = DateTime.now();
        // 两次点击间隔大于 1.5 秒
        if (_lastPressedAt == null ||
            now.difference(_lastPressedAt!) > const Duration(milliseconds: 1500)) {
          _lastPressedAt = now;
          
          // 👈 【核心修复1】：瞬间清空之前的提示，绝对不排队！
          ScaffoldMessenger.of(context).clearSnackBars();
          
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              // 👈 【核心修复2】：文字居中，视觉更紧凑
              content: const Text('再滑一次退出应用', textAlign: TextAlign.center), 
              duration: const Duration(milliseconds: 800), // 800毫秒停留最舒服
              behavior: SnackBarBehavior.floating,
              width: 180, // 👈 【核心修复3】：限制宽度，让它变成一个小胶囊，而不是霸占整个屏幕底部
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
            ),
          );
          return;
        }

        // 2秒内连滑两次，安全退出
        SystemNavigator.pop();
      },
      
      child: Scaffold(
        body: widget.content,
        // 自定义可横向滚动的底部导航栏
        bottomNavigationBar: SafeArea(
          child: Container(
            height: 64,
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              border: Border(
                top: BorderSide(color: theme.dividerColor.withValues(alpha: 0.5), width: 1),
              ),
            ),
            child: ShaderMask(
              shaderCallback: (Rect bounds) {
                return LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: [
                    theme.colorScheme.surface,
                    Colors.transparent,
                    Colors.transparent,
                    theme.colorScheme.surface,
                  ],
                  stops: const [0.0, 0.05, 0.95, 1.0],
                ).createShader(bounds);
              },
              blendMode: BlendMode.dstOut,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    _buildNavItem(context, icon: Icons.auto_awesome, label: '生成', branchIndex: 0),
                    _buildNavItem(context, icon: Icons.photo_library, label: '本地画廊', branchIndex: 1),
                    _buildNavItem(context, icon: Icons.public, label: '在线画廊', branchIndex: 2),
                    _buildNavItem(context, icon: Icons.style, label: 'Vibe库', branchIndex: 7),
                    _buildNavItem(context, icon: Icons.book, label: '标签词库', branchIndex: 6),
                    _buildNavItem(context, icon: Icons.casino, label: '提示词配置', branchIndex: 4),
                    _buildNavItem(context, icon: Icons.bar_chart, label: '统计', branchIndex: 5),
                    _buildNavItem(context, icon: Icons.settings, label: '设置', branchIndex: 3),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNavItem(BuildContext context, {required IconData icon, required String label, required int branchIndex}) {
    // 注意这里改成了 widget.navigationShell
    final isSelected = widget.navigationShell.currentIndex == branchIndex;
    final theme = Theme.of(context);

    return InkWell(
      onTap: () => widget.navigationShell.goBranch(branchIndex),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        constraints: const BoxConstraints(minWidth: 64),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 24,
              color: isSelected ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                color: isSelected ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

const _defaultTransitionDuration = Duration(milliseconds: 300);
const _defaultCurve = Curves.easeOutCubic;

CustomTransitionPage<void> _buildFadePage({
  required GoRouterState state,
  required Widget child,
  Duration duration = _defaultTransitionDuration,
}) {
  return CustomTransitionPage(
    key: state.pageKey,
    child: child,
    transitionDuration: duration,
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      return FadeTransition(
        opacity: CurveTween(curve: _defaultCurve).animate(animation),
        child: child,
      );
    },
  );
}

CustomTransitionPage<void> _buildFadeSlidePage({
  required GoRouterState state,
  required Widget child,
  Offset slideOffset = Offset.zero,
  Duration duration = _defaultTransitionDuration,
}) {
  return CustomTransitionPage(
    key: state.pageKey,
    child: child,
    transitionDuration: duration,
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final curvedAnimation = CurveTween(curve: _defaultCurve).animate(animation);
      return FadeTransition(
        opacity: curvedAnimation,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: slideOffset,
            end: Offset.zero,
          ).animate(curvedAnimation),
          child: child,
        ),
      );
    },
  );
}

class _QueuePanel extends ConsumerWidget {
  final bool isVisible;
  final double maxWidth;
  final double heightFactor;

  const _QueuePanel({
    required this.isVisible,
    required this.maxWidth,
    required this.heightFactor,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        return Stack(
          children: [
            if (isVisible)
              Positioned.fill(
                child: GestureDetector(
                  onTap: () => ref
                      .read(queueManagementVisibleProvider.notifier)
                      .state = false,
                  child: Container(color: Colors.black54),
                ),
              ),
            TweenAnimationBuilder<Offset>(
              tween: Tween(
                begin: const Offset(0, 1),
                end: isVisible ? Offset.zero : const Offset(0, 1),
              ),
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutCubic,
              builder: (context, offset, child) {
                return IgnorePointer(
                  ignoring: offset.dy >= 0.5,
                  child: FractionalTranslation(
                    translation: offset,
                    child: child,
                  ),
                );
              },
              child: Align(
                alignment: Alignment.bottomCenter,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: maxWidth),
                  child: Material(
                    color: theme.scaffoldBackgroundColor,
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
                    clipBehavior: Clip.antiAlias,
                    child: SafeArea(
                      top: false,
                      child: SizedBox(
                        height: constraints.maxHeight * heightFactor,
                        child: const QueueManagementPage(),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}