import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sara_desktop/ai_config_store.dart';
import 'package:sara_desktop/chat_message.dart';
import 'package:sara_desktop/chat_attachment.dart';
import 'package:sara_desktop/camera_capture.dart';
import 'package:sara_desktop/conversation_rag_service.dart';
import 'package:sara_desktop/gemini_reply_service.dart';
import 'package:sara_desktop/local_embedding_provider.dart';
import 'package:sara_desktop/message_database.dart';
import 'package:sara_desktop/sara_backup.dart';
import 'package:sara_desktop/terminal_command.dart';
import 'package:sara_desktop/web_search_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zxing_lib/src/barcode_format.dart';
import 'package:zxing_lib/src/qrcode/qrcode_writer.dart';

void main() {
  test(
    'local embedding mean pooling ignores padding and normalizes vectors',
    () {
      final vector = LocalE5EmbeddingProvider.meanPoolAndNormalize(
        [3, 0, 0, 4, 99, 99],
        [1, 1, 0],
        hiddenSize: 2,
      );
      expect(vector[0], closeTo(0.6, 1e-12));
      expect(vector[1], closeTo(0.8, 1e-12));
    },
  );

  test('formats UTC timestamps in Indonesian WIB date format', () {
    final saturdayNovemberSeventh = DateTime.utc(
      2026,
      11,
      6,
      17,
    ).millisecondsSinceEpoch;
    expect(
      formatJakartaTimestamp(saturdayNovemberSeventh),
      'Sabtu, 7 November 2026, 00:00',
    );
  });

  group('GeminiReplyService', () {
    test(
      'regenerate request includes previous alternative replies as context',
      () async {
        SharedPreferences.setMockInitialValues({});
        final preferences = await SharedPreferences.getInstance();
        final config = _MemoryAiConfigStore()
          ..apiKeys = ['stream-key']
          ..values['ai_model'] = 'gemini-3.5-flash-lite';
        final service = GeminiReplyService(
          configStore: config,
          preferences: preferences,
          client: MockClient((request) async {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            final instructions =
                body['systemInstruction']['parts'][0]['text'] as String;
            expect(instructions, contains('meaningfully different new reply'));
            expect(
              instructions,
              contains('Format user-facing replies as Markdown'),
            );
            expect(
              instructions,
              contains('Never use HTML tags or HTML markup'),
            );
            final contents = body['contents'] as List<dynamic>;
            final latestParts =
                (contents.last as Map<String, dynamic>)['parts']
                    as List<dynamic>;
            final branchContext = latestParts
                .map(
                  (part) => jsonDecode((part as Map<String, dynamic>)['text']),
                )
                .whereType<Map<String, dynamic>>()
                .firstWhere(
                  (part) => part.containsKey('previous_alternative_ai_replies'),
                );
            expect(branchContext['previous_alternative_ai_replies'], [
              {'role': 'model', 'content': 'Earlier alternative'},
            ]);
            return http.Response(
              'data: {"candidates":[{"content":{"parts":[{"text":"New reply"}]}}]}\n\n',
              200,
              headers: {'content-type': 'text/event-stream'},
            );
          }),
        );

        expect(
          await service.generateReply(
            [_userMessage],
            previousBranchReplies: const [
              ChatMessage(
                id: 'old-branch',
                role: 'model',
                content: 'Earlier alternative',
                timestamp: 'today',
                createdAtUtc: 2,
              ),
            ],
          ),
          'New reply',
        );
      },
    );

    test('streams SSE text chunks as they arrive', () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final config = _MemoryAiConfigStore()
        ..apiKeys = ['stream-key']
        ..values['ai_model'] = 'gemini-3.5-flash-lite';
      final updates = <String>[];
      final service = GeminiReplyService(
        configStore: config,
        preferences: preferences,
        client: MockClient((request) async {
          expect(request.url.path, contains(':streamGenerateContent'));
          expect(request.url.queryParameters['alt'], 'sse');
          return http.Response(
            'data: {"candidates":[{"content":{"parts":[{"text":"Hello"}]}}]}\n\n'
            'data: {"candidates":[{"content":{"parts":[{"text":" there"}]}}]}\n\n',
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        }),
      );

      expect(
        await service.generateReply([_userMessage], onText: updates.add),
        'Hello there',
      );
      expect(updates, ['Hello', 'Hello there']);
    });

    test('appends links to the web sources actually used in the reply', () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final config = _MemoryAiConfigStore()
        ..apiKeys = ['stream-key']
        ..values['ai_model'] = 'gemini-3.5-flash-lite'
        ..values[WebSearchConfigKeys.enabled] = 'true'
        ..values[WebSearchConfigKeys.tavilyApiKey] = 'tavily-key';
      var geminiRequests = 0;
      final updates = <String>[];
      final service = GeminiReplyService(
        configStore: config,
        preferences: preferences,
        client: MockClient((request) async {
          if (request.url.host == 'api.tavily.com') {
            return http.Response(
              jsonEncode({
                'results': [
                  for (var index = 1; index <= 3; index++)
                    {
                      'title': 'Source $index',
                      'url': 'https://example.com/source-$index',
                      'content': 'Search result $index',
                    },
                ],
              }),
              200,
            );
          }

          geminiRequests++;
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final declarations =
              (body['tools'][0]['functionDeclarations'] as List)
                  .cast<Map<String, dynamic>>();
          expect(
            declarations.any(
              (declaration) => declaration['name'] == 'search_web',
            ),
            isTrue,
          );
          if (geminiRequests == 1) {
            return http.Response(
              'data: {"candidates":[{"content":{"parts":[{"functionCall":'
              '{"name":"search_web","args":{"query":"recent topic"}}}]}}]}\n\n',
              200,
              headers: {'content-type': 'text/event-stream'},
            );
          }

          final contents = body['contents'] as List;
          final functionResponse =
              contents.last['parts'][0]['functionResponse'];
          expect(functionResponse['name'], 'search_web');
          expect(functionResponse['response']['results'], hasLength(3));
          return http.Response(
            'data: {"candidates":[{"content":{"parts":[{"text":"The answer is supported."}]}}]}\n\n',
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        }),
      );

      final reply = await service.generateReply([
        _userMessage,
      ], onText: updates.add);

      expect(geminiRequests, 2);
      expect(reply, contains('The answer is supported.'));
      expect(reply, contains('**Search sources**'));
      for (var index = 1; index <= 3; index++) {
        expect(
          reply,
          contains('- [Source $index](https://example.com/source-$index)'),
        );
      }
      expect(updates.last, reply);
    });

    test('chat reply can use and dispose a temporary camera frame', () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final config = _MemoryAiConfigStore()
        ..apiKeys = ['chat-camera-key']
        ..values['ai_model'] = 'gemini-3.5-flash-lite';
      var requests = 0;
      var disposedFrames = 0;
      final service = GeminiReplyService(
        configStore: config,
        preferences: preferences,
        client: MockClient((request) async {
          requests++;
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final declarations =
              (body['tools'][0]['functionDeclarations'] as List)
                  .cast<Map<String, dynamic>>();
          expect(
            declarations.any(
              (declaration) =>
                  declaration['name'] == 'sara_look_through_camera',
            ),
            isTrue,
          );
          final systemInstruction =
              body['systemInstruction']['parts'][0]['text'] as String;
          expect(
            systemInstruction,
            contains('optional sara_look_through_camera'),
          );
          if (requests == 1) {
            return http.Response(
              'data: {"candidates":[{"content":{"parts":[{"functionCall":'
              '{"name":"sara_look_through_camera","args":{}}}]}}]}\n\n',
              200,
              headers: {'content-type': 'text/event-stream'},
            );
          }

          expect(disposedFrames, 0);
          final contents = body['contents'] as List;
          final cameraParts =
              (contents.last as Map<String, dynamic>)['parts'] as List;
          expect(
            cameraParts.first['functionResponse']['name'],
            'sara_look_through_camera',
          );
          expect(cameraParts.last['inlineData'], {
            'mimeType': 'image/jpeg',
            'data': '/9j/2Q==',
          });
          return http.Response(
            'data: {"candidates":[{"content":{"parts":[{"text":"Kelihatannya terang."}]}}]}\n\n',
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        }),
      );

      final reply = await service.generateReply(
        [_userMessage],
        captureCameraFrame: () async => CameraFrame(
          bytes: Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]),
          dispose: () async {
            disposedFrames++;
          },
        ),
      );

      expect(reply, 'Kelihatannya terang.');
      expect(requests, 2);
      expect(disposedFrames, 1);
    });

    test(
      'terminal tool waits for approval and returns command output to Sara',
      () async {
        SharedPreferences.setMockInitialValues({});
        final preferences = await SharedPreferences.getInstance();
        final config = _MemoryAiConfigStore()
          ..apiKeys = ['terminal-key']
          ..values['ai_model'] = 'gemini-3.5-flash-lite';
        final approval = Completer<TerminalApprovalDecision>();
        final approvalShown = Completer<TerminalCommandRequest>();
        var executeCalls = 0;
        var loggedResults = 0;
        var requests = 0;
        final workingDirectory = Directory.current.path;
        final service = GeminiReplyService(
          configStore: config,
          preferences: preferences,
          client: MockClient((request) async {
            requests++;
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            final declarations =
                (body['tools'][0]['functionDeclarations'] as List)
                    .cast<Map<String, dynamic>>();
            expect(
              declarations.any(
                (tool) => tool['name'] == 'request_terminal_command',
              ),
              isTrue,
            );
            final instructions =
                body['systemInstruction']['parts'][0]['text'] as String;
            expect(instructions, contains('All allow applies only'));
            if (requests == 1) {
              return http.Response(
                'data: {"candidates":[{"content":{"parts":[{"functionCall":'
                '{"name":"request_terminal_command","args":'
                '{"command":"printf terminal-ok",'
                '"workingDirectory":"$workingDirectory"}}}]}}]}\n\n',
                200,
                headers: {'content-type': 'text/event-stream'},
              );
            }
            final contents = body['contents'] as List;
            final toolResponse =
                (contents.last as Map<String, dynamic>)['parts'] as List;
            expect(
              toolResponse.first['functionResponse']['response']['stdout'],
              'terminal-ok',
            );
            return http.Response(
              'data: {"candidates":[{"content":{"parts":[{"text":"The command worked."}]}}]}\n\n',
              200,
              headers: {'content-type': 'text/event-stream'},
            );
          }),
        );

        final replyFuture = service.generateReply(
          [_userMessage],
          responseMessageId: 'terminal-reply',
          approveTerminalCommand: (request) {
            if (!approvalShown.isCompleted) approvalShown.complete(request);
            return approval.future;
          },
          executeTerminalCommand: (request) async {
            executeCalls++;
            return TerminalCommandResult(
              request: request,
              exitCode: 0,
              stdout: 'terminal-ok',
              stderr: '',
            );
          },
          onTerminalCommandResult: (_) {
            loggedResults++;
          },
        );

        final requested = await approvalShown.future;
        expect(requested.command, 'printf terminal-ok');
        expect(requested.workingDirectory, workingDirectory);
        expect(requested.responseMessageId, 'terminal-reply');
        expect(executeCalls, 0);
        approval.complete(TerminalApprovalDecision.allow);

        expect(await replyFuture, 'The command worked.');
        expect(executeCalls, 1);
        expect(loggedResults, 1);
        expect(requests, 2);
      },
    );

    test(
      'terminal commands are not capped by an application count limit',
      () async {
        SharedPreferences.setMockInitialValues({});
        final preferences = await SharedPreferences.getInstance();
        final config = _MemoryAiConfigStore()
          ..apiKeys = ['unlimited-terminal-key']
          ..values['ai_model'] = 'gemini-3.5-flash-lite';
        const commandCount = 9;
        var requests = 0;
        var executions = 0;
        final workingDirectory = Directory.current.path;
        final service = GeminiReplyService(
          configStore: config,
          preferences: preferences,
          client: MockClient((request) async {
            requests++;
            if (requests <= commandCount) {
              final body = jsonEncode({
                'candidates': [
                  {
                    'content': {
                      'parts': [
                        {
                          'functionCall': {
                            'name': 'request_terminal_command',
                            'args': {
                              'command': 'printf command-$requests',
                              'workingDirectory': workingDirectory,
                            },
                          },
                        },
                      ],
                    },
                  },
                ],
              });
              return http.Response(
                'data: $body\n\n',
                200,
                headers: {'content-type': 'text/event-stream'},
              );
            }
            return http.Response(
              'data: {"candidates":[{"content":{"parts":[{"text":"Done."}]}}]}\n\n',
              200,
              headers: {'content-type': 'text/event-stream'},
            );
          }),
        );

        final reply = await service.generateReply(
          [_userMessage],
          approveTerminalCommand: (_) async =>
              TerminalApprovalDecision.allowAll,
          executeTerminalCommand: (request) async {
            executions++;
            return TerminalCommandResult(
              request: request,
              exitCode: 0,
              stdout: 'ok',
              stderr: '',
            );
          },
        );

        expect(reply, 'Done.');
        expect(executions, commandCount);
        expect(requests, commandCount + 1);
      },
    );

    test(
      'stored terminal message data is not included in Gemini context',
      () async {
        SharedPreferences.setMockInitialValues({});
        final preferences = await SharedPreferences.getInstance();
        final config = _MemoryAiConfigStore()
          ..apiKeys = ['terminal-history-key']
          ..values['ai_model'] = 'gemini-3.5-flash-lite';
        const privateCommand = 'PRIVATE_COMMAND_SENTINEL';
        const privateOutput = 'PRIVATE_OUTPUT_SENTINEL';
        final service = GeminiReplyService(
          configStore: config,
          preferences: preferences,
          client: MockClient((request) async {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            final declarations =
                (body['tools'][0]['functionDeclarations'] as List)
                    .cast<Map<String, dynamic>>();
            expect(
              declarations.any(
                (tool) => tool['name'] == 'search_terminal_command_history',
              ),
              isFalse,
            );
            final conversationJson = jsonEncode(body['contents']);
            expect(conversationJson, isNot(contains(privateCommand)));
            expect(conversationJson, isNot(contains(privateOutput)));
            return http.Response(
              'data: {"candidates":[{"content":{"parts":[{"text":"Okay."}]}}]}\n\n',
              200,
              headers: {'content-type': 'text/event-stream'},
            );
          }),
        );

        final reply = await service.generateReply(
          [
            _userMessage,
            ChatMessage(
              id: 'terminal-data-response',
              role: 'model',
              content: 'Done.',
              timestamp: _userMessage.timestamp,
              createdAtUtc: _userMessage.createdAtUtc + 1,
              parentMessageId: _userMessage.id,
              terminalActivities: [
                TerminalCommandHistoryEntry(
                  taskContext: 'Private task context',
                  command: privateCommand,
                  workingDirectory: '/private',
                  exitCode: 0,
                  stdout: privateOutput,
                  stderr: '',
                  error: null,
                  timedOut: false,
                  cancelled: false,
                  skipped: false,
                  outputTruncated: false,
                  createdAtUtc: _userMessage.createdAtUtc,
                ),
              ],
            ),
          ],
          approveTerminalCommand: (_) async => TerminalApprovalDecision.skip,
          executeTerminalCommand: (_) async =>
              throw StateError('No command is expected.'),
        );

        expect(reply, 'Okay.');
      },
    );

    test(
      'accepts an empty SSE completion when the model chooses silence',
      () async {
        SharedPreferences.setMockInitialValues({});
        final preferences = await SharedPreferences.getInstance();
        final config = _MemoryAiConfigStore()
          ..apiKeys = ['stream-key']
          ..values['ai_model'] = 'gemini-3.5-flash-lite';
        final service = GeminiReplyService(
          configStore: config,
          preferences: preferences,
          client: MockClient((request) async {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            final instructions =
                body['systemInstruction']['parts'][0]['text'] as String;
            expect(instructions, contains('genuine conversational discretion'));
            expect(instructions, contains('clearly ending the conversation'));
            expect(instructions, contains('supplied conversation'));
            expect(
              instructions,
              contains(
                'Use this established voice consistently; do not analyze or imitate',
              ),
            );
            expect(
              instructions,
              contains(
                'For this user, use "gua/lu", not "gue/lo" or "aku/kamu"',
              ),
            );
            expect(
              instructions,
              contains('never say "Ada yang bisa dibantu hari ini?"'),
            );
            expect(
              instructions,
              contains('not to a fixed "always brief" rule'),
            );
            expect(
              instructions,
              contains(
                'parentheses are strictly for side-thoughts or deep explanations',
              ),
            );
            expect(instructions, contains('NEVER add a period after it'));
            expect(
              instructions,
              contains('NEVER use hyphens or dashes as stylistic connectors'),
            );
            expect(
              instructions,
              contains('Treat consensual adult conversations about sex'),
            );
            expect(instructions, contains('Do not act uncomfortable, evade'));
            expect(
              instructions,
              contains('Do not go silent solely because the user mentions'),
            );
            expect(
              instructions,
              contains('offer a safe, nonviolent direction'),
            );
            expect(instructions, isNot(contains('moodIntensity')));
            expect(instructions, isNot(contains('update_sara_inner_life')));
            expect(
              instructions,
              contains('If you choose silence, return no user-facing text'),
            );
            return http.Response(
              'data: {"candidates":[{"content":{"parts":[]},'
              '"finishReason":"STOP"}]}\n\n',
              200,
              headers: {'content-type': 'text/event-stream'},
            );
          }),
        );

        expect(await service.generateReply([_userMessage]), isEmpty);
      },
    );

    test(
      'sends local file bytes as inline data without changing the path',
      () async {
        SharedPreferences.setMockInitialValues({});
        final preferences = await SharedPreferences.getInstance();
        final config = _MemoryAiConfigStore()
          ..apiKeys = ['test-key']
          ..values['ai_model'] = 'gemini-3.5-flash-lite';
        final directory = await Directory.systemTemp.createTemp('sara-media-');
        final attachmentPath = path.join(directory.path, 'sample.png');
        final bytes = [1, 2, 3, 4];
        await File(attachmentPath).writeAsBytes(bytes);
        addTearDown(() => directory.delete(recursive: true));
        Map<String, dynamic>? requestBody;
        final service = GeminiReplyService(
          configStore: config,
          preferences: preferences,
          client: MockClient((request) async {
            requestBody = jsonDecode(request.body) as Map<String, dynamic>;
            return http.Response(
              jsonEncode({
                'candidates': [
                  {
                    'content': {
                      'parts': [
                        {'text': 'I see the image.'},
                      ],
                    },
                  },
                ],
              }),
              200,
            );
          }),
        );
        final attachment = ChatAttachment(
          id: 'attachment-id',
          path: attachmentPath,
          name: 'sample.png',
          mimeType: 'image/png',
        );

        expect(
          await service.generateReply(
            [_userMessage],
            attachmentsByMessage: {
              _userMessage.id: [attachment],
            },
          ),
          'I see the image.',
        );
        final contents = requestBody!['contents'] as List;
        final parts = (contents.first as Map)['parts'] as List;
        expect(parts, hasLength(2));
        expect((parts[1] as Map)['inlineData'], {
          'mimeType': 'image/png',
          'data': base64Encode(bytes),
        });
        expect(File(attachmentPath).existsSync(), isTrue);
      },
    );

    test(
      'sends arbitrary files but never includes environment files',
      () async {
        SharedPreferences.setMockInitialValues({});
        final preferences = await SharedPreferences.getInstance();
        final config = _MemoryAiConfigStore()
          ..apiKeys = ['test-key']
          ..values['ai_model'] = 'gemini-3.5-flash-lite';
        final directory = await Directory.systemTemp.createTemp('sara-files-');
        addTearDown(() => directory.delete(recursive: true));
        final htmlPath = path.join(directory.path, 'page.html');
        final binaryPath = path.join(directory.path, 'archive.bin');
        final jsonPath = path.join(directory.path, 'data.json');
        final envPath = path.join(directory.path, '.env.local');
        await File(htmlPath).writeAsString('<h1>safe html</h1>');
        await File(binaryPath).writeAsBytes([1, 2, 3]);
        await File(jsonPath).writeAsString('{"safe":true}');
        await File(envPath).writeAsString('API_KEY=never-send-this');
        String? requestBody;
        final service = GeminiReplyService(
          configStore: config,
          preferences: preferences,
          client: MockClient((request) async {
            requestBody = request.body;
            return http.Response(
              jsonEncode({
                'candidates': [
                  {
                    'content': {
                      'parts': [
                        {'text': 'Received the files.'},
                      ],
                    },
                  },
                ],
              }),
              200,
            );
          }),
        );

        expect(
          await service.generateReply(
            [_userMessage],
            attachmentsByMessage: {
              _userMessage.id: [
                ChatAttachment(
                  id: 'html-file',
                  path: htmlPath,
                  name: 'page.html',
                  mimeType: 'text/html',
                ),
                ChatAttachment(
                  id: 'unknown-file',
                  path: binaryPath,
                  name: 'archive.bin',
                  mimeType: 'application/octet-stream',
                ),
                ChatAttachment(
                  id: 'json-file',
                  path: jsonPath,
                  name: 'data.json',
                  mimeType: 'application/json',
                ),
                ChatAttachment(
                  id: 'environment-file',
                  path: envPath,
                  name: '.env.local',
                  mimeType: 'text/plain',
                ),
              ],
            },
          ),
          'Received the files.',
        );

        final request = jsonDecode(requestBody!) as Map<String, dynamic>;
        final contents = request['contents'] as List;
        final parts = (contents.first as Map)['parts'] as List;
        final inlineData = parts
            .skip(1)
            .map((part) => (part as Map)['inlineData'] as Map)
            .toList();
        expect(inlineData.map((part) => part['mimeType']), [
          'text/html',
          'application/octet-stream',
          'application/json',
        ]);
        expect(requestBody, isNot(contains('API_KEY=never-send-this')));
        expect(requestBody, isNot(contains('.env.local')));
      },
    );

    test(
      'only reads an earlier attachment when the model requests it',
      () async {
        SharedPreferences.setMockInitialValues({});
        final preferences = await SharedPreferences.getInstance();
        final config = _MemoryAiConfigStore()
          ..apiKeys = ['on-demand-key']
          ..values['ai_model'] = 'gemini-3.5-flash-lite';
        final directory = await Directory.systemTemp.createTemp('sara-media-');
        final attachmentPath = path.join(directory.path, 'earlier.png');
        final bytes = [12, 24, 36, 48];
        await File(attachmentPath).writeAsBytes(bytes);
        addTearDown(() => directory.delete(recursive: true));

        final earlierMessage = ChatMessage(
          id: 'earlier-user-message',
          role: 'user',
          content: 'I uploaded this earlier.',
          timestamp: 'Sabtu, 7 November 2026, 00:56',
          createdAtUtc: DateTime.now().toUtc().millisecondsSinceEpoch - 1000,
        );
        final currentMessage = ChatMessage(
          id: 'current-user-message',
          role: 'user',
          content: 'What is in that picture?',
          timestamp: 'Sabtu, 7 November 2026, 00:57',
          createdAtUtc: DateTime.now().toUtc().millisecondsSinceEpoch,
        );
        final attachment = ChatAttachment(
          id: 'earlier-image',
          path: attachmentPath,
          name: 'earlier.png',
          mimeType: 'image/png',
          expiresAtUtc: DateTime.now()
              .toUtc()
              .add(const Duration(hours: 1))
              .millisecondsSinceEpoch,
        );
        final requestBodies = <Map<String, dynamic>>[];
        final service = GeminiReplyService(
          configStore: config,
          preferences: preferences,
          client: MockClient((request) async {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            requestBodies.add(body);
            if (requestBodies.length == 1) {
              final contents = body['contents'] as List;
              expect((contents[0]['parts'] as List), hasLength(1));
              expect((contents[1]['parts'] as List), hasLength(1));
              final declarations = body['tools'][0]['functionDeclarations'];
              expect(
                declarations.any(
                  (tool) => tool['name'] == 'read_uploaded_attachment',
                ),
                isTrue,
              );
              return http.Response(
                'data: {"candidates":[{"content":{"parts":[{"functionCall":'
                '{"name":"read_uploaded_attachment","args":'
                '{"attachmentId":"earlier-image"}}}]}}]}\n\n',
                200,
                headers: {'content-type': 'text/event-stream'},
              );
            }

            final contents = body['contents'] as List;
            final toolResponse = contents.last['parts'] as List;
            expect(
              toolResponse.first['functionResponse']['name'],
              'read_uploaded_attachment',
            );
            expect(toolResponse.last['inlineData'], {
              'mimeType': 'image/png',
              'data': base64Encode(bytes),
            });
            expect(request.body, isNot(contains(attachmentPath)));
            return http.Response(
              'data: {"candidates":[{"content":{"parts":'
              '[{"text":"It is a picture."}]}}]}\n\n',
              200,
              headers: {'content-type': 'text/event-stream'},
            );
          }),
        );

        final reply = await service.generateReply(
          [earlierMessage, currentMessage],
          attachmentsByMessage: {
            earlierMessage.id: [attachment],
          },
        );

        expect(reply, 'It is a picture.');
        expect(requestBodies, hasLength(2));
      },
    );

    test(
      'returns only valid uploaded media selected by Gemini tools',
      () async {
        SharedPreferences.setMockInitialValues({});
        final preferences = await SharedPreferences.getInstance();
        final config = _MemoryAiConfigStore()
          ..apiKeys = ['tool-key']
          ..values['ai_model'] = 'gemini-3.5-flash-lite';
        final directory = await Directory.systemTemp.createTemp('sara-media-');
        final attachmentPath = path.join(directory.path, 'sample.png');
        await File(attachmentPath).writeAsBytes([1, 2, 3]);
        addTearDown(() => directory.delete(recursive: true));
        final attachment = ChatAttachment(
          id: 'media-1',
          path: attachmentPath,
          name: 'sample.png',
          mimeType: 'image/png',
          expiresAtUtc: DateTime.now()
              .toUtc()
              .add(const Duration(hours: 1))
              .millisecondsSinceEpoch,
        );
        final requestBodies = <Map<String, dynamic>>[];
        var requests = 0;
        final service = GeminiReplyService(
          configStore: config,
          preferences: preferences,
          client: MockClient((request) async {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            requestBodies.add(body);
            requests++;
            if (requests == 1) {
              expect(body['tools'], isNotNull);
              return http.Response(
                'data: {"candidates":[{"content":{"parts":[{"functionCall":'
                '{"name":"send_uploaded_media","args":{"attachmentIds":'
                '["media-1"]}}}]}}]}\n\n',
                200,
                headers: {'content-type': 'text/event-stream'},
              );
            }
            final contents = body['contents'] as List;
            expect(contents[1]['role'], 'model');
            expect(
              contents[1]['parts'][0]['functionCall']['name'],
              'send_uploaded_media',
            );
            expect(
              contents[2]['parts'][0]['functionResponse']['name'],
              'send_uploaded_media',
            );
            expect(request.body, isNot(contains(attachmentPath)));
            return http.Response(
              jsonEncode({
                'candidates': [
                  {
                    'content': {'parts': []},
                  },
                ],
              }),
              200,
            );
          }),
        );
        List<ChatAttachment>? selectedMedia;

        final reply = await service.generateReply(
          [_userMessage],
          attachmentsByMessage: {
            _userMessage.id: [attachment],
          },
          onMedia: (items) => selectedMedia = items,
        );

        expect(reply, isEmpty);
        expect(requests, 2);
        expect(selectedMedia, [same(attachment)]);
        expect(requestBodies.first['tools'], isNotNull);
      },
    );

    test(
      'does not send expired attachments or offer them to Gemini tools',
      () async {
        SharedPreferences.setMockInitialValues({});
        final preferences = await SharedPreferences.getInstance();
        final config = _MemoryAiConfigStore()
          ..apiKeys = ['expired-key']
          ..values['ai_model'] = 'gemini-3.5-flash-lite';
        final directory = await Directory.systemTemp.createTemp('sara-media-');
        final attachmentPath = path.join(directory.path, 'expired.png');
        await File(attachmentPath).writeAsBytes([1, 2, 3]);
        addTearDown(() => directory.delete(recursive: true));
        final attachment = ChatAttachment(
          id: 'expired-media',
          path: attachmentPath,
          name: 'expired.png',
          mimeType: 'image/png',
          expiresAtUtc: DateTime.now()
              .toUtc()
              .subtract(const Duration(seconds: 1))
              .millisecondsSinceEpoch,
        );
        Map<String, dynamic>? requestBody;
        final service = GeminiReplyService(
          configStore: config,
          preferences: preferences,
          client: MockClient((request) async {
            requestBody = jsonDecode(request.body) as Map<String, dynamic>;
            return http.Response(
              'data: {"candidates":[{"content":{"parts":[{"text":"No file"}]}}]}\n\n',
              200,
              headers: {'content-type': 'text/event-stream'},
            );
          }),
        );

        expect(
          await service.generateReply(
            [_userMessage],
            attachmentsByMessage: {
              _userMessage.id: [attachment],
            },
          ),
          'No file',
        );
        expect(requestBody!.containsKey('tools'), isFalse);
        expect((requestBody!['contents'][0]['parts'] as List), hasLength(1));
      },
    );

    test('Gemini barcode tool decodes a previously uploaded image', () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final config = _MemoryAiConfigStore()
        ..apiKeys = ['barcode-key']
        ..values['ai_model'] = 'gemini-3.5-flash-lite';
      final directory = await Directory.systemTemp.createTemp('sara-barcode-');
      final barcodeFile = await _createQrImage(directory, 'scan me');
      addTearDown(() => directory.delete(recursive: true));
      final attachment = ChatAttachment(
        id: 'barcode-image',
        path: barcodeFile.path,
        name: 'barcode.png',
        mimeType: 'image/png',
        expiresAtUtc: DateTime.now()
            .toUtc()
            .add(const Duration(hours: 1))
            .millisecondsSinceEpoch,
      );
      var requests = 0;
      final service = GeminiReplyService(
        configStore: config,
        preferences: preferences,
        client: MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          requests++;
          if (requests == 1) {
            final declarations = body['tools'][0]['functionDeclarations'];
            expect(
              declarations.any(
                (declaration) => declaration['name'] == 'scan_image_barcode',
              ),
              isTrue,
            );
            return http.Response(
              'data: {"candidates":[{"content":{"parts":[{"functionCall":'
              '{"name":"scan_image_barcode","args":'
              '{"attachmentId":"barcode-image"}}}]}}]}\n\n',
              200,
              headers: {'content-type': 'text/event-stream'},
            );
          }
          final contents = body['contents'] as List;
          final toolResponse =
              contents[2]['parts'][0]['functionResponse']['response'];
          expect(toolResponse['found'], isTrue);
          expect(toolResponse['barcode'], 'qrCode: scan me');
          return http.Response(
            'data: {"candidates":[{"content":{"parts":'
            '[{"text":"The QR code says scan me."}]}}]}\n\n',
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        }),
      );

      expect(
        await service.generateReply(
          [_userMessage],
          attachmentsByMessage: {
            _userMessage.id: [attachment],
          },
        ),
        'The QR code says scan me.',
      );
      expect(requests, 2);
    });

    test('starts with first key and skips it after a later failure', () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final config = _MemoryAiConfigStore()
        ..apiKeys = ['primary-key', 'secondary-key']
        ..values['ai_model'] = 'gemini-3.5-flash-lite';
      final attemptedKeys = <String>[];
      var primaryRequests = 0;
      final service = GeminiReplyService(
        configStore: config,
        preferences: preferences,
        client: MockClient((request) async {
          final key = request.headers['x-goog-api-key']!;
          attemptedKeys.add(key);
          if (key == 'primary-key' && ++primaryRequests > 1) {
            return http.Response(
              jsonEncode({
                'error': {'message': 'Unavailable'},
              }),
              503,
            );
          }
          return http.Response(
            jsonEncode({
              'candidates': [
                {
                  'content': {
                    'parts': [
                      {'text': 'Reply'},
                    ],
                  },
                },
              ],
            }),
            200,
          );
        }),
      );

      for (var index = 0; index < 3; index++) {
        expect(await service.generateReply([_userMessage]), 'Reply');
      }
      expect(attemptedKeys, [
        'primary-key',
        'primary-key',
        'secondary-key',
        'primary-key',
        'secondary-key',
      ]);
    });

    test(
      'rotates after failure and skips cached failed key next time',
      () async {
        SharedPreferences.setMockInitialValues({});
        final preferences = await SharedPreferences.getInstance();
        final config = _MemoryAiConfigStore()
          ..apiKeys = ['bad-key', 'working-key']
          ..values['ai_model'] = 'gemini-3.5-flash-lite';
        final attemptedKeys = <String>[];
        final requestBodies = <Map<String, dynamic>>[];
        final service = GeminiReplyService(
          configStore: config,
          preferences: preferences,
          client: MockClient((request) async {
            final key = request.headers['x-goog-api-key']!;
            attemptedKeys.add(key);
            requestBodies.add(jsonDecode(request.body) as Map<String, dynamic>);
            if (key == 'bad-key') {
              return http.Response(
                jsonEncode({
                  'error': {'message': 'Invalid key'},
                }),
                403,
              );
            }
            return http.Response(
              jsonEncode({
                'candidates': [
                  {
                    'content': {
                      'parts': [
                        {'text': 'Hello from Sara'},
                      ],
                    },
                  },
                ],
              }),
              200,
            );
          }),
        );

        expect(
          await service.generateReply([_userMessage], personalName: 'Rani'),
          'Hello from Sara',
        );
        expect(await service.generateReply([_userMessage]), 'Hello from Sara');
        expect(attemptedKeys, ['bad-key', 'working-key', 'working-key']);
        final systemInstruction =
            requestBodies.first['systemInstruction'] as Map<String, dynamic>;
        expect(jsonEncode(systemInstruction), contains('Rani'));
        final requestContent = requestBodies.first['contents'] as List<dynamic>;
        final requestMessage = requestContent.first as Map<String, dynamic>;
        final requestJson =
            (requestMessage['parts'] as List).first as Map<String, dynamic>;
        final serializedMessage = jsonDecode(requestJson['text'] as String);
        expect(serializedMessage, {
          'id': _userMessage.id,
          'role': _userMessage.role,
          'content': _userMessage.content,
          'timestamp': _userMessage.timestamp,
          'created_at_utc': _userMessage.createdAtUtc,
        });
        expect(
          requestBodies
              .first['generationConfig']['thinkingConfig']['thinkingLevel'],
          'minimal',
        );
        expect(
          requestBodies
              .last['generationConfig']['thinkingConfig']['thinkingLevel'],
          'minimal',
        );
        expect(preferences.getStringList('failed_gemini_key_fingerprints'), [
          sha256.convert(utf8.encode('bad-key')).toString(),
        ]);
      },
    );

    test('reports all keys failed and caches only fingerprints', () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final config = _MemoryAiConfigStore()
        ..apiKeys = ['first-key', 'second-key']
        ..values['ai_model'] = 'gemini-3.5-flash-lite';
      var requests = 0;
      final service = GeminiReplyService(
        configStore: config,
        preferences: preferences,
        client: MockClient((request) async {
          requests++;
          return http.Response(
            jsonEncode({
              'error': {'message': 'Rejected'},
            }),
            403,
          );
        }),
      );

      await expectLater(
        service.generateReply([_userMessage]),
        throwsA(isA<AllGeminiApiKeysFailedException>()),
      );
      await expectLater(
        service.generateReply([_userMessage]),
        throwsA(isA<AllGeminiApiKeysFailedException>()),
      );
      final failedFingerprints = preferences.getStringList(
        'failed_gemini_key_fingerprints',
      )!;
      expect(requests, 2);
      expect(failedFingerprints, hasLength(2));
      expect(failedFingerprints, isNot(contains('first-key')));
      expect(failedFingerprints, isNot(contains('second-key')));
    });

    test('retrieves old active-branch messages and queues thinker work', () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final directory = await Directory.systemTemp.createTemp('sara-rag-');
      final store = await SqliteMessageStore.openAtPath(
        path.join(directory.path, 'message.sql'),
      );
      addTearDown(() async {
        await store.close();
        await directory.delete(recursive: true);
      });
      final history = <ChatMessage>[];
      for (var index = 0; index < 23; index++) {
        final id = 'rag-message-$index';
        history.add(
          ChatMessage(
            id: id,
            role: index.isEven ? 'user' : 'model',
            content: index == 0
                ? 'historical source marker: Sara suggested a blue notebook'
                : index == 22
                ? 'What color notebook do I prefer?'
                : 'Ordinary conversation item $index',
            timestamp: '2026-01-01 10:00:00',
            createdAtUtc: index + 1,
            parentMessageId: index == 0 ? null : history.last.id,
          ),
        );
      }
      await store.saveExchange(history);
      final inactiveBranchUser = ChatMessage(
        id: 'rag-inactive-branch-user',
        role: 'user',
        content: 'inactive branch private marker',
        timestamp: '2026-01-01 10:00:00',
        createdAtUtc: 22,
        parentMessageId: history.first.id,
      );
      await store.saveMessage(inactiveBranchUser);
      final inactiveBranch = ChatMessage(
        id: 'rag-inactive-branch',
        role: 'model',
        content: 'inactive branch response',
        timestamp: '2026-01-01 10:00:00',
        createdAtUtc: 23,
        parentMessageId: inactiveBranchUser.id,
      );
      await store.saveMessage(inactiveBranch);
      await store.saveMessageEmbeddings([
        MessageEmbeddingRecord(
          messageId: history.first.id,
          topicId: 'active-topic',
          model: LocalE5EmbeddingProvider.modelId,
          values: const [1, 0],
          createdAtUtc: 1,
        ),
        MessageEmbeddingRecord(
          messageId: inactiveBranch.id,
          topicId: 'inactive-topic',
          model: LocalE5EmbeddingProvider.modelId,
          values: const [1, 0],
          createdAtUtc: 22,
        ),
      ]);
      await store.saveConversationMemory(
        topic: const ConversationTopicSummary(
          id: 'active-topic',
          title: 'Active topic',
          summary: 'An active-branch summary.',
          throughMessageId: 'rag-message-0',
          updatedAtUtc: 1,
        ),
        embeddings: const [],
        userMemories: [
          UserMemoryRecord(
            id: 'active-notebook-memory',
            kind: 'preference',
            memoryKey: 'notebook_color',
            content: 'Prefers blue notebooks.',
            confidence: 0.9,
            sourceMessageIds: [history.first.id],
            createdAtUtc: 1,
            updatedAtUtc: 1,
            embeddingModel: LocalE5EmbeddingProvider.modelId,
            embedding: const [1, 0],
          ),
          UserMemoryRecord(
            id: 'expired-memory',
            kind: 'wellbeing',
            memoryKey: 'expired_state',
            content: 'Expired temporary state.',
            confidence: 0.9,
            sourceMessageIds: [history.first.id],
            createdAtUtc: 1,
            updatedAtUtc: 1,
            expiresAtUtc: 1,
            embeddingModel: LocalE5EmbeddingProvider.modelId,
            embedding: const [1, 0],
          ),
        ],
      );
      await store.saveConversationTopicEmbeddings([
        ConversationTopicEmbeddingRecord(
          topicId: 'active-topic',
          model: LocalE5EmbeddingProvider.modelId,
          values: const [1, 0],
          createdAtUtc: 1,
        ),
        ConversationTopicEmbeddingRecord(
          topicId: 'inactive-topic',
          model: LocalE5EmbeddingProvider.modelId,
          values: const [1, 0],
          createdAtUtc: 22,
        ),
      ]);
      await store.saveConversationMemory(
        topic: ConversationTopicSummary(
          id: 'inactive-topic',
          title: 'Inactive topic',
          summary: 'An inactive-branch summary.',
          throughMessageId: inactiveBranch.id,
          updatedAtUtc: 22,
        ),
        embeddings: const [],
        userMemories: [
          UserMemoryRecord(
            id: 'inactive-memory',
            kind: 'preference',
            memoryKey: 'inactive_secret',
            content: 'Inactive branch private preference.',
            confidence: 0.9,
            sourceMessageIds: [inactiveBranchUser.id],
            createdAtUtc: 22,
            updatedAtUtc: 22,
            embeddingModel: LocalE5EmbeddingProvider.modelId,
            embedding: const [1, 0],
          ),
        ],
      );
      final config = _MemoryAiConfigStore()
        ..apiKeys = ['rag-key']
        ..values['ai_model'] = 'gemini-3.5-flash-lite';
      Map<String, dynamic>? chatRequest;
      Map<String, dynamic>? summaryRequest;
      final service = GeminiReplyService(
        configStore: config,
        preferences: preferences,
        messageStore: store,
        embeddingProvider: const _FixedEmbeddingProvider(),
        client: MockClient((request) async {
          if (request.url.path.endsWith(':batchEmbedContents')) {
            throw StateError('Document embeddings must stay local.');
          }
          if (request.url.path.endsWith(':embedContent')) {
            throw StateError('Query embeddings must stay local.');
          }
          if (request.url.path.endsWith(':streamGenerateContent')) {
            chatRequest = jsonDecode(request.body) as Map<String, dynamic>;
            return http.Response(
              'data: {"candidates":[{"content":{"parts":[{"text":"I remember the blue notebook."}]}}]}\n\n',
              200,
              headers: {'content-type': 'text/event-stream'},
            );
          }
          if (request.url.path.endsWith(':generateContent')) {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            summaryRequest = body;
            return http.Response(
              jsonEncode({
                'candidates': [
                  {
                    'content': {
                      'parts': [
                        {
                          'text':
                              '{"title":"Notebook","summary":"Sara suggested a blue notebook.","intent":"Remember the notebook preference.","open_threads":[],"memories":[],"resolved_memories":[],"proactive_message":null,"proactive_confidence":0}',
                        },
                      ],
                    },
                  },
                ],
              }),
              200,
            );
          }
          throw StateError('Unexpected Gemini memory request: ${request.url}');
        }),
      );

      expect(
        await service.generateReply(history, responseMessageId: 'rag-response'),
        'I remember the blue notebook.',
      );
      expect(
        jsonEncode(chatRequest),
        contains('retrieved_conversation_memory'),
      );
      final latestParts =
          (chatRequest!['contents'] as List).last['parts'] as List;
      final memory =
          latestParts
                  .whereType<Map>()
                  .map((part) => part['text'])
                  .whereType<String>()
                  .map((text) {
                    try {
                      return jsonDecode(text);
                    } on FormatException {
                      return null;
                    }
                  })
                  .whereType<Map>()
                  .firstWhere(
                    (part) => part.containsKey('retrieved_conversation_memory'),
                  )['retrieved_conversation_memory']
              as Map;
      expect(jsonEncode(memory), contains('historical source marker'));
      expect(jsonEncode(memory), contains('An active-branch summary'));
      expect(jsonEncode(memory), contains('Prefers blue notebooks.'));
      expect(jsonEncode(memory), isNot(contains('inactive')));
      expect(jsonEncode(memory), isNot(contains('Expired temporary state.')));
      expect(
        latestParts.whereType<Map>().any((part) {
          final text = part['text'];
          if (text is! String) return false;
          try {
            return (jsonDecode(text) as Map).containsKey(
              'live_background_thinker_handoff',
            );
          } on FormatException {
            return false;
          }
        }),
        isFalse,
      );
      expect((chatRequest!['contents'] as List).length, 21);

      final modelMessage = ChatMessage(
        id: 'rag-response',
        role: 'model',
        content: 'I remember the blue notebook.',
        timestamp: '2026-01-01 10:01:00',
        createdAtUtc: 22,
        parentMessageId: history.last.id,
      );
      await store.appendMessage(modelMessage);
      await service.saveConversationMemory(
        responseMessageId: modelMessage.id,
        userMessage: history.last,
        modelMessage: modelMessage,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(summaryRequest, isNull);
      expect(await store.loadConversationMemoryJobs(), hasLength(1));
      expect(
        (await store.loadConversationTopicSummaries()).any(
          (topic) => topic.throughMessageId == modelMessage.id,
        ),
        isFalse,
      );
      expect(
        (await store.loadMessageEmbeddings()).map(
          (embedding) => embedding.messageId,
        ),
        contains(history.first.id),
      );
      final nextUser = ChatMessage(
        id: 'rag-next-user',
        role: 'user',
        content: 'What did you recommend for my notes?',
        timestamp: '2026-01-01 10:02:00',
        createdAtUtc: 23,
        parentMessageId: modelMessage.id,
      );
      await store.appendMessage(nextUser);
      await service.generateReply([
        ...history,
        modelMessage,
        nextUser,
      ], responseMessageId: 'rag-next-response');
      final nextParts =
          (chatRequest!['contents'] as List).last['parts'] as List;
      expect(
        nextParts
            .map((part) => (part as Map)['text'])
            .whereType<String>()
            .any((text) => text.contains('Remember the notebook preference.')),
        isFalse,
      );
    });

    test('processes three saved exchanges in one thinker request', () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final directory = await Directory.systemTemp.createTemp(
        'sara-rag-batch-',
      );
      final store = await SqliteMessageStore.openAtPath(
        path.join(directory.path, 'message.sql'),
      );
      addTearDown(() async {
        await store.close();
        await directory.delete(recursive: true);
      });
      final exchanges = <(ChatMessage, ChatMessage)>[];
      String? parentId;
      for (var index = 0; index < 3; index++) {
        final user = _message(
          id: 'batch-user-$index',
          createdAtUtc: index * 2 + 1,
          parentMessageId: parentId,
        );
        final model = _message(
          id: 'batch-model-$index',
          role: 'model',
          createdAtUtc: index * 2 + 2,
          parentMessageId: user.id,
        );
        exchanges.add((user, model));
        parentId = model.id;
      }
      await store.saveExchange([
        for (final exchange in exchanges) ...[exchange.$1, exchange.$2],
      ]);
      await store.saveConversationMemory(
        topic: ConversationTopicSummary(
          id: 'existing-memory-topic',
          title: 'Notebook decision',
          summary: 'The user plans to choose a notebook size.',
          throughMessageId: exchanges.first.$2.id,
          updatedAtUtc: 2,
        ),
        embeddings: const [],
        userMemories: [
          UserMemoryRecord(
            id: 'existing-follow-up',
            kind: 'follow_up',
            memoryKey: 'choose_notebook_size',
            content: 'Choose a notebook size.',
            confidence: 0.9,
            sourceMessageIds: [exchanges.first.$1.id],
            createdAtUtc: 1,
            updatedAtUtc: 1,
            expiresAtUtc: DateTime.now()
                .toUtc()
                .add(const Duration(days: 30))
                .millisecondsSinceEpoch,
            embeddingModel: LocalE5EmbeddingProvider.modelId,
            embedding: const [1, 0],
          ),
        ],
      );
      final config = _MemoryAiConfigStore()
        ..apiKeys = ['batch-key']
        ..values['ai_model'] = 'gemini-3.5-flash-lite';
      var thinkerRequests = 0;
      Map<String, dynamic>? thinkerBody;
      final service = ConversationRagService(
        messageStore: store,
        configStore: config,
        preferences: preferences,
        embeddingProvider: const _FixedEmbeddingProvider(),
        client: MockClient((request) async {
          thinkerRequests++;
          thinkerBody = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode({
              'candidates': [
                {
                  'content': {
                    'parts': [
                      {
                        'text':
                            '{"title":"Topic","summary":"Three exchanges summarized.","intent":"Continue the topic.","open_threads":[],"memories":[{"kind":"habit","key":"plans_with_notes","content":"Often uses notes to plan ideas.","confidence":0.8,"source_message_ids":["batch-user-0","batch-user-2"],"expires_in_days":null},{"kind":"wellbeing","key":"current_state","content":"Had a hard day recently.","confidence":0.7,"source_message_ids":["unknown-id","batch-user-1"],"expires_in_days":14.0}],"resolved_memories":[{"kind":"follow_up","key":"choose_notebook_size"}],"proactive_message":null,"proactive_confidence":0}',
                      },
                    ],
                  },
                },
              ],
            }),
            200,
          );
        }),
      );
      addTearDown(service.dispose);

      for (final exchange in exchanges) {
        service.enqueueExchangeMemory(
          context: const ConversationRagContext(),
          userMessage: exchange.$1,
          modelMessage: exchange.$2,
        );
      }
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (DateTime.now().isBefore(deadline) &&
          !(await store.loadConversationTopicSummaries()).any(
            (topic) => topic.throughMessageId == exchanges.last.$2.id,
          )) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      expect(thinkerRequests, 1);
      expect(
        ((thinkerBody!['contents'] as List).single['parts'] as List)
            .single['text'],
        contains('"new_exchanges"'),
      );
      final thinkerContext =
          jsonDecode(
                (((thinkerBody!['contents'] as List).single['parts'] as List)
                        .single['text']
                    as String),
              )
              as Map;
      expect(thinkerContext['new_exchanges'], hasLength(6));
      expect(await store.loadConversationMemoryJobs(), isEmpty);
      final savedMemories = await store.loadUserMemories();
      expect(savedMemories, hasLength(2));
      final savedHabit = savedMemories.singleWhere(
        (memory) => memory.kind == 'habit',
      );
      expect(savedHabit.sourceMessageIds, [
        exchanges.first.$1.id,
        exchanges.last.$1.id,
      ]);
      final savedWellbeing = savedMemories.singleWhere(
        (memory) => memory.kind == 'wellbeing',
      );
      expect(savedWellbeing.sourceMessageIds, [exchanges[1].$1.id]);
      expect(savedWellbeing.expiresAtUtc, isNotNull);
      expect(
        (await store.loadConversationTopicSummaries()).single.throughMessageId,
        exchanges.last.$2.id,
      );
    });

    test(
      'resumes a full persistent thinker batch after reopening SQLite',
      () async {
        SharedPreferences.setMockInitialValues({});
        final preferences = await SharedPreferences.getInstance();
        final directory = await Directory.systemTemp.createTemp(
          'sara-rag-resume-',
        );
        final databasePath = path.join(directory.path, 'message.sql');
        var store = await SqliteMessageStore.openAtPath(databasePath);
        addTearDown(() async {
          await store.close();
          await directory.delete(recursive: true);
        });
        final jobs = <ConversationMemoryJob>[];
        final messages = <ChatMessage>[];
        final queuedAtUtc = DateTime.now().toUtc().millisecondsSinceEpoch;
        String? parentId;
        for (var index = 0; index < 3; index++) {
          final user = _message(
            id: 'u$index',
            createdAtUtc: index * 2 + 1,
            parentMessageId: parentId,
          );
          final model = _message(
            id: 'm$index',
            role: 'model',
            createdAtUtc: index * 2 + 2,
            parentMessageId: user.id,
          );
          messages.addAll([user, model]);
          jobs.add(
            ConversationMemoryJob(
              id: model.id,
              userMessageId: user.id,
              modelMessageId: model.id,
              queuedAtUtc: queuedAtUtc + index,
              forkTopicOnUpdate: false,
            ),
          );
          parentId = model.id;
        }
        await store.saveExchange(messages);
        for (final job in jobs) {
          await store.enqueueConversationMemoryJob(job);
        }
        await store.close();
        store = await SqliteMessageStore.openAtPath(databasePath);

        final config = _MemoryAiConfigStore()
          ..apiKeys = ['resume-key']
          ..values['ai_model'] = 'gemini-3.5-flash-lite';
        var thinkerRequests = 0;
        final service = ConversationRagService(
          messageStore: store,
          configStore: config,
          preferences: preferences,
          embeddingProvider: const _FixedEmbeddingProvider(),
          client: MockClient((request) async {
            thinkerRequests++;
            return http.Response(
              jsonEncode({
                'candidates': [
                  {
                    'content': {
                      'parts': [
                        {
                          'text':
                              '{"title":"Topic","summary":"Resumed three exchanges.","intent":"Continue.","open_threads":[],"memories":[],"resolved_memories":[],"proactive_message":null,"proactive_confidence":0}',
                        },
                      ],
                    },
                  },
                ],
              }),
              200,
            );
          }),
        );
        addTearDown(service.dispose);

        await service.startBackgroundProcessing();
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (DateTime.now().isBefore(deadline) &&
            (await store.loadConversationMemoryJobs()).isNotEmpty) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }

        expect(thinkerRequests, 1);
        expect(await store.loadConversationMemoryJobs(), isEmpty);
        expect(
          (await store.loadConversationTopicSummaries())
              .single
              .throughMessageId,
          'm2',
        );
      },
    );

    test(
      'indexes history and summarizes active topics in the background',
      () async {
        SharedPreferences.setMockInitialValues({});
        final preferences = await SharedPreferences.getInstance();
        final directory = await Directory.systemTemp.createTemp(
          'sara-rag-index-',
        );
        final store = await SqliteMessageStore.openAtPath(
          path.join(directory.path, 'message.sql'),
        );
        final user = ChatMessage(
          id: 'background-user',
          role: 'user',
          content: 'I prefer blue notebooks for writing down ideas and plans.',
          timestamp: '2026-01-01 10:00:00',
          createdAtUtc: 1,
        );
        final response = ChatMessage(
          id: 'background-model',
          role: 'model',
          content: 'I will remember that blue notebooks suit your ideas.',
          timestamp: '2026-01-01 10:00:00',
          createdAtUtc: 2,
          parentMessageId: user.id,
        );
        await store.saveExchange([user, response]);
        addTearDown(() async {
          await store.close();
          await directory.delete(recursive: true);
        });

        final summarized = Completer<void>();
        var summaryCalls = 0;
        final config = _MemoryAiConfigStore()
          ..apiKeys = ['background-key']
          ..values['ai_model'] = 'gemini-3.5-flash-lite';
        final service = GeminiReplyService(
          configStore: config,
          preferences: preferences,
          messageStore: store,
          embeddingProvider: const _FixedEmbeddingProvider(),
          client: MockClient((request) async {
            if (request.url.path.endsWith(':batchEmbedContents')) {
              throw StateError('Document embeddings must stay local.');
            }
            expect(request.url.path, endsWith(':generateContent'));
            summaryCalls++;
            summarized.complete();
            return http.Response(
              jsonEncode({
                'candidates': [
                  {
                    'content': {
                      'parts': [
                        {
                          'text':
                              '{"title":"Blue notebooks","summary":"The user prefers blue notebooks for ideas and plans.","intent":"Remember the stationery preference.","open_threads":[],"memories":[],"resolved_memories":[],"proactive_message":null,"proactive_confidence":0}',
                        },
                      ],
                    },
                  },
                ],
              }),
              200,
            );
          }),
        );
        addTearDown(service.disposeConversationBackgroundTasks);

        await service.startConversationBackgroundTasks();
        await summarized.future.timeout(const Duration(seconds: 5));
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (DateTime.now().isBefore(deadline) &&
            (await store.loadConversationTopicSummaries()).isEmpty) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }

        expect(summaryCalls, 1);
        expect(
          (await store.loadMessageEmbeddings())
              .map((embedding) => embedding.messageId)
              .toSet(),
          {user.id, response.id},
        );
        final topic = (await store.loadConversationTopicSummaries()).single;
        expect(topic.throughMessageId, response.id);
        expect(
          topic.backgroundState['intent'],
          'Remember the stationery preference.',
        );
      },
    );

    test(
      'does not reuse a ready handoff from an inactive regenerated reply',
      () async {
        SharedPreferences.setMockInitialValues({});
        final preferences = await SharedPreferences.getInstance();
        final directory = await Directory.systemTemp.createTemp(
          'sara-handoff-branches-',
        );
        final store = await SqliteMessageStore.openAtPath(
          path.join(directory.path, 'message.sql'),
        );
        addTearDown(() async {
          await store.close();
          await directory.delete(recursive: true);
        });

        final user = ChatMessage(
          id: 'handoff-user',
          role: 'user',
          content: 'Help me think through this decision.',
          timestamp: '2026-01-01 10:00:00',
          createdAtUtc: 1,
        );
        ChatMessage reply(String id, int createdAtUtc) => ChatMessage(
          id: id,
          role: 'model',
          content: 'A distinct response from $id.',
          timestamp: '2026-01-01 10:00:00',
          createdAtUtc: createdAtUtc,
          parentMessageId: user.id,
        );
        final branchAReply = reply('handoff-reply-a', 2);
        final branchBReply = reply('handoff-reply-b', 3);
        await store.saveExchange([user, branchAReply, branchBReply]);
        await store.activateMessageBranch(branchAReply.id);

        final config = _MemoryAiConfigStore()
          ..apiKeys = ['handoff-test-key']
          ..values['ai_model'] = 'gemini-3.5-flash-lite';
        final service = ConversationRagService(
          messageStore: store,
          configStore: config,
          preferences: preferences,
          embeddingProvider: const _FixedEmbeddingProvider(),
          client: MockClient((request) async {
            expect(request.url.path, endsWith(':generateContent'));
            return http.Response(
              jsonEncode({
                'candidates': [
                  {
                    'content': {
                      'parts': [
                        {
                          'text':
                              '{"title":"Decision","summary":"Branch A context.","intent":"Handoff from branch A.","open_threads":[],"memories":[],"resolved_memories":[],"proactive_message":null,"proactive_confidence":0}',
                        },
                      ],
                    },
                  },
                ],
              }),
              200,
            );
          }),
        );
        addTearDown(service.dispose);

        await service.saveExchangeMemory(
          context: const ConversationRagContext(),
          userMessage: user,
          modelMessage: branchAReply,
        );

        await store.activateMessageBranch(branchBReply.id);
        await store.appendMessage(
          ChatMessage(
            id: 'handoff-next-user',
            role: 'user',
            content: 'What should I consider next?',
            timestamp: '2026-01-01 10:01:00',
            createdAtUtc: 4,
            parentMessageId: branchBReply.id,
          ),
        );
        final activeHistory = await store.loadActiveMessages();
        expect(activeHistory.map((message) => message.id), [
          user.id,
          branchBReply.id,
          'handoff-next-user',
        ]);
        expect(service.takeReadyHandoff(activeHistory), isNull);
      },
    );

    test(
      'keeps topic-summary versions isolated when switching branches',
      () async {
        SharedPreferences.setMockInitialValues({});
        final preferences = await SharedPreferences.getInstance();
        final directory = await Directory.systemTemp.createTemp(
          'sara-rag-branches-',
        );
        final store = await SqliteMessageStore.openAtPath(
          path.join(directory.path, 'message.sql'),
        );
        addTearDown(() async {
          await store.close();
          await directory.delete(recursive: true);
        });

        ChatMessage message(
          String id,
          String role,
          int createdAtUtc, {
          String? parentMessageId,
        }) => ChatMessage(
          id: id,
          role: role,
          content: '$role conversation about a shared topic',
          timestamp: '2026-01-01 10:00:00',
          createdAtUtc: createdAtUtc,
          parentMessageId: parentMessageId,
        );

        final root = message('branch-root', 'user', 1);
        final sharedReply = message(
          'branch-shared-reply',
          'model',
          2,
          parentMessageId: root.id,
        );
        final branchAUser = message(
          'branch-a-user',
          'user',
          3,
          parentMessageId: sharedReply.id,
        );
        final branchAReply = message(
          'branch-a-reply',
          'model',
          4,
          parentMessageId: branchAUser.id,
        );
        final branchBUser = message(
          'branch-b-user',
          'user',
          5,
          parentMessageId: sharedReply.id,
        );
        final branchBReply = message(
          'branch-b-reply',
          'model',
          6,
          parentMessageId: branchBUser.id,
        );
        await store.saveExchange([
          root,
          sharedReply,
          branchAUser,
          branchAReply,
          branchBUser,
          branchBReply,
        ]);
        await store.saveMessageEmbeddings([
          for (final item in [sharedReply, branchAReply, branchBReply])
            MessageEmbeddingRecord(
              messageId: item.id,
              topicId: 'shared-topic-family',
              model: LocalE5EmbeddingProvider.modelId,
              values: const [1, 0],
              createdAtUtc: item.createdAtUtc,
            ),
        ]);
        await store.saveConversationMemory(
          topic: ConversationTopicSummary(
            id: 'shared-topic-version',
            title: 'Shared topic',
            summary: 'The summary before the branches diverged.',
            throughMessageId: sharedReply.id,
            updatedAtUtc: 2,
            backgroundState: const {'topic_family_id': 'shared-topic-family'},
          ),
          embeddings: const [],
        );
        await store.saveConversationMemory(
          topic: ConversationTopicSummary(
            id: 'branch-a-topic-version',
            title: 'Branch A topic',
            summary: 'A detail specific to branch A.',
            throughMessageId: branchAReply.id,
            updatedAtUtc: 4,
            backgroundState: const {'topic_family_id': 'shared-topic-family'},
          ),
          embeddings: const [],
        );
        await store.saveConversationTopicEmbeddings([
          for (final topicId in [
            'shared-topic-version',
            'branch-a-topic-version',
          ])
            ConversationTopicEmbeddingRecord(
              topicId: topicId,
              model: LocalE5EmbeddingProvider.modelId,
              values: const [1, 0],
              createdAtUtc: 2,
            ),
        ]);
        await store.activateMessageBranch(branchBUser.id);

        final config = _MemoryAiConfigStore()
          ..apiKeys = ['branch-memory-key']
          ..values['ai_model'] = 'gemini-3.5-flash-lite';
        final service = ConversationRagService(
          messageStore: store,
          configStore: config,
          preferences: preferences,
          embeddingProvider: const _FixedEmbeddingProvider(),
          client: MockClient((request) async {
            if (request.url.path.endsWith(':embedContent')) {
              return http.Response(
                jsonEncode({
                  'embedding': {
                    'values': [1.0, 0.0],
                  },
                }),
                200,
              );
            }
            if (request.url.path.endsWith(':batchEmbedContents')) {
              final body = jsonDecode(request.body) as Map<String, dynamic>;
              return http.Response(
                jsonEncode({
                  'embeddings': [
                    for (
                      var index = 0;
                      index < (body['requests'] as List).length;
                      index++
                    )
                      {
                        'values': [1.0, 0.0],
                      },
                  ],
                }),
                200,
              );
            }
            expect(request.url.path, endsWith(':generateContent'));
            return http.Response(
              jsonEncode({
                'candidates': [
                  {
                    'content': {
                      'parts': [
                        {
                          'text':
                              '{"title":"Branch B topic","summary":"A detail specific to branch B.","intent":"Keep branch B context separate.","open_threads":[],"memories":[],"resolved_memories":[],"proactive_message":null,"proactive_confidence":0}',
                        },
                      ],
                    },
                  },
                ],
              }),
              200,
            );
          }),
        );
        addTearDown(service.dispose);

        final branchBQuery = message(
          'branch-b-query',
          'user',
          7,
          parentMessageId: branchBReply.id,
        );
        await store.appendMessage(branchBQuery);
        final context = await service.retrieveContext(
          await store.loadActiveMessages(),
        );
        expect(context.topicSummaries.single.id, 'shared-topic-version');
        expect(context.forkTopicOnUpdate, isTrue);

        final branchBAnswer = message(
          'branch-b-answer',
          'model',
          8,
          parentMessageId: branchBQuery.id,
        );
        await store.appendMessage(branchBAnswer);
        await service.saveExchangeMemory(
          context: context,
          userMessage: branchBQuery,
          modelMessage: branchBAnswer,
        );

        final topicsAfterBranchB = await store.loadConversationTopicSummaries();
        expect(
          topicsAfterBranchB
              .singleWhere((topic) => topic.id == 'shared-topic-version')
              .throughMessageId,
          sharedReply.id,
        );
        final branchBTopic = topicsAfterBranchB.singleWhere(
          (topic) =>
              topic.id != 'shared-topic-version' &&
              topic.id != 'branch-a-topic-version',
        );
        expect(branchBTopic.throughMessageId, branchBAnswer.id);
        expect(
          branchBTopic.backgroundState['topic_family_id'],
          'shared-topic-family',
        );

        await store.activateMessageBranch(branchAUser.id);
        final branchAQuery = message(
          'branch-a-query',
          'user',
          9,
          parentMessageId: branchAReply.id,
        );
        await store.appendMessage(branchAQuery);
        final branchAContext = await service.retrieveContext(
          await store.loadActiveMessages(),
        );
        expect(
          branchAContext.topicSummaries.single.id,
          'branch-a-topic-version',
        );
        expect(branchAContext.forkTopicOnUpdate, isFalse);
      },
    );

    test('backfills the newly selected branch', () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final directory = await Directory.systemTemp.createTemp(
        'sara-rag-switch-',
      );
      final store = await SqliteMessageStore.openAtPath(
        path.join(directory.path, 'message.sql'),
      );
      addTearDown(() async {
        await store.close();
        await directory.delete(recursive: true);
      });

      ChatMessage message(
        String id,
        String role,
        int createdAtUtc, {
        String? parentMessageId,
      }) => ChatMessage(
        id: id,
        role: role,
        content: '$role shares a meaningful preference about the garden.',
        timestamp: '2026-01-01 10:00:00',
        createdAtUtc: createdAtUtc,
        parentMessageId: parentMessageId,
      );

      final root = message('switch-root', 'user', 1);
      final sharedReply = message(
        'switch-shared-reply',
        'model',
        2,
        parentMessageId: root.id,
      );
      final branchAUser = message(
        'switch-branch-a-user',
        'user',
        3,
        parentMessageId: sharedReply.id,
      );
      final branchAReply = message(
        'switch-branch-a-reply',
        'model',
        4,
        parentMessageId: branchAUser.id,
      );
      final branchBUser = message(
        'switch-branch-b-user',
        'user',
        5,
        parentMessageId: sharedReply.id,
      );
      final branchBReply = message(
        'switch-branch-b-reply',
        'model',
        6,
        parentMessageId: branchBUser.id,
      );
      await store.saveExchange([
        root,
        sharedReply,
        branchAUser,
        branchAReply,
        branchBUser,
        branchBReply,
      ]);
      await store.saveMessageEmbeddings([
        for (final item in [
          root,
          sharedReply,
          branchAUser,
          branchAReply,
          branchBUser,
          branchBReply,
        ])
          MessageEmbeddingRecord(
            messageId: item.id,
            topicId: null,
            model: LocalE5EmbeddingProvider.modelId,
            values: const [1, 0],
            createdAtUtc: item.createdAtUtc,
          ),
      ]);

      final firstSummary = Completer<void>();
      final secondSummary = Completer<void>();
      var summaryCalls = 0;
      final config = _MemoryAiConfigStore()
        ..apiKeys = ['branch-backfill-key']
        ..values['ai_model'] = 'gemini-3.5-flash-lite';
      final service = ConversationRagService(
        messageStore: store,
        configStore: config,
        preferences: preferences,
        embeddingProvider: const _FixedEmbeddingProvider(),
        client: MockClient((request) async {
          expect(request.url.path, endsWith(':generateContent'));
          summaryCalls++;
          if (summaryCalls == 1) firstSummary.complete();
          if (summaryCalls == 2) secondSummary.complete();
          return http.Response(
            jsonEncode({
              'candidates': [
                {
                  'content': {
                    'parts': [
                      {
                        'text':
                            '{"title":"Garden topic","summary":"A meaningful garden preference.","intent":"Remember the garden preference.","open_threads":[],"memories":[],"resolved_memories":[],"proactive_message":null,"proactive_confidence":0}',
                      },
                    ],
                  },
                },
              ],
            }),
            200,
          );
        }),
      );
      addTearDown(service.dispose);

      await service.startBackgroundProcessing();
      await firstSummary.future.timeout(const Duration(seconds: 5));
      final firstDeadline = DateTime.now().add(const Duration(seconds: 5));
      while (DateTime.now().isBefore(firstDeadline) &&
          !(await store.loadConversationTopicSummaries()).any(
            (topic) => topic.throughMessageId == branchBReply.id,
          )) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      await store.activateMessageBranch(branchAUser.id);
      service.scheduleActiveBranchTopicBackfill();
      await secondSummary.future.timeout(const Duration(seconds: 5));
      final secondDeadline = DateTime.now().add(const Duration(seconds: 5));
      while (DateTime.now().isBefore(secondDeadline) &&
          !(await store.loadConversationTopicSummaries()).any(
            (topic) => topic.throughMessageId == branchAReply.id,
          )) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      final summaries = await store.loadConversationTopicSummaries();
      expect(
        summaries.map((topic) => topic.throughMessageId),
        containsAll([branchAReply.id, branchBReply.id]),
      );
      expect(summaryCalls, 2);
    });
  });

  test(
    'SQLite version 22 migrates topic memory tables without losing messages',
    () async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      final directory = await Directory.systemTemp.createTemp('sara-v22-rag-');
      final databasePath = path.join(directory.path, 'message.sql');
      var store = await SqliteMessageStore.openAtPath(databasePath);
      await store.saveMessage(_message(id: 'v22-message', createdAtUtc: 1));
      await store.close();

      final oldDatabase = await databaseFactory.openDatabase(databasePath);
      await oldDatabase.execute('DROP TABLE message_embedding');
      await oldDatabase.execute('DROP TABLE conversation_topic');
      await oldDatabase.execute('PRAGMA user_version = 22');
      await oldDatabase.close();

      store = await SqliteMessageStore.openAtPath(databasePath);
      addTearDown(() async {
        await store.close();
        await directory.delete(recursive: true);
      });
      expect((await store.loadMessages()).single.id, 'v22-message');
      expect(await store.loadConversationTopicSummaries(), isEmpty);
      expect(await store.loadMessageEmbeddings(), isEmpty);
      expect(await store.loadUserMemories(), isEmpty);
      expect(await store.loadConversationMemoryJobs(), isEmpty);
      expect(
        (await store.exportBackupData()).keys,
        containsAll([
          'conversation_topic',
          'message_embedding',
          'user_memory',
          'background_memory_job',
        ]),
      );
    },
  );

  test(
    'SQLite version 24 keeps old vectors during model-index migration',
    () async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      final directory = await Directory.systemTemp.createTemp('sara-v24-rag-');
      final databasePath = path.join(directory.path, 'message.sql');
      var store = await SqliteMessageStore.openAtPath(databasePath);
      final message = _message(id: 'v24-message', createdAtUtc: 1);
      await store.saveMessage(message);
      await store.saveMessageEmbeddings([
        MessageEmbeddingRecord(
          messageId: message.id,
          topicId: null,
          model: 'gemini-embedding-001',
          values: const [0.2, 0.8],
          createdAtUtc: 1,
        ),
      ]);
      await store.close();

      final oldDatabase = await databaseFactory.openDatabase(databasePath);
      await oldDatabase.execute('DROP INDEX message_embedding_topic');
      await oldDatabase.execute(
        'ALTER TABLE message_embedding RENAME TO message_embedding_v25',
      );
      await oldDatabase.execute('''
      CREATE TABLE message_embedding (
        message_id TEXT PRIMARY KEY NOT NULL,
        topic_id TEXT,
        model TEXT NOT NULL,
        embedding TEXT NOT NULL,
        created_at_utc INTEGER NOT NULL
      )
    ''');
      await oldDatabase.execute('''
      INSERT INTO message_embedding
        (message_id, topic_id, model, embedding, created_at_utc)
      SELECT message_id, topic_id, model, embedding, created_at_utc
      FROM message_embedding_v25
    ''');
      await oldDatabase.execute('DROP TABLE message_embedding_v25');
      await oldDatabase.execute('PRAGMA user_version = 24');
      await oldDatabase.close();

      store = await SqliteMessageStore.openAtPath(databasePath);
      addTearDown(() async {
        await store.close();
        await directory.delete(recursive: true);
      });
      await store.saveMessageEmbeddings([
        MessageEmbeddingRecord(
          messageId: message.id,
          topicId: null,
          model: LocalE5EmbeddingProvider.modelId,
          values: const [1, 0],
          createdAtUtc: 2,
        ),
      ]);

      final embeddings = await store.loadMessageEmbeddingsForMessages([
        message.id,
      ]);
      expect(embeddings.map((embedding) => embedding.model), {
        'gemini-embedding-001',
        LocalE5EmbeddingProvider.modelId,
      });
    },
  );

  test('SQLite version 23 adds background topic state', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final directory = await Directory.systemTemp.createTemp('sara-v23-state-');
    final databasePath = path.join(directory.path, 'message.sql');
    final oldDatabase = await databaseFactory.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(
        version: 23,
        onCreate: (database, version) async {
          await database.execute('''
            CREATE TABLE conversation_topic (
              id TEXT PRIMARY KEY NOT NULL,
              title TEXT NOT NULL,
              summary TEXT NOT NULL,
              through_message_id TEXT NOT NULL,
              updated_at_utc INTEGER NOT NULL
            )
          ''');
          await database.insert('conversation_topic', {
            'id': 'old-topic',
            'title': 'Topic',
            'summary': 'Summary',
            'through_message_id': 'message-id',
            'updated_at_utc': 1,
          });
        },
      ),
    );
    await oldDatabase.close();

    final store = await SqliteMessageStore.openAtPath(databasePath);
    addTearDown(() async {
      await store.close();
      await directory.delete(recursive: true);
    });

    final topic = (await store.loadConversationTopicSummaries()).single;
    expect(topic.id, 'old-topic');
    expect(topic.backgroundState, isEmpty);
  });

  test(
    'deleting source messages removes derived topic summaries and vectors',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'sara-rag-delete-',
      );
      final store = await SqliteMessageStore.openAtPath(
        path.join(directory.path, 'message.sql'),
      );
      addTearDown(() async {
        await store.close();
        await directory.delete(recursive: true);
      });
      final user = _message(id: 'rag-delete-user', createdAtUtc: 1);
      final response = _message(
        id: 'rag-delete-response',
        role: 'model',
        createdAtUtc: 2,
        parentMessageId: user.id,
      );
      await store.saveExchange([user, response]);
      await store.saveMessageEmbeddings([
        MessageEmbeddingRecord(
          messageId: user.id,
          topicId: 'delete-topic',
          model: 'gemini-embedding-001',
          values: const [1, 0],
          createdAtUtc: 1,
        ),
        MessageEmbeddingRecord(
          messageId: response.id,
          topicId: 'delete-topic',
          model: 'gemini-embedding-001',
          values: const [0, 1],
          createdAtUtc: 2,
        ),
      ]);
      await store.saveConversationMemory(
        topic: ConversationTopicSummary(
          id: 'delete-topic',
          title: 'Topic',
          summary: 'Derived from these messages.',
          throughMessageId: response.id,
          updatedAtUtc: 2,
        ),
        embeddings: const [],
        userMemories: [
          UserMemoryRecord(
            id: 'delete-memory',
            kind: 'wellbeing',
            memoryKey: 'current_state',
            content: 'Was having a difficult day.',
            confidence: 0.8,
            sourceMessageIds: [user.id],
            createdAtUtc: 2,
            updatedAtUtc: 2,
            expiresAtUtc: 100000,
            embeddingModel: LocalE5EmbeddingProvider.modelId,
            embedding: const [1, 0],
          ),
        ],
      );
      await store.enqueueConversationMemoryJob(
        ConversationMemoryJob(
          id: response.id,
          userMessageId: user.id,
          modelMessageId: response.id,
          queuedAtUtc: 2,
          forkTopicOnUpdate: false,
        ),
      );
      await store.saveConversationTopicEmbeddings([
        const ConversationTopicEmbeddingRecord(
          topicId: 'delete-topic',
          model: 'gemini-embedding-001',
          values: [1, 0],
          createdAtUtc: 2,
        ),
      ]);

      await store.deleteMessage(user.id);
      expect(await store.loadConversationTopicSummaries(), isEmpty);
      expect((await store.loadMessageEmbeddings()).single.topicId, isNull);
      expect(await store.loadConversationTopicEmbeddings(), isEmpty);
      expect(await store.loadUserMemories(), isEmpty);
      expect(await store.loadConversationMemoryJobs(), isEmpty);
      await store.clearMessages();
      expect(await store.loadMessageEmbeddings(), isEmpty);
      expect(await store.loadConversationTopicEmbeddings(), isEmpty);
    },
  );

  test(
    'SQLite message store persists and orders messages by UTC time',
    () async {
      final directory = await Directory.systemTemp.createTemp('sara-db-test-');
      final store = await SqliteMessageStore.openAtPath(
        path.join(directory.path, 'message.sql'),
      );
      addTearDown(() async {
        await store.close();
        await directory.delete(recursive: true);
      });

      await store.saveMessage(_message(id: 'later', createdAtUtc: 20));
      await store.saveMessage(_message(id: 'earlier', createdAtUtc: 10));
      const attachment = ChatAttachment(
        id: 'attachment-id',
        path: '/tmp/photo.png',
        name: 'photo.png',
        mimeType: 'image/png',
      );
      await store.saveMessageAttachments('earlier', [attachment]);
      await store.writePersonalName('Rani');

      expect((await store.loadMessages()).map((message) => message.id), [
        'earlier',
        'later',
      ]);
      final loadedAttachments = (await store.loadAttachments())['earlier']!;
      expect(loadedAttachments, hasLength(1));
      expect(loadedAttachments.single.path, attachment.path);
      expect(loadedAttachments.single.mimeType, attachment.mimeType);
      expect(await store.readPersonalName(), 'Rani');
      await store.deleteMessages(['earlier']);
      expect((await store.loadMessages()).map((message) => message.id), [
        'later',
      ]);
      expect(await store.loadAttachments(), isEmpty);
      await store.clearMessages();
      expect(await store.loadMessages(), isEmpty);
      expect(await store.loadAttachments(), isEmpty);
      expect(await store.readPersonalName(), 'Rani');
      await store.clearPersonalName();
      expect(await store.readPersonalName(), isNull);
      await expectLater(
        store.saveMessage(
          _message(id: 'invalid-role', role: 'assistant', createdAtUtc: 30),
        ),
        throwsA(isA<Exception>()),
      );
    },
  );

  test('SQLite stores terminal activities on message rows', () async {
    final directory = await Directory.systemTemp.createTemp('sara-terminal-');
    final databasePath = path.join(directory.path, 'message.sql');
    var store = await SqliteMessageStore.openAtPath(databasePath);
    addTearDown(() async {
      await store.close();
      await directory.delete(recursive: true);
    });
    final userMessage = _message(id: 'terminal-user', createdAtUtc: 50);
    final responseMessage = _message(
      id: 'terminal-response',
      role: 'model',
      createdAtUtc: 60,
      parentMessageId: userMessage.id,
    );
    await store.saveExchange([userMessage, responseMessage]);
    final activity = TerminalCommandHistoryEntry(
      responseMessageId: responseMessage.id,
      taskContext: 'Inspect a process.',
      command: 'ps aux',
      workingDirectory: '/home/user',
      exitCode: 0,
      stdout: 'process result',
      stderr: '',
      error: null,
      timedOut: false,
      cancelled: false,
      skipped: false,
      outputTruncated: false,
      createdAtUtc: 100,
    );
    await store.saveTerminalCommandActivities(userMessage.id, [activity]);
    await store.close();
    store = await SqliteMessageStore.openAtPath(databasePath);

    final loadedUser = (await store.loadMessages()).singleWhere(
      (message) => message.id == userMessage.id,
    );
    expect(loadedUser.terminalActivities, hasLength(1));
    expect(loadedUser.terminalActivities.single.command, 'ps aux');
    expect(loadedUser.terminalActivities.single.stdout, 'process result');
    final backup = await store.exportBackupData();
    expect(backup, isNot(contains('terminal_command_history')));
    final database = await databaseFactory.openDatabase(databasePath);
    addTearDown(database.close);
    final tables = await database.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table'",
    );
    expect(
      tables.map((row) => row['name']),
      isNot(contains('terminal_command_history')),
    );

    await store.moveTerminalCommandActivities(
      userMessage.id,
      responseMessage.id,
    );
    final movedMessages = await store.loadMessages();
    expect(
      movedMessages
          .singleWhere((message) => message.id == userMessage.id)
          .terminalActivities,
      isEmpty,
    );
    expect(
      movedMessages
          .singleWhere((message) => message.id == responseMessage.id)
          .terminalActivities
          .single
          .command,
      'ps aux',
    );
    await store.clearMessages();
    expect(await store.loadMessages(), isEmpty);
  });

  test('SQLite stores ratings and reactions on response messages', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final directory = await Directory.systemTemp.createTemp('sara-feedback-');
    final store = await SqliteMessageStore.openAtPath(
      path.join(directory.path, 'message.sql'),
    );
    addTearDown(() async {
      await store.close();
      await directory.delete(recursive: true);
    });

    final user = _message(id: 'feedback-user', createdAtUtc: 100);
    final response = _message(
      id: 'feedback-response',
      role: 'model',
      createdAtUtc: 101,
    );
    await store.saveExchange([user, response]);
    await store.saveAssistantFeedback(user.id, response.id, 1);
    await store.saveAssistantReaction(user.id, response.id, '❤️');

    final persisted = (await store.loadMessages()).last;
    expect(persisted.rating, 1);
    expect(persisted.reaction, '❤️');
    expect(await store.loadAssistantFeedback(), {response.id: 1});
    expect(await store.loadAssistantReactions(), {response.id: '❤️'});

    await store.saveAssistantFeedback(user.id, response.id, null);
    expect((await store.loadMessages()).last.reaction, '❤️');
    await store.deleteMessages([response.id]);
    expect(await store.loadAssistantFeedback(), isEmpty);
    expect(await store.loadAssistantReactions(), isEmpty);
  });

  test(
    'SQLite version 19 migration moves feedback and keeps active branches',
    () async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      final directory = await Directory.systemTemp.createTemp('sara-v20-');
      final databasePath = path.join(directory.path, 'message.sql');
      final store = await SqliteMessageStore.openAtPath(databasePath);
      await store.saveExchange([
        _message(id: 'migration-user', createdAtUtc: 100),
        _message(
          id: 'migration-response-a',
          role: 'model',
          createdAtUtc: 101,
          parentMessageId: 'migration-user',
        ),
        _message(
          id: 'migration-response-b',
          role: 'model',
          createdAtUtc: 102,
          parentMessageId: 'migration-user',
        ),
      ]);
      await store.activateMessageBranch('migration-response-a');
      await store.close();

      final legacyDatabase = await databaseFactory.openDatabase(databasePath);
      await legacyDatabase.execute('''
      CREATE TABLE assistant_feedback (
        response_message_id TEXT PRIMARY KEY NOT NULL,
        rating INTEGER,
        reaction TEXT
      )
    ''');
      await legacyDatabase.insert('assistant_feedback', {
        'response_message_id': 'migration-response-a',
        'rating': -1,
        'reaction': '❤️',
      });
      await legacyDatabase.execute(
        'CREATE TABLE conversation_memory (id TEXT)',
      );
      await legacyDatabase.execute(
        'CREATE TABLE sara_private_thought (id TEXT)',
      );
      await legacyDatabase.execute('CREATE TABLE sara_autonomy_goal (id TEXT)');
      await legacyDatabase.execute(
        'CREATE TABLE feedback_preference (id INTEGER)',
      );
      await legacyDatabase.execute('PRAGMA user_version = 19');
      await legacyDatabase.close();

      final migratedStore = await SqliteMessageStore.openAtPath(databasePath);
      addTearDown(() async {
        await migratedStore.close();
        await directory.delete(recursive: true);
      });
      final response = (await migratedStore.loadMessages()).singleWhere(
        (message) => message.id == 'migration-response-a',
      );
      expect(response.rating, -1);
      expect(response.reaction, '❤️');
      expect(
        (await migratedStore.loadActiveMessages()).map((message) => message.id),
        ['migration-user', 'migration-response-a'],
      );
      final backupTables = (await migratedStore.exportBackupData()).keys;
      expect(backupTables, contains('active_child'));
      expect(backupTables, isNot(contains('conversation_state')));
      expect(backupTables, isNot(contains('conversation_memory')));
      final database = await databaseFactory.openDatabase(databasePath);
      addTearDown(database.close);
      final remainingAiTables = await database.query(
        'sqlite_master',
        columns: ['name'],
        where: 'type = ? AND name IN (?, ?, ?, ?, ?)',
        whereArgs: [
          'table',
          'conversation_memory',
          'sara_private_thought',
          'sara_autonomy_goal',
          'assistant_feedback',
          'feedback_preference',
        ],
      );
      expect(remainingAiTables, isEmpty);
    },
  );

  test('Sara JSON backup restores database and attachment file data', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final directory = await Directory.systemTemp.createTemp('sara-backup-');
    final store = await SqliteMessageStore.openAtPath(
      path.join(directory.path, 'message.sql'),
    );
    final supportDirectory = Directory(path.join(directory.path, 'support'));
    final clipboardDirectory = Directory(
      path.join(supportDirectory.path, 'Sara', 'clipboard-attachments'),
    );
    await clipboardDirectory.create(recursive: true);
    final clipboardFile = File(
      path.join(clipboardDirectory.path, 'clipboard.png'),
    );
    final externalFile = File(path.join(directory.path, 'external.png'));
    await clipboardFile.writeAsBytes([1, 2, 3]);
    await externalFile.writeAsBytes([4, 5, 6]);
    final backupService = SaraBackupService(
      supportDirectoryProvider: () async => supportDirectory,
    );
    addTearDown(() async {
      await store.close();
      await directory.delete(recursive: true);
    });

    final user = _message(id: 'backup-user', createdAtUtc: 100);
    final response = _message(
      id: 'backup-response',
      role: 'model',
      createdAtUtc: 101,
      parentMessageId: user.id,
    );
    await store.saveExchange([user, response]);
    await store.writePersonalName('Rani');
    await store.saveMessageAttachments(user.id, [
      ChatAttachment(
        id: 'backup-attachment',
        path: clipboardFile.path,
        name: 'clipboard.png',
        mimeType: 'image/png',
        expiresAtUtc: DateTime.now()
            .toUtc()
            .add(const Duration(hours: 1))
            .millisecondsSinceEpoch,
        isClipboardCopy: true,
      ),
      ChatAttachment(
        id: 'external-attachment',
        path: externalFile.path,
        name: 'external.png',
        mimeType: 'image/png',
        expiresAtUtc: DateTime.now()
            .toUtc()
            .add(const Duration(hours: 1))
            .millisecondsSinceEpoch,
      ),
    ]);
    await store.saveAssistantFeedback(user.id, response.id, 1);
    await store.saveAssistantReaction(user.id, response.id, '❤️');
    await store.saveMessageEmbeddings([
      MessageEmbeddingRecord(
        messageId: user.id,
        topicId: 'backup-topic',
        model: 'gemini-embedding-001',
        values: const [0.25, 0.75],
        createdAtUtc: 100,
      ),
      MessageEmbeddingRecord(
        messageId: user.id,
        topicId: 'backup-topic',
        model: LocalE5EmbeddingProvider.modelId,
        values: const [0.6, 0.8],
        createdAtUtc: 101,
      ),
    ]);
    await store.saveConversationMemory(
      topic: ConversationTopicSummary(
        id: 'backup-topic',
        title: 'Notebook',
        summary: 'Sara suggested a blue notebook.',
        throughMessageId: response.id,
        updatedAtUtc: 101,
        backgroundState: const {
          'intent': 'Remember the notebook preference.',
          'open_threads': ['Choose a notebook size.'],
        },
      ),
      embeddings: const [],
      userMemories: [
        UserMemoryRecord(
          id: 'backup-memory',
          kind: 'preference',
          memoryKey: 'notebook_color',
          content: 'Prefers blue notebooks.',
          confidence: 0.9,
          sourceMessageIds: [user.id],
          createdAtUtc: 101,
          updatedAtUtc: 101,
          embeddingModel: LocalE5EmbeddingProvider.modelId,
          embedding: const [0.6, 0.8],
        ),
      ],
    );
    await store.enqueueConversationMemoryJob(
      ConversationMemoryJob(
        id: response.id,
        userMessageId: user.id,
        modelMessageId: response.id,
        queuedAtUtc: 101,
        forkTopicOnUpdate: false,
      ),
    );
    await store.saveConversationTopicEmbeddings([
      const ConversationTopicEmbeddingRecord(
        topicId: 'backup-topic',
        model: LocalE5EmbeddingProvider.modelId,
        values: [0.6, 0.8],
        createdAtUtc: 101,
      ),
    ]);
    final backupBytes = await backupService.createBackup(store);
    final backupPayload = jsonDecode(utf8.decode(backupBytes)) as Map;
    expect(backupPayload['version'], 5);
    expect((backupPayload['attachment_files'] as Map).length, 2);
    final backupTables = backupPayload['database'] as Map;
    expect(backupTables, isNot(contains('sara_inner_life')));
    expect(backupTables, isNot(contains('sara_inner_life_branch')));
    expect(
      (backupTables['message'] as List).singleWhere(
        (row) => row['id'] == response.id,
      )['rating'],
      1,
    );
    expect(backupTables, isNot(contains('conversation_memory')));
    expect(backupTables, isNot(contains('sara_private_thought')));
    expect(backupTables, isNot(contains('sara_autonomy_goal')));
    expect(backupTables, isNot(contains('assistant_feedback')));
    expect(backupTables, isNot(contains('feedback_preference')));
    expect(backupTables['conversation_topic'], hasLength(1));
    expect(backupTables['message_embedding'], hasLength(2));
    expect(backupTables['conversation_topic_embedding'], hasLength(1));
    expect(backupTables['user_memory'], hasLength(1));
    expect(backupTables['background_memory_job'], hasLength(1));

    await store.writePersonalName('Other');
    await store.saveMessage(_message(id: 'replacement', createdAtUtc: 200));
    final restoreResult = await backupService.restoreBackup(store, backupBytes);
    expect(restoreResult.cleanupErrors, isEmpty);

    expect((await store.loadMessages()).map((message) => message.id), [
      user.id,
      response.id,
    ]);
    expect(await store.readPersonalName(), 'Rani');
    final restoredAttachments = (await store.loadAttachments())[user.id]!;
    final restoredClipboard = restoredAttachments.singleWhere(
      (attachment) => attachment.id == 'backup-attachment',
    );
    final restoredExternal = restoredAttachments.singleWhere(
      (attachment) => attachment.id == 'external-attachment',
    );
    expect(restoredClipboard.path, isNot(clipboardFile.path));
    expect(restoredExternal.path, isNot(externalFile.path));
    expect(restoredClipboard.isClipboardCopy, isTrue);
    expect(restoredExternal.isClipboardCopy, isTrue);
    expect(await File(restoredClipboard.path!).readAsBytes(), [1, 2, 3]);
    expect(await File(restoredExternal.path!).readAsBytes(), [4, 5, 6]);
    expect(await clipboardFile.exists(), isFalse);
    expect(await externalFile.exists(), isTrue);
    expect(await store.loadAssistantFeedback(), {'backup-response': 1});
    expect(await store.loadAssistantReactions(), {'backup-response': '❤️'});
    final restoredTopic = (await store.loadConversationTopicSummaries()).single;
    expect(restoredTopic.title, 'Notebook');
    expect(restoredTopic.backgroundState, {
      'intent': 'Remember the notebook preference.',
      'open_threads': ['Choose a notebook size.'],
    });
    expect(
      {
        for (final embedding in await store.loadMessageEmbeddings())
          embedding.model: embedding.values,
      },
      {
        'gemini-embedding-001': [0.25, 0.75],
        LocalE5EmbeddingProvider.modelId: [0.6, 0.8],
      },
    );
    expect((await store.loadConversationTopicEmbeddings()).single.values, [
      0.6,
      0.8,
    ]);
    expect(
      (await store.loadUserMemories()).single.content,
      'Prefers blue notebooks.',
    );
    expect((await store.loadConversationMemoryJobs()).single.id, response.id);

    final version3Payload = jsonDecode(utf8.decode(backupBytes)) as Map;
    version3Payload['version'] = 3;
    final version3Database = version3Payload['database'] as Map;
    (version3Database['conversation_topic'] as List).single.remove(
      'background_state',
    );
    version3Database
      ..remove('user_memory')
      ..remove('background_memory_job');
    final version3Bytes = Uint8List.fromList(
      utf8.encode(jsonEncode(version3Payload)),
    );
    await backupService.restoreBackup(store, version3Bytes);
    expect(
      (await store.loadConversationTopicSummaries()).single.backgroundState,
      isEmpty,
    );
    expect(await store.loadUserMemories(), isEmpty);
    expect(await store.loadConversationMemoryJobs(), isEmpty);

    final version2Payload = jsonDecode(utf8.decode(backupBytes)) as Map;
    version2Payload['version'] = 2;
    final version2Database = version2Payload['database'] as Map;
    version2Database
      ..remove('conversation_topic')
      ..remove('message_embedding')
      ..remove('conversation_topic_embedding')
      ..remove('user_memory')
      ..remove('background_memory_job');
    final version2Bytes = Uint8List.fromList(
      utf8.encode(jsonEncode(version2Payload)),
    );
    await backupService.restoreBackup(store, version2Bytes);
    expect(await store.loadConversationTopicSummaries(), isEmpty);
    expect(await store.loadMessageEmbeddings(), isEmpty);
    expect(await store.loadUserMemories(), isEmpty);
    expect(await store.loadConversationMemoryJobs(), isEmpty);

    final legacyPayload = jsonDecode(utf8.decode(backupBytes)) as Map;
    legacyPayload['version'] = 1;
    final legacyDatabase = legacyPayload['database'] as Map;
    legacyDatabase.remove('conversation_topic');
    legacyDatabase.remove('message_embedding');
    legacyDatabase.remove('conversation_topic_embedding');
    legacyDatabase.remove('user_memory');
    legacyDatabase.remove('background_memory_job');
    legacyDatabase['sara_inner_life'] = [
      {'mood': 'warm', 'self_reflection': 'Ignored old state.'},
    ];
    legacyDatabase['sara_inner_life_branch'] = [
      {'branch_message_id': response.id, 'mood': 'warm'},
    ];
    legacyDatabase['assistant_feedback'] = [
      {'response_message_id': response.id, 'rating': 1, 'reaction': null},
    ];
    legacyDatabase['conversation_memory'] = [];
    legacyDatabase['sara_private_thought'] = [];
    legacyDatabase['sara_autonomy_goal'] = [];
    legacyDatabase['feedback_preference'] = [];
    final responseBackupRow =
        (legacyDatabase['message'] as List).singleWhere(
              (row) => row['id'] == response.id,
            )
            as Map;
    responseBackupRow.remove('rating');
    responseBackupRow.remove('reaction');
    final legacyBytes = Uint8List.fromList(
      utf8.encode(jsonEncode(legacyPayload)),
    );
    await backupService.restoreBackup(store, legacyBytes);
    expect(await store.loadAssistantFeedback(), {'backup-response': 1});
    expect(await store.loadAssistantReactions(), isEmpty);
    expect(
      (await store.exportBackupData()).keys,
      isNot(contains('sara_inner_life')),
    );
    expect(
      (await store.exportBackupData()).keys,
      isNot(contains('sara_inner_life_branch')),
    );
  });

  test(
    'SQLite expires paths but keeps attachment references for user and AI',
    () async {
      final directory = await Directory.systemTemp.createTemp('sara-db-test-');
      final store = await SqliteMessageStore.openAtPath(
        path.join(directory.path, 'message.sql'),
      );
      addTearDown(() async {
        await store.close();
        await directory.delete(recursive: true);
      });
      final expiresAt = DateTime.now()
          .toUtc()
          .add(const Duration(hours: 24))
          .millisecondsSinceEpoch;
      final userMessage = _message(id: 'user-media', createdAtUtc: 10);
      final modelMessage = _message(
        id: 'model-media',
        role: 'model',
        createdAtUtc: 20,
      );
      final attachment = ChatAttachment(
        id: 'same-media',
        path: '/tmp/photo.png',
        name: 'photo.png',
        mimeType: 'image/png',
        expiresAtUtc: expiresAt,
        isClipboardCopy: true,
      );
      await store.saveExchangeWithAttachments(
        [userMessage, modelMessage],
        userMessage.id,
        [attachment],
        additionalAttachments: {
          modelMessage.id: [attachment],
        },
      );

      expect(await store.loadExpiredAttachments(expiresAt - 1), isEmpty);
      expect(await store.loadExpiredAttachments(expiresAt), hasLength(2));
      await store.expireAttachments(expiresAt);
      final storedAttachments = await store.loadAttachments();
      for (final attachments in storedAttachments.values) {
        expect(attachments.single.path, isNull);
        expect(attachments.single.name, 'photo.png');
        expect(attachments.single.isClipboardCopy, isTrue);
        expect(attachments.single.isExpiredAt(expiresAt), isTrue);
      }
    },
  );

  test('SQLite clears selected temporary attachment paths', () async {
    final directory = await Directory.systemTemp.createTemp('sara-db-test-');
    final store = await SqliteMessageStore.openAtPath(
      path.join(directory.path, 'message.sql'),
    );
    addTearDown(() async {
      await store.close();
      await directory.delete(recursive: true);
    });
    final message = _message(id: 'camera-message', createdAtUtc: 10);
    const cameraPath = '/tmp/sara-camera-photo.png';
    await store.saveMessage(message);
    await store.saveMessageAttachments(message.id, [
      const ChatAttachment(
        id: 'camera-photo',
        path: cameraPath,
        name: 'camera-photo.png',
        mimeType: 'image/png',
        isClipboardCopy: true,
      ),
    ]);

    await store.clearAttachmentPaths([cameraPath]);

    final attachment = (await store.loadAttachments())[message.id]!.single;
    expect(attachment.path, isNull);
    expect(attachment.expiresAtUtc, isNull);
    expect(attachment.name, 'camera-photo.png');
  });

  test('SQLite version 1 database migrates to include personal data', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final directory = await Directory.systemTemp.createTemp('sara-migration-');
    final databasePath = path.join(directory.path, 'message.sql');
    final legacyDatabase = await databaseFactory.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (database, version) async {
          await database.execute('''
            CREATE TABLE message (
              id TEXT PRIMARY KEY NOT NULL,
              role TEXT NOT NULL CHECK (role IN ('user', 'model')),
              type TEXT NOT NULL CHECK (type IN ('text', 'voice_note')),
              content TEXT NOT NULL,
              timestamp TEXT NOT NULL,
              created_at_utc INTEGER NOT NULL
            )
          ''');
          await database.execute(
            'CREATE INDEX message_order ON message(created_at_utc ASC, id ASC)',
          );
        },
      ),
    );
    await legacyDatabase.insert(
      'message',
      _message(
          id: 'legacy',
          createdAtUtc: DateTime.utc(2026, 11, 6, 17).millisecondsSinceEpoch,
        ).toMap()
        ..remove('terminal_command_data')
        ..remove('parent_message_id')
        ..remove('rating')
        ..remove('reaction')
        ..['type'] = 'text',
    );
    await legacyDatabase.close();

    var store = await SqliteMessageStore.openAtPath(databasePath);
    addTearDown(() async {
      await store.close();
      await directory.delete(recursive: true);
    });

    expect(await store.readPersonalName(), isNull);
    expect(
      (await store.loadMessages()).single.timestamp,
      'Sabtu, 7 November 2026, 00:00',
    );
    await store.writePersonalName('Rani');
    expect(await store.readPersonalName(), 'Rani');
  });

  test('SQLite version 20 removes message type and keeps branches', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final directory = await Directory.systemTemp.createTemp('sara-type-v21-');
    final databasePath = path.join(directory.path, 'message.sql');
    final store = await SqliteMessageStore.openAtPath(databasePath);
    await store.saveExchange([
      _message(id: 'legacy-text', createdAtUtc: 1),
      _message(
        id: 'legacy-voice',
        role: 'model',
        createdAtUtc: 2,
        parentMessageId: 'legacy-text',
      ),
      _message(
        id: 'legacy-voice-alternative',
        role: 'model',
        createdAtUtc: 3,
        parentMessageId: 'legacy-text',
      ),
    ]);
    await store.saveAssistantFeedback('legacy-text', 'legacy-voice', 1);
    await store.activateMessageBranch('legacy-voice');
    await store.close();

    final oldDatabase = await databaseFactory.openDatabase(databasePath);
    await oldDatabase.execute(
      "ALTER TABLE message ADD COLUMN type TEXT NOT NULL DEFAULT 'text'",
    );
    await oldDatabase.execute('''
      CREATE TABLE conversation_state (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        active_leaf_message_id TEXT
      )
    ''');
    await oldDatabase.insert('conversation_state', {
      'id': 1,
      'active_leaf_message_id': 'legacy-voice',
    });
    await oldDatabase.execute('''
      CREATE TABLE terminal_command_history (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        response_message_id TEXT,
        task_context TEXT NOT NULL,
        command TEXT NOT NULL,
        working_directory TEXT NOT NULL,
        exit_code INTEGER,
        stdout TEXT NOT NULL,
        stderr TEXT NOT NULL,
        error TEXT,
        timed_out INTEGER NOT NULL,
        cancelled INTEGER NOT NULL,
        skipped INTEGER NOT NULL,
        output_truncated INTEGER NOT NULL,
        created_at_utc INTEGER NOT NULL
      )
    ''');
    final historyId = await oldDatabase.insert('terminal_command_history', {
      'task_context': 'Inspect the requested process.',
      'command': 'ps aux',
      'working_directory': '/home/user',
      'exit_code': 0,
      'stdout': 'process list',
      'stderr': '',
      'timed_out': 0,
      'cancelled': 0,
      'skipped': 0,
      'output_truncated': 0,
      'created_at_utc': 4,
    });
    await oldDatabase.execute('''
      CREATE TABLE terminal_command_activity_link (
        terminal_history_id INTEGER NOT NULL,
        response_message_id TEXT NOT NULL,
        PRIMARY KEY (terminal_history_id, response_message_id)
      )
    ''');
    await oldDatabase.insert('terminal_command_activity_link', {
      'terminal_history_id': historyId,
      'response_message_id': 'legacy-voice',
    });
    await oldDatabase.insert('terminal_command_activity_link', {
      'terminal_history_id': historyId,
      'response_message_id': 'legacy-voice-alternative',
    });
    await oldDatabase.execute('PRAGMA user_version = 20');
    await oldDatabase.close();

    final migratedStore = await SqliteMessageStore.openAtPath(databasePath);
    addTearDown(() async {
      await migratedStore.close();
      await directory.delete(recursive: true);
    });
    final messages = await migratedStore.loadMessages();
    expect(messages.map((message) => message.id), [
      'legacy-text',
      'legacy-voice',
      'legacy-voice-alternative',
    ]);
    final migratedResponse = messages.singleWhere(
      (message) => message.id == 'legacy-voice',
    );
    expect(migratedResponse.rating, 1);
    expect(migratedResponse.parentMessageId, 'legacy-text');
    expect(
      (await migratedStore.loadActiveMessages()).map((message) => message.id),
      ['legacy-text', 'legacy-voice'],
    );
    final migratedActivitiesA = messages.singleWhere(
      (message) => message.id == 'legacy-voice',
    );
    final migratedActivitiesB = messages.singleWhere(
      (message) => message.id == 'legacy-voice-alternative',
    );
    expect(migratedActivitiesA.terminalActivities, hasLength(1));
    expect(migratedActivitiesB.terminalActivities, hasLength(1));
    expect(migratedActivitiesA.terminalActivities.single.command, 'ps aux');
    expect(migratedActivitiesB.terminalActivities.single.command, 'ps aux');
    final schemaDatabase = await databaseFactory.openDatabase(databasePath);
    addTearDown(schemaDatabase.close);
    final columns = await schemaDatabase.rawQuery('PRAGMA table_info(message)');
    expect(columns.map((column) => column['name']), isNot(contains('type')));
    final tableNames = (await schemaDatabase.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table'",
    )).map((table) => table['name']);
    expect(tableNames, isNot(contains('conversation_state')));
    expect(tableNames, isNot(contains('terminal_command_history')));
  });

  test(
    'SQLite branches restore the selected path and delete only a subtree',
    () async {
      final directory = await Directory.systemTemp.createTemp('sara-branches-');
      final databasePath = path.join(directory.path, 'message.sql');
      var store = await SqliteMessageStore.openAtPath(databasePath);
      addTearDown(() async {
        await store.close();
        await directory.delete(recursive: true);
      });

      await store.saveExchange([
        _message(id: 'a', createdAtUtc: 1),
        _message(
          id: 'b1',
          role: 'model',
          createdAtUtc: 2,
          parentMessageId: 'a',
        ),
        _message(id: 'c1', createdAtUtc: 3, parentMessageId: 'b1'),
        _message(
          id: 'd1',
          role: 'model',
          createdAtUtc: 4,
          parentMessageId: 'c1',
        ),
        _message(
          id: 'b2',
          role: 'model',
          createdAtUtc: 5,
          parentMessageId: 'a',
        ),
        _message(id: 'c2', createdAtUtc: 6, parentMessageId: 'b2'),
        _message(
          id: 'd2',
          role: 'model',
          createdAtUtc: 7,
          parentMessageId: 'c2',
        ),
      ]);

      expect((await store.loadActiveMessages()).map((message) => message.id), [
        'a',
        'b2',
        'c2',
        'd2',
      ]);
      final branches = await store.loadMessageBranches();
      expect(branches['b1']!.alternatives, ['b1', 'b2']);
      await store.activateMessageBranch('b1');
      await store.close();
      store = await SqliteMessageStore.openAtPath(databasePath);
      expect((await store.loadActiveMessages()).map((message) => message.id), [
        'a',
        'b1',
        'c1',
        'd1',
      ]);
      final deleted = await store.loadSubtreeMessageIds('c1');
      await store.deleteMessages(deleted);
      expect((await store.loadActiveMessages()).map((message) => message.id), [
        'a',
        'b1',
      ]);
      expect((await store.loadMessages()).map((message) => message.id), [
        'a',
        'b1',
        'b2',
        'c2',
        'd2',
      ]);
      await store.saveAssistantReaction('a', 'b1', '❤️');
      final deletedResponseBranch = await store.loadSubtreeMessageIds('b1');
      await store.deleteMessages(deletedResponseBranch);
      expect((await store.loadActiveMessages()).map((message) => message.id), [
        'a',
        'b2',
        'c2',
        'd2',
      ]);
      expect((await store.loadMessages()).map((message) => message.id), [
        'a',
        'b2',
        'c2',
        'd2',
      ]);
      expect(await store.loadAssistantReactions(), isEmpty);
    },
  );

  test(
    'SQLite exposes edited user messages as navigable sibling branches',
    () async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      final directory = await Directory.systemTemp.createTemp(
        'sara-user-branch-',
      );
      final store = await SqliteMessageStore.openAtPath(
        path.join(directory.path, 'message.sql'),
      );
      addTearDown(() async {
        await store.close();
        await directory.delete(recursive: true);
      });
      await store.saveExchange([
        _message(id: 'root-user', createdAtUtc: 1),
        _message(
          id: 'root-reply',
          role: 'model',
          createdAtUtc: 2,
          parentMessageId: 'root-user',
        ),
        _message(
          id: 'original-user',
          createdAtUtc: 3,
          parentMessageId: 'root-reply',
        ),
        _message(
          id: 'original-response',
          role: 'model',
          createdAtUtc: 4,
          parentMessageId: 'original-user',
        ),
        _message(
          id: 'edited-user',
          createdAtUtc: 5,
          parentMessageId: 'root-reply',
        ),
        _message(
          id: 'edited-response',
          role: 'model',
          createdAtUtc: 6,
          parentMessageId: 'edited-user',
        ),
      ]);

      final branches = await store.loadMessageBranches();
      expect(branches['edited-user']!.alternatives, [
        'original-user',
        'edited-user',
      ]);
      expect(branches['edited-user']!.activeIndex, 1);
      await store.activateMessageBranch('original-user');
      expect((await store.loadActiveMessages()).map((message) => message.id), [
        'root-user',
        'root-reply',
        'original-user',
        'original-response',
      ]);
    },
  );

  test('SQLite version 3 database migrates to include attachments', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final directory = await Directory.systemTemp.createTemp('sara-migration-');
    final databasePath = path.join(directory.path, 'message.sql');
    final legacyDatabase = await databaseFactory.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(
        version: 3,
        onCreate: (database, version) async {
          await database.execute('''
            CREATE TABLE message (
              id TEXT PRIMARY KEY NOT NULL,
              role TEXT NOT NULL CHECK (role IN ('user', 'model')),
              type TEXT NOT NULL CHECK (type IN ('text', 'voice_note')),
              content TEXT NOT NULL,
              timestamp TEXT NOT NULL,
              created_at_utc INTEGER NOT NULL
            )
          ''');
          await database.execute(
            'CREATE INDEX message_order ON message(created_at_utc ASC, id ASC)',
          );
          await database.execute('''
            CREATE TABLE personal (
              id INTEGER PRIMARY KEY CHECK (id = 1),
              name TEXT NOT NULL
            )
          ''');
        },
      ),
    );
    await legacyDatabase.close();

    final store = await SqliteMessageStore.openAtPath(databasePath);
    addTearDown(() async {
      await store.close();
      await directory.delete(recursive: true);
    });
    expect(await store.loadAttachments(), isEmpty);
    const attachment = ChatAttachment(
      id: 'legacy-attachment',
      path: '/tmp/legacy.png',
      name: 'legacy.png',
      mimeType: 'image/png',
    );
    await store.saveMessage(_message(id: 'legacy', createdAtUtc: 10));
    await store.saveMessageAttachments('legacy', [attachment]);
    final loadedAttachments = (await store.loadAttachments())['legacy']!;
    expect(loadedAttachments, hasLength(1));
    expect(loadedAttachments.single.path, attachment.path);
  });

  test(
    'SQLite version 4 attachment rows migrate with message-based expiry',
    () async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      final directory = await Directory.systemTemp.createTemp(
        'sara-migration-',
      );
      final databasePath = path.join(directory.path, 'message.sql');
      final createdAt = DateTime.now()
          .toUtc()
          .subtract(const Duration(hours: 48))
          .millisecondsSinceEpoch;
      final legacyDatabase = await databaseFactory.openDatabase(
        databasePath,
        options: OpenDatabaseOptions(
          version: 4,
          onCreate: (database, version) async {
            await database.execute('''
            CREATE TABLE message (
              id TEXT PRIMARY KEY NOT NULL,
              role TEXT NOT NULL CHECK (role IN ('user', 'model')),
              type TEXT NOT NULL CHECK (type IN ('text', 'voice_note')),
              content TEXT NOT NULL,
              timestamp TEXT NOT NULL,
              created_at_utc INTEGER NOT NULL
            )
          ''');
            await database.execute(
              'CREATE INDEX message_order ON message(created_at_utc ASC, id ASC)',
            );
            await database.execute('''
            CREATE TABLE personal (
              id INTEGER PRIMARY KEY CHECK (id = 1),
              name TEXT NOT NULL
            )
          ''');
            await database.execute('''
            CREATE TABLE message_attachment (
              id TEXT PRIMARY KEY NOT NULL,
              message_id TEXT NOT NULL,
              path TEXT NOT NULL,
              name TEXT NOT NULL,
              mime_type TEXT NOT NULL
            )
          ''');
          },
        ),
      );
      await legacyDatabase.insert(
        'message',
        (_message(id: 'legacy-user', createdAtUtc: createdAt).toMap()
          ..remove('terminal_command_data')
          ..remove('parent_message_id')
          ..remove('rating')
          ..remove('reaction')
          ..['type'] = 'text'),
      );
      await legacyDatabase.insert('message_attachment', {
        'id': 'legacy-image',
        'message_id': 'legacy-user',
        'path': '/tmp/legacy.png',
        'name': 'legacy.png',
        'mime_type': 'image/png',
      });
      await legacyDatabase.close();

      final store = await SqliteMessageStore.openAtPath(databasePath);
      addTearDown(() async {
        await store.close();
        await directory.delete(recursive: true);
      });
      final attachment = (await store.loadAttachments())['legacy-user']!.single;
      expect(attachment.path, '/tmp/legacy.png');
      expect(
        attachment.expiresAtUtc,
        createdAt + const Duration(hours: 24).inMilliseconds,
      );
      expect(attachment.isClipboardCopy, isFalse);
      expect(
        await store.loadExpiredAttachments(
          DateTime.now().toUtc().millisecondsSinceEpoch,
        ),
        hasLength(1),
      );
    },
  );
}

const _userMessage = ChatMessage(
  id: 'user-id',
  role: 'user',
  content: 'Hi',
  timestamp: '2026-01-01 10:00:00',
  createdAtUtc: 1767261600000,
);

ChatMessage _message({
  required String id,
  String role = 'user',
  required int createdAtUtc,
  String? parentMessageId,
}) {
  return ChatMessage(
    id: id,
    role: role,
    content: id,
    timestamp: '2026-01-01 10:00:00',
    createdAtUtc: createdAtUtc,
    parentMessageId: parentMessageId,
  );
}

Future<File> _createQrImage(Directory directory, String text) async {
  final matrix = QRCodeWriter().encode(text, BarcodeFormat.qrCode, 240, 240);
  final image = img.Image(
    width: matrix.width,
    height: matrix.height,
    numChannels: 3,
  );
  for (var y = 0; y < matrix.height; y++) {
    for (var x = 0; x < matrix.width; x++) {
      final value = matrix.get(x, y) ? 0 : 255;
      image.setPixelRgb(x, y, value, value, value);
    }
  }
  final file = File(path.join(directory.path, 'barcode.png'));
  await file.writeAsBytes(img.encodePng(image));
  return file;
}

class _FixedEmbeddingProvider implements ConversationEmbeddingProvider {
  const _FixedEmbeddingProvider();

  @override
  String get embeddingModelId => LocalE5EmbeddingProvider.modelId;

  @override
  bool get isReady => true;

  @override
  Future<void> ensureReady() async {}

  @override
  Future<List<double>> embedQuery(String text) async => const [1, 0];

  @override
  Future<List<List<double>>> embedDocuments(List<String> texts) async =>
      List.generate(texts.length, (_) => const [1, 0]);

  @override
  Future<void> dispose() async {}
}

class _MemoryAiConfigStore implements AiConfigStore {
  final values = <String, String>{};
  List<String> apiKeys = [];

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }

  @override
  Future<List<String>> readApiKeys() async => [...apiKeys];

  @override
  Future<void> writeApiKeys(List<String> value) async {
    apiKeys = [...value];
  }
}
