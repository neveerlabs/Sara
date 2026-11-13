import 'dart:async';
import 'dart:convert';
import 'dart:io';

enum TerminalApprovalDecision { allow, skip, allowAll }

class TerminalCommandRequest {
  const TerminalCommandRequest({
    required this.command,
    required this.workingDirectory,
    this.taskContext = '',
    this.responseMessageId,
  });

  final String command;
  final String workingDirectory;
  final String taskContext;
  final String? responseMessageId;
}

class TerminalCommandResult {
  const TerminalCommandResult({
    required this.request,
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    this.error,
    this.timedOut = false,
    this.cancelled = false,
    this.skipped = false,
    this.outputTruncated = false,
  });

  final TerminalCommandRequest request;
  final int? exitCode;
  final String stdout;
  final String stderr;
  final String? error;
  final bool timedOut;
  final bool cancelled;
  final bool skipped;
  final bool outputTruncated;

  bool get succeeded =>
      error == null && !timedOut && !cancelled && !skipped && exitCode == 0;
}

class TerminalCommandHistoryEntry {
  const TerminalCommandHistoryEntry({
    this.id,
    this.responseMessageId,
    required this.taskContext,
    required this.command,
    required this.workingDirectory,
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    required this.error,
    required this.timedOut,
    required this.cancelled,
    required this.skipped,
    required this.outputTruncated,
    required this.createdAtUtc,
  });

  factory TerminalCommandHistoryEntry.fromResult(TerminalCommandResult result) {
    return TerminalCommandHistoryEntry(
      taskContext: result.request.taskContext,
      responseMessageId: result.request.responseMessageId,
      command: result.request.command,
      workingDirectory: result.request.workingDirectory,
      exitCode: result.exitCode,
      stdout: result.stdout,
      stderr: result.stderr,
      error: result.error,
      timedOut: result.timedOut,
      cancelled: result.cancelled,
      skipped: result.skipped,
      outputTruncated: result.outputTruncated,
      createdAtUtc: DateTime.now().toUtc().millisecondsSinceEpoch,
    );
  }

  factory TerminalCommandHistoryEntry.fromMap(Map<String, Object?> map) {
    return TerminalCommandHistoryEntry(
      id: map['id'] as int?,
      responseMessageId: map['response_message_id'] as String?,
      taskContext: map['task_context']! as String,
      command: map['command']! as String,
      workingDirectory: map['working_directory']! as String,
      exitCode: map['exit_code'] as int?,
      stdout: map['stdout']! as String,
      stderr: map['stderr']! as String,
      error: map['error'] as String?,
      timedOut: map['timed_out'] == 1,
      cancelled: map['cancelled'] == 1,
      skipped: map['skipped'] == 1,
      outputTruncated: map['output_truncated'] == 1,
      createdAtUtc: map['created_at_utc']! as int,
    );
  }

  final int? id;
  final String? responseMessageId;
  final String taskContext;
  final String command;
  final String workingDirectory;
  final int? exitCode;
  final String stdout;
  final String stderr;
  final String? error;
  final bool timedOut;
  final bool cancelled;
  final bool skipped;
  final bool outputTruncated;
  final int createdAtUtc;

  Map<String, Object?> toMap() => {
    if (id != null) 'id': id,
    'response_message_id': responseMessageId,
    'task_context': taskContext,
    'command': command,
    'working_directory': workingDirectory,
    'exit_code': exitCode,
    'stdout': stdout,
    'stderr': stderr,
    'error': error,
    'timed_out': timedOut ? 1 : 0,
    'cancelled': cancelled ? 1 : 0,
    'skipped': skipped ? 1 : 0,
    'output_truncated': outputTruncated ? 1 : 0,
    'created_at_utc': createdAtUtc,
  };
}

typedef TerminalCommandApprovalHandler =
    Future<TerminalApprovalDecision> Function(TerminalCommandRequest request);
typedef TerminalCommandResultHandler =
    FutureOr<void> Function(TerminalCommandResult result);
typedef TerminalCommandActivityHandler =
    void Function(
      TerminalCommandRequest request, {
      required bool running,
      required bool automaticallyAllowed,
    });
typedef TerminalCommandOutputHandler =
    void Function(String stdout, String stderr);

class TerminalCommandRunner {
  TerminalCommandRunner({
    this.timeout = const Duration(minutes: 2),
    this.maxOutputCharacters = 16000,
  });

  final Duration timeout;
  final int maxOutputCharacters;
  Process? _process;
  bool _cancelled = false;

  Future<TerminalCommandResult> run(
    TerminalCommandRequest request, {
    TerminalCommandOutputHandler? onOutput,
  }) async {
    if (_process != null) {
      throw StateError('A terminal command is already running.');
    }

    Process process;
    try {
      process = await Process.start('/bin/bash', [
        '-lc',
        request.command,
      ], workingDirectory: request.workingDirectory);
    } on ProcessException catch (error) {
      return TerminalCommandResult(
        request: request,
        exitCode: null,
        stdout: '',
        stderr: '',
        error: error.message,
      );
    }

    _process = process;
    _cancelled = false;
    await process.stdin.close();
    final stdout = StringBuffer();
    final stderr = StringBuffer();
    var outputCharacters = 0;
    var outputTruncated = false;

    void append(StringBuffer buffer, String text) {
      final remaining = maxOutputCharacters - outputCharacters;
      if (remaining <= 0) {
        outputTruncated = true;
        return;
      }
      if (text.length > remaining) {
        buffer.write(text.substring(0, remaining));
        outputCharacters += remaining;
        outputTruncated = true;
      } else {
        buffer.write(text);
        outputCharacters += text.length;
      }
      onOutput?.call(stdout.toString(), stderr.toString());
    }

    final stdoutSubscription = utf8.decoder
        .bind(process.stdout)
        .listen((text) => append(stdout, text));
    final stderrSubscription = utf8.decoder
        .bind(process.stderr)
        .listen((text) => append(stderr, text));
    final completion = Future.wait<void>([
      process.exitCode.then<void>((_) {}),
      stdoutSubscription.asFuture<void>(),
      stderrSubscription.asFuture<void>(),
    ]);
    var timedOut = false;
    int? exitCode;
    try {
      await completion.timeout(timeout);
      exitCode = await process.exitCode;
    } on TimeoutException {
      timedOut = true;
      process.kill(ProcessSignal.sigterm);
      try {
        exitCode = await process.exitCode.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        process.kill(ProcessSignal.sigkill);
      }
    }
    await stdoutSubscription.cancel();
    await stderrSubscription.cancel();
    final cancelled = _cancelled;
    if (identical(_process, process)) _process = null;
    return TerminalCommandResult(
      request: request,
      exitCode: exitCode,
      stdout: stdout.toString(),
      stderr: stderr.toString(),
      timedOut: timedOut,
      cancelled: cancelled,
      outputTruncated: outputTruncated,
    );
  }

  Future<void> stop() async {
    final process = _process;
    if (process == null) return;
    _cancelled = true;
    process.kill(ProcessSignal.sigterm);
  }
}
