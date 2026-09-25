import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../theme/qiyu_icons.dart';
import '../../theme/qiyu_tokens.dart';
import '../shell/qiyu_widgets.dart';
import 'provider_catalog.dart';
import 'settings_section_shell.dart';
import 'tts_settings_client.dart';
import 'tts_settings_view_model.dart';
import 'voice_tier_suggestion.dart';

/// 语音朗读（TTS）设置领域：合成服务类型、地址、模型、音色、语速、
/// 高级参数与 API Key。
///
/// 领域的深模块边界在这里收口——控制器与焦点管理、协议缺省值与音色
/// 预设目录的落位、设置同步（含 extraParams 的 JSON 编排）、语速选择
/// 态、草稿校验（必填与 extraParams 的 JSON 对象校验）与保存编排都落
/// 在 [TtsSettingsForm]；[TtsSettingsSection] 只负责把这些状态画出来。
/// 新增或修改本领域的一条校验、一个缺省值或一段保存编排，只动本文件。
/// 异步编排（网关调用、加载、错误态与试听播放）仍归
/// [TtsSettingsViewModel]。
///
/// 自定义档（custom）的旋钮——鉴权头、响应形态、字段名与高级参数——
/// 只在选中自定义档时露出与上送，切走即清草稿；脏字符与结构校验在
/// Host 保存时人话驳回（与地址、模型同律）。

/// 语音朗读领域的表单控制器：服务类型与音色选择态、语速、各输入框
/// 的控制器与焦点、已保存设置的同步、草稿校验与保存编排。
///
/// 本类不是 widget，也不持有任何 UI 呈现；错误提示等「怎么说给人听」
/// 的呈现通过 [readDraftOrReport] 的回调交给区块 widget。
final class TtsSettingsForm {
  TtsSettingsForm();

  final baseUrlController = TextEditingController();
  final modelController = TextEditingController();
  final apiKeyController = TextEditingController();
  final voiceController = TextEditingController();
  final authHeaderController = TextEditingController();
  final responseFieldController = TextEditingController();
  final extraParamsController = TextEditingController();

  final baseUrlFocusNode = FocusNode();
  final modelFocusNode = FocusNode();
  final apiKeyFocusNode = FocusNode();
  final voiceFocusNode = FocusNode();
  final authHeaderFocusNode = FocusNode();
  final responseFieldFocusNode = FocusNode();
  final extraParamsFocusNode = FocusNode();

  TtsServiceKind _provider = TtsServiceKind.openAiCompatible;
  bool _customVoice = false;
  double? _speed;
  TtsResponseShape _responseShape = TtsResponseShape.rawBytes;
  TtsTransport _transport = TtsTransport.httpChunk;
  TtsSettings? _syncedSettings;
  bool _disposed = false;

  /// 当前选中的服务类型。
  TtsServiceKind get provider => _provider;

  /// 当前语速档：null＝默认。
  double? get speed => _speed;

  /// 自定义档的当前响应形态（仅自定义档有意义）。
  TtsResponseShape get responseShape => _responseShape;

  /// 豆包档的当前传输方式（票三）：HTTP 分块或缺省 WebSocket 双向。
  TtsTransport get transport => _transport;

  /// 当前协议的缺省地址与模型（含输入提示用档位）。
  ({String url, String model, String urlHint, String modelHint})
  get protocolDefaults => _ttsProtocolDefaults(_provider);

  /// 音色下拉的当前值：自定义音色态显示「输入其他音色 ID」那一档；
  /// 已存音色不在当前协议预设目录里时也按自定义态呈现。
  String get voiceDropdownValue {
    final presets = ttsVoicePresetsFor(_provider);
    final currentVoice = voiceController.text.trim();
    if (_customVoice) {
      return customVoiceValue;
    }
    if (currentVoice.isEmpty) {
      return presets.isNotEmpty ? presets.first.id : customVoiceValue;
    }
    return presets.any((p) => p.id == currentVoice)
        ? currentVoice
        : customVoiceValue;
  }

  /// 是否亮出音色 ID 输入框。按协议显式判定而不是按「无预设目录」推断：
  /// 千问档没有预设音色目录，音色恒为自由输入；自定义合成档同样没有
  /// 目录，但 Spec 不给它音色位（只露出鉴权头/响应形态/字段名/高级
  /// 参数四件套）——按空目录推断会让它连带多出一个音色输入框。
  bool get showCustomVoiceField {
    if (_provider == TtsServiceKind.qwenTts) {
      return true;
    }
    final presets = ttsVoicePresetsFor(_provider);
    final currentVoice = voiceController.text.trim();
    return _customVoice ||
        (currentVoice.isNotEmpty && presets.every((p) => p.id != currentVoice));
  }

  /// 页面卸载时释放全部控制器与焦点节点。
  void dispose() {
    _disposed = true;
    baseUrlController.dispose();
    modelController.dispose();
    apiKeyController.dispose();
    voiceController.dispose();
    authHeaderController.dispose();
    responseFieldController.dispose();
    extraParamsController.dispose();
    baseUrlFocusNode.dispose();
    modelFocusNode.dispose();
    apiKeyFocusNode.dispose();
    voiceFocusNode.dispose();
    authHeaderFocusNode.dispose();
    responseFieldFocusNode.dispose();
    extraParamsFocusNode.dispose();
  }

  /// 已保存设置同步进表单：只处理新出现的设置对象（同一对象重复同步
  /// 直接返回，用户的选择与草稿不被重置）；未配置时按当前协议回填
  /// 缺省地址、模型与首个音色预设。Key 永不回显——只在未获焦时清掉
  /// 旧草稿。
  void sync(TtsSettings? settings) {
    if (settings == null || identical(settings, _syncedSettings)) {
      return;
    }
    _syncedSettings = settings;
    _provider = settings.provider;
    final presets = ttsVoicePresetsFor(_provider);
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
      final voice = settings.voice?.trim() ?? '';
      syncFocusProtectedField(voiceController, voiceFocusNode, voice);
      _customVoice = voice.isNotEmpty && !presets.any((p) => p.id == voice);
      _speed = settings.speed;
      // 传输方式随快照回显（只对豆包档有意义，其余档恒为缺省值）。
      _transport = settings.transport;
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
      final defaults = _ttsProtocolDefaults(_provider);
      syncFocusProtectedField(
        baseUrlController,
        baseUrlFocusNode,
        defaults.url,
      );
      syncFocusProtectedField(modelController, modelFocusNode, defaults.model);
      syncFocusProtectedField(
        voiceController,
        voiceFocusNode,
        _defaultVoiceFor(_provider),
      );
      _customVoice = false;
      _speed = null;
      _responseShape = TtsResponseShape.rawBytes;
      _transport = TtsTransport.httpChunk;
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

  /// 切换服务类型：落该协议的缺省地址与模型，并选该协议的缺省音色
  /// （预设目录首档，千问档给官方示例音色 ID）。千问与自定义档没有
  /// 语速参数：切过去就丢掉可能从上个协议带过来的语速草稿，不存一个
  /// 调了不动的值。自定义档旋钮只对自定义档有意义：切走时清掉草稿。
  /// 传输方式只归豆包档：切走即回落缺省 HTTP 分块（与 Host 落盘口径
  /// 一致，避免选了一个不消费的值）。
  void selectProvider(String wireName) {
    final next = TtsServiceKind.values.firstWhere(
      (kind) => kind.wireName == wireName,
      orElse: () => TtsServiceKind.openAiCompatible,
    );
    if (next == _provider) {
      return;
    }
    _provider = next;
    _customVoice = false;
    _transport = TtsTransport.httpChunk;
    if (next != TtsServiceKind.custom) {
      _responseShape = TtsResponseShape.rawBytes;
      authHeaderController.clear();
      responseFieldController.clear();
      extraParamsController.clear();
    }
    final defaults = _ttsProtocolDefaults(next);
    baseUrlController.text = defaults.url;
    modelController.text = defaults.model;
    voiceController.text = _defaultVoiceFor(next);
    if (next == TtsServiceKind.qwenTts || next == TtsServiceKind.custom) {
      _speed = null;
    }
  }

  /// 选择音色：预设音色直接落名，「输入其他音色 ID」切到自定义态并
  /// 清空等待输入。
  void selectVoice(String voice) {
    _customVoice = voice == customVoiceValue;
    voiceController.text = _customVoice ? '' : voice;
  }

  /// 调整语速；null＝回到默认档。
  void selectSpeed(double? value) {
    _speed = value;
  }

  /// 切换自定义档的响应形态（下拉给出 wire 名）。
  void selectResponseShape(String wireName) {
    _responseShape = TtsResponseShape.values.firstWhere(
      (shape) => shape.wireName == wireName,
      orElse: () => TtsResponseShape.rawBytes,
    );
  }

  /// 切换豆包档的传输方式（票三，下拉给出 wire 名）。
  void selectTransport(String wireName) {
    _transport = TtsTransport.values.firstWhere(
      (transport) => transport.wireName == wireName,
      orElse: () => TtsTransport.httpChunk,
    );
  }

  /// 读草稿：必填校验与 extraParams 的 JSON 对象校验都在领域内。草稿
  /// 不合法时经 [report] 给出人话并返回 null——呈现方式（渐隐提示）
  /// 由区块决定。自定义档另带鉴权头、响应形态与字段名旋钮；鉴权头的
  /// 脏字符与结构校验在 Host 保存时人话驳回（与地址、模型同律，单一
  /// 校验源）。
  TtsSettingsDraft? readDraftOrReport(void Function(String message) report) {
    if (baseUrlController.text.trim().isEmpty ||
        modelController.text.trim().isEmpty) {
      report('请填写语音合成服务地址和模型名称。');
      return null;
    }
    final key = apiKeyController.text.trim();
    final voice = voiceController.text.trim();
    Map<String, Object?>? extraParams;
    String? authHeader;
    String? responseField;
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
    if (_provider == TtsServiceKind.custom) {
      final header = authHeaderController.text.trim();
      final field = responseFieldController.text.trim();
      authHeader = header.isEmpty ? null : header;
      responseField = field.isEmpty ? null : field;
    }
    return TtsSettingsDraft(
      provider: _provider,
      baseUrl: baseUrlController.text.trim(),
      model: modelController.text.trim(),
      apiKey: key.isEmpty ? null : key,
      voice: voice.isEmpty ? null : voice,
      speed: _speed,
      extraParams: extraParams,
      authHeader: authHeader,
      responseShape: _provider == TtsServiceKind.custom
          ? _responseShape
          : null,
      responseField: responseField,
      // 传输方式只随豆包档上送：其余档 Host 归一为缺省 HTTP 分块。
      transport: _provider == TtsServiceKind.volcTts ? _transport : null,
    );
  }

  /// 一次保存的领域编排：读草稿 → 交视图模型 → 成功后清掉 Key 草稿，
  /// 不把明文留在输入框（失败时草稿保留待重试）。返回是否真的保存成功。
  Future<bool> save(
    TtsSettingsViewModel viewModel, {
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

  /// 一键换档（确认制，ADR 0020）：先算清回填计划，再按同一份计划把
  /// 建议落位写进表单草稿——落盘仍走用户点「保存到本机」的既有保存
  /// 路径。目标档不在已知档位集合时返回 null（对话框不弹、表单不动，
  /// 与建议解析的保守兜底同律）。计划规则：
  /// - 新版语音通道条目（票 07：defaultEndpoint 与 addressTemplate 同时
  ///   出现）：官方 WS 推理地址可代填，同档与跨档都把地址填成它——3.x
  ///   型号在现行地址上调不通（probe 实测），地址必须跟着换；maas 模板
  ///   只是卡片上的备选信息，不进草稿。
  /// - 跨档（其余建议）：切档、按处置填地址（可代填缺省端点直接填），
  ///   填型号，并清掉 Key 草稿——沿用「切换服务不沿用旧 Key」既有机制
  ///   （保存时已存 Key 也按凭据作用域清空，重填后生效）。
  /// - 同档（其余建议）：只改型号。地址与 Key 一律不动。
  VoiceTierRefillPlan? planSuggestionApply(VoiceTierSuggestionData suggestion) {
    if (_ttsProviderLabel(suggestion.targetProvider) == null) {
      return null;
    }
    final crossTier = _provider.wireName != suggestion.targetProvider;
    final RefillAddressAction addressAction;
    if (suggestion.defaultEndpoint != null &&
        suggestion.addressTemplate != null) {
      // 新版语音通道条目（票 07）：推理地址可代填，同档跨档都填。
      addressAction = RefillAddressAction.suggestedEndpoint;
    } else if (!crossTier) {
      addressAction = RefillAddressAction.keepCurrent;
    } else if (suggestion.defaultEndpoint != null) {
      addressAction = RefillAddressAction.suggestedEndpoint;
    } else if (suggestion.addressTemplate != null) {
      addressAction = RefillAddressAction.templateDraft;
    } else {
      addressAction = RefillAddressAction.keepCurrent;
    }
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

/// 语音朗读设置区块。
class TtsSettingsSection extends StatefulWidget {
  const TtsSettingsSection({super.key});

  @override
  State<TtsSettingsSection> createState() => _TtsSettingsSectionState();
}

class _TtsSettingsSectionState extends State<TtsSettingsSection>
    with SettingsSaveFeedback {
  final _form = TtsSettingsForm();

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
  Future<void> _save(TtsSettingsViewModel viewModel) async {
    final saved = await _form.save(viewModel, report: _reportInvalidDraft);
    reportSettingsSaved(saved);
  }

  Future<void> _confirmForgetKey(TtsSettingsViewModel viewModel) async {
    final confirmed = await confirmSettingsForgetKey(
      context: context,
      keyPrefix: 'tts-',
      title: '忘记语音合成的 API Key？',
      content:
          '忘记后本机不再保存这个 Key，栖语暂时读不出声，直到你重新输入。'
          '语音合成服务的地址、模型、音色和语速不受影响。',
    );
    if (confirmed) {
      await viewModel.forgetApiKey();
    }
  }

  /// 一键换档的确认制：先展示将要改成什么（档位／地址／型号／Key），
  /// 用户确认才写进表单草稿（落盘仍要点「保存到本机」）。取消与摸掉
  /// 对话框都算不改。四行内容全部从回填计划的真实结果推导——展示与
  /// 回填同源，地址行写的就是将要落进地址栏的内容。
  Future<void> _confirmApplySuggestion(
    VoiceTierSuggestionData suggestion,
  ) async {
    final plan = _form.planSuggestionApply(suggestion);
    if (plan == null) {
      return;
    }
    // 新版语音通道条目（票 07）：回填的是官方推理地址，maas 模板只是
    // 卡片备选——地址行与 Key 行都按推理地址口径如实说。
    final fillsNewVersionEndpoint =
        plan.addressAction == RefillAddressAction.suggestedEndpoint &&
        suggestion.addressTemplate != null;
    // 同档回填的地址内容是否真的会变：不变（如已在推理地址上换同档
    // 型号）就不换凭据作用域，Key 行照旧说「保留」。比较用原始 trim 值
    // 而非凭据作用域的地址归一（normalizeProviderBaseUri 在 Host 侧）：
    // 本地复制一份归一逻辑会造第二真相源，宁可在此过度警示（说成需
    // 重填而实际沿用）——作用域的真相在 Host 保存侧，反向漏警示不存在。
    final sameTierAddressChanges = !plan.crossTier &&
        plan.addressAction == RefillAddressAction.suggestedEndpoint &&
        plan.baseUrl.trim() != _form.baseUrlController.text.trim();
    final involvesMaasTemplate =
        suggestion.addressTemplate != null ||
        plan.addressAction == RefillAddressAction.templateDraft;
    final changes = <String>[
      if (plan.crossTier)
        '服务类型：${_ttsProviderLabel(_form.provider.wireName)} → '
            '${_ttsProviderLabel(plan.providerWireName)}',
      '模型名称：${_form.modelController.text.trim().isEmpty ? '（空）' : _form.modelController.text.trim()} → '
          '${plan.model}',
      switch (plan.addressAction) {
        RefillAddressAction.suggestedEndpoint when fillsNewVersionEndpoint =>
          '服务地址：填入官方推理地址\n${plan.baseUrl}',
        RefillAddressAction.suggestedEndpoint =>
          '服务地址：填入建议地址\n${plan.baseUrl}',
        RefillAddressAction.templateDraft =>
          '服务地址：填入官方地址模板\n${plan.baseUrl}\n'
              '把 {业务空间ID} 换成你自己的阿里云百炼业务空间 ID 后再保存',
        RefillAddressAction.keepCurrent when involvesMaasTemplate =>
          '服务地址：保持不变；保存测试前请按卡片指引把地址换成新版端点',
        RefillAddressAction.keepCurrent => '服务地址：不变',
      },
      // Key 行说实话：跨档清 Key 草稿（切换服务不沿用旧 Key，既有机制）；
      // 同档回填推理地址时地址会变——保存按既有凭据规则换作用域，Key
      // 需重填；地址不变的同档回填与纯换型号不动 Key。跨档分支不再附
      // 「需自有百炼 Key」：官方推理地址对可用 Key 放行（probe 实测），
      // maas 端点的 Key 要求只随备选模板出现在卡片指引里。
      if (plan.crossTier)
        'API Key：清空重填，切换服务不沿用旧 Key'
      else if (sameTierAddressChanges)
        'API Key：地址变更保存后 Key 需重填（已保存的 Key 不沿用新地址）'
      else if (involvesMaasTemplate &&
          plan.addressAction == RefillAddressAction.keepCurrent)
        'API Key：保留已保存的 Key；地址换成新版端点保存时，Key 按既有规则需重填'
      else
        'API Key：保留',
    ];
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('tts-tier-suggestion-dialog'),
        title: const Text('按建议调整？'),
        content: Text(changes.join('\n')),
        actions: [
          QiyuFocusRingScope(
            borderRadius: QiyuRadii.circleBorder,
            child: TextButton(
              key: const Key('tts-tier-suggestion-cancel'),
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('再想想'),
            ),
          ),
          FilledButton(
            key: const Key('tts-tier-suggestion-confirm'),
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
    return Consumer<TtsSettingsViewModel>(
      builder: (context, viewModel, child) {
        _form.sync(viewModel.settings);
        final theme = Theme.of(context);
        final keySet = viewModel.settings?.keySet ?? false;
        final testResult = viewModel.testResult;
        final provider = _form.provider;
        final defaults = _form.protocolDefaults;
        return SettingsSectionPanel(
          sectionId: SettingsSectionId.tts,
          title: '语音朗读',
          children: [
            Text(
              switch (provider) {
                TtsServiceKind.volcTts =>
                  '把栖语写完的话读出来。豆包语音合成走火山方舟接口，'
                        '传输方式见下方下拉（HTTP 分块逐句合成，或 WebSocket '
                        '双向边出文本边合成）；模型名称填 Resource-Id；'
                        'Key 只存本机 provider.json；音频只存在内存，播完即丢。',
                TtsServiceKind.qwenTts =>
                  '把栖语写完的话读出来的服务（千问语音合成，走阿里云百炼）。'
                        '她先把每句完整写好、过了安全检查才开口读；服务端返回'
                        '音频地址后由本机取回完整的一段；音频只存在内存，'
                        '播完即丢，本机不留声音文件。',
                TtsServiceKind.custom =>
                  '把栖语写完的话读出来的服务（自定义语音合成服务）。'
                        'POST 填写的完整地址，请求体固定 {model, input}，'
                        '响应按所选形态取音频；Key 只存本机 provider.json；'
                        '音频只存在内存，播完即丢，本机不留声音文件。',
                TtsServiceKind.openAiCompatible =>
                  '把栖语写完的话读出来的服务（OpenAI 兼容语音合成，如 tts-1）。'
                        '她先把每句完整写好、过了安全检查才开口读；音频只存在内存，'
                        '播完即丢，本机不留声音文件。',
              },
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.55,
              ),
            ),
            const SizedBox(height: 16),
            SettingsControlledDropdown(
              dropdownKey: const Key('tts-provider'),
              label: '服务类型',
              value: provider.wireName,
              // 档位目录单处共用：下拉选项、对话框档位改名与建议回填的
              // 档位识别（未知 wire 名不回填）都从这里出。
              items: [
                for (final choice in _ttsProviderChoices)
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
              key: const Key('tts-base-url'),
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
              key: const Key('tts-model'),
              controller: _form.modelController,
              focusNode: _form.modelFocusNode,
              decoration: InputDecoration(
                labelText: provider == TtsServiceKind.volcTts
                    ? 'Resource-Id'
                    : '模型名称',
                hintText: defaults.modelHint,
                // 千问档亮一句支持范围说明（F3：型号决定 API 家族，不做
                // 传输选择器）：型号取协议缺省档位（与回填同源，不另立
                // 一份字面量），用户只看得到缺省型号时也知道支持范围。
                // 流式型号两个家族：qwen3-tts-flash（HTTP SSE，边出文字
                // 边出声）与 qwen3-tts-flash-realtime（WebSocket 连续喂
                // 文本，前几个字就出声）；官方现标 Non-streaming 的旧型号
                // （qwen-audio-3.1-tts-next）不用于流式场景。
                // 3.x 新型号按地址派形状（ADR 0020 补篇，票 07）：官方
                // WS 推理地址实测全链路可用，直接填即可（按句流式）；
                // maas HTTP 端点留作备选（含业务空间 ID，栖语不代填，
                // 按句等整段返回）。
                helperText: provider == TtsServiceKind.qwenTts
                    ? '流式合成型号：$qwenTtsDefaultModel（HTTP SSE，边出文字边出声）'
                          '；$qwenTtsDefaultModel-realtime（WebSocket，前几个字就出声）\n'
                          '3.x 新型号（qwen-audio-3.1-tts-flash 等）走官方新版语音通道：'
                          '服务地址直接填 $qwenTtsWsInferenceEndpoint（推理通道按句流式）；'
                          '也可填官方 maas HTTP 端点 $qwenTtsMaasAddressTemplate，'
                          '把 {业务空间ID} 换成你自己的阿里云百炼业务空间 ID'
                          '（栖语不代填，按句等整段返回）；型号支持范围见'
                          '官方模型页：https://help.aliyun.com/zh/model-studio/qwen-tts'
                    : null,
                border: settingsOutlineBorder(color: QiyuColors.line),
                enabledBorder: settingsOutlineBorder(color: QiyuColors.line),
                focusedBorder: settingsOutlineBorder(
                  color: QiyuColors.composerFocusLine,
                ),
              ),
            ),
            const SizedBox(height: 16),
            // 豆包档的传输方式（票三）：HTTP 分块（逐句合成，票二形态）
            // 或 WebSocket 双向（边出文本边合成，首音再早一截）。只列已
            // 实现的两种；千问档按型号驱动（见模型名提示），自定义档不动。
            if (provider == TtsServiceKind.volcTts) ...[
              SettingsControlledDropdown(
                dropdownKey: const Key('tts-transport'),
                label: '传输方式',
                value: _form.transport.wireName,
                items: const [
                  DropdownMenuItem(
                    value: 'http_chunk',
                    child: Text('HTTP 分块'),
                  ),
                  DropdownMenuItem(
                    value: 'ws_bidirection',
                    child: Text('WebSocket 双向'),
                  ),
                ],
                helperText:
                    'HTTP 分块：每写好一句合成一句；'
                    'WebSocket 双向：前几个字一出就开始合成，多轮对话音色语调更连贯。'
                    '地址栏仍填 HTTP 端点，WebSocket 地址由本机自动派生',
                onChanged: (wireName) =>
                    setState(() => _form.selectTransport(wireName)),
              ),
              const SizedBox(height: 16),
            ],
            // 自定义档旋钮：鉴权头、响应形态与字段名，只在这一档露出。
            if (provider == TtsServiceKind.custom) ...[
              TextField(
                key: const Key('tts-auth-header'),
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
                dropdownKey: const Key('tts-response-shape'),
                label: '响应形态',
                value: _form.responseShape.wireName,
                items: const [
                  DropdownMenuItem(
                    value: 'raw_bytes',
                    child: Text('裸音频字节'),
                  ),
                  DropdownMenuItem(
                    value: 'json_field',
                    child: Text('JSON 字段'),
                  ),
                  DropdownMenuItem(
                    value: 'json_lines',
                    child: Text('逐行 JSON'),
                  ),
                ],
                // F3 第一期：自定义档的传输形态只列已实现的——裸音频字节
                // （且未覆盖成压缩格式）走 HTTP 分块流式（stream_format=
                // audio + response_format=pcm）；逐行 JSON 与 JSON 字段
                // 拿不到音频块，按 E1 每句一整块做句子级整段朗读（现有
                // 配置全部保留，不淘汰在用型号）。
                helperText:
                    '裸音频字节（且未覆盖成压缩格式）走流式分块合成；逐行 JSON 与 JSON 字段按句子级整段朗读',
                onChanged: (wireName) =>
                    setState(() => _form.selectResponseShape(wireName)),
              ),
              const SizedBox(height: 16),
              TextField(
                key: const Key('tts-response-field'),
                controller: _form.responseFieldController,
                focusNode: _form.responseFieldFocusNode,
                decoration: InputDecoration(
                  labelText: '字段名',
                  hintText: 'data',
                  helperText: 'JSON 字段与逐行 JSON 形态生效，留取缺省 data',
                  border: settingsOutlineBorder(color: QiyuColors.line),
                  enabledBorder: settingsOutlineBorder(color: QiyuColors.line),
                  focusedBorder: settingsOutlineBorder(
                    color: QiyuColors.composerFocusLine,
                  ),
                ),
              ),
            ],
            Builder(
              builder: (context) {
                // 自定义档没有音色位：Spec 只给鉴权头/响应形态/字段名/高级
                // 参数四件套，音色（厂商各叫各的）走高级参数传。
                if (provider == TtsServiceKind.custom) {
                  return const SizedBox.shrink();
                }
                // 千问档没有预设音色目录：音色直给「音色 ID」输入框，
                // 任何千问音色 ID 都能填。
                if (provider == TtsServiceKind.qwenTts) {
                  return TextField(
                    key: const Key('tts-voice'),
                    controller: _form.voiceController,
                    focusNode: _form.voiceFocusNode,
                    decoration: InputDecoration(
                      labelText: '音色 ID',
                      hintText: qwenTtsDefaultVoice,
                      border: settingsOutlineBorder(color: QiyuColors.line),
                      enabledBorder: settingsOutlineBorder(
                        color: QiyuColors.line,
                      ),
                      focusedBorder: settingsOutlineBorder(
                        color: QiyuColors.composerFocusLine,
                      ),
                    ),
                  );
                }
                final voicePresets = ttsVoicePresetsFor(provider);
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SettingsControlledDropdown(
                      dropdownKey: const Key('tts-voice-preset'),
                      label: '朗读音色',
                      value: _form.voiceDropdownValue,
                      items: [
                        for (final preset in voicePresets)
                          DropdownMenuItem(
                            value: preset.id,
                            child: Text(
                              preset.category != null
                                  ? '【${preset.category}】${preset.label}'
                                  : preset.label,
                            ),
                          ),
                        const DropdownMenuItem(
                          value: customVoiceValue,
                          child: Row(
                            children: [
                              Icon(QiyuIcons.edit, size: 18),
                              SizedBox(width: 8),
                              Text('输入其他音色 ID'),
                            ],
                          ),
                        ),
                      ],
                      onChanged: (voice) =>
                          setState(() => _form.selectVoice(voice)),
                    ),
                    if (_form.showCustomVoiceField) ...[
                      const SizedBox(height: 16),
                      TextField(
                        key: const Key('tts-voice'),
                        controller: _form.voiceController,
                        focusNode: _form.voiceFocusNode,
                        decoration: InputDecoration(
                          labelText: '音色 ID',
                          hintText: provider == TtsServiceKind.volcTts
                              ? 'zh_female_vv_uranus_bigtts'
                              : 'alloy',
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
                  ],
                );
              },
            ),
            // 千问与自定义档没有语速参数：不显示语速滑条（厂商自有语速
            // 参数走高级参数传），界面不出现调了不动的旋钮。
            if (provider != TtsServiceKind.qwenTts &&
                provider != TtsServiceKind.custom) ...[
              const SizedBox(height: 8),
              MergeSemantics(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            _form.speed == null
                                ? '语速：默认'
                                : '语速：${_form.speed!.toStringAsFixed(2)} 倍',
                            style: theme.textTheme.titleSmall,
                          ),
                        ),
                        if (_form.speed != null)
                          QiyuFocusRingScope(
                            borderRadius: QiyuRadii.circleBorder,
                            child: TextButton(
                              key: const Key('tts-speed-reset'),
                              onPressed: () =>
                                  setState(() => _form.selectSpeed(null)),
                              child: const Text('默认'),
                            ),
                          ),
                      ],
                    ),
                    Slider(
                      key: const Key('tts-speed-slider'),
                      value: _form.speed ?? 1.0,
                      min: 0.5,
                      max: 2.0,
                      divisions: 6,
                      label: (_form.speed ?? 1.0).toStringAsFixed(2),
                      onChanged: (value) =>
                          setState(() => _form.selectSpeed(value)),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 8),
            SettingsApiKeyField(
              fieldKey: const Key('tts-api-key'),
              controller: _form.apiKeyController,
              focusNode: _form.apiKeyFocusNode,
              keySet: keySet,
              title: keySet
                  ? 'API Key 已保存在本机 provider.json'
                  : '尚未保存语音合成的 API Key',
              titleStyle: theme.textTheme.titleSmall,
              label: 'API Key',
              hint: keySet
                  ? '留空即可继续使用已保存的 Key'
                  : '保存后写入本机 provider.json',
              forgetButtonKey: const Key('forget-tts-key'),
              forgetLabel: '忘记语音合成的 Key',
              onForgetKey: viewModel.saving
                  ? null
                  : () => unawaited(_confirmForgetKey(viewModel)),
            ),
            const SizedBox(height: 16),
            ExpansionTile(
              key: const Key('tts-advanced-params-tile'),
              title: const Text('高级参数'),
              subtitle: const Text('自定义云端扩展参数 (JSON)'),
              tilePadding: EdgeInsets.zero,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 8.0, bottom: 8.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        switch (provider) {
                          TtsServiceKind.volcTts =>
                            '配置豆包语音合成的深合并参数，例如：\n'
                                  '{\n'
                                  '  "audio_params": { "sample_rate": 16000 },\n'
                                  '  "additions": { "explicit_dialect": "sichuan" }\n'
                                  '}',
                          // 千问的高级参数深合并进 input：换 instruct 模型时
                          // 传 instructions 这类指令控制字段。
                          TtsServiceKind.qwenTts =>
                            '配置千问语音合成的扩展参数，深合并进 input，例如：\n'
                                  '{\n'
                                  '  "instructions": "用温柔的语气慢慢读"\n'
                                  '}',
                          // 自定义档的高级参数同样深合并进 input：音色、语速
                          // 这类厂商字段名各叫各的，都从这里兜住。
                          TtsServiceKind.custom =>
                            '配置自定义语音合成服务的扩展参数，深合并进 input，例如：\n'
                                  '{\n'
                                  '  "voice": "custom-voice"\n'
                                  '}',
                          TtsServiceKind.openAiCompatible =>
                            '配置 OpenAI 兼容语音合成的顶层扩展参数，例如：\n'
                                  '{\n'
                                  '  "response_format": "mp3"\n'
                                  '}\n'
                                  '覆盖成压缩格式将按句子级整段朗读。',
                        },
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        key: const Key('tts-extra-params'),
                        controller: _form.extraParamsController,
                        focusNode: _form.extraParamsFocusNode,
                        keyboardType: TextInputType.multiline,
                        maxLines: 5,
                        decoration: InputDecoration(
                          labelText: '自定义扩展参数 (JSON)',
                          hintText:
                              '{\n  "audio_params": {\n    "sample_rate": 16000\n  }\n}',
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
            const SizedBox(height: 20),
            if (viewModel.errorMessage case final message?)
              SettingsStatusMessage(message: message, succeeded: false),
            if (viewModel.errorMessage == null)
              // 命中档位映射表（ADR 0020）：引导卡片取代普通失败行——
              // Host 从未出网，结论与「按建议调整」当场可读可点。建议落
              // 在转写域时本域回填不了，卡片只给指路文案。
              if (testResult?.tierSuggestion case final suggestion?)
                VoiceTierSuggestionCard(
                  suggestion: suggestion,
                  applyButtonKey: const Key('tts-tier-suggestion-apply'),
                  // 建议落在转写域、或目标档本界面不认识时回填不了：
                  // 只给指路文案（回填计划算不出来即不亮按钮）。
                  onApply: suggestion.targetsSynthesis &&
                          _form.planSuggestionApply(suggestion) != null
                      ? () => unawaited(_confirmApplySuggestion(suggestion))
                      : null,
                )
              else if (testResult case final result?)
                SettingsStatusMessage(
                  message: result.message,
                  succeeded: result.succeeded,
                ),
            if (testResult != null && testResult.succeeded) ...[
              const SizedBox(height: 8),
              TextButton.icon(
                key: const Key('tts-replay-preview'),
                onPressed: () => unawaited(viewModel.replayPreview()),
                icon: const Icon(QiyuIcons.volume_up),
                label: const Text('再听一次试听'),
              ),
            ],
            if (viewModel.errorMessage != null || testResult != null)
              const SizedBox(height: 14),
            SettingsSaveTestButtons(
              saveButtonKey: const Key('save-tts-settings'),
              saveLabel: '保存到本机',
              saveBusy: viewModel.saving,
              onSave: () => unawaited(_save(viewModel)),
              test: (
                buttonKey: const Key('test-tts-connection'),
                label: '测试连接并试听',
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

/// 朗读档位目录：wire 名 ↔ 设置页人话标签，单处共用——服务类型下拉的
/// 选项、确认对话框里的档位名、建议回填的档位识别（[_ttsProviderLabel]
/// 查不到即未知档位，不亮回填）都从这里出。
const _ttsProviderChoices = <({String wireName, String label})>[
  (wireName: 'openai_compatible', label: 'OpenAI 兼容语音合成'),
  (wireName: 'volc_tts', label: '豆包语音合成'),
  (wireName: 'qwen_tts', label: '千问语音合成'),
  (wireName: 'custom', label: '自定义合成服务'),
];

/// 服务类型 wire 名 → 设置页同款人话标签；未知 wire 名返回 null
/// （Host 表将来给出本界面不认识的档位时，保守不回填）。
String? _ttsProviderLabel(String wireName) {
  for (final choice in _ttsProviderChoices) {
    if (choice.wireName == wireName) {
      return choice.label;
    }
  }
  return null;
}

/// 三套 TTS 协议各自的缺省地址、模型与输入提示档位。千问与千问识别同
/// 端点（阿里云百炼 DashScope 多模态接口）：地址是完整端点、不拼后缀，
/// 模型与音色给官方示例值。自定义档给空档——完整地址由用户直填，没有
/// 可猜的缺省端点（与转写自定义档同律）。
({String url, String model, String urlHint, String modelHint})
_ttsProtocolDefaults(TtsServiceKind kind) => switch (kind) {
  TtsServiceKind.openAiCompatible => (
    url: '',
    model: '',
    urlHint: 'https://api.example.com/v1',
    modelHint: 'tts-1',
  ),
  // 豆包走火山方舟订阅专属 HTTP 端点（官方文档 2026-08-23 核实）：
  // 地址是完整端点、模型名称字段填 Resource-Id（不带 volc. 前缀）。
  TtsServiceKind.volcTts => (
    url: 'https://openspeech.bytedance.com/api/v3/plan/tts/unidirectional',
    model: 'seed-tts-2.0',
    urlHint: 'https://openspeech.bytedance.com/api/v3/plan/tts/unidirectional',
    modelHint: 'seed-tts-2.0',
  ),
  TtsServiceKind.qwenTts => (
    url: qwenTtsDefaultEndpoint,
    model: qwenTtsDefaultModel,
    urlHint: qwenTtsDefaultEndpoint,
    modelHint: qwenTtsDefaultModel,
  ),
  TtsServiceKind.custom => (
    url: '',
    model: '',
    urlHint: 'https://api.example.com/v1/audio/speech',
    modelHint: 'tts-1',
  ),
};

/// 各协议的缺省音色：有预设目录的落首档，没有目录的档给各自的缺省值
/// （千问直给官方示例音色 ID）。
///
/// 为什么按协议点名而不是按「无预设目录」推断：缺省音色是各协议自己
/// 的值，空目录只是千问当前恰好没有目录。按空目录推断会让将来的无目录
/// 档（如自定义合成）顺手继承千问的 Cherry；点名写死则新档位进来时
/// 逃不过一次显式选择。
String _defaultVoiceFor(TtsServiceKind kind) {
  final presets = ttsVoicePresetsFor(kind);
  if (presets.isNotEmpty) {
    return presets.first.id;
  }
  return kind == TtsServiceKind.qwenTts ? qwenTtsDefaultVoice : '';
}
