import 'dart:async';
import 'dart:io';

import 'package:cross_file/cross_file.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons_300.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sara_desktop/ai_config_store.dart';
import 'package:sara_desktop/app_localizations.dart';
import 'package:sara_desktop/chat_attachment.dart';
import 'package:sara_desktop/chat_message.dart';
import 'package:sara_desktop/camera_capture.dart';
import 'package:sara_desktop/camera_capture_cache.dart';
import 'package:sara_desktop/desktop_notification_service.dart';
import 'package:sara_desktop/gemini_reply_service.dart';
import 'package:sara_desktop/main.dart';
import 'package:sara_desktop/message_database.dart';
import 'package:sara_desktop/smart_text_input_formatter.dart';
import 'package:sara_desktop/sound_of_text_service.dart';
import 'package:sara_desktop/terminal_command.dart';

void main() {
  setUp(() {
    AppLanguageController.language.value = AppLanguage.english;
    SharedPreferences.setMockInitialValues({'app_language': 'en'});
  });

  testWidgets(
    'camera tool is available during a normal user reply when enabled',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({
        'app_language': 'en',
        'sara_camera_enabled': true,
      });
      final replyService = _FakeReplyService();
      await tester.pumpWidget(
        _testApp(
          configStore: _MemoryAiConfigStore(),
          messageStore: _MemoryMessageStore(),
          replyService: replyService,
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'What can you see?');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(replyService.cameraToolAvailableCalls, 1);
    },
  );

  testWidgets('sending and receiving messages play their notification sounds', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final sounds = <String>[];
    await tester.pumpWidget(
      _testApp(
        messageStore: _MemoryMessageStore(),
        replyService: _FakeReplyService(reply: 'A reply'),
        notificationSoundPlayer: (assetPath) async {
          sounds.add(assetPath);
        },
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Hello');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(sounds, ['assets/sound/send.mp3', 'assets/sound/received.mp3']);
  });

  testWidgets('composer uses Shift+Enter for newlines and Enter to send', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final messageStore = _MemoryMessageStore();
    await tester.pumpWidget(
      _testApp(
        messageStore: messageStore,
        replyService: _FakeReplyService(reply: 'A reply'),
      ),
    );
    await tester.pumpAndSettle();

    final composerInput = find.descendant(
      of: find.byKey(const ValueKey('chat-composer')),
      matching: find.byType(TextField),
    );
    await tester.enterText(composerInput, 'First line');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();

    expect(
      tester.widget<TextField>(composerInput).controller!.text,
      'First line\n',
    );
    expect(messageStore.messages, isEmpty);

    await tester.enterText(composerInput, 'First line\nSecond line');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(messageStore.messages.first.content, 'First line\nSecond line');
  });

  testWidgets('one search result remains inline in the chat', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final messageStore = _MemoryMessageStore()
      ..messages.add(
        const ChatMessage(
          id: 'one-search-source',
          role: 'model',
          content:
              'Here is the answer.\n\n**Search sources**\n'
              '- [First source](https://localhost/first)\n'
              '- [Invalid source](https://:443/invalid)',
          timestamp: '2026-11-06 22:00:00',
          createdAtUtc: 1793973600000,
        ),
      );
    await tester.pumpWidget(
      _testApp(messageStore: messageStore, replyService: _FakeReplyService()),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('search-results-button-one-search-source')),
      findsNothing,
    );
    expect(find.text('First source'), findsOneWidget);
    expect(find.text('Search sources'), findsOneWidget);
    expect(
      find.byKey(
        const ValueKey('link-preview-request-https://localhost/first'),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('link-preview-request-https://:443/invalid')),
      findsNothing,
    );
  });

  testWidgets('two search results use a web pages button', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final messageStore = _MemoryMessageStore()
      ..messages.add(
        const ChatMessage(
          id: 'two-search-sources',
          role: 'model',
          content:
              'Here is the answer with [a link](https://localhost/first).\n\n'
              '**Search sources**\n'
              '- [First source](https://localhost/first)\n'
              '- [Second source](https://localhost/second)',
          timestamp: '2026-11-06 22:00:00',
          createdAtUtc: 1793973600000,
        ),
      );
    await tester.pumpWidget(
      _testApp(messageStore: messageStore, replyService: _FakeReplyService()),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('search-results-button-two-search-sources')),
      findsOneWidget,
    );
    expect(find.text('2 web pages'), findsOneWidget);
    expect(find.text('Search sources'), findsNothing);
    expect(
      find.byKey(
        const ValueKey('link-preview-request-https://localhost/first'),
      ),
      findsNothing,
    );
  });

  testWidgets(
    'search results open in a side panel and keep settings floating',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final messageCreatedAtUtc = DateTime.utc(
        2026,
        11,
        12,
        17,
      ).millisecondsSinceEpoch;
      final messageStore = _MemoryMessageStore()
        ..messages.add(
          ChatMessage(
            id: 'five-search-sources',
            role: 'model',
            content:
                'Here is the answer.\n\n**Search sources**\n'
                '- [First source](https://localhost/first)\n'
                '- [Second source](https://localhost/second)\n'
                '- [Third source](https://localhost/third)\n'
                '- [Fourth source](https://localhost/fourth)\n'
                '- [](https://localhost/fifth)',
            timestamp: '2026-11-06 22:00:00',
            createdAtUtc: messageCreatedAtUtc,
          ),
        );
      await tester.pumpWidget(
        _testApp(messageStore: messageStore, replyService: _FakeReplyService()),
      );
      await tester.pumpAndSettle();

      final button = find.byKey(
        const ValueKey('search-results-button-five-search-sources'),
      );
      expect(button, findsOneWidget);
      expect(find.text('5 web pages'), findsOneWidget);
      for (final path in ['first', 'second', 'third', 'fourth']) {
        expect(
          find.byKey(ValueKey('website-badge-https://localhost/$path')),
          findsOneWidget,
        );
      }
      expect(
        find.byKey(const ValueKey('website-badge-https://localhost/fifth')),
        findsNothing,
      );
      final firstBadge = tester.widget<Container>(
        find.byKey(const ValueKey('website-badge-https://localhost/first')),
      );
      final badgeDecoration = firstBadge.decoration! as BoxDecoration;
      expect(badgeDecoration.color, const Color(0xFF2A2B2F));
      expect(badgeDecoration.border, isNotNull);
      final buttonSurface = tester.widget<Material>(
        find.byKey(
          const ValueKey('search-results-button-surface-five-search-sources'),
        ),
      );
      expect(buttonSurface.color, Colors.transparent);
      expect(buttonSurface.shape, isA<StadiumBorder>());
      final composer = find.byKey(const ValueKey('chat-composer'));
      final composerCenterBeforeOpen = tester.getCenter(composer).dx;
      await tester.tap(button);
      await tester.pumpAndSettle();

      final panel = find.byKey(const ValueKey('search-results-panel'));
      expect(panel, findsOneWidget);
      expect(tester.getSize(panel).width, 390);
      expect(
        find.byKey(const ValueKey('close-search-results')),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const ValueKey('search-result-card-https://localhost/first'),
        ),
        findsOneWidget,
      );
      expect(find.textContaining('| 2026/11/13'), findsNWidgets(5));
      expect(find.text('First source'), findsOneWidget);
      expect(find.text('https://localhost/fifth'), findsOneWidget);
      expect(tester.getCenter(composer).dx, lessThan(composerCenterBeforeOpen));
      expect(find.byTooltip('Settings'), findsOneWidget);
      expect(
        tester.getRect(find.byTooltip('Settings')).center.dx,
        greaterThan(tester.getRect(panel).left),
      );
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Close settings'), findsOneWidget);
      await tester.tap(find.byTooltip('Close settings'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('close-search-results')));
      await tester.pumpAndSettle();
      expect(panel, findsNothing);
      expect(tester.getCenter(composer).dx, composerCenterBeforeOpen);
    },
  );

  testWidgets(
    'terminal approval stays beside the composer and clears after run',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final replyService = _FakeReplyService()
        ..terminalCommandRequest = TerminalCommandRequest(
          command: "printf 'terminal-output'",
          workingDirectory: Directory.current.path,
        )
        ..terminalCommandResult = TerminalCommandResult(
          request: TerminalCommandRequest(
            command: "printf 'terminal-output'",
            workingDirectory: Directory.current.path,
          ),
          exitCode: 0,
          stdout: 'terminal-output',
          stderr: '',
        );
      final messageStore = _MemoryMessageStore();
      await tester.pumpWidget(
        _testApp(
          configStore: _MemoryAiConfigStore(),
          messageStore: messageStore,
          replyService: replyService,
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField),
        'Run a safe test command.',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(
        find.byKey(const ValueKey('terminal-command-approval')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('terminal-command-text')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('terminal-activity-content')),
          matching: find.byType(HighlightView),
        ),
        findsOneWidget,
      );
      final bashHighlight = tester.widget<HighlightView>(
        find.descendant(
          of: find.byKey(const ValueKey('terminal-activity-content')),
          matching: find.byType(HighlightView),
        ),
      );
      expect(bashHighlight.language, 'bash');
      expect(bashHighlight.theme['root']?.color, const Color(0xFFC9D5E8));
      expect(bashHighlight.theme['built_in']?.color, const Color(0xFF61AFEF));
      expect(
        tester
            .getRect(find.byKey(const ValueKey('terminal-command-approval')))
            .bottom,
        lessThanOrEqualTo(
          tester.getRect(find.byKey(const ValueKey('chat-composer'))).top,
        ),
      );
      expect(find.byTooltip('Copy'), findsNothing);
      expect(find.byTooltip('Like'), findsNothing);
      expect(find.byTooltip('Dislike'), findsNothing);
      expect(find.byTooltip('Speech'), findsNothing);
      expect(find.byTooltip('Regenerate'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('terminal-command-allow')));
      for (
        var attempt = 0;
        attempt < 40 &&
            find
                .byKey(const ValueKey('terminal-command-approval'))
                .evaluate()
                .isNotEmpty;
        attempt++
      ) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pumpAndSettle();

      final assistantMessage = messageStore.messages.singleWhere(
        (message) => message.role == 'model',
      );
      expect(assistantMessage.content, isNotEmpty);
      expect(assistantMessage.terminalActivities, hasLength(1));
      expect(
        assistantMessage.terminalActivities.single.stdout,
        'terminal-output',
      );
      expect(find.byTooltip('Copy'), findsOneWidget);
      expect(find.byTooltip('Like'), findsOneWidget);
      expect(find.byTooltip('Dislike'), findsOneWidget);
      expect(find.byTooltip('Speech'), findsOneWidget);
      expect(find.byTooltip('Regenerate'), findsOneWidget);
      expect(
        assistantMessage.terminalActivities.single.responseMessageId,
        assistantMessage.id,
      );
      expect(find.text('Terminal activity'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('terminal-activity-arrow-right')),
        findsOneWidget,
      );
      expect(
        tester.widget<CustomPaint>(
          find.byKey(const ValueKey('terminal-activity-arrow-right')),
        ),
        isNotNull,
      );
      final responseContentRect = tester.getRect(
        find.byKey(
          ValueKey('assistant-message-content-${assistantMessage.id}'),
        ),
      );
      final activityToggleRect = tester.getRect(
        find.byKey(const ValueKey('terminal-activity-toggle')),
      );
      expect(
        activityToggleRect.bottom,
        lessThanOrEqualTo(responseContentRect.top),
      );
      expect(
        responseContentRect.top - activityToggleRect.bottom,
        lessThanOrEqualTo(8),
      );
      expect(find.text('terminal-output'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('terminal-activity-toggle')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('terminal-activity-arrow-down')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('terminal-activity-content')),
        findsOneWidget,
      );
      expect(find.byType(HighlightView), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('terminal-activity-content')),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is SingleChildScrollView &&
                widget.scrollDirection == Axis.horizontal,
          ),
        ),
        findsWidgets,
      );
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is SelectableText &&
              widget.data?.contains('Exit code: 0') == true,
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('terminal-command-approval')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('terminal-command-result')),
        findsNothing,
      );
    },
  );

  testWidgets('completed AI reply notifies when app is inactive', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final notificationArguments = <List<String>>[];
    final notificationService = DesktopNotificationService(
      isLinux: true,
      runner: (executable, arguments) async {
        notificationArguments.add(arguments);
        return ProcessResult(1, 0, '', '');
      },
    );
    await tester.pumpWidget(
      _testApp(
        configStore: _MemoryAiConfigStore()..apiKeys = ['test-key'],
        messageStore: _MemoryMessageStore(),
        replyService: _FakeReplyService(reply: 'Your update is ready.'),
        notificationService: notificationService,
      ),
    );
    await tester.pumpAndSettle();
    addTearDown(
      () => tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      ),
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.enterText(find.byType(TextField), 'Check the update.');
    await tester.tap(find.byIcon(LucideIcons300.arrowUp));
    await tester.pumpAndSettle();

    expect(notificationArguments, hasLength(1));
    expect(notificationArguments.single[2], 'Sara sent you a message');
    expect(notificationArguments.single.last, 'Your update is ready.');
  });

  testWidgets('terminal approval notifies when app is inactive', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const command = "printf 'approval-needed'";
    final notificationArguments = <List<String>>[];
    final notificationService = DesktopNotificationService(
      isLinux: true,
      runner: (executable, arguments) async {
        notificationArguments.add(arguments);
        return ProcessResult(1, 0, '', '');
      },
    );
    final replyService = _FakeReplyService()
      ..terminalCommandRequest = TerminalCommandRequest(
        command: command,
        workingDirectory: Directory.current.path,
      );
    await tester.pumpWidget(
      _testApp(
        configStore: _MemoryAiConfigStore()..apiKeys = ['test-key'],
        messageStore: _MemoryMessageStore(),
        replyService: replyService,
        notificationService: notificationService,
      ),
    );
    await tester.pumpAndSettle();
    addTearDown(
      () => tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      ),
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.enterText(find.byType(TextField), 'Run a command.');
    await tester.tap(find.byIcon(LucideIcons300.arrowUp));
    for (
      var attempt = 0;
      attempt < 40 &&
          find
              .byKey(const ValueKey('terminal-command-approval'))
              .evaluate()
              .isEmpty;
      attempt++
    ) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(
      find.byKey(const ValueKey('terminal-command-approval')),
      findsOneWidget,
    );
    expect(notificationArguments, hasLength(1));
    expect(notificationArguments.single[2], 'Sara needs your approval');
    expect(notificationArguments.single.last, contains(command));

    await tester.tap(find.byKey(const ValueKey('terminal-command-skip')));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
  });

  testWidgets('completed AI reply does not notify while chat is active', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final notificationArguments = <List<String>>[];
    final notificationService = DesktopNotificationService(
      isLinux: true,
      runner: (executable, arguments) async {
        notificationArguments.add(arguments);
        return ProcessResult(1, 0, '', '');
      },
    );
    await tester.pumpWidget(
      _testApp(
        configStore: _MemoryAiConfigStore()..apiKeys = ['test-key'],
        messageStore: _MemoryMessageStore(),
        replyService: _FakeReplyService(reply: 'Your update is ready.'),
        notificationService: notificationService,
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Check the update.');
    await tester.tap(find.byIcon(LucideIcons300.arrowUp));
    await tester.pumpAndSettle();

    expect(notificationArguments, isEmpty);
  });

  testWidgets('completed AI reply notifies while Settings is open', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final replyGate = Completer<String>();
    final notificationArguments = <List<String>>[];
    final notificationService = DesktopNotificationService(
      isLinux: true,
      runner: (executable, arguments) async {
        notificationArguments.add(arguments);
        return ProcessResult(1, 0, '', '');
      },
    );
    await tester.pumpWidget(
      _testApp(
        configStore: _MemoryAiConfigStore()..apiKeys = ['test-key'],
        messageStore: _MemoryMessageStore(),
        replyService: _FakeReplyService(
          reply: 'The result is ready.',
          replyGate: replyGate.future,
        ),
        notificationService: notificationService,
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Run the task.');
    await tester.tap(find.byIcon(LucideIcons300.arrowUp));
    await tester.pump();
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();

    replyGate.complete('The result is ready.');
    await tester.pumpAndSettle();

    expect(notificationArguments, hasLength(1));
    expect(notificationArguments.single[2], 'Sara sent you a message');
    expect(notificationArguments.single.last, 'The result is ready.');
  });

  testWidgets('English is the default and language changes update the UI', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    AppLanguageController.language.value = AppLanguage.english;
    addTearDown(() async {
      AppLanguageController.language.value = AppLanguage.english;
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString('app_language', 'en');
    });
    await tester.pumpWidget(
      _testApp(
        configStore: _MemoryAiConfigStore(),
        messageStore: _MemoryMessageStore(),
        replyService: _FakeReplyService(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('What would you like to talk about?'), findsOneWidget);
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('app-language-selector')),
    );
    final languageDescription = tester.getRect(
      find.text('Choose the language used throughout Sara.'),
    );
    final languageSelector = tester.getRect(
      find.byKey(const ValueKey('app-language-selector')),
    );
    expect(languageSelector.left, greaterThan(languageDescription.right));
    await tester.tap(find.text('Indonesian'));
    await tester.pumpAndSettle();

    expect(find.text('Pengaturan'), findsOneWidget);
    expect(find.text('Atur ruang chat sesuai keinginanmu'), findsNothing);
    await AppLanguageController.set(AppLanguage.english);
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Personalize your chat workspace'), findsNothing);
    expect(find.text('From'), findsOneWidget);
    expect(find.byKey(const ValueKey('developer-brand-logo')), findsOneWidget);
    final brandBanner = tester.widget<Container>(
      find.byKey(const ValueKey('developer-brand-banner')),
    );
    expect((brandBanner.decoration! as BoxDecoration).border, isNull);
    expect(
      (brandBanner.decoration! as BoxDecoration).color,
      Colors.transparent,
    );
    final bannerRect = tester.getRect(
      find.byKey(const ValueKey('developer-brand-banner')),
    );
    final fromRect = tester.getRect(find.text('From'));
    final brandRect = tester.getRect(
      find.byKey(const ValueKey('developer-brand-logo')),
    );
    expect(fromRect.center.dx, closeTo(bannerRect.center.dx, 1));
    expect(brandRect.center.dx, closeTo(bannerRect.center.dx, 1));
    expect(brandRect.bottom, closeTo(bannerRect.bottom - 10, 1));
    expect(fromRect.bottom, closeTo(brandRect.top - 4, 1));
    final personalHeader = find
        .ancestor(
          of: find.text('Make Sara feel more like yours.'),
          matching: find.byType(Row),
        )
        .first;
    final personalIcon = find.descendant(
      of: personalHeader,
      matching: find.byIcon(LucideIcons300.userRound),
    );
    final personalIconTheme = find
        .ancestor(of: personalIcon, matching: find.byType(IconTheme))
        .first;
    expect(tester.widget<IconTheme>(personalIconTheme).data.size, 30);
    final personalIconFrame = tester.widget<Container>(
      find.byKey(const ValueKey('settings-section-icon-frame')),
    );
    expect((personalIconFrame.decoration! as BoxDecoration).border, isNotNull);
    final languageIcon = tester.widget<Icon>(
      find.byKey(const ValueKey('settings-language-icon')),
    );
    expect(languageIcon.icon, LucideIcons300.globe);
    expect(languageIcon.size, 28);
    await tester.tap(find.text('Configure'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const ValueKey('configure-help-toggle')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Set up Google Gemini'), findsOneWidget);
    expect(find.byKey(const ValueKey('open-google-ai-studio')), findsOneWidget);
    expect(find.text('Gemini API keys'), findsNothing);
    expect(find.text('?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('settings-nav-configure')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Set up Google Gemini'), findsNothing);
    expect(find.text('Gemini API keys'), findsOneWidget);
    final configureIcon = find.byIcon(LucideIcons300.slidersHorizontal).last;
    final configureIconTheme = find
        .ancestor(of: configureIcon, matching: find.byType(IconTheme))
        .first;
    expect(tester.widget<IconTheme>(configureIconTheme).data.size, 30);
    await tester.tap(find.text('Data'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.byKey(const ValueKey('settings-data-camera-icon')),
      findsNothing,
    );
    expect(
      tester
          .widget<Container>(
            find.byKey(const ValueKey('settings-content-panel')),
          )
          .color,
      const Color(0xFF24262A),
    );
    final cameraSwitch = find.byKey(const ValueKey('camera-access-switch'));
    expect(tester.widget<Switch>(cameraSwitch).value, isFalse);
    await tester.tap(cameraSwitch);
    await tester.pumpAndSettle();
    final activeSwitch = tester.widget<Switch>(cameraSwitch);
    expect(activeSwitch.value, isTrue);
    expect(
      activeSwitch.thumbColor?.resolve({WidgetState.selected}),
      const Color(0xFFDCE4F5),
    );
    expect(
      activeSwitch.trackColor?.resolve({WidgetState.selected}),
      const Color(0xFF46536D),
    );
    expect(
      (await SharedPreferences.getInstance()).getBool('sara_camera_enabled'),
      isTrue,
    );
    expect(
      tester.widget<Container>(
        find.byKey(const ValueKey('developer-brand-banner')),
      ),
      isNotNull,
    );
    await tester.tap(find.byTooltip('Close settings'));
    await tester.pumpAndSettle();
    expect(find.text('What would you like to talk about?'), findsOneWidget);
  });

  testWidgets('API key list shows three rows and scrolls inside its panel', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final configStore = _MemoryAiConfigStore()
      ..values['ai_model'] = 'gemini-3.5-flash-lite'
      ..apiKeys = [
        'test-key-1111',
        'test-key-2222',
        'test-key-3333',
        'test-key-4444',
        'test-key-5555',
      ];
    await tester.pumpWidget(
      _testApp(
        configStore: configStore,
        messageStore: _MemoryMessageStore(),
        replyService: _FakeReplyService(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-nav-configure')));
    await tester.pumpAndSettle();

    final viewport = find.byKey(const ValueKey('api-key-list-viewport'));
    final viewportRect = tester.getRect(viewport);
    expect(viewportRect.height, closeTo(3 * 46.0, 0.1));
    for (var index = 1; index <= 3; index++) {
      final tileRect = tester.getRect(
        find.byKey(ValueKey('api-key-tile-$index')),
      );
      expect(tileRect.top, greaterThanOrEqualTo(viewportRect.top));
      expect(tileRect.bottom, lessThanOrEqualTo(viewportRect.bottom));
    }

    await tester.drag(viewport, const Offset(0, -100));
    await tester.pumpAndSettle();
    final scrolledViewportRect = tester.getRect(viewport);
    final fourthTile = find.byKey(const ValueKey('api-key-tile-4'));
    final scrolledFourthTileRect = tester.getRect(fourthTile);
    expect(
      scrolledFourthTileRect.top,
      greaterThanOrEqualTo(scrolledViewportRect.top),
    );
    expect(
      scrolledFourthTileRect.bottom,
      lessThanOrEqualTo(scrolledViewportRect.bottom),
    );
  });

  testWidgets('Ctrl+V pastes plain text without closing the chat', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.getData') {
            return {'text': 'pasted text'};
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );

    await tester.pumpWidget(
      _testApp(
        messageStore: _MemoryMessageStore(),
        replyService: _FakeReplyService(),
        clipboardImageReader: () async => null,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(TextField));
    await tester.enterText(find.byType(TextField), 'draft ');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'draft pasted text',
    );
    expect(find.byType(SaraApp), findsOneWidget);
  });

  testWidgets('Ctrl+V attaches clipboard image without closing the chat', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final imageFile = File('${Directory.current.path}/assets/flutter_logo.png');
    final imageBytes = await tester.runAsync(imageFile.readAsBytes);
    var imageReaderCalled = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.getData') return null;
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );

    await tester.pumpWidget(
      _testApp(
        messageStore: _MemoryMessageStore(),
        replyService: _FakeReplyService(),
        clipboardImageReader: () async {
          imageReaderCalled = true;
          return Uint8List.fromList(imageBytes!);
        },
        clipboardImageSaver: (_) async => ChatAttachment(
          id: 'pasted-image',
          path: imageFile.path,
          name: 'clipboard-image.png',
          mimeType: 'image/png',
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(TextField));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(imageReaderCalled, isTrue);
    expect(tester.takeException(), isNull);
    expect(find.text('clipboard-image.png'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('attachment-preview-tile-pasted-image')),
      findsOneWidget,
    );
    expect(find.byType(SaraApp), findsOneWidget);
  });

  testWidgets('photo picker adds local paths as attachment previews', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final imageFile = File('${Directory.current.path}/assets/flutter_logo.png');

    final originalPlatform = FilePickerPlatform.instance;
    FilePickerPlatform.instance = _FakeFilePickerPlatform([
      _TestPlatformFile('flutter_logo.png', imageFile.path),
    ]);
    addTearDown(() => FilePickerPlatform.instance = originalPlatform);

    final messageStore = _MemoryMessageStore();
    await tester.pumpWidget(
      _testApp(messageStore: messageStore, replyService: _FakeReplyService()),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Add attachment'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Photo'));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(Image).last);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('attachment-preview-dialog')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('close-attachment-preview')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('close-attachment-preview')));
    await tester.pumpAndSettle();

    expect(find.text('flutter_logo.png'), findsOneWidget);
    final composerImageTile = find.descendant(
      of: find.byKey(const ValueKey('chat-composer')),
      matching: find.byWidgetPredicate(
        (widget) =>
            widget.key is ValueKey<String> &&
            (widget.key! as ValueKey<String>).value.startsWith(
              'attachment-preview-tile-',
            ),
      ),
    );
    expect(tester.getSize(composerImageTile), const Size(68, 68));
    await tester.enterText(find.byType(TextField), 'What is in this image?');
    await tester.pump();
    await tester.tap(find.byIcon(LucideIcons300.arrowUp));
    await tester.pumpAndSettle();
    expect(find.text('flutter_logo.png'), findsOneWidget);
    expect(messageStore.attachments.values.single.single.path, imageFile.path);
    await tester.tap(find.byType(Image).last);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('attachment-preview-dialog')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('close-attachment-preview')));
    await tester.pumpAndSettle();
    final attachmentRect = tester.getRect(
      find.byKey(const ValueKey('sent-attachment-grid')),
    );
    final attachmentTileSize = tester.getSize(
      find.byKey(
        ValueKey(
          'attachment-preview-tile-${messageStore.attachments.values.single.single.id}',
        ),
      ),
    );
    final attachmentImage = tester.widget<Image>(
      find.descendant(
        of: find.byKey(
          ValueKey(
            'attachment-preview-tile-${messageStore.attachments.values.single.single.id}',
          ),
        ),
        matching: find.byType(Image),
      ),
    );
    final bubbleRect = tester.getRect(
      find.byKey(const ValueKey('user-message-bubble')),
    );
    expect(attachmentRect.bottom, lessThan(bubbleRect.top));
    expect(attachmentTileSize.width, lessThanOrEqualTo(160));
    expect(attachmentTileSize.height, lessThanOrEqualTo(180));
    expect(
      (attachmentTileSize.width / attachmentTileSize.height),
      closeTo(1, 0.02),
    );
    expect(attachmentImage.fit, BoxFit.contain);
    expect(bubbleRect.width, lessThanOrEqualTo(560));
  });

  testWidgets('composer shows regular files as wide attachment cards', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final filePath = '${Directory.current.path}/logic.txt';
    final originalPlatform = FilePickerPlatform.instance;
    FilePickerPlatform.instance = _FakeFilePickerPlatform([
      _TestPlatformFile('logic.txt', filePath),
    ]);
    addTearDown(() => FilePickerPlatform.instance = originalPlatform);

    await tester.pumpWidget(
      _testApp(
        messageStore: _MemoryMessageStore(),
        replyService: _FakeReplyService(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Add attachment'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('File'));
    await tester.pumpAndSettle();

    final fileTile = find.descendant(
      of: find.byKey(const ValueKey('chat-composer')),
      matching: find.byWidgetPredicate(
        (widget) =>
            widget.key is ValueKey<String> &&
            (widget.key! as ValueKey<String>).value.startsWith(
              'attachment-preview-tile-',
            ),
      ),
    );
    expect(tester.getSize(fileTile), const Size(224, 52));
    expect(find.text('logic.txt'), findsOneWidget);
  });

  testWidgets('composer uses one file icon for supported and unknown files', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final directory = await tester.runAsync(
      () => Directory.systemTemp.createTemp('sara-file-icons-'),
    );
    addTearDown(() => directory!.delete(recursive: true));
    const extensions = ['pdf', 'json', 'html', 'py', 'txt', 'md', 'bin'];
    final filePaths = await tester.runAsync(() async {
      final paths = <String>[];
      for (final extension in extensions) {
        final file = File('${directory!.path}/sample.$extension');
        await file.writeAsString('file content');
        paths.add(file.path);
      }
      return paths;
    });

    final originalPlatform = FilePickerPlatform.instance;
    FilePickerPlatform.instance = _FakeFilePickerPlatform(
      filePaths!
          .asMap()
          .entries
          .map(
            (entry) => _TestPlatformFile(
              'sample.${extensions[entry.key]}',
              entry.value,
            ),
          )
          .toList(),
    );
    addTearDown(() => FilePickerPlatform.instance = originalPlatform);

    await tester.pumpWidget(
      _testApp(
        messageStore: _MemoryMessageStore(),
        replyService: _FakeReplyService(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Add attachment'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('File'));
    await tester.pumpAndSettle();

    final composer = find.byKey(const ValueKey('chat-composer'));
    final attachmentList = find.descendant(
      of: composer,
      matching: find.byType(ListView),
    );
    for (final extension in extensions) {
      final fileTile = find.byKey(ValueKey('attachment-file-tile.$extension'));
      await tester.dragUntilVisible(
        fileTile,
        attachmentList,
        const Offset(-300, 0),
      );
      expect(tester.getSize(fileTile), const Size(224, 52));
      final fileIcon = tester.widget<CustomPaint>(
        find.descendant(
          of: fileTile,
          matching: find.byKey(const ValueKey('attachment-generic-file-icon')),
        ),
      );
      expect(fileIcon.painter, isNotNull);
      expect(fileIcon.size, const Size(23, 26));
    }
  });

  testWidgets('camera preview closes and captures a photo into attachments', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final imageFile = File('${Directory.current.path}/assets/flutter_logo.png');
    final imageBytes = await tester.runAsync(imageFile.readAsBytes);
    final sessions = <StreamController<Uint8List>>[];
    var closeCount = 0;
    var cacheCleanupCount = 0;
    Future<CameraPreviewSession> openSession() async {
      final frames = StreamController<Uint8List>();
      sessions.add(frames);
      return CameraPreviewSession(
        frames: frames.stream,
        close: () async {
          closeCount++;
          await frames.close();
        },
      );
    }

    Uint8List? savedBytes;
    await tester.pumpWidget(
      _testApp(
        messageStore: _MemoryMessageStore(),
        replyService: _FakeReplyService(),
        cameraSessionFactory: openSession,
        cameraCacheCleaner: (_) async {
          cacheCleanupCount++;
        },
        cameraImageSaver: (bytes) async {
          savedBytes = Uint8List.fromList(bytes);
          return ChatAttachment(
            id: 'camera-photo',
            path: imageFile.path,
            name: 'camera-photo.png',
            mimeType: 'image/png',
          );
        },
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(cacheCleanupCount, 1);

    await tester.tap(find.byTooltip('Add attachment'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Camera'));
    await tester.pump();
    expect(find.byKey(const ValueKey('camera-close')), findsOneWidget);
    final cameraDialog = find.byKey(const ValueKey('camera-frame'));
    final dialogRect = tester.getRect(cameraDialog);
    expect(dialogRect.width, greaterThan(1000));
    expect(dialogRect.width, lessThan(1200));
    expect(dialogRect.height, greaterThan(600));
    expect(dialogRect.height, lessThan(750));
    expect(dialogRect.width, lessThan(1280));
    expect(dialogRect.height, lessThan(800));
    final closeRect = tester.getRect(
      find.byKey(const ValueKey('camera-close')),
    );
    expect(dialogRect.right - closeRect.right, lessThan(12));
    expect(dialogRect.top - closeRect.top, lessThan(12));
    expect(find.text('Capture photo'), findsNothing);
    expect(find.text('Camera'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('camera-close')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();
    expect(closeCount, 1);
    expect(find.byKey(const ValueKey('camera-preview-image')), findsNothing);

    await tester.tap(find.byTooltip('Add attachment'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Camera'));
    await tester.pump();
    sessions.last.add(Uint8List.fromList(imageBytes!));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('camera-preview-image')), findsOneWidget);
    final shutterRect = tester.getRect(
      find.byKey(const ValueKey('camera-shutter-icon')),
    );
    expect(shutterRect.center.dx, closeTo(dialogRect.center.dx, 1));
    expect(shutterRect.center.dy, greaterThan(dialogRect.center.dy));
    expect(shutterRect.bottom, lessThan(dialogRect.bottom));
    await tester.tap(find.byKey(const ValueKey('camera-capture')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();

    expect(closeCount, 2);
    expect(savedBytes, orderedEquals(imageBytes));
    expect(find.text('camera-photo.png'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);
    await tester.pump();
    expect(cacheCleanupCount, 2);
  });

  test('camera cache is cleared on startup and application exit', () async {
    final directory = await Directory.systemTemp.createTemp('sara-camera-');
    addTearDown(() => directory.delete(recursive: true));
    final supportDirectory = Directory('${directory.path}/support');
    final cacheDirectory = Directory('${directory.path}/cache');
    final cameraDirectory = Directory(
      '${cacheDirectory.path}/Sara/camera-attachments',
    );
    await cameraDirectory.create(recursive: true);
    final photo = File('${cameraDirectory.path}/photo.png');
    await photo.writeAsBytes([1, 2, 3]);
    final autonomousCameraDirectory = Directory(
      '${cacheDirectory.path}/Sara/autonomous-camera',
    );
    await autonomousCameraDirectory.create(recursive: true);
    final autonomousFrame = File(
      '${autonomousCameraDirectory.path}/temporary-frame.jpg',
    );
    await autonomousFrame.writeAsBytes([0xFF, 0xD8, 0xFF, 0xD9]);
    final clipboardDirectory = Directory(
      '${supportDirectory.path}/Sara/clipboard-attachments',
    );
    await clipboardDirectory.create(recursive: true);
    final sentPhoto = File('${clipboardDirectory.path}/sent-photo.png');
    await sentPhoto.writeAsBytes([7, 8, 9]);
    final store = _MemoryMessageStore()
      ..attachments['previous-camera-message'] = [
        ChatAttachment(
          id: 'previous-camera-photo',
          path: photo.path,
          name: 'camera-photo.png',
          mimeType: 'image/png',
          isClipboardCopy: true,
        ),
        ChatAttachment(
          id: 'sent-camera-photo',
          path: sentPhoto.path,
          name: 'camera-photo.png',
          mimeType: 'image/png',
          isClipboardCopy: true,
        ),
      ];

    await CameraCaptureCache.clear(
      messageStore: store,
      supportDirectory: supportDirectory,
      cacheDirectory: cacheDirectory,
    );

    expect(await photo.exists(), isFalse);
    expect(await autonomousFrame.exists(), isFalse);
    expect(await sentPhoto.exists(), isFalse);
    expect(
      store.attachments['previous-camera-message']!.every(
        (attachment) => attachment.path == null,
      ),
      isTrue,
    );

    final closingPhoto = File('${cameraDirectory.path}/closing-photo.png');
    await closingPhoto.writeAsBytes([4, 5, 6]);
    store.attachments['current-camera-message'] = [
      ChatAttachment(
        id: 'current-camera-photo',
        path: closingPhoto.path,
        name: 'camera-photo.png',
        mimeType: 'image/png',
        isClipboardCopy: true,
      ),
    ];
    await CameraCaptureCache.clear(
      messageStore: store,
      supportDirectory: supportDirectory,
      cacheDirectory: cacheDirectory,
    );
    expect(await closingPhoto.exists(), isFalse);
    expect(store.attachments['current-camera-message']!.single.path, isNull);
  });

  testWidgets('video attachments show an extracted thumbnail in the grid', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final directory = await tester.runAsync(
      () => Directory.systemTemp.createTemp('sara-video-thumbnail-'),
    );
    addTearDown(() => directory!.delete(recursive: true));
    final videoPath = '${directory!.path}/sample.mp4';
    final generatedVideo = await tester.runAsync(
      () => Process.run('ffmpeg', [
        '-hide_banner',
        '-loglevel',
        'error',
        '-f',
        'lavfi',
        '-i',
        'color=c=red:s=64x64:d=1',
        '-c:v',
        'mpeg4',
        '-y',
        videoPath,
      ]),
    );
    expect(generatedVideo!.exitCode, 0, reason: '${generatedVideo.stderr}');

    final originalPlatform = FilePickerPlatform.instance;
    FilePickerPlatform.instance = _FakeFilePickerPlatform([
      _TestPlatformFile('sample.mp4', videoPath),
    ]);
    addTearDown(() => FilePickerPlatform.instance = originalPlatform);

    await tester.pumpWidget(
      _testApp(
        messageStore: _MemoryMessageStore(),
        replyService: _FakeReplyService(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Add attachment'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Photo'));
    await tester.pumpAndSettle();

    for (
      var attempt = 0;
      attempt < 20 &&
          find
              .byKey(const ValueKey('video-attachment-thumbnail-image'))
              .evaluate()
              .isEmpty;
      attempt++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 250)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();

    expect(find.text('sample.mp4'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('video-attachment-thumbnail-image')),
      findsOneWidget,
    );
    final thumbnail = tester.widget<Image>(
      find.byKey(const ValueKey('video-attachment-thumbnail-image')),
    );
    final thumbnailFile = (thumbnail.image as FileImage).file;
    expect(thumbnailFile.existsSync(), isTrue);
    expect(thumbnail.fit, BoxFit.cover);
    expect(find.byIcon(LucideIcons300.circlePlay), findsOneWidget);
  });

  testWidgets('file picker blocks environment files', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final directory = await tester.runAsync(
      () => Directory.systemTemp.createTemp('sara-env-block-'),
    );
    final envFile = File('${directory!.path}/.env.local');
    await tester.runAsync(() => envFile.writeAsString('API_KEY=private'));
    addTearDown(() => directory.delete(recursive: true));

    final originalPlatform = FilePickerPlatform.instance;
    FilePickerPlatform.instance = _FakeFilePickerPlatform([
      _TestPlatformFile('.env.local', envFile.path),
    ]);
    addTearDown(() => FilePickerPlatform.instance = originalPlatform);

    await tester.pumpWidget(
      _testApp(
        messageStore: _MemoryMessageStore(),
        replyService: _FakeReplyService(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Add attachment'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('File'));
    await tester.pumpAndSettle();

    expect(
      find.text('Sensitive file cannot be uploaded: .env.local'),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('chat-composer')),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget.key is ValueKey<String> &&
              (widget.key! as ValueKey<String>).value.startsWith(
                'attachment-preview-tile-',
              ),
        ),
      ),
      findsNothing,
    );
  });

  testWidgets('uploaded attachments leave the latest chat message scrollable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final imagePath = '${Directory.current.path}/assets/flutter_logo.png';
    final originalPlatform = FilePickerPlatform.instance;
    FilePickerPlatform.instance = _FakeFilePickerPlatform([
      _TestPlatformFile('flutter_logo.png', imagePath),
    ]);
    addTearDown(() => FilePickerPlatform.instance = originalPlatform);

    final messageStore = _MemoryMessageStore()
      ..messages.addAll(
        List.generate(
          18,
          (index) => ChatMessage(
            id: 'attachment-scroll-$index',
            role: index.isEven ? 'user' : 'model',
            content:
                'Scrollable history message $index ${'A long line. ' * 12}',
            timestamp: 'today',
            createdAtUtc: index,
          ),
        ),
      );
    await tester.pumpWidget(
      _testApp(messageStore: messageStore, replyService: _FakeReplyService()),
    );
    await tester.pumpAndSettle();
    final listFinder = find.byType(ListView).first;
    final listView = tester.widget<ListView>(listFinder);
    final initialViewport = tester.getRect(listFinder);
    expect(listView.controller!.position.extentAfter, lessThanOrEqualTo(1));

    await tester.tap(find.byTooltip('Add attachment'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Photo'));
    await tester.pumpAndSettle();

    final composer = find.byKey(const ValueKey('chat-composer'));
    final composerRect = tester.getRect(composer);
    final uploadedViewport = tester.getRect(listFinder);
    expect(uploadedViewport.height, lessThan(initialViewport.height));
    expect(uploadedViewport.bottom, lessThanOrEqualTo(composerRect.top));
    expect(find.text('flutter_logo.png'), findsOneWidget);
    expect(listView.controller!.position.extentAfter, greaterThan(0));

    await tester.drag(listFinder, const Offset(0, -1200));
    await tester.pumpAndSettle();
    expect(listView.controller!.position.extentAfter, lessThanOrEqualTo(1));
    expect(
      tester.getRect(find.byKey(const ValueKey('attachment-scroll-17'))).bottom,
      lessThanOrEqualTo(uploadedViewport.bottom),
    );
  });

  testWidgets('composer refreshes availability when attachments are appended', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final imagePath = '${Directory.current.path}/assets/flutter_logo.png';
    final filePath = '${Directory.current.path}/logic.txt';
    final originalPlatform = FilePickerPlatform.instance;
    FilePickerPlatform.instance = _FakeFilePickerPlatform([
      _TestPlatformFile('flutter_logo.png', imagePath),
    ]);
    addTearDown(() => FilePickerPlatform.instance = originalPlatform);

    await tester.pumpWidget(
      _testApp(
        messageStore: _MemoryMessageStore(),
        replyService: _FakeReplyService(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Add attachment'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Photo'));
    await tester.pumpAndSettle();

    FilePickerPlatform.instance = _FakeFilePickerPlatform([
      _TestPlatformFile('logic.txt', filePath),
    ]);
    await tester.tap(find.byTooltip('Add attachment'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('File'));
    await tester.pumpAndSettle();

    final composer = find.byKey(const ValueKey('chat-composer'));
    final tiles = find.descendant(
      of: composer,
      matching: find.byWidgetPredicate(
        (widget) =>
            widget.key is ValueKey<String> &&
            (widget.key! as ValueKey<String>).value.startsWith(
              'attachment-preview-tile-',
            ),
      ),
    );
    expect(tiles, findsNWidgets(2));
    expect(
      find.descendant(of: composer, matching: find.byType(Image)),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: composer,
        matching: find.byIcon(LucideIcons300.triangleAlert),
      ),
      findsNothing,
    );
    expect(find.text('logic.txt'), findsOneWidget);
  });

  testWidgets('dropping a file into the chat attaches its original path', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final imageFile = File('${Directory.current.path}/assets/flutter_logo.png');
    final messageStore = _MemoryMessageStore();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const codec = StandardMethodCodec();

    await tester.pumpWidget(
      _testApp(messageStore: messageStore, replyService: _FakeReplyService()),
    );
    await tester.pumpAndSettle();

    await messenger.handlePlatformMessage(
      'desktop_drop',
      codec.encodeMethodCall(const MethodCall('entered', [640.0, 300.0])),
      (_) {},
    );
    await messenger.handlePlatformMessage(
      'desktop_drop',
      codec.encodeMethodCall(MethodCall('performOperation', [imageFile.path])),
      (_) {},
    );
    await tester.pumpAndSettle();

    expect(find.text('flutter_logo.png'), findsOneWidget);
    final attachedImage = tester.widget<Image>(find.byType(Image).last);
    expect((attachedImage.image as FileImage).file.path, imageFile.path);
    expect(find.byKey(const ValueKey('room-file-drop-target')), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('chat-composer'))).height,
      lessThan(260),
    );
  });

  testWidgets('missing sent media shows warning and compact composer fits', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(580, 420);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final messageStore = _MemoryMessageStore()
      ..messages.add(
        const ChatMessage(
          id: 'old-user',
          role: 'user',
          content: 'Old image',
          timestamp: 'Sabtu, 7 November 2026, 00:56',
          createdAtUtc: 1,
        ),
      )
      ..attachments['old-user'] = const [
        ChatAttachment(
          id: 'missing-image',
          path: '/missing/sara-image.png',
          name: 'sara-image.png',
          mimeType: 'image/png',
        ),
      ];

    await tester.pumpWidget(
      _testApp(messageStore: messageStore, replyService: _FakeReplyService()),
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(LucideIcons300.triangleAlert), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-composer')), findsOneWidget);
    expect(find.byKey(const ValueKey('room-file-drop-target')), findsOneWidget);
    final composer = tester.getRect(
      find.byKey(const ValueKey('chat-composer')),
    );
    final settings = tester.getRect(find.byTooltip('Settings'));
    expect(composer.bottom, lessThanOrEqualTo(420));
    expect(composer.contains(settings.center), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'expired attachment keeps its warning without deleting user file',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final directory = await tester.runAsync(
        () => Directory.systemTemp.createTemp('sara-expired-'),
      );
      final file = File('${directory!.path}/user-image.png');
      await tester.runAsync(() => file.writeAsBytes([1, 2, 3]));
      addTearDown(() => directory.delete(recursive: true));
      final message = ChatMessage(
        id: 'expired-upload',
        role: 'user',
        content: 'Old image',
        timestamp: 'Sabtu, 7 November 2026, 00:56',
        createdAtUtc: 1,
      );
      final store = _MemoryMessageStore()
        ..messages.add(message)
        ..attachments[message.id] = [
          ChatAttachment(
            id: 'expired-image',
            path: file.path,
            name: 'user-image.png',
            mimeType: 'image/png',
            expiresAtUtc: DateTime.now()
                .toUtc()
                .subtract(const Duration(seconds: 1))
                .millisecondsSinceEpoch,
          ),
        ];

      await tester.pumpWidget(
        _testApp(messageStore: store, replyService: _FakeReplyService()),
      );
      await tester.pumpAndSettle();

      expect(store.attachments[message.id]!.single.path, isNull);
      expect(file.existsSync(), isTrue);
      expect(find.text('user-image.png'), findsOneWidget);
      expect(find.byIcon(LucideIcons300.triangleAlert), findsOneWidget);
    },
  );

  testWidgets('sent attachment updates to missing warning while app is open', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final directory = await tester.runAsync(
      () => Directory.systemTemp.createTemp('sara-watch-'),
    );
    final file = File('${directory!.path}/photo.bin');
    await tester.runAsync(() => file.writeAsBytes([1, 2, 3]));
    addTearDown(() => directory.delete(recursive: true));

    final messageStore = _MemoryMessageStore()
      ..messages.add(
        const ChatMessage(
          id: 'existing-user',
          role: 'user',
          content: 'Previously attached file',
          timestamp: 'Sabtu, 7 November 2026, 00:56',
          createdAtUtc: 1,
        ),
      )
      ..attachments['existing-user'] = [
        ChatAttachment(
          id: 'watched-file',
          path: file.path,
          name: 'photo.bin',
          mimeType: 'application/octet-stream',
        ),
      ];

    await tester.pumpWidget(
      _testApp(messageStore: messageStore, replyService: _FakeReplyService()),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Previously attached file'), findsOneWidget);
    expect(find.byIcon(LucideIcons300.triangleAlert), findsNothing);

    await tester.runAsync(() async {
      file.deleteSync();
      await Future<void>.delayed(const Duration(seconds: 1));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byIcon(LucideIcons300.triangleAlert), findsOneWidget);
  });

  testWidgets('restores bottom scroll on launch, scroll-up, and send', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final messageStore = _MemoryMessageStore()
      ..messages.addAll(
        List.generate(
          18,
          (index) => ChatMessage(
            id: 'history-$index',
            role: index.isEven ? 'user' : 'model',
            content:
                'History message $index ${'A longer conversation line. ' * 14}',
            timestamp: 'Sabtu, 7 November 2026, 00:56',
            createdAtUtc: index,
          ),
        ),
      );
    await tester.pumpWidget(
      _testApp(messageStore: messageStore, replyService: _FakeReplyService()),
    );
    await tester.pumpAndSettle();

    final initialList = tester.widget<ListView>(find.byType(ListView).first);
    expect(initialList.controller!.position.extentAfter, lessThanOrEqualTo(1));
    expect(find.byKey(const ValueKey('scroll-to-bottom-button')), findsNothing);
    await tester.drag(find.byType(ListView).first, const Offset(0, 360));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('scroll-to-bottom-button')),
      findsOneWidget,
    );
    final scrollButton = find.byKey(const ValueKey('scroll-to-bottom-button'));
    expect(find.byType(Scrollbar), findsOneWidget);
    expect(tester.getSize(scrollButton), const Size(32, 32));
    final scrollButtonRect = tester.getRect(scrollButton);
    final composerRect = tester.getRect(
      find.byKey(const ValueKey('chat-composer')),
    );
    expect(
      (scrollButtonRect.right - composerRect.right).abs(),
      lessThanOrEqualTo(2),
    );
    expect(scrollButtonRect.bottom, lessThan(composerRect.top));
    expect(composerRect.top - scrollButtonRect.bottom, lessThanOrEqualTo(12));
    expect(find.byKey(const ValueKey('scroll-to-bottom-icon')), findsOneWidget);
    expect(
      tester
          .widget<CustomPaint>(
            find.byKey(const ValueKey('scroll-to-bottom-icon')),
          )
          .painter,
      isA<CustomPainter>(),
    );
    expect(
      tester
          .widget<CustomPaint>(
            find.byKey(const ValueKey('scroll-to-bottom-icon')),
          )
          .size,
      const Size(17, 17),
    );

    await tester.tap(scrollButton);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('scroll-to-bottom-button')), findsNothing);

    await tester.drag(find.byType(ListView).first, const Offset(0, 360));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('scroll-to-bottom-button')),
      findsOneWidget,
    );
    await tester.enterText(find.byType(TextField), 'new message');
    await tester.pump();
    await tester.tap(find.byIcon(LucideIcons300.arrowUp));
    await tester.pumpAndSettle();
    expect(find.text('Hai juga!'), findsOneWidget);
    final listView = tester.widget<ListView>(find.byType(ListView).first);
    final position = listView.controller!.position;
    expect(position.extentAfter, lessThanOrEqualTo(1));
    expect(find.byKey(const ValueKey('scroll-to-bottom-button')), findsNothing);
  });

  testWidgets('conversation scroll responds across main body beside messages', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final messageStore = _MemoryMessageStore()
      ..messages.addAll(
        List.generate(
          18,
          (index) => ChatMessage(
            id: 'wide-scroll-$index',
            role: index.isEven ? 'user' : 'model',
            content: 'Wide scroll message $index ${'Conversation line. ' * 14}',
            timestamp: 'today',
            createdAtUtc: index,
          ),
        ),
      );
    await tester.pumpWidget(
      _testApp(messageStore: messageStore, replyService: _FakeReplyService()),
    );
    await tester.pumpAndSettle();

    final listView = tester.widget<ListView>(find.byType(ListView).first);
    final listRect = tester.getRect(find.byType(ListView).first);
    final composerRect = tester.getRect(
      find.byKey(const ValueKey('chat-composer')),
    );
    expect(listRect.left, 0);
    expect(listRect.right, 1280);
    expect(listRect.bottom, lessThanOrEqualTo(composerRect.top));
    final initialExtentBefore = listView.controller!.position.extentBefore;
    expect(listView.controller!.position.extentAfter, 0);

    await tester.dragFrom(
      Offset(90, listRect.bottom - 20),
      const Offset(0, 240),
    );
    await tester.pumpAndSettle();

    expect(
      listView.controller!.position.extentBefore,
      lessThan(initialExtentBefore),
    );

    final extentAfterSideScroll = listView.controller!.position.extentAfter;
    await tester.dragFrom(
      Offset(composerRect.left + 100, composerRect.top + 2),
      const Offset(0, -180),
    );
    await tester.pumpAndSettle();
    expect(listView.controller!.position.extentAfter, extentAfterSideScroll);
  });

  testWidgets(
    'assistant copy action copies the response and shows confirmation',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      String? copiedText;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              copiedText = (call.arguments as Map)['text'] as String?;
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );

      final configStore = _MemoryAiConfigStore()
        ..apiKeys = ['test-key']
        ..values['ai_model'] = 'gemini-3.5-flash-lite';
      await tester.pumpWidget(
        _testApp(
          configStore: configStore,
          messageStore: _MemoryMessageStore(),
          replyService: _FakeReplyService(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'hello');
      await tester.pump();
      await tester.tap(find.byIcon(LucideIcons300.arrowUp));
      await tester.pumpAndSettle();

      expect(find.byType(MarkdownBody), findsNWidgets(2));
      await tester.tap(find.byTooltip('Copy').last);
      await tester.pump();
      expect(copiedText, 'Hai juga!');
      expect(find.byTooltip('Copied'), findsOneWidget);
      expect(find.byIcon(LucideIcons300.check), findsOneWidget);
      expect(find.byTooltip('Speech'), findsOneWidget);
      expect(find.byTooltip('Regenerate'), findsOneWidget);

      await tester.pump(const Duration(seconds: 2));
      expect(find.byTooltip('Copy').last, findsOneWidget);
    },
  );

  testWidgets('speech button starts and stops playback for an AI reply', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final speechController = _FakeSpeechPlaybackController();
    await tester.pumpWidget(
      _testApp(
        configStore: _MemoryAiConfigStore()..apiKeys = ['test-key'],
        messageStore: _MemoryMessageStore(),
        replyService: _FakeReplyService(),
        speechPlaybackController: speechController,
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Read this aloud.');
    await tester.pump();
    await tester.tap(find.byIcon(LucideIcons300.arrowUp));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Speech'));
    await tester.pump();
    expect(speechController.lastText, 'Hai juga!');
    expect(speechController.lastVoice, 'id-ID');
    expect(find.byTooltip('Stop speech'), findsOneWidget);
    expect(find.byIcon(LucideIcons300.volume2), findsOneWidget);

    await tester.tap(find.byTooltip('Stop speech'));
    await tester.pump();
    expect(speechController.speakingMessageId.value, isNull);
    expect(find.byTooltip('Speech'), findsOneWidget);
    expect(find.byIcon(LucideIcons300.volume2), findsOneWidget);
  });

  testWidgets('Markdown code blocks are wide, scrollable, and copy fully', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    String? copiedText;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copiedText = (call.arguments as Map)['text'] as String?;
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );

    final code = [
      ...List.generate(14, (index) => 'print("line $index");'),
      'final longValue = "${'x' * 180}";',
    ].join('\n');
    final message = '```dart\n$code\n```';
    await tester.pumpWidget(
      _testApp(
        messageStore: _MemoryMessageStore(),
        replyService: _FakeReplyService(reply: message),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'show code');
    await tester.pump();
    await tester.tap(find.byIcon(LucideIcons300.arrowUp));
    await tester.pumpAndSettle();

    final codeBlock = find.byKey(const ValueKey('markdown-code-block'));
    expect(codeBlock, findsOneWidget);
    expect(tester.getSize(codeBlock).width, greaterThan(600));
    expect(tester.getSize(codeBlock).height, lessThanOrEqualTo(220));
    final codeScrollDirections = tester
        .widgetList<SingleChildScrollView>(
          find.descendant(
            of: codeBlock,
            matching: find.byType(SingleChildScrollView),
          ),
        )
        .map((scrollView) => scrollView.scrollDirection)
        .toSet();
    expect(codeScrollDirections, containsAll([Axis.horizontal, Axis.vertical]));
    final highlightedCode = tester.widget<HighlightView>(
      find.descendant(of: codeBlock, matching: find.byType(HighlightView)),
    );
    expect(highlightedCode.language, 'dart');
    expect(highlightedCode.theme['keyword']?.color, isNotNull);
    expect(highlightedCode.theme['string']?.color, isNotNull);
    expect(highlightedCode.theme['root']?.backgroundColor, Colors.transparent);
    final scrollables = find.descendant(
      of: codeBlock,
      matching: find.byType(Scrollable),
    );
    expect(scrollables, findsNWidgets(2));
    final verticalScroll = tester.state<ScrollableState>(scrollables.first);
    await tester.drag(scrollables.first, const Offset(0, -80));
    await tester.pumpAndSettle();
    expect(verticalScroll.position.pixels, greaterThan(0));
    final horizontalScroll = tester.state<ScrollableState>(scrollables.last);
    await tester.drag(scrollables.last, const Offset(-160, 0));
    await tester.pumpAndSettle();
    expect(horizontalScroll.position.pixels, greaterThan(0));
    final markdownBody = tester.widget<MarkdownBody>(
      find.ancestor(of: codeBlock, matching: find.byType(MarkdownBody)).first,
    );
    final codeblockDecoration = markdownBody.styleSheet?.codeblockDecoration;
    expect(codeblockDecoration, isA<BoxDecoration>());
    expect((codeblockDecoration! as BoxDecoration).border, isNull);
    expect((codeblockDecoration as BoxDecoration).color, isNull);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(codeBlock));
    await mouse.moveTo(tester.getCenter(codeBlock));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('copy-code-button')));
    await tester.pump();
    expect(copiedText, code);
  });

  testWidgets('user message bubble renders Markdown', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const markdown = '**Bold** and _italic_\n\n- item one';
    final messageStore = _MemoryMessageStore()
      ..messages.add(
        const ChatMessage(
          id: 'markdown-user',
          role: 'user',
          content: markdown,
          timestamp: 'Sabtu, 7 November 2026, 00:56',
          createdAtUtc: 1,
        ),
      );
    await tester.pumpWidget(
      _testApp(messageStore: messageStore, replyService: _FakeReplyService()),
    );
    await tester.pumpAndSettle();

    final bubble = tester.widget<AnimatedContainer>(
      find.byKey(const ValueKey('user-message-bubble')),
    );
    expect(bubble.child, isA<MarkdownBody>());
    expect((bubble.child! as MarkdownBody).data, markdown);
    final decoration = bubble.decoration! as BoxDecoration;
    expect(decoration.color, const Color(0xFF252A34));
    expect(decoration.border, isNotNull);
    expect(
      tester.getSize(find.byKey(const ValueKey('user-message-bubble'))).width,
      lessThanOrEqualTo(640),
    );
  });

  testWidgets('user message hover actions copy and delete following history', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    String? copiedText;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copiedText = (call.arguments as Map)['text'] as String?;
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );

    ChatMessage userMessage(
      String id,
      String content,
      int timestamp, {
      String? parentMessageId,
    }) => ChatMessage(
      id: id,
      role: 'user',
      content: content,
      timestamp: 'Sabtu, 7 November 2026, 00:56',
      createdAtUtc: timestamp,
      parentMessageId: parentMessageId,
    );
    ChatMessage modelMessage(
      String id,
      String content,
      int timestamp, {
      String? parentMessageId,
    }) => ChatMessage(
      id: id,
      role: 'model',
      content: content,
      timestamp: 'Sabtu, 7 November 2026, 00:56',
      createdAtUtc: timestamp,
      parentMessageId: parentMessageId,
    );

    final messageStore = _MemoryMessageStore()
      ..messages.addAll([
        userMessage('before', 'Keep this', 1),
        userMessage('target', 'Delete from here', 2, parentMessageId: 'before'),
        modelMessage(
          'reply-after',
          'Remove this reply',
          3,
          parentMessageId: 'target',
        ),
        userMessage(
          'user-after',
          'Remove this too',
          4,
          parentMessageId: 'reply-after',
        ),
      ])
      ..attachments['target'] = const [
        ChatAttachment(
          id: 'target-attachment',
          path: '/tmp/target.png',
          name: 'target.png',
          mimeType: 'image/png',
        ),
      ];

    await tester.pumpWidget(
      _testApp(messageStore: messageStore, replyService: _FakeReplyService()),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('user-message-actions')), findsNothing);
    final bubble = find.byKey(const ValueKey('user-message-bubble')).at(1);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(bubble));
    await mouse.moveTo(tester.getCenter(bubble));
    await tester.pumpAndSettle();

    expect(find.byTooltip('Delete'), findsOneWidget);
    expect(find.byTooltip('Copy'), findsNWidgets(2));
    expect(find.byTooltip('Edit'), findsOneWidget);
    expect(find.byIcon(LucideIcons300.trash2), findsOneWidget);
    expect(find.byIcon(LucideIcons300.pencil), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('delete-target')))
          .color,
      const Color(0xFFFF8585),
    );
    for (final key in ['copy-user-target', 'edit-target']) {
      expect(
        tester.widget<IconButton>(find.byKey(ValueKey(key))).color,
        const Color(0xFF9AA3B2),
      );
    }
    final actions = tester.widget<Container>(
      find.byKey(const ValueKey('user-message-actions')),
    );
    expect(actions.decoration, isNull);
    await tester.tap(find.byKey(const ValueKey('copy-user-target')));
    await tester.pump();
    expect(copiedText, 'Delete from here');
    expect(find.text('Message copied'), findsOneWidget);
    expect(find.byKey(const ValueKey('toast-message')), findsOneWidget);
    final toastText = tester.widget<Text>(find.text('Message copied'));
    expect(toastText.style?.decoration, TextDecoration.none);

    await mouse.moveTo(const Offset(20, 20));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('user-message-actions')), findsNothing);
    await mouse.moveTo(tester.getCenter(bubble));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('delete-target')));
    await tester.pumpAndSettle();
    expect(find.text('Delete messages?'), findsOneWidget);
    expect(find.byType(CupertinoAlertDialog), findsOneWidget);
    expect(messageStore.messages, hasLength(4));
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(messageStore.messages, hasLength(4));
    await mouse.moveTo(tester.getCenter(bubble));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('delete-target')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete').last);
    await tester.pumpAndSettle();
    expect(messageStore.messages.map((message) => message.id), ['before']);
    expect(messageStore.attachments, isEmpty);
    expect(find.text('Keep this'), findsOneWidget);
    expect(find.text('Delete from here'), findsNothing);
    expect(find.text('Remove this reply'), findsNothing);
    expect(find.text('Remove this too'), findsNothing);
    await mouse.removePointer();
  });

  testWidgets('AI messages do not have a more or delete action', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final messageStore = _MemoryMessageStore()
      ..messages.addAll([
        const ChatMessage(
          id: 'user-before-ai-response',
          role: 'user',
          content: 'A question',
          timestamp: '2026-11-07 22:00:00',
          createdAtUtc: 1793973600000,
        ),
        const ChatMessage(
          id: 'ai-response',
          role: 'model',
          content: 'An answer',
          timestamp: '2026-11-07 22:00:01',
          createdAtUtc: 1793973601000,
          parentMessageId: 'user-before-ai-response',
        ),
      ]);

    await tester.pumpWidget(
      _testApp(messageStore: messageStore, replyService: _FakeReplyService()),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('more-options-ai-response')),
      findsNothing,
    );
    expect(find.byTooltip('Delete'), findsNothing);
    expect(messageStore.messages, hasLength(2));
  });

  testWidgets('user action spacing stays constant for long message bubbles', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final messageStore = _MemoryMessageStore()
      ..messages.addAll([
        const ChatMessage(
          id: 'short-user',
          role: 'user',
          content: 'Short message',
          timestamp: 'Sabtu, 7 November 2026, 00:56',
          createdAtUtc: 1,
        ),
        ChatMessage(
          id: 'long-user',
          role: 'user',
          content: 'A long message. ' * 90,
          timestamp: 'Sabtu, 7 November 2026, 00:56',
          createdAtUtc: 2,
        ),
      ]);

    await tester.pumpWidget(
      _testApp(messageStore: messageStore, replyService: _FakeReplyService()),
    );
    await tester.pumpAndSettle();

    final shortBubble = find.byKey(const ValueKey('user-message-bubble')).at(0);
    final longBubble = find.byKey(const ValueKey('user-message-bubble')).at(1);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(shortBubble));
    await mouse.moveTo(tester.getCenter(shortBubble));
    await tester.pumpAndSettle();
    final shortBubbleRect = tester.getRect(shortBubble);
    final shortActionsRect = tester.getRect(
      find.byKey(const ValueKey('user-message-actions')),
    );
    final shortGap = shortActionsRect.top - shortBubbleRect.bottom;

    await mouse.moveTo(tester.getCenter(longBubble));
    await tester.pumpAndSettle();
    final longBubbleRect = tester.getRect(longBubble);
    final longActionsRect = tester.getRect(
      find.byKey(const ValueKey('user-message-actions')),
    );
    final longGap = longActionsRect.top - longBubbleRect.bottom;

    expect(longBubbleRect.height, greaterThan(shortBubbleRect.height * 2));
    expect((longGap - shortGap).abs(), lessThanOrEqualTo(1));
    await mouse.removePointer();
  });

  testWidgets('composer has a localized dark blur and borderless input', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _testApp(
        messageStore: _MemoryMessageStore(),
        replyService: _FakeReplyService(),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      Theme.of(tester.element(find.byType(Scaffold))).scaffoldBackgroundColor,
      const Color(0xFF18191C),
    );
    expect(
      find.byKey(const ValueKey('footer-bottom-background')),
      findsOneWidget,
    );
    expect(find.byType(BackdropFilter), findsNothing);
    final footerRect = tester.getRect(
      find.byKey(const ValueKey('footer-backdrop')),
    );
    final composerRect = tester.getRect(
      find.byKey(const ValueKey('chat-composer')),
    );
    expect(footerRect.width, lessThan(1280));
    expect(footerRect.width, closeTo(composerRect.width, 1));
    expect(footerRect.top, closeTo(composerRect.top, 1));
    expect(find.byKey(const ValueKey('submit-message-button')), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('submit-message-button'))),
      const Size(40, 40),
    );
    expect(find.byIcon(LucideIcons300.arrowUp), findsOneWidget);
    final emptyButton = tester.widget<FilledButton>(
      find.byKey(const ValueKey('submit-message-button')),
    );
    expect(
      emptyButton.style!.backgroundColor!.resolve({}),
      const Color(0xFF3A4B6A),
    );
    final composer = tester.widget<Container>(
      find.byKey(const ValueKey('chat-composer')),
    );
    expect(
      (composer.decoration! as BoxDecoration).color,
      const Color(0xFF2A2B2F),
    );
    final inputDecoration = tester
        .widget<TextField>(find.byType(TextField))
        .decoration!;
    expect(inputDecoration.border, InputBorder.none);
    expect(inputDecoration.focusedBorder, InputBorder.none);
    expect(inputDecoration.enabledBorder, InputBorder.none);
    final attachmentButton = tester.widget<IconButton>(
      find.byKey(const ValueKey('composer-attachment-button')),
    );
    expect((attachmentButton.icon as Icon).size, 26);
    expect(
      tester.getSize(find.byKey(const ValueKey('composer-mode-button'))).height,
      40,
    );
    expect(
      attachmentButton.style!.shape!.resolve({}),
      isA<CircleBorder>().having(
        (shape) => shape.side,
        'side',
        BorderSide.none,
      ),
    );
    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pump();
    expect(find.byKey(const ValueKey('submit-message-button')), findsOneWidget);
    expect(find.byIcon(LucideIcons300.arrowUp), findsOneWidget);
    final readyButton = tester.widget<FilledButton>(
      find.byKey(const ValueKey('submit-message-button')),
    );
    expect(
      readyButton.style!.backgroundColor!.resolve({}),
      const Color(0xFF3D70D8),
    );
    expect(readyButton.style!.elevation!.resolve({}), 0);
    expect(readyButton.style!.side!.resolve({})?.width, 0.25);
    expect(
      tester
          .widget<Icon>(find.byKey(const ValueKey('submit-message-icon')))
          .size,
      27,
    );
  });

  testWidgets('AI reply is revealed progressively while streaming', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const reply = 'A reply that should appear gradually.';
    final replyGate = Completer<String>();
    final messageStore = _MemoryMessageStore()
      ..messages.addAll(
        List.generate(
          18,
          (index) => ChatMessage(
            id: 'stream-scroll-$index',
            role: index.isEven ? 'user' : 'model',
            content: 'Previous message $index ${'Conversation text. ' * 12}',
            timestamp: 'today',
            createdAtUtc: index,
          ),
        ),
      );
    await tester.pumpWidget(
      _testApp(
        messageStore: messageStore,
        replyService: _FakeReplyService(
          reply: reply,
          replyGate: replyGate.future,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('submit-message-button')));
    await tester.pump(const Duration(milliseconds: 100));

    final visibleReply = tester
        .widgetList<MarkdownBody>(find.byType(MarkdownBody))
        .last
        .data;
    expect(visibleReply, isNotEmpty);
    expect(visibleReply.length, lessThan(reply.length));

    final scrollPosition = tester
        .widget<ListView>(find.byType(ListView).first)
        .controller!
        .position;
    await tester.pump(const Duration(milliseconds: 350));
    expect(scrollPosition.extentAfter, lessThanOrEqualTo(1));

    await tester.drag(find.byType(ListView).first, const Offset(0, 180));
    await tester.pumpAndSettle();
    expect(scrollPosition.extentAfter, greaterThan(80));
    final manuallyScrolledOffset = scrollPosition.pixels;
    await tester.pump(const Duration(milliseconds: 300));
    expect(scrollPosition.pixels, closeTo(manuallyScrolledOffset, 1));

    replyGate.complete(reply);
    await tester.pumpAndSettle();
    expect(
      tester.widgetList<MarkdownBody>(find.byType(MarkdownBody)).last.data,
      reply,
    );
  });

  testWidgets(
    'regenerate saves a sibling AI response without replacing the old one',
    (tester) async {
      final messageStore = _MemoryMessageStore()
        ..messages.addAll([
          const ChatMessage(
            id: 'regenerate-user',
            role: 'user',
            content: 'Say hello',
            timestamp: 'today',
            createdAtUtc: 1,
          ),
          const ChatMessage(
            id: 'regenerate-original',
            role: 'model',
            content: 'Original reply',
            timestamp: 'today',
            createdAtUtc: 2,
            parentMessageId: 'regenerate-user',
          ),
        ]);
      final replyGate = Completer<String>();
      final replyService = _FakeReplyService(
        reply: 'Alternative reply',
        replyGate: replyGate.future,
      );
      await tester.pumpWidget(
        _testApp(messageStore: messageStore, replyService: replyService),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey('regenerate-regenerate-original')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(replyService.calls, 1);
      expect(
        replyService.lastPreviousBranchReplies.map(
          (message) => message.content,
        ),
        ['Original reply'],
      );
      expect(find.text('Say hello'), findsOneWidget);
      expect(find.text('Original reply'), findsNothing);
      final streamedReply = tester
          .widgetList<MarkdownBody>(find.byType(MarkdownBody))
          .last
          .data;
      expect(streamedReply, isNotEmpty);
      expect(streamedReply.length, lessThan('Alternative reply'.length));
      replyGate.complete('Alternative reply');
      await tester.pumpAndSettle();

      expect(
        messageStore.messages.map((message) => message.id),
        containsAll(['regenerate-original']),
      );
      expect(messageStore.messages, hasLength(3));
      expect(find.text('Original reply'), findsOneWidget);
      expect(find.text('Alternative reply'), findsOneWidget);
      expect(messageStore.messages.last.parentMessageId, 'regenerate-user');
    },
  );

  testWidgets(
    'editing a user message with Vent active creates a silent branch',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      ChatMessage user(
        String id,
        String content,
        int timestamp, {
        String? parentMessageId,
      }) => ChatMessage(
        id: id,
        role: 'user',
        content: content,
        timestamp: 'today',
        createdAtUtc: timestamp,
        parentMessageId: parentMessageId,
      );
      ChatMessage model(
        String id,
        String content,
        int timestamp, {
        String? parentMessageId,
      }) => ChatMessage(
        id: id,
        role: 'model',
        content: content,
        timestamp: 'today',
        createdAtUtc: timestamp,
        parentMessageId: parentMessageId,
      );
      final messageStore = _BranchMemoryMessageStore()
        ..messages.addAll([
          user('earlier-user', 'Earlier question', 1),
          model(
            'earlier-reply',
            'Earlier answer',
            2,
            parentMessageId: 'earlier-user',
          ),
          user(
            'original-user',
            'Original question',
            3,
            parentMessageId: 'earlier-reply',
          ),
          model(
            'original-reply',
            'Old answer',
            4,
            parentMessageId: 'original-user',
          ),
        ]);
      final replyService = _FakeReplyService(reply: 'Fresh answer');
      await tester.pumpWidget(
        _testApp(messageStore: messageStore, replyService: replyService),
      );
      await tester.pumpAndSettle();

      final originalBubble = find
          .byKey(const ValueKey('user-message-bubble'))
          .at(1);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: tester.getCenter(originalBubble));
      await mouse.moveTo(tester.getCenter(originalBubble));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('edit-original-user')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('edit-input-original-user')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('cancel-edit-original-user')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('send-edit-original-user')),
        findsOneWidget,
      );

      await tester.enterText(
        find.byKey(const ValueKey('edit-input-original-user')),
        'Edited question',
      );
      final editModeButton = find.byKey(
        const ValueKey('edit-mode-original-user'),
      );
      final inactiveModeContainer = tester.widget<Container>(
        find
            .descendant(of: editModeButton, matching: find.byType(Container))
            .last,
      );
      final inactiveBorder =
          (inactiveModeContainer.decoration! as BoxDecoration).border!
              as Border;
      await tester.tap(
        find.descendant(of: editModeButton, matching: find.text('Vent')),
      );
      await tester.pump();
      expect(find.text('Unwind'), findsNothing);
      expect(
        find.descendant(
          of: editModeButton,
          matching: find.byIcon(LucideIcons300.volumeX),
        ),
        findsOneWidget,
      );
      final activeModeContainer = tester.widget<Container>(
        find
            .descendant(of: editModeButton, matching: find.byType(Container))
            .last,
      );
      final activeBorder =
          (activeModeContainer.decoration! as BoxDecoration).border! as Border;
      expect(activeBorder.top.color, isNot(inactiveBorder.top.color));
      expect(
        find.descendant(of: editModeButton, matching: find.text('Vent')),
        findsOneWidget,
      );
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();

      expect(replyService.calls, 0);
      expect(find.text('Original question'), findsNothing);
      expect(find.text('Edited question'), findsOneWidget);
      expect(find.text('Old answer'), findsNothing);
      expect(find.text('Fresh answer'), findsNothing);
      final storedMessages = await messageStore.loadMessages();
      expect(
        storedMessages.map((message) => message.id),
        containsAll(['original-user', 'original-reply']),
      );
      final editedMessage = storedMessages.singleWhere(
        (message) => message.content == 'Edited question',
      );
      expect(editedMessage.parentMessageId, 'earlier-reply');

      final editedBubble = find
          .byKey(const ValueKey('user-message-bubble'))
          .last;
      await mouse.moveTo(tester.getCenter(editedBubble));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(ValueKey('branch-user-position-${editedMessage.id}')),
          matching: find.text('2/2'),
        ),
        findsOneWidget,
      );
      expect(
        tester.getSize(
          find.byKey(ValueKey('branch-user-position-${editedMessage.id}')),
        ),
        const Size(28, 30),
      );
      await tester.tap(
        find.byKey(ValueKey('branch-user-previous-${editedMessage.id}')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Original question'), findsOneWidget);
      expect(find.text('Old answer'), findsOneWidget);
      expect(find.text('Edited question'), findsNothing);
      expect(find.text('Fresh answer'), findsNothing);
    },
  );

  testWidgets('branch navigation uses aligned left and right arrow buttons', (
    tester,
  ) async {
    final messageStore = _MemoryMessageStore()
      ..messages.addAll([
        const ChatMessage(
          id: 'branch-user',
          role: 'user',
          content: 'Question',
          timestamp: 'today',
          createdAtUtc: 1,
        ),
        const ChatMessage(
          id: 'branch-reply-1',
          role: 'model',
          content: 'First',
          timestamp: 'today',
          createdAtUtc: 2,
          parentMessageId: 'branch-user',
        ),
        const ChatMessage(
          id: 'branch-reply-2',
          role: 'model',
          content: 'Second',
          timestamp: 'today',
          createdAtUtc: 3,
          parentMessageId: 'branch-user',
        ),
      ])
      ..branches = {
        'branch-reply-1': const MessageBranchNavigation(
          parentMessageId: 'branch-user',
          alternatives: ['branch-reply-1', 'branch-reply-2'],
          activeIndex: 1,
        ),
        'branch-reply-2': const MessageBranchNavigation(
          parentMessageId: 'branch-user',
          alternatives: ['branch-reply-1', 'branch-reply-2'],
          activeIndex: 1,
        ),
      };

    await tester.pumpWidget(
      _testApp(messageStore: messageStore, replyService: _FakeReplyService()),
    );
    await tester.pumpAndSettle();

    final leftFinder = find.byKey(
      const ValueKey('branch-previous-branch-reply-2'),
    );
    final rightFinder = find.byKey(
      const ValueKey('branch-next-branch-reply-2'),
    );
    expect(
      find.descendant(
        of: leftFinder,
        matching: find.byKey(const ValueKey('branch-arrow-left')),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: rightFinder,
        matching: find.byKey(const ValueKey('branch-arrow-right')),
      ),
      findsOneWidget,
    );
    expect(tester.getSize(leftFinder), const Size(30, 30));
    expect(tester.getSize(rightFinder), const Size(30, 30));
    expect(
      tester.getSize(
        find.byKey(const ValueKey('branch-position-branch-reply-2')),
      ),
      const Size(28, 30),
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('branch-position-branch-reply-2')),
        matching: find.text('2/2'),
      ),
      findsOneWidget,
    );
    final branchCount = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const ValueKey('branch-position-branch-reply-2')),
        matching: find.text('2/2'),
      ),
    );
    expect(branchCount.style?.fontSize, 14);
  });

  testWidgets('AI response feedback can be switched and removed', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final messageStore = _MemoryMessageStore()
      ..messages.addAll([
        const ChatMessage(
          id: 'feedback-user',
          role: 'user',
          content: 'A question',
          timestamp: '2026-11-07 22:00:00',
          createdAtUtc: 1793973600000,
        ),
        const ChatMessage(
          id: 'feedback-response',
          role: 'model',
          content: 'A short answer.',
          timestamp: '2026-11-07 22:00:01',
          createdAtUtc: 1793973601000,
        ),
      ]);
    await tester.pumpWidget(
      _testApp(messageStore: messageStore, replyService: _FakeReplyService()),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('like-feedback-response')));
    await tester.pumpAndSettle();
    expect(messageStore.feedback['feedback-response'], ('feedback-user', 1));
    expect(find.byTooltip('Liked'), findsOneWidget);
    final likedIcon = tester.widget<Icon>(
      find.descendant(
        of: find.byKey(const ValueKey('like-feedback-response')),
        matching: find.byType(Icon),
      ),
    );
    expect(likedIcon.icon, LucideIcons300.thumbsUp);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('like-feedback-response')),
        matching: find.byKey(const ValueKey('feedback-fill-up')),
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('dislike-feedback-response')));
    await tester.pumpAndSettle();
    expect(messageStore.feedback['feedback-response'], ('feedback-user', -1));
    expect(find.byTooltip('Disliked'), findsOneWidget);
    final dislikedIcon = tester.widget<Icon>(
      find.descendant(
        of: find.byKey(const ValueKey('dislike-feedback-response')),
        matching: find.byType(Icon),
      ),
    );
    expect(dislikedIcon.icon, LucideIcons300.thumbsDown);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('dislike-feedback-response')),
        matching: find.byKey(const ValueKey('feedback-fill-down')),
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('dislike-feedback-response')));
    await tester.pumpAndSettle();
    expect(messageStore.feedback, isEmpty);
    expect(find.byTooltip('Dislike'), findsOneWidget);
  });

  testWidgets('AI reactions can be added, changed, and removed', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final messageStore = _MemoryMessageStore()
      ..messages.addAll([
        const ChatMessage(
          id: 'reaction-user',
          role: 'user',
          content: 'A question',
          timestamp: '2026-11-07 22:00:00',
          createdAtUtc: 1793973600000,
        ),
        const ChatMessage(
          id: 'reaction-response',
          role: 'model',
          content: 'A short answer.',
          timestamp: '2026-11-07 22:00:01',
          createdAtUtc: 1793973601000,
        ),
      ]);
    await tester.pumpWidget(
      _testApp(messageStore: messageStore, replyService: _FakeReplyService()),
    );
    await tester.pumpAndSettle();

    final reactionButton = find.byKey(
      const ValueKey('assistant-reaction-button'),
    );
    expect(find.byTooltip('Reaction'), findsOneWidget);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(reactionButton));
    await mouse.moveTo(const Offset(20, 20));
    await tester.pump();
    await mouse.moveTo(tester.getCenter(reactionButton));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('assistant-reaction-capsule')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('quick-reaction-❤️')));
    await tester.pumpAndSettle();
    expect(messageStore.reactions['reaction-response'], (
      'reaction-user',
      '❤️',
    ));
    expect((tester.widget<IconButton>(reactionButton).icon as Text).data, '❤️');

    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('assistant-reaction-capsule')),
      findsNothing,
    );
    expect(messageStore.reactions['reaction-response']?.$2, '❤️');

    await mouse.moveTo(const Offset(20, 20));
    await tester.pump();
    await mouse.moveTo(tester.getCenter(reactionButton));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('more-reactions-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('emoji-picker-panel')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('emoji-picker-panel')),
        matching: find.byType(TextButton),
      ),
      findsNothing,
    );
    await tester.enterText(
      find.byKey(const ValueKey('emoji-picker-search')),
      'thinking',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('emoji-picker-item-🤔')));
    await tester.pumpAndSettle();
    expect(messageStore.reactions['reaction-response'], (
      'reaction-user',
      '🤔',
    ));
    expect(find.byKey(const ValueKey('emoji-picker-panel')), findsNothing);

    await tester.tap(reactionButton);
    await tester.pumpAndSettle();
    expect(messageStore.reactions, isEmpty);
    expect(tester.widget<IconButton>(reactionButton).icon, isA<Icon>());
    await mouse.removePointer();
  });

  testWidgets('opening settings does not stop an in-flight AI reply', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const reply = 'The reply continues while settings are open.';
    final replyGate = Completer<String>();
    final messageStore = _MemoryMessageStore();
    final notificationArguments = <List<String>>[];
    final notificationService = DesktopNotificationService(
      isLinux: true,
      runner: (executable, arguments) async {
        notificationArguments.add(arguments);
        return ProcessResult(1, 0, '', '');
      },
    );
    await tester.pumpWidget(
      _testApp(
        configStore: _MemoryAiConfigStore(),
        messageStore: messageStore,
        replyService: _FakeReplyService(
          reply: reply,
          replyGate: replyGate.future,
        ),
        notificationService: notificationService,
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('submit-message-button')));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.byTooltip('Settings').first);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Close settings'), findsOneWidget);

    replyGate.complete(reply);
    await tester.pumpAndSettle();

    expect(messageStore.messages.map((message) => message.role), [
      'user',
      'model',
    ]);
    expect(find.text(reply), findsOneWidget);
    expect(find.byTooltip('Close settings'), findsOneWidget);
    expect(notificationArguments, hasLength(1));
    expect(notificationArguments.single.last, reply);
  });

  testWidgets('reply indicator disappears when streamed text appears', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final replyGate = Completer<String>();
    final replyService = _FakeReplyService(
      reply: 'A streamed answer.',
      replyGate: replyGate.future,
    );
    await tester.pumpWidget(
      _testApp(messageStore: _MemoryMessageStore(), replyService: replyService),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('submit-message-button')));
    await tester.pump();
    expect(find.text('Thinking...'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('submit-message-spinner')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('submit-message-icon')), findsNothing);

    await tester.pump(const Duration(milliseconds: 70));
    final visibleMessages = tester.widgetList<MarkdownBody>(
      find.byType(MarkdownBody),
    );
    expect(visibleMessages.length, 2);
    expect(visibleMessages.last.data, isNotEmpty);
    expect(find.text('Thinking...'), findsNothing);
    expect(find.byKey(const ValueKey('submit-message-spinner')), findsNothing);
    expect(find.byKey(const ValueKey('submit-message-icon')), findsOneWidget);

    replyGate.complete('A streamed answer.');
    await tester.pumpAndSettle();
    expect(
      tester.widgetList<MarkdownBody>(find.byType(MarkdownBody)).last.data,
      'A streamed answer.',
    );
  });

  testWidgets('Vent blocks replies only while active', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final messageStore = _MemoryMessageStore();
    final replyService = _FakeReplyService();
    await tester.pumpWidget(
      _testApp(messageStore: messageStore, replyService: replyService),
    );
    await tester.pumpAndSettle();

    final ventButton = find.byKey(const ValueKey('composer-mode-button'));
    expect(find.text('Vent'), findsOneWidget);
    expect(find.text('Unwind'), findsNothing);
    expect(find.byIcon(LucideIcons300.volumeX), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'What do you think?');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('submit-message-button')));
    await tester.pumpAndSettle();
    expect(replyService.calls, 1);
    expect(messageStore.messages.map((message) => message.role), [
      'user',
      'model',
    ]);

    await tester.tap(find.text('Vent'));
    await tester.pump();
    expect(find.text('Vent'), findsOneWidget);
    expect(find.text('Unwind'), findsNothing);
    expect(find.byIcon(LucideIcons300.volumeX), findsOneWidget);
    final activeModeContainer = tester.widget<Container>(
      find.descendant(of: ventButton, matching: find.byType(Container)).last,
    );
    final activeBorder =
        (activeModeContainer.decoration! as BoxDecoration).border! as Border;

    await tester.enterText(find.byType(TextField), 'I just need to vent.');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('submit-message-button')));
    await tester.pumpAndSettle();
    expect(replyService.calls, 1);
    expect(messageStore.messages.map((message) => message.role), [
      'user',
      'model',
      'user',
    ]);
    expect(find.text('I just need to vent.'), findsOneWidget);

    await tester.tap(find.text('Vent'));
    await tester.pump();
    final inactiveModeContainer = tester.widget<Container>(
      find.descendant(of: ventButton, matching: find.byType(Container)).last,
    );
    final inactiveBorder =
        (inactiveModeContainer.decoration! as BoxDecoration).border! as Border;
    expect(activeBorder.top.color, isNot(inactiveBorder.top.color));
  });

  testWidgets('failed user save retries without requesting an AI reply', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final messageStore = _MemoryMessageStore()..failNextAppend = true;
    final replyService = _FakeReplyService(reply: '');
    await tester.pumpWidget(
      _testApp(messageStore: messageStore, replyService: replyService),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'No need to respond.');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('submit-message-button')));
    await tester.pumpAndSettle();

    expect(replyService.calls, 0);
    expect(messageStore.messages, isEmpty);
    expect(find.text('No need to respond.'), findsOneWidget);
    expect(find.text('Hai juga!'), findsNothing);
    expect(find.byTooltip('Retry message'), findsOneWidget);

    await tester.tap(find.byTooltip('Retry message'));
    await tester.pumpAndSettle();
    expect(replyService.calls, 0);
    expect(messageStore.messages.map((message) => message.role), ['user']);
    expect(find.byTooltip('Retry message'), findsNothing);
  });

  testWidgets('AI can send an uploaded image as a media-only reply', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final imageFile = File('${Directory.current.path}/assets/flutter_logo.png');
    final priorMessage = ChatMessage(
      id: 'prior-upload',
      role: 'user',
      content: 'Uploaded image earlier',
      timestamp: 'Sabtu, 7 November 2026, 00:56',
      createdAtUtc: DateTime.now().toUtc().millisecondsSinceEpoch,
    );
    final priorAttachment = ChatAttachment(
      id: 'prior-image',
      path: imageFile.path,
      name: 'flutter_logo.png',
      mimeType: 'image/png',
      expiresAtUtc: DateTime.now()
          .toUtc()
          .add(const Duration(hours: 1))
          .millisecondsSinceEpoch,
    );
    final messageStore = _MemoryMessageStore()
      ..messages.add(priorMessage)
      ..attachments[priorMessage.id] = [priorAttachment];
    final replyService = _FakeReplyService(
      reply: '',
      responseAttachments: [priorAttachment],
    );

    await tester.pumpWidget(
      _testApp(messageStore: messageStore, replyService: replyService),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Send me that image.');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('submit-message-button')));
    await tester.pumpAndSettle();

    final modelMessage = messageStore.messages.singleWhere(
      (message) => message.role == 'model',
    );
    expect(modelMessage.content, isEmpty);
    expect(
      messageStore.attachments[modelMessage.id]!.single.id,
      priorAttachment.id,
    );
    expect(find.byKey(const ValueKey('model-attachment-grid')), findsOneWidget);
    expect(find.byType(Image), findsWidgets);
    final modelGrid = find.byKey(const ValueKey('model-attachment-grid'));
    final modelMediaTile = tester.getSize(
      find.descendant(
        of: modelGrid,
        matching: find.byKey(
          const ValueKey('attachment-preview-tile-prior-image'),
        ),
      ),
    );
    expect(modelMediaTile.width, greaterThan(180));
    expect(modelMediaTile.height, greaterThan(180));
    expect(modelMediaTile.width, lessThanOrEqualTo(320));
    expect(modelMediaTile.height, lessThanOrEqualTo(300));
  });

  testWidgets('clear chat removes messages but keeps the personal name', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final messageStore = _MemoryMessageStore()
      ..personalName = 'Rani'
      ..messages.add(
        const ChatMessage(
          id: 'existing',
          role: 'user',
          content: 'Keep no messages',
          timestamp: '2026-11-06 22:00:00',
          createdAtUtc: 1793973600000,
        ),
      );
    await tester.pumpWidget(
      _testApp(
        configStore: _MemoryAiConfigStore(),
        messageStore: messageStore,
        replyService: _FakeReplyService(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Data').first);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('import-backup-button')), findsOneWidget);
    expect(find.byKey(const ValueKey('export-backup-button')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('import-backup-button')),
        matching: find.byIcon(LucideIcons300.upload),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('export-backup-button')),
        matching: find.byIcon(LucideIcons300.download),
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('clear-chat-button')));
    await tester.pumpAndSettle();
    expect(find.text('Clear chat?'), findsOneWidget);
    expect(messageStore.messages, hasLength(1));
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(messageStore.messages, hasLength(1));

    await tester.tap(find.byKey(const ValueKey('clear-chat-button')));
    await tester.pumpAndSettle();
    expect(find.text('Clear chat?'), findsOneWidget);
    await tester.tap(find.text('Clear chat').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Close settings'));
    await tester.pumpAndSettle();

    expect(messageStore.messages, isEmpty);
    expect(messageStore.personalName, 'Rani');
    expect(find.text('What would you like to talk about?'), findsOneWidget);
  });

  testWidgets('composer and message editor share smart delimiter formatting', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final messageStore = _MemoryMessageStore()
      ..messages.add(
        const ChatMessage(
          id: 'editable-user',
          role: 'user',
          content: 'Original',
          timestamp: 'today',
          createdAtUtc: 1,
        ),
      );
    await tester.pumpWidget(
      _testApp(messageStore: messageStore, replyService: _FakeReplyService()),
    );
    await tester.pumpAndSettle();

    final composerInput = find.descendant(
      of: find.byKey(const ValueKey('chat-composer')),
      matching: find.byType(TextField),
    );
    expect(
      tester.widget<TextField>(composerInput).inputFormatters,
      contains(isA<SmartTextInputFormatter>()),
    );
    final userBubble = find.byKey(const ValueKey('user-message-bubble'));
    await tester.ensureVisible(userBubble);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.moveTo(tester.getCenter(userBubble));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('edit-editable-user')));
    await tester.pumpAndSettle();
    await mouse.removePointer();

    final editInput = find.byKey(const ValueKey('edit-input-editable-user'));
    expect(
      tester.widget<TextField>(editInput).inputFormatters,
      contains(isA<SmartTextInputFormatter>()),
    );
  });

  testWidgets(
    'message editor uses Shift+Enter for newlines and Enter to save',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final messageStore = _MemoryMessageStore()
        ..messages.add(
          const ChatMessage(
            id: 'keyboard-edit-user',
            role: 'user',
            content: 'Original',
            timestamp: 'today',
            createdAtUtc: 1,
          ),
        );
      await tester.pumpWidget(
        _testApp(messageStore: messageStore, replyService: _FakeReplyService()),
      );
      await tester.pumpAndSettle();

      final userBubble = find.byKey(const ValueKey('user-message-bubble'));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.moveTo(tester.getCenter(userBubble));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('edit-keyboard-edit-user')));
      await tester.pumpAndSettle();
      await mouse.removePointer();

      final editInput = find.byKey(
        const ValueKey('edit-input-keyboard-edit-user'),
      );
      await tester.enterText(editInput, 'First line');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();

      expect(
        tester.widget<TextField>(editInput).controller!.text,
        'First line\n',
      );
      expect(messageStore.messages.single.content, 'Original');

      await tester.enterText(editInput, 'First line\nSecond line');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(
        messageStore.messages.map((message) => message.content),
        contains('First line\nSecond line'),
      );
      expect(
        find.byKey(const ValueKey('edit-input-keyboard-edit-user')),
        findsNothing,
      );
    },
  );

  testWidgets('removes the stored user message when the AI request fails', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final configStore = _MemoryAiConfigStore()..apiKeys = ['test-key'];
    final messageStore = _MemoryMessageStore();
    final replyService = _FakeReplyService(error: StateError('test failure'));
    await tester.pumpWidget(
      _testApp(
        configStore: configStore,
        messageStore: messageStore,
        replyService: replyService,
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'temporary prompt');
    await tester.pump();
    await tester.tap(find.byIcon(LucideIcons300.arrowUp));
    await tester.pumpAndSettle();

    expect(messageStore.messages, isEmpty);
    expect(find.text('temporary prompt'), findsOneWidget);
    expect(find.byTooltip('Retry message'), findsOneWidget);
    expect(find.textContaining('Request failed'), findsWidgets);
    final retryButton = find.ancestor(
      of: find.byTooltip('Retry message'),
      matching: find.byType(IconButton),
    );
    final retryRect = tester.getRect(retryButton);
    final bubbleRect = tester.getRect(
      find.byKey(const ValueKey('user-message-bubble')),
    );
    expect(retryRect.right, lessThan(bubbleRect.left));
    expect(bubbleRect.left - retryRect.right, closeTo(4, 1));
    final retryWidget = tester.widget<IconButton>(retryButton);
    expect(retryWidget.constraints!.maxWidth, 26);
    expect(retryWidget.style?.backgroundColor?.resolve({}), isNull);

    replyService.error = null;
    await tester.tap(find.byTooltip('Retry message'));
    await tester.pumpAndSettle();
    expect(messageStore.messages.map((message) => message.role), [
      'user',
      'model',
    ]);
    expect(replyService.calls, 2);
    expect(find.byTooltip('Retry message'), findsNothing);
  });

  testWidgets('request error shows desktop notification when app is inactive', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final notificationArguments = <List<String>>[];
    String? copiedError;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copiedError = (call.arguments as Map)['text'] as String?;
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );
    final notificationService = DesktopNotificationService(
      isLinux: true,
      runner: (executable, arguments) async {
        notificationArguments.add(arguments);
        return ProcessResult(1, 0, '', '');
      },
    );
    await tester.pumpWidget(
      _testApp(
        configStore: _MemoryAiConfigStore()..apiKeys = ['test-key'],
        messageStore: _MemoryMessageStore(),
        replyService: _FakeReplyService(error: StateError('test failure')),
        notificationService: notificationService,
      ),
    );
    await tester.pumpAndSettle();
    addTearDown(
      () => tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      ),
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.enterText(find.byType(TextField), 'trigger an error');
    await tester.tap(find.byIcon(LucideIcons300.arrowUp));
    await tester.pumpAndSettle();

    expect(notificationArguments, hasLength(1));
    expect(notificationArguments.single.last, contains('AI request failed'));
    expect(notificationArguments.single.last, contains('test failure'));
    expect(find.byTooltip('Copy error details'), findsOneWidget);
    await tester.tap(find.byTooltip('Copy error details'));
    await tester.pump();
    expect(copiedError, contains('AI request failed'));
    expect(copiedError, contains('test failure'));
  });

  testWidgets('retries saving a completed reply without another AI request', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final messageStore = _MemoryMessageStore()..failNextExchangeSave = true;
    final replyService = _FakeReplyService();
    await tester.pumpWidget(
      _testApp(
        configStore: _MemoryAiConfigStore()..apiKeys = ['test-key'],
        messageStore: messageStore,
        replyService: replyService,
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'save me');
    await tester.pump();
    await tester.tap(find.byIcon(LucideIcons300.arrowUp));
    await tester.pumpAndSettle();

    expect(replyService.calls, 1);
    expect(messageStore.messages.map((message) => message.role), ['user']);
    expect(find.text('Hai juga!'), findsOneWidget);
    expect(find.byTooltip('Retry message'), findsOneWidget);
    expect(find.textContaining('test database failure'), findsOneWidget);

    await tester.tap(find.byTooltip('Retry message'));
    await tester.pumpAndSettle();
    expect(replyService.calls, 1);
    expect(messageStore.messages.map((message) => message.role), [
      'user',
      'model',
    ]);
    expect(find.byTooltip('Retry message'), findsNothing);
  });

  testWidgets('retrying failed Vent persistence does not request AI', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final messageStore = _MemoryMessageStore()..failNextAppend = true;
    final replyService = _FakeReplyService();
    await tester.pumpWidget(
      _testApp(
        configStore: _MemoryAiConfigStore()..apiKeys = ['test-key'],
        messageStore: messageStore,
        replyService: replyService,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Vent'));
    await tester.pump();
    await tester.enterText(
      find.byType(TextField),
      'Keep this without a reply.',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('submit-message-button')));
    await tester.pumpAndSettle();

    expect(replyService.calls, 0);
    expect(messageStore.messages, isEmpty);
    expect(find.byTooltip('Retry message'), findsOneWidget);
    await tester.tap(find.byTooltip('Retry message'));
    await tester.pumpAndSettle();

    expect(replyService.calls, 0);
    expect(messageStore.messages.map((message) => message.role), ['user']);
    expect(find.byTooltip('Retry message'), findsNothing);
  });

  testWidgets('Linux title bar shows Sara branding and controls', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const channel = MethodChannel('personal.sara/window');
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          return call.method == 'toggleMaximize' ? true : null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    await tester.pumpWidget(
      _testApp(
        messageStore: _MemoryMessageStore(),
        replyService: _FakeReplyService(),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('linux-window-title-bar')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('linux-window-app-icon')), findsOneWidget);
    expect(find.text('Sara'), findsOneWidget);
    expect(find.text('Personal AI Chat'), findsOneWidget);
    final titleBar = find.byKey(const ValueKey('linux-window-title-bar'));
    expect(tester.getSize(titleBar).height, 36);
    expect(
      tester
          .widget<CustomPaint>(
            find.byKey(const ValueKey('window-control-icon-minimize')),
          )
          .size,
      const Size.square(14),
    );
    expect(
      tester
          .widget<Text>(
            find.descendant(of: titleBar, matching: find.text('Sara')),
          )
          .style!
          .fontSize,
      15,
    );
    await tester.tap(find.byKey(const ValueKey('linux-window-minimize')));
    await tester.tap(find.byKey(const ValueKey('linux-window-maximize')));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('window-control-icon-restore')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: titleBar, matching: find.byType(Tooltip)),
      findsNothing,
    );
    await tester.drag(find.text('Personal AI Chat'), const Offset(25, 0));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byKey(const ValueKey('linux-window-close')));
    await tester.pump();

    expect(calls, ['minimize', 'toggleMaximize', 'startDragging', 'close']);
  });

  testWidgets('emoji picker inserts a searched emoji at the text cursor', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _testApp(
        messageStore: _MemoryMessageStore(),
        replyService: _FakeReplyService(),
      ),
    );
    await tester.pumpAndSettle();

    final input = find.byType(TextField).first;
    final composerInput = tester.widget<TextField>(input);
    expect(composerInput.style!.fontFamilyFallback, isNull);
    await tester.enterText(input, 'hello');
    final controller = tester.widget<TextField>(input).controller!;
    controller.selection = const TextSelection.collapsed(offset: 2);

    final attachmentButton = tester.getCenter(
      find.byKey(const ValueKey('composer-attachment-button')),
    );
    final emojiButton = find.byKey(const ValueKey('emoji-picker-button'));
    final modeButton = find.byKey(const ValueKey('composer-mode-button'));
    expect(tester.getCenter(emojiButton).dx, greaterThan(attachmentButton.dx));
    expect(
      tester.getCenter(emojiButton).dx,
      lessThan(tester.getCenter(modeButton).dx),
    );
    expect(
      tester.getCenter(emojiButton).dx - attachmentButton.dx,
      closeTo(40, 0.1),
    );
    final emojiButtonWidget = tester.widget<IconButton>(emojiButton);
    expect(emojiButtonWidget.icon, isA<Icon>());
    expect((emojiButtonWidget.icon as Icon).icon, LucideIcons300.smile);
    expect((emojiButtonWidget.icon as Icon).color, Colors.white);
    final emojiButtonShape = emojiButtonWidget.style!.shape!.resolve({});
    expect(emojiButtonShape, isA<CircleBorder>());
    expect((emojiButtonShape as CircleBorder).side, BorderSide.none);

    await tester.tap(emojiButton);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('emoji-picker-panel')), findsOneWidget);
    expect(find.text('Emoji'), findsNothing);
    expect(find.byKey(const ValueKey('emoji-picker-close')), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('emoji-picker-panel')),
        matching: find.byType(TextButton),
      ),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('emoji-picker-grid')), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('emoji-picker-search')),
      'thinking',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('emoji-picker-item-🤔')));
    await tester.pumpAndSettle();
    final thinkingEmojiCell = tester.widget<IconButton>(
      find.byKey(const ValueKey('emoji-picker-item-🤔')),
    );
    expect(thinkingEmojiCell.tooltip, isNull);
    expect(
      (thinkingEmojiCell.icon as Text).style!.fontFamily,
      'Noto Color Emoji',
    );

    expect(controller.text, 'he🤔llo');
    final controllerText = controller.buildTextSpan(
      context: tester.element(input),
      style: composerInput.style,
      withComposing: false,
    );
    final emojiTextSpan = controllerText.children!.cast<TextSpan>().singleWhere(
      (span) => span.text == '🤔',
    );
    final regularTextSpan = controllerText.children!
        .cast<TextSpan>()
        .singleWhere((span) => span.text == 'h');
    expect(emojiTextSpan.style!.fontFamily, 'Noto Color Emoji');
    expect(regularTextSpan.style, isNull);
    expect(find.byKey(const ValueKey('emoji-picker-panel')), findsOneWidget);
    await tester.tapAt(const Offset(20, 200));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('emoji-picker-panel')), findsNothing);
  });

  testWidgets('a single sent emoji is saved and animated, mixed text is not', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final messageStore = _MemoryMessageStore();
    final replyService = _FakeReplyService(reply: '🤔');
    await tester.pumpWidget(
      _testApp(messageStore: messageStore, replyService: replyService),
    );
    await tester.pumpAndSettle();

    final input = find.byType(TextField).first;
    await tester.enterText(input, '🤔');
    await tester.tap(find.byKey(const ValueKey('submit-message-button')));
    await tester.pumpAndSettle();

    final emojiMessage = messageStore.messages.singleWhere(
      (message) => message.role == 'user',
    );
    expect(emojiMessage.content, '🤔');
    expect(
      find.byKey(ValueKey('animated-emoji-${emojiMessage.id}')),
      findsOneWidget,
    );
    final aiEmojiMessage = messageStore.messages.singleWhere(
      (message) => message.role == 'model',
    );
    final aiEmoji = find.byKey(ValueKey('animated-emoji-${aiEmojiMessage.id}'));
    expect(aiEmojiMessage.content, '🤔');
    expect(aiEmoji, findsOneWidget);
    final aiEmojiText = tester.widget<Text>(
      find.descendant(of: aiEmoji, matching: find.byType(Text)),
    );
    expect(aiEmojiText.style?.fontSize, 48);

    await tester.enterText(input, 'I am thinking 🤔');
    await tester.tap(find.byKey(const ValueKey('submit-message-button')));
    await tester.pumpAndSettle();
    final mixedMessage = messageStore.messages.lastWhere(
      (message) => message.role == 'user',
    );
    expect(mixedMessage.content, 'I am thinking 🤔');
    expect(
      find.byKey(ValueKey('animated-emoji-${mixedMessage.id}')),
      findsNothing,
    );
    final mixedMessageText = tester
        .widgetList<SelectableText>(find.byType(SelectableText))
        .singleWhere(
          (text) => text.textSpan?.toPlainText() == mixedMessage.content,
        );
    TextStyle? renderedEmojiStyle;
    void findEmojiStyle(InlineSpan span) {
      if (span is TextSpan) {
        if (span.text == '🤔') renderedEmojiStyle = span.style;
        for (final child in span.children ?? const <InlineSpan>[]) {
          findEmojiStyle(child);
        }
      }
    }

    findEmojiStyle(mixedMessageText.textSpan!);
    expect(renderedEmojiStyle?.fontFamily, 'Noto Color Emoji');
    expect(replyService.calls, 2);
  });

  testWidgets('shows the dark chat theme and one session', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final configStore = _MemoryAiConfigStore()
      ..values['ai_model'] = 'gemini-3.5-flash-lite';
    final messageStore = _MemoryMessageStore();
    final replyService = _FakeReplyService();
    await tester.pumpWidget(
      _testApp(
        configStore: configStore,
        messageStore: messageStore,
        replyService: replyService,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('What would you like to talk about?'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).decoration?.hintText,
      'Where your thoughts find a home...',
    );
    expect(
      Theme.of(tester.element(find.byType(Scaffold))).brightness,
      Brightness.dark,
    );
    expect(find.text('Thinking'), findsNothing);
    expect(find.text('Search'), findsNothing);
    expect(find.text('Vent'), findsOneWidget);
    expect(find.byIcon(LucideIcons300.volumeX), findsOneWidget);
    expect(find.byKey(const ValueKey('sara-app-logo')), findsOneWidget);
    expect(find.text('Percakapan baru'), findsNothing);

    await tester.tap(find.byTooltip('Add attachment'));
    await tester.pumpAndSettle();
    final menuRect = tester.getRect(
      find.byKey(const ValueKey('attachment-menu')),
    );
    expect(menuRect.width, greaterThan(menuRect.height));
    expect(menuRect.width, closeTo(252, 0.1));
    expect(menuRect.height, lessThan(160));
    final menuMaterial = tester.widget<Material>(
      find
          .ancestor(
            of: find.byKey(const ValueKey('attachment-menu')),
            matching: find.byType(Material),
          )
          .first,
    );
    expect(menuMaterial.color, const Color(0xFF202124));
    expect(find.text('Camera'), findsOneWidget);
    expect(find.text('Photo'), findsOneWidget);
    expect(find.text('File'), findsOneWidget);

    tester.binding.handlePointerEvent(
      const PointerScrollEvent(
        position: Offset(640, 300),
        scrollDelta: Offset(0, 30),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('attachment-menu')), findsNothing);

    await tester.tap(find.byTooltip('Add attachment'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(640, 345));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('attachment-menu')), findsNothing);

    await tester.tap(find.text('Vent'));
    await tester.pumpAndSettle();
    expect(find.text('Vent'), findsOneWidget);
    expect(find.text('Unwind'), findsNothing);
    expect(find.byIcon(LucideIcons300.volumeX), findsOneWidget);

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    final settingsButtonRect = tester.getRect(find.byTooltip('Settings'));
    expect(settingsButtonRect.right, greaterThan(1200));
    expect(settingsButtonRect.bottom, greaterThan(740));
    final settingsDialogRect = tester.getRect(find.byType(Dialog));
    expect(settingsDialogRect.width, greaterThan(780));
    expect(settingsDialogRect.height, greaterThan(540));
    expect(find.text('Personal'), findsNWidgets(2));
    expect(find.text('Make Sara feel more like yours.'), findsOneWidget);
    final settingsPanel = tester.getRect(
      find.byKey(const ValueKey('settings-content-panel')),
    );
    final personalSubtitle = tester.getRect(
      find.text('Make Sara feel more like yours.'),
    );
    expect(personalSubtitle.top, greaterThanOrEqualTo(settingsPanel.top + 20));
    expect(personalSubtitle.top, lessThan(settingsPanel.top + 65));
    await tester.tap(find.text('Configure').first);
    await tester.pumpAndSettle();
    expect(find.text('Adjust your AI connection settings.'), findsOneWidget);
    expect(find.text('AI provider'), findsNothing);
    expect(find.text('Enter mengirim pesan'), findsNothing);
    expect(find.text('Enter to send'), findsNothing);
    expect(find.text('Response sounds'), findsNothing);
    expect(find.text('Google Gemini'), findsOneWidget);
    expect(find.text('Gemini API'), findsOneWidget);
    expect(find.text('Gemini API keys'), findsOneWidget);
    final webSearchSwitch = tester.widget<Switch>(
      find.byKey(const ValueKey('web-search-enabled-switch')),
    );
    expect(
      webSearchSwitch.thumbColor?.resolve(const {}),
      const Color(0xFFB4BAC7),
    );
    expect(
      webSearchSwitch.thumbColor?.resolve({WidgetState.selected}),
      const Color(0xFFDCE4F5),
    );
    expect(
      webSearchSwitch.trackColor?.resolve(const {}),
      const Color(0xFF414752),
    );
    expect(
      webSearchSwitch.trackColor?.resolve({WidgetState.selected}),
      const Color(0xFF46536D),
    );
    expect(
      webSearchSwitch.trackOutlineColor?.resolve(const {}),
      const Color(0xFF687080),
    );
    expect(
      webSearchSwitch.trackOutlineColor?.resolve({WidgetState.selected}),
      const Color(0xFF46536D),
    );
    expect(find.text('Provider'), findsOneWidget);
    expect(find.text('Model'), findsOneWidget);
    expect(find.byKey(const ValueKey('ai-model-field')), findsNothing);
    expect(
      find.byKey(const ValueKey('ai-current-model')).evaluate().single.widget,
      isA<Text>(),
    );
    expect(find.text('gemini-3.5-flash-lite'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('ai-api-key-field')),
      'local-test-key',
    );
    final saveButton = find.text('Add API key');
    await tester.drag(
      find.byKey(const ValueKey('configure-settings-scroll-view')),
      const Offset(0, -600),
    );
    await tester.pumpAndSettle();
    await tester.tap(saveButton);
    await tester.pumpAndSettle();
    expect(configStore.values['ai_model'], 'gemini-3.5-flash-lite');
    expect(configStore.apiKeys, ['local-test-key']);
    await tester.enterText(
      find.byKey(const ValueKey('ai-api-key-field')),
      'second-test-key',
    );
    await tester.drag(
      find.byKey(const ValueKey('configure-settings-scroll-view')),
      const Offset(0, -600),
    );
    await tester.pumpAndSettle();
    await tester.tap(saveButton);
    await tester.pumpAndSettle();
    expect(configStore.apiKeys, ['local-test-key', 'second-test-key']);
    await tester.drag(
      find.byKey(const ValueKey('configure-settings-scroll-view')),
      const Offset(0, 600),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Remove API key 1'));
    await tester.pumpAndSettle();
    expect(find.text('Remove API key?'), findsOneWidget);
    expect(find.byType(CupertinoAlertDialog), findsOneWidget);
    expect(configStore.apiKeys, ['local-test-key', 'second-test-key']);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(configStore.apiKeys, ['local-test-key', 'second-test-key']);

    await tester.tap(find.byTooltip('Remove API key 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove key'));
    await tester.pumpAndSettle();
    expect(configStore.apiKeys, ['second-test-key']);

    await tester.tap(find.text('Personal').first);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('personal-name-field')),
      'Rani',
    );
    await tester.ensureVisible(
      find.byKey(const ValueKey('save-personal-name')),
    );
    await tester.tap(find.byKey(const ValueKey('save-personal-name')));
    await tester.pumpAndSettle();
    expect(messageStore.personalName, 'Rani');
    await tester.pump(const Duration(seconds: 5));
    await tester.tap(find.text('Data').first);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('clear-chat-button')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('clear-chat-button')),
        matching: find.byType(CustomPaint),
      ),
      findsNWidgets(2),
    );
    final dataSettingsPanel = tester.getRect(
      find.byKey(const ValueKey('settings-content-panel')),
    );
    final dataContent = tester.getRect(
      find.byKey(const ValueKey('data-settings-content')),
    );
    expect(dataContent.top, greaterThanOrEqualTo(dataSettingsPanel.top));
    expect(dataContent.top, greaterThanOrEqualTo(dataSettingsPanel.top + 10));
    expect(dataContent.top, lessThan(dataSettingsPanel.top + 45));
    await tester.tap(find.byTooltip('Close settings'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Vent'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'Hai Sara');
    await tester.pump();
    await tester.tap(find.byType(TextField));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(find.text('Hai Sara'), findsOneWidget);
    expect(replyService.lastPersonalName, 'Rani');
    expect(messageStore.messages.map((message) => message.role), [
      'user',
      'model',
    ]);
  });
}

SaraApp _testApp({
  AiConfigStore configStore = const SecureAiConfigStore(),
  MessageStore? messageStore,
  AiReplyService? replyService,
  SpeechPlaybackController? speechPlaybackController,
  Future<Uint8List?> Function()? clipboardImageReader,
  Future<ChatAttachment> Function(Uint8List bytes)? clipboardImageSaver,
  CameraSessionFactory? cameraSessionFactory,
  Future<ChatAttachment> Function(Uint8List bytes)? cameraImageSaver,
  Future<void> Function(MessageStore messageStore)? cameraCacheCleaner,
  DesktopNotificationService? notificationService,
  Future<void> Function(String assetPath)? notificationSoundPlayer,
}) {
  return SaraApp(
    configStore: configStore,
    messageStore: messageStore,
    replyService: replyService,
    speechPlaybackController: speechPlaybackController,
    clipboardImageReader: clipboardImageReader,
    clipboardImageSaver: clipboardImageSaver,
    cameraSessionFactory: cameraSessionFactory,
    cameraImageSaver: cameraImageSaver,
    cameraCacheCleaner: cameraCacheCleaner ?? (_) async {},
    notificationService:
        notificationService ?? const DesktopNotificationService(isLinux: false),
    notificationSoundPlayer: notificationSoundPlayer ?? (_) async {},
  );
}

class _FakeSpeechPlaybackController implements SpeechPlaybackController {
  @override
  final ValueNotifier<String?> speakingMessageId = ValueNotifier(null);

  @override
  final ValueNotifier<String?> loadingMessageId = ValueNotifier(null);

  String? lastText;
  String? lastVoice;

  @override
  Future<void> toggle({
    required String messageId,
    required String text,
    required String voice,
  }) async {
    if (speakingMessageId.value == messageId) {
      speakingMessageId.value = null;
      return;
    }
    lastText = text;
    lastVoice = voice;
    speakingMessageId.value = messageId;
  }

  @override
  void dispose() {
    speakingMessageId.dispose();
    loadingMessageId.dispose();
  }
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

class _MemoryMessageStore implements MessageStore {
  final messages = <ChatMessage>[];
  Map<String, MessageBranchNavigation> branches = {};
  final attachments = <String, List<ChatAttachment>>{};
  final feedback = <String, (String userMessageId, int rating)>{};
  final reactions = <String, (String userMessageId, String reaction)>{};
  final topicSummaries = <String, ConversationTopicSummary>{};
  final messageEmbeddings = <(String, String), MessageEmbeddingRecord>{};
  final topicEmbeddings =
      <(String, String), ConversationTopicEmbeddingRecord>{};
  final userMemories = <String, UserMemoryRecord>{};
  final memoryJobs = <String, ConversationMemoryJob>{};
  String? personalName;
  bool failNextAppend = false;
  bool failNextExchangeSave = false;

  @override
  Future<List<ChatMessage>> loadMessages() async => [...messages];

  @override
  Future<List<ChatMessage>> loadActiveMessages() async => [...messages];

  @override
  Future<Map<String, MessageBranchNavigation>> loadMessageBranches() async => {
    ...branches,
  };

  @override
  Future<List<String>> loadSubtreeMessageIds(String messageId) async {
    final deleted = <String>{messageId};
    var changed = true;
    while (changed) {
      changed = false;
      for (final message in messages) {
        if (message.parentMessageId != null &&
            deleted.contains(message.parentMessageId) &&
            deleted.add(message.id)) {
          changed = true;
        }
      }
    }
    return deleted.toList();
  }

  @override
  Future<List<ChatMessage>> activateMessageBranch(String messageId) async => [
    ...messages,
  ];

  @override
  Future<Map<String, List<ChatAttachment>>> loadAttachments() async =>
      attachments.map((id, items) => MapEntry(id, [...items]));

  @override
  Future<void> saveTerminalCommandActivities(
    String messageId,
    List<TerminalCommandHistoryEntry> activities,
  ) async {
    final index = messages.indexWhere((message) => message.id == messageId);
    if (index < 0) throw StateError('Message is missing.');
    messages[index] = messages[index].withTerminalActivities(activities);
  }

  @override
  Future<void> moveTerminalCommandActivities(
    String fromMessageId,
    String toMessageId,
  ) async {
    final sourceIndex = messages.indexWhere(
      (message) => message.id == fromMessageId,
    );
    final targetIndex = messages.indexWhere(
      (message) => message.id == toMessageId,
    );
    if (sourceIndex < 0 || targetIndex < 0) {
      throw StateError('Message is missing.');
    }
    final source = messages[sourceIndex];
    final target = messages[targetIndex];
    final merged = [...target.terminalActivities];
    final signatures = merged
        .map(
          (activity) =>
              (activity.command, activity.taskContext, activity.createdAtUtc),
        )
        .toSet();
    for (final activity in source.terminalActivities) {
      final signature = (
        activity.command,
        activity.taskContext,
        activity.createdAtUtc,
      );
      if (signatures.add(signature)) merged.add(activity);
    }
    messages[targetIndex] = target.withTerminalActivities(merged);
    messages[sourceIndex] = source.withTerminalActivities(const []);
  }

  @override
  Future<Map<String, int>> loadAssistantFeedback() async => {
    for (final entry in feedback.entries) entry.key: entry.value.$2,
  };

  @override
  Future<Map<String, String>> loadAssistantReactions() async => {
    for (final entry in reactions.entries) entry.key: entry.value.$2,
  };

  @override
  Future<void> saveAssistantFeedback(
    String userMessageId,
    String responseMessageId,
    int? rating,
  ) async {
    if (rating == null) {
      feedback.remove(responseMessageId);
    } else {
      feedback[responseMessageId] = (userMessageId, rating);
    }
  }

  @override
  Future<void> saveAssistantReaction(
    String userMessageId,
    String responseMessageId,
    String? reaction,
  ) async {
    if (reaction == null) {
      reactions.remove(responseMessageId);
    } else {
      reactions[responseMessageId] = (userMessageId, reaction);
    }
  }

  @override
  Future<List<ChatAttachment>> loadExpiredAttachments(int nowUtc) async =>
      attachments.values
          .expand((items) => items)
          .where(
            (attachment) =>
                attachment.path != null &&
                attachment.expiresAtUtc != null &&
                attachment.expiresAtUtc! <= nowUtc,
          )
          .toList();

  @override
  Future<void> expireAttachments(int nowUtc) async {
    for (final entry in attachments.entries) {
      attachments[entry.key] = entry.value
          .map(
            (attachment) =>
                attachment.expiresAtUtc != null &&
                    attachment.expiresAtUtc! <= nowUtc
                ? ChatAttachment(
                    id: attachment.id,
                    path: null,
                    name: attachment.name,
                    mimeType: attachment.mimeType,
                    expiresAtUtc: attachment.expiresAtUtc,
                    isClipboardCopy: attachment.isClipboardCopy,
                  )
                : attachment,
          )
          .toList();
    }
  }

  @override
  Future<void> clearAttachmentPaths(List<String> paths) async {
    final pathSet = paths.toSet();
    for (final entry in attachments.entries) {
      attachments[entry.key] = entry.value
          .map(
            (attachment) => pathSet.contains(attachment.path)
                ? ChatAttachment(
                    id: attachment.id,
                    path: null,
                    name: attachment.name,
                    mimeType: attachment.mimeType,
                    expiresAtUtc: attachment.expiresAtUtc,
                    isClipboardCopy: attachment.isClipboardCopy,
                  )
                : attachment,
          )
          .toList();
    }
  }

  @override
  Future<void> saveMessage(ChatMessage message) async {
    messages.add(message);
  }

  @override
  Future<void> appendMessage(ChatMessage message) async {
    if (failNextAppend) {
      failNextAppend = false;
      throw StateError('test database failure');
    }
    messages.add(message);
  }

  @override
  Future<bool> appendMessageIfActiveLeaf(
    ChatMessage message, {
    required String? expectedLeafId,
  }) async {
    final history = await loadActiveMessages();
    final activeLeafId = history.isEmpty ? null : history.last.id;
    if (activeLeafId != expectedLeafId ||
        message.parentMessageId != expectedLeafId) {
      return false;
    }
    await appendMessage(message);
    return true;
  }

  @override
  Future<void> saveMessageAttachments(
    String messageId,
    List<ChatAttachment> value,
  ) async {
    attachments[messageId] = [...value];
  }

  @override
  Future<void> saveExchange(List<ChatMessage> exchange) async {
    if (failNextExchangeSave) {
      failNextExchangeSave = false;
      throw StateError('test database failure');
    }
    for (final message in exchange) {
      messages.removeWhere((stored) => stored.id == message.id);
      messages.add(message);
    }
  }

  @override
  Future<void> saveExchangeWithAttachments(
    List<ChatMessage> exchange,
    String userMessageId,
    List<ChatAttachment> value, {
    Map<String, List<ChatAttachment>> additionalAttachments =
        const <String, List<ChatAttachment>>{},
  }) async {
    await saveExchange(exchange);
    attachments[userMessageId] = [...value];
    for (final entry in additionalAttachments.entries) {
      attachments[entry.key] = [...entry.value];
    }
  }

  @override
  Future<List<ConversationTopicSummary>>
  loadConversationTopicSummaries() async =>
      topicSummaries.values.toList(growable: false);

  @override
  Future<List<MessageEmbeddingRecord>> loadMessageEmbeddings() async =>
      messageEmbeddings.values.toList(growable: false);

  @override
  Future<List<MessageEmbeddingRecord>> loadMessageEmbeddingsForMessages(
    List<String> messageIds,
  ) async => messageEmbeddings.values
      .where((embedding) => messageIds.contains(embedding.messageId))
      .toList(growable: false);

  @override
  Future<List<ConversationTopicEmbeddingRecord>>
  loadConversationTopicEmbeddings() async =>
      topicEmbeddings.values.toList(growable: false);

  @override
  Future<List<UserMemoryRecord>> loadUserMemories() async =>
      userMemories.values.toList(growable: false);

  @override
  Future<List<ConversationMemoryJob>> loadConversationMemoryJobs() async =>
      memoryJobs.values.toList(growable: false)
        ..sort((left, right) => left.queuedAtUtc.compareTo(right.queuedAtUtc));

  @override
  Future<void> enqueueConversationMemoryJob(ConversationMemoryJob job) async {
    memoryJobs.putIfAbsent(job.id, () => job);
  }

  @override
  Future<void> deleteConversationMemoryJobs(List<String> jobIds) async {
    memoryJobs.removeWhere((id, _) => jobIds.contains(id));
  }

  @override
  Future<void> saveMessageEmbeddings(
    List<MessageEmbeddingRecord> embeddings,
  ) async {
    for (final embedding in embeddings) {
      messageEmbeddings[(embedding.messageId, embedding.model)] = embedding;
    }
  }

  @override
  Future<void> saveConversationTopicEmbeddings(
    List<ConversationTopicEmbeddingRecord> embeddings,
  ) async {
    for (final embedding in embeddings) {
      topicEmbeddings[(embedding.topicId, embedding.model)] = embedding;
    }
  }

  @override
  Future<void> saveConversationMemory({
    required ConversationTopicSummary topic,
    required List<MessageEmbeddingRecord> embeddings,
    List<String> topicSourceMessageIds = const [],
    List<ConversationTopicEmbeddingRecord> topicEmbeddings = const [],
    List<UserMemoryRecord> userMemories = const [],
    List<String> completedJobIds = const [],
    List<String> deletedMemoryIds = const [],
  }) async {
    topicSummaries[topic.id] = topic;
    for (final id in topicSourceMessageIds) {
      for (final entry
          in messageEmbeddings.entries
              .where(
                (entry) => entry.key.$1 == id && entry.value.topicId == null,
              )
              .toList()) {
        final existing = entry.value;
        messageEmbeddings[entry.key] = MessageEmbeddingRecord(
          messageId: existing.messageId,
          topicId: topic.id,
          model: existing.model,
          values: existing.values,
          createdAtUtc: existing.createdAtUtc,
        );
      }
    }
    await saveMessageEmbeddings(embeddings);
    await saveConversationTopicEmbeddings(topicEmbeddings);
    for (final memory in userMemories) {
      this.userMemories[memory.id] = memory;
    }
    this.userMemories.removeWhere((id, _) => deletedMemoryIds.contains(id));
    await deleteConversationMemoryJobs(completedJobIds);
  }

  @override
  Future<void> deleteMessage(String id) async {
    await deleteMessages([id]);
  }

  @override
  Future<void> deleteMessages(List<String> ids) async {
    final deletedIds = ids.toSet();
    messages.removeWhere((message) => deletedIds.contains(message.id));
    messageEmbeddings.removeWhere((key, _) => deletedIds.contains(key.$1));
    for (final id in ids) {
      attachments.remove(id);
    }
    feedback.removeWhere(
      (responseId, value) =>
          deletedIds.contains(responseId) || deletedIds.contains(value.$1),
    );
    reactions.removeWhere(
      (responseId, value) =>
          deletedIds.contains(responseId) || deletedIds.contains(value.$1),
    );
    final deletedTopics = topicSummaries.values
        .where((topic) => deletedIds.contains(topic.throughMessageId))
        .map((topic) => topic.id)
        .toSet();
    topicSummaries.removeWhere((id, _) => deletedTopics.contains(id));
    topicEmbeddings.removeWhere((key, _) => deletedTopics.contains(key.$1));
    memoryJobs.removeWhere(
      (_, job) =>
          deletedIds.contains(job.userMessageId) ||
          deletedIds.contains(job.modelMessageId),
    );
    userMemories.removeWhere(
      (_, memory) => memory.sourceMessageIds.every(deletedIds.contains),
    );
    for (final entry in userMemories.entries.toList()) {
      final memory = entry.value;
      if (memory.sourceMessageIds.any(deletedIds.contains)) {
        userMemories[entry.key] = UserMemoryRecord(
          id: memory.id,
          kind: memory.kind,
          memoryKey: memory.memoryKey,
          content: memory.content,
          confidence: memory.confidence,
          sourceMessageIds: memory.sourceMessageIds
              .where((id) => !deletedIds.contains(id))
              .toList(growable: false),
          createdAtUtc: memory.createdAtUtc,
          updatedAtUtc: memory.updatedAtUtc,
          expiresAtUtc: memory.expiresAtUtc,
          embeddingModel: memory.embeddingModel,
          embedding: memory.embedding,
        );
      }
    }
  }

  @override
  Future<String?> readPersonalName() async => personalName;

  @override
  Future<void> writePersonalName(String name) async {
    personalName = name;
  }

  @override
  Future<void> clearPersonalName() async {
    personalName = null;
  }

  @override
  Future<void> clearMessages() async {
    messages.clear();
    attachments.clear();
    feedback.clear();
    reactions.clear();
    topicSummaries.clear();
    messageEmbeddings.clear();
    topicEmbeddings.clear();
    userMemories.clear();
    memoryJobs.clear();
  }

  @override
  Future<Map<String, Object?>> exportBackupData() async =>
      throw UnsupportedError('Backup is not supported by this test store.');

  @override
  Future<void> importBackupData(
    Map<String, Object?> tables, {
    required Map<String, String> clipboardPaths,
  }) async =>
      throw UnsupportedError('Backup is not supported by this test store.');

  @override
  Future<void> close() async {}
}

class _BranchMemoryMessageStore extends _MemoryMessageStore {
  final Map<String, String> _activeChildren = {};

  @override
  Future<List<ChatMessage>> loadActiveMessages() async {
    if (messages.isEmpty) return const [];
    final ordered = [...messages]
      ..sort((a, b) {
        final timestampOrder = a.createdAtUtc.compareTo(b.createdAtUtc);
        return timestampOrder != 0 ? timestampOrder : a.id.compareTo(b.id);
      });
    final byId = {for (final message in ordered) message.id: message};
    final children = <String, List<ChatMessage>>{};
    for (final message in ordered) {
      final parentId = message.parentMessageId;
      if (parentId != null) {
        children.putIfAbsent(parentId, () => []).add(message);
      }
    }
    final root = ordered.firstWhere(
      (message) => message.parentMessageId == null,
    );
    final activePath = <ChatMessage>[];
    final visited = <String>{};
    var currentId = root.id;
    while (visited.add(currentId)) {
      final current = byId[currentId];
      if (current == null) break;
      activePath.add(current);
      final available = children[currentId] ?? const <ChatMessage>[];
      if (available.isEmpty) break;
      final selected = _activeChildren[currentId];
      currentId = available.any((message) => message.id == selected)
          ? selected!
          : available.last.id;
    }
    return activePath;
  }

  @override
  Future<Map<String, MessageBranchNavigation>> loadMessageBranches() async {
    final ordered = [...messages]
      ..sort((a, b) {
        final timestampOrder = a.createdAtUtc.compareTo(b.createdAtUtc);
        return timestampOrder != 0 ? timestampOrder : a.id.compareTo(b.id);
      });
    final siblings = <String, List<ChatMessage>>{};
    for (final message in ordered) {
      final parentId = message.parentMessageId;
      if (parentId != null) {
        siblings.putIfAbsent(parentId, () => []).add(message);
      }
    }
    final result = <String, MessageBranchNavigation>{};
    for (final entry in siblings.entries) {
      if (entry.value.length < 2) continue;
      final alternatives = entry.value.map((message) => message.id).toList();
      final selected = _activeChildren[entry.key] ?? alternatives.last;
      final selectedIndex = alternatives.indexOf(selected);
      for (final message in entry.value) {
        result[message.id] = MessageBranchNavigation(
          parentMessageId: entry.key,
          alternatives: alternatives,
          activeIndex: selectedIndex < 0 ? 0 : selectedIndex,
        );
      }
    }
    return result;
  }

  @override
  Future<List<ChatMessage>> activateMessageBranch(String messageId) async {
    final message = messages.firstWhere((item) => item.id == messageId);
    final parentId = message.parentMessageId;
    if (parentId == null) {
      throw StateError('The root message has no alternative branch.');
    }
    _activeChildren[parentId] = messageId;
    return loadActiveMessages();
  }

  @override
  Future<void> appendMessage(ChatMessage message) async {
    await super.appendMessage(message);
    final parentId = message.parentMessageId;
    if (parentId != null) _activeChildren[parentId] = message.id;
  }

  @override
  Future<void> saveExchange(List<ChatMessage> exchange) async {
    await super.saveExchange(exchange);
    for (final message in exchange) {
      final parentId = message.parentMessageId;
      if (parentId != null) _activeChildren[parentId] = message.id;
    }
  }

  @override
  Future<void> saveExchangeWithAttachments(
    List<ChatMessage> exchange,
    String userMessageId,
    List<ChatAttachment> value, {
    Map<String, List<ChatAttachment>> additionalAttachments =
        const <String, List<ChatAttachment>>{},
  }) async {
    await saveExchange(exchange);
    attachments[userMessageId] = [...value];
    for (final entry in additionalAttachments.entries) {
      attachments[entry.key] = [...entry.value];
    }
  }
}

class _FakeReplyService implements AiReplyService {
  _FakeReplyService({
    this.error,
    this.reply = 'Hai juga!',
    this.replyGate,
    this.responseAttachments = const [],
  });

  Object? error;
  final String reply;
  final Future<String>? replyGate;
  final List<ChatAttachment> responseAttachments;
  String? lastPersonalName;
  List<ChatMessage> lastHistory = const [];
  List<ChatMessage> lastPreviousBranchReplies = const [];
  int calls = 0;
  int cameraToolAvailableCalls = 0;
  TerminalCommandRequest? terminalCommandRequest;
  TerminalCommandResult? terminalCommandResult;

  @override
  Future<String> generateReply(
    List<ChatMessage> history, {
    String? personalName,
    String? responseMessageId,
    List<ChatMessage> previousBranchReplies = const [],
    Map<String, List<ChatAttachment>> attachmentsByMessage = const {},
    void Function(Object error)? onMemoryError,
    void Function(String text)? onText,
    void Function(List<ChatAttachment> attachments)? onMedia,
    Future<CameraFrame> Function()? captureCameraFrame,
    TerminalCommandApprovalHandler? approveTerminalCommand,
    Future<TerminalCommandResult> Function(TerminalCommandRequest request)?
    executeTerminalCommand,
    TerminalCommandActivityHandler? onTerminalCommandActivity,
    TerminalCommandResultHandler? onTerminalCommandResult,
  }) async {
    calls++;
    if (captureCameraFrame != null) cameraToolAvailableCalls++;
    lastHistory = [...history];
    lastPersonalName = personalName;
    lastPreviousBranchReplies = [...previousBranchReplies];
    if (error != null) throw error!;
    final terminalRequestTemplate = terminalCommandRequest;
    final terminalRequest = terminalRequestTemplate == null
        ? null
        : TerminalCommandRequest(
            command: terminalRequestTemplate.command,
            workingDirectory: terminalRequestTemplate.workingDirectory,
            taskContext: terminalRequestTemplate.taskContext,
            responseMessageId: responseMessageId,
          );
    if (terminalRequest != null &&
        approveTerminalCommand != null &&
        executeTerminalCommand != null) {
      onTerminalCommandActivity?.call(
        terminalRequest,
        running: false,
        automaticallyAllowed: false,
      );
      final decision = await approveTerminalCommand(terminalRequest);
      if (decision != TerminalApprovalDecision.skip) {
        onTerminalCommandActivity?.call(
          terminalRequest,
          running: true,
          automaticallyAllowed: decision == TerminalApprovalDecision.allowAll,
        );
        final configuredResult = terminalCommandResult;
        final result = configuredResult == null
            ? await executeTerminalCommand(terminalRequest)
            : TerminalCommandResult(
                request: terminalRequest,
                exitCode: configuredResult.exitCode,
                stdout: configuredResult.stdout,
                stderr: configuredResult.stderr,
                error: configuredResult.error,
                timedOut: configuredResult.timedOut,
                cancelled: configuredResult.cancelled,
                skipped: configuredResult.skipped,
                outputTruncated: configuredResult.outputTruncated,
              );
        await onTerminalCommandResult?.call(result);
        onTerminalCommandActivity?.call(
          terminalRequest,
          running: false,
          automaticallyAllowed: false,
        );
      }
    }
    onText?.call(reply);
    onMedia?.call(responseAttachments);
    return replyGate ?? Future<String>.value(reply);
  }
}

class _FakeFilePickerPlatform extends FilePickerPlatform {
  _FakeFilePickerPlatform(this.files);

  final List<PlatformFile> files;

  @override
  Future<List<PlatformFile>> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async => files;
}

base class _TestPlatformFile extends PlatformFile {
  _TestPlatformFile(this.name, this.localPath);

  @override
  final String name;

  final String localPath;

  @override
  String? get path => localPath;

  @override
  Uri get uri => Uri.file(localPath);

  @override
  XFile get xFile => throw UnimplementedError();

  @override
  int? lengthSync() => 3;

  @override
  Future<int?> length() async => 3;

  @override
  Future<Uint8List> readAsBytes() async => Uint8List(0);

  @override
  Stream<Uint8List> readAsByteStream() => const Stream.empty();
}
