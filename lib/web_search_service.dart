import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'ai_config_store.dart';

class WebSearchConfigKeys {
  static const enabled = 'web_search_enabled';
  static const tavilyApiKey = 'web_search_tavily_api_key';
  static const tinyFishApiKey = 'web_search_tinyfish_api_key';
  static const firecrawlApiKey = 'web_search_firecrawl_api_key';
}

class WebSearchResult {
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

class WebSearchException implements Exception {
  const WebSearchException(this.message);

  final String message;

  @override
  String toString() => message;
}

class WebSearchService {
  WebSearchService({
    required http.Client client,
    required AiConfigStore configStore,
    this.requestTimeout = const Duration(seconds: 20),
  }) : _client = client,
       _configStore = configStore;

  final http.Client _client;
  final AiConfigStore _configStore;
  final Duration requestTimeout;

  Future<List<WebSearchResult>> search(String query) async {
    final normalizedQuery = query.trim();
    if (normalizedQuery.isEmpty) {
      throw const WebSearchException('The web search query is empty.');
    }

    final tavilyApiKey = await _configStore.read(
      WebSearchConfigKeys.tavilyApiKey,
    );
    final tinyFishApiKey = await _configStore.read(
      WebSearchConfigKeys.tinyFishApiKey,
    );
    final firecrawlApiKey = await _configStore.read(
      WebSearchConfigKeys.firecrawlApiKey,
    );
    final failures = <String>[];
    final tavilyKey = tavilyApiKey?.trim();
    if (tavilyKey != null && tavilyKey.isNotEmpty) {
      final results = await _tryProvider(
        'Tavily',
        failures,
        () => _searchTavily(normalizedQuery, tavilyKey),
      );
      if (results != null && results.length >= 3) {
        return results.take(5).toList(growable: false);
      }
      if (results != null) failures.add('Tavily returned fewer than 3 results');
    }

    final tinyFishKey = tinyFishApiKey?.trim();
    if (tinyFishKey != null && tinyFishKey.isNotEmpty) {
      final results = await _tryProvider(
        'TinyFish',
        failures,
        () => _searchTinyFish(normalizedQuery, tinyFishKey),
      );
      if (results != null && results.length >= 3) {
        return results.take(5).toList(growable: false);
      }
      if (results != null) {
        failures.add('TinyFish returned fewer than 3 results');
      }
    }

    final firecrawlKey = firecrawlApiKey?.trim();
    final firecrawlResults = await _tryProvider(
      'Firecrawl',
      failures,
      () => _searchFirecrawl(
        normalizedQuery,
        firecrawlKey == null || firecrawlKey.isEmpty ? null : firecrawlKey,
      ),
    );
    if (firecrawlResults != null && firecrawlResults.isNotEmpty) {
      return firecrawlResults.take(5).toList(growable: false);
    }
    if (firecrawlResults != null) {
      failures.add('Firecrawl returned no usable results');
    }

    throw WebSearchException('Web search failed. ${failures.join('; ')}');
  }

  Future<List<WebSearchResult>?> _tryProvider(
    String provider,
    List<String> failures,
    Future<List<WebSearchResult>> Function() request,
  ) async {
    try {
      return await request();
    } on _ProviderRequestException catch (error) {
      failures.add('$provider: ${error.reason}');
    } on http.ClientException {
      failures.add('$provider: network error');
    } on TimeoutException {
      failures.add('$provider: request timed out');
    } on FormatException {
      failures.add('$provider: invalid response');
    }
    return null;
  }

  Future<List<WebSearchResult>> _searchTavily(
    String query,
    String apiKey,
  ) async {
    final response = await _client
        .post(
          Uri.parse('https://api.tavily.com/search'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $apiKey',
          },
          body: jsonEncode({
            'query': query,
            'search_depth': 'basic',
            'max_results': 5,
          }),
        )
        .timeout(requestTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _ProviderRequestException('HTTP ${response.statusCode}');
    }
    final payload = _decodeObject(response.body);
    return _parseResults(payload['results'], 'content');
  }

  Future<List<WebSearchResult>> _searchTinyFish(
    String query,
    String apiKey,
  ) async {
    final response = await _client
        .get(
          Uri.https('api.search.tinyfish.ai', '', {'query': query}),
          headers: {'X-API-Key': apiKey},
        )
        .timeout(requestTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _ProviderRequestException('HTTP ${response.statusCode}');
    }
    final payload = _decodeObject(response.body);
    return _parseResults(payload['results'], 'snippet');
  }

  Future<List<WebSearchResult>> _searchFirecrawl(
    String query,
    String? apiKey,
  ) async {
    final headers = <String, String>{'Content-Type': 'application/json'};
    if (apiKey != null) {
      headers['Authorization'] = 'Bearer $apiKey';
    }
    final response = await _client
        .post(
          Uri.parse('https://api.firecrawl.dev/v2/search'),
          headers: headers,
          body: jsonEncode({'query': query, 'limit': 5}),
        )
        .timeout(requestTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _ProviderRequestException('HTTP ${response.statusCode}');
    }
    final payload = _decodeObject(response.body);
    final data = payload['data'];
    if (data is! Map<String, dynamic>) {
      throw const FormatException('Firecrawl response has no data object.');
    }
    return _parseResults(data['web'], 'description');
  }

  Map<String, dynamic> _decodeObject(String body) {
    final payload = jsonDecode(body);
    if (payload is! Map<String, dynamic>) {
      throw const FormatException('Search response is not a JSON object.');
    }
    return payload;
  }

  List<WebSearchResult> _parseResults(dynamic value, String snippetField) {
    if (value is! List) {
      throw const FormatException('Search response has no results list.');
    }
    final results = <WebSearchResult>[];
    final seenUrls = <String>{};
    for (final item in value) {
      if (item is! Map<String, dynamic>) continue;
      final title = _cleanText(item['title']);
      final snippet = _cleanText(item[snippetField]);
      final url = _cleanUrl(item['url']);
      if (title.isEmpty || snippet.isEmpty || url == null) continue;
      if (!seenUrls.add(url)) continue;
      results.add(
        WebSearchResult(
          title: title,
          url: url,
          snippet: snippet.length > 1200 ? snippet.substring(0, 1200) : snippet,
        ),
      );
      if (results.length == 5) break;
    }
    return results;
  }

  String _cleanText(dynamic value) {
    if (value is! String) return '';
    return value.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  String? _cleanUrl(dynamic value) {
    if (value is! String) return null;
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        (uri.scheme != 'https' && uri.scheme != 'http') ||
        uri.host.isEmpty) {
      return null;
    }
    return uri.removeFragment().toString();
  }
}

class _ProviderRequestException implements Exception {
  const _ProviderRequestException(this.reason);

  final String reason;
}
