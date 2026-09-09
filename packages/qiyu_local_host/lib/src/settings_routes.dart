import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';

import 'api_http.dart';
import 'developer_diagnostics.dart';
import 'local_data_service.dart';
import 'provider_config.dart';
import 'provider_settings_service.dart';
import 'proxy_settings_service.dart';
import 'stt_settings_service.dart';
import 'tts_settings_service.dart';
import 'web_search_settings_service.dart';

/// 设置领域路由：模型 Provider、联网搜索、语音转写（STT）、语音合成
/// （TTS）四段配置的读写与连接测试，出站代理配置，体验选项，以及
/// 开发者诊断入口。
///
/// 本模块持有设置领域的路径匹配、payload 解析（含各字段的类型与缺省
/// 规则）、序列化与错误翻译；删除本模块，这些职责会整体摊回路由总控。
final class SettingsRoutes implements ApiRoutes {
  SettingsRoutes({
    required this.providerSettingsService,
    required this.webSearchSettingsService,
    required this.sttSettingsService,
    required this.ttsSettingsService,
    required this.experienceRepository,
    required this.developerDiagnostics,
    required this.requestDiagnostics,
    required this.proxySettingsService,
  });

  final ProviderSettingsService providerSettingsService;
  final WebSearchSettingsService webSearchSettingsService;
  final SttSettingsService sttSettingsService;
  final TtsSettingsService ttsSettingsService;
  final ExperienceSettingsRepository experienceRepository;
  final DeveloperDiagnosticsService developerDiagnostics;
  final RequestDiagnosticsRecorder? requestDiagnostics;
  final ProxySettingsService proxySettingsService;

  @override
  Future<Response?> handle(Request request) async {
    // 本领域没有共享口径之外的异常差异：请求体不可读、invalid_request、
    // Provider 配置与凭据库故障、本地数据故障全走共享翻译前导。
    return runApiRoute(() => _route(request));
  }

  /// 依次询问各子域；返回 null 表示请求不属于设置领域，交回总控。
  Future<Response?> _route(Request request) async {
    for (final subdomain in [
      _providerRoutes,
      _webSearchRoutes,
      _proxyRoutes,
      _sttRoutes,
      _ttsRoutes,
      _preferenceRoutes,
    ]) {
      final response = await subdomain(request);
      if (response != null) {
        return response;
      }
    }
    return null;
  }

  /// 模型 Provider 子域：配置读取/保存、连接测试与忘记 Key。
  Future<Response?> _providerRoutes(Request request) async {
    final method = request.method;
    final path = request.url.path;
    if (method == 'GET' && path == 'api/provider') {
      final settings = await providerSettingsService.read();
      return Response.ok(
        jsonEncode(settings.toJson()),
        headers: jsonHeaders,
      );
    }
    if (method == 'PUT' && path == 'api/provider') {
      final payload = await readJsonObject(request, maxBytes: 32 * 1024);
      final config = _providerConfigFromPayload(payload);
      final settings = await providerSettingsService.save(
        config: config,
        apiKey: _apiKeyFromPayload(payload),
      );
      return Response.ok(
        jsonEncode(settings.toJson()),
        headers: jsonHeaders,
      );
    }
    if (method == 'POST' && path == 'api/provider/test') {
      final payload = await readJsonObject(request, maxBytes: 32 * 1024);
      final apiKey = _apiKeyFromPayload(payload);
      final config = payload.isEmpty
          ? (await providerSettingsService.read()).config
          : _providerConfigFromPayload(payload);
      if (config == null) {
        const result = ProviderTestResult(
          status: ProviderTestStatus.notConfigured,
          message: '还没有保存模型配置。',
        );
        return Response.ok(
          jsonEncode(result.toJson()),
          headers: jsonHeaders,
        );
      }
      final result = await providerSettingsService.test(
        config: config,
        apiKey: apiKey,
      );
      requestDiagnostics?.record(
        source: RecentRequestSources.providerTest,
        result: result.succeeded
            ? RecentRequestResults.ok
            : RecentRequestResults.failed,
        detail: 'status=${result.status.name}',
      );
      return Response.ok(jsonEncode(result.toJson()), headers: jsonHeaders);
    }
    if (method == 'DELETE' && path == 'api/provider/key') {
      final settings = await providerSettingsService.forgetApiKey();
      return Response.ok(
        jsonEncode(settings.toJson()),
        headers: jsonHeaders,
      );
    }
    return null;
  }

  /// 联网搜索子域：Key 的保存、读取与忘记。
  Future<Response?> _webSearchRoutes(Request request) async {
    final method = request.method;
    final path = request.url.path;
    if (method == 'GET' && path == 'api/provider/web-search') {
      final settings = await webSearchSettingsService.read();
      return Response.ok(
        jsonEncode(settings.toJson()),
        headers: jsonHeaders,
      );
    }
    if (method == 'PUT' && path == 'api/provider/web-search') {
      final payload = await readJsonObject(request, maxBytes: 8 * 1024);
      final unexpected = payload.keys.where((key) => key != 'apiKey');
      if (unexpected.isNotEmpty) {
        throw const ProviderConfigException('联网搜索配置格式不正确。');
      }
      final settings = await webSearchSettingsService.save(
        apiKey: _apiKeyFromPayload(payload),
      );
      return Response.ok(
        jsonEncode(settings.toJson()),
        headers: jsonHeaders,
      );
    }
    if (method == 'DELETE' && path == 'api/provider/web-search/key') {
      final settings = await webSearchSettingsService.forgetApiKey();
      return Response.ok(
        jsonEncode(settings.toJson()),
        headers: jsonHeaders,
      );
    }
    return null;
  }

  /// 出站代理子域：代理配置的读取与保存。地址与端口不是凭据，随
  /// 快照回显；启用中的配置在服务层校验（地址必填、端口 1–65535）。
  Future<Response?> _proxyRoutes(Request request) async {
    final method = request.method;
    final path = request.url.path;
    if (method == 'GET' && path == 'api/provider/proxy') {
      final settings = await proxySettingsService.read();
      return Response.ok(
        jsonEncode(settings.toJson()),
        headers: jsonHeaders,
      );
    }
    if (method == 'PUT' && path == 'api/provider/proxy') {
      final payload = await readJsonObject(request, maxBytes: 4 * 1024);
      final enabled = payload['enabled'];
      final host = payload['host'];
      final port = payload['port'];
      if (enabled is! bool || host is! String || port is! int) {
        throw const ProviderConfigException('代理配置格式不正确。');
      }
      final settings = await proxySettingsService.save(
        enabled: enabled,
        host: host,
        port: port,
      );
      return Response.ok(
        jsonEncode(settings.toJson()),
        headers: jsonHeaders,
      );
    }
    return null;
  }

  /// 语音转写（STT）子域：配置读取/保存、连接测试与忘记 Key。
  Future<Response?> _sttRoutes(Request request) async {
    final method = request.method;
    final path = request.url.path;
    if (method == 'GET' && path == 'api/provider/stt') {
      final settings = await sttSettingsService.read();
      return Response.ok(
        jsonEncode(settings.toJson()),
        headers: jsonHeaders,
      );
    }
    if (method == 'PUT' && path == 'api/provider/stt') {
      final payload = await readJsonObject(request, maxBytes: 32 * 1024);
      final settings = await sttSettingsService.save(
        provider: _sttProviderFromPayload(payload),
        baseUrl: _sttTextField(payload, 'baseUrl'),
        model: _sttTextField(payload, 'model'),
        apiKey: _apiKeyFromPayload(payload),
      );
      return Response.ok(
        jsonEncode(settings.toJson()),
        headers: jsonHeaders,
      );
    }
    if (method == 'POST' && path == 'api/provider/stt/test') {
      final payload = await readJsonObject(request, maxBytes: 32 * 1024);
      final result = await sttSettingsService.test(
        provider: _sttProviderFromPayload(payload),
        baseUrl: _optionalSttTextField(payload, 'baseUrl'),
        model: _optionalSttTextField(payload, 'model'),
        apiKey: _apiKeyFromPayload(payload),
      );
      requestDiagnostics?.record(
        source: RecentRequestSources.providerTest,
        result: result.succeeded
            ? RecentRequestResults.ok
            : RecentRequestResults.failed,
        detail: 'stt status=${result.status.name}',
      );
      return Response.ok(jsonEncode(result.toJson()), headers: jsonHeaders);
    }
    if (method == 'DELETE' && path == 'api/provider/stt/key') {
      final settings = await sttSettingsService.forgetApiKey();
      return Response.ok(
        jsonEncode(settings.toJson()),
        headers: jsonHeaders,
      );
    }
    return null;
  }

  /// 语音合成（TTS）子域：配置读取/保存、连接测试、自动朗读开关与
  /// 忘记 Key。
  Future<Response?> _ttsRoutes(Request request) async {
    final method = request.method;
    final path = request.url.path;
    if (method == 'GET' && path == 'api/provider/tts') {
      final settings = await ttsSettingsService.read();
      return Response.ok(
        jsonEncode(settings.toJson()),
        headers: jsonHeaders,
      );
    }
    if (method == 'PUT' && path == 'api/provider/tts') {
      final payload = await readJsonObject(request, maxBytes: 32 * 1024);
      final settings = await ttsSettingsService.save(
        provider: _ttsProviderFromPayload(payload),
        baseUrl: _sttTextField(payload, 'baseUrl'),
        model: _sttTextField(payload, 'model'),
        apiKey: _apiKeyFromPayload(payload),
        voice: _optionalSttTextField(payload, 'voice'),
        speed: _ttsSpeedFromPayload(payload),
        autoSpeak: _ttsAutoSpeakFromPayload(payload),
        extraParams: _ttsExtraParamsFromPayload(payload),
      );
      return Response.ok(
        jsonEncode(settings.toJson()),
        headers: jsonHeaders,
      );
    }
    if (method == 'POST' && path == 'api/provider/tts/test') {
      final payload = await readJsonObject(request, maxBytes: 32 * 1024);
      final result = await ttsSettingsService.test(
        provider: _ttsProviderFromPayload(payload),
        baseUrl: _optionalSttTextField(payload, 'baseUrl'),
        model: _optionalSttTextField(payload, 'model'),
        apiKey: _apiKeyFromPayload(payload),
        voice: _optionalSttTextField(payload, 'voice'),
        speed: _ttsSpeedFromPayload(payload),
        extraParams: _ttsExtraParamsFromPayload(payload),
      );
      requestDiagnostics?.record(
        source: RecentRequestSources.providerTest,
        result: result.succeeded
            ? RecentRequestResults.ok
            : RecentRequestResults.failed,
        detail: 'tts status=${result.status.name}',
      );
      return Response.ok(jsonEncode(result.toJson()), headers: jsonHeaders);
    }
    if (method == 'PUT' && path == 'api/provider/tts/auto-speak') {
      final payload = await readJsonObject(request, maxBytes: 4 * 1024);
      final enabled = payload['enabled'];
      if (enabled is! bool) {
        throw invalidRequest('朗读开关请求格式不正确。');
      }
      final settings = await ttsSettingsService.setAutoSpeak(enabled);
      return Response.ok(
        jsonEncode(settings.toJson()),
        headers: jsonHeaders,
      );
    }
    if (method == 'DELETE' && path == 'api/provider/tts/key') {
      final settings = await ttsSettingsService.forgetApiKey();
      return Response.ok(
        jsonEncode(settings.toJson()),
        headers: jsonHeaders,
      );
    }
    return null;
  }

  /// 体验选项与开发者诊断子域：选项读写；诊断入口只在开发者模式
  /// 开启时存在。
  Future<Response?> _preferenceRoutes(Request request) async {
    final method = request.method;
    final path = request.url.path;
    if (method == 'GET' && path == 'api/preferences') {
      final settings = await experienceRepository.load();
      return Response.ok(
        jsonEncode(settings.toJson()),
        headers: jsonHeaders,
      );
    }
    if (method == 'PUT' && path == 'api/preferences') {
      final payload = await readJsonObject(request, maxBytes: 4 * 1024);
      final developerMode = payload['developerMode'];
      if (developerMode is! bool) {
        throw invalidRequest('体验选项请求格式不正确。');
      }
      final ExperienceSettings settings;
      try {
        settings = await experienceRepository.save(
          ExperienceSettings(developerMode: developerMode),
        );
      } on Object catch (error) {
        throw LocalDataException('体验选项保存失败，请稍后重试。', error);
      }
      return Response.ok(
        jsonEncode(settings.toJson()),
        headers: jsonHeaders,
      );
    }
    if (method == 'GET' && path == 'api/dev/diagnostics') {
      // 实验室/开发者能力默认不打扰普通用户：未开启开发者模式时
      // 端点直接按不存在处理；诊断只读，绝不修改生产数据。
      final settings = await experienceRepository.load();
      if (!settings.developerMode) {
        return plainError(HttpStatus.notFound, 'Not found');
      }
      final snapshot = await developerDiagnostics.snapshot();
      return Response.ok(jsonEncode(snapshot), headers: jsonHeaders);
    }
    return null;
  }
}

ProviderConfig _providerConfigFromPayload(Map<String, Object?> payload) {
  final provider = payload['provider'];
  final baseUrl = payload['baseUrl'];
  final model = payload['model'];
  final temperature = payload['temperature'];
  final timeoutSeconds = payload['timeoutSeconds'];
  if (provider is! String ||
      baseUrl is! String ||
      model is! String ||
      temperature is! num ||
      timeoutSeconds is! int) {
    throw const ProviderConfigException('模型配置格式不正确。');
  }
  return ProviderConfig(
    kind: ProviderKind.fromWireName(provider),
    baseUrl: baseUrl,
    model: model,
    temperature: temperature.toDouble(),
    timeoutSeconds: timeoutSeconds,
  );
}

/// 从 Provider 相关请求体取可选 API Key；类型不对时按配置格式错误拒绝。
String? _apiKeyFromPayload(Map<String, Object?> payload) {
  final apiKey = payload['apiKey'];
  if (apiKey != null && apiKey is! String) {
    throw const ProviderConfigException('API Key 格式不正确。');
  }
  return apiKey as String?;
}

/// STT 设置必填文本字段：缺失或类型不对按配置格式错误拒绝。
String _sttTextField(Map<String, Object?> payload, String key) {
  final value = payload[key];
  if (value is! String) {
    throw const ProviderConfigException('语音服务配置格式不正确。');
  }
  return value;
}

/// STT 连接测试的可选文本字段：空负载（测试已保存配置）允许缺失。
String? _optionalSttTextField(Map<String, Object?> payload, String key) {
  final value = payload[key];
  if (value == null) {
    return null;
  }
  if (value is! String) {
    throw const ProviderConfigException('语音服务配置格式不正确。');
  }
  return value;
}

/// STT 设置的服务类型（provider）：可选字段，缺省 openai_compatible；
/// 非法协议名按配置格式错误拒绝，不落盘。
SttProviderKind _sttProviderFromPayload(Map<String, Object?> payload) {
  final value = payload['provider'];
  if (value == null) {
    return SttProviderKind.openAiCompatible;
  }
  if (value is! String) {
    throw const ProviderConfigException('语音服务配置格式不正确。');
  }
  return SttProviderKind.fromWireName(value);
}

/// TTS 设置的服务类型（provider）：缺省与校验规则同 STT。
TtsProviderKind _ttsProviderFromPayload(Map<String, Object?> payload) {
  final value = payload['provider'];
  if (value == null) {
    return TtsProviderKind.openAiCompatible;
  }
  if (value is! String) {
    throw const ProviderConfigException('语音服务配置格式不正确。');
  }
  return TtsProviderKind.fromWireName(value);
}

/// TTS 语速（speed）：可选数值字段；null/缺省不设置（沿用服务缺省），
/// 类型不对按配置格式错误拒绝。
double? _ttsSpeedFromPayload(Map<String, Object?> payload) {
  final value = payload['speed'];
  if (value == null) {
    return null;
  }
  if (value is! num) {
    throw const ProviderConfigException('语音服务配置格式不正确。');
  }
  return value.toDouble();
}

/// TTS 自动朗读开关（autoSpeak）：可选布尔字段，缺省 true。
bool? _ttsAutoSpeakFromPayload(Map<String, Object?> payload) {
  final value = payload['autoSpeak'];
  if (value == null) {
    return null;
  }
  if (value is! bool) {
    throw const ProviderConfigException('语音服务配置格式不正确。');
  }
  return value;
}

/// TTS 自定义高级参数（extraParams）：可选 Map 对象。
Map<String, Object?>? _ttsExtraParamsFromPayload(
  Map<String, Object?> payload,
) {
  final value = payload['extraParams'] ?? payload['extra_params'];
  if (value == null) {
    return null;
  }
  if (value is! Map) {
    throw const ProviderConfigException('语音服务配置格式不正确。');
  }
  return value.cast<String, Object?>();
}
