import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'message_database.dart';

class BackupRestoreResult {
  const BackupRestoreResult(this.cleanupErrors);

  final List<String> cleanupErrors;
}

class SaraBackupService {
  static const _format = 'sara-desktop-backup';
  static const _version = 2;
  static const _previousVersion = 1;
  static const _uuid = Uuid();

  SaraBackupService({
    Future<Directory> Function()? supportDirectoryProvider,
  }) : _supportDirectoryProvider =
            supportDirectoryProvider ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _supportDirectoryProvider;

  Future<Uint8List> createBackup(MessageStore store) async {
    final tables = await store.exportBackupData();
    final clipboardDirectory = await _clipboardDirectoryPath();
    final attachmentFiles = <String, Object?>{};
    final attachments = tables['message_attachment'];
    if (attachments is! List) {
      throw const FormatException('Could not read attachment records.');
    }

    for (final attachment in attachments) {
      if (attachment is! Map || attachment['path'] is! String) {
        continue;
      }
      final filePath = attachment['path']! as String;
      final absoluteFilePath = path.normalize(path.absolute(filePath));
      if (attachment['is_clipboard_copy'] == 1 &&
          !path.isWithin(clipboardDirectory, absoluteFilePath)) {
        throw StateError(
          'Refusing to include a clipboard attachment outside Sara storage.',
        );
      }
      final file = File(absoluteFilePath);
      if (!await file.exists()) continue;
      final messageId = attachment['message_id'];
      final attachmentId = attachment['id'];
      if (messageId is! String || attachmentId is! String) {
        throw const FormatException('Attachment identifiers are invalid.');
      }
      attachmentFiles['$messageId:$attachmentId'] = {
        'extension': path.extension(filePath),
        'data': base64Encode(await file.readAsBytes()),
      };
    }

    final payload = <String, Object?>{
      'format': _format,
      'version': _version,
      'created_at_utc': DateTime.now().toUtc().millisecondsSinceEpoch,
      'database': tables,
      'attachment_files': attachmentFiles,
    };
    return Uint8List.fromList(utf8.encode(jsonEncode(payload)));
  }

  Future<BackupRestoreResult> restoreBackup(
    MessageStore store,
    Uint8List backupBytes,
  ) async {
    final decoded = jsonDecode(utf8.decode(backupBytes));
    if (decoded is! Map ||
        decoded['format'] != _format ||
        !{_previousVersion, _version}.contains(decoded['version']) ||
        decoded['database'] is! Map ||
        decoded['attachment_files'] is! Map) {
      throw const FormatException('This is not a supported Sara backup file.');
    }

    final tables = Map<String, Object?>.from(decoded['database'] as Map);
    final encodedFiles = decoded['attachment_files'] as Map;
    if (encodedFiles.keys.any((key) => key is! String)) {
      throw const FormatException('Backup attachment index is invalid.');
    }

    final existingAttachments = await store.loadAttachments();
    final oldClipboardPaths = existingAttachments.values
        .expand((items) => items)
        .where((attachment) => attachment.isClipboardCopy)
        .map((attachment) => attachment.path)
        .whereType<String>()
        .toSet();
    final clipboardDirectory = await _clipboardDirectoryPath();
    final restoredPaths = <String, String>{};
    final createdFiles = <File>[];
    final attachmentRows = tables['message_attachment'];
    if (attachmentRows is! List) {
      throw const FormatException('Backup attachment records are invalid.');
    }
    final validAttachmentKeys = attachmentRows
        .whereType<Map>()
        .map((row) => '${row['message_id']}:${row['id']}')
        .toSet();
    final decodedFiles = <String, (String, Uint8List)>{};
    try {
      for (final entry in encodedFiles.entries) {
        if (!validAttachmentKeys.contains(entry.key)) {
          throw const FormatException(
            'Backup contains an unlinked attachment file.',
          );
        }
        final value = entry.value;
        if (value is! Map ||
            value['data'] is! String ||
            value['extension'] is! String) {
          throw const FormatException('Backup attachment data is invalid.');
        }
        final extension = value['extension']! as String;
        final safeExtension =
            RegExp(r'^\.[A-Za-z0-9]{1,10}$').hasMatch(extension)
                ? extension
                : '.bin';
        decodedFiles[entry.key as String] = (
          safeExtension,
          base64Decode(value['data']! as String),
        );
      }

      await Directory(clipboardDirectory).create(recursive: true);
      for (final entry in decodedFiles.entries) {
        final file = File(path.join(
          clipboardDirectory,
          '${_uuid.v4()}${entry.value.$1}',
        ));
        createdFiles.add(file);
        await file.writeAsBytes(entry.value.$2, flush: true);
        restoredPaths[entry.key] = file.path;
      }

      await store.importBackupData(tables, clipboardPaths: restoredPaths);
    } catch (error) {
      final cleanupErrors = <String>[];
      for (final file in createdFiles) {
        try {
          if (await file.exists()) await file.delete();
        } catch (cleanupError) {
          cleanupErrors.add('${file.path}: $cleanupError');
        }
      }
      if (cleanupErrors.isNotEmpty) {
        throw StateError(
          'Backup restore failed: $error. Temporary files could not be '
          'cleaned up: ${cleanupErrors.join('; ')}',
        );
      }
      rethrow;
    }

    final cleanupErrors = <String>[];
    for (final oldPath in oldClipboardPaths) {
      final absolutePath = path.normalize(path.absolute(oldPath));
      if (!path.isWithin(clipboardDirectory, absolutePath)) {
        cleanupErrors.add(
          '$oldPath: refusing to delete a file outside Sara storage',
        );
        continue;
      }
      try {
        final file = File(absolutePath);
        if (await file.exists()) await file.delete();
      } catch (error) {
        cleanupErrors.add('$oldPath: $error');
      }
    }
    return BackupRestoreResult(cleanupErrors);
  }

  Future<String> _clipboardDirectoryPath() async {
    final supportDirectory = await _supportDirectoryProvider();
    return path.normalize(path.absolute(
      path.join(supportDirectory.path, 'Sara', 'clipboard-attachments'),
    ));
  }
}
