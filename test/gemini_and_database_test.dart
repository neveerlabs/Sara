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
import 'package:sara_desktop/gemini_reply_service.dart';
import 'package:sara_desktop/conversation_memory.dart';
import 'package:sara_desktop/message_database.dart';
import 'package:sara_desktop/sara_backup.dart';
import 'package:sara_desktop/sara_autonomy.dart';
import 'package:sara_desktop/sara_inner_life.dart';
import 'package:sara_desktop/terminal_command.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zxing_lib/src/barcode_format.dart';
import 'package:zxing_lib/src/qrcode/qrcode_writer.dart';

void main() {
  test('formats UTC timestamps in Indonesian WIB date format', () {
    final saturdayNovemberSeventh =
        DateTime.utc(2026, 11, 6, 17).millisecondsSinceEpoch;
    expect(
      formatJakartaTimestamp(saturdayNovemberSeventh),
      'Sabtu, 7 November 2026, 00:00',
    );
  });

  test('simulated inner state gradually returns toward its baseline', () {
    final oldState = SaraInnerLife(
      mood: 'angry',
      moodIntensity: 100,
      energy: 0,
      drives: const {
        'connection': 100,
        'curiosity': 0,
        'autonomy': 100,
        'security': 0,
      },
      selfReflection: 'An earlier reflection.',
      sourceMessageIds: const ['source'],
      updatedAtUtc: 1000,
    );
    final afterOneDay =
        oldState.asOf(1000 + const Duration(hours: 24).inMilliseconds);
    expect(afterOneDay.moodIntensity, lessThan(100));
    expect(afterOneDay.energy, greaterThan(0));
    expect(afterOneDay.drives['connection'], lessThan(100));
    expect(afterOneDay.mood, 'angry');
    expect(afterOneDay.selfReflection, oldState.selfReflection);
  });

  test('autonomous inner-life numbers accept rounded bounded JSON decimals',
      () {
    final state = SaraAutonomyInnerLife.fromJson({
      'mood': 'curious',
      'moodIntensity': 42.6,
      'energy': 70.0,
      'drives': {
        'connection': 50.2,
        'curiosity': 81.7,
        'autonomy': 49.5,
        'security': 100.0,
      },
    });

    expect(state.moodIntensity, 43);
    expect(state.energy, 70);
    expect(state.drives, {
      'connection': 50,
      'curiosity': 82,
      'autonomy': 50,
      'security': 100,
    });
    expect(
      () => SaraAutonomyInnerLife.fromJson({
        'mood': 'curious',
        'moodIntensity': 101.2,
        'energy': 70,
        'drives': {
          'connection': 50,
          'curiosity': 50,
          'autonomy': 50,
          'security': 50,
        },
      }),
      throwsA(isA<FormatException>()),
    );
  });

  test('invalid autonomous inner-life fields preserve prior values', () {
    final fallback = SaraAutonomyInnerLife.fromSummary(jsonEncode({
      'mood': 'warm',
      'mood_intensity': 44,
      'energy': 63,
      'drives_json': jsonEncode({
        'connection': 71,
        'curiosity': 52,
        'autonomy': 49,
        'security': 68,
      }),
    }));
    final invalidFields = <String>[];
    final state = SaraAutonomyInnerLife.fromJson(
      {
        'mood': 'unknown',
        'moodIntensity': 'not-a-number',
        'energy': 75,
        'drives': {
          'connection': 95,
        },
      },
      fallback: fallback,
      onInvalidFields: invalidFields.addAll,
    );

    expect(state.mood, 'warm');
    expect(state.moodIntensity, 44);
    expect(state.energy, 75);
    expect(state.drives, {
      'connection': 95,
      'curiosity': 52,
      'autonomy': 49,
      'security': 68,
    });
    expect(
      invalidFields,
      containsAll([
        'mood',
        'moodIntensity',
        'drives.curiosity',
        'drives.autonomy',
        'drives.security',
      ]),
    );
  });

  group('GeminiReplyService', () {
    test('autonomous cycle returns a structured private decision', () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final config = _MemoryAiConfigStore()
        ..apiKeys = ['autonomy-key']
        ..values['ai_model'] = 'gemini-3.5-flash-lite';
      Map<String, dynamic>? requestBody;
      final service = GeminiReplyService(
        configStore: config,
        preferences: preferences,
        autonomyClientFactory: () => MockClient((request) async {
          requestBody = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            'data: ${jsonEncode({
                  'candidates': [
                    {
                      'content': {
                        'parts': [
                          {
                            'text': jsonEncode({
                              'memoryQuery': '',
                              'reflection': List.filled(
                                      80, 'A nuanced private reflection.')
                                  .join(' '),
                              'remember': true,
                              'sourceMessageIds': ['invented-message-id', 42],
                              'action': 'reach_out',
                              'nextCheckMinutes': 30.6,
                              'message': 'Eh, kepikiran obrolan kita tadi.',
                              'innerLife': {
                                'mood': 'curious',
                                'moodIntensity': 40,
                                'energy': 70,
                                'drives': {
                                  'connection': 50,
                                  'curiosity': 60,
                                  'autonomy': 50,
                                  'security': 50,
                                },
                              },
                              'goalUpdates': [
                                {
                                  'id': '',
                                  'title': 'Remember the music conversation',
                                  'description':
                                      'Bring up the shared music topic later.',
                                  'status': 'active',
                                  'sourceMessageIds': [],
                                },
                              ],
                            }),
                          },
                        ],
                      },
                    },
                  ],
                })}\n\n',
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        }),
      );

      final decision = await service.thinkAutonomously(
        activeMessageIds: const [],
        personalName: 'Rani',
        innerLifeSummary: '{"mood":"curious"}',
        currentGoals: const [],
      );
      expect(decision.action, 'reach_out');
      expect(decision.message, 'Eh, kepikiran obrolan kita tadi.');
      expect(decision.nextCheckMinutes, 31);
      expect(decision.reflection.length, greaterThan(500));
      expect(decision.innerLife.mood, 'curious');
      expect(decision.sourceMessageIds, isEmpty);
      expect(
          decision.goalUpdates.single.title, 'Remember the music conversation');
      expect(
        requestBody!['generationConfig']['responseMimeType'],
        'application/json',
      );
      final autonomyPrompt =
          requestBody!['systemInstruction']['parts'][0]['text'] as String;
      expect(autonomyPrompt, contains('Do not mock, roast, belittle'));
      expect(autonomyPrompt, contains('Do not add laughter by habit'));
      expect(autonomyPrompt, contains('aku-kamu phrasing'));
      expect(autonomyPrompt, contains('Never invent, guess'));
      expect(autonomyPrompt, contains('500-2500 characters'));
      expect(requestBody!['tools'], isNull);
      final sentText =
          requestBody!['contents'][0]['parts'][0]['text'] as String;
      expect(sentText, isNot(contains('recentPrivateReflections')));
      expect(sentText, isNot(contains('recentConversation')));
      expect(sentText, contains('curious'));
    });

    test('autonomous camera tool supports repeated temporary frames', () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final config = _MemoryAiConfigStore()
        ..apiKeys = ['autonomy-camera-key']
        ..values['ai_model'] = 'gemini-3.5-flash-lite';
      var requests = 0;
      var captures = 0;
      var disposedFrames = 0;
      final service = GeminiReplyService(
        configStore: config,
        preferences: preferences,
        autonomyClientFactory: () => MockClient((request) async {
          requests++;
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['tools'], isNotNull);
          expect(body['generationConfig']['responseMimeType'], isNull);
          if (requests > 1) {
            final contents = body['contents'] as List;
            final lastUserParts =
                (contents.last as Map<String, dynamic>)['parts'] as List;
            expect(
              lastUserParts.any((part) =>
                  (part as Map<String, dynamic>).containsKey('inlineData')),
              isTrue,
            );
            expect(
              jsonEncode(lastUserParts),
              contains('/9j/2Q=='),
            );
          }
          final parts = requests < 3
              ? [
                  {
                    'functionCall': {
                      'name': 'sara_look_through_camera',
                      'args': <String, Object?>{},
                    },
                  },
                ]
              : [
                  {
                    'text': '```json\n${jsonEncode({
                          'memoryQuery': '',
                          'reflection': 'The light in the room feels calm.',
                          'remember': false,
                          'sourceMessageIds': [],
                          'action': 'think',
                          'nextCheckMinutes': 30,
                          'message': '',
                          'innerLife': {
                            'mood': 'calm',
                            'moodIntensity': 25,
                            'energy': 65,
                            'drives': {
                              'connection': 50,
                              'curiosity': 50,
                              'autonomy': 50,
                              'security': 50,
                            },
                          },
                          'goalUpdates': [],
                        })}\n```',
                  },
                ];
          return http.Response(
            'data: ${jsonEncode({
                  'candidates': [
                    {
                      'content': {'parts': parts},
                    },
                  ],
                })}\n\n',
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        }),
      );

      final decision = await service.thinkAutonomously(
        activeMessageIds: const [],
        personalName: null,
        innerLifeSummary: '{}',
        currentGoals: const [],
        captureCameraFrame: () async {
          captures++;
          return CameraFrame(
            bytes: Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]),
            dispose: () async {
              disposedFrames++;
            },
          );
        },
      );

      expect(requests, 3);
      expect(captures, 2);
      expect(disposedFrames, 2);
      expect(decision.reflection, 'The light in the room feels calm.');
    });

    test('malformed autonomous output does not invalidate the API key',
        () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final config = _MemoryAiConfigStore()
        ..apiKeys = ['valid-key']
        ..values['ai_model'] = 'gemini-3.5-flash-lite';
      final service = GeminiReplyService(
        configStore: config,
        preferences: preferences,
        autonomyClientFactory: () => MockClient((_) async {
          return http.Response(
            'data: ${jsonEncode({
                  'candidates': [
                    {
                      'content': {
                        'parts': [
                          {
                            'text': jsonEncode({
                              'memoryQuery': '',
                              'reflection': 'A private reflection.',
                              'remember': false,
                              'sourceMessageIds': [],
                              'action': 'think',
                              'nextCheckMinutes': 'not-a-number',
                              'message': '',
                              'innerLife': {
                                'mood': 'curious',
                                'moodIntensity': 40,
                                'energy': 70,
                                'drives': {
                                  'connection': 50,
                                  'curiosity': 60,
                                  'autonomy': 50,
                                  'security': 50,
                                },
                              },
                              'goalUpdates': [],
                            }),
                          },
                        ],
                      },
                    },
                  ],
                })}\n\n',
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        }),
      );

      await expectLater(
        service.thinkAutonomously(
          activeMessageIds: const [],
          personalName: null,
          innerLifeSummary: '{}',
          currentGoals: const [],
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message.toString(),
            'message',
            contains('nextCheckMinutes'),
          ),
        ),
      );
      expect(
        preferences.getStringList('failed_gemini_key_fingerprints'),
        isEmpty,
      );
    });

    test('autonomous thinking reads private memories only when requested',
        () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final config = _MemoryAiConfigStore()
        ..apiKeys = ['autonomy-memory-key']
        ..values['ai_model'] = 'gemini-3.5-flash-lite';
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      final directory =
          await Directory.systemTemp.createTemp('sara-auto-memory-');
      final memoryStore = await SqliteMessageStore.openAtPath(
        path.join(directory.path, 'message.sql'),
      );
      await memoryStore.savePrivateThought(const SaraPrivateThought(
        id: 'old-jazz-thought',
        reflection: 'I would like to explore jazz improvisation.',
        action: 'think',
        isRemembered: true,
        sourceMessageIds: [],
        createdAtUtc: 2,
      ));
      addTearDown(() async {
        await memoryStore.close();
        await directory.delete(recursive: true);
      });

      var requests = 0;
      final service = GeminiReplyService(
        configStore: config,
        preferences: preferences,
        memoryStore: memoryStore,
        autonomyClientFactory: () => MockClient((request) async {
          requests++;
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          if (requests == 1) {
            return http.Response(
              'data: ${jsonEncode({
                    'candidates': [
                      {
                        'content': {
                          'parts': [
                            {
                              'text': jsonEncode({
                                'memoryQuery': 'jazz improvisation',
                              }),
                            },
                          ],
                        },
                      },
                    ],
                  })}\n\n',
              200,
              headers: {'content-type': 'text/event-stream'},
            );
          }
          final sent = jsonEncode(body['contents']);
          expect(sent, contains('I would like to explore jazz improvisation.'));
          return http.Response(
            'data: ${jsonEncode({
                  'candidates': [
                    {
                      'content': {
                        'parts': [
                          {
                            'text': jsonEncode({
                              'memoryQuery': '',
                              'reflection':
                                  'I am still curious about jazz improvisation.',
                              'remember': false,
                              'sourceMessageIds': [],
                              'action': 'think',
                              'nextCheckMinutes': 30,
                              'message': '',
                              'innerLife': {
                                'mood': 'curious',
                                'moodIntensity': 40,
                                'energy': 70,
                                'drives': {
                                  'connection': 50,
                                  'curiosity': 60,
                                  'autonomy': 50,
                                  'security': 50,
                                },
                              },
                              'goalUpdates': [],
                            }),
                          },
                        ],
                      },
                    },
                  ],
                })}\n\n',
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        }),
      );

      final decision = await service.thinkAutonomously(
        activeMessageIds: const [],
        personalName: null,
        innerLifeSummary: '{}',
        currentGoals: const [],
      );

      expect(requests, 2);
      expect(
          decision.reflection, 'I am still curious about jazz improvisation.');
      expect(decision.remember, isFalse);
    });

    test('regenerate request includes previous alternative replies as context',
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
          final contents = body['contents'] as List<dynamic>;
          final latestParts =
              (contents.last as Map<String, dynamic>)['parts'] as List<dynamic>;
          final branchContext = latestParts
              .map((part) => jsonDecode((part as Map<String, dynamic>)['text']))
              .whereType<Map<String, dynamic>>()
              .firstWhere(
                (part) => part.containsKey('previous_alternative_ai_replies'),
              );
          expect(
            branchContext['previous_alternative_ai_replies'],
            [
              {'role': 'model', 'content': 'Earlier alternative'}
            ],
          );
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
          thinkingEnabled: true,
          previousBranchReplies: const [
            ChatMessage(
              id: 'old-branch',
              role: 'model',
              type: 'text',
              content: 'Earlier alternative',
              timestamp: 'today',
              createdAtUtc: 2,
            ),
          ],
        ),
        'New reply',
      );
    });

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
        await service.generateReply(
          [_userMessage],
          thinkingEnabled: false,
          onText: updates.add,
        ),
        'Hello there',
      );
      expect(updates, ['Hello', 'Hello there']);
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
              systemInstruction, contains('optional sara_look_through_camera'));
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
          expect(
            cameraParts.last['inlineData'],
            {
              'mimeType': 'image/jpeg',
              'data': '/9j/2Q==',
            },
          );
          return http.Response(
            'data: {"candidates":[{"content":{"parts":[{"text":"Kelihatannya terang."}]}}]}\n\n',
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        }),
      );

      final reply = await service.generateReply(
        [_userMessage],
        thinkingEnabled: true,
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

    test('terminal tool waits for approval and returns command output to Sara',
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
        thinkingEnabled: true,
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
    });

    test('terminal commands are not capped by an application count limit',
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
        thinkingEnabled: true,
        approveTerminalCommand: (_) async => TerminalApprovalDecision.allowAll,
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
    });

    test('Sara can search saved terminal attempts before proposing a command',
        () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final config = _MemoryAiConfigStore()
        ..apiKeys = ['terminal-history-key']
        ..values['ai_model'] = 'gemini-3.5-flash-lite';
      final directory = await Directory.systemTemp.createTemp('sara-history-');
      final memoryStore = await SqliteMessageStore.openAtPath(
        path.join(directory.path, 'message.sql'),
      );
      addTearDown(() async {
        await memoryStore.close();
        await directory.delete(recursive: true);
      });
      await memoryStore.saveTerminalCommandHistory(
        TerminalCommandHistoryEntry(
          taskContext: 'Check why the Thunar process is frozen.',
          command: 'pgrep -a thunar',
          workingDirectory: '/home/user',
          exitCode: 1,
          stdout: '',
          stderr: '',
          error: null,
          timedOut: false,
          cancelled: false,
          skipped: false,
          outputTruncated: false,
          createdAtUtc: DateTime.now().toUtc().millisecondsSinceEpoch,
        ),
      );
      var requests = 0;
      final service = GeminiReplyService(
        configStore: config,
        preferences: preferences,
        memoryStore: memoryStore,
        client: MockClient((request) async {
          requests++;
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final declarations =
              (body['tools'][0]['functionDeclarations'] as List)
                  .cast<Map<String, dynamic>>();
          expect(
            declarations.any(
              (tool) => tool['name'] == 'search_terminal_command_history',
            ),
            isTrue,
          );
          if (requests == 1) {
            return http.Response(
              'data: {"candidates":[{"content":{"parts":[{"functionCall":'
              '{"name":"search_terminal_command_history","args":'
              '{"query":"Thunar process"}}}]}}]}\n\n',
              200,
              headers: {'content-type': 'text/event-stream'},
            );
          }
          final contents = body['contents'] as List;
          final toolResponse =
              (contents.last as Map<String, dynamic>)['parts'] as List;
          final attempts = toolResponse.first['functionResponse']['response']
              ['attempts'] as List;
          expect(attempts, hasLength(1));
          expect(attempts.single['command'], 'pgrep -a thunar');
          expect(attempts.single['exitCode'], 1);
          return http.Response(
            'data: {"candidates":[{"content":{"parts":[{"text":"I found the earlier failed attempt."}]}}]}\n\n',
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        }),
      );

      final reply = await service.generateReply(
        [_userMessage],
        thinkingEnabled: true,
        approveTerminalCommand: (_) async => TerminalApprovalDecision.skip,
        executeTerminalCommand: (_) async => throw StateError(
          'History search should not execute a shell command.',
        ),
      );

      expect(reply, 'I found the earlier failed attempt.');
      expect(requests, 2);
    });

    test('accepts an empty SSE completion when the model chooses silence',
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
          expect(
            instructions,
            contains('clearly ending the conversation'),
          );
          expect(instructions, contains('recognizable voice and continuity'));
          expect(instructions,
              contains('If you choose silence, return no user-facing text'));
          return http.Response(
            'data: {"candidates":[{"content":{"parts":[]},'
            '"finishReason":"STOP"}]}\n\n',
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        }),
      );

      expect(
        await service.generateReply(
          [_userMessage],
          thinkingEnabled: false,
        ),
        isEmpty,
      );
    });

    test('sends local file bytes as inline data without changing the path',
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
          thinkingEnabled: false,
          attachmentsByMessage: {
            _userMessage.id: [attachment],
          },
        ),
        'I see the image.',
      );
      final contents = requestBody!['contents'] as List;
      final parts = (contents.first as Map)['parts'] as List;
      expect(parts, hasLength(2));
      expect(
        (parts[1] as Map)['inlineData'],
        {
          'mimeType': 'image/png',
          'data': base64Encode(bytes),
        },
      );
      expect(File(attachmentPath).existsSync(), isTrue);
    });

    test('sends arbitrary files but never includes environment files',
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
          thinkingEnabled: false,
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
      expect(
        inlineData.map((part) => part['mimeType']),
        ['text/html', 'application/octet-stream', 'application/json'],
      );
      expect(requestBody, isNot(contains('API_KEY=never-send-this')));
      expect(requestBody, isNot(contains('.env.local')));
    });

    test('only reads an earlier attachment when the model requests it',
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
        type: 'text',
        content: 'I uploaded this earlier.',
        timestamp: 'Sabtu, 7 November 2026, 00:56',
        createdAtUtc: DateTime.now().toUtc().millisecondsSinceEpoch - 1000,
      );
      final currentMessage = ChatMessage(
        id: 'current-user-message',
        role: 'user',
        type: 'text',
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
          expect(toolResponse.first['functionResponse']['name'],
              'read_uploaded_attachment');
          expect(
            toolResponse.last['inlineData'],
            {
              'mimeType': 'image/png',
              'data': base64Encode(bytes),
            },
          );
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
        thinkingEnabled: true,
        attachmentsByMessage: {
          earlierMessage.id: [attachment],
        },
      );

      expect(reply, 'It is a picture.');
      expect(requestBodies, hasLength(2));
    });

    test('retrieves relevant old conversation memory with source messages',
        () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final config = _MemoryAiConfigStore()
        ..apiKeys = ['memory-retrieval-key']
        ..values['ai_model'] = 'gemini-3.5-flash-lite';
      final history = List<ChatMessage>.generate(40, (index) {
        return ChatMessage(
          id: 'history-$index',
          role: index == 39 || index.isEven ? 'user' : 'model',
          type: 'text',
          content: index == 39
              ? 'When did we discuss the lighthouse plan?'
              : 'Unrelated conversation number $index.',
          timestamp: formatJakartaTimestamp(1794000000000 + index * 60000),
          createdAtUtc: 1794000000000 + index * 60000,
        );
      });
      final memory = ConversationMemory(
        id: 'lighthouse-memory',
        title: 'Lighthouse plan',
        summary: 'We discussed the lighthouse plan and agreed to revisit it.',
        sourceMessageIds: ['history-1', 'history-2'],
        startAtUtc: history[1].createdAtUtc,
        endAtUtc: history[2].createdAtUtc,
        updatedAtUtc: history[2].createdAtUtc,
      );
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      final directory = await Directory.systemTemp.createTemp('sara-memory-');
      final memoryStore = await SqliteMessageStore.openAtPath(
        path.join(directory.path, 'message.sql'),
      );
      await memoryStore.saveConversationMemory(memory);
      addTearDown(() async {
        await memoryStore.close();
        await directory.delete(recursive: true);
      });
      Map<String, dynamic>? requestBody;
      final service = GeminiReplyService(
        configStore: config,
        preferences: preferences,
        memoryStore: memoryStore,
        client: MockClient((request) async {
          requestBody = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            'data: {"candidates":[{"content":{"parts":[{"text":"We discussed it earlier."}]}}]}\n\n',
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        }),
      );

      expect(
        await service.generateReply(history, thinkingEnabled: false),
        'We discussed it earlier.',
      );
      final sentContents = requestBody!['contents'] as List;
      final sentJson = sentContents
          .expand((message) => message['parts'] as List)
          .map((part) => part['text'])
          .whereType<String>()
          .join('\n');
      expect(sentJson, contains('retrieved_conversation_memories'));
      expect(sentJson, contains('lighthouse-memory'));
      expect(sentJson, contains('history-1'));
      expect(sentJson, isNot(contains('history-5')));
      expect(sentContents.length, lessThan(history.length));
    });

    test('stores a topic memory only for valid source message IDs', () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final config = _MemoryAiConfigStore()
        ..apiKeys = ['memory-save-key']
        ..values['ai_model'] = 'gemini-3.5-flash-lite';
      final history = [
        _userMessage,
        _message(
          id: 'model-source',
          role: 'model',
          createdAtUtc: _userMessage.createdAtUtc + 1000,
        ),
      ];
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      final directory = await Directory.systemTemp.createTemp('sara-memory-');
      final memoryStore = await SqliteMessageStore.openAtPath(
        path.join(directory.path, 'message.sql'),
      );
      addTearDown(() async {
        await memoryStore.close();
        await directory.delete(recursive: true);
      });
      await memoryStore.saveExchange(history);
      var requests = 0;
      final service = GeminiReplyService(
        configStore: config,
        preferences: preferences,
        memoryStore: memoryStore,
        client: MockClient((request) async {
          requests++;
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(
            (body['tools'][0]['functionDeclarations'] as List)
                .any((tool) => tool['name'] == 'save_conversation_memory'),
            isTrue,
          );
          if (requests == 1) {
            return http.Response(
              'data: {"candidates":[{"content":{"parts":[{"functionCall":'
              '{"name":"save_conversation_memory","args":{"title":"A decision",'
              '"summary":"The user decided to keep the project local.",'
              '"sourceMessageIds":["user-id","model-source"]}}}]}}]}\n\n',
              200,
              headers: {'content-type': 'text/event-stream'},
            );
          }
          return http.Response(
            'data: {"candidates":[{"content":{"parts":[{"text":"Got it."}]}}]}\n\n',
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        }),
      );

      expect(
        await service.generateReply(history, thinkingEnabled: true),
        'Got it.',
      );
      expect(requests, 2);
      final memories = await memoryStore.loadConversationMemories();
      expect(memories, hasLength(1));
      expect(memories.single.title, 'A decision');
      expect(memories.single.sourceMessageIds, ['user-id', 'model-source']);
      expect(memories.single.startAtUtc, _userMessage.createdAtUtc);
    });

    test('Sara searches saved private reflections only when she chooses',
        () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final config = _MemoryAiConfigStore()
        ..apiKeys = ['private-memory-key']
        ..values['ai_model'] = 'gemini-3.5-flash-lite';
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      final directory = await Directory.systemTemp.createTemp('sara-thought-');
      final memoryStore = await SqliteMessageStore.openAtPath(
        path.join(directory.path, 'message.sql'),
      );
      await memoryStore.saveMessage(_userMessage);
      await memoryStore.savePrivateThought(const SaraPrivateThought(
        id: 'music-reflection',
        reflection: 'I want to learn more about jazz and music.',
        action: 'think',
        isRemembered: true,
        sourceMessageIds: [],
        createdAtUtc: 2,
      ));
      await memoryStore.savePrivateThought(const SaraPrivateThought(
        id: 'other-branch',
        reflection: 'A private thought about cooking pasta.',
        action: 'think',
        isRemembered: true,
        sourceMessageIds: ['inactive-branch-message'],
        createdAtUtc: 3,
      ));
      addTearDown(() async {
        await memoryStore.close();
        await directory.delete(recursive: true);
      });

      var requests = 0;
      final service = GeminiReplyService(
        configStore: config,
        preferences: preferences,
        memoryStore: memoryStore,
        client: MockClient((request) async {
          requests++;
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(
            (body['tools'][0]['functionDeclarations'] as List)
                .any((tool) => tool['name'] == 'search_sara_private_memories'),
            isTrue,
          );
          if (requests == 1) {
            return http.Response(
              'data: ${jsonEncode({
                    'candidates': [
                      {
                        'content': {
                          'parts': [
                            {
                              'functionCall': {
                                'name': 'search_sara_private_memories',
                                'args': {'query': 'jazz music'},
                              },
                            },
                          ],
                        },
                      },
                    ],
                  })}\n\n',
              200,
              headers: {'content-type': 'text/event-stream'},
            );
          }
          final contents = body['contents'] as List;
          final memoryResult =
              contents.last['parts'][0]['functionResponse']['response'];
          expect(memoryResult['memories'], hasLength(1));
          expect(
            memoryResult['memories'][0]['reflection'],
            'I want to learn more about jazz and music.',
          );
          return http.Response(
            'data: {"candidates":[{"content":{"parts":[{"text":"I remember."}]}}]}\n\n',
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        }),
      );

      expect(
        await service.generateReply([_userMessage], thinkingEnabled: true),
        'I remember.',
      );
      expect(requests, 2);
    });

    test('updates simulated inner life and persists it locally', () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final config = _MemoryAiConfigStore()
        ..apiKeys = ['inner-life-key']
        ..values['ai_model'] = 'gemini-3.5-flash-lite';
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      final directory = await Directory.systemTemp.createTemp('sara-inner-');
      final memoryStore = await SqliteMessageStore.openAtPath(
        path.join(directory.path, 'message.sql'),
      );
      await memoryStore.saveMessage(_userMessage);
      addTearDown(() async {
        await memoryStore.close();
        await directory.delete(recursive: true);
      });
      var requests = 0;
      final service = GeminiReplyService(
        configStore: config,
        preferences: preferences,
        memoryStore: memoryStore,
        client: MockClient((request) async {
          requests++;
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(
            (body['tools'][0]['functionDeclarations'] as List)
                .any((tool) => tool['name'] == 'update_sara_inner_life'),
            isTrue,
          );
          if (requests == 1) {
            final systemInstruction =
                body['systemInstruction']['parts'][0]['text'] as String;
            expect(systemInstruction, contains('simulated inner life'));
            expect(systemInstruction, contains('literal human consciousness'));
            expect(systemInstruction, contains('Match the user’s language'));
            expect(systemInstruction, contains('brief, direct reply'));
            expect(systemInstruction, contains('aku-kamu phrasing'));
            expect(systemInstruction, contains('Prefer everyday words'));
            expect(
              systemInstruction,
              contains('Read the mood and moodIntensity'),
            );
            expect(systemInstruction, contains('Mood intensity controls'));
            expect(
              systemInstruction,
              contains('without lashing out'),
            );
            expect(systemInstruction, contains('safe, attentive listener'));
            expect(systemInstruction, contains('Never mock, roast, belittle'));
            expect(systemInstruction, contains('Do not laugh or use “haha”'));
            expect(
              systemInstruction,
              contains(
                'Do not refuse, shame, or change the subject solely because',
              ),
            );
            expect(systemInstruction, contains('Unwind permits a reply'));
            expect(
              systemInstruction,
              contains(
                  'do not add this disclaimer to ordinary emotional conversation'),
            );
            return http.Response(
              'data: {"candidates":[{"content":{"parts":[{"functionCall":'
              '{"name":"update_sara_inner_life","args":{"mood":"curious",'
              '"moodIntensity":85,"energy":70,"drives":{"connection":65,'
              '"curiosity":90,"autonomy":55,"security":50},'
              '"selfReflection":"I want to understand this idea more deeply.",'
              '"sourceMessageIds":["user-id"]}}}]}}]}\n\n',
              200,
              headers: {'content-type': 'text/event-stream'},
            );
          }
          if (requests == 2) {
            final contents = body['contents'] as List;
            final toolResponse = contents.last['parts'][0]['functionResponse'];
            expect(toolResponse['name'], 'update_sara_inner_life');
            expect(
              toolResponse['response']['simulatedState']['mood'],
              'curious',
            );
          } else {
            final systemInstruction =
                body['systemInstruction']['parts'][0]['text'] as String;
            expect(systemInstruction, contains('"mood":"curious"'));
            return http.Response(
              'data: {"candidates":[{"content":{"parts":[{"text":"I remember."}]}}]}\n\n',
              200,
              headers: {'content-type': 'text/event-stream'},
            );
          }
          return http.Response(
            'data: {"candidates":[{"content":{"parts":[{"text":"I am curious about that too."}]}}]}\n\n',
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        }),
      );
      final errors = <Object>[];

      expect(
        await service.generateReply(
          [_userMessage],
          thinkingEnabled: true,
          onInnerLifeError: errors.add,
        ),
        'I am curious about that too.',
      );
      expect(requests, 2);
      expect(errors, isEmpty);
      final stored = await memoryStore.loadSaraInnerLife();
      expect(stored.mood, 'curious');
      expect(stored.moodIntensity, greaterThan(25));
      expect(stored.drives['curiosity'], greaterThan(50));
      expect(
          stored.selfReflection, 'I want to understand this idea more deeply.');
      expect(stored.sourceMessageIds, ['user-id']);

      final followup = _message(
        id: 'followup-user',
        createdAtUtc: _userMessage.createdAtUtc + 1000,
      );
      await memoryStore.saveMessage(followup);
      expect(
        await service.generateReply(
          [_userMessage, followup],
          thinkingEnabled: false,
        ),
        'I remember.',
      );
      expect(requests, 3);
    });

    test('returns only valid uploaded media selected by Gemini tools',
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
          expect(contents[1]['parts'][0]['functionCall']['name'],
              'send_uploaded_media');
          expect(contents[2]['parts'][0]['functionResponse']['name'],
              'send_uploaded_media');
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
        thinkingEnabled: false,
        attachmentsByMessage: {
          _userMessage.id: [attachment],
        },
        onMedia: (items) => selectedMedia = items,
      );

      expect(reply, isEmpty);
      expect(requests, 2);
      expect(selectedMedia, [same(attachment)]);
      expect(requestBodies.first['tools'], isNotNull);
    });

    test('does not send expired attachments or offer them to Gemini tools',
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
          thinkingEnabled: false,
          attachmentsByMessage: {
            _userMessage.id: [attachment],
          },
        ),
        'No file',
      );
      expect(requestBody!.containsKey('tools'), isFalse);
      expect(
        (requestBody!['contents'][0]['parts'] as List),
        hasLength(1),
      );
    });

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
          thinkingEnabled: false,
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
        expect(
          await service.generateReply(
            [_userMessage],
            thinkingEnabled: false,
          ),
          'Reply',
        );
      }
      expect(attemptedKeys, [
        'primary-key',
        'primary-key',
        'secondary-key',
        'primary-key',
        'secondary-key',
      ]);
    });

    test('rotates after failure and skips cached failed key next time',
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
          requestBodies.add(
            jsonDecode(request.body) as Map<String, dynamic>,
          );
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
        await service.generateReply(
          [_userMessage],
          personalName: 'Rani',
          thinkingEnabled: true,
        ),
        'Hello from Sara',
      );
      expect(
        await service.generateReply(
          [_userMessage],
          thinkingEnabled: false,
        ),
        'Hello from Sara',
      );
      expect(attemptedKeys, ['bad-key', 'working-key', 'working-key']);
      final systemInstruction =
          requestBodies.first['systemInstruction'] as Map<String, dynamic>;
      expect(
        jsonEncode(systemInstruction),
        contains('Rani'),
      );
      final requestContent = requestBodies.first['contents'] as List<dynamic>;
      final requestMessage = requestContent.first as Map<String, dynamic>;
      final requestJson =
          (requestMessage['parts'] as List).first as Map<String, dynamic>;
      final serializedMessage = jsonDecode(requestJson['text'] as String);
      expect(serializedMessage, {
        'id': _userMessage.id,
        'role': _userMessage.role,
        'content': _userMessage.content,
        'type': _userMessage.type,
        'timestamp': _userMessage.timestamp,
        'created_at_utc': _userMessage.createdAtUtc,
      });
      expect(
        requestBodies.first['generationConfig']['thinkingConfig']
            ['thinkingLevel'],
        'high',
      );
      expect(
        requestBodies.last['generationConfig']['thinkingConfig']
            ['thinkingLevel'],
        'minimal',
      );
      expect(
        preferences.getStringList('failed_gemini_key_fingerprints'),
        [sha256.convert(utf8.encode('bad-key')).toString()],
      );
    });

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
        service.generateReply([_userMessage], thinkingEnabled: true),
        throwsA(isA<AllGeminiApiKeysFailedException>()),
      );
      await expectLater(
        service.generateReply([_userMessage], thinkingEnabled: true),
        throwsA(isA<AllGeminiApiKeysFailedException>()),
      );
      final failedFingerprints =
          preferences.getStringList('failed_gemini_key_fingerprints')!;
      expect(requests, 2);
      expect(failedFingerprints, hasLength(2));
      expect(failedFingerprints, isNot(contains('first-key')));
      expect(failedFingerprints, isNot(contains('second-key')));
    });

    test(
        'autonomous thinking retries transient rate limits without blacklisting',
        () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final config = _MemoryAiConfigStore()
        ..apiKeys = ['busy-key', 'available-key']
        ..values['ai_model'] = 'gemini-3.5-flash-lite';
      final attemptedKeys = <String>[];
      final service = GeminiReplyService(
        configStore: config,
        preferences: preferences,
        autonomyClientFactory: () => MockClient((request) async {
          final key = request.headers['x-goog-api-key']!;
          attemptedKeys.add(key);
          if (key == 'busy-key') {
            return http.Response(
              jsonEncode({
                'error': {'message': 'Quota exceeded'},
              }),
              429,
            );
          }
          return http.Response(
            'data: ${jsonEncode({
                  'candidates': [
                    {
                      'content': {
                        'parts': [
                          {
                            'text': jsonEncode({
                              'memoryQuery': '',
                              'reflection': 'A useful thought.',
                              'remember': false,
                              'sourceMessageIds': [],
                              'action': 'rest',
                              'nextCheckMinutes': 30,
                              'message': '',
                              'innerLife': {
                                'mood': 'calm',
                                'moodIntensity': 30,
                                'energy': 70,
                                'drives': {
                                  'connection': 50,
                                  'curiosity': 50,
                                  'autonomy': 50,
                                  'security': 50,
                                },
                              },
                              'goalUpdates': [],
                            }),
                          },
                        ],
                      },
                    },
                  ],
                })}\n\n',
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        }),
      );

      for (var attempt = 0; attempt < 2; attempt++) {
        final decision = await service.thinkAutonomously(
          activeMessageIds: const [],
          personalName: null,
          innerLifeSummary: '{}',
          currentGoals: const [],
        );
        expect(decision.action, 'rest');
      }

      expect(
        attemptedKeys,
        ['busy-key', 'available-key', 'busy-key', 'available-key'],
      );
      expect(
        preferences.getStringList('failed_gemini_key_fingerprints'),
        isEmpty,
      );
    });
  });

  test('SQLite message store persists and orders messages by UTC time',
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

    expect(
      (await store.loadMessages()).map((message) => message.id),
      ['earlier', 'later'],
    );
    final loadedAttachments = (await store.loadAttachments())['earlier']!;
    expect(loadedAttachments, hasLength(1));
    expect(loadedAttachments.single.path, attachment.path);
    expect(loadedAttachments.single.mimeType, attachment.mimeType);
    expect(await store.readPersonalName(), 'Rani');
    await store.deleteMessages(['earlier']);
    expect(
      (await store.loadMessages()).map((message) => message.id),
      ['later'],
    );
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
  });

  test('SQLite terminal history persists and retrieves similar failed attempts',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('sara-terminal-db-');
    final databasePath = path.join(directory.path, 'message.sql');
    var store = await SqliteMessageStore.openAtPath(databasePath);
    addTearDown(() async {
      await store.close();
      await directory.delete(recursive: true);
    });

    await store.saveMessage(
      _message(id: 'terminal-response', role: 'model', createdAtUtc: 50),
    );
    await store.saveMessage(
      _message(id: 'terminal-response-2', role: 'model', createdAtUtc: 60),
    );
    await store.saveTerminalCommandHistory(
      TerminalCommandHistoryEntry(
        responseMessageId: 'terminal-response',
        taskContext: 'Find the frozen Thunar file manager process.',
        command: 'pkill thunar',
        workingDirectory: '/home/user',
        exitCode: 1,
        stdout: '',
        stderr: '',
        error: null,
        timedOut: false,
        cancelled: false,
        skipped: false,
        outputTruncated: false,
        createdAtUtc: 100,
      ),
    );
    await store.saveTerminalCommandHistory(
      TerminalCommandHistoryEntry(
        responseMessageId: 'terminal-response-2',
        taskContext: 'Try stopping the Thunar process after inspection.',
        command: 'pkill thunar',
        workingDirectory: '/home/user',
        exitCode: 1,
        stdout: '',
        stderr: '',
        error: null,
        timedOut: false,
        cancelled: false,
        skipped: false,
        outputTruncated: false,
        createdAtUtc: 150,
      ),
    );
    await store.saveTerminalCommandHistory(
      TerminalCommandHistoryEntry(
        responseMessageId: 'terminal-response-2',
        taskContext: 'The Thunar process was stopped successfully.',
        command: 'pkill thunar',
        workingDirectory: '/home/user',
        exitCode: 0,
        stdout: 'stopped',
        stderr: '',
        error: null,
        timedOut: false,
        cancelled: false,
        skipped: false,
        outputTruncated: false,
        createdAtUtc: 175,
      ),
    );
    await store.saveTerminalCommandHistory(
      TerminalCommandHistoryEntry(
        taskContext: 'Inspect the Thunar process before stopping it.',
        command: 'ps aux | grep thunar',
        workingDirectory: '/home/user',
        exitCode: 0,
        stdout: 'thunar is not running',
        stderr: '',
        error: null,
        timedOut: false,
        cancelled: false,
        skipped: false,
        outputTruncated: false,
        createdAtUtc: 200,
      ),
    );
    await store.close();
    store = await SqliteMessageStore.openAtPath(databasePath);

    final matches = await store.searchTerminalCommandHistory('Thunar process');
    expect(matches, hasLength(3));
    expect(matches.first['command'], 'ps aux | grep thunar');
    expect(matches.last['exitCode'], 1);
    final backup = await store.exportBackupData();
    expect(backup['terminal_command_history'], hasLength(3));
    final activities =
        await store.loadTerminalCommandActivities({'terminal-response'});
    expect(activities['terminal-response'], hasLength(1));
    expect(
      (await store.loadTerminalCommandActivities(
          {'terminal-response-2'}))['terminal-response-2'],
      hasLength(2),
    );
    final duplicateContexts =
        activities['terminal-response']!.single.taskContext;
    expect(duplicateContexts, contains('Try stopping the Thunar process'));
    expect(
      activities['terminal-response']!.single.responseMessageId,
      'terminal-response',
    );

    await store.deleteMessage('terminal-response');
    expect(
      await store.loadTerminalCommandActivities({'terminal-response'}),
      hasLength(1),
    );
    expect(await store.searchTerminalCommandHistory('Thunar process'),
        hasLength(3));
    final legacyBackup = Map<String, Object?>.from(backup);
    legacyBackup.remove('terminal_command_activity_link');
    legacyBackup['terminal_command_history'] =
        (backup['terminal_command_history']! as List).map((row) {
      final record = Map<String, Object?>.from(row as Map);
      record.remove('response_message_id');
      return record;
    }).toList(growable: false);
    await store.importBackupData(legacyBackup, clipboardPaths: const {});
    expect(
      await store.loadTerminalCommandActivities(
        {'terminal-response', 'terminal-response-2'},
      ),
      isEmpty,
    );
    expect(
      await store.searchTerminalCommandHistory('Thunar process'),
      hasLength(3),
    );
    await store.clearMessages();
    expect(
      await store.searchTerminalCommandHistory('Thunar process'),
      hasLength(3),
    );
  });

  test('SQLite preserves Sara mental state after message deletion until clear',
      () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final directory = await Directory.systemTemp.createTemp('sara-memory-');
    final store = await SqliteMessageStore.openAtPath(
      path.join(directory.path, 'message.sql'),
    );
    addTearDown(() async {
      await store.close();
      await directory.delete(recursive: true);
    });
    final source = _message(id: 'memory-source', createdAtUtc: 100);
    final retainedSource = _message(id: 'retained-source', createdAtUtc: 200);
    await store.saveMessage(source);
    await store.saveMessage(retainedSource);
    final linkedMemory = ConversationMemory(
      id: 'local-memory',
      title: 'A past topic',
      summary: 'A short topic summary.',
      sourceMessageIds: [source.id, retainedSource.id],
      startAtUtc: source.createdAtUtc,
      endAtUtc: retainedSource.createdAtUtc,
      updatedAtUtc: source.createdAtUtc,
    );
    final retainedMemory = ConversationMemory(
      id: 'retained-memory',
      title: 'An unrelated topic',
      summary: 'A summary based on the retained message.',
      sourceMessageIds: [retainedSource.id],
      startAtUtc: retainedSource.createdAtUtc,
      endAtUtc: retainedSource.createdAtUtc,
      updatedAtUtc: retainedSource.createdAtUtc,
    );
    await store.saveConversationMemory(linkedMemory);
    await store.saveConversationMemory(retainedMemory);
    await store.saveSaraInnerLife(
      SaraInnerLife(
        mood: 'warm',
        moodIntensity: 70,
        energy: 55,
        drives: const {
          'connection': 75,
          'curiosity': 50,
          'autonomy': 50,
          'security': 50,
        },
        selfReflection: 'A meaningful conversation stayed with me.',
        sourceMessageIds: [retainedSource.id],
        updatedAtUtc: 20,
      ),
    );
    final loaded = await store.loadConversationMemories();
    expect(loaded, hasLength(2));
    expect(
      loaded.map((memory) => memory.id).toSet(),
      {'local-memory', 'retained-memory'},
    );
    expect((await store.loadSaraInnerLife()).mood, 'warm');
    await store.deleteMessage(source.id);
    expect(
      (await store.loadConversationMemories()).map((memory) => memory.id),
      ['retained-memory'],
    );
    expect((await store.loadSaraInnerLife()).mood, 'warm');

    await store.saveSaraInnerLife(
      SaraInnerLife(
        mood: 'warm',
        moodIntensity: 70,
        energy: 55,
        drives: const {
          'connection': 75,
          'curiosity': 50,
          'autonomy': 50,
          'security': 50,
        },
        selfReflection: 'A meaningful conversation stayed with me.',
        sourceMessageIds: [retainedSource.id],
        updatedAtUtc: 20,
      ),
    );
    await store.deleteMessage(retainedSource.id);
    expect(await store.loadConversationMemories(), isEmpty);
    expect((await store.loadSaraInnerLife()).mood, 'warm');
    expect(
      (await store.loadSaraInnerLife()).sourceMessageIds,
      isEmpty,
    );
    await store.saveConversationMemory(retainedMemory);
    await store.saveSaraInnerLife(
      SaraInnerLife(
        mood: 'joyful',
        moodIntensity: 80,
        energy: 80,
        drives: const {
          'connection': 80,
          'curiosity': 80,
          'autonomy': 80,
          'security': 80,
        },
        selfReflection: 'A final reflection.',
        sourceMessageIds: [],
        updatedAtUtc: 30,
      ),
    );
    await store.clearMessages();
    expect(await store.loadConversationMemories(), isEmpty);
    expect((await store.loadSaraInnerLife()).mood, 'calm');
  });

  test(
      'SQLite stores response feedback, summarizes trends, and deletes linked votes',
      () async {
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

    final firstUser = _message(id: 'feedback-user-1', createdAtUtc: 100);
    final firstResponse = _message(
      id: 'feedback-response-1',
      role: 'model',
      createdAtUtc: 101,
    );
    final secondUser = _message(id: 'feedback-user-2', createdAtUtc: 200);
    final secondResponse = _message(
      id: 'feedback-response-2',
      role: 'model',
      createdAtUtc: 201,
    );
    await store.saveExchange(
      [firstUser, firstResponse, secondUser, secondResponse],
    );

    await store.saveAssistantFeedback(firstUser.id, firstResponse.id, 1);
    expect(await store.loadAssistantFeedback(), {firstResponse.id: 1});
    expect(
      await store.loadFeedbackPreferenceSummary(),
      contains('too limited'),
    );

    await store.saveAssistantFeedback(secondUser.id, secondResponse.id, 1);
    expect(await store.loadAssistantFeedback(), {
      firstResponse.id: 1,
      secondResponse.id: 1,
    });
    expect(
      await store.loadFeedbackPreferenceSummary(),
      contains('often likes concise replies'),
    );

    await store.saveAssistantFeedback(
      secondUser.id,
      secondResponse.id,
      -1,
    );
    expect(await store.loadAssistantFeedback(), {
      firstResponse.id: 1,
      secondResponse.id: -1,
    });
    await store.deleteMessages([firstUser.id]);
    expect(await store.loadAssistantFeedback(), {
      secondResponse.id: -1,
    });
    expect(
      await store.loadFeedbackPreferenceSummary(),
      contains('too limited'),
    );

    final thirdUser = _message(id: 'feedback-user-3', createdAtUtc: 300);
    final thirdResponse = _message(
      id: 'feedback-response-3',
      role: 'model',
      createdAtUtc: 301,
    );
    await store.saveExchange([thirdUser, thirdResponse]);
    await store.saveAssistantFeedback(thirdUser.id, thirdResponse.id, 1);
    await store.deleteMessages([thirdResponse.id]);
    expect(await store.loadAssistantFeedback(), {
      secondResponse.id: -1,
    });
    await store.deleteMessages([secondResponse.id]);
    expect(await store.loadAssistantFeedback(), isEmpty);
    expect(await store.loadFeedbackPreferenceSummary(), isNull);

    await store.saveExchange([thirdUser, thirdResponse]);
    await store.saveAssistantFeedback(thirdUser.id, thirdResponse.id, -1);
    await store.clearMessages();
    expect(await store.loadAssistantFeedback(), isEmpty);
    expect(await store.loadFeedbackPreferenceSummary(), isNull);
  });

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
    final clipboardFile =
        File(path.join(clipboardDirectory.path, 'clipboard.png'));
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
    await store.saveMessageAttachments(
      user.id,
      [
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
      ],
    );
    await store.saveConversationMemory(
      ConversationMemory(
        id: 'backup-memory',
        title: 'Topic',
        summary: 'A saved memory.',
        sourceMessageIds: [user.id],
        startAtUtc: 100,
        endAtUtc: 101,
        updatedAtUtc: 102,
      ),
    );
    final innerLife = SaraInnerLife(
      mood: 'curious',
      moodIntensity: 71,
      energy: 62,
      drives: const {
        'connection': 68,
        'curiosity': 81,
        'autonomy': 73,
        'security': 54,
      },
      selfReflection: 'A thought worth keeping.',
      sourceMessageIds: [user.id],
      updatedAtUtc: 103,
    );
    await store.saveSaraInnerLife(innerLife);
    await store.saveSaraInnerLifeForBranch(innerLife, response.id);
    final privateThought = SaraPrivateThought(
      id: 'backup-thought',
      reflection: 'Sara remembered a useful idea.',
      action: 'think',
      isRemembered: true,
      sourceMessageIds: [user.id],
      createdAtUtc: 104,
    );
    await store.savePrivateThought(privateThought);
    final autonomyGoal = SaraAutonomyGoal(
      id: 'backup-goal',
      title: 'Return to this idea',
      description: 'Bring it up when it feels natural.',
      status: 'active',
      sourceMessageIds: [user.id],
      updatedAtUtc: 105,
      branchMessageId: response.id,
    );
    expect(
      await store.saveAutonomyGoalsForBranch(
        [autonomyGoal],
        response.id,
      ),
      isTrue,
    );
    await store.saveAssistantFeedback(user.id, response.id, 1);
    final backupBytes = await backupService.createBackup(store);
    final backupPayload = jsonDecode(utf8.decode(backupBytes)) as Map;
    expect((backupPayload['attachment_files'] as Map).length, 2);
    final backupTables = backupPayload['database'] as Map;
    expect((backupTables['sara_inner_life'] as List), hasLength(1));
    expect((backupTables['sara_inner_life_branch'] as List), hasLength(1));
    expect((backupTables['sara_private_thought'] as List), hasLength(1));
    expect((backupTables['sara_autonomy_goal'] as List), hasLength(1));

    await store.writePersonalName('Other');
    await store.saveMessage(_message(id: 'replacement', createdAtUtc: 200));
    await store.savePrivateThought(const SaraPrivateThought(
      id: 'replacement-thought',
      reflection: 'Temporary local thought.',
      action: 'think',
      isRemembered: true,
      sourceMessageIds: [],
      createdAtUtc: 201,
    ));
    final restoreResult = await backupService.restoreBackup(
      store,
      backupBytes,
    );
    expect(restoreResult.cleanupErrors, isEmpty);

    expect((await store.loadMessages()).map((message) => message.id), [
      user.id,
      response.id,
    ]);
    expect(await store.readPersonalName(), 'Rani');
    final restoredAttachments = (await store.loadAttachments())[user.id]!;
    final restoredClipboard = restoredAttachments
        .singleWhere((attachment) => attachment.id == 'backup-attachment');
    final restoredExternal = restoredAttachments
        .singleWhere((attachment) => attachment.id == 'external-attachment');
    expect(restoredClipboard.path, isNot(clipboardFile.path));
    expect(restoredExternal.path, isNot(externalFile.path));
    expect(restoredClipboard.isClipboardCopy, isTrue);
    expect(restoredExternal.isClipboardCopy, isTrue);
    expect(await File(restoredClipboard.path!).readAsBytes(), [1, 2, 3]);
    expect(await File(restoredExternal.path!).readAsBytes(), [4, 5, 6]);
    expect(await clipboardFile.exists(), isFalse);
    expect(await externalFile.exists(), isTrue);
    expect(
      (await store.loadConversationMemories()).single.id,
      'backup-memory',
    );
    expect(
      (await store.loadSaraInnerLife()).selfReflection,
      innerLife.selfReflection,
    );
    expect(
      (await store.loadSaraInnerLifeForPath([user.id, response.id]))
          .selfReflection,
      innerLife.selfReflection,
    );
    expect(
      (await store.loadPrivateThoughts()).single.reflection,
      privateThought.reflection,
    );
    expect(
      (await store.loadAutonomyGoalsForPath([user.id, response.id]))
          .single
          .title,
      autonomyGoal.title,
    );
    expect(await store.loadAssistantFeedback(), {'backup-response': 1});
  });

  test('Gemini receives only the summarized response feedback preference',
      () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final config = _MemoryAiConfigStore()
      ..apiKeys = ['feedback-context-key']
      ..values['ai_model'] = 'gemini-3.5-flash-lite';
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

    final history = <ChatMessage>[
      _message(id: 'liked-user-1', createdAtUtc: 100),
      _message(id: 'liked-reply-1', role: 'model', createdAtUtc: 101),
      _message(id: 'liked-user-2', createdAtUtc: 200),
      _message(id: 'liked-reply-2', role: 'model', createdAtUtc: 201),
      _message(id: 'latest-user', createdAtUtc: 300),
    ];
    await store.saveExchange(history);
    await store.saveAssistantFeedback('liked-user-1', 'liked-reply-1', 1);
    await store.saveAssistantFeedback('liked-user-2', 'liked-reply-2', 1);
    Map<String, dynamic>? requestBody;
    final service = GeminiReplyService(
      configStore: config,
      preferences: preferences,
      memoryStore: store,
      client: MockClient((request) async {
        requestBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          'data: {"candidates":[{"content":{"parts":[{"text":"Answer"}]}}]}\n\n',
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      }),
    );

    expect(
        await service.generateReply(history, thinkingEnabled: false), 'Answer');
    final instruction =
        requestBody!['systemInstruction']['parts'][0]['text'] as String;
    expect(instruction, contains('often likes concise replies'));
    expect(instruction, isNot(contains('liked-reply-1')));
    expect(instruction, isNot(contains('liked-reply-2')));
  });

  test('SQLite expires paths but keeps attachment references for user and AI',
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
  });

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
    await store.saveMessageAttachments(
      message.id,
      [
        const ChatAttachment(
          id: 'camera-photo',
          path: cameraPath,
          name: 'camera-photo.png',
          mimeType: 'image/png',
          isClipboardCopy: true,
        ),
      ],
    );

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
        ..remove('parent_message_id'),
    );
    await legacyDatabase.close();

    var store = await SqliteMessageStore.openAtPath(databasePath);
    addTearDown(() async {
      await store.close();
      await directory.delete(recursive: true);
    });

    expect(await store.readPersonalName(), isNull);
    expect((await store.loadSaraInnerLife()).mood, 'calm');
    expect(
      (await store.loadMessages()).single.timestamp,
      'Sabtu, 7 November 2026, 00:00',
    );
    await store.writePersonalName('Rani');
    expect(await store.readPersonalName(), 'Rani');
  });

  test('SQLite version 10 migrates all messages to text-only type', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final directory = await Directory.systemTemp.createTemp('sara-type-v11-');
    final databasePath = path.join(directory.path, 'message.sql');
    final oldDatabase = await databaseFactory.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(
        version: 10,
        onCreate: (database, version) async {
          await database.execute('''
            CREATE TABLE message (
              id TEXT PRIMARY KEY NOT NULL,
              role TEXT NOT NULL CHECK (role IN ('user', 'model')),
              type TEXT NOT NULL CHECK (type IN ('text', 'voice_note')),
              content TEXT NOT NULL,
              timestamp TEXT NOT NULL,
              created_at_utc INTEGER NOT NULL,
              parent_message_id TEXT
            )
          ''');
          await database.execute(
            'CREATE INDEX message_order ON message(created_at_utc ASC, id ASC)',
          );
          await database.execute(
            'CREATE INDEX message_parent ON message(parent_message_id)',
          );
        },
      ),
    );
    await oldDatabase.insert(
      'message',
      _message(id: 'legacy-text', createdAtUtc: 1).toMap(),
    );
    await oldDatabase.insert('message', {
      ..._message(
        id: 'legacy-voice',
        role: 'model',
        createdAtUtc: 2,
        parentMessageId: 'legacy-text',
      ).toMap(),
      'type': 'voice_note',
    });
    await oldDatabase.close();

    final store = await SqliteMessageStore.openAtPath(databasePath);
    addTearDown(() async {
      await store.close();
      await directory.delete(recursive: true);
    });
    final messages = await store.loadMessages();
    expect(messages.map((message) => message.id), [
      'legacy-text',
      'legacy-voice',
    ]);
    expect(messages.map((message) => message.type), ['text', 'text']);
    expect(messages.last.parentMessageId, 'legacy-text');
    expect(messages.last.content, 'legacy-voice');
    await store.saveMessage(
      ChatMessage(
        id: 'new-voice',
        role: 'model',
        type: 'voice_note',
        content: 'normalized to text',
        timestamp: '2026-01-01 10:00:00',
        createdAtUtc: 3,
      ),
    );
    expect((await store.loadMessages()).last.type, 'text');
    final schemaDatabase = await databaseFactory.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(version: 14),
    );
    addTearDown(schemaDatabase.close);
    final schema = (await schemaDatabase.rawQuery(
      "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'message'",
    ))
        .single['sql']! as String;
    expect(schema, contains("CHECK (type = 'text')"));
    await expectLater(
      schemaDatabase.insert('message', {
        'id': 'raw-voice',
        'role': 'model',
        'type': 'voice_note',
        'content': 'not supported',
        'timestamp': '2026-01-01 10:00:00',
        'created_at_utc': 4,
        'parent_message_id': null,
      }),
      throwsA(isA<DatabaseException>()),
    );
  });

  test('SQLite stores private thoughts and guards spontaneous messages',
      () async {
    final directory = await Directory.systemTemp.createTemp('sara-thoughts-');
    final databasePath = path.join(directory.path, 'message.sql');
    final store = await SqliteMessageStore.openAtPath(databasePath);
    addTearDown(() async {
      await store.close();
      await directory.delete(recursive: true);
    });
    final userMessage = _message(id: 'thought-source', createdAtUtc: 1);
    await store.appendMessage(userMessage);
    final thought = SaraPrivateThought(
      id: 'private-thought',
      reflection: 'A short private reflection.',
      action: 'think',
      isRemembered: true,
      sourceMessageIds: const ['thought-source'],
      createdAtUtc: 2,
    );

    expect(
      await store.savePrivateThoughtIfActiveLeaf(
        thought,
        expectedLeafId: 'thought-source',
      ),
      isTrue,
    );
    expect((await store.loadPrivateThoughts()).single.reflection,
        thought.reflection);

    final spontaneousMessage = _message(
      id: 'spontaneous',
      role: 'model',
      createdAtUtc: 3,
      parentMessageId: 'thought-source',
    );
    expect(
      await store.appendMessageIfActiveLeaf(
        spontaneousMessage,
        expectedLeafId: 'stale-leaf',
      ),
      isFalse,
    );
    expect(
      await store.appendMessageIfActiveLeaf(
        spontaneousMessage,
        expectedLeafId: 'thought-source',
      ),
      isTrue,
    );
    expect((await store.loadActiveMessages()).last.id, 'spontaneous');

    final backgroundThought = SaraPrivateThought(
      id: 'background-thought',
      reflection: 'Thinking continued while the chat changed.',
      action: 'think',
      isRemembered: true,
      sourceMessageIds: const ['thought-source'],
      createdAtUtc: 4,
    );
    expect(
      await store.savePrivateThoughtIfSourcesExist(backgroundThought),
      isTrue,
    );
    await store.deleteMessage('thought-source');
    final retainedThoughts = await store.loadPrivateThoughts();
    expect(
      retainedThoughts.map((item) => item.id).toSet(),
      {'private-thought', 'background-thought'},
    );
    expect(
      retainedThoughts.every((item) => item.sourceMessageIds.isEmpty),
      isTrue,
    );
    await store.clearMessages();
    expect(await store.loadPrivateThoughts(), isEmpty);
  });

  test('SQLite long-term goals are isolated to the conversation branch',
      () async {
    final directory = await Directory.systemTemp.createTemp('sara-goals-');
    final databasePath = path.join(directory.path, 'message.sql');
    final store = await SqliteMessageStore.openAtPath(databasePath);
    addTearDown(() async {
      await store.close();
      await directory.delete(recursive: true);
    });

    await store.appendMessage(_message(id: 'goal-root', createdAtUtc: 1));
    await store.appendMessage(_message(
      id: 'goal-branch-one',
      role: 'model',
      createdAtUtc: 2,
      parentMessageId: 'goal-root',
    ));
    final goal = SaraAutonomyGoal(
      id: 'goal-1',
      title: 'Explore the music topic',
      description: 'Bring the topic up again when it feels natural.',
      status: 'active',
      sourceMessageIds: const ['goal-root'],
      updatedAtUtc: 3,
      branchMessageId: 'goal-branch-one',
    );
    expect(
      await store.saveAutonomyGoalsForBranch([goal], 'goal-branch-one'),
      isTrue,
    );

    await store.appendMessage(_message(
      id: 'goal-branch-two',
      role: 'model',
      createdAtUtc: 4,
      parentMessageId: 'goal-root',
    ));
    expect(
      await store.loadAutonomyGoalsForPath(
        (await store.loadActiveMessages())
            .map((message) => message.id)
            .toList(),
      ),
      isEmpty,
    );

    await store.activateMessageBranch('goal-branch-one');
    final restoredGoals = await store.loadAutonomyGoalsForPath(
      (await store.loadActiveMessages()).map((message) => message.id).toList(),
    );
    expect(restoredGoals.single.title, goal.title);
    await store.deleteMessage('goal-branch-one');
    final remainingPath = (await store.loadActiveMessages())
        .map((message) => message.id)
        .toList();
    final retainedGoals = await store.loadAutonomyGoalsForPath(remainingPath);
    expect(retainedGoals.single.title, goal.title);
    expect(retainedGoals.single.sourceMessageIds, ['goal-root']);
    await store.clearMessages();
    expect(await store.loadAutonomyGoalsForPath(const []), isEmpty);
  });

  test('SQLite branches restore the selected path and delete only a subtree',
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

    expect(
      (await store.loadActiveMessages()).map((message) => message.id),
      ['a', 'b2', 'c2', 'd2'],
    );
    final branches = await store.loadMessageBranches();
    expect(branches['b1']!.alternatives, ['b1', 'b2']);
    final firstState = SaraInnerLife.initial(10);
    final secondState = SaraInnerLife(
      mood: 'curious',
      moodIntensity: 70,
      energy: 55,
      drives: firstState.drives,
      selfReflection: 'Second branch',
      sourceMessageIds: const ['a'],
      updatedAtUtc: 20,
    );
    await store.saveSaraInnerLifeForBranch(firstState, 'b1');
    await store.saveSaraInnerLifeForBranch(secondState, 'b2');
    final deletedBranchState = SaraInnerLife(
      mood: 'joyful',
      moodIntensity: 85,
      energy: 72,
      drives: firstState.drives,
      selfReflection: 'A reflection made in the deleted branch.',
      sourceMessageIds: const ['a', 'b1', 'c1'],
      updatedAtUtc: 30,
    );
    await store.saveSaraInnerLifeForBranch(deletedBranchState, 'c1');
    expect(
      (await store.loadSaraInnerLifeForPath(['a', 'b1'])).mood,
      'calm',
    );
    expect(
      (await store.loadSaraInnerLifeForPath(['a', 'b2'])).mood,
      'curious',
    );
    await store.activateMessageBranch('b1');
    await store.close();
    store = await SqliteMessageStore.openAtPath(databasePath);
    expect(
      (await store.loadActiveMessages()).map((message) => message.id),
      ['a', 'b1', 'c1', 'd1'],
    );
    final deleted = await store.loadSubtreeMessageIds('c1');
    await store.deleteMessages(deleted);
    expect(
      (await store.loadActiveMessages()).map((message) => message.id),
      ['a', 'b1'],
    );
    expect(
      (await store.loadMessages()).map((message) => message.id),
      ['a', 'b1', 'b2', 'c2', 'd2'],
    );
    final restoredState = await store.loadSaraInnerLifeForPath(['a', 'b1']);
    expect(restoredState.selfReflection, deletedBranchState.selfReflection);
    expect(restoredState.sourceMessageIds, ['a', 'b1']);
  });

  test('SQLite exposes edited user messages as navigable sibling branches',
      () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final directory =
        await Directory.systemTemp.createTemp('sara-user-branch-');
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
    expect(
      (await store.loadActiveMessages()).map((message) => message.id),
      ['root-user', 'root-reply', 'original-user', 'original-response'],
    );
  });

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

  test('SQLite version 4 attachment rows migrate with message-based expiry',
      () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final directory = await Directory.systemTemp.createTemp('sara-migration-');
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
        ..remove('parent_message_id')),
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
  });
}

const _userMessage = ChatMessage(
  id: 'user-id',
  role: 'user',
  type: 'text',
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
    type: 'text',
    content: id,
    timestamp: '2026-01-01 10:00:00',
    createdAtUtc: createdAtUtc,
    parentMessageId: parentMessageId,
  );
}

Future<File> _createQrImage(Directory directory, String text) async {
  final matrix = QRCodeWriter().encode(
    text,
    BarcodeFormat.qrCode,
    240,
    240,
  );
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
