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
  final extraParamsController = TextEditingController();

  final baseUrlFocusNode = FocusNode();
  final modelFocusNode = FocusNode();
  final apiKeyFocusNode = FocusNode();
  final voiceFocusNode = FocusNode();
  final extraParamsFocusNode = FocusNode();

  TtsServiceKind _provider = TtsServiceKind.openAiCompatible;
  bool _customVoice = false;
  double? _speed;
  TtsSettings? _syncedSettings;
  bool _disposed = false;

  /// 当前选中的服务类型。
  TtsServiceKind get provider => _provider;

  /// 当前语速档：null＝默认。
  double? get speed => _speed;

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

  /// 是否亮出自定义音色输入框：选了「输入其他音色 ID」，或已存音色
  /// 不在当前协议的预设目录里。
  bool get showCustomVoiceField {
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
    extraParamsController.dispose();
    baseUrlFocusNode.dispose();
    modelFocusNode.dispose();
    apiKeyFocusNode.dispose();
    voiceFocusNode.dispose();
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
      final defaultVoice = presets.isNotEmpty ? presets.first.id : '';
      syncFocusProtectedField(voiceController, voiceFocusNode, defaultVoice);
      _customVoice = false;
      _speed = null;
      syncFocusProtectedField(extraParamsController, extraParamsFocusNode, '');
    }
    if (!apiKeyFocusNode.hasFocus && apiKeyController.text.isNotEmpty) {
      apiKeyController.clear();
    }
  }

  /// 切换服务类型：落该协议的缺省地址与模型，并选首个音色预设。
  void selectProvider(String wireName) {
    final next = wireName == 'volc_tts'
        ? TtsServiceKind.volcTts
        : TtsServiceKind.openAiCompatible;
    if (next == _provider) {
      return;
    }
    _provider = next;
    _customVoice = false;
    final presets = ttsVoicePresetsFor(next);
    final defaults = _ttsProtocolDefaults(next);
    baseUrlController.text = defaults.url;
    modelController.text = defaults.model;
    voiceController.text = presets.isNotEmpty ? presets.first.id : '';
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

  /// 读草稿：必填校验与 extraParams 的 JSON 对象校验都在领域内。草稿
  /// 不合法时经 [report] 给出人话并返回 null——呈现方式（SnackBar）
  /// 由区块决定。
  TtsSettingsDraft? readDraftOrReport(void Function(String message) report) {
    if (baseUrlController.text.trim().isEmpty ||
        modelController.text.trim().isEmpty) {
      report('请填写语音合成服务地址和模型名称。');
      return null;
    }
    final key = apiKeyController.text.trim();
    final voice = voiceController.text.trim();
    Map<String, Object?>? extraParams;
    final extraText = extraParamsController.text.trim();
    if (extraText.isNotEmpty) {
      try {
        final decoded = jsonDecode(extraText);
        if (decoded is! Map) {
          report('自定义高级参数必须是 JSON 对象。');
          return null;
        }
        extraParams = decoded.cast<String, Object?>();
      } on FormatException {
        report('自定义高级参数 JSON 格式不正确，请检查语法。');
        return null;
      }
    }
    return TtsSettingsDraft(
      provider: _provider,
      baseUrl: baseUrlController.text.trim(),
      model: modelController.text.trim(),
      apiKey: key.isEmpty ? null : key,
      voice: voice.isEmpty ? null : voice,
      speed: _speed,
      extraParams: extraParams,
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
}

/// 语音朗读设置区块。
class TtsSettingsSection extends StatefulWidget {
  const TtsSettingsSection({super.key});

  @override
  State<TtsSettingsSection> createState() => _TtsSettingsSectionState();
}

class _TtsSettingsSectionState extends State<TtsSettingsSection> {
  final _form = TtsSettingsForm();

  @override
  void dispose() {
    _form.dispose();
    super.dispose();
  }

  /// 领域校验结论的呈现：SnackBar 播报。
  void _reportInvalidDraft(String message) =>
      showSettingsSnackBar(context, message);

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
              provider == TtsServiceKind.volcTts
                  ? '把栖语写完的话读出来。豆包语音合成走火山方舟的 HTTP 接口，'
                        '模型名称填 Resource-Id；Key 只存本机 provider.json；'
                        '音频只存在内存，播完即丢。'
                  : '把栖语写完的话读出来的服务（OpenAI 兼容语音合成，如 tts-1）。'
                        '她先把每句完整写好、过了安全检查才开口读；音频只存在内存，'
                        '播完即丢，本机不留声音文件。',
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.55,
              ),
            ),
            const SizedBox(height: 16),
            SettingsControlledDropdown(
              dropdownKey: const Key('tts-provider'),
              label: '服务类型',
              value: provider == TtsServiceKind.volcTts
                  ? 'volc_tts'
                  : 'openai_compatible',
              items: const [
                DropdownMenuItem(
                  value: 'openai_compatible',
                  child: Text('OpenAI 兼容语音合成'),
                ),
                DropdownMenuItem(value: 'volc_tts', child: Text('豆包语音合成')),
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
                border: const OutlineInputBorder(),
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
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            Builder(
              builder: (context) {
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
                          border: const OutlineInputBorder(),
                        ),
                      ),
                    ],
                  ],
                );
              },
            ),
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
            const SizedBox(height: 8),
            Text(
              keySet ? 'API Key 已保存在本机 provider.json' : '尚未保存语音合成的 API Key',
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            TextField(
              key: const Key('tts-api-key'),
              controller: _form.apiKeyController,
              focusNode: _form.apiKeyFocusNode,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: 'API Key',
                hintText: keySet ? '留空即可继续使用已保存的 Key' : '保存后写入本机 provider.json',
                border: const OutlineInputBorder(),
              ),
            ),
            if (keySet) ...[
              const SizedBox(height: 8),
              QiyuFocusRingScope(
                borderRadius: QiyuRadii.circleBorder,
                child: TextButton(
                  key: const Key('forget-tts-key'),
                  onPressed: viewModel.saving
                      ? null
                      : () => unawaited(_confirmForgetKey(viewModel)),
                  child: const Text('忘记语音合成的 Key'),
                ),
              ),
            ],
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
                        provider == TtsServiceKind.volcTts
                            ? '配置豆包语音合成的深合并参数，例如：\n'
                                  '{\n'
                                  '  "audio_params": { "sample_rate": 16000 },\n'
                                  '  "additions": { "explicit_dialect": "sichuan" }\n'
                                  '}'
                            : '配置 OpenAI 兼容语音合成的顶层扩展参数，例如：\n'
                                  '{\n'
                                  '  "response_format": "mp3"\n'
                                  '}',
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
                        decoration: const InputDecoration(
                          labelText: '自定义扩展参数 (JSON)',
                          hintText:
                              '{\n  "audio_params": {\n    "sample_rate": 16000\n  }\n}',
                          border: OutlineInputBorder(),
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
              if (testResult case final result?)
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
            Wrap(
              spacing: QiyuSpacing.sm,
              runSpacing: 12,
              children: [
                FilledButton.icon(
                  key: const Key('save-tts-settings'),
                  onPressed: viewModel.saving
                      ? null
                      : () => unawaited(
                          _form.save(viewModel, report: _reportInvalidDraft),
                        ),
                  icon: settingsBusyOr(viewModel.saving, QiyuIcons.lock),
                  label: const Text('保存到本机'),
                ),
                OutlinedButton.icon(
                  key: const Key('test-tts-connection'),
                  onPressed: viewModel.testing
                      ? null
                      : () {
                          final draft = _form.readDraftOrReport(
                            _reportInvalidDraft,
                          );
                          if (draft != null) {
                            unawaited(viewModel.testConnection(draft));
                          }
                        },
                  icon: settingsBusyOr(viewModel.testing, QiyuIcons.bolt),
                  label: const Text('测试连接并试听'),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

/// 两套 TTS 协议各自的缺省地址、模型与输入提示档位。
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
};
