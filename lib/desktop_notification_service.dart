import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

typedef DesktopNotificationRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
);

class DesktopNotificationService {
  const DesktopNotificationService({
    DesktopNotificationRunner? runner,
    bool? isLinux,
  })  : _runner = runner ?? Process.run,
        _isLinux = isLinux;

  final DesktopNotificationRunner _runner;
  final bool? _isLinux;

  Future<void> show({
    required String title,
    required String body,
  }) async {
    if (!(_isLinux ?? Platform.isLinux)) return;
    try {
      final result = await _runner(
        'notify-send',
        [
          '--app-name=Sara',
          '--expire-time=8000',
          title,
          body,
        ],
      ).timeout(const Duration(seconds: 5));
      if (result.exitCode != 0) {
        throw ProcessException(
          'notify-send',
          ['--app-name=Sara', '--expire-time=8000', title, body],
          result.stderr.toString(),
          result.exitCode,
        );
      }
    } on ProcessException catch (error) {
      debugPrint('Could not show desktop notification: $error');
    } on TimeoutException catch (error) {
      debugPrint('Desktop notification timed out: $error');
    }
  }
}
