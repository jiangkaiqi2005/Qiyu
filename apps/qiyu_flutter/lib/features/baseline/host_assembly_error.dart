import 'dart:async';

import 'package:flutter/material.dart';

import '../../theme/qiyu_theme.dart';
import '../../theme/qiyu_tokens.dart';
import 'host_bootstrap.dart';

/// 装配失败错误页（票 07）：安卓壳的启动装配在 `main()` 里先起进程内
/// 本机 Host 再跑 UI，装配一旦失败（目录解析、宪法资产、Host 启动、
/// 启动凭据）就没有任何可用的宿主与存储——此刻还活着的只有 Flutter
/// 自己的绘制。本文件因此是一张**不依赖宿主与存储**的极简错误页：人话
/// 原因加重试按钮；重试重新执行装配，成功经 [HostAssemblyErrorApp.launch]
/// 放行回原首帧链路（生产接线是 `runApp(QiyuApp(...))`）。
///
/// 文案纪律：只讲用户能做的事，不透出异常类型、堆栈与本机路径；连续
/// 重试失败后如实告知卸载重装的代价（恢复应用，但清除本机数据），把
/// 「毫不知情地丢光记忆」变成「知情后自己决定」。

/// 连续装配失败达到此次数后，错误页展示卸载重装提示。计数含首次装配
/// 失败（错误页本就只在失败后出现）：首次装配加两次重试，共三次。前
/// 两次先让「再试一次」独自承担——失败可能是暂时的，清除数据的代价
/// 不该早早压到用户头上。
const int _persistentFailureThreshold = 3;

/// 错误页的宿主壳：持有重试状态（等待态、连续失败计数），把装配缝
/// [assemble] 与放行缝 [launch] 留给调用方注入——生产由 `main()` 传
/// `bootstrapHost` 与 `runApp(QiyuApp(...))`，测试传桩。自身不触碰
/// 宿主与存储：构建的只有主题与静态文本。
class HostAssemblyErrorApp extends StatefulWidget {
  const HostAssemblyErrorApp({
    super.key,
    required this.assemble,
    required this.launch,
  });

  /// 重新执行装配：失败时抛错（错误页捕获并累计失败次数），成功时
  /// 返回装配结果交给 [launch]。
  final Future<HostBinding?> Function() assemble;

  /// 装配成功后的放行：生产实现里它 `runApp` 换根，本页随之退场。
  final void Function(HostBinding? binding) launch;

  @override
  State<HostAssemblyErrorApp> createState() => _HostAssemblyErrorAppState();
}

class _HostAssemblyErrorAppState extends State<HostAssemblyErrorApp> {
  /// 已发生的连续装配失败次数：错误页只在首次装配失败后出现，从 1 起算。
  int _failedAttempts = 1;

  bool _retrying = false;

  Future<void> _handleRetry() async {
    if (_retrying) {
      return;
    }
    setState(() => _retrying = true);
    final HostBinding? binding;
    try {
      binding = await widget.assemble();
    } catch (error) {
      // 装配继续失败：留在错误页，累计次数（达到阈值后展示卸载重装
      // 提示）。成功路径不在此复位——放行后本页即被换根退场。
      if (!mounted) {
        return;
      }
      setState(() {
        _retrying = false;
        _failedAttempts += 1;
      });
      return;
    }
    widget.launch(binding);
    // 放行若未立即换根（测试替身），把等待态收回去；生产里换根在即，
    // 这一次重置只是让退场前的最后一帧不残留禁用按钮。
    if (!mounted) {
      return;
    }
    setState(() => _retrying = false);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '栖语',
      debugShowCheckedModeBanner: false,
      // 与主应用同一份主题来源：错误页不另造视觉值。
      theme: qiyuDarkTheme(),
      home: HostAssemblyErrorPage(
        onRetry: _handleRetry,
        retryInProgress: _retrying,
        persistentFailure: _failedAttempts >= _persistentFailureThreshold,
      ),
    );
  }
}

/// 极简错误页本体：标题、人话原因、重试按钮；持续失败后追加卸载重装
/// 提示。无网络、无存储、无平台通道——能渲染就一定渲染得出来。
class HostAssemblyErrorPage extends StatelessWidget {
  const HostAssemblyErrorPage({
    super.key,
    required this.onRetry,
    this.retryInProgress = false,
    this.persistentFailure = false,
  });

  final Future<void> Function() onRetry;

  /// 重试进行中：按钮转等待态并禁用，防止并发重复装配。
  final bool retryInProgress;

  /// 连续装配失败达到阈值：展示卸载重装提示。
  final bool persistentFailure;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '栖语这次没能启动',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: QiyuSpacing.sm),
                  Text(
                    '可能是应用内部有一部分还没准备好。再试一次通常就能进去。',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: QiyuSpacing.lg),
                  FilledButton(
                    onPressed:
                        retryInProgress ? null : () => unawaited(onRetry()),
                    child: retryInProgress
                        ? const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              ),
                              SizedBox(width: QiyuSpacing.sm),
                              Text('正在重新启动…'),
                            ],
                          )
                        : const Text('再试一次'),
                  ),
                  if (persistentFailure) ...[
                    const SizedBox(height: QiyuSpacing.lg),
                    Text(
                      '反复重试仍然没有成功。卸载栖语后重新安装可以恢复应用，'
                      '但会清除本机保存的全部数据（对话、记忆与设置）。',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
