import 'package:flutter/material.dart';

import '../../theme/qiyu_icons.dart';

/// Host 档位映射表下发的结构化建议（连接测试结果里的 `suggestion`
/// 字段，ADR 0020）。浏览器侧只消费这个字段，不复制表、不做双源同步
/// （spec 决策 11）；表 miss 或测试成功时为 null。
///
/// [targetFamily]/[targetProvider]/[targetModel] 统一描述「建议的落位」：
/// 应换档时是目标档与目标型号；不支持时是建议替代型号所属的族与档。
final class VoiceTierSuggestionData {
  const VoiceTierSuggestionData({
    required this.kind,
    required this.targetFamily,
    required this.targetProvider,
    required this.targetModel,
    required this.reason,
    this.defaultEndpoint,
    this.addressTemplate,
    this.addressGuidance,
  });

  factory VoiceTierSuggestionData.fromJson(Map<String, Object?> json) =>
      VoiceTierSuggestionData(
        // 未知 kind 按应换档呈现：老界面遇到新 Host 的新种类时宁可多给
        // 一张可确认的卡片，也不静默吞掉 Host 的精确话术（确认制兜底）。
        kind: switch (json['kind']) {
          'unsupported' => VoiceSuggestionKind.unsupported,
          _ => VoiceSuggestionKind.switchTier,
        },
        targetFamily: json['targetFamily'] as String? ?? '',
        targetProvider: json['targetProvider'] as String? ?? '',
        targetModel: json['targetModel'] as String? ?? '',
        reason: json['reason'] as String? ?? '',
        defaultEndpoint: json['defaultEndpoint'] as String?,
        addressTemplate: json['addressTemplate'] as String?,
        addressGuidance: json['addressGuidance'] as String?,
      );

  final VoiceSuggestionKind kind;

  /// 建议落位的服务族 wire 值（`synthesis`＝朗读，`transcription`＝转写）。
  /// 与当前域不同时本域回填不了，卡片只给指路文案。
  final String targetFamily;

  /// 建议落位的协议档 wire 名（如 `qwen_tts`）。
  final String targetProvider;

  /// 应换档时为该型号本身；不支持时为建议替代型号。
  final String targetModel;

  /// Host 给的人话结论（设置页卡片与正式路径话术同源）。
  final String reason;

  /// 可代填的缺省端点；新版端点（含业务空间 ID）为 null——栖语不代填。
  final String? defaultEndpoint;

  /// 官方地址模板（含拼接占位）：只给指引不代填时非 null。
  final String? addressTemplate;

  /// 模板拼接指引话术。
  final String? addressGuidance;

  /// 建议是否落在朗读域：朗读设置页据此决定亮不亮「按建议调整」；
  /// 落在转写域时卡片只给指路文案。
  bool get targetsSynthesis => targetFamily == 'synthesis';

  /// 建议是否落在转写域：转写设置页据此决定亮不亮「按建议调整」；
  /// 落在朗读域时卡片只给指路文案。
  bool get targetsTranscription => targetFamily == 'transcription';
}

/// 建议的两种形态：应换档（含同档内换新版端点）与不支持。
enum VoiceSuggestionKind { switchTier, unsupported }

/// 档位建议引导卡片：人话结论＋（可回填时的）「按建议调整」按钮。
/// 朗读与转写两个设置域共用同一张卡片（票 04 接转写侧），回填动作由
/// 调用方确认后执行——本组件不落盘任何配置。
///
/// 读屏：整卡是 live region，出现即播报结论；按钮带语义标签。窄屏无
/// 固定宽度，随面板收窄。
class VoiceTierSuggestionCard extends StatelessWidget {
  const VoiceTierSuggestionCard({
    super.key,
    required this.suggestion,
    required this.applyButtonKey,
    this.onApply,
  });

  final VoiceTierSuggestionData suggestion;

  /// 「按建议调整」按钮的测试定位键。
  final Key applyButtonKey;

  /// 确认制回填入口：null 表示本域回填不了（建议落在另一族），按钮
  /// 不亮，卡片只给指路文案。
  final VoidCallback? onApply;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final detailLines = <String>[
      if (suggestion.kind == VoiceSuggestionKind.unsupported)
        '可以改用 ${suggestion.targetModel}。'
      else ...[
        if (suggestion.defaultEndpoint != null)
          '建议地址：${suggestion.defaultEndpoint}',
        if (suggestion.addressTemplate != null) ...[
          '地址模板：${suggestion.addressTemplate}',
          ?suggestion.addressGuidance,
        ],
        '建议型号：${suggestion.targetModel}',
      ],
      if (onApply == null)
        '请到语音${suggestion.targetsSynthesis ? '朗读' : '输入'}设置里调整。',
    ];
    return Semantics(
      liveRegion: true,
      container: true,
      label: '换档建议。${suggestion.reason}',
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          border: Border.all(color: theme.colorScheme.outlineVariant),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  QiyuIcons.info,
                  size: 20,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    suggestion.reason,
                    style: theme.textTheme.bodyLarge,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              detailLines.join('\n'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
            if (onApply != null) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.tonal(
                  key: applyButtonKey,
                  onPressed: onApply,
                  // 读屏语义标签：按钮可见字样之外的完整动作说明。
                  child: const Text(
                    '按建议调整',
                    semanticsLabel:
                        '按建议调整，自动填好建议的档位、地址与型号，确认后才保存',
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 一键换档的地址处置：保持现状（同档，或跨档但建议未给可填地址）、
/// 填建议的缺省端点（现行形状）、把官方地址模板填作草稿（新版端点，
/// `{业务空间ID}` 待用户替换）。
enum RefillAddressAction { keepCurrent, suggestedEndpoint, templateDraft }

/// 应用一条建议后表单将处的状态：确认对话框据此如实展示「将要改成
/// 什么」，各设置域表单的 applySuggestion（朗读与转写共用本计划）按同
/// 一份计划落草稿——展示与回填永远同源，不各猜各的。
final class VoiceTierRefillPlan {
  const VoiceTierRefillPlan({
    required this.crossTier,
    required this.providerWireName,
    required this.model,
    required this.addressAction,
    required this.baseUrl,
  });

  /// 是否跨档：跨档清 Key 草稿（切换服务不沿用旧 Key），同档保留。
  final bool crossTier;

  /// 目标档 wire 名。
  final String providerWireName;

  /// 目标型号。
  final String model;

  /// 地址处置。
  final RefillAddressAction addressAction;

  /// 将落进地址栏的内容：建议端点、地址模板原文，或保持的现状。
  final String baseUrl;
}
