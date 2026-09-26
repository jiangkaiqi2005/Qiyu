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
import 'voice_tier_metadata.dart';
import 'voice_tier_suggestion.dart';

/// 语音朗读（TTS）设置领域：合成服务类型、地址、模型、音色、语速、
/// 高级参数与 API Key。
///
/// 领域的深模块边界在这里收口——控制器与焦点管理、设置同步（含
/// extraParams 的 JSON 编排）、语速选择态、草稿校验（必填与 extraParams
/// 的 JSON 对象校验）与保存编排都落在 [TtsSettingsForm]；
/// [TtsSettingsSection] 只负责把这些状态画出来。新增或修改本领域的一
/// 条校验或一段保存编排，只动本文件。异步编排（网关调用、加载、错误
/// 态与试听播放）仍归 [TtsSettingsViewModel]。
///
/// 档位知识不在这里（票 08，ADR 0021）：服务类型下拉、说明文案、缺省
/// 地址与模型、各档能力开关全部来自宿主随快照下推的档位元数据
/// （[VoiceTierMetadata]），旧版宿主回落内置降级目录。新增一个档位＝
/// 宿主归口加数据行，本文件零改动。
///
/// 自定义档（custom）的旋钮——鉴权头、响应形态、字段名与高级参数——
/// 只在元数据声明旋钮能力的档露出与上送，切走即清草稿；脏字符与结构
/// 校验在 Host 保存时人话驳回（与地址、模型同律）。

/// 语音朗读领域的表单控制器：服务类型选择态、语速、各输入框的控制器
/// 与焦点、已保存设置的同步、草稿校验与保存编排。
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

  /// 当前选中的档位 wire 名（票 08）：元数据下推的档位集可以比
  /// [TtsServiceKind] 大，表单按 wire 名持有选择、按元数据渲染。
  String _providerWireName = 'openai_compatible';

  /// 档位元数据目录：随快照下推，快照缺席（旧版宿主）回落内置降级目录。
  VoiceTierCatalog _tierCatalog = const VoiceTierCatalog(
    pushed: null,
    fallback: builtinTtsTierCatalog,
  );

  bool _customVoice = false;
  double? _speed;
  TtsResponseShape _responseShape = TtsResponseShape.rawBytes;
  TtsTransport _transport = TtsTransport.httpChunk;
  TtsSettings? _syncedSettings;
  bool _disposed = false;

  /// 当前选中的服务类型（类型化视图）：未知 wire 名按缺省档呈现，原始
  /// 身份在 [_providerWireName]。
  TtsServiceKind get provider =>
      TtsServiceKind.maybeFromWireName(_providerWireName) ??
      TtsServiceKind.openAiCompatible;

  /// 当前选中档位的下推元数据：渲染与缺省回填的唯一档位知识源（票 08）。
  VoiceTierMetadata get tier => _tierCatalog.tierFor(_providerWireName);

  /// 当前选中的档位 wire 名（下拉取值、保存编排与类型化视图共用）。
  String get providerWireName => _providerWireName;

  /// 服务类型下拉的当前值：选中档在呈现行集里时用它的 wire 名；行集
  /// 缺席该档（旧版宿主快照带未知 wire 名的防御形状）时回退类型化视
  /// 图的 wire 名，取值与选项不失配、界面不崩溃。
  String get dropdownValue {
    for (final wire in [_providerWireName, provider.wireName]) {
      if (_tierCatalog.rows.any((choice) => choice.wireName == wire)) {
        return wire;
      }
    }
    final rows = _tierCatalog.rows;
    return rows.isEmpty ? _providerWireName : rows.first.wireName;
  }

  /// 各档的缺省音色：预设档落目录首档（目录留在界面侧，随界面版本发
  /// 布），自由输入档给元数据带的官方示例音色，无音色位给空。
  String _defaultVoiceFor(VoiceTierMetadata current) {
    if (current.voiceMode == VoiceTierVoiceMode.presets) {
      final presets = ttsVoicePresetsFor(provider);
      if (presets.isNotEmpty) {
        return presets.first.id;
      }
    }
    return current.defaultVoice ?? '';
  }

  /// 服务类型下拉的行集：宿主下发的档位元数据，旧版宿主回落内置降级
  /// 目录，顺序即目录顺序。
  List<VoiceTierMetadata> get tierChoices => _tierCatalog.rows;

  /// 档位 wire 名 → 人话标签（确认对话框用）：查下发与降级行集；查不
  /// 到回退 wire 名本身（未知档位不显示成空）。
  String tierLabelOf(String wireName) =>
      _tierCatalog.knownTier(wireName)?.label ?? wireName;

  /// 当前语速档：null＝默认。
  double? get speed => _speed;

  /// 自定义档的当前响应形态（仅旋钮档有意义）。
  TtsResponseShape get responseShape => _responseShape;

  /// 豆包档的当前传输方式（票三）：HTTP 分块或缺省 WebSocket 双向。
  TtsTransport get transport => _transport;

  /// 当前协议的缺省地址与模型（含输入提示用档位）。
  ({String url, String model, String urlHint, String modelHint})
  get protocolDefaults => (
    url: tier.defaultEndpoint,
    model: tier.defaultModel,
    urlHint: tier.urlHint,
    modelHint: tier.modelHint,
  );

  /// 音色下拉的当前值：自定义音色态显示「输入其他音色 ID」那一档；
  /// 已存音色不在当前协议预设目录里时也按自定义态呈现。
  String get voiceDropdownValue {
    final presets = ttsVoicePresetsFor(provider);
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

  /// 是否亮出音色 ID 输入框。自由输入档（元数据声明）恒亮；预设档在
  /// 自定义音色态或已存音色不在目录里时亮。
  bool get showCustomVoiceField {
    if (tier.voiceMode == VoiceTierVoiceMode.freeInput) {
      return true;
    }
    final presets = ttsVoicePresetsFor(provider);
    final currentVoice = voiceController.text.trim();
    return _customVoice ||
        (currentVoice.isNotEmpty && presets.every((p) => p.id != currentVoice));
  }

  /// 当前档位是否处于型号驱动的实时形态（型号驱动，ADR 0018）：档位
  /// 元数据带实时后缀规则（千问档 `-realtime`）且型号草稿 trim+小写后
  /// 以该后缀结尾，与网关侧 Realtime 会话的档位判定同口径（型号驱动
  /// 优先于地址判定；其余档无实时形态规则，照常消费高级参数）。该形
  /// 态网关不吃 extraParams（写了不报错也不生效），设置页据此禁用高级
  /// 参数输入并就地提示，不再静默吞掉用户填写的内容。
  bool get isQwenRealtimeTier {
    final suffix = tier.realtimeModelSuffix;
    return suffix != null &&
        modelController.text.trim().toLowerCase().endsWith(suffix);
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
  /// 直接返回，用户的选择与草稿不被重置）；未配置时按当前档位回填元
  /// 数据带的缺省地址、模型与缺省音色。Key 永不回显——只在未获焦时清
  /// 掉旧草稿。
  void sync(TtsSettings? settings) {
    // 档位目录随快照更新（票 08）：新设置对象第一次进来就换上它下发的
    // 行集；同一对象重复同步不重复换，用户的选择与草稿不被重置。
    if (settings != null && !identical(settings, _syncedSettings)) {
      _tierCatalog = settings.tierCatalog;
    }
    if (settings == null || identical(settings, _syncedSettings)) {
      return;
    }
    _syncedSettings = settings;
    _providerWireName = settings.providerWireName;
    final presets = ttsVoicePresetsFor(provider);
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
      // 传输方式随快照回显（只对带传输选项的档有意义，其余档恒为缺省值）。
      _transport = settings.transport;
      // 旋钮随快照回显；非旋钮档这些值恒为空，同步即清草稿。
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
      final defaults = protocolDefaults;
      syncFocusProtectedField(
        baseUrlController,
        baseUrlFocusNode,
        defaults.url,
      );
      syncFocusProtectedField(modelController, modelFocusNode, defaults.model);
      syncFocusProtectedField(
        voiceController,
        voiceFocusNode,
        _defaultVoiceFor(tier),
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

  /// 切换服务类型：落元数据带的缺省地址与模型，并选该档的缺省音色
  /// （预设目录首档，自由输入档给官方示例音色 ID）。没有语速参数的档：
  /// 切过去就丢掉可能从上个档带过来的语速草稿，不存一个调了不动的值。
  /// 旋钮只对旋钮档有意义：切走时清掉草稿。传输方式切档即回落缺省
  /// HTTP 分块（与 Host 落盘口径一致，避免选了一个不消费的值）。
  void selectProvider(String wireName) {
    if (wireName == _providerWireName) {
      return;
    }
    _providerWireName = wireName;
    _customVoice = false;
    _transport = TtsTransport.httpChunk;
    final next = tier;
    if (!next.customKnobs) {
      _responseShape = TtsResponseShape.rawBytes;
      authHeaderController.clear();
      responseFieldController.clear();
      extraParamsController.clear();
    }
    final defaults = protocolDefaults;
    baseUrlController.text = defaults.url;
    modelController.text = defaults.model;
    voiceController.text = _defaultVoiceFor(next);
    if (!next.speedSlider) {
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
  /// 由区块决定。旋钮档另带鉴权头、响应形态与字段名旋钮（按元数据能
  /// 力门控，票 08）；鉴权头的脏字符与结构校验在 Host 保存时人话驳回
  /// （与地址、模型同律，单一校验源）。
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
    if (tier.customKnobs) {
      final header = authHeaderController.text.trim();
      final field = responseFieldController.text.trim();
      authHeader = header.isEmpty ? null : header;
      responseField = field.isEmpty ? null : field;
    }
    return TtsSettingsDraft(
      provider: provider,
      // 未知档位（不在 TtsServiceKind 里）上送原始 wire 名：档位身份
      // 不因界面枚举封闭而丢失（票 08）。
      providerWireName:
          TtsServiceKind.maybeFromWireName(_providerWireName) == null
          ? _providerWireName
          : null,
      baseUrl: baseUrlController.text.trim(),
      model: modelController.text.trim(),
      apiKey: key.isEmpty ? null : key,
      voice: voice.isEmpty ? null : voice,
      speed: _speed,
      extraParams: extraParams,
      authHeader: authHeader,
      responseShape: tier.customKnobs ? _responseShape : null,
      responseField: responseField,
      // 传输方式只随带传输选项的档上送：其余档 Host 归一为缺省 HTTP 分块。
      transport: tier.transports.isNotEmpty ? _transport : null,
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
  /// 路径。目标档不在下发与降级行集里时返回 null（对话框不弹、表单不
  /// 动，与建议解析的保守兜底同律）。计划规则：
  /// - 新版语音通道条目（票 07：defaultEndpoint 与 addressTemplate 同时
  ///   出现）：官方 WS 推理地址可代填，同档与跨档都把地址填成它——3.x
  ///   型号在现行地址上调不通（probe 实测），地址必须跟着换；maas 模板
  ///   只是卡片上的备选信息，不进草稿。
  /// - 跨档（其余建议）：切档、按处置填地址（可代填缺省端点直接填），
  ///   填型号，并清掉 Key 草稿——沿用「切换服务不沿用旧 Key」既有机制
  ///   （保存时已存 Key 也按凭据作用域清空，重填后生效）。
  /// - 同档（其余建议）：只改型号。地址与 Key 一律不动。
  VoiceTierRefillPlan? planSuggestionApply(VoiceTierSuggestionData suggestion) {
    if (_tierCatalog.knownTier(suggestion.targetProvider) == null) {
      return null;
    }
    final crossTier = _providerWireName != suggestion.targetProvider;
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
  /// 回填同源，地址行写的就是将要落进地址栏的内容。档位改名查元数据
  /// 目录（票 08）：下发的行集优先，旧版宿主回落降级目录。
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
        '服务类型：${_form.tier.label} → ${_form.tierLabelOf(plan.providerWireName)}',
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
        final current = _form.tier;
        final defaults = _form.protocolDefaults;
        return SettingsSectionPanel(
          sectionId: SettingsSectionId.tts,
          title: '语音朗读',
          children: [
            Text(
              current.description,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.55,
              ),
            ),
            const SizedBox(height: 16),
            SettingsControlledDropdown(
              dropdownKey: const Key('tts-provider'),
              label: '服务类型',
              value: _form.dropdownValue,
              // 档位目录随元数据下推（票 08）：下拉选项按宿主行集渲染，
              // 对话框档位改名与建议回填的档位识别同源。
              items: [
                for (final choice in _form.tierChoices)
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
              // 实时形态判定跟着型号草稿逐键翻转（isQwenRealtimeTier 读
              // 型号文本）：键入经 onChanged 重建界面，实时形态下高级参
              // 数的禁用与提示即时跟手。只重建，不改动草稿值。
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: current.modelLabel,
                hintText: defaults.modelHint,
                // 型号支持范围说明（元数据带，千问档非空，票 08）：型号
                // 取归口缺省档位，用户只看得到缺省型号时也知道支持范围。
                helperText: current.modelHelperText,
                border: settingsOutlineBorder(color: QiyuColors.line),
                enabledBorder: settingsOutlineBorder(color: QiyuColors.line),
                focusedBorder: settingsOutlineBorder(
                  color: QiyuColors.composerFocusLine,
                ),
              ),
            ),
            const SizedBox(height: 16),
            // 传输方式（票三）：只对带传输选项的档露出（豆包档，元数据
            // 声明选项与说明）；千问档按型号驱动（见模型名提示），自定义
            // 档不动。
            if (current.transports.isNotEmpty) ...[
              SettingsControlledDropdown(
                dropdownKey: const Key('tts-transport'),
                label: '传输方式',
                value: _form.transport.wireName,
                items: [
                  for (final option in current.transports)
                    DropdownMenuItem(
                      value: option.wireName,
                      child: Text(option.label),
                    ),
                ],
                helperText: current.transportHelperText,
                onChanged: (wireName) =>
                    setState(() => _form.selectTransport(wireName)),
              ),
              const SizedBox(height: 16),
            ],
            // 旋钮档（自定义档）：鉴权头、响应形态与字段名，只在元数据
            // 声明旋钮能力的档露出。
            if (current.customKnobs) ...[
              TextField(
                key: const Key('tts-auth-header'),
                controller: _form.authHeaderController,
                focusNode: _form.authHeaderFocusNode,
                decoration: InputDecoration(
                  labelText: '鉴权头',
                  hintText: current.authHeaderHint,
                  helperText: current.authHeaderHelperText,
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
                items: [
                  for (final option in current.responseShapeOptions)
                    DropdownMenuItem(
                      value: option.wireName,
                      child: Text(option.label),
                    ),
                ],
                // 流式/整段分工说明随元数据带（F3 第一期）：裸音频字节
                // （且未覆盖成压缩格式）走 HTTP 分块流式；逐行 JSON 与
                // JSON 字段拿不到音频块，按 E1 每句一整块做句子级整段
                // 朗读（现有配置全部保留，不淘汰在用型号）。
                helperText: current.responseShapeHelperText,
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
                  hintText: current.responseFieldHint,
                  helperText: current.responseFieldHelperText,
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
                // 无音色位的档（元数据声明）：音色（厂商各叫各的）走高级
                // 参数传，界面不出现调了不动的旋钮。
                if (current.voiceMode == VoiceTierVoiceMode.none) {
                  return const SizedBox.shrink();
                }
                // 自由输入档没有预设音色目录：音色直给「音色 ID」输入框，
                // 任何音色 ID 都能填。
                if (current.voiceMode == VoiceTierVoiceMode.freeInput) {
                  return TextField(
                    key: const Key('tts-voice'),
                    controller: _form.voiceController,
                    focusNode: _form.voiceFocusNode,
                    decoration: InputDecoration(
                      labelText: '音色 ID',
                      hintText: current.voiceHint,
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
                final voicePresets = ttsVoicePresetsFor(_form.provider);
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
                          hintText: current.voiceHint,
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
            // 没有语速参数的档（元数据声明）：不显示语速滑条（厂商自有
            // 语速参数走高级参数传），界面不出现调了不动的旋钮。
            if (current.speedSlider) ...[
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
            // 高级参数面板按元数据能力露出（票 08）：随船四档恒有（与改
            // 前渲染一字不差），未知档位按元数据如实呈现，界面不出现填了
            // 不生效的旋钮。
            if (current.advancedParams)
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
                        if (current.extraParamsExample case final example?)
                          Text(
                            example,
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
                          // 实时形态不吃自定义高级参数（网关侧该形态写了
                          // 不报错也不生效）：就地禁用并如实提示，不再静默
                          // 吞掉填写内容。禁用只挡编辑，已填草稿原样保留；
                          // 切回普通型号或其他档即恢复。
                          enabled: !_form.isQwenRealtimeTier,
                          decoration: InputDecoration(
                            labelText: '自定义扩展参数 (JSON)',
                            hintText:
                                '{\n  "audio_params": {\n    "sample_rate": 16000\n  }\n}',
                            helperText: _form.isQwenRealtimeTier
                                ? current.realtimeExtraParamsHint
                                : null,
                            contentPadding: const EdgeInsets.all(16),
                            border: settingsOutlineBorder(
                              color: QiyuColors.line,
                            ),
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
                  // 建议落在转写域、或目标档不在下发与降级行集里时回填
                  // 不了：只给指路文案（回填计划算不出来即不亮按钮）。
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
