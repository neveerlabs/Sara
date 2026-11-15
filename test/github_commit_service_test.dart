import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sara_desktop/github_commit_service.dart';

void main() {
  test(
    'loads the latest commit author, timestamp, and change statistics',
    () async {
      final requests = <Uri>[];
      final client = MockClient((request) async {
        requests.add(request.url);
        if (request.url.path.endsWith('/commits')) {
          return http.Response(
            jsonEncode([
              {
                'sha': 'abcdef1234567890',
                'commit': {
                  'message': 'feat: add latest commit card\n\nMore details',
                  'author': {
                    'date': '2026-11-15T00:41:59Z',
                    'name': 'neveerlabs',
                  },
                },
                'author': {
                  'login': 'neveerlabs',
                  'avatar_url': 'https://avatars.githubusercontent.com/u/123',
                },
              },
            ]),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'sha': 'abcdef1234567890',
            'stats': {'additions': 2508, 'deletions': 666, 'total': 3174},
            'files': List.generate(11, (_) => <String, Object?>{}),
          }),
          200,
        );
      });
      final service = GitHubCommitService(client: client);
      addTearDown(service.close);

      final commit = await service.fetchLatestCommit();

      expect(commit.shortSha, 'abcdef1');
      expect(commit.username, 'neveerlabs');
      expect(commit.avatarUrl, 'https://avatars.githubusercontent.com/u/123');
      expect(commit.message, startsWith('feat: add latest commit card'));
      expect(commit.committedAt, DateTime.utc(2026, 11, 15, 0, 41, 59));
      expect(commit.filesChanged, 11);
      expect(commit.additions, 2508);
      expect(commit.deletions, 666);
      expect(commit.changes, 3174);
      expect(requests, hasLength(2));
      expect(requests.first.queryParameters['per_page'], '1');
      expect(requests.last.path, endsWith('/commits/abcdef1234567890'));
    },
  );

  test('fails explicitly when GitHub cannot return the commit list', () async {
    final client = MockClient((_) async => http.Response('rate limited', 403));
    final service = GitHubCommitService(client: client);
    addTearDown(service.close);

    await expectLater(
      service.fetchLatestCommit(),
      throwsA(
        isA<GitHubCommitException>().having(
          (error) => error.message,
          'message',
          contains('HTTP 403'),
        ),
      ),
    );
  });

  test('formats relative age and commit counts in English', () {
    final now = DateTime(2026, 11, 15, 12);

    expect(
      formatCommitTimeAgo(now.subtract(const Duration(minutes: 1)), now: now),
      '1 minute ago',
    );
    expect(
      formatCommitTimeAgo(now.subtract(const Duration(hours: 2)), now: now),
      '2 hours ago',
    );
    expect(
      formatCommitTimeAgo(now.subtract(const Duration(days: 14)), now: now),
      '2 weeks ago',
    );
    expect(
      formatCommitTimeAgo(now.subtract(const Duration(days: 60)), now: now),
      '2 months ago',
    );
    expect(formatCommitCount(12687), '12,687');
    expect(
      formatCommitDateTime(DateTime(2026, 11, 15, 21, 5)),
      'November 15, 2026 at 9:05 PM',
    );
  });
}
