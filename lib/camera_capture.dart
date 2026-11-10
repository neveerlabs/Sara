import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

typedef CameraSessionFactory = Future<CameraPreviewSession> Function();

class CameraFrame {
  CameraFrame({
    required this.bytes,
    required Future<void> Function() dispose,
  }) : _dispose = dispose;

  final Uint8List bytes;
  final Future<void> Function() _dispose;
  Future<void>? _disposing;

  Future<void> dispose() => _disposing ??= _dispose();
}

class CameraPreviewSession {
  CameraPreviewSession({
    required this.frames,
    required Future<void> Function() close,
  }) : _close = close;

  final Stream<Uint8List> frames;
  final Future<void> Function() _close;
  Future<void>? _closing;

  Future<void> dispose() => _closing ??= _close();

  static Future<CameraPreviewSession> open() async {
    if (!Platform.isLinux) {
      throw UnsupportedError('Camera capture is only available on Linux.');
    }

    final devices = await Directory('/dev')
        .list()
        .where((entity) =>
            RegExp(r'^video\d+$').hasMatch(entity.uri.pathSegments.last))
        .toList();
    devices.sort((left, right) {
      final leftNumber = int.parse(
        RegExp(r'\d+$').firstMatch(left.path)!.group(0)!,
      );
      final rightNumber = int.parse(
        RegExp(r'\d+$').firstMatch(right.path)!.group(0)!,
      );
      return leftNumber.compareTo(rightNumber);
    });
    if (devices.isEmpty) throw StateError('No camera device was found.');

    final failures = <String>[];
    for (final device in devices) {
      final session = await _openDevice(device.path, failures);
      if (session != null) return session;
    }
    throw StateError(
      failures.isEmpty
          ? 'No camera device could be opened.'
          : failures.join('\n'),
    );
  }

  static Future<CameraPreviewSession?> _openDevice(
    String devicePath,
    List<String> failures,
  ) async {
    Process? process;
    StreamSubscription<List<int>>? stdoutSubscription;
    StreamSubscription<List<int>>? stderrSubscription;
    StreamController<Uint8List>? frames;
    final firstFrame = Completer<void>();
    var stderr = '';
    try {
      process = await Process.start(
        'ffmpeg',
        [
          '-hide_banner',
          '-loglevel',
          'error',
          '-f',
          'v4l2',
          '-framerate',
          '15',
          '-video_size',
          '640x480',
          '-i',
          devicePath,
          '-vf',
          'fps=8,scale=640:480:force_original_aspect_ratio=decrease',
          '-f',
          'image2pipe',
          '-vcodec',
          'mjpeg',
          '-q:v',
          '5',
          'pipe:1',
        ],
      );
      frames = StreamController<Uint8List>();
      final controller = frames;
      final parser = _JpegFrameParser((frame) {
        if (!firstFrame.isCompleted) firstFrame.complete();
        if (!controller.isClosed) controller.add(frame);
      });
      stdoutSubscription = process.stdout.listen(
        parser.add,
        onError: (Object error, StackTrace stackTrace) {
          if (!firstFrame.isCompleted) firstFrame.completeError(error);
          if (!controller.isClosed) controller.addError(error, stackTrace);
        },
      );
      stderrSubscription = process.stderr.listen((chunk) {
        stderr = (stderr + utf8.decode(chunk, allowMalformed: true));
        if (stderr.length > 2000)
          stderr = stderr.substring(stderr.length - 2000);
      });
      unawaited(process.exitCode.then((exitCode) {
        if (!firstFrame.isCompleted) {
          firstFrame.completeError(
            StateError(stderr.trim().isEmpty
                ? 'Camera process exited with status $exitCode.'
                : stderr.trim()),
          );
        }
        if (!controller.isClosed) unawaited(controller.close());
      }));
      await firstFrame.future.timeout(const Duration(seconds: 6));

      final activeProcess = process;
      final activeStdout = stdoutSubscription;
      final activeStderr = stderrSubscription;
      final activeFrames = frames;
      return CameraPreviewSession(
        frames: activeFrames.stream,
        close: () async {
          activeProcess.kill(ProcessSignal.sigterm);
          try {
            await activeProcess.exitCode.timeout(const Duration(seconds: 2));
          } on TimeoutException {
            activeProcess.kill(ProcessSignal.sigkill);
            await activeProcess.exitCode;
          }
          await activeStdout.cancel();
          await activeStderr.cancel();
          if (!activeFrames.isClosed) await activeFrames.close();
        },
      );
    } on Object catch (error) {
      failures.add('$devicePath: $error');
      process?.kill(ProcessSignal.sigterm);
      await stdoutSubscription?.cancel();
      await stderrSubscription?.cancel();
      if (frames != null && !frames.isClosed) await frames.close();
      if (process != null) {
        try {
          await process.exitCode.timeout(const Duration(seconds: 2));
        } on TimeoutException {
          process.kill(ProcessSignal.sigkill);
          await process.exitCode;
        }
      }
      return null;
    }
  }
}

class _JpegFrameParser {
  _JpegFrameParser(this.onFrame);

  final void Function(Uint8List frame) onFrame;
  final List<int> _buffer = [];

  void add(List<int> chunk) {
    _buffer.addAll(chunk);
    while (true) {
      final start = _findMarker(0xD8, 0);
      if (start < 0) {
        if (_buffer.length > 1) _buffer.removeRange(0, _buffer.length - 1);
        return;
      }
      if (start > 0) _buffer.removeRange(0, start);
      final end = _findMarker(0xD9, 2);
      if (end < 0) {
        if (_buffer.length > 4 * 1024 * 1024) _buffer.clear();
        return;
      }
      onFrame(Uint8List.fromList(_buffer.sublist(0, end + 2)));
      _buffer.removeRange(0, end + 2);
    }
  }

  int _findMarker(int marker, int start) {
    for (var index = start; index + 1 < _buffer.length; index++) {
      if (_buffer[index] == 0xFF && _buffer[index + 1] == marker) {
        return index;
      }
    }
    return -1;
  }
}
