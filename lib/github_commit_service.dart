import 'dart:convert';

import 'package:http/http.dart' as http;

class GitHubCommit {
  const GitHubCommit({
    required this.sha,
    required this.url,
    required this.username,
    required this.avatarUrl,
    required this.message,
    required this.committedAt,
    required this.filesChanged,
    required this.additions,
    required this.deletions,
    required this.changes,
  });

  final String sha;
  final String url;
  final String username;
  final String? avatarUrl;
  final String message;
  final DateTime committedAt;
  final int filesChanged;
  final int additions;
  final int deletions;
  final int changes;

  String get shortSha => sha.substring(0, sha.length < 7 ? sha.length : 7);
}

class GitHubCommitService {
  GitHubCommitService({
    http.Client? client,
    Uri? apiBaseUri,
    this.requestTimeout = const Duration(seconds: 10),
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       _apiBaseUri = apiBaseUri ?? Uri.https('api.github.com', '');

  static const _repositoryPath = '/repos/neveerlabs/Sara';
  static const _headers = {
    'Accept': 'application/vnd.github+json',
    'X-GitHub-Api-Version': '2022-11-28',
    'User-Agent': 'Sara-Desktop',
  };

  final http.Client _client;
  final bool _ownsClient;
  final Uri _apiBaseUri;
  final Duration requestTimeout;

  Future<GitHubCommit> fetchLatestCommit() async {
    final listResponse = await _get(
      _apiBaseUri.resolve('$_repositoryPath/commits?per_page=1'),
    );
    final commits = _decodeList(listResponse.body, 'commit list');
    if (commits.isEmpty) {
      throw const FormatException('The repository has no commits.');
    }

    final latest = _decodeObject(commits.first, 'latest commit');
    final sha = _readString(latest['sha'], 'commit SHA');
    final detailsResponse = await _get(
      _apiBaseUri.resolve('$_repositoryPath/commits/$sha'),
    );
    final details = _decodeObject(
      jsonDecode(detailsResponse.body),
      'commit details',
    );
    final actualSha = _readString(details['sha'], 'commit SHA');
    if (actualSha != sha) {
      throw const FormatException('GitHub returned mismatched commit details.');
    }

    final gitCommit = _decodeObject(latest['commit'], 'commit metadata');
    final gitAuthor = _decodeObject(gitCommit['author'], 'commit author');
    final githubAuthor = latest['author'] is Map
        ? _decodeObject(latest['author'], 'GitHub author')
        : latest['committer'] is Map
        ? _decodeObject(latest['committer'], 'GitHub committer')
        : null;
    final date = DateTime.tryParse(
      _readString(gitAuthor['date'], 'commit date'),
    );
    if (date == null) {
      throw const FormatException('GitHub returned an invalid commit date.');
    }

    final stats = _decodeObject(details['stats'], 'commit statistics');
    final files = details['files'];
    if (files is! List) {
      throw const FormatException('GitHub returned invalid changed-file data.');
    }

    return GitHubCommit(
      sha: sha,
      url: 'https://github.com/neveerlabs/Sara/commit/$sha',
      username:
          _optionalString(githubAuthor?['login']) ?? 'Unknown contributor',
      avatarUrl: _validatedAvatarUrl(githubAuthor?['avatar_url']),
      message: _readString(gitCommit['message'], 'commit message'),
      committedAt: date,
      filesChanged: files.length,
      additions: _readInteger(stats['additions'], 'insertions'),
      deletions: _readInteger(stats['deletions'], 'deletions'),
      changes: _readInteger(stats['total'], 'total changes'),
    );
  }

  void close() {
    if (_ownsClient) _client.close();
  }

  Future<http.Response> _get(Uri uri) async {
    final response = await _client
        .get(uri, headers: _headers)
        .timeout(requestTimeout);
    if (response.statusCode != 200) {
      throw GitHubCommitException(
        'GitHub returned HTTP ${response.statusCode} while loading the latest commit.',
      );
    }
    return response;
  }
}

class GitHubCommitException implements Exception {
  const GitHubCommitException(this.message);

  final String message;

  @override
  String toString() => message;
}

String formatCommitTimeAgo(DateTime committedAt, {DateTime? now}) {
  final difference = (now ?? DateTime.now()).difference(committedAt.toLocal());
  final minutes = difference.inMinutes;
  if (minutes < 60) return _timeAgo(minutes, 'minute');

  final hours = difference.inHours;
  if (hours < 24) return _timeAgo(hours, 'hour');

  final days = difference.inDays;
  if (days < 7) return _timeAgo(days, 'day');
  if (days < 30) return _timeAgo(days ~/ 7, 'week');
  if (days < 365) return _timeAgo(days ~/ 30, 'month');
  return _timeAgo(days ~/ 365, 'year');
}

String formatCommitDateTime(DateTime committedAt) {
  const months = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];
  final localDate = committedAt.toLocal();
  final hour = localDate.hour % 12 == 0 ? 12 : localDate.hour % 12;
  final minute = localDate.minute.toString().padLeft(2, '0');
  final meridiem = localDate.hour >= 12 ? 'PM' : 'AM';
  return '${months[localDate.month - 1]} ${localDate.day}, '
      '${localDate.year} at $hour:$minute $meridiem';
}

String formatCommitCount(int value) {
  return value.toString().replaceAllMapped(
    RegExp(r'\B(?=(\d{3})+(?!\d))'),
    (match) => ',',
  );
}

String _timeAgo(int value, String unit) {
  final count = value < 1 ? 1 : value;
  return '$count $unit${count == 1 ? '' : 's'} ago';
}

List<Object?> _decodeList(String body, String label) {
  final decoded = jsonDecode(body);
  if (decoded is! List)
    throw FormatException('GitHub returned invalid $label.');
  return decoded;
}

Map<String, dynamic> _decodeObject(Object? value, String label) {
  if (value is! Map) throw FormatException('GitHub returned invalid $label.');
  return Map<String, dynamic>.from(value);
}

String _readString(Object? value, String label) {
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('GitHub returned an invalid $label.');
  }
  return value;
}

String? _optionalString(Object? value) =>
    value is String && value.trim().isNotEmpty ? value : null;

String? _validatedAvatarUrl(Object? value) {
  final rawUrl = _optionalString(value);
  if (rawUrl == null) return null;
  final uri = Uri.tryParse(rawUrl);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host != 'avatars.githubusercontent.com' ||
      uri.userInfo.isNotEmpty) {
    return null;
  }
  return uri.toString();
}

int _readInteger(Object? value, String label) {
  if (value is! int || value < 0) {
    throw FormatException('GitHub returned an invalid $label count.');
  }
  return value;
}
