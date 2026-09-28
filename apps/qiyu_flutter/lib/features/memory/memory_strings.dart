import 'package:flutter/widgets.dart';

import '../shell/qiyu_ui_locale.dart';

/// Every UI label has both translations at its declaration site.
enum MemoryLabel {
  title('记忆', 'Memory'),
  backup('备份与恢复', 'Backup and restore'),
  refresh('刷新记忆', 'Refresh memory'),
  recent('最近发生', 'Recent'),
  longTerm('长期印象', 'Long-term'),
  aboutYou('关于你', 'About you'),
  relationship('我们的关系', 'Our relationship'),
  damage('部分记忆文件出现过损坏', 'Some memory files were damaged'),
  recentEmpty(
    '还没有最近的记录。\n聊过之后，这里会出现整理好的记忆。',
    'Nothing recent yet.\nMemories will appear here after you talk.',
  ),
  organizing('整理中', 'Organizing'),
  longTermEmpty(
    '还没有形成长期印象。\n长期印象来自周期性的深度整理，需要一些积累。',
    'No long-term impressions yet.\nThey grow from periodic reflection over time.',
  ),
  unreadable(
    '这一部分记忆暂时读不出来，不影响其他内容。',
    'This part of memory could not be read. Other memories are unaffected.',
  ),
  personaEmpty(
    '还没有形成关于你的画像。\n画像来自一次次聊天里的积累，慢慢来。',
    'Nothing about you here yet.\nIt takes shape over many conversations.',
  ),
  sectionUnreadable(
    '这一部分暂时读不出来，不影响其他内容。',
    'This section could not be read. Other memories are unaffected.',
  ),
  sectionEmpty('还没有形成这一部分画像。', 'Nothing here yet.'),
  appellationTitle('栖语这样叫你', 'What Qiyu calls you'),
  notSet('还没设置', 'Not set yet'),
  set('设置', 'Set'),
  edit('修改', 'Edit'),
  appellationQuestion('栖语怎么称呼你？', 'What should Qiyu call you?'),
  appellationHint('名字、昵称、代号都行', 'A name, nickname, or anything you like'),
  cancel('取消', 'Cancel'),
  save('保存', 'Save'),
  relationshipEmpty(
    '还没有形成关系记录。\n相处方式会随着一次次的聊天慢慢清晰。',
    'No relationship notes yet.\nThey become clearer as you talk.',
  ),
  confirmed('当前相处方式', 'How we are now'),
  probes('试探中', 'Still exploring'),
  recentChanges('近期变化', 'Recent changes'),
  sharedPast('共同过往', 'Shared past'),
  back('返回记忆', 'Back to memory'),
  detail('记忆详情', 'Memory details'),
  retryError(
    '记忆中心暂时不可用，请稍后重试。',
    'Memory is unavailable right now. Please try again later.',
  ),
  itemGone(
    '这条记忆不存在或已经变化，请返回后刷新。',
    'This memory is gone or has changed. Go back and refresh.',
  ),
  revealNotice(
    '仅本次展示，稍后自动重新遮罩',
    'Shown only this time; it will be hidden again soon',
  ),
  reveal('临时查看', 'View temporarily'),
  userEdited('由你修正', 'Corrected by you'),
  excerpt('当时的摘录', 'Excerpt from then'),
  daySummary('当天小结', 'Day summary'),
  viewDay('查看这一天的记录', 'View this day'),
  viewConversation('查看当时的对话', 'View the conversation'),
  supporting('支持它的理解', 'Supporting thoughts'),
  noSupporting('暂时没有记录支持它的依据。', 'No supporting notes recorded yet.'),
  evidence('证据', 'Evidence'),
  noEvidence('暂时没有记录在案的证据。', 'No evidence recorded yet.'),
  noDayEntries('这一天没有可展示的记录。', 'No records to show for this day.'),
  hasExcerpt('有摘录', 'Has excerpt'),
  conflictEvidence('有冲突证据', 'Conflicting evidence'),
  conflict('冲突', 'Conflict'),
  masked(
    '这条内容涉及私密信息，暂不直接展示。',
    'This contains private information and is hidden here.',
  ),
  editTitle('修正这条记忆', 'Correct this memory'),
  editHint('按你的说法写', 'Write it in your own words'),
  banTitle('不再提起这条记忆？', 'Stop bringing up this memory?'),
  banDescription(
    '确认后，栖语不会再主动提起它，聊天和整理都会避开这条内容。以后可以随时解除。',
    'Qiyu will avoid bringing this up in conversation and reflection. You can undo this later.',
  ),
  notNow('先不用', 'Not now'),
  banAction('不再提起', 'Do not bring up'),
  revealTitle('仅本次展示', 'Show this time only'),
  revealDescription(
    '关闭或稍后会自动重新遮罩。',
    'It will be hidden again when you close this or shortly after.',
  ),
  close('关闭', 'Close'),
  deleteTitle('删除这条记忆？', 'Delete this memory?'),
  checkingImpact('正在核对影响范围…', 'Checking what will be affected…'),
  confirmDelete('确认删除', 'Delete memory');

  const MemoryLabel(this.zh, this.en);
  final String zh;
  final String en;

  String of(BuildContext context) => qiyuIsEn(context) ? en : zh;
}

String memoryErrorFor(BuildContext context, String message) =>
    message == MemoryLabel.retryError.zh
    ? MemoryLabel.retryError.of(context)
    : message;

const _recoveryLayersEn = <String, String>{
  '原始会话': 'Original conversation',
  '每日记录': 'Daily record',
  '整理检查点': 'Organization checkpoint',
  '月份索引': 'Monthly index',
  '每日索引': 'Daily index',
  '月度摘要': 'Monthly summary',
  '记忆控制': 'Memory controls',
  '未闭环事项': 'Open items',
  '未闭环事项归档': 'Open items archive',
  '近日状态': 'Recent state',
  '关系记录': 'Relationship notes',
  '长期印象': 'Long-term impressions',
  '画像投影': 'Profile projection',
  'Dream 状态': 'Dream state',
  '写入残留': 'Interrupted write',
  '记忆文件': 'Memory file',
};

const _personaBranchesEn = <String, String>{
  '身份事实': 'Identity facts',
  '性格表达': 'Personality and expression',
  '价值原则': 'Values',
  '偏好习惯': 'Preferences',
  '边界禁区': 'Boundaries',
  'identity': 'identity',
  'expression': 'expression',
  'values': 'values',
  'preferences': 'preferences',
  'boundaries': 'boundaries',
};

String recoveryLayerFor(BuildContext context, String layer) {
  if (!qiyuIsEn(context)) return layer;
  final fixed = _recoveryLayersEn[layer];
  if (fixed != null) return fixed;

  final conversation = RegExp(r'^原始会话（(\d{4}-\d{2}-\d{2}) 第 (\d+) 段）$')
      .firstMatch(layer);
  if (conversation != null) {
    return 'Original conversation (${conversation[1]}, segment ${conversation[2]})';
  }
  final dated = RegExp(r'^(每日记录|每日索引|月度摘要)（(\d{4}-\d{2}(?:-\d{2})?)）$')
      .firstMatch(layer);
  final datedLabel = dated == null ? null : _recoveryLayersEn[dated[1]];
  if (dated != null && datedLabel != null) {
    return '$datedLabel (${dated[2]})';
  }
  final branch = RegExp(r'^(画像分支|画像归档)（(.+)）$').firstMatch(layer);
  final branchLabel = branch == null ? null : _personaBranchesEn[branch[2]];
  if (branch != null && branchLabel != null) {
    return '${branch[1] == '画像分支' ? 'Profile branch' : 'Profile archive'} ($branchLabel)';
  }
  return layer;
}

enum BackupLabel {
  rollbackQuestion('回滚到导入之前？', 'Roll back to before import?'),
  rollbackDescription(
    '记忆会恢复到最近一次导入前的状态。回滚前会先给当前状态留一份保底快照。',
    'Memory will return to its state before the most recent import. A safety snapshot of the current state will be kept first.',
  ),
  notNow('先不回滚', 'Not now'),
  confirmRollback('确认回滚', 'Roll back'),
  error('备份操作没有成功，可稍后重试。', 'Backup did not complete. Please try again later.'),
  exportTitle('导出备份', 'Export backup'),
  exportDescription(
    '把栖语的完整本地记忆打包为可阅读、可携带的 Markdown 备份。API Key 与模型凭据从不进入备份。',
    'Export Qiyu’s complete local memory as a readable, portable Markdown backup. API keys and model credentials are never included.',
  ),
  dataWarning(
    '会话与记忆只存在这台设备上：未导出即随卸载永久丢失，换机前记得先导出。',
    'Conversations and memories live only on this device. Uninstalling without an export will erase them permanently. Export before changing devices.',
  ),
  packing('正在打包…', 'Preparing…'),
  importTitle('导入备份', 'Import backup'),
  rollbackTitle('回滚', 'Rollback'),
  importDescription(
    '导入前会先验证备份的版本与完整性，并展示与本机数据的差异；确认后先创建可回滚快照，再写入。本机已有的禁提与删除控制会继续生效。',
    'Qiyu will check the backup and show differences from local data before import. After confirmation, it creates a rollback snapshot before writing. Existing memory controls remain in effect.',
  ),
  chooseFile('选择备份文件', 'Choose backup file'),
  fileUnsupported(
    '当前环境不支持选择文件，请改用桌面版栖语导入。',
    'File selection is unavailable here. Use Qiyu on desktop to import.',
  ),
  reading('正在读取备份文件…', 'Reading backup file…'),
  previewing('正在验证备份并比对差异…', 'Checking backup and comparing differences…'),
  importing(
    '正在创建快照并写入，请不要关闭栖语…',
    'Creating a snapshot and importing. Keep Qiyu open…',
  ),
  controlsMerged(
    '记忆控制已按并集合并，更保守的隐私结果保留。',
    'Memory controls were combined, keeping the more private outcome.',
  ),
  controlsUnchanged('记忆控制保持不变。', 'Memory controls are unchanged.'),
  rollbackHint(
    '如果结果不对，可以在下方「回滚」恢复原样。',
    'If anything looks wrong, use Rollback below to restore the previous state.',
  ),
  conflictWarning(
    '冲突与不可恢复的内容不会写入本机；同名原始会话一律保留本机版本。',
    'Conflicts and unrecoverable items will not be written. Existing original conversations are kept.',
  ),
  importConfirmHint(
    '确认后栖语会先创建一份可回滚的快照，再写入备份内容。',
    'Qiyu will create a rollback snapshot before importing.',
  ),
  confirmImport('确认导入', 'Import backup'),
  checkingSnapshots('正在查看快照…', 'Checking snapshots…'),
  noSnapshots(
    '还没有快照。导入备份时会自动创建。',
    'No snapshots yet. One will be created during import.',
  ),
  restoring('正在恢复…', 'Restoring…'),
  rollbackBeforeImport('回滚到导入之前', 'Roll back before import');

  const BackupLabel(this.zh, this.en);
  final String zh;
  final String en;

  String of(BuildContext context) => qiyuIsEn(context) ? en : zh;
}

String memoryKindText(BuildContext context, String kind) {
  if (!qiyuIsEn(context)) {
    return switch (kind) {
      'concern' => '关注的事',
      'relationship' => '关系变化',
      _ => '记忆',
    };
  }
  return switch (kind) {
    'concern' => 'On your mind',
    'relationship' => 'Relationship change',
    _ => 'Memory',
  };
}

String memoryControlText(BuildContext context, String label) {
  if (!qiyuIsEn(context)) return label;
  return switch (label) {
    '已冻结' => 'Paused',
    '已禁提' => 'Do not bring up',
    _ => label,
  };
}

String memoryBranchText(BuildContext context, String wire, String fallback) {
  if (!qiyuIsEn(context)) return fallback;
  return switch (wire) {
    'identity' => 'Identity facts',
    'expression' => 'Personality and expression',
    'values' => 'Values and principles',
    'preferences' => 'Preferences and habits',
    'boundaries' => 'Boundaries',
    _ => fallback,
  };
}

String memoryStructureText(BuildContext context, String label) {
  if (!qiyuIsEn(context)) return label;
  return switch (label) {
    '待稳定事实' => 'Emerging fact',
    '重复模式' => 'Recurring pattern',
    '边界信号' => 'Boundary signal',
    '明确自述' => 'Stated directly',
    '行为观察' => 'Observed behavior',
    _ => label,
  };
}

String? memoryStageText(BuildContext context, String? stage) {
  if (stage == null || !qiyuIsEn(context)) return stage;
  return switch (stage) {
    '初识' => 'Getting acquainted',
    '熟悉' => 'Familiar',
    '朋友' => 'Friends',
    '深交' => 'Close',
    _ => stage,
  };
}

String memoryActionMessage(BuildContext context, String message) {
  if (!qiyuIsEnNow(context)) return message;
  if (message.startsWith('已不再提起这条记忆；')) {
    return 'Qiyu will no longer bring up this memory. Some updates could not finish now and will be retried later.';
  }
  return switch (message) {
    '这条记忆不存在或已经变化，请返回后刷新。' =>
      'This memory is gone or has changed. Go back and refresh.',
    '控制记录暂时写不进去，这次没有生效，原有内容保持不变，可稍后重试。' =>
      'Memory controls could not be saved. Nothing changed. Try again later.',
    '已暂停使用这条记忆，解除前不会出现在对话和整理里。' =>
      'This memory is paused and will not be used in conversation or reflection until resumed.',
    '已恢复使用这条记忆。' => 'This memory can be used again.',
    '已不再提起这条记忆。' => 'Qiyu will no longer bring up this memory.',
    '已解除禁提。' => 'Qiyu may bring up this memory again.',
    '修正已保存；索引与画像的同步没有一次完成，可稍后重试。' =>
      'Correction saved. Some related updates will be retried later.',
    '修正没有保存成功，原内容保持不变，可稍后重试。' =>
      'Correction was not saved. The original remains unchanged. Try again later.',
    '这一天的记录暂时读不出来，修正没有生效，可稍后重试。' =>
      'This day could not be read. The correction was not applied. Try again later.',
    '已按你的说法修正这条记录。' => 'This record was corrected in your words.',
    '长期印象暂时读不出来，修正没有生效，可稍后重试。' =>
      'Long-term memory could not be read. The correction was not applied. Try again later.',
    '已按你的说法修正这条长期印象。' =>
      'This long-term impression was corrected in your words.',
    '没有可定位的删除目标。' => 'No matching memory to delete.',
    '删除没有生效：控制记录写不进去，原有内容保持不变，可稍后重试。' =>
      'Deletion was not applied because memory controls could not be saved. Nothing changed. Try again later.',
    '已删除。原始对话记录还在，但不会再从那里整理出这条内容。' =>
      'Deleted. The original conversation remains, but this memory will not be recreated from it.',
    '这条内容不需要揭示。' => 'This content is already visible.',
    '仅本次展示，离开页面或稍后会自动重新遮罩。' =>
      'Shown only this time. It will be hidden again when you leave or shortly after.',
    _ => message,
  };
}
