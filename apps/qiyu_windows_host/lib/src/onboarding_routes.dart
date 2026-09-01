import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';

import 'api_http.dart';
import 'onboarding_state.dart';

/// 引导领域路由：首次见面状态读取与完成标记。
///
/// 本模块持有引导领域的路径匹配、状态序列化与错误翻译；删除本模块，
/// 这些职责会整体摊回路由总控。
final class OnboardingRoutes implements ApiRoutes {
  OnboardingRoutes({required this.onboardingRepository});

  final OnboardingRepository onboardingRepository;

  @override
  Future<Response?> handle(Request request) async {
    try {
      return await _route(request);
    } on OnboardingStateException catch (error) {
      return jsonError(
        HttpStatus.internalServerError,
        code: 'onboarding_unavailable',
        message: error.message,
        retryable: true,
      );
    }
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
      final state = await onboardingRepository.markCompleted(DateTime.now());
      return Response.ok(
        jsonEncode({'completed': state.completed}),
        headers: jsonHeaders,
      );
    }
    return null;
  }
}
