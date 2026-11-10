import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sara_desktop/terminal_command.dart';

void main() {
  test('runs a command in the requested directory and captures both streams',
      () async {
    final request = TerminalCommandRequest(
      command: "printf 'out'; printf 'err' >&2",
      workingDirectory: Directory.current.path,
    );
    final result = await TerminalCommandRunner().run(request);

    expect(result.succeeded, isTrue);
    expect(result.exitCode, 0);
    expect(result.stdout, 'out');
    expect(result.stderr, 'err');
  });

  test('streams command output while the process is active', () async {
    final chunks = <String>[];
    final result = await TerminalCommandRunner().run(
      TerminalCommandRequest(
        command: "printf 'live-output'",
        workingDirectory: Directory.current.path,
      ),
      onOutput: (stdout, stderr) => chunks.add('$stdout$stderr'),
    );

    expect(result.succeeded, isTrue);
    expect(chunks, isNotEmpty);
    expect(chunks.last, 'live-output');
  });

  test('bounds captured command output', () async {
    final result = await TerminalCommandRunner(maxOutputCharacters: 5).run(
      TerminalCommandRequest(
        command: "printf '1234567890'",
        workingDirectory: Directory.current.path,
      ),
    );

    expect(result.stdout, '12345');
    expect(result.outputTruncated, isTrue);
  });

  test('stops a running command when requested', () async {
    final runner = TerminalCommandRunner();
    final resultFuture = runner.run(
      TerminalCommandRequest(
        command: 'exec sleep 10',
        workingDirectory: Directory.current.path,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await runner.stop();
    final result = await resultFuture;

    expect(result.cancelled, isTrue);
    expect(result.exitCode, isNotNull);
  });
}
