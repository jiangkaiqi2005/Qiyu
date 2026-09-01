import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../theme/qiyu_icons.dart';
import '../../theme/qiyu_tokens.dart';
import '../shell/qiyu_widgets.dart';
import 'settings_section_shell.dart';
import 'web_search_settings_client.dart';
import 'web_search_settings_view_model.dart';

/// 联网搜索设置领域：AnySearch API Key 的配置与保存。
///
/// 领域的深模块边界在这里收口——控制器与焦点管理、设置同步、Key 草稿
/// 校验（去空白、空白等价于不换 Key）与保存编排都落在
/// [WebSearchSettingsForm]；[WebSearchSettingsSection] 只负责把这些状态
/// 画出来。新增或修改本领域的一条校验或一段保存编排，只动本文件。
/// 异步编排（网关调用、加载与错误态）仍归 [WebSearchSettingsViewModel]。

/// 联网搜索领域的表单控制器：Key 输入框的控制器与焦点、已保存设置
/// 的同步、草稿读取与保存编排。
///
/// 本类不是 widget，也不持有任何 UI 呈现。
final class WebSearchSettingsForm {
  WebSearchSettingsForm();

  final apiKeyController = TextEditingController();

  final apiKeyFocusNode = FocusNode();

  WebSearchSettings? _syncedSettings;
  bool _disposed = false;

  /// 页面卸载时释放控制器与焦点节点。
  void dispose() {
    _disposed = true;
    apiKeyController.dispose();
    apiKeyFocusNode.dispose();
  }

  /// 已保存设置同步进表单：只处理新出现的设置对象（同一对象重复同步
  /// 直接返回，输入中的草稿不被重置）。Key 永不回显——只在未获焦时
  /// 清掉旧草稿，不把残留 Key 带进下一轮。
  void sync(WebSearchSettings? settings) {
    if (settings == null || identical(settings, _syncedSettings)) {
      return;
    }
    _syncedSettings = settings;
    if (!apiKeyFocusNode.hasFocus && apiKeyController.text.isNotEmpty) {
      apiKeyController.clear();
    }
  }

  /// 读草稿：Key 去除首尾空白，空白等价于「不换 Key」（存 null）。
  /// 本领域没有必填校验，草稿永远合法，返回值不为空。
  WebSearchSettingsDraft readDraft() {
    final key = apiKeyController.text.trim();
    return WebSearchSettingsDraft(apiKey: key.isEmpty ? null : key);
  }

  /// 一次保存的领域编排：读草稿 → 交视图模型 → 无论成败都清掉 Key
  /// 草稿，不让明文留在输入框（失败时页面显示人话错误，Key 不回填）。
  /// 返回是否真的保存成功。
  Future<bool> save(WebSearchSettingsViewModel viewModel) async {
    final saved = await viewModel.save(readDraft());
    if (!_disposed) {
      apiKeyController.clear();
    }
    return saved;
  }
}

/// 联网搜索设置区块。
class WebSearchSettingsSection extends StatefulWidget {
  const WebSearchSettingsSection({super.key});

  @override
  State<WebSearchSettingsSection> createState() =>
      _WebSearchSettingsSectionState();
}

class _WebSearchSettingsSectionState extends State<WebSearchSettingsSection> {
  final _form = WebSearchSettingsForm();

  @override
  void dispose() {
    _form.dispose();
    super.dispose();
  }

  Future<void> _confirmForgetKey(WebSearchSettingsViewModel viewModel) async {
    final confirmed = await confirmSettingsForgetKey(
      context: context,
      keyPrefix: 'web-search-',
      title: '忘记 AnySearch API Key？',
      content:
          '忘记后本机不再保存这个 Key，联网搜索会立即停用，'
          '普通聊天仍可照常使用。',
    );
    if (confirmed) {
      await viewModel.forgetApiKey();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<WebSearchSettingsViewModel>(
      builder: (context, viewModel, child) {
        _form.sync(viewModel.settings);
        final theme = Theme.of(context);
        final keySet = viewModel.settings?.keySet ?? false;
        return SettingsSectionPanel(
          sectionId: SettingsSectionId.webSearch,
          title: '联网搜索',
          children: [
            Text(
              '需要当前时间、天气、新闻等变化中的事实时，栖语可以按需搜索。'
              'Key 只保存在本机 provider.json，页面不会取回明文。',
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.55,
              ),
            ),
            const SizedBox(height: 16),
            if (viewModel.loading)
              const Center(child: CircularProgressIndicator())
            else ...[
              Text(
                keySet ? 'AnySearch Key 已保存在本机' : '尚未保存 AnySearch Key',
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              TextField(
                key: const Key('web-search-api-key'),
                controller: _form.apiKeyController,
                focusNode: _form.apiKeyFocusNode,
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: 'ANYSEARCH_API_KEY',
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
                    key: const Key('forget-web-search-key'),
                    onPressed: viewModel.saving
                        ? null
                        : () => unawaited(_confirmForgetKey(viewModel)),
                    child: const Text('忘记 AnySearch Key'),
                  ),
                ),
              ],
              const SizedBox(height: 20),
              if (viewModel.errorMessage case final message?) ...[
                SettingsStatusMessage(message: message, succeeded: false),
                const SizedBox(height: 14),
              ],
              FilledButton.icon(
                key: const Key('save-web-search-settings'),
                onPressed: viewModel.saving
                    ? null
                    : () => unawaited(_form.save(viewModel)),
                icon: settingsBusyOr(viewModel.saving, QiyuIcons.lock),
                label: const Text('保存到本机'),
              ),
            ],
          ],
        );
      },
    );
  }
}
