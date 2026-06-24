import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../core/constants/storage_keys.dart';
import '../../core/storage/local_storage_service.dart';
import '../../core/storage/queue_state_storage.dart';
import '../../data/models/queue/replication_task.dart';
import '../../data/models/queue/replication_task_status.dart';
import '../../data/models/queue/failure_handling_strategy.dart';
import 'image_generation_provider.dart';
import 'notification_settings_provider.dart';
import 'replication_queue_provider.dart';
import 'fixed_tags_provider.dart';
import 'quality_preset_provider.dart';
import 'uc_preset_provider.dart';
import '../../core/services/notification_service.dart';

part 'queue_execution_provider.g.dart';

enum QueueExecutionStatus { idle, ready, running, paused, completed }

class QueueExecutionState {
  final QueueExecutionStatus status;
  final int completedCount;
  final int failedCount;
  final int skippedCount;
  final String? currentTaskId;
  final int retryCount;
  final List<String> failedTaskIds;
  final bool autoExecuteEnabled;
  final double taskIntervalSeconds;
  final FailureHandlingStrategy failureStrategy;
  final int totalTasksInSession;
  final DateTime? sessionStartTime;

  const QueueExecutionState({
    this.status = QueueExecutionStatus.idle,
    this.completedCount = 0,
    this.failedCount = 0,
    this.skippedCount = 0,
    this.currentTaskId,
    this.retryCount = 0,
    this.failedTaskIds = const [],
    this.autoExecuteEnabled = false,
    this.taskIntervalSeconds = 0.0,
    this.failureStrategy = FailureHandlingStrategy.skip,
    this.totalTasksInSession = 0,
    this.sessionStartTime,
  });

  QueueExecutionState copyWith({
    QueueExecutionStatus? status,
    int? completedCount,
    int? failedCount,
    int? skippedCount,
    String? currentTaskId,
    int? retryCount,
    List<String>? failedTaskIds,
    bool? autoExecuteEnabled,
    double? taskIntervalSeconds,
    FailureHandlingStrategy? failureStrategy,
    int? totalTasksInSession,
    DateTime? sessionStartTime,
  }) {
    return QueueExecutionState(
      status: status ?? this.status,
      completedCount: completedCount ?? this.completedCount,
      failedCount: failedCount ?? this.failedCount,
      skippedCount: skippedCount ?? this.skippedCount,
      currentTaskId: currentTaskId ?? this.currentTaskId,
      retryCount: retryCount ?? this.retryCount,
      failedTaskIds: failedTaskIds ?? this.failedTaskIds,
      autoExecuteEnabled: autoExecuteEnabled ?? this.autoExecuteEnabled,
      taskIntervalSeconds: taskIntervalSeconds ?? this.taskIntervalSeconds,
      failureStrategy: failureStrategy ?? this.failureStrategy,
      totalTasksInSession: totalTasksInSession ?? this.totalTasksInSession,
      sessionStartTime: sessionStartTime ?? this.sessionStartTime,
    );
  }

  bool get isRunning => status == QueueExecutionStatus.running;
  bool get isReady => status == QueueExecutionStatus.ready;
  bool get isPaused => status == QueueExecutionStatus.paused;
  bool get isIdle => status == QueueExecutionStatus.idle;
  bool get isCompleted => status == QueueExecutionStatus.completed;

  double get progress {
    if (totalTasksInSession <= 0) return 0.0;
    return (completedCount + failedCount + skippedCount) / totalTasksInSession;
  }
  bool get hasFailedTasks => failedTaskIds.isNotEmpty;
}

class QueueSettings {
  final int retryCount;
  final double retryIntervalSeconds;
  final bool autoExecuteEnabled;
  final double taskIntervalSeconds;
  final FailureHandlingStrategy failureStrategy;

  const QueueSettings({
    this.retryCount = 10,
    this.retryIntervalSeconds = 1.0,
    this.autoExecuteEnabled = false,
    this.taskIntervalSeconds = 0.0,
    this.failureStrategy = FailureHandlingStrategy.skip,
  });

  Duration get retryInterval => Duration(milliseconds: (retryIntervalSeconds * 1000).toInt());
  Duration get taskInterval => Duration(milliseconds: (taskIntervalSeconds * 1000).toInt());
}

@Riverpod(keepAlive: true)
class QueueExecutionNotifier extends _$QueueExecutionNotifier {
  late final QueueStateStorage _stateStorage;

  @override
  QueueExecutionState build() {
    _stateStorage = ref.read(queueStateStorageProvider);

    ref.listen<ImageGenerationState>(
      imageGenerationNotifierProvider,
      (previous, next) {
        _onGenerationStateChanged(previous, next);
      },
    );

    // ✅ 修复：加新任务时如果是完成状态(绿)，重置回空闲(灰)
    ref.listen<ReplicationQueueState>(
      replicationQueueNotifierProvider,
      (previous, next) {
        if (state.status == QueueExecutionStatus.completed && next.tasks.isNotEmpty) {
          startNewSession();
        }
      },
    );

    return _loadFromStorageSync();
  }

  QueueExecutionState _loadFromStorageSync() {
    try {
      final data = _stateStorage.loadExecutionState();
      return QueueExecutionState(
        autoExecuteEnabled: data.autoExecuteEnabled,
        taskIntervalSeconds: data.taskIntervalSeconds,
        failureStrategy: data.failureStrategy,
      );
    } catch (e) {
      return const QueueExecutionState();
    }
  }

  Future<void> _saveToStorage() async {
    await _stateStorage.saveExecutionState(
      QueueExecutionStateData(
        completedCount: state.completedCount,
        failedCount: state.failedCount,
        skippedCount: state.skippedCount,
        autoExecuteEnabled: state.autoExecuteEnabled,
        taskIntervalSeconds: state.taskIntervalSeconds,
        failureStrategy: state.failureStrategy,
        isPaused: state.isPaused,
        currentTaskId: state.currentTaskId,
        failedTaskIds: state.failedTaskIds,
      ),
    );
  }

  QueueSettings _getSettings() {
    final storage = ref.read(localStorageServiceProvider);
    return QueueSettings(
      retryCount: storage.getSetting<int>(StorageKeys.queueRetryCount, defaultValue: 10) ?? 10,
      retryIntervalSeconds: storage.getSetting<double>(StorageKeys.queueRetryInterval, defaultValue: 1.0) ?? 1.0,
      autoExecuteEnabled: state.autoExecuteEnabled,
      taskIntervalSeconds: state.taskIntervalSeconds,
      failureStrategy: state.failureStrategy,
    );
  }

  Future<void> setAutoExecute(bool enabled) async {
    state = state.copyWith(autoExecuteEnabled: enabled);
    await _saveToStorage();
    if (enabled && state.status == QueueExecutionStatus.paused) {
      resume();
    } else if (enabled && state.status == QueueExecutionStatus.ready) {
      final queueState = ref.read(replicationQueueNotifierProvider);
      if (queueState.tasks.isNotEmpty) _triggerSilentGenerate(queueState.tasks.first);
    }
  }

  Future<void> setTaskInterval(double seconds) async {
    state = state.copyWith(taskIntervalSeconds: seconds.clamp(0.0, 10.0));
    await _saveToStorage();
  }

  Future<void> setFailureStrategy(FailureHandlingStrategy strategy) async {
    state = state.copyWith(failureStrategy: strategy);
    await _saveToStorage();
  }

  Future<void> pause() async {
    if (state.status != QueueExecutionStatus.running && state.status != QueueExecutionStatus.ready) return;
    state = state.copyWith(status: QueueExecutionStatus.paused);
    await _saveToStorage();
  }

  Future<void> resume() async {
    final queueState = ref.read(replicationQueueNotifierProvider);
    if (queueState.isEmpty) return;

    // 1. 如果是从灰色(空闲)状态首次启动，或者上个队列刚跑完的绿色状态
    if (state.status == QueueExecutionStatus.idle || 
        state.status == QueueExecutionStatus.completed ||
        state.completedCount >= state.totalTasksInSession) {
      startNewSession(); // 清零计分板
      
      final nextTask = queueState.tasks.first;
      state = state.copyWith(
        totalTasksInSession: queueState.count,
        sessionStartTime: DateTime.now(),
        retryCount: 0,
      );

      _triggerSilentGenerate(nextTask);
      return;
    } 

    // 2. 如果是从黄色(暂停)状态恢复，直接开火
    final nextTask = queueState.tasks.firstWhere(
      (t) => t.id == state.currentTaskId, 
      orElse: () => queueState.tasks.first
    );
    _triggerSilentGenerate(nextTask);
  }

  void prepareNextTask() {
    final queueState = ref.read(replicationQueueNotifierProvider);
    if (queueState.isEmpty) {
      state = state.copyWith(status: QueueExecutionStatus.idle);
      return;
    }

    final nextTask = queueState.tasks.first;
    final isNewSession = state.totalTasksInSession == 0;

    state = state.copyWith(
      retryCount: 0,
      totalTasksInSession: isNewSession ? queueState.count : state.totalTasksInSession,
      sessionStartTime: isNewSession ? DateTime.now() : state.sessionStartTime,
    );
    _saveToStorage();
    
    // 💥 终极修复：直接干掉恶心的 ready 状态和判断！
    _triggerSilentGenerate(nextTask);
  }

  // ✅ 核心魔法：完全不碰UI，直接在内存拼装参数并发给生成器
  void _triggerSilentGenerate(ReplicationTask task) {
    state = state.copyWith(status: QueueExecutionStatus.running, currentTaskId: task.id);
    if (task.id.isNotEmpty) {
      ref.read(replicationQueueNotifierProvider.notifier).updateTaskStatus(task.id, ReplicationTaskStatus.running);
    }

    // 内存拼接固定词
    final fixedTagsState = ref.read(fixedTagsNotifierProvider);
    var finalPrompt = fixedTagsState.applyToPrompt(task.prompt);

    final currentParams = ref.read(generationParamsNotifierProvider);
    final model = currentParams.model;

    final qualityContent = ref.read(qualityPresetNotifierProvider.notifier).getEffectiveContent(model);
    if (qualityContent?.isNotEmpty == true) {
      finalPrompt = finalPrompt.isEmpty ? qualityContent! : '$finalPrompt, $qualityContent';
    }
    final ucContent = ref.read(ucPresetNotifierProvider.notifier).getEffectiveContent(model);

    // 构造最终参数
    final runParams = currentParams.copyWith(
      prompt: task.prompt,
      // 负向提示词沿用主界面当前设置
    );
   
    // 直接静默触发生成！
    ref.read(imageGenerationNotifierProvider.notifier).generate(runParams);
  }
    
  void startExecution() {
    if (state.status != QueueExecutionStatus.ready) return;
    state = state.copyWith(status: QueueExecutionStatus.running);
    if (state.currentTaskId != null) {
      ref.read(replicationQueueNotifierProvider.notifier).updateTaskStatus(state.currentTaskId!, ReplicationTaskStatus.running);
    }
  }

  void stopExecution() {
    state = state.copyWith(status: QueueExecutionStatus.idle, currentTaskId: null);
    _saveToStorage();
  }

  void _onGenerationStateChanged(ImageGenerationState? previous, ImageGenerationState next) {
    if (previous?.status == GenerationStatus.generating && next.status == GenerationStatus.completed) {
      final isQueueMode = state.status == QueueExecutionStatus.running || state.status == QueueExecutionStatus.ready;
      if (isQueueMode) {
        _onTaskCompleted();
      } else {
        _triggerGenerationNotification();
      }
      return;
    }

    if (state.status != QueueExecutionStatus.running && state.status != QueueExecutionStatus.ready) return;

    if (previous?.status != GenerationStatus.generating && next.status == GenerationStatus.generating) {
      if (state.status == QueueExecutionStatus.ready) startExecution();
      return;
    }

    if (previous?.status == GenerationStatus.generating && next.status == GenerationStatus.error) {
      _onTaskError();
      return;
    }

    if (next.status == GenerationStatus.cancelled) {
      stopExecution();
      return;
    }
  }

  void _triggerGenerationNotification() {
    final settings = ref.read(notificationSettingsNotifierProvider);
    if (!settings.soundEnabled) return;
    Future.microtask(() async {
      await NotificationService.instance.notifyGenerationComplete(playSound: settings.soundEnabled, customSoundPath: settings.customSoundPath);
    });
  }

  Future<void> _onTaskCompleted() async {
    final currentTaskId = state.currentTaskId;
    if (currentTaskId != null) {
      ref.read(replicationQueueNotifierProvider.notifier).updateTaskStatus(currentTaskId, ReplicationTaskStatus.completed);
    }
    await ref.read(replicationQueueNotifierProvider.notifier).markCompleted();
    state = state.copyWith(completedCount: state.completedCount + 1, retryCount: 0);
    await _saveToStorage();

    if (state.isPaused) return;

    if (state.taskIntervalSeconds > 0) {
      await Future.delayed(Duration(milliseconds: (state.taskIntervalSeconds * 1000).toInt()));
    }
    _processNextTask();
  }

  Future<void> _onTaskError() async {
    final settings = _getSettings();
    if (state.retryCount < settings.retryCount) {
      state = state.copyWith(retryCount: state.retryCount + 1);
      await Future.delayed(settings.retryInterval);

      if (state.status != QueueExecutionStatus.running) return;
      state = state.copyWith(status: QueueExecutionStatus.ready);
      
      if (state.autoExecuteEnabled) {
        final queueState = ref.read(replicationQueueNotifierProvider);
        if (queueState.tasks.isNotEmpty) _triggerSilentGenerate(queueState.tasks.first);
      }
    } else {
      await _handleFailedTask();
    }
  }

  Future<void> _handleFailedTask() async {
    final currentTaskId = state.currentTaskId;
    if (currentTaskId == null) {
      _processNextTask();
      return;
    }

    final queueNotifier = ref.read(replicationQueueNotifierProvider.notifier);
    final task = ref.read(replicationQueueNotifierProvider).tasks.firstWhere((t) => t.id == currentTaskId, orElse: () => ReplicationTask.create(prompt: ''));

    switch (state.failureStrategy) {
      case FailureHandlingStrategy.autoRetry:
        await queueNotifier.remove(currentTaskId);
        await queueNotifier.add(task.copyWith(status: ReplicationTaskStatus.pending, retryCount: 0, errorMessage: null));
        break;
      case FailureHandlingStrategy.skip:
        await queueNotifier.moveToFailedPool(currentTaskId);
        break;
      case FailureHandlingStrategy.pauseAndWait:
        await queueNotifier.updateTaskStatus(currentTaskId, ReplicationTaskStatus.failed);
        state = state.copyWith(status: QueueExecutionStatus.paused, failedCount: state.failedCount + 1, failedTaskIds: [...state.failedTaskIds, currentTaskId], retryCount: 0);
        await _saveToStorage();
        return;
    }

    state = state.copyWith(failedCount: state.failedCount + 1, failedTaskIds: [...state.failedTaskIds, currentTaskId], retryCount: 0);
    await _saveToStorage();
    _processNextTask();
  }

  void _processNextTask() {
    final queueState = ref.read(replicationQueueNotifierProvider);

    if (queueState.tasks.isEmpty) {
      state = state.copyWith(status: QueueExecutionStatus.completed, currentTaskId: null);
      _saveToStorage();
      _triggerGenerationNotification();
      return;
    }

    final nextTask = queueState.tasks.first;

    if (state.autoExecuteEnabled) {
      _triggerSilentGenerate(nextTask);
    } else {
      // ✅ 没开自动，跑完一张必定变黄(暂停)！
      state = state.copyWith(status: QueueExecutionStatus.paused, currentTaskId: nextTask.id, retryCount: 0);
      _saveToStorage();
    }
  }

  Future<void> retryFailedTask(String taskId) async {
    final queueNotifier = ref.read(replicationQueueNotifierProvider.notifier);
    await queueNotifier.retryFailedTask(taskId);
    state = state.copyWith(failedTaskIds: state.failedTaskIds.where((id) => id != taskId).toList());
    await _saveToStorage();
  }

  Future<void> requeueFailedTask(String taskId) async {
    final queueNotifier = ref.read(replicationQueueNotifierProvider.notifier);
    await queueNotifier.requeueFailedTask(taskId);
    state = state.copyWith(failedTaskIds: state.failedTaskIds.where((id) => id != taskId).toList());
    await _saveToStorage();
  }

  Future<void> clearFailedTasks() async {
    final queueNotifier = ref.read(replicationQueueNotifierProvider.notifier);
    await queueNotifier.clearFailedTasks();
    state = state.copyWith(failedTaskIds: []);
    await _saveToStorage();
  }

  void reset() {
    state = const QueueExecutionState();
    _saveToStorage();
  }

  void startNewSession() {
    final queueState = ref.read(replicationQueueNotifierProvider);
    state = state.copyWith(
      status: QueueExecutionStatus.idle,
      currentTaskId: queueState.tasks.isNotEmpty ? queueState.tasks.first.id : null,
      completedCount: 0,
      failedCount: 0,
      skippedCount: 0,
      failedTaskIds: [],
      totalTasksInSession: queueState.count,
      sessionStartTime: DateTime.now(),
    );
    _saveToStorage();
  }
}

@riverpod
QueueSettings queueSettings(Ref ref) {
  final storage = ref.watch(localStorageServiceProvider);
  final executionState = ref.watch(queueExecutionNotifierProvider);

  return QueueSettings(
    retryCount: storage.getSetting<int>(StorageKeys.queueRetryCount, defaultValue: 10) ?? 10,
    retryIntervalSeconds: storage.getSetting<double>(StorageKeys.queueRetryInterval, defaultValue: 1.0) ?? 1.0,
    autoExecuteEnabled: executionState.autoExecuteEnabled,
    taskIntervalSeconds: executionState.taskIntervalSeconds,
    failureStrategy: executionState.failureStrategy,
  );
}