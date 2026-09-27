import 'dart:async';

import 'daily_finalization.dart';
import 'developer_diagnostics.dart';
import 'dream.dart';
import 'markdown_memory_repository.dart';
import 'memory_recovery.dart';
import 'monthly_summary.dart';
import 'provider_settings_service.dart';

/// 空闲补办轮询的待办类别，附每日尝试上限（spec：Dream 每天至多
/// 8 次、日终归档补扫至多 10 轮、月压缩至多 10 轮）与诊断原因码。
enum _IdleCatchupItem {
  finalization(10, 'finalization'),
  monthlyCompression(10, 'monthly-compression'),
  dream(8, 'dream');

  const _IdleCatchupItem(this._dailyAttemptLimit, this._wireName);

  final int _dailyAttemptLimit;
  final String _wireName;
}

/// 后台失败记账（ticket 21）的任务类别：对外只透 [displayName] 的平实
/// 中文名，绝不透代码里的诊断标签与错误细节。
enum _CadenceTask {
  finalization('日终归档'),
  monthlyCompression('月压缩'),
  dream('梦境整理'),
  recovery('恢复扫描'),
  idleCatchup('空闲补办');

  const _CadenceTask(this.displayName);

  final String displayName;
}

/// 一条后台失败记账（ticket 21）：同一任务同一晚的连续失败共享一条，
/// 该任务之后成功即翻转为已恢复。纯内存旁路记录，不落盘。
final class _BackgroundFailureRecord {
  _BackgroundFailureRecord({required this.night, required this.failedAt})
    : count = 1;

  /// 记账时所在的「晚」（本机会话日期口径，与节奏模块其余记账同源）。
  String night;

  /// 最近一次失败时刻。
  DateTime failedAt;

  /// 本条记录累计失败次数（同一晚同一任务的重复失败只累计不另开）。
  int count = 1;

  /// 该任务失败之后是否已有一次成功（已恢复）。
  bool recovered = false;
}

/// 后台最近失败的只读快照（ticket 21）：页面经只读 API 取用展示。只含
/// 平实任务名、最近失败时刻、累计失败次数与是否已恢复，绝不透内部
/// 错误原文、堆栈或路径。
final class BackgroundFailureStatus {
  const BackgroundFailureStatus({
    required this.task,
    required this.failedAt,
    required this.count,
    required this.recovered,
  });

  /// 任务的平实中文名（日终归档/月压缩/梦境整理/恢复扫描/空闲补办）。
  final String task;

  /// 该条记录最近一次失败的时刻（本机时间）。
  final DateTime failedAt;

  /// 本条失败记录累计失败次数。
  final int count;

  /// 该任务失败之后是否已有一次成功（已恢复）。
  final bool recovered;
}

/// 记忆节奏（ticket 22 / ADR 0002）：交付后时间节奏链独立模块。
/// 日终归档、月压缩与 Dream 的调度与执行，连同启动恢复扫描与空闲
/// 补办，从聊天交付服务迁到这里集中编排：启动由组合根直调
/// [initialize]，每轮对话交付完成（轮内召回循环之后）由聊天服务只调
/// [onDeliveryComplete] 一个钩子，动作在模块内部按固定先后排成一条
/// 自己的串行任务链，失败只记本机诊断，绝不阻塞首个可见回应。
/// 隐藏动作应用与随手记建叶不属于本模块——它们是本轮对话结果应用
/// 的一部分，留在聊天服务（CONTEXT.md「记忆节奏」词条）。
final class MemoryCadence {
  MemoryCadence({
    this.providerPort,
    this.dailyFinalization,
    this.monthlySummary,
    this.dreamService,
    this.memoryRecovery,
    this.requestDiagnostics,
    bool Function()? isDeliveryBusy,
    Clock? clock,
    void Function(String message)? diagnosticsSink,
  }) : _isDeliveryBusy = isDeliveryBusy ?? _neverBusy,
       _clock = clock ?? DateTime.now,
       _diagnosticsSink = diagnosticsSink ?? stderrDiagnostics;

  final ProviderChatPort? providerPort;
  final DailyFinalizationService? dailyFinalization;

  /// 月压缩（ticket 15，五段节奏第四动作）：进入新月、跨年或启动
  /// 补做时压缩当前月之前的月份。
  final MonthlySummaryStore? monthlySummary;

  /// Dream（ticket 16，五段节奏第五动作）：晚安后且距上次成功至少
  /// [dreamMinIntervalDays] 天时深度重组产出长期印象；启动或跨天首条
  /// 消息时补跑上次晚安未成功的请求。与日终归档、月压缩挂同一条后台
  /// 任务链，保证只看到 finalized 材料。
  final DreamService? dreamService;

  /// 损坏隔离与证据驱动恢复（ticket 21）：启动后台任务链上排在补
  /// 归档、月压缩与 Dream 之前执行——恢复修好的材料才能被后续整理
  /// 安全引用；受损层跳过，绝不阻塞首个可见回应。
  final MemoryRecoveryService? memoryRecovery;

  /// 开发者诊断最近请求记录器（ticket 23）：只记来源、结果与脱敏
  /// 细节，绝不记用户文本；null 时不记录。
  final RequestDiagnosticsRecorder? requestDiagnostics;

  /// 是否有在途聊天交付（聊天永远优先）：空闲补办轮询据此让路，由
  /// 组合根接入聊天服务的同一只读信号。
  final bool Function() _isDeliveryBusy;

  final Clock _clock;
  final void Function(String message) _diagnosticsSink;
  Future<void> _finalizationTask = Future.value();
  String? _lastDeliveryDate;

  /// 维护独占（spec「维护隔离及恢复」）：置位后空闲补办轮询不再发现并
  /// 排程新活；已排入任务链的工作照常完成。复位后下一次 tick 重新按
  /// 待办检测，维护期间跳过的当次补办不丢失。由聊天服务的维护独占
  /// 入口置位并在 finally 里配对复位。
  bool _schedulingPaused = false;

  /// 空闲补办轮询：同一时刻至多一个补办块在跑（上轮未结束本轮跳过）；
  /// 每日尝试上限只在内存按类计数，键为本地自然日，跨 0 点清零。
  bool _catchupInFlight = false;
  String? _catchupAttemptDate;
  final Map<_IdleCatchupItem, int> _catchupAttempts = {};

  /// 后台失败记账（ticket 21）：五员里「真正尝试过且失败」的旁路记录，
  /// 与既有 attempted/succeeded 记账同口径但互不影响；失败出口逐处记
  /// 一笔，只读状态经 [backgroundFailureStatus] 暴露给页面。
  final Map<_CadenceTask, _BackgroundFailureRecord> _backgroundFailures = {};

  static bool _neverBusy() => false;

  /// 启动节奏链（组合根在仓库初始化之后直调）：恢复扫描→补日终→
  /// 补月压缩→补 Dream。全部挂后台任务链，绝不阻塞首个可见回应。
  void initialize() {
    // 启动恢复扫描（ticket 21）：排在一切补归档之前——先隔离损坏原件、
    // 自底向上重建，补归档与月压缩才看得到修复后的材料。后台执行，
    // 受损层跳过，绝不阻塞首个可见回应。
    final recovery = memoryRecovery;
    if (recovery != null) {
      _chainFinalizationStep(
        _CadenceTask.recovery,
        'memory recovery',
        recovery.sweepAndRecover,
      );
    }
    // 启动补扫：发现 finalized 仍为 false 的历史日期并安全补做日终归档。
    // 后台执行，绝不阻塞首个可见回应。
    _runFinalization(
      'startup',
      (service) =>
          service.catchUpUnfinalized(before: localSessionDate(_clock())),
    );
    // 启动也补做月压缩：跨月停机后重新打开时，上月摘要在这里补齐。
    _scheduleMonthlyCompression();
    // 启动补跑 Dream：只兑现上次晚安留下且仍满足最小间隔
    // （dreamMinIntervalDays）的请求，没有晚安请求时绝不自行运行。
    _scheduleDream(bedtime: false);
  }

  /// 把一个后台整理步骤挂到串行任务链末尾：步骤之间不并发，失败只记
  /// '<label> deferred [$error]' 诊断并旁路记账该任务的失败（ticket 21），
  /// 绝不阻塞后续步骤与聊天。步骤本身的无异常完成不在此记成功——恢复
  /// 信号只由各自真正成功的出口给出（如接纳成功的 Dream 与全部成功的
  /// 归档）。
  void _chainFinalizationStep(
    _CadenceTask task,
    String label,
    Future<void> Function() work,
  ) {
    _finalizationTask = _finalizationTask.then((_) async {
      try {
        await work();
      } on Object catch (error) {
        _recordBackgroundOutcome(task, succeeded: false);
        _diagnosticsSink('$label deferred [$error]');
      }
    });
  }

  /// 等待已调度的后台日终归档完成。日终归档幂等且每一步原子写入，
  /// 供测试断言与 Host 优雅收尾使用。
  Future<void> finalizePending() => _finalizationTask;

  /// 维护独占进入等待前调用：抑制空闲补办轮询的新排程（spec：先抑制
  /// 新后台排程，再等待已在途工作）。已排入任务链的工作照常完成，
  /// 绝不在任务内部等待复位——否则维护入口等任务、任务等维护会互相
  /// 卡死。必须与 [resumeBackgroundScheduling] 配对，复位放在 finally。
  void pauseBackgroundScheduling() => _schedulingPaused = true;

  /// 恢复常规调度：维护结束后未完成整理由下一次空闲补办 tick 补齐。
  void resumeBackgroundScheduling() => _schedulingPaused = false;

  /// 后台最近失败的只读快照（ticket 21）：优先取最近失败的未恢复记录；
  /// 没有未恢复时取今晚已恢复的那条（页面据此短暂展示「已恢复」再隐
  /// 去）；都没有则安静返回 null。
  BackgroundFailureStatus? get backgroundFailureStatus {
    final tonight = localSessionDate(_clock());
    _CadenceTask? failureTask;
    _BackgroundFailureRecord? failure;
    _CadenceTask? recoveredTask;
    _BackgroundFailureRecord? recovered;
    for (final entry in _backgroundFailures.entries) {
      final record = entry.value;
      if (!record.recovered) {
        if (failure == null || record.failedAt.isAfter(failure.failedAt)) {
          failureTask = entry.key;
          failure = record;
        }
      } else if (record.night == tonight) {
        if (recovered == null || record.failedAt.isAfter(recovered.failedAt)) {
          recoveredTask = entry.key;
          recovered = record;
        }
      }
    }
    final task = failureTask ?? recoveredTask;
    final record = failure ?? recovered;
    if (task == null || record == null) {
      return null;
    }
    return BackgroundFailureStatus(
      task: task.displayName,
      failedAt: record.failedAt,
      count: record.count,
      recovered: record.recovered,
    );
  }

  /// 记一次后台任务成败（ticket 21）：成功只把该任务未恢复的记录翻转
  /// 为已恢复（回报一次「已恢复」）；失败在无记录、已恢复或跨晚时开新
  /// 记录，否则只累计次数并刷新最近失败时刻——同一任务同一晚始终只有
  /// 一条提示。纯旁路：不改变任何既有失败处理路径。
  void _recordBackgroundOutcome(_CadenceTask task, {required bool succeeded}) {
    final record = _backgroundFailures[task];
    if (succeeded) {
      if (record != null && !record.recovered) {
        record.recovered = true;
      }
      return;
    }
    final now = _clock();
    final tonight = localSessionDate(now);
    if (record == null || record.recovered || record.night != tonight) {
      _backgroundFailures[task] = _BackgroundFailureRecord(
        night: tonight,
        failedAt: now,
      );
    } else {
      record
        ..count += 1
        ..failedAt = now;
    }
  }

  /// 空闲补办轮询 tick（spec：空闲补办轮询器）。生产由
  /// [PeriodicIdleCatchupPoller] 每 10 分钟调用一次；测试直接调用并配
  /// 假时钟。按序检查三项记忆整理待办（未定稿日期、未压缩月份、待补
  /// 跑 Dream，全部本机读取零模型调用），无在途聊天时把活排进后台
  /// 任务链；各项资格（间隔、待补跑复查、完整覆盖判定）仍在各自服务
  /// 内部复查，本方法只负责发现待办、让路与排程。
  Future<void> pollTick() async {
    try {
      await _pollTick();
      // 轮询自身跑完即记成功（ticket 21）：各项整理的成败由它们自己的
      // 失败出口记账，这里只关照轮询本身。
      _recordBackgroundOutcome(_CadenceTask.idleCatchup, succeeded: true);
    } on Object catch (error) {
      _recordBackgroundOutcome(_CadenceTask.idleCatchup, succeeded: false);
      _diagnosticsSink('idle catchup deferred [$error]');
    }
  }

  Future<void> _pollTick() async {
    // 维护独占期间整个 tick 让路（spec：期间新工作排队或跳过当次
    // 补办）：不读数据、不排程，恢复调度后的下一次 tick 重新检测，
    // 跳过的当次不丢失。
    if (_schedulingPaused) {
      _diagnosticsSink('idle catchup skipped reason=maintenance');
      return;
    }
    // 未配置模型服务：安静地什么都不做，绝不用本地规则补写长期记忆。
    final prepared = await providerPort?.prepareChatRequest();
    if (prepared == null) {
      return;
    }
    // 聊天永远优先：有在途交付就让路，且不消耗每日尝试上限。
    if (_isDeliveryBusy()) {
      _diagnosticsSink('idle catchup skipped reason=busy-delivery');
      return;
    }
    if (_catchupInFlight) {
      _diagnosticsSink('idle catchup skipped reason=busy-catchup');
      return;
    }
    final today = localSessionDate(_clock());
    final month = today.substring(0, 7);
    final scheduled = <_IdleCatchupItem>[];
    final blocked = <_IdleCatchupItem>[];
    void track(_IdleCatchupItem item) {
      if (_attemptsForToday(item, today) >= item._dailyAttemptLimit) {
        blocked.add(item);
      } else {
        scheduled.add(item);
      }
    }

    // ① 存在未定稿日期（或已定稿但有未消费待补请求）→ 补日终归档；
    //   沿用现有补扫入口（幂等），完整覆盖判定在补扫内部复查。
    final finalization = dailyFinalization;
    if (finalization != null &&
        await finalization.hasUnfinalized(before: today)) {
      track(_IdleCatchupItem.finalization);
    }
    // ② 上月未生成月摘要且有已定稿日期 → 补月压缩（幂等入口照旧）。
    final compressor = monthlySummary;
    if (compressor != null &&
        await compressor.hasPendingCompression(beforeMonth: month)) {
      track(_IdleCatchupItem.monthlyCompression);
    }
    // ③ Dream 状态存在待补跑请求 → 补跑（bedtime:false 只兑现 pending；
    //   间隔复查在 DreamService 内部）。
    final dream = dreamService;
    if (dream != null && (await dream.readState()).pending) {
      track(_IdleCatchupItem.dream);
    }
    for (final item in blocked) {
      _diagnosticsSink(
        'idle catchup blocked item=${item._wireName} reason=daily-limit',
      );
    }
    if (scheduled.isEmpty) {
      return;
    }
    // 排程复查与置位之间没有 await：并发到达的 tick 在此串行化，
    // 同一时刻至多一个补办块在跑。置位前最后同步复查一次维护抑制：
    // 上面的待办检测有多个 await，检测途中可能已进入维护——
    // 「检测时未维护、排程时已在维护」的插队窗口在这里关死。
    if (_schedulingPaused) {
      _diagnosticsSink('idle catchup skipped reason=maintenance');
      return;
    }
    if (_catchupInFlight) {
      _diagnosticsSink('idle catchup skipped reason=busy-catchup');
      return;
    }
    _catchupInFlight = true;
    _diagnosticsSink(
      'idle catchup scheduled '
      'items=${scheduled.map((item) => item._wireName).join(',')}',
    );
    _finalizationTask = _finalizationTask.then((_) async {
      var failed = false;
      try {
        for (final item in scheduled) {
          if (!await _runCatchupItem(item, today: today, month: month)) {
            failed = true;
          }
        }
      } finally {
        _catchupInFlight = false;
      }
      _diagnosticsSink(
        'idle catchup done status=${failed ? 'failed' : 'ok'} '
        'items=${scheduled.map((item) => item._wireName).join(',')}',
      );
    });
  }

  /// 在后台任务链上执行一项补办并记账每日上限，返回是否成功。
  Future<bool> _runCatchupItem(
    _IdleCatchupItem item, {
    required String today,
    required String month,
  }) async {
    switch (item) {
      case _IdleCatchupItem.finalization:
        final service = dailyFinalization;
        if (service == null) {
          return true;
        }
        final succeeded = await _runFinalizationWork(
          service,
          'idle-catchup',
          (service) => service.catchUpUnfinalized(before: today),
        );
        return _settleCatchupAttempt(item, succeeded: succeeded);
      case _IdleCatchupItem.monthlyCompression:
        final compressor = monthlySummary;
        if (compressor == null) {
          return true;
        }
        var succeeded = false;
        try {
          await compressor.compressBefore(month);
          // 成功口径：尝试后不再存在待压缩月份（单月失败由压缩内部
          // 记诊断不上抛，摘要仍缺时按失败计入每日上限）。
          succeeded =
              !(await compressor.hasPendingCompression(beforeMonth: month));
        } on Object catch (error) {
          _diagnosticsSink(
            'monthly compression deferred [$error] reason=idle-catchup',
          );
        }
        // 后台失败记账（ticket 21）：与每日上限同一份成败口径。
        _recordBackgroundOutcome(
          _CadenceTask.monthlyCompression,
          succeeded: succeeded,
        );
        return _settleCatchupAttempt(item, succeeded: succeeded);
      case _IdleCatchupItem.dream:
        final dream = dreamService;
        if (dream == null) {
          return true;
        }
        final result = await _runDreamWork(dream, bedtime: false);
        if (!result.attempted) {
          // 资格不符（间隔未到等）：没有真正尝试，不消耗每日上限。
          return true;
        }
        return _settleCatchupAttempt(item, succeeded: result.succeeded);
    }
  }

  /// 记账一次补办尝试：成功清零该类计数，失败 +1。结算时刻取当前
  /// 本地日期——补办块跨 0 点完成时，失败计入新的一天而不是发起 tick
  /// 的昨天，保证新一天的可尝试额度不被少记一次。
  bool _settleCatchupAttempt(_IdleCatchupItem item, {required bool succeeded}) {
    final today = localSessionDate(_clock());
    final attempts = _attemptsForToday(item, today);
    _catchupAttempts[item] = succeeded ? 0 : attempts + 1;
    return succeeded;
  }

  /// [item] 在自然日 [today] 的已尝试次数。有副作用：传入日期晚于
  /// 记账日时先清空全部计数（每日上限按本地自然日口径跨 0 点清零），
  /// 因此只应传「当前」本地日期，绝不作跨日纯读使用。
  int _attemptsForToday(_IdleCatchupItem item, String today) {
    if (_catchupAttemptDate != today) {
      _catchupAttemptDate = today;
      _catchupAttempts.clear();
    }
    return _catchupAttempts[item] ?? 0;
  }

  /// 聊天服务在每轮交付完成（轮内召回循环之后）调用的唯一钩子；
  /// 晚安识别留在聊天服务，经 [bedtime] 传入。全部不阻塞首响：
  /// - 晚安：可见回复完成后归档当天并补做更早的未完成日期（第三动作），
  ///   随后依次补月压缩（第四动作）与 Dream（第五动作，ticket 16）。
  ///   Dream 是独立动作：归档服务绝不调用它，资格在 DreamService 内复查。
  /// - 日期变化（含进程跨午夜后的第一条消息）：补做昨天及更早的未完成日期；
  ///   当天仍在进行中，不归档；随后与晚安分支同口径调度 Dream 补跑
  ///   （只兑现 pending 请求）。
  void onDeliveryComplete({required bool bedtime}) {
    if (dailyFinalization == null) {
      return;
    }
    final today = localSessionDate(_clock());
    final dateChanged = _lastDeliveryDate != today;
    _lastDeliveryDate = today;
    if (bedtime) {
      // 晚安请求先登记：即使进程在随后的归档完成前退出，启动补跑
      // 也能兑现这次 Dream（笔记定稿：当晚没跑成，下次启动补）。
      _markDreamBedtime();
      _runFinalization(
        'bedtime',
        (service) => service.finalizeForBedtime(date: today),
      );
      _scheduleMonthlyCompression();
      // Dream 排在补归档与月压缩之后：只读 finalized 材料与最新月摘要。
      // 资格（晚安 + 距上次成功 ≥3 天）在 DreamService 内复查。
      _scheduleDream(bedtime: true);
    } else if (dateChanged) {
      _runFinalization(
        'date-change',
        (service) => service.catchUpUnfinalized(before: today),
      );
      // 新月（含跨年）的第一次对话在这里触发上月压缩（五段节奏
      // 第四动作）。压缩排在补归档之后：只收 finalized 日期。
      _scheduleMonthlyCompression();
      // Dream 补跑与晚安分支同口径：排在补归档与月压缩之后、只兑现
      // pending 请求（笔记定稿：当晚没跑成，下次启动/空闲时补），资格
      // 在 DreamService 内复查。启动、跨天首条消息与晚安三个触发点都
      // 会尝试兑现 pending，直到成功为止。
      _scheduleDream(bedtime: false);
    }
  }

  /// 月压缩挂到日终归档同一条后台任务链上：保证补归档先完成、
  /// 压缩只看到 finalized 日期；失败只记诊断，绝不阻塞聊天。
  void _scheduleMonthlyCompression() {
    final compressor = monthlySummary;
    if (compressor == null) {
      return;
    }
    final now = _clock();
    final month = '${now.year}-${'${now.month}'.padLeft(2, '0')}';
    _chainFinalizationStep(
      _CadenceTask.monthlyCompression,
      'monthly compression',
      // 成功口径与空闲补办一致：尝试后不再存在待压缩月份（单月失败由
      // 压缩内部记诊断不上抛，摘要仍缺时按失败记账，ticket 21）。
      () async {
        await compressor.compressBefore(month);
        _recordBackgroundOutcome(
          _CadenceTask.monthlyCompression,
          succeeded:
              !(await compressor.hasPendingCompression(beforeMonth: month)),
        );
      },
    );
  }

  /// 晚安触发预登记：排在晚安任务链最前面，把最小间隔
  /// （[dreamMinIntervalDays] 天）已到的请求先落成 pending；失败只记
  /// 诊断。
  void _markDreamBedtime() {
    final dream = dreamService;
    if (dream == null) {
      return;
    }
    _chainFinalizationStep(
      _CadenceTask.dream,
      'dream bedtime mark',
      dream.markBedtime,
    );
  }

  /// Dream 挂到日终归档同一条后台任务链上：补归档与月压缩先完成，
  /// Dream 只看到 finalized 材料；失败只记诊断，绝不阻塞聊天，
  /// 未成功的请求由下次晚安、启动或跨天首条消息补跑继续。
  void _scheduleDream({required bool bedtime}) {
    final dream = dreamService;
    if (dream == null) {
      return;
    }
    _finalizationTask = _finalizationTask.then(
      (_) => _runDreamWork(dream, bedtime: bedtime),
    );
  }

  /// 执行一次 Dream 并记诊断。返回结果供空闲补办轮询记账：
  /// `attempted` 表示本轮真正发起了补跑（接纳、真正失败或执行异常，
  /// 资格不符的 skipped 未消耗模型调用不算），`succeeded` 仅在接纳
  /// 成功时为真。
  Future<({bool attempted, bool succeeded})> _runDreamWork(
    DreamService dream, {
    required bool bedtime,
  }) async {
    try {
      final outcome = await dream.run(bedtime: bedtime);
      final status = outcome.status;
      if (status == DreamStatus.modelFailed ||
          status == DreamStatus.validationFailed ||
          status == DreamStatus.writeFailed ||
          status == DreamStatus.skippedUnreadable) {
        final detail = outcome.detail == null ? '' : ' [${outcome.detail}]';
        _diagnosticsSink('dream deferred status=${status.name}$detail');
      }
      // skipped ⇔ 资格不符的四个状态（notEligible/notDue/skippedNoMaterial/
      // skippedNoProvider，switch 全集覆盖）：它们未消耗模型调用，
      // 不是真正的补跑尝试。
      final result = switch (status) {
        DreamStatus.accepted => RecentRequestResults.ok,
        DreamStatus.notEligible ||
        DreamStatus.notDue ||
        DreamStatus.skippedNoMaterial ||
        DreamStatus.skippedNoProvider =>
          RecentRequestResults.skipped,
        _ => RecentRequestResults.failed,
      };
      // 后台失败记账（ticket 21）：与 attempted/succeeded 同口径——资格
      // 不符的跳过不记账，真正尝试且失败记一次，接纳成功翻转恢复。
      if (result != RecentRequestResults.skipped) {
        _recordBackgroundOutcome(
          _CadenceTask.dream,
          succeeded: status == DreamStatus.accepted,
        );
      }
      requestDiagnostics?.record(
        source: RecentRequestSources.dream,
        result: result,
        detail: 'status=${status.name}',
      );
      return (
        attempted: result != RecentRequestResults.skipped,
        succeeded: status == DreamStatus.accepted,
      );
    } on Object catch (error) {
      _recordBackgroundOutcome(_CadenceTask.dream, succeeded: false);
      requestDiagnostics?.record(
        source: RecentRequestSources.dream,
        result: RecentRequestResults.failed,
        // 细节只记错误类别，不记第三方错误原文。
        detail: '${error.runtimeType}',
      );
      _diagnosticsSink('dream deferred [$error]');
      return (attempted: true, succeeded: false);
    }
  }

  /// 把一次后台归档挂到串行任务链上：归档之间不并发，失败只记诊断。
  void _runFinalization(
    String reason,
    Future<FinalizationReport> Function(DailyFinalizationService service) work,
  ) {
    final service = dailyFinalization;
    if (service == null) {
      return;
    }
    _finalizationTask = _finalizationTask.then(
      (_) => _runFinalizationWork(service, reason, work),
    );
  }

  /// 执行一次日终归档并记诊断：全部日期成功（无 failed/不可读）返回
  /// true。空闲补办轮询据此消耗每日尝试上限，触发点路径忽略返回值。
  Future<bool> _runFinalizationWork(
    DailyFinalizationService service,
    String reason,
    Future<FinalizationReport> Function(DailyFinalizationService service) work,
  ) async {
    try {
      final report = await work(service);
      var troubled = 0;
      for (final outcome in report.outcomes) {
        if (outcome.status == FinalizationStatus.failed ||
            outcome.status == FinalizationStatus.skippedUnreadable) {
          troubled += 1;
          final detail = outcome.detail == null ? '' : ' [${outcome.detail}]';
          _diagnosticsSink(
            'finalization ${outcome.status.name} date=${outcome.date}'
            '$detail reason=$reason',
          );
        }
      }
      requestDiagnostics?.record(
        source: RecentRequestSources.finalization,
        result: troubled == 0
            ? RecentRequestResults.ok
            : RecentRequestResults.failed,
        detail:
            'dates=${report.outcomes.length} troubled=$troubled '
            'reason=$reason',
      );
      // 后台失败记账（ticket 21）：与「全部日期成功」的返回口径一致，
      // 触发点路径与空闲补办路径都经这里。
      _recordBackgroundOutcome(
        _CadenceTask.finalization,
        succeeded: troubled == 0,
      );
      return troubled == 0;
    } on Object catch (error) {
      requestDiagnostics?.record(
        source: RecentRequestSources.finalization,
        result: RecentRequestResults.failed,
        // 细节只记错误类别，不记第三方错误原文。
        detail: '${error.runtimeType} reason=$reason',
      );
      _recordBackgroundOutcome(_CadenceTask.finalization, succeeded: false);
      _diagnosticsSink('finalization deferred [$error] reason=$reason');
      return false;
    }
  }
}

/// 空闲补办轮询定时器（spec：唯一新缝是 [MemoryCadence.pollTick]，
/// 真定时器只是可注入的薄壳；测试不启动真定时器，直接拨 tick 配假
/// 时钟）。随宿主启动、随宿主收尾取消。
abstract interface class IdleCatchupPoller {
  void start();

  void stop();
}

/// 生产实现：每 [interval] 调一次 [onTick]。薄到不做端到端测试
/// （spec Out of Scope），随全量门禁冒烟覆盖。
final class PeriodicIdleCatchupPoller implements IdleCatchupPoller {
  PeriodicIdleCatchupPoller(
    this._onTick, {
    this.interval = const Duration(minutes: 10),
  });

  final Future<void> Function() _onTick;
  final Duration interval;
  Timer? _timer;

  @override
  void start() => _timer ??= Timer.periodic(interval, (_) {
        unawaited(_onTick());
      });

  @override
  void stop() {
    _timer?.cancel();
    _timer = null;
  }
}
