abstract class DiagnosticsStrings {
  const DiagnosticsStrings();

  static DiagnosticsStrings of(bool english) =>
      english ? const DiagnosticsStringsEn() : const DiagnosticsStringsZh();

  String get backToSettings;
  String get title;
  String get refresh;
  String get description;
  String get recentRequests;
  String get finalization;
  String get dream;
  String get fileHealth;
  String get dataLocation;
  String get noRequests;
  String get finalizationDisabled;
  String todayArchived(String date);
  String todayPending(String date);
  String get todayUnknown;
  String pendingDays(int pending, int unreadable);
  String get dreamDisabled;
  String get dreamNeverRan;
  String dreamLastSuccess(String date, int? days);
  String dreamInterval(int days);
  String dreamPending(bool pending);
  String modelConfigured(bool configured);
  String dreamEligible(bool eligible);
  String sessions(Object readable, Object unreadable);
  String episodes(Object days, Object unfinalized, Object unreadable);
  String longMemory(String readability);
  String dreamState(String readability);
  String memoryControls(String readability);
  String personaTree(String readability);
  String recoveryScanned(Object quarantined);
  String get recoveryNeverRan;
  String get unknown;
  String get notCreated;
  String get readable;
  String get unreadable;
  String get disabled;
  String source(String code);
  String result(String code, {required bool local});
}

class DiagnosticsStringsZh extends DiagnosticsStrings {
  const DiagnosticsStringsZh();

  @override
  String get backToSettings => '返回设置';
  @override
  String get title => '开发者诊断';
  @override
  String get refresh => '刷新诊断';
  @override
  String get description => '只读快照，不修改任何数据；只在本机展示，不包含对话正文。';
  @override
  String get recentRequests => '最近请求（本次启动以来）';
  @override
  String get finalization => '后台整理';
  @override
  String get dream => 'Dream 资格';
  @override
  String get fileHealth => '本地文件健康';
  @override
  String get dataLocation => '数据位置';
  @override
  String get noRequests => '本次启动后还没有请求记录。';
  @override
  String get finalizationDisabled => '未启用日终整理。';
  @override
  String todayArchived(String date) => '今天（$date）已归档';
  @override
  String todayPending(String date) => '今天（$date）尚未归档';
  @override
  String get todayUnknown => '今天的归档状态未知';
  @override
  String pendingDays(int pending, int unreadable) =>
      '待补归档 $pending 天 · 不可读 $unreadable 天';
  @override
  String get dreamDisabled => '未启用 Dream。';
  @override
  String get dreamNeverRan => '还没有成功运行过 Dream';
  @override
  String dreamLastSuccess(String date, int? days) => '上次成功：$date（$days 天前）';
  @override
  String dreamInterval(int days) => '最小间隔 $days 天';
  @override
  String dreamPending(bool pending) => pending ? '有待补跑的晚安请求' : '没有待补跑请求';
  @override
  String modelConfigured(bool configured) =>
      configured ? '模型服务已配置' : '未配置模型服务（不会运行）';
  @override
  String dreamEligible(bool eligible) => eligible ? '当前具备资格' : '当前不具备资格';
  @override
  String sessions(Object readable, Object unreadable) =>
      '会话文件：可读 $readable 份，不可读 $unreadable 份';
  @override
  String episodes(Object days, Object unfinalized, Object unreadable) =>
      '每日记录：共 $days 天，未归档 $unfinalized 天，不可读 $unreadable 天';
  @override
  String longMemory(String readability) => '长期印象：$readability';
  @override
  String dreamState(String readability) => 'Dream 状态：$readability';
  @override
  String memoryControls(String readability) => '记忆控制：$readability';
  @override
  String personaTree(String readability) => '画像树：$readability';
  @override
  String recoveryScanned(Object quarantined) => '恢复扫描：隔离原件 $quarantined 份';
  @override
  String get recoveryNeverRan => '恢复扫描：还没有运行过';
  @override
  String get unknown => '未知';
  @override
  String get notCreated => '尚未创建';
  @override
  String get readable => '可读';
  @override
  String get unreadable => '不可读';
  @override
  String get disabled => '未启用';
  @override
  String source(String code) => switch (code) {
    'chat' => '聊天',
    'provider-test' => '连接测试',
    'finalization' => '日终整理',
    'dream' => 'Dream',
    _ => code,
  };
  @override
  String result(String code, {required bool local}) => switch (code) {
    'ok' => local ? '本地规则回应' : '模型回应',
    'fallback' => '已回退本地',
    'failed' => '失败',
    'skipped' => '跳过',
    'cancelled' => '已停止',
    _ => code,
  };
}

class DiagnosticsStringsEn extends DiagnosticsStrings {
  const DiagnosticsStringsEn();

  @override
  String get backToSettings => 'Back to Settings';
  @override
  String get title => 'Developer diagnostics';
  @override
  String get refresh => 'Refresh diagnostics';
  @override
  String get description =>
      'A read only snapshot shown on this device. It changes no data and contains no chat text.';
  @override
  String get recentRequests => 'Recent requests (this launch)';
  @override
  String get finalization => 'Background processing';
  @override
  String get dream => 'Dream eligibility';
  @override
  String get fileHealth => 'Local file health';
  @override
  String get dataLocation => 'Data location';
  @override
  String get noRequests => 'No requests since this launch.';
  @override
  String get finalizationDisabled => 'Daily finalization is not enabled.';
  @override
  String todayArchived(String date) => 'Today ($date) was archived';
  @override
  String todayPending(String date) => 'Today ($date) has not been archived';
  @override
  String get todayUnknown => 'Today’s archive status is unknown';
  @override
  String pendingDays(int pending, int unreadable) =>
      '$pending days pending archive · $unreadable days unreadable';
  @override
  String get dreamDisabled => 'Dream is not enabled.';
  @override
  String get dreamNeverRan => 'Dream has not completed yet';
  @override
  String dreamLastSuccess(String date, int? days) =>
      'Last success: $date ($days days ago)';
  @override
  String dreamInterval(int days) => 'Minimum interval: $days days';
  @override
  String dreamPending(bool pending) =>
      pending ? 'A goodnight request is pending' : 'No request is pending';
  @override
  String modelConfigured(bool configured) => configured
      ? 'Model service configured'
      : 'No model service configured (will not run)';
  @override
  String dreamEligible(bool eligible) =>
      eligible ? 'Eligible now' : 'Not eligible now';
  @override
  String sessions(Object readable, Object unreadable) =>
      'Session files: $readable readable, $unreadable unreadable';
  @override
  String episodes(Object days, Object unfinalized, Object unreadable) =>
      'Daily records: $days days, $unfinalized unarchived, $unreadable unreadable';
  @override
  String longMemory(String readability) =>
      'Long term impressions: $readability';
  @override
  String dreamState(String readability) => 'Dream state: $readability';
  @override
  String memoryControls(String readability) => 'Memory controls: $readability';
  @override
  String personaTree(String readability) => 'Profile tree: $readability';
  @override
  String recoveryScanned(Object quarantined) =>
      'Recovery scan: $quarantined originals quarantined';
  @override
  String get recoveryNeverRan => 'Recovery scan has not run';
  @override
  String get unknown => 'Unknown';
  @override
  String get notCreated => 'Not created';
  @override
  String get readable => 'Readable';
  @override
  String get unreadable => 'Unreadable';
  @override
  String get disabled => 'Not enabled';
  @override
  String source(String code) => switch (code) {
    'chat' => 'Chat',
    'provider-test' => 'Connection test',
    'finalization' => 'Daily finalization',
    'dream' => 'Dream',
    _ => code,
  };
  @override
  String result(String code, {required bool local}) => switch (code) {
    'ok' => local ? 'Local reply' : 'Model reply',
    'fallback' => 'Fell back to local reply',
    'failed' => 'Failed',
    'skipped' => 'Skipped',
    'cancelled' => 'Stopped',
    _ => code,
  };
}
