import 'dart:io';

import 'package:path/path.dart' as path;

import 'message_database.dart';

class CameraCaptureCache {
  const CameraCaptureCache._();

  static Future<void> clear({
    required MessageStore messageStore,
    required Directory supportDirectory,
    required Directory cacheDirectory,
  }) async {
    final saraSupportDirectory =
        path.normalize(path.absolute(path.join(supportDirectory.path, 'Sara')));
    final saraCacheDirectory =
        path.normalize(path.absolute(path.join(cacheDirectory.path, 'Sara')));
    final clipboardDirectory =
        path.join(saraSupportDirectory, 'clipboard-attachments');
    final cameraDirectories = [
      path.normalize(path.join(saraCacheDirectory, 'camera-attachments')),
      path.normalize(path.join(saraSupportDirectory, 'camera-attachments')),
      path.normalize(path.join(saraCacheDirectory, 'autonomous-camera')),
    ];
    final storedAttachments = await messageStore.loadAttachments();
    final cameraPaths = <String>{};
    for (final attachment
        in storedAttachments.values.expand((items) => items)) {
      if (!attachment.isClipboardCopy ||
          attachment.name != 'camera-photo.png' ||
          attachment.path == null) {
        continue;
      }
      final absoluteFilePath = path.normalize(path.absolute(attachment.path!));
      if (!path.isWithin(clipboardDirectory, absoluteFilePath) &&
          !cameraDirectories.any(
            (directory) => path.isWithin(directory, absoluteFilePath),
          )) {
        continue;
      }
      cameraPaths.add(absoluteFilePath);
      final file = File(absoluteFilePath);
      if (await file.exists()) await file.delete();
    }

    for (final cameraDirectory in cameraDirectories) {
      final directory = Directory(cameraDirectory);
      if (!await directory.exists()) continue;
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is! File) continue;
        final absoluteFilePath = path.normalize(path.absolute(entity.path));
        if (!path.isWithin(cameraDirectory, absoluteFilePath)) {
          throw StateError(
            'Refusing to delete camera cache file outside the app folder.',
          );
        }
        await entity.delete();
      }
    }
    if (cameraPaths.isNotEmpty) {
      await messageStore.clearAttachmentPaths(cameraPaths.toList());
    }
  }
}
