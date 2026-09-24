import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../theme/qiyu_tokens.dart';
import '../shell/qiyu_widgets.dart';
import 'settings_section_shell.dart';
import 'stt_settings_client.dart';
import 'stt_settings_view_model.dart';
import 'voice_tier_suggestion.dart';

/// 语音输入（STT）设置领域：转写服务类型、地址、模型、鉴权头、响应形态
/// 与 API Key。
///
/// 领域的深模块边界在这里收口——控制器与焦点管理、协议缺省值
/// （各协议各自的地址与模型档位）、设置同步、协议切换时的地址
/// 兼容性回填、草稿校验与保存编排都落在 [SttSettingsForm]；
/// [SttSettingsSection] 只负责把这些状态画出来。新增或修改本领域的
/// 一条校验、一个缺省值或一段保存编排，只动本文件。异步编排
/// （网关调用、加载与错误态）仍归 [SttSettingsViewModel]。
///
/// 自定义档（custom）的旋钮——鉴权头、响应形态、字段名/路径与高级
/// 参数——只在选中自定义档时露出与上送，切走即清草稿；脏字符与结构
/// 校验在 Host 保存时人话驳回（与地址、模型同律）。

/// 语音输入领域的表单控制器：服务类型选择态、各输入框的控制器与
/// 焦点、已保存设置的同步、草稿校验与保存编排。
///
/// 本类不是 widget，也不持有任何 UI 呈现；错误提示等「怎么说给人听」
/// 的呈现通过 [readDraftOrReport] 的回调交给区块 widget。
final class SttSettingsForm {
  SttSettingsForm();

  final baseUrlController = TextEditingController();
  final modelController = TextEditingController();
  final apiKeyController = TextEditingController();
  final authHeaderController = TextEditingController();
  final responseFieldController = TextEditingController();
  final extraParamsController = TextEditingController();

  final baseUrlFocusNode = FocusNode();
  final modelFocusNode = FocusNode();
  final apiKeyFocusNode = FocusNode();
  final authHeaderFocusNode = FocusNode();
  final responseFieldFocusNode = FocusNode();
  final extraParamsFocusNode = FocusNode();

  SttServiceKind _provider = SttServiceKind.openaiCompatible;
  SttResponseShape _responseShape = SttResponseShape.jsonPath;
  SttSettings? _syncedSettings;
  bool _disposed = false;

  /// 当前选中的服务类型。
  SttServiceKind get provider => _provider;

  /// 自定义档的当前响应形态（仅自定义档有意义）。
  SttResponseShape get responseShape => _responseShape;

  /// 当前协议的缺省地址与模型（含输入提示用档位）。
  ({String url, String model, String urlHint, String modelHint})
  get protocolDefaults => _sttProtocolDefaults(_provider);

  /// 页面卸载时释放全部控制器与焦点节点。
  void dispose() {
    _disposed = true;
    baseUrlController.dispose();
    modelController.dispose();
    apiKeyController.dispose();
    authHeaderController.dispose();
    responseFieldController.dispose();
    extraParamsController.dispose();
    baseUrlFocusNode.dispose();
    modelFocusNode.dispose();
    apiKeyFocusNode.dispose();
    authHeaderFocusNode.dispose();
    responseFieldFocusNode.dispose();
    extraParamsFocusNode.dispose();
  }

  /// 已保存设置同步进表单：只处理新出现的设置对象（同一对象重复同步
  /// 直接返回，用户的选择与草稿不被重置）；未配置时按当前协议回填
  /// 缺省地址与模型。Key 永不回显——只在未获焦时清掉旧草稿。
  void sync(SttSettings? settings) {
    if (settings == null || identical(settings, _syncedSettings)) {
      return;
    }
    _syncedSettings = settings;
    _provider = settings.provider;
    if (settings.configured) {
      syncFocusProtectedField(
        baseUrlController,
        baseUrlFocusNode,
        settings.baseUrl ?? '',
      );
      syncFocusProtectedField(
        modelController,
        modelFocusNode,
        settings.model ?? '',
      );
      // 自定义档旋钮随快照回显；其余档这些值恒为空，同步即清草稿。
      _responseShape = settings.responseShape;
      syncFocusProtectedField(
        authHeaderController,
        authHeaderFocusNode,
        settings.authHeader ?? '',
      );
      syncFocusProtectedField(
        responseFieldController,
        responseFieldFocusNode,
        settings.responseField ?? '',
      );
      final extraText =
          (settings.extraParams != null && settings.extraParams!.isNotEmpty)
          ? const JsonEncoder.withIndent('  ').convert(settings.extraParams)
          : '';
      syncFocusProtectedField(
        extraParamsController,
        extraParamsFocusNode,
        extraText,
      );
    } else {
      final defaults = _sttProtocolDefaults(_provider);
      syncFocusProtectedField(
        baseUrlController,
        baseUrlFocusNode,
        defaults.url,
      );
      syncFocusProtectedField(modelController, modelFocusNode, defaults.model);
      _responseShape = SttResponseShape.jsonPath;
      syncFocusProtectedField(authHeaderController, authHeaderFocusNode, '');
      syncFocusProtectedField(
        responseFieldController,
        responseFieldFocusNode,
        '',
      );
      syncFocusProtectedField(extraParamsController, extraParamsFocusNode, '');
    }
    if (!apiKeyFocusNode.hasFocus && apiKeyController.text.isNotEmpty) {
      apiKeyController.clear();
    }
  }

  /// 切换服务类型：地址空白或 scheme 与新协议不兼容（https 不能给豆包，
  /// wss 不能给 OpenAI 兼容、千问与自定义）时，换成新协议的缺省地址和
  /// 模型。自定义档旋钮只对自定义档有意义：切走时清掉草稿。
  void selectProvider(String wireName) {
    final next = SttServiceKind.values.firstWhere(
      (kind) => kind.wireName == wireName,
      orElse: () => SttServiceKind.openaiCompatible,
    );
    if (next == _provider) {
      return;
    }
    final previous = _provider;
    _provider = next;
    if (next != SttServiceKind.custom) {
      _responseShape = SttResponseShape.jsonPath;
      authHeaderController.clear();
      responseFieldController.clear();
      extraParamsController.clear();
    }
    _applyProtocolDefaults(from: previous, to: next);
  }

  /// 切换自定义档的响应形态（下拉给出 wire 名）。
  void selectResponseShape(String wireName) {
    _responseShape = SttResponseShape.values.firstWhere(
      (shape) => shape.wireName == wireName,
      orElse: () => SttResponseShape.jsonPath,
    );
  }

  void _applyProtocolDefaults({
    required SttServiceKind from,
    required SttServiceKind to,
  }) {
    final url = baseUrlController.text.trim();
    final model = modelController.text.trim();
    final fromDefaults = _sttProtocolDefaults(from);
    final toDefaults = _sttProtocolDefaults(to);
    final uri = Uri.tryParse(url);
    final schemeCompatible = switch (to) {
      SttServiceKind.openaiCompatible =>
        uri != null && (uri.scheme == 'http' || uri.scheme == 'https'),
      SttServiceKind.volcSeedAsr =>
        uri != null && (uri.scheme == 'ws' || uri.scheme == 'wss'),
      // 千问与自定义同为 HTTP 家族：http/https 互认。
      SttServiceKind.qwenAsr =>
        uri != null && (uri.scheme == 'http' || uri.scheme == 'https'),
      SttServiceKind.custom =>
        uri != null && (uri.scheme == 'http' || uri.scheme == 'https'),
    };
    if (url.isEmpty || !schemeCompatible) {
      baseUrlController.text = toDefaults.url;
      if (model.isEmpty || model == fromDefaults.model || !schemeCompatible) {
        modelController.text = toDefaults.model;
      }
    } else if (model.isEmpty || model == fromDefaults.model) {
      modelController.text = toDefaults.model;
    }
  }

  /// 读草稿：必填校验在领域内，自定义档另校验高级参数是合法 JSON 对象。
  /// 草稿不合法时经 [report] 给出人话并返回 null——呈现方式（渐隐提示）
  /// 由区块决定。鉴权头的脏字符与结构校验在 Host 保存时人话驳回（与
  /// 地址、模型同律，单一校验源）。
  SttSettingsDraft? readDraftOrReport(void Function(String message) report) {
    if (baseUrlController.text.trim().isEmpty ||
        modelController.text.trim().isEmpty) {
      report('请填写语音服务地址和模型名称。');
      return null;
    }
    final key = apiKeyController.text.trim();
    Map<String, Object?>? extraParams;
    String? authHeader;
    String? responseField;
    if (_provider == SttServiceKind.custom) {
      final extraText = extraParamsController.text.trim();
      if (extraText.isNotEmpty) {
        try {
          final decoded = jsonDecode(extraText);
          if (decoded is! Map) {
            report('自定义高级参数必须是 JSON 对象。');
            return null;
          }
          // 键急转字符串：JSON 对象键恒为字符串，懒 cast 只是给将来的
          // 手改调用方留一条裸 TypeError 的路。
          extraParams = Map<String, Object?>.from(
            decoded.map((k, v) => MapEntry(k.toString(), v)),
          );
        } on FormatException {
          report('自定义高级参数 JSON 格式不正确，请检查语法。');
          return null;
        }
      }
      final header = authHeaderController.text.trim();
      final field = responseFieldController.text.trim();
      authHeader = header.isEmpty ? null : header;
      responseField = field.isEmpty ? null : field;
    }
    return SttSettingsDraft(
      provider: _provider,
      baseUrl: baseUrlController.text.trim(),
      model: modelController.text.trim(),
      apiKey: key.isEmpty ? null : key,
      authHeader: authHeader,
      responseShape: _provider == SttServiceKind.custom
          ? _responseShape
          : null,
      responseField: responseField,
      extraParams: extraParams,
    );
  }

  /// 一次保存的领域编排：读草稿 → 交视图模型 → 成功后清掉 Key 草稿，
  /// 不把明文留在输入框（失败时草稿保留待重试）。返回是否真的保存成功。
  Future<bool> save(
    SttSettingsViewModel viewModel, {
    void Function(String message)? report,
  }) async {
    final draft = readDraftOrReport(report ?? (_) {});
    if (draft == null) {
      return false;
    }
    final saved = await viewModel.save(draft);
    if (saved && !_disposed) {
      apiKeyController.clear();
    }
    return saved;
  }

  /// 一键换档（确认制，ADR 0020，票 04 识别侧接线）：先算清回填计划，
  /// 再按同一份计划把建议落位写进表单草稿——落盘仍走用户点「保存到本
  /// 机」的既有保存路径。目标档不在已知档位集合时返回 null（对话框不
  /// 弹、表单不动，与建议解析的保守兜底同律）。计划规则与朗读侧一致：
  /// - 跨档：切档、按处置填地址（识别族建议都带可代填缺省端点；共享
  ///   计划形状里的官方地址模板分支照模式保留）、填型号，并清掉 Key
  ///   草稿——沿用「切换服务不沿用旧 Key」既有机制。
  /// - 同档（如千问识别档里把不支持型号换成替代型号）：只改型号。地址
  ///   与 Key 一律不动。
  VoiceTierRefillPlan? planSuggestionApply(VoiceTierSuggestionData suggestion) {
    if (_sttProviderLabel(suggestion.targetProvider) == null) {
      return null;
    }
    final crossTier = _provider.wireName != suggestion.targetProvider;
    final addressAction = !crossTier
        ? RefillAddressAction.keepCurrent
        : suggestion.defaultEndpoint != null
        ? RefillAddressAction.suggestedEndpoint
        : suggestion.addressTemplate != null
        ? RefillAddressAction.templateDraft
        : RefillAddressAction.keepCurrent;
    return VoiceTierRefillPlan(
      crossTier: crossTier,
      providerWireName: suggestion.targetProvider,
      model: suggestion.targetModel,
      addressAction: addressAction,
      baseUrl: switch (addressAction) {
        RefillAddressAction.suggestedEndpoint => suggestion.defaultEndpoint!,
        RefillAddressAction.templateDraft => suggestion.addressTemplate!,
        RefillAddressAction.keepCurrent => baseUrlController.text,
      },
    );
  }

  /// 按 [planSuggestionApply] 的计划落草稿；null 计划是显式 no-op。
  /// 计划在所有分支权威：keepCurrent 分支也照写 plan.baseUrl（内容即
  /// 现状、等值回写），展示与落草稿不存在分支差异。
  void applySuggestion(VoiceTierRefillPlan? plan) {
    if (plan == null) {
      return;
    }
    if (plan.crossTier) {
      selectProvider(plan.providerWireName);
    }
    baseUrlController.text = plan.baseUrl;
    modelController.text = plan.model;
    if (plan.crossTier) {
      apiKeyController.clear();
    }
  }
}

/// 语音输入设置区块。
class SttSettingsSection extends StatefulWidget {
  const SttSettingsSection({super.key});

  @override
  State<SttSettingsSection> createState() => _SttSettingsSectionState();
}

class _SttSettingsSectionState extends State<SttSettingsSection>
    with SettingsSaveFeedback {
  final _form = SttSettingsForm();

  @override
  void dispose() {
    _form.dispose();
    super.dispose();
  }

  /// 领域校验结论的呈现：渐隐提示播报。
  void _reportInvalidDraft(String message) =>
      showSettingsNotice(context, message);

  /// 一次保存：读草稿 → 交视图模型，成功收尾（统一轻提示与挂载检查）
  /// 归壳层 [SettingsSaveFeedback]。
  Future<void> _save(SttSettingsViewModel viewModel) async {
    final saved = await _form.save(viewModel, report: _reportInvalidDraft);
    reportSettingsSaved(saved);
  }

  Future<void> _confirmForgetKey(SttSettingsViewModel viewModel) async {
    final confirmed = await confirmSettingsForgetKey(
      context: context,
      keyPrefix: 'stt-',
      title: '忘记语音服务的 API Key？',
      content:
          '忘记后本机不再保存这个 Key，语音输入暂时不可用，直到你重新输入。'
          '语音服务的地址和模型不受影响。',
    );
    if (confirmed) {
      await viewModel.forgetApiKey();
    }
  }

  /// 一键换档的确认制（票 04 识别侧接线，与朗读侧同一体验）：先展示将
  /// 要改成什么（档位／地址／型号／Key），用户确认才写进表单草稿（落盘
  /// 仍要点「保存到本机」）。取消与摸掉对话框都算不改。各行内容全部从
  /// 回填计划的真实结果推导——展示与回填同源，地址行写的就是将要落进
  /// 地址栏的内容。
  Future<void> _confirmApplySuggestion(
    VoiceTierSuggestionData suggestion,
  ) async {
    final plan = _form.planSuggestionApply(suggestion);
    if (plan == null) {
      return;
    }
    final changes = <String>[
      if (plan.crossTier)
        '服务类型：${_sttProviderLabel(_form.provider.wireName)} → '
            '${_sttProviderLabel(plan.providerWireName)}',
      '模型名称：${_form.modelController.text.trim().isEmpty ? '（空）' : _form.modelController.text.trim()} → '
          '${plan.model}',
      switch (plan.addressAction) {
        RefillAddressAction.suggestedEndpoint =>
          '服务地址：填入建议地址\n${plan.baseUrl}',
        RefillAddressAction.templateDraft =>
          '服务地址：填入官方地址模板\n${plan.baseUrl}\n'
              '把 {业务空间ID} 换成你自己的阿里云百炼业务空间 ID 后再保存',
        RefillAddressAction.keepCurrent => '服务地址：不变',
      },
      // Key 行说实话：回填动作本身跨档清 Key 草稿、同档不动。
      if (plan.crossTier)
        'API Key：清空重填，切换服务不沿用旧 Key'
      else
        'API Key：保留',
    ];
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('stt-tier-suggestion-dialog'),
        title: const Text('按建议调整？'),
        content: Text(changes.join('\n')),
        actions: [
          QiyuFocusRingScope(
            borderRadius: QiyuRadii.circleBorder,
            child: TextButton(
              key: const Key('stt-tier-suggestion-cancel'),
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('再想想'),
            ),
          ),
          FilledButton(
            key: const Key('stt-tier-suggestion-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('按建议调整'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      setState(() => _form.applySuggestion(plan));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<SttSettingsViewModel>(
      builder: (context, viewModel, child) {
        _form.sync(viewModel.settings);
        final theme = Theme.of(context);
        final keySet = viewModel.settings?.keySet ?? false;
        final provider = _form.provider;
        final defaults = _form.protocolDefaults;
        final custom = provider == SttServiceKind.custom;
        return SettingsSectionPanel(
          sectionId: SettingsSectionId.stt,
          title: '语音输入',
          children: [
            Text(
              switch (provider) {
                SttServiceKind.openaiCompatible =>
                  '把说的话转成文字的服务（OpenAI 兼容转写，如 whisper 系列）。'
                        'Key 只保存在本机 provider.json；录音只存在内存里，'
                        '转写完成即丢弃，不会进入会话与记忆。',
                SttServiceKind.volcSeedAsr =>
                  '把说的话转成文字。豆包走官方语音识别协议；'
                        'Key 只保存在本机 provider.json；录音只存在内存里，'
                        '转写完成即丢弃，不会进入会话与记忆。',
                SttServiceKind.qwenAsr =>
                  '把说的话转成文字的服务（千问语音识别，走阿里云百炼）。'
                        'Key 只保存在本机 provider.json；录音只存在内存里，'
                        '转写完成即丢弃，不会进入会话与记忆。',
                SttServiceKind.custom =>
                  '把说的话转成文字的服务（自定义转写服务）。'
                        'POST 填写的完整地址，录音按 multipart 表单上传；'
                        'Key 只保存在本机 provider.json；录音只存在内存里，'
                        '转写完成即丢弃，不会进入会话与记忆。',
              },
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.55,
              ),
            ),
            const SizedBox(height: 16),
            SettingsControlledDropdown(
              dropdownKey: const Key('stt-provider'),
              label: '服务类型',
              value: provider.wireName,
              // 档位目录单处共用：下拉选项、对话框档位改名与建议回填的
              // 档位识别（未知 wire 名不回填）都从这里出。
              items: [
                for (final choice in _sttProviderChoices)
                  DropdownMenuItem(
                    value: choice.wireName,
                    child: Text(choice.label),
                  ),
              ],
              onChanged: (wireName) =>
                  setState(() => _form.selectProvider(wireName)),
            ),
            const SizedBox(height: 16),
            TextField(
              key: const Key('stt-base-url'),
              controller: _form.baseUrlController,
              focusNode: _form.baseUrlFocusNode,
              decoration: InputDecoration(
                labelText: '服务地址',
                hintText: defaults.urlHint,
                border: settingsOutlineBorder(color: QiyuColors.line),
                enabledBorder: settingsOutlineBorder(color: QiyuColors.line),
                focusedBorder: settingsOutlineBorder(
                  color: QiyuColors.composerFocusLine,
                ),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              key: const Key('stt-model'),
              controller: _form.modelController,
              focusNode: _form.modelFocusNode,
              decoration: InputDecoration(
                labelText: provider == SttServiceKind.volcSeedAsr
                    ? 'Resource-Id'
                    : '模型名称',
                hintText: defaults.modelHint,
                // 千问档亮一句支持范围说明：型号取协议缺省档位（与回填同源，
                // 不另立一份字面量），用户只看得到缺省型号时也知道支持范围。
                helperText: provider == SttServiceKind.qwenAsr
                    ? '支持 HTTP 非流式识别模型，如 $qwenAsrDefaultModel'
                    : null,
                border: settingsOutlineBorder(color: QiyuColors.line),
                enabledBorder: settingsOutlineBorder(color: QiyuColors.line),
                focusedBorder: settingsOutlineBorder(
                  color: QiyuColors.composerFocusLine,
                ),
              ),
            ),
            // 自定义档旋钮：鉴权头、响应形态与字段名/路径，只在这一档露出。
            if (custom) ...[
              const SizedBox(height: 16),
              TextField(
                key: const Key('stt-auth-header'),
                controller: _form.authHeaderController,
                focusNode: _form.authHeaderFocusNode,
                decoration: InputDecoration(
                  labelText: '鉴权头',
                  hintText: 'Authorization: Bearer',
                  helperText: '留空按默认 Authorization: Bearer 发送',
                  border: settingsOutlineBorder(color: QiyuColors.line),
                  enabledBorder: settingsOutlineBorder(color: QiyuColors.line),
                  focusedBorder: settingsOutlineBorder(
                    color: QiyuColors.composerFocusLine,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              SettingsControlledDropdown(
                dropdownKey: const Key('stt-response-shape'),
                label: '响应形态',
                value: _form.responseShape.wireName,
                items: const [
                  DropdownMenuItem(
                    value: 'json_path',
                    child: Text('JSON 字段路径'),
                  ),
                  DropdownMenuItem(value: 'sse', child: Text('SSE 流式')),
                ],
                onChanged: (wireName) =>
                    setState(() => _form.selectResponseShape(wireName)),
              ),
              const SizedBox(height: 16),
              TextField(
                key: const Key('stt-response-field'),
                controller: _form.responseFieldController,
                focusNode: _form.responseFieldFocusNode,
                decoration: InputDecoration(
                  labelText: '字段名/路径',
                  hintText: 'text',
                  helperText: 'JSON 字段路径形态生效，点号路径，如 result.text',
                  border: settingsOutlineBorder(color: QiyuColors.line),
                  enabledBorder: settingsOutlineBorder(color: QiyuColors.line),
                  focusedBorder: settingsOutlineBorder(
                    color: QiyuColors.composerFocusLine,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 8),
            SettingsApiKeyField(
              fieldKey: const Key('stt-api-key'),
              controller: _form.apiKeyController,
              focusNode: _form.apiKeyFocusNode,
              keySet: keySet,
              title: keySet
                  ? 'API Key 已保存在本机 provider.json'
                  : '尚未保存语音服务的 API Key',
              titleStyle: theme.textTheme.titleSmall,
              label: 'API Key',
              hint: keySet
                  ? '留空即可继续使用已保存的 Key'
                  : '保存后写入本机 provider.json',
              forgetButtonKey: const Key('forget-stt-key'),
              forgetLabel: '忘记语音服务的 Key',
              onForgetKey: viewModel.saving
                  ? null
                  : () => unawaited(_confirmForgetKey(viewModel)),
            ),
            // 高级参数面板：只对自定义档露出（其余档请求形状固定）。
            if (custom) ...[
              const SizedBox(height: 16),
              ExpansionTile(
                key: const Key('stt-advanced-params-tile'),
                title: const Text('高级参数'),
                subtitle: const Text('自定义转写服务扩展字段 (JSON)'),
                tilePadding: EdgeInsets.zero,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 8.0, bottom: 8.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '配置自定义转写服务的 multipart 额外表单字段，例如：\n'
                          '{\n'
                          '  "speaker": "zh",\n'
                          '  "enable_punctuation": true\n'
                          '}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          key: const Key('stt-extra-params'),
                          controller: _form.extraParamsController,
                          focusNode: _form.extraParamsFocusNode,
                          keyboardType: TextInputType.multiline,
                          maxLines: 5,
                          decoration: InputDecoration(
                            labelText: '自定义扩展字段 (JSON)',
                            hintText:
                                '{\n  "speaker": "zh"\n}',
                            contentPadding: const EdgeInsets.all(16),
                            border: settingsOutlineBorder(color: QiyuColors.line),
                            enabledBorder: settingsOutlineBorder(
                              color: QiyuColors.line,
                            ),
                            focusedBorder: settingsOutlineBorder(
                              color: QiyuColors.composerFocusLine,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 20),
            if (viewModel.errorMessage case final message?)
              SettingsStatusMessage(message: message, succeeded: false),
            if (viewModel.errorMessage == null)
              // 命中档位映射表（ADR 0020，票 04 识别侧接线）：引导卡片取代
              // 普通失败行——Host 从未出网，结论与「按建议调整」当场可读
              // 可点。建议落在朗读域时本域回填不了，卡片只给指路文案。
              if (viewModel.testResult?.tierSuggestion case final suggestion?)
                VoiceTierSuggestionCard(
                  suggestion: suggestion,
                  applyButtonKey: const Key('stt-tier-suggestion-apply'),
                  // 建议落在朗读域、或目标档本界面不认识时回填不了：
                  // 只给指路文案（回填计划算不出来即不亮按钮）。
                  onApply: suggestion.targetsTranscription &&
                          _form.planSuggestionApply(suggestion) != null
                      ? () => unawaited(_confirmApplySuggestion(suggestion))
                      : null,
                )
              else if (viewModel.testResult case final result?)
                SettingsStatusMessage(
                  message: result.message,
                  succeeded: result.succeeded,
                ),
            if (viewModel.errorMessage != null || viewModel.testResult != null)
              const SizedBox(height: 14),
            SettingsSaveTestButtons(
              saveButtonKey: const Key('save-stt-settings'),
              saveLabel: '保存到本机',
              saveBusy: viewModel.saving,
              onSave: () => unawaited(_save(viewModel)),
              test: (
                buttonKey: const Key('test-stt-connection'),
                label: '测试连接',
                busy: viewModel.testing,
                onPressed: () {
                  final draft = _form.readDraftOrReport(_reportInvalidDraft);
                  if (draft != null) {
                    unawaited(viewModel.testConnection(draft));
                  }
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 转写档位目录：wire 名 ↔ 设置页人话标签，单处共用——服务类型下拉的
/// 选项、确认对话框里的档位名、建议回填的档位识别（[_sttProviderLabel]
/// 查不到即未知档位，不亮回填）都从这里出。
const _sttProviderChoices = <({String wireName, String label})>[
  (wireName: 'openai_compatible', label: 'OpenAI 兼容转写'),
  (wireName: 'volc_seed_asr', label: '豆包流式语音识别'),
  (wireName: 'qwen_asr', label: '千问语音识别'),
  (wireName: 'custom', label: '自定义转写服务'),
];

/// 服务类型 wire 名 → 设置页同款人话标签；未知 wire 名返回 null
/// （Host 表将来给出本界面不认识的档位时，保守不回填）。
String? _sttProviderLabel(String wireName) {
  for (final choice in _sttProviderChoices) {
    if (choice.wireName == wireName) {
      return choice.label;
    }
  }
  return null;
}

/// 各套 STT 协议各自的缺省地址、模型与输入提示档位。千问档给完整端点
/// 与官方示例模型（地址栏不拼后缀，两种请求形状都用同一个地址）；自定义
/// 档给空档——完整地址由用户直填，没有可猜的缺省端点。
({String url, String model, String urlHint, String modelHint})
_sttProtocolDefaults(SttServiceKind kind) => switch (kind) {
  SttServiceKind.openaiCompatible => (
    url: '',
    model: '',
    urlHint: 'https://api.example.com/v1',
    modelHint: 'whisper-1',
  ),
  SttServiceKind.volcSeedAsr => (
    url: 'wss://openspeech.bytedance.com/api/v3/plan/sauc/bigmodel_nostream',
    model: 'volc.seedasr.sauc.duration',
    urlHint:
        'wss://openspeech.bytedance.com/api/v3/plan/sauc/bigmodel_nostream',
    modelHint: 'volc.seedasr.sauc.duration',
  ),
  SttServiceKind.qwenAsr => (
    url: qwenAsrDefaultEndpoint,
    model: qwenAsrDefaultModel,
    urlHint: qwenAsrDefaultEndpoint,
    modelHint: qwenAsrDefaultModel,
  ),
  SttServiceKind.custom => (
    url: '',
    model: '',
    urlHint: 'https://api.example.com/v1/audio/transcriptions',
    modelHint: 'whisper-1',
  ),
};
