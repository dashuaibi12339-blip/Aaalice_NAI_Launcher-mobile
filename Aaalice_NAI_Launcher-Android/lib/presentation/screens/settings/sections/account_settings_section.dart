import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nai_launcher/core/utils/localization_extension.dart';

import '../../../providers/auth_provider.dart';
import '../../../providers/account_manager_provider.dart';
import '../../../widgets/common/app_toast.dart';
import '../../../widgets/settings/account_detail_tile.dart';
import '../../../widgets/settings/account_profile_sheet.dart';
import '../widgets/settings_card.dart';

/// 账户设置板块
///
/// 显示当前账户信息，支持编辑账户资料、切换账号、添加账号和退出登录。
class AccountSettingsSection extends ConsumerStatefulWidget {
  const AccountSettingsSection({super.key});

  @override
  ConsumerState<AccountSettingsSection> createState() =>
      _AccountSettingsSectionState();
}

class _AccountSettingsSectionState extends ConsumerState<AccountSettingsSection> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    
    // 监听登录状态
    final authState = ref.watch(authNotifierProvider);
    final currentAccountId = authState.accountId;
    final isLoggedIn = currentAccountId != null;

    // 监听账号管理器状态，获取所有账号
    final accountManagerState = ref.watch(accountManagerNotifierProvider);
    final allAccounts = accountManagerState.accounts;
    
    // 过滤出除了当前登录账号以外的“其他账号”，用于切换
    final otherAccounts = allAccounts.where((a) => a.id != currentAccountId).toList();

    return SettingsCard(
      title: context.l10n.settings_account,
      icon: Icons.person,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 1. 当前登录账号信息卡片
            AccountDetailTile(
              onEdit: () => _showProfileSheet(context),
              onLogin: () => _navigateToLogin(context),
            ),
            
            // 如果已登录，显示完整的账号管理菜单
            if (isLoggedIn) ...[
              const SizedBox(height: 8),
              Divider(height: 1, color: theme.dividerColor.withValues(alpha: 0.3)),
              
              // 2. 账号切换列表（如果有其他账号）
              if (otherAccounts.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.only(left: 16, top: 12, bottom: 4),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '切换账号', 
                      style: TextStyle(
                        fontSize: 12, 
                        color: theme.colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
                ...otherAccounts.map((account) => ListTile(
                  leading: CircleAvatar(
                    radius: 16,
                    backgroundColor: theme.colorScheme.primaryContainer,
                    child: Text(
                      account.displayName.isNotEmpty 
                          ? account.displayName.characters.first.toUpperCase() 
                          : '?',
                      style: TextStyle(
                        fontSize: 14, 
                        color: theme.colorScheme.onPrimaryContainer,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  title: Text(
                    account.displayName,
                    style: const TextStyle(fontSize: 14),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    account.email,
                    style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurfaceVariant),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: FilledButton.tonal(
                    onPressed: () => _switchAccount(context, account.id),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(60, 30),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                    ),
                    child: const Text('切换', style: TextStyle(fontSize: 12)),
                  ),
                  onTap: () => _switchAccount(context, account.id),
                )),
                Divider(height: 1, color: theme.dividerColor.withValues(alpha: 0.3)),
              ],

              // 3. 添加账号
              ListTile(
                leading: Icon(Icons.person_add_alt_1, size: 22, color: theme.colorScheme.primary),
                title: const Text('添加账号', style: TextStyle(fontSize: 14)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                onTap: () => _navigateToLogin(context),
              ),

              // 4. 退出登录
              ListTile(
                leading: const Icon(Icons.logout, color: Colors.redAccent, size: 22),
                title: const Text('退出登录', style: TextStyle(color: Colors.redAccent, fontSize: 14)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                onTap: () => _handleLogout(context),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // 执行账号切换
  void _switchAccount(BuildContext context, String accountId) async {
    try {
      // 1. 获取目标账号的 Token
      final token = await ref.read(accountManagerNotifierProvider.notifier).getAccountToken(accountId);
      
      if (token == null) {
        if (context.mounted) {
          AppToast.error(context, context.l10n.auth_tokenNotFound);
        }
        return;
      }

      // 2. 获取目标账号的完整信息
      final account = ref.read(accountManagerNotifierProvider).accounts.firstWhere((a) => a.id == accountId);
      
      // 3. 设为默认账号
      await ref.read(accountManagerNotifierProvider.notifier).setDefaultAccount(accountId);
      
      // 4. 调用原作者正确的切换账号方法
      final success = await ref.read(authNotifierProvider.notifier).switchAccount(
        account.id,
        token,
        displayName: account.displayName,
        accountType: account.accountType,
      );
      
      if (context.mounted) {
        if (success) {
          AppToast.success(context, '账号已切换');
        } else {
          AppToast.error(context, '切换失败，请检查网络');
        }
      }
    } catch (e) {
      if (context.mounted) {
        AppToast.error(context, '切换失败: $e');
      }
    }
  }

  // 退出登录的二次确认弹窗与逻辑
  void _handleLogout(BuildContext context) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('退出登录'),
        content: const Text('确定要退出当前账号吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              try {
                ref.read(authNotifierProvider.notifier).logout();
                AppToast.success(context, '已退出登录');
              } catch (e) {
                AppToast.error(context, '退出失败: $e');
              }
            },
            child: const Text('确定退出', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
  }

  /// 显示账号资料编辑底部面板
  void _showProfileSheet(BuildContext context) {
    final authState = ref.read(authNotifierProvider);
    final accountId = authState.accountId;

    if (accountId == null) {
      AppToast.info(context, '请先登录');
      return;
    }

    final accounts = ref.read(accountManagerNotifierProvider).accounts;
    final account = accounts.where((a) => a.id == accountId).firstOrNull;

    if (account == null) {
      AppToast.info(context, '未找到账号信息');
      return;
    }

    AccountProfileBottomSheet.show(
      context: context,
      account: account,
    );
  }

  /// 导航到登录页面（用于添加账号或首次登录）
  void _navigateToLogin(BuildContext context) {
    // 这里保留了原作者的逻辑。原作者目前是用 Toast 提示，
    // 如果 PC 端有弹窗组件，后续可以将这里改为显示登录 Dialog
    AppToast.info(context, '请前往登录页面');
  }
}