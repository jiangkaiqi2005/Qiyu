import 'package:flutter/material.dart';

import '../navigation.dart';

/// 隐私说明页（ticket 23）：数据只在本机、何时调用用户选择的模型
/// 服务、哪些敏感信息永不提升为记忆、日志与诊断统一脱敏。文案与
/// Windows Host 主链路实际行为一一对应。
class PrivacyView extends StatelessWidget {
  const PrivacyView({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(24, 18, 24, 48),
              children: [
                Row(
                  children: [
                    IconButton(
                      key: const Key('privacy-back'),
                      onPressed: () => backToPrevious(context),
                      tooltip: '返回设置',
                      icon: const Icon(Icons.arrow_back),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '隐私与边界',
                      style: theme.textTheme.headlineSmall,
                    ),
                  ],
                ),
                const SizedBox(height: 30),
                Text(
                  '你的夜晚只属于你',
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                    letterSpacing: -0.8,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  '栖语没有账号，没有云端记忆。这里说清楚数据在哪里、'
                  '什么时候会用到你选择的模型服务，以及哪些内容永远不会被记住。',
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.55,
                  ),
                ),
                const SizedBox(height: 28),
                _PrivacySection(
                  tag: '本机',
                  title: '数据只保存在你的电脑上',
                  body: '聊天记录、整理后的每日记录、长期印象、画像与关系、'
                      '记忆控制，全部是保存在本机「栖语数据目录」里的 '
                      'Markdown 文件，用任何文本编辑器都能直接打开查看。'
                      'API Key 由 Windows 凭据管理器保管，不落进记忆文件。'
                      '在设置里清除本机数据前会自动保留一份备份快照，'
                      '随时可以在「备份与恢复」里找回；'
                      '若你直接删除整个数据目录，则无法找回。',
                ),
                _PrivacySection(
                  tag: '模型',
                  title: '何时调用你选择的模型服务',
                  body: '只有你在设置里配置了模型服务时，栖语才会联网，且只发往你填写的地址：'
                      '你发来消息需要模型回应时、晚安后的当日整理、'
                      '间隔至少七天的 Dream 深度整理、对话中的记忆查找，'
                      '以及你主动发起的连接测试。'
                      '没有配置模型服务时，一切都在本机规则里完成，不产生任何网络请求。'
                      '涉及自伤等危机的输入永远只由本机安全规则处理，绝不发送给模型。',
                ),
                _PrivacySection(
                  tag: '记忆',
                  title: '这些内容永远不会被提升为记忆',
                  body: 'API Key、密码、口令、Cookie、验证码、身份证号、'
                      '银行卡号、私钥等敏感原文，在写入任何记忆文件之前一律过滤。'
                      '涉及私密内容的记忆在记忆中心默认打码展示，'
                      '单次揭示需要明确确认，页面不缓存原文。',
                ),
                _PrivacySection(
                  tag: '诊断',
                  title: '日志与诊断统一脱敏',
                  body: '本机日志和开发者诊断只记录请求来源、结果与错误类别，'
                      '不记录任何对话正文；API Key、授权头、启动凭据和'
                      '默认遮罩的敏感原文绝不会出现在任何导出里。'
                      '开发者诊断默认关闭，只读，不触碰任何数据。',
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton(
                    key: const Key('privacy-back-to-settings'),
                    onPressed: () => backToPrevious(context),
                    child: const Text('返回设置'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PrivacySection extends StatelessWidget {
  const _PrivacySection({
    required this.tag,
    required this.title,
    required this.body,
  });

  final String tag;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  tag,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(title, style: theme.textTheme.titleMedium),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            body,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.6,
            ),
          ),
        ],
      ),
    );
  }
}
