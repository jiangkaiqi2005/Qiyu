import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../theme/qiyu_icons.dart';
import '../../theme/qiyu_tokens.dart';
import '../shell/qiyu_widgets.dart';
import 'settings_section_shell.dart';
import 'stt_settings_client.dart';
import 'stt_settings_view_model.dart';

/// 语音输入（STT）设置领域：转写服务类型、地址、模型与 API Key。
///
/// 领域的深模块边界在这里收口——控制器与焦点管理、协议缺省值
/// （两套协议各自的地址与模型档位）、设置同步、协议切换时的地址
/// 兼容性回填、草稿校验与保存编排都落在 [SttSettingsForm]；
/// [SttSettingsSection] 只负责把这些状态画出来。新增或修改本领域的
/// 一条校验、一个缺省值或一段保存编排，只动本文件。异步编排
/// （网关调用、加载与错误态）仍归 [SttSettingsViewModel]。

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

  final baseUrlFocusNode = FocusNode();
  final modelFocusNode = FocusNode();
  final apiKeyFocusNode = FocusNode();

  SttServiceKind _provider = SttServiceKind.openaiCompatible;
  SttSettings? _syncedSettings;
  bool _disposed = false;

  /// 当前选中的服务类型。
  SttServiceKind get provider => _provider;

  /// 当前协议的缺省地址与模型（含输入提示用档位）。
  ({String url, String model, String urlHint, String modelHint})
  get protocolDefaults => _sttProtocolDefaults(_provider);

  /// 页面卸载时释放全部控制器与焦点节点。
  void dispose() {
    _disposed = true;
    baseUrlController.dispose();
    modelController.dispose();
    apiKeyController.dispose();
    baseUrlFocusNode.dispose();
    modelFocusNode.dispose();
    apiKeyFocusNode.dispose();
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
    } else {
      final defaults = _sttProtocolDefaults(_provider);
      syncFocusProtectedField(baseUrlController, baseUrlFocusNode, defaults.url);
      syncFocusProtectedField(modelController, modelFocusNode, defaults.model);
    }
    if (!apiKeyFocusNode.hasFocus && apiKeyController.text.isNotEmpty) {
      apiKeyController.clear();
    }
  }

  /// 切换服务类型：地址空白或 scheme 与新协议不兼容（https 不能给豆包，
  /// wss 不能给 OpenAI 兼容）时，换成新协议的缺省地址和模型。
  void selectProvider(String wireName) {
    final next = wireName == 'volc_seed_asr'
        ? SttServiceKind.volcSeedAsr
        : SttServiceKind.openaiCompatible;
    if (next == _provider) {
      return;
    }
    final previous = _provider;
    _provider = next;
    _applyProtocolDefaults(from: previous, to: next);
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

  /// 读草稿：必填校验在领域内。草稿不合法时经 [report] 给出人话并
  /// 返回 null——呈现方式（SnackBar）由区块决定。
  SttSettingsDraft? readDraftOrReport(
    void Function(String message) report,
  ) {
    if (baseUrlController.text.trim().isEmpty ||
        modelController.text.trim().isEmpty) {
      report('请填写语音服务地址和模型名称。');
      return null;
    }
    final key = apiKeyController.text.trim();
    return SttSettingsDraft(
      provider: _provider,
      baseUrl: baseUrlController.text.trim(),
      model: modelController.text.trim(),
      apiKey: key.isEmpty ? null : key,
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
}

/// 语音输入设置区块。
class SttSettingsSection extends StatefulWidget {
  const SttSettingsSection({super.key});

  @override
  State<SttSettingsSection> createState() => _SttSettingsSectionState();
}

class _SttSettingsSectionState extends State<SttSettingsSection> {
  final _form = SttSettingsForm();

  @override
  void dispose() {
    _form.dispose();
    super.dispose();
  }

  /// 领域校验结论的呈现：SnackBar 播报。
  void _reportInvalidDraft(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _confirmForgetKey(SttSettingsViewModel viewModel) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('stt-forget-key-dialog'),
        title: const Text('忘记语音服务的 API Key？'),
        content: const Text(
          '忘记后本机不再保存这个 Key，语音输入暂时不可用，直到你重新输入。'
          '语音服务的地址和模型不受影响。',
        ),
        actions: [
          QiyuFocusRingScope(
            borderRadius: QiyuRadii.circleBorder,
            child: TextButton(
              key: const Key('stt-forget-key-cancel'),
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('再想想'),
            ),
          ),
          FilledButton(
            key: const Key('stt-forget-key-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('忘记 Key'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await viewModel.forgetApiKey();
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
        return SettingsSectionPanel(
          sectionId: SettingsSectionId.stt,
          title: '语音输入',
          children: [
            Text(
              provider == SttServiceKind.volcSeedAsr
                  ? '把说的话转成文字。豆包走官方语音识别协议；'
                        'Key 只保存在本机 provider.json；录音只存在内存里，'
                        '转写完成即丢弃，不会进入会话与记忆。'
                  : '把说的话转成文字的服务（OpenAI 兼容转写，如 whisper 系列）。'
                        'Key 只保存在本机 provider.json；录音只存在内存里，'
                        '转写完成即丢弃，不会进入会话与记忆。',
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.55,
              ),
            ),
            const SizedBox(height: 16),
            SettingsControlledDropdown(
              dropdownKey: const Key('stt-provider'),
              label: '服务类型',
              value: provider == SttServiceKind.volcSeedAsr
                  ? 'volc_seed_asr'
                  : 'openai_compatible',
              items: const [
                DropdownMenuItem(
                  value: 'openai_compatible',
                  child: Text('OpenAI 兼容转写'),
                ),
                DropdownMenuItem(
                  value: 'volc_seed_asr',
                  child: Text('豆包流式语音识别'),
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
                border: const OutlineInputBorder(),
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
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              keySet
                  ? 'API Key 已保存在本机 provider.json'
                  : '尚未保存语音服务的 API Key',
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            TextField(
              key: const Key('stt-api-key'),
              controller: _form.apiKeyController,
              focusNode: _form.apiKeyFocusNode,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: 'API Key',
                hintText: keySet
                    ? '留空即可继续使用已保存的 Key'
                    : '保存后写入本机 provider.json',
                border: const OutlineInputBorder(),
              ),
            ),
            if (keySet) ...[
              const SizedBox(height: 8),
              QiyuFocusRingScope(
                borderRadius: QiyuRadii.circleBorder,
                child: TextButton(
                  key: const Key('forget-stt-key'),
                  onPressed: viewModel.saving
                      ? null
                      : () => unawaited(_confirmForgetKey(viewModel)),
                  child: const Text('忘记语音服务的 Key'),
                ),
              ),
            ],
            const SizedBox(height: 20),
            if (viewModel.errorMessage case final message?)
              SettingsStatusMessage(message: message, succeeded: false),
            if (viewModel.testResult case final result?)
              SettingsStatusMessage(
                message: result.message,
                succeeded: result.succeeded,
              ),
            if (viewModel.errorMessage != null || viewModel.testResult != null)
              const SizedBox(height: 14),
            Wrap(
              spacing: QiyuSpacing.sm,
              runSpacing: 12,
              children: [
                FilledButton.icon(
                  key: const Key('save-stt-settings'),
                  onPressed: viewModel.saving
                      ? null
                      : () =>
                            unawaited(_form.save(viewModel, report: _reportInvalidDraft)),
                  icon: settingsBusyOr(viewModel.saving, QiyuIcons.lock),
                  label: const Text('保存到本机'),
                ),
                OutlinedButton.icon(
                  key: const Key('test-stt-connection'),
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
                  label: const Text('测试连接'),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

/// 两套 STT 协议各自的缺省地址、模型与输入提示档位。
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
};
