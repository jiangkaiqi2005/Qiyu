import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'model_gateway.dart';
import 'web_search.dart';

const anySearchEndpoint = 'https://api.anysearch.com/mcp';
const anySearchClientName = 'qiyu-windows-host';

final class AnySearchClient implements WebSearchClient {
  const AnySearchClient(this.httpClient);

  final ProviderHttpClient httpClient;

  @override
  Future<List<WebSearchResult>> search({
    required String apiKey,
    required String query,
    Future<void>? whenCancelled,
  }) async {
    var cancelled = false;
    whenCancelled?.then((_) => cancelled = true);
    final safeQuery = sanitizeWebSearchQuery(query);
    if (safeQuery.isEmpty) {
      throw const ModelGatewayException(
        kind: ModelFailureKind.contentParsing,
        message: '搜索词为空。',
      );
    }
    try {
      final uri = Uri.parse(anySearchEndpoint);
      final headers = {
        'content-type': 'application/json',
        'accept': 'application/json',
        'authorization': 'Bearer ${apiKey.trim()}',
        'X-Anysearch-Client': anySearchClientName,
      };
      final requestBody = utf8.encode(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': 'qiyu-web-search',
          'method': 'tools/call',
          'params': {
            'name': 'search',
            'arguments': {'query': safeQuery, 'max_results': 5},
          },
        }),
      );
      final response =
          whenCancelled != null && httpClient is CancellableProviderHttpClient
          ? await (httpClient as CancellableProviderHttpClient).postCancellable(
              uri: uri,
              headers: headers,
              body: requestBody,
              timeout: const Duration(seconds: 20),
              whenCancelled: whenCancelled,
            )
          : await httpClient.post(
              uri: uri,
              headers: headers,
              body: requestBody,
              timeout: const Duration(seconds: 20),
            );
      final body = await response.body.join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw providerStatusFailure(
          response.statusCode,
          '',
          serviceLabel: '联网搜索服务',
        );
      }
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, Object?> || decoded['error'] != null) {
        throw const ModelGatewayException(
          kind: ModelFailureKind.provider,
          message: '联网搜索服务拒绝了这次请求。',
        );
      }
      final results = _normalizeResults(decoded['result']);
      if (results.isEmpty) {
        throw const ModelGatewayException(
          kind: ModelFailureKind.contentParsing,
          message: '联网搜索服务没有返回可用结果。',
        );
      }
      return results;
    } on ProviderRequestCancelled {
      rethrow;
    } on TimeoutException {
      throw const ModelGatewayException(
        kind: ModelFailureKind.timeout,
        message: '联网搜索服务响应超时。',
      );
    } on HandshakeException {
      throw const ModelGatewayException(
        kind: ModelFailureKind.tls,
        message: '联网搜索服务的 TLS 安全连接失败。',
      );
    } on SocketException catch (error) {
      throw providerSocketFailure(error, serviceLabel: '联网搜索服务');
    } on ModelGatewayException {
      rethrow;
    } on Object {
      if (cancelled) {
        throw const ProviderRequestCancelled();
      }
      throw const ModelGatewayException(
        kind: ModelFailureKind.incompatibleResponse,
        message: '联网搜索服务返回了不兼容的响应格式。',
      );
    }
  }
}

List<WebSearchResult> _normalizeResults(Object? raw) {
  var candidates = _resultCandidates(raw);
  if (candidates.isEmpty) {
    candidates = [
      for (final markdown in _resultMarkdownTexts(raw))
        ..._parseMarkdownResults(markdown),
    ];
  }
  final results = <WebSearchResult>[];
  var totalRunes = 0;
  for (final candidate in candidates) {
    if (candidate is! Map) {
      continue;
    }
    final title = _clip(candidate['title'], 160);
    final url = _clip(candidate['url'] ?? candidate['link'], 800);
    final snippet = _clip(
      candidate['snippet'] ?? candidate['content'] ?? candidate['description'],
      1200,
    );
    if (title.isEmpty && url.isEmpty && snippet.isEmpty) {
      continue;
    }
    final nextRunes =
        title.runes.length + url.runes.length + snippet.runes.length;
    if (totalRunes + nextRunes > 6000) {
      break;
    }
    results.add(WebSearchResult(title: title, url: url, snippet: snippet));
    totalRunes += nextRunes;
    if (results.length == 5) {
      break;
    }
  }
  return results;
}

Iterable<String> _resultMarkdownTexts(Object? raw) sync* {
  if (raw is String) {
    yield raw;
    return;
  }
  if (raw is! Map) {
    return;
  }
  final content = raw['content'];
  if (content is! List<Object?>) {
    return;
  }
  for (final part in content) {
    if (part is Map && part['text'] is String) {
      yield part['text']! as String;
    }
  }
}

List<Map<String, String>> _parseMarkdownResults(String markdown) {
  final results = <Map<String, String>>[];
  _MarkdownSearchEntry? current;

  void finishCurrent() {
    final entry = current;
    if (entry == null || (entry.title.isEmpty && entry.url.isEmpty)) {
      return;
    }
    results.add({
      'title': entry.title,
      'url': entry.url,
      'snippet': entry.snippet.join(' ').trim(),
    });
  }

  final headingPattern = RegExp(r'^###\s+(?:\d+\.\s*)?(.*)$');
  final linkedTitlePattern = RegExp(
    r'^\[([^\]]+)\]\((https?://[^)\s]+)\)\s*$',
    caseSensitive: false,
  );
  final urlPattern = RegExp(
    r'^-?\s*\*\*URL\*\*\s*:\s*(\S+)\s*$',
    caseSensitive: false,
  );
  final snippetPattern = RegExp(
    r'^-?\s*\*\*(?:Snippet|Summary|Description|Content)\*\*\s*:\s*(.*)$',
    caseSensitive: false,
  );
  final metadataPattern = RegExp(r'^-?\s*\*\*[^*]+\*\*\s*:');

  for (final rawLine in const LineSplitter().convert(markdown)) {
    final line = rawLine.trim();
    final heading = headingPattern.firstMatch(line);
    if (heading != null) {
      finishCurrent();
      final rawTitle = heading.group(1)!.trim();
      final linkedTitle = linkedTitlePattern.firstMatch(rawTitle);
      current = _MarkdownSearchEntry(
        title: linkedTitle?.group(1)?.trim() ?? rawTitle,
        url: linkedTitle?.group(2)?.trim() ?? '',
      );
      continue;
    }
    final entry = current;
    if (entry == null || line.isEmpty) {
      continue;
    }
    final url = urlPattern.firstMatch(line);
    if (url != null) {
      entry.url = url.group(1)!.trim();
      continue;
    }
    final snippet = snippetPattern.firstMatch(line);
    if (snippet != null) {
      final value = snippet.group(1)!.trim();
      if (value.isNotEmpty) {
        entry.snippet.add(value);
      }
      continue;
    }
    if (metadataPattern.hasMatch(line) || line.startsWith('## ')) {
      continue;
    }
    final plain = line.replaceFirst(RegExp(r'^[-*]\s+'), '').trim();
    if (plain.isNotEmpty) {
      entry.snippet.add(plain);
    }
  }
  finishCurrent();
  return results;
}

final class _MarkdownSearchEntry {
  _MarkdownSearchEntry({required this.title, required this.url});

  final String title;
  String url;
  final List<String> snippet = [];
}

List<Object?> _resultCandidates(Object? raw) {
  if (raw is List<Object?>) {
    return raw;
  }
  if (raw is! Map) {
    return const [];
  }
  for (final key in const ['results', 'data', 'items']) {
    final value = raw[key];
    if (value is List<Object?>) {
      return value;
    }
  }
  final content = raw['content'];
  if (content is List<Object?>) {
    for (final part in content) {
      if (part is Map && part['text'] is String) {
        try {
          final decoded = jsonDecode(part['text']! as String);
          final nested = _resultCandidates(decoded);
          if (nested.isNotEmpty) {
            return nested;
          }
        } on FormatException {
          continue;
        }
      }
    }
  }
  return const [];
}

String _clip(Object? value, int maxRunes) {
  final text = value is String ? value.trim() : '';
  final runes = text.runes.toList(growable: false);
  return runes.length <= maxRunes
      ? text
      : String.fromCharCodes(runes.take(maxRunes));
}
