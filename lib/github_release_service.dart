import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;

class GitHubRelease {
  const GitHubRelease({
    required this.tagName,
    required this.version,
    required this.releaseUrl,
    required this.debUrl,
    required this.sha256,
    required this.assetSize,
  });

  final String tagName;
  final String version;
  final Uri releaseUrl;
  final Uri debUrl;
  final String sha256;
  final int assetSize;

  bool isNewerThan(String currentVersion) {
    final releaseParts = _versionParts(version);
    final currentParts = _versionParts(currentVersion);
    for (var index = 0; index < releaseParts.length; index++) {
      if (releaseParts[index] != currentParts[index]) {
        return releaseParts[index] > currentParts[index];
      }
    }
    return false;
  }
}

class GitHubReleaseService {
  GitHubReleaseService({
    http.Client? client,
    Uri? apiBaseUri,
    this.requestTimeout = const Duration(seconds: 20),
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       _apiBaseUri = apiBaseUri ?? Uri.https('api.github.com', '');

  static const _repositoryPath = '/repos/neveerlabs/Sara';
  static const _headers = {
    'Accept': 'application/vnd.github+json',
    'X-GitHub-Api-Version': '2022-11-28',
    'User-Agent': 'Sara-Desktop',
  };
  static const _maxAssetSize = 128 * 1024 * 1024;
  static const _backupMarkerName = '.sara-update-backup';

  final http.Client _client;
  final bool _ownsClient;
  final Uri _apiBaseUri;
  final Duration requestTimeout;

  Future<GitHubRelease> fetchLatestRelease() async {
    final response = await _client
        .get(
          _apiBaseUri.resolve('$_repositoryPath/releases/latest'),
          headers: _headers,
        )
        .timeout(requestTimeout);
    if (response.statusCode != 200) {
      throw GitHubReleaseException(
        'GitHub returned HTTP ${response.statusCode} while checking for updates.',
      );
    }

    final release = _decodeObject(jsonDecode(response.body), 'release');
    final tagName = _readString(release['tag_name'], 'release tag');
    final version = _versionFromTag(tagName);
    final releaseUrl = _validatedGitHubUrl(
      release['html_url'],
      '/neveerlabs/Sara/releases/tag/$tagName',
      'release URL',
    );
    final assets = release['assets'];
    if (assets is! List) {
      throw const FormatException('GitHub returned invalid release assets.');
    }
    final asset = assets
        .whereType<Map>()
        .map(Map<String, dynamic>.from)
        .where((asset) => asset['name'] == 'sara_linux_amd64.deb')
        .firstOrNull;
    if (asset == null) {
      throw const FormatException(
        'The latest release does not contain sara_linux_amd64.deb.',
      );
    }

    final digest = _readString(asset['digest'], 'asset SHA-256 digest');
    final digestMatch = RegExp(
      r'^sha256:([a-fA-F0-9]{64})$',
    ).firstMatch(digest);
    if (digestMatch == null) {
      throw const FormatException(
        'GitHub returned an invalid release asset SHA-256 digest.',
      );
    }
    final size = _readInteger(asset['size'], 'asset size');
    if (size == 0 || size > _maxAssetSize) {
      throw const FormatException('The release asset size is not supported.');
    }

    return GitHubRelease(
      tagName: tagName,
      version: version,
      releaseUrl: releaseUrl,
      debUrl: _validatedGitHubUrl(
        asset['browser_download_url'],
        '/neveerlabs/Sara/releases/download/$tagName/sara_linux_amd64.deb',
        'release asset URL',
      ),
      sha256: digestMatch.group(1)!.toLowerCase(),
      assetSize: size,
    );
  }

  Future<void> downloadAndInstall(
    GitHubRelease release, {
    required Directory installDirectory,
  }) async {
    if (!Platform.isLinux || Abi.current() != Abi.linuxX64) {
      throw UnsupportedError(
        'Automatic updates are supported only on Linux amd64.',
      );
    }

    final executablePath = path.normalize(Platform.resolvedExecutable);
    final installPath = path.normalize(installDirectory.absolute.path);
    if (path.dirname(executablePath) != installPath ||
        path.basename(executablePath) != 'sara') {
      throw StateError(
        'The current Sara installation path could not be verified.',
      );
    }

    final workspace = await Directory.systemTemp.createTemp('sara-update-');
    try {
      final debFile = File(path.join(workspace.path, 'sara_linux_amd64.deb'));
      final response = await _client
          .get(release.debUrl)
          .timeout(requestTimeout);
      if (response.statusCode != 200) {
        throw GitHubReleaseException(
          'GitHub returned HTTP ${response.statusCode} while downloading the update.',
        );
      }
      final bytes = response.bodyBytes;
      if (bytes.length != release.assetSize) {
        throw const FormatException(
          'The downloaded release asset size does not match GitHub.',
        );
      }
      final actualDigest = sha256.convert(bytes).toString();
      if (actualDigest != release.sha256) {
        throw const FormatException(
          'The downloaded release asset failed SHA-256 verification.',
        );
      }
      await debFile.writeAsBytes(bytes, flush: true);

      final packageFields = await _runChecked('dpkg-deb', ['-f', debFile.path]);
      final control = _parseControlFields(packageFields);
      if (control['Package'] != 'sara' ||
          control['Architecture'] != 'amd64' ||
          !_packageVersionMatches(control['Version'], release.version)) {
        throw const FormatException(
          'The downloaded Debian package does not match the GitHub release.',
        );
      }

      final extracted = Directory(path.join(workspace.path, 'extracted'));
      await extracted.create();
      await _runChecked('dpkg-deb', ['-x', debFile.path, extracted.path]);
      final packageBundle = Directory(path.join(extracted.path, 'opt', 'sara'));
      await _validateBundle(packageBundle, release.version);

      final parent = Directory(installPath).parent;
      final stagedBundle = await parent.createTemp('.sara-update-new-');
      final backup = Directory(path.join(parent.path, '.sara-update-previous'));
      try {
        await _runChecked('cp', [
          '-a',
          '${packageBundle.path}${path.separator}.',
          '${stagedBundle.path}${path.separator}',
        ]);
        await _validateBundle(stagedBundle, release.version);
        if (await backup.exists()) {
          throw StateError(
            'A previous Sara update backup exists and could not be removed safely.',
          );
        }

        await File(
          path.join(installPath, _backupMarkerName),
        ).writeAsString('$pid\n', flush: true);
        try {
          await Directory(installPath).rename(backup.path);
        } catch (_) {
          final marker = File(path.join(installPath, _backupMarkerName));
          if (await marker.exists()) await marker.delete();
          rethrow;
        }
        try {
          await stagedBundle.rename(installPath);
          await _validateBundle(Directory(installPath), release.version);
        } catch (error) {
          try {
            final failedBundle = Directory(installPath);
            if (await failedBundle.exists()) {
              await failedBundle.delete(recursive: true);
            }
            await backup.rename(installPath);
            final marker = File(path.join(installPath, _backupMarkerName));
            if (await marker.exists()) await marker.delete();
          } catch (rollbackError) {
            throw StateError(
              'Could not install the update: $error. '
              'Restoring the previous Sara installation also failed: $rollbackError',
            );
          }
          rethrow;
        }
      } finally {
        if (await stagedBundle.exists()) {
          await stagedBundle.delete(recursive: true);
        }
      }
    } finally {
      await workspace.delete(recursive: true);
    }
  }

  Future<void> cleanupPreviousInstall(Directory installDirectory) async {
    final backup = Directory(
      path.join(installDirectory.absolute.parent.path, '.sara-update-previous'),
    );
    if (!await backup.exists()) return;
    final marker = File(path.join(backup.path, _backupMarkerName));
    if (!await marker.exists()) return;
    final previousPid = int.tryParse(await marker.readAsString());
    if (previousPid == null || await Directory('/proc/$previousPid').exists()) {
      return;
    }
    await backup.delete(recursive: true);
  }

  void close() {
    if (_ownsClient) _client.close();
  }

  Future<String> _runChecked(String executable, List<String> arguments) async {
    final result = await Process.run(
      executable,
      arguments,
    ).timeout(requestTimeout);
    if (result.exitCode != 0) {
      throw ProcessException(
        executable,
        arguments,
        result.stderr.toString(),
        result.exitCode,
      );
    }
    return result.stdout.toString();
  }
}

class GitHubReleaseException implements Exception {
  const GitHubReleaseException(this.message);

  final String message;

  @override
  String toString() => message;
}

String _versionFromTag(String tagName) {
  final match = RegExp(r'^v(\d+)\.(\d+)\.(\d+)$').firstMatch(tagName);
  if (match == null) {
    throw const FormatException(
      'The latest GitHub release tag is not a stable vX.Y.Z version.',
    );
  }
  return '${match[1]}.${match[2]}.${match[3]}';
}

List<int> _versionParts(String version) {
  final match = RegExp(
    r'^v?(\d+)\.(\d+)\.(\d+)(?:\+\d+)?$',
  ).firstMatch(version);
  if (match == null) {
    throw FormatException('Invalid Sara version: $version');
  }
  return [int.parse(match[1]!), int.parse(match[2]!), int.parse(match[3]!)];
}

Uri _validatedGitHubUrl(Object? rawUrl, String expectedPath, String label) {
  final value = _readString(rawUrl, label);
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host != 'github.com' ||
      uri.userInfo.isNotEmpty ||
      uri.path != expectedPath ||
      uri.hasQuery ||
      uri.hasFragment) {
    throw FormatException('GitHub returned an invalid $label.');
  }
  return uri;
}

Map<String, dynamic> _decodeObject(Object? value, String label) {
  if (value is! Map) {
    throw FormatException('GitHub returned an invalid $label.');
  }
  return Map<String, dynamic>.from(value);
}

String _readString(Object? value, String label) {
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('GitHub returned an invalid $label.');
  }
  return value;
}

int _readInteger(Object? value, String label) {
  if (value is! int || value < 0) {
    throw FormatException('GitHub returned an invalid $label.');
  }
  return value;
}

Map<String, String> _parseControlFields(String control) {
  final fields = <String, String>{};
  for (final line in const LineSplitter().convert(control)) {
    final separator = line.indexOf(':');
    if (separator <= 0) continue;
    fields[line.substring(0, separator)] = line.substring(separator + 1).trim();
  }
  return fields;
}

bool _packageVersionMatches(String? packageVersion, String releaseVersion) =>
    packageVersion == releaseVersion ||
    packageVersion?.startsWith('$releaseVersion+') == true;

Future<void> _validateBundle(Directory bundle, String releaseVersion) async {
  if (!await bundle.exists() ||
      !await File(path.join(bundle.path, 'sara')).exists()) {
    throw const FormatException('The Debian package contains no Sara bundle.');
  }
  final versionFile = File(
    path.join(bundle.path, 'data', 'flutter_assets', 'version.json'),
  );
  if (!await versionFile.exists()) {
    throw const FormatException('The Sara bundle has no version metadata.');
  }
  final metadata = _decodeObject(
    jsonDecode(await versionFile.readAsString()),
    'bundle version metadata',
  );
  if (metadata['version'] != releaseVersion) {
    throw const FormatException(
      'The Sara bundle version does not match the GitHub release tag.',
    );
  }
}
