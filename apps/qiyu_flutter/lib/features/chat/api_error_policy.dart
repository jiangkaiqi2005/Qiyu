import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';

// 本文件是聊天页异常处理的纯 Dart 策略表：分类、判定与会话级频控全在
// 这里，不引入任何 Flutter 依赖，可逐条枚举测试；页面只负责执行判定
// （setState、弹窗、导航与焦点返还）。

/// 接口与语音服务异常类型：语义分流与文案定义（Spec §2）。
enum ApiErrorCategory {
  /// 429 请求过于频繁 / 限流
  rateLimited(
    title: '服务请求受限',
    message: '模型服务返回请求过于频繁（429）。本次已为您切换为本地基础模式回复，建议稍后再试或检查服务商用量额度。',
  ),

  /// 401 / 403 鉴权未通过
  authentication(
    title: 'API Key 鉴权失败',
    message: '服务商未通过验证（401/403），通常是 API Key 填写错误、已失效或未开通权限。本次已为您切换为本地基础模式回复。',
  ),

  /// 404 模型未找到
  modelNotFound(
    title: '模型名称不存在',
    message: '服务商未找到当前配置的模型（404）。请检查模型名称拼写，或前往设置确认服务商是否支持该模型。',
  ),

  /// 其他 4xx 客户端异常
  otherClientError(
    title: '模型服务异常',
    message: '服务商返回客户端请求异常。本次已为您切换为本地基础模式回复，建议前往设置检查模型配置。',
  ),

  /// 语音输入（STT 转写）受限
  sttError(
    title: '语音服务受限',
    message: '语音服务请求受限或配置异常。请检查语音服务配置或服务商用量额度。',
  ),

  /// 语音朗读（TTS 合成）受限
  ttsError(
    title: '语音朗读受限',
    message: '语音朗读合成请求受限或配置异常。请检查语音服务配置或服务商用量额度。',
  );

  const ApiErrorCategory({
    required this.title,
    required this.message,
  });

  final String title;
  final String message;

  /// 输入框上方状态行频控去重时的轻量提示文案。
  String get noticeText => switch (this) {
    ApiErrorCategory.rateLimited => '⚠️ 接口频繁受限 (429)，当前保持本地基础回复',
    ApiErrorCategory.authentication => '⚠️ API Key 鉴权失败 (401/403)，当前保持本地基础回复',
    ApiErrorCategory.modelNotFound => '⚠️ 模型名称不存在 (404)，当前保持本地基础回复',
    ApiErrorCategory.otherClientError => '⚠️ 模型服务异常，当前保持本地基础回复',
    ApiErrorCategory.sttError => '⚠️ 语音服务频繁受限，当前保持静音',
    ApiErrorCategory.ttsError => '⚠️ 语音朗读频繁受限，当前保持静音',
  };
}

/// 状态条轻提示的载荷：文案与是否附「去设置检查」链接。
final class ApiErrorNotice {
  const ApiErrorNotice({
    required this.message,
    this.showSettingsLink = true,
  });

  final String message;
  final bool showSettingsLink;
}

/// 策略表对一轮异常给出的判定：页面按变体执行，不做二次判断。
sealed class ApiErrorTurnDecision {
  const ApiErrorTurnDecision();
}

/// 清掉在显的轻提示（该轮无异常、或异常属于设计内降级与无分类兜底）。
final class ClearApiErrorNotice extends ApiErrorTurnDecision {
  const ClearApiErrorNotice();
}

/// 就地轻提示（网络瞬态、服务不可用等）：绝不弹模态配置修复窗。
final class ShowApiErrorNotice extends ApiErrorTurnDecision {
  const ShowApiErrorNotice(this.notice);

  final ApiErrorNotice notice;
}

/// 走会话级频控的模态弹窗分发：同会话同类仅首次弹出，其后降级轻提示。
final class DispatchApiErrorDialog extends ApiErrorTurnDecision {
  const DispatchApiErrorDialog({required this.category, required this.delay});

  final ApiErrorCategory category;

  /// 流式落定后约 300ms 缓冲（与原型一致，留出视觉落定呼吸时间，Spec §2）；
  /// 语音链路即时触发，不缓冲。
  final bool delay;
}

/// 异常分类与会话级弹窗频控策略表：判定无副作用之外的状态只有每会话一份
/// 的已弹窗记录，`resetSession` 随会话切换调用。
final class ApiErrorPolicy {
  final Set<ApiErrorCategory> _alertedCategories = {};

  /// 会话切换（含新开与恢复）时复位频控：新会话内同类错误重新走首次弹窗。
  void resetSession() {
    _alertedCategories.clear();
  }

  /// 轮末异常判定：composer 的轮次收尾回调按 VM 给出的兜底原因与服务错误
  /// 元数据查表。分支顺序即优先级——设计内降级与网络瞬态抢在服务错误
  /// 元数据之前。
  ApiErrorTurnDecision decideTurn({
    required FallbackReason? reason,
    required ServiceErrorCategory? serviceError,
  }) {
    if (reason == null) {
      return const ClearApiErrorNotice();
    }

    // 严格排除设计内降级：安全拦截、未配置模型与输出卫生拒绝绝对不弹窗
    // （人格与话术约束在提示词层，输出侧不再正则判决——ADR 0017）
    if (reason == FallbackReason.safety ||
        reason == FallbackReason.noLlmConfig ||
        reason == FallbackReason.invalidModelResponse ||
        reason == FallbackReason.emptyModelReply) {
      return const ClearApiErrorNotice();
    }

    // 网络瞬态（超时/网络/DNS/TLS）：维持就地轻提示，绝不弹出模态配置修复窗
    if (reason == FallbackReason.modelTimeout) {
      return const ShowApiErrorNotice(
        ApiErrorNotice(
          message: '⚠️ 网络连接超时，当前保持本地基础回复',
          showSettingsLink: false,
        ),
      );
    }
    if (reason == FallbackReason.modelNetwork ||
        reason == FallbackReason.modelDns ||
        reason == FallbackReason.modelTls ||
        serviceError == ServiceErrorCategory.network) {
      return const ShowApiErrorNotice(
        ApiErrorNotice(
          message: '⚠️ 网络连接异常，当前保持本地基础回复',
          showSettingsLink: false,
        ),
      );
    }

    // 截断与解析失败（票 06）：模型回复没说完就结束，就地轻提示给出
    // 明确失败信号，与网络瞬态同构，绝不弹模态窗。
    if (reason == FallbackReason.modelContentParsing) {
      return const ShowApiErrorNotice(
        ApiErrorNotice(
          message: '⚠️ 模型回复不完整，当前保持本地基础回复',
          showSettingsLink: false,
        ),
      );
    }

    if (serviceError == ServiceErrorCategory.server) {
      return const ShowApiErrorNotice(
        ApiErrorNotice(
          message: '⚠️ 模型服务暂时不可用，当前保持本地基础回复',
          showSettingsLink: false,
        ),
      );
    }

    final category = _categorizeFallbackReason(reason, serviceError);
    if (category == null) {
      return const ClearApiErrorNotice();
    }

    // 流式落定后约 300ms 缓冲
    return decideCategory(category, delay: true);
  }

  /// 会话级频控去重：同会话内仅第 1 次弹窗；第 2 次及后续展示状态条轻提示。
  /// 文本聊天与语音链路共用同一份记录（跨通道共享频控）。
  ApiErrorTurnDecision decideCategory(
    ApiErrorCategory category, {
    bool delay = false,
  }) {
    if (_alertedCategories.contains(category)) {
      return ShowApiErrorNotice(
        ApiErrorNotice(
          message: category.noticeText,
          showSettingsLink: true,
        ),
      );
    }
    _alertedCategories.add(category);
    return DispatchApiErrorDialog(category: category, delay: delay);
  }

  ApiErrorCategory? _categorizeFallbackReason(
    FallbackReason reason,
    ServiceErrorCategory? serviceError,
  ) {
    if (serviceError != null) {
      return switch (serviceError) {
        ServiceErrorCategory.authentication => ApiErrorCategory.authentication,
        ServiceErrorCategory.modelNotFound => ApiErrorCategory.modelNotFound,
        ServiceErrorCategory.rateLimited => ApiErrorCategory.rateLimited,
        ServiceErrorCategory.client => ApiErrorCategory.otherClientError,
        ServiceErrorCategory.server || ServiceErrorCategory.network => null,
      };
    }
    // 老 Host 没有分类元数据时，仅使用含义明确的既有原因。
    return switch (reason) {
      FallbackReason.modelRateLimited => ApiErrorCategory.rateLimited,
      FallbackReason.modelAuthentication => ApiErrorCategory.authentication,
      FallbackReason.modelNotFound => ApiErrorCategory.modelNotFound,
      _ => null,
    };
  }
}
