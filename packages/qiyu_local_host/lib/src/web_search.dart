import 'markdown_memory_repository.dart';

const maxWebSearchQueryRunes = 500;

final class WebSearchResult {
  const WebSearchResult({
    required this.title,
    required this.url,
    required this.snippet,
  });

  final String title;
  final String url;
  final String snippet;

  Map<String, String> toJson() => {
    'title': title,
    'url': url,
    'snippet': snippet,
  };
}

abstract interface class WebSearchClient {
  Future<List<WebSearchResult>> search({
    required String apiKey,
    required String query,
    Future<void>? whenCancelled,
  });
}

String sanitizeWebSearchQuery(String query) {
  final trimmed = query.trim();
  if (trimmed.isEmpty || trimmed.runes.length > maxWebSearchQueryRunes) {
    return '';
  }
  final redacted = redactSessionText(trimmed).trim();
  final meaningful = redacted.replaceAll('[已脱敏]', '').trim();
  return meaningful.isEmpty ? '' : redacted;
}
