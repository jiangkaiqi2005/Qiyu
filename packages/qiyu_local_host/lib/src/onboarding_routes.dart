import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';

import 'api_http.dart';
import 'onboarding_state.dart';
import 'persona_tree.dart';

/// 引导领域路由：首次见面状态读取与完成标记。
///
/// 本模块持有引导领域的路径匹配、状态序列化与错误翻译；删除本模块，
/// 这些职责会整体摊回路由总控。
final class OnboardingRoutes implements ApiRoutes {
  OnboardingRoutes({required this.onboardingRepository, required this.personaTree});

  final OnboardingRepository onboardingRepository;

  /// 称呼写入口之一（首见引导）：完成引导时可携带自填称呼，落到
  /// persona.md 受保护设定行；格式被拒时引导保持未完成。
  final PersonaTreeStore personaTree;

  @override
  Future<Response?> handle(Request request) async {
    // 领域差异只有引导状态不可用；完成请求现在读取可选称呼字段，
    // 请求体缺陷走共享翻译口径。
    return runApiRoute(
      () => _route(request),
      translateDomainError: (error) => error is OnboardingStateException
          ? jsonError(
              HttpStatus.internalServerError,
              code: 'onboarding_unavailable',
              message: error.message,
              retryable: true,
            )
          : null,
    );
  }

  Future<Response?> _route(Request request) async {
    final method = request.method;
    final path = request.url.path;
    if (method == 'GET' && path == 'api/onboarding') {
      final state = await onboardingRepository.load();
      return Response.ok(
        jsonEncode({'completed': state.completed}),
        headers: jsonHeaders,
      );
    }
    if (method == 'POST' && path == 'api/onboarding/complete') {
      final appellation = await _readOptionalAppellation(request);
      if (appellation != null) {
        // 校验先行：称呼被拒时引导保持未完成，用户可改后重试或跳过。
        final written = await personaTree.setAppellation(appellation);
        if (written == null) {
          return jsonError(
            HttpStatus.badRequest,
            code: 'invalid_appellation',
            message: appellationRejectedMessage,
            retryable: false,
          );
        }
      }
      final state = await onboardingRepository.markCompleted(DateTime.now());
      return Response.ok(
        jsonEncode({'completed': state.completed}),
        headers: jsonHeaders,
      );
    }
    return null;
  }

  /// 完成请求里的可选称呼字段：请求体为空视为不带称呼（向后兼容）；
  /// 字段缺省或 null 同样视为不带；非字符串一律拒绝。
  Future<String?> _readOptionalAppellation(Request request) async {
    final bytes = await readLimitedBytes(
      request,
      maxBytes: 16 * 1024,
      onOversize: () => const FormatException('request body is too large'),
    );
    if (bytes.isEmpty) {
      return null;
    }
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('request body must be an object');
    }
    final value = decoded['appellation'];
    if (value == null) {
      return null;
    }
    if (value is! String) {
      throw invalidRequest('称呼格式不正确。');
    }
    return value;
  }
}
