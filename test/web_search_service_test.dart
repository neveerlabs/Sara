import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sara_desktop/ai_config_store.dart';
import 'package:sara_desktop/web_search_service.dart';

void main() {
  group('WebSearchService', () {
    test('falls back from Tavily to TinyFish and caps results at five', () async {
      final config = _MemoryAiConfigStore()
        ..values[WebSearchConfigKeys.tavilyApiKey] = 'tavily-key'
        ..values[WebSearchConfigKeys.tinyFishApiKey] = 'tinyfish-key';
      final requests = <http.Request>[];
      final service = WebSearchService(
        configStore: config,
        client: MockClient((request) async {
          requests.add(request);
          if (request.url.host == 'api.tavily.com') {
            expect(request.headers['authorization'], 'Bearer tavily-key');
            return http.Response('quota exceeded', 429);
          }
          expect(request.url.host, 'api.search.tinyfish.ai');
          expect(request.headers['x-api-key'], 'tinyfish-key');
          return http.Response(
            jsonEncode({
              'results': List.generate(
                6,
                (index) => {
                  'title': 'Result $index',
                  'url': 'https://example.com/$index',
                  'snippet': 'Snippet $index',
                },
              ),
            }),
            200,
          );
        }),
      );

      final results = await service.search('latest search APIs');

      expect(requests, hasLength(2));
      expect(results, hasLength(5));
      expect(results.first.title, 'Result 0');
    });

    test('falls back when a provider returns fewer than three clean results',
        () async {
      final config = _MemoryAiConfigStore()
        ..values[WebSearchConfigKeys.tavilyApiKey] = 'tavily-key'
        ..values[WebSearchConfigKeys.tinyFishApiKey] = 'tinyfish-key';
      final service = WebSearchService(
        configStore: config,
        client: MockClient((request) async {
          if (request.url.host == 'api.tavily.com') {
            return http.Response(
              jsonEncode({
                'results': [
                  {
                    'title': 'Only result',
                    'url': 'https://example.com/1',
                    'content': 'One result is not enough',
                  },
                ],
              }),
              200,
            );
          }
          return http.Response(
            jsonEncode({
              'results': List.generate(
                3,
                (index) => {
                  'title': 'TinyFish $index',
                  'url': 'https://tinyfish.example/$index',
                  'snippet': 'TinyFish snippet $index',
                },
              ),
            }),
            200,
          );
        }),
      );

      final results = await service.search('topic with few results');

      expect(results, hasLength(3));
      expect(results.first.title, 'TinyFish 0');
    });

    test(
      'uses Firecrawl without an API key and accepts fewer than three',
      () async {
        final config = _MemoryAiConfigStore();
        final service = WebSearchService(
          configStore: config,
          client: MockClient((request) async {
            expect(request.url.host, 'api.firecrawl.dev');
            expect(request.url.path, '/v2/search');
            expect(request.headers.containsKey('authorization'), isFalse);
            expect(jsonDecode(request.body), {
              'query': 'local search',
              'limit': 5,
            });
            return http.Response(
              jsonEncode({
                'data': {
                  'web': [
                    {
                      'title': 'Result 1',
                      'url': 'https://example.com/1',
                      'description': 'First result',
                    },
                    {
                      'title': 'Result 2',
                      'url': 'https://example.com/2',
                      'description': 'Second result',
                    },
                  ],
                },
              }),
              200,
            );
          }),
        );

        final results = await service.search('local search');

        expect(results, hasLength(2));
      },
    );

    test('uses the saved Firecrawl key when provided', () async {
      final config = _MemoryAiConfigStore()
        ..values[WebSearchConfigKeys.firecrawlApiKey] = 'firecrawl-key';
      final service = WebSearchService(
        configStore: config,
        client: MockClient((request) async {
          expect(request.headers['authorization'], 'Bearer firecrawl-key');
          return http.Response(
            jsonEncode({
              'data': {
                'web': [
                  for (var index = 0; index < 3; index++)
                    {
                      'title': 'Result $index',
                      'url': 'https://example.com/$index',
                      'description': 'Snippet $index',
                    },
                ],
              },
            }),
            200,
          );
        }),
      );

      final results = await service.search('keyed search');

      expect(results, hasLength(3));
    });

    test('reports an explicit error when every configured provider fails',
        () async {
      final config = _MemoryAiConfigStore()
        ..values[WebSearchConfigKeys.tavilyApiKey] = 'bad-tavily-key';
      final service = WebSearchService(
        configStore: config,
        client: MockClient((request) async => http.Response('unavailable', 503)),
      );

      await expectLater(
        service.search('unavailable topic'),
        throwsA(
          isA<WebSearchException>().having(
            (error) => error.message,
            'message',
            allOf(contains('Tavily: HTTP 503'), contains('Firecrawl: HTTP 503')),
          ),
        ),
      );
    });
  });
}

class _MemoryAiConfigStore implements AiConfigStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }

  @override
  Future<List<String>> readApiKeys() async => [];

  @override
  Future<void> writeApiKeys(List<String> apiKeys) async {}
}
