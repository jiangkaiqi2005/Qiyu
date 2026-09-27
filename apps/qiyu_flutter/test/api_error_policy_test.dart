import 'package:flutter_test/flutter_test.dart';
import 'package:qiyu_behavior_core/qiyu_behavior_core.dart';
import 'package:qiyu_flutter/features/chat/api_error_policy.dart';

void main() {
  group('ApiErrorPolicy.decideTurn 逐条枚举（纯 Dart 策略表）', () {
    late ApiErrorPolicy policy;

    setUp(() => policy = ApiErrorPolicy());

    void expectClear(
      ApiErrorTurnDecision decision, {
      String? because,
    }) =>
        expect(decision, isA<ClearApiErrorNotice>(), reason: because);

    void expectNotice(
      ApiErrorTurnDecision decision,
      String message, {
      String? because,
    }) {
      expect(decision, isA<ShowApiErrorNotice>(), reason: because);
      final show = decision as ShowApiErrorNotice;
      expect(show.notice.message, message, reason: because);
      // 就地轻提示一律不带「去设置检查」链接（模态窗才引导去设置）。
      expect(show.notice.showSettingsLink, isFalse, reason: because);
    }

    void expectDialog(
      ApiErrorTurnDecision decision,
      ApiErrorCategory category, {
      String? because,
    }) {
      expect(decision, isA<DispatchApiErrorDialog>(), reason: because);
      final dispatch = decision as DispatchApiErrorDialog;
      expect(dispatch.category, category, reason: because);
    }

    test('无兜底原因：清提示，即便服务错误元数据同时在场上', () {
      expectClear(policy.decideTurn(reason: null, serviceError: null));
      expectClear(
        policy.decideTurn(reason: null, serviceError: ServiceErrorCategory.network),
        because: 'reason 为空短路在前，serviceError 不参与判定',
      );
    });

    test('设计内降级四类：绝不弹窗也绝不轻提示', () {
      for (final reason in [
        FallbackReason.safety,
        FallbackReason.noLlmConfig,
        FallbackReason.invalidModelResponse,
        FallbackReason.emptyModelReply,
      ]) {
        expectClear(
          policy.decideTurn(reason: reason, serviceError: null),
          because: '${reason.name} 属设计内降级',
        );
      }
    });

    test('全部 15 个 FallbackReason（无服务错误元数据）逐条命中既定条目', () {
      // 设计内降级（重申：与上一条目同一分支，锁全枚举覆盖）。
      expectClear(policy.decideTurn(reason: FallbackReason.safety, serviceError: null));
      expectClear(policy.decideTurn(reason: FallbackReason.noLlmConfig, serviceError: null));
      expectClear(
        policy.decideTurn(reason: FallbackReason.emptyModelReply, serviceError: null),
      );
      expectClear(
        policy.decideTurn(reason: FallbackReason.invalidModelResponse, serviceError: null),
      );

      // 网络瞬态：同一段文案、就地轻提示。
      expectNotice(
        policy.decideTurn(reason: FallbackReason.modelTimeout, serviceError: null),
        '⚠️ 网络连接超时，当前保持本地基础回复',
      );
      expectNotice(
        policy.decideTurn(reason: FallbackReason.modelNetwork, serviceError: null),
        '⚠️ 网络连接异常，当前保持本地基础回复',
      );
      expectNotice(
        policy.decideTurn(reason: FallbackReason.modelDns, serviceError: null),
        '⚠️ 网络连接异常，当前保持本地基础回复',
      );
      expectNotice(
        policy.decideTurn(reason: FallbackReason.modelTls, serviceError: null),
        '⚠️ 网络连接异常，当前保持本地基础回复',
      );

      // 截断与解析失败：就地轻提示。
      expectNotice(
        policy.decideTurn(reason: FallbackReason.modelContentParsing, serviceError: null),
        '⚠️ 模型回复不完整，当前保持本地基础回复',
      );

      // 直配弹窗：首次分发（delay 由轮末路径固定为 true）。
      expectDialog(
        policy.decideTurn(reason: FallbackReason.modelRateLimited, serviceError: null),
        ApiErrorCategory.rateLimited,
      );
      expectDialog(
        policy.decideTurn(reason: FallbackReason.modelAuthentication, serviceError: null),
        ApiErrorCategory.authentication,
      );
      expectDialog(
        policy.decideTurn(reason: FallbackReason.modelNotFound, serviceError: null),
        ApiErrorCategory.modelNotFound,
      );

      // 无明确分类：清提示。
      expectClear(
        policy.decideTurn(reason: FallbackReason.modelProvider, serviceError: null),
      );
      expectClear(
        policy.decideTurn(reason: FallbackReason.modelInternal, serviceError: null),
      );
      expectClear(
        policy.decideTurn(reason: FallbackReason.incompatibleModelResponse, serviceError: null),
      );
    });

    test('服务错误元数据逐条分类：network/server 走轻提示，其余走弹窗', () {
      // serviceError 抢在 reason 分类之前定档。
      expectNotice(
        policy.decideTurn(
          reason: FallbackReason.modelInternal,
          serviceError: ServiceErrorCategory.network,
        ),
        '⚠️ 网络连接异常，当前保持本地基础回复',
      );
      expectNotice(
        policy.decideTurn(
          reason: FallbackReason.modelRateLimited,
          serviceError: ServiceErrorCategory.server,
        ),
        '⚠️ 模型服务暂时不可用，当前保持本地基础回复',
        because: 'server 分支先于限流直配，锁分支顺序',
      );
      expectDialog(
        policy.decideTurn(
          reason: FallbackReason.modelProvider,
          serviceError: ServiceErrorCategory.authentication,
        ),
        ApiErrorCategory.authentication,
      );
      expectDialog(
        policy.decideTurn(
          reason: FallbackReason.modelInternal,
          serviceError: ServiceErrorCategory.modelNotFound,
        ),
        ApiErrorCategory.modelNotFound,
      );
      expectDialog(
        policy.decideTurn(
          reason: FallbackReason.modelProvider,
          serviceError: ServiceErrorCategory.rateLimited,
        ),
        ApiErrorCategory.rateLimited,
      );
      expectDialog(
        policy.decideTurn(
          reason: FallbackReason.incompatibleModelResponse,
          serviceError: ServiceErrorCategory.client,
        ),
        ApiErrorCategory.otherClientError,
      );

      // 分支顺序锁：超时轻提示抢在 serviceError network 之前。
      expectNotice(
        policy.decideTurn(
          reason: FallbackReason.modelTimeout,
          serviceError: ServiceErrorCategory.network,
        ),
        '⚠️ 网络连接超时，当前保持本地基础回复',
      );
    });

    test('轮末路径的弹窗分发固定带 300ms 落定缓冲（独立频控实例）', () {
      final policy = ApiErrorPolicy();
      final dispatch =
          policy.decideTurn(reason: FallbackReason.modelRateLimited, serviceError: null)
              as DispatchApiErrorDialog;
      expect(dispatch.delay, isTrue);
    });
  });

  group('ApiErrorPolicy.decideCategory 会话级频控', () {
    test('同会话同类错误：首次弹窗（不缓冲），其后状态条轻提示', () {
      final policy = ApiErrorPolicy();
      expectDialogFirst(policy.decideCategory(ApiErrorCategory.rateLimited));

      ShowApiErrorNotice repeat =
          policy.decideCategory(ApiErrorCategory.rateLimited) as ShowApiErrorNotice;
      expect(repeat.notice.message, '⚠️ 接口频繁受限 (429)，当前保持本地基础回复');
      expect(repeat.notice.showSettingsLink, isTrue);

      repeat = policy.decideCategory(ApiErrorCategory.rateLimited) as ShowApiErrorNotice;
      expect(repeat.notice.showSettingsLink, isTrue);
    });

    test('不同类别互不串扰，各走首次弹窗', () {
      final policy = ApiErrorPolicy();
      expectDialogFirst(policy.decideCategory(ApiErrorCategory.sttError));
      expectDialogFirst(policy.decideCategory(ApiErrorCategory.ttsError));
      expectDialogFirst(policy.decideCategory(ApiErrorCategory.authentication));
    });

    test('弹窗频控文案逐类核对', () {
      final cases = <ApiErrorCategory, String>{
        ApiErrorCategory.rateLimited: '⚠️ 接口频繁受限 (429)，当前保持本地基础回复',
        ApiErrorCategory.authentication: '⚠️ API Key 鉴权失败 (401/403)，当前保持本地基础回复',
        ApiErrorCategory.modelNotFound: '⚠️ 模型名称不存在 (404)，当前保持本地基础回复',
        ApiErrorCategory.otherClientError: '⚠️ 模型服务异常，当前保持本地基础回复',
        ApiErrorCategory.sttError: '⚠️ 语音服务频繁受限，当前保持静音',
        ApiErrorCategory.ttsError: '⚠️ 语音朗读频繁受限，当前保持静音',
      };
      cases.forEach((category, text) {
        final policy = ApiErrorPolicy();
        policy.decideCategory(category);
        final repeat = policy.decideCategory(category) as ShowApiErrorNotice;
        expect(repeat.notice.message, text, reason: category.name);
      });
    });

    test('resetSession 后同类错误重新走首次弹窗', () {
      final policy = ApiErrorPolicy();
      expectDialogFirst(policy.decideCategory(ApiErrorCategory.authentication));
      expect(
        policy.decideCategory(ApiErrorCategory.authentication),
        isA<ShowApiErrorNotice>(),
      );
      policy.resetSession();
      expectDialogFirst(policy.decideCategory(ApiErrorCategory.authentication));
    });

    test('跨通道共享频控：轮末弹过的类别，语音链路同会话只出轻提示', () {
      final policy = ApiErrorPolicy();
      final turnDecision = policy.decideTurn(
        reason: FallbackReason.modelRateLimited,
        serviceError: null,
      );
      expect(turnDecision, isA<DispatchApiErrorDialog>());
      expect(
        policy.decideCategory(ApiErrorCategory.rateLimited),
        isA<ShowApiErrorNotice>(),
        reason: '弹窗与轻提示共用同一份会话级记录',
      );
    });
  });
}

void expectDialogFirst(ApiErrorTurnDecision decision) {
  expect(decision, isA<DispatchApiErrorDialog>());
  expect(
    (decision as DispatchApiErrorDialog).delay,
    isFalse,
    reason: '语音链路即时触发，不缓冲',
  );
}
