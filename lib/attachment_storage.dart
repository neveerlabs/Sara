import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'attachment_file_policy.dart';
import 'chat_attachment.dart';

class AttachmentStorage {
  AttachmentStorage({Future<Directory> Function()? supportDirectoryProvider})
    : _supportDirectoryProvider =
          supportDirectoryProvider ?? getApplicationSupportDirectory;

  static const retention = Duration(hours: 24);
  static const _uuid = Uuid();

  final Future<Directory> Function() _supportDirectoryProvider;

  Future<String> directoryPath() async {
    final supportDirectory = await _supportDirectoryProvider();
    return path.normalize(
      path.absolute(path.join(supportDirectory.path, 'Sara', 'attachments')),
    );
  }

  Future<ChatAttachment> copyFile(
    String sourcePath, {
    String? name,
    String? mimeType,
  }) async {
    if (isSensitiveAttachmentPath(sourcePath)) {
      throw FileSystemException(
        'Sensitive files cannot be attached.',
        sourcePath,
      );
    }
    final source = File(sourcePath);
    if (!await source.exists()) {
      throw FileSystemException(
        'Attachment source file does not exist.',
        sourcePath,
      );
    }
    final directory = Directory(await directoryPath());
    await directory.create(recursive: true);
    final id = _uuid.v4();
    final file = File(
      path.join(directory.path, '$id${path.extension(sourcePath)}'),
    );
    try {
      await source.copy(file.path);
      final now = DateTime.now().toUtc();
      await file.setLastModified(now);
      return _attachment(
        id: id,
        filePath: file.path,
        name: name ?? path.basename(sourcePath),
        mimeType: mimeType ?? attachmentMimeType(sourcePath),
        now: now,
      );
    } catch (_) {
      if (await file.exists()) await file.delete();
      rethrow;
    }
  }

  Future<ChatAttachment> copyAttachment(ChatAttachment attachment) async {
    final sourcePath = attachment.path;
    if (sourcePath == null) {
      return ChatAttachment(
        id: _uuid.v4(),
        path: null,
        name: attachment.name,
        mimeType: attachment.mimeType,
        expiresAtUtc: attachment.expiresAtUtc,
        isAppManagedCopy: attachment.isAppManagedCopy,
      );
    }
    if (attachment.isExpiredAt(DateTime.now().toUtc().millisecondsSinceEpoch)) {
      return ChatAttachment(
        id: _uuid.v4(),
        path: null,
        name: attachment.name,
        mimeType: attachment.mimeType,
        expiresAtUtc: attachment.expiresAtUtc,
        isAppManagedCopy: attachment.isAppManagedCopy,
      );
    }
    if (!await File(sourcePath).exists()) {
      return ChatAttachment(
        id: _uuid.v4(),
        path: null,
        name: attachment.name,
        mimeType: attachment.mimeType,
        expiresAtUtc: attachment.expiresAtUtc,
        isAppManagedCopy: attachment.isAppManagedCopy,
      );
    }
    return copyFile(
      sourcePath,
      name: attachment.name,
      mimeType: attachment.mimeType,
    );
  }

  Future<ChatAttachment> saveImageBytes(
    Uint8List bytes, {
    required String name,
  }) async {
    final decodedImage = img.decodeImage(bytes);
    if (decodedImage == null) {
      throw StateError('Attachment image could not be decoded.');
    }
    return _save(
      bytes: Uint8List.fromList(img.encodePng(decodedImage)),
      extension: '.png',
      name: name,
      mimeType: 'image/png',
    );
  }

  Future<void> deleteManagedFiles(Iterable<String> filePaths) async {
    final directory = await directoryPath();
    for (final filePath in filePaths.toSet()) {
      final absoluteFilePath = path.normalize(path.absolute(filePath));
      if (!path.isWithin(directory, absoluteFilePath)) {
        throw StateError(
          'Refusing to delete an attachment outside Sara storage.',
        );
      }
      final file = File(absoluteFilePath);
      if (await file.exists()) await file.delete();
    }
  }

  Future<void> deleteExpiredOrphans({
    required int nowUtc,
    required Set<String> retainedPaths,
  }) async {
    final directoryPath = await this.directoryPath();
    final directory = Directory(directoryPath);
    if (!await directory.exists()) return;

    final cutoff = DateTime.fromMillisecondsSinceEpoch(
      nowUtc,
      isUtc: true,
    ).subtract(retention);
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) continue;
      final absoluteFilePath = path.normalize(path.absolute(entity.path));
      if (!path.isWithin(directoryPath, absoluteFilePath)) {
        throw StateError('Attachment file resolved outside Sara storage.');
      }
      if (retainedPaths.contains(absoluteFilePath)) continue;
      if ((await entity.lastModified()).toUtc().isBefore(cutoff)) {
        await entity.delete();
      }
    }
  }

  Future<ChatAttachment> _save({
    required Uint8List bytes,
    required String extension,
    required String name,
    required String mimeType,
  }) async {
    final directory = Directory(await directoryPath());
    await directory.create(recursive: true);
    final id = _uuid.v4();
    final file = File(path.join(directory.path, '$id$extension'));
    await file.writeAsBytes(bytes, flush: true);
    final now = DateTime.now().toUtc();
    await file.setLastModified(now);
    return _attachment(
      id: id,
      filePath: file.path,
      name: name,
      mimeType: mimeType,
      now: now,
    );
  }

  ChatAttachment _attachment({
    required String id,
    required String filePath,
    required String name,
    required String mimeType,
    required DateTime now,
  }) {
    return ChatAttachment(
      id: id,
      path: filePath,
      name: name,
      mimeType: mimeType,
      expiresAtUtc: now.add(retention).millisecondsSinceEpoch,
      isAppManagedCopy: true,
    );
  }
}
