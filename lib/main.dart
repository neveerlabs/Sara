import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:emoji_picker_flutter/emoji_picker_flutter.dart' as emoji_picker;
import 'package:emoji_picker_flutter/locales/emoji_set_en.dart'
    show emojiSetEnglish;
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart' show PointerScrollEvent;
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:image/image.dart' as img;
import 'package:lucide_icons_flutter/lucide_icons_300.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:super_clipboard/super_clipboard.dart';
import 'package:uuid/uuid.dart';

import 'ai_config_store.dart';
import 'web_search_service.dart';
import 'app_localizations.dart';
import 'attachment_file_policy.dart';
import 'camera_capture.dart';
import 'camera_capture_cache.dart';
import 'chat_attachment.dart';
import 'chat_message.dart';
import 'gemini_reply_service.dart';
import 'desktop_notification_service.dart';
import 'link_preview_service.dart';
import 'message_database.dart';
import 'sara_backup.dart';
import 'smart_text_input_formatter.dart';
import 'sound_of_text_service.dart';
import 'terminal_command.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SaraApp());
}

Future<void> _playNotificationSoundAsset(String assetPath) async {
  MediaKit.ensureInitialized();
  final player = Player();
  try {
    await player.open(Media('asset:///$assetPath'), play: true);
    await player.stream.completed.firstWhere((completed) => completed);
  } finally {
    await player.dispose();
  }
}

Future<Uint8List?> _readClipboardImageFromSystem() async {
  if (!Platform.isLinux) {
    final clipboard = await ClipboardReader.readClipboard();
    const imageFormats = [
      Formats.png,
      Formats.jpeg,
      Formats.webp,
      Formats.gif,
      Formats.tiff,
    ];
    for (final item in clipboard.items) {
      for (final format in imageFormats) {
        if (!item.hasValue(format)) continue;
        final bytes = await item.readValue(format);
        if (bytes != null) return bytes;
      }
    }
    return null;
  }

  final targets = await Process.run('xclip', [
    '-selection',
    'clipboard',
    '-o',
    '-target',
    'TARGETS',
  ], stdoutEncoding: utf8).timeout(const Duration(seconds: 3));
  if (targets.exitCode != 0) {
    throw ProcessException(
      'xclip',
      ['-selection', 'clipboard', '-o', '-target', 'TARGETS'],
      targets.stderr.toString(),
      targets.exitCode,
    );
  }

  const imageTargets = [
    'image/png',
    'image/jpeg',
    'image/webp',
    'image/gif',
    'image/tiff',
  ];
  final availableTargets = (targets.stdout as String)
      .split(RegExp(r'\s+'))
      .toSet();
  for (final target in imageTargets) {
    if (!availableTargets.contains(target)) continue;
    final image = await Process.run('xclip', [
      '-selection',
      'clipboard',
      '-o',
      '-target',
      target,
    ], stdoutEncoding: null).timeout(const Duration(seconds: 5));
    if (image.exitCode != 0) {
      throw ProcessException(
        'xclip',
        ['-selection', 'clipboard', '-o', '-target', target],
        image.stderr.toString(),
        image.exitCode,
      );
    }
    final bytes = image.stdout;
    if (bytes is List<int> && bytes.isNotEmpty) {
      return Uint8List.fromList(bytes);
    }
  }
  return null;
}

const _canvas = Color(0xFF18191C);
const _surface = Color(0xFF202124);
const _surfaceRaised = Color(0xFF2A2B2F);
const _border = Color(0xFF424449);
const _muted = Color(0xFF9AA3B2);
const _text = Color(0xFFE6EAF2);
const _accent = Color(0xFF79A0FF);
const _providerStorageKey = 'ai_provider';
const _modelStorageKey = 'ai_model';
const _defaultModel = 'gemini-3.5-flash-lite';
const _emojiFontFamily = 'Noto Color Emoji';
const _uuid = Uuid();

String? _singleEmoji(String text) {
  final graphemes = text.trim().characters;
  if (graphemes.length != 1) return null;

  final emoji = graphemes.first;
  final codePoints = emoji.runes.toList();
  final hasEmojiBase = codePoints.any((codePoint) {
    if (codePoint >= 0x1F3FB && codePoint <= 0x1F3FF) return false;
    return (codePoint >= 0x1F000 && codePoint <= 0x1FAFF) ||
        (codePoint >= 0x2300 && codePoint <= 0x23FF) ||
        (codePoint >= 0x2600 && codePoint <= 0x27BF) ||
        (codePoint >= 0x2B00 && codePoint <= 0x2BFF) ||
        const {
          0x00A9,
          0x00AE,
          0x203C,
          0x2049,
          0x2122,
          0x2139,
          0x3030,
          0x303D,
          0x3297,
          0x3299,
        }.contains(codePoint);
  });
  return hasEmojiBase || codePoints.contains(0x20E3) ? emoji : null;
}

class _EmojiAwareTextEditingController extends TextEditingController {
  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final currentValue = value;
    final composing = withComposing && currentValue.isComposingRangeValid
        ? currentValue.composing
        : TextRange.empty;
    var offset = 0;
    final spans = <TextSpan>[];
    for (final grapheme in currentValue.text.characters) {
      final end = offset + grapheme.length;
      final isEmoji = _singleEmoji(grapheme) != null;
      final overlapsComposing =
          composing.isValid && composing.start < end && composing.end > offset;
      TextStyle? spanStyle = isEmoji
          ? const TextStyle(fontFamily: _emojiFontFamily)
          : null;
      if (overlapsComposing) {
        spanStyle = (spanStyle ?? const TextStyle()).merge(
          const TextStyle(decoration: TextDecoration.underline),
        );
      }
      spans.add(TextSpan(text: grapheme, style: spanStyle));
      offset = end;
    }
    return TextSpan(style: style, children: spans);
  }
}

class _EmojiMarkdownSyntax extends md.InlineSyntax {
  _EmojiMarkdownSyntax() : super(r'[^\x00-\x7F]+');

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    for (final grapheme in match[0]!.characters) {
      if (_singleEmoji(grapheme) != null) {
        parser.addNode(md.Element.text('saraEmoji', grapheme));
      } else {
        parser.addNode(md.Text(grapheme));
      }
    }
    return true;
  }
}

class _MarkdownEmojiBuilder extends MarkdownElementBuilder {
  @override
  Widget visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    return Text.rich(
      TextSpan(
        text: element.textContent,
        style: (parentStyle ?? preferredStyle ?? const TextStyle()).copyWith(
          fontFamily: _emojiFontFamily,
        ),
      ),
    );
  }
}

KeyEventResult _handleEnterSubmission(
  KeyEvent event,
  TextEditingController controller,
  VoidCallback onSubmit,
) {
  final isEnterKey =
      event.logicalKey == LogicalKeyboardKey.enter ||
      event.logicalKey == LogicalKeyboardKey.numpadEnter;
  if (!isEnterKey) return KeyEventResult.ignored;
  if (event is KeyUpEvent) return KeyEventResult.ignored;
  if (event is KeyRepeatEvent) return KeyEventResult.handled;
  if (event is! KeyDownEvent) return KeyEventResult.ignored;

  if (HardwareKeyboard.instance.isShiftPressed) {
    final value = controller.value;
    final selection = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    final start = selection.start;
    final end = selection.end;
    final text = value.text.replaceRange(start, end, '\n');
    controller.value = value.copyWith(
      text: text,
      selection: TextSelection.collapsed(offset: start + 1),
      composing: TextRange.empty,
    );
  } else {
    onSubmit();
  }
  return KeyEventResult.handled;
}

OverlayEntry? _activeToast;
Timer? _activeToastTimer;
Future<void> Function(String message)? _notifyUnseenError;

Future<void> _copyToastMessage(String message) async {
  try {
    await Clipboard.setData(ClipboardData(text: message));
  } catch (error) {
    debugPrint('Could not copy error details from toast: $error');
  }
}

void _showToast(
  BuildContext context,
  String message, {
  bool isError = false,
  bool notifyDesktop = true,
}) {
  final notifyError = _notifyUnseenError;
  if (isError && notifyDesktop && notifyError != null) {
    unawaited(notifyError(message));
  }
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) {
    debugPrint(
      'Could not display notification because no overlay is available.',
    );
    return;
  }
  _activeToastTimer?.cancel();
  if (_activeToast?.mounted ?? false) _activeToast!.remove();

  final cleanMessage = message.trim().replaceAll(RegExp(r'[.!?]+$'), '');
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (context) => Positioned(
      left: 16,
      right: 16,
      bottom: 24 + MediaQuery.paddingOf(context).bottom,
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.sizeOf(context).width - 32,
          ),
          child: DecoratedBox(
            key: const ValueKey('toast-message'),
            decoration: BoxDecoration(
              color: const Color(0xF02B303A),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: const Color(0x554E5665)),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x33000000),
                  blurRadius: 18,
                  offset: Offset(0, 6),
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      cleanMessage,
                      maxLines: isError ? 2 : 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: _text,
                        inherit: false,
                        fontSize: 12,
                        height: 1.15,
                        fontWeight: FontWeight.w500,
                        decoration: TextDecoration.none,
                        decorationColor: Colors.transparent,
                      ),
                    ),
                  ),
                  if (isError) ...[
                    const SizedBox(width: 8),
                    IconButton(
                      key: const ValueKey('copy-toast-error'),
                      tooltip: appText('Copy error details'),
                      onPressed: () => unawaited(_copyToastMessage(message)),
                      icon: const Icon(LucideIcons300.copy),
                      color: _text,
                      iconSize: 16,
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints.tightFor(
                        width: 30,
                        height: 30,
                      ),
                      padding: EdgeInsets.zero,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
  _activeToast = entry;
  overlay.insert(entry);
  _activeToastTimer = Timer(Duration(milliseconds: isError ? 8000 : 2200), () {
    if (!identical(_activeToast, entry)) return;
    _activeToast = null;
    if (entry.mounted) entry.remove();
  });
}

Future<bool?> _showIosConfirmation({
  required BuildContext context,
  required String title,
  required String message,
  required String cancelLabel,
  required String confirmLabel,
  bool destructive = false,
}) {
  return showCupertinoDialog<bool>(
    context: context,
    barrierDismissible: true,
    builder: (context) => CupertinoTheme(
      data: const CupertinoThemeData(
        brightness: Brightness.dark,
        primaryColor: _accent,
      ),
      child: CupertinoAlertDialog(
        title: Text(title),
        content: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(message),
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(cancelLabel),
          ),
          CupertinoDialogAction(
            isDestructiveAction: destructive,
            isDefaultAction: !destructive,
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    ),
  );
}

class SaraApp extends StatefulWidget {
  const SaraApp({
    super.key,
    this.configStore = const SecureAiConfigStore(),
    this.messageStore,
    this.replyService,
    this.speechPlaybackController,
    this.clipboardImageReader,
    this.clipboardImageSaver,
    this.cameraSessionFactory,
    this.cameraImageSaver,
    this.cameraCacheCleaner,
    this.notificationService,
    this.notificationSoundPlayer,
  });

  final AiConfigStore configStore;
  final MessageStore? messageStore;
  final AiReplyService? replyService;
  final SpeechPlaybackController? speechPlaybackController;
  final Future<Uint8List?> Function()? clipboardImageReader;
  final Future<ChatAttachment> Function(Uint8List bytes)? clipboardImageSaver;
  final CameraSessionFactory? cameraSessionFactory;
  final Future<ChatAttachment> Function(Uint8List bytes)? cameraImageSaver;
  final Future<void> Function(MessageStore messageStore)? cameraCacheCleaner;
  final DesktopNotificationService? notificationService;
  final Future<void> Function(String assetPath)? notificationSoundPlayer;

  @override
  State<SaraApp> createState() => _SaraAppState();
}

class _SaraAppState extends State<SaraApp> {
  @override
  void initState() {
    super.initState();
    unawaited(_loadLanguage());
  }

  Future<void> _loadLanguage() async {
    try {
      await AppLanguageController.load();
    } catch (error) {
      debugPrint('Could not load saved language preference: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AppLanguage>(
      valueListenable: AppLanguageController.language,
      builder: (context, language, _) => MaterialApp(
        title: 'Sara',
        locale: Locale(language == AppLanguage.indonesian ? 'id' : 'en'),
        supportedLocales: const [Locale('en'), Locale('id')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: Brightness.dark,
          scaffoldBackgroundColor: _canvas,
          dialogTheme: const DialogThemeData(
            backgroundColor: _surface,
            surfaceTintColor: Colors.transparent,
          ),
          snackBarTheme: const SnackBarThemeData(
            backgroundColor: _surfaceRaised,
            contentTextStyle: TextStyle(color: _text),
          ),
          inputDecorationTheme: InputDecorationTheme(
            filled: true,
            fillColor: _surfaceRaised,
            hintStyle: const TextStyle(color: _muted),
            enabledBorder: OutlineInputBorder(
              borderSide: BorderSide(color: _border),
              borderRadius: BorderRadius.all(Radius.circular(10)),
            ),
            focusedBorder: OutlineInputBorder(
              borderSide: BorderSide(color: _accent),
              borderRadius: BorderRadius.all(Radius.circular(10)),
            ),
          ),
          colorScheme: const ColorScheme.dark(
            primary: _accent,
            surface: _surface,
            onSurface: _text,
          ),
          fontFamily: 'Roboto',
          useMaterial3: true,
          textSelectionTheme: const TextSelectionThemeData(
            cursorColor: _accent,
            selectionColor: Color(0x6679A0FF),
            selectionHandleColor: _accent,
          ),
        ),
        home: ChatPage(
          configStore: widget.configStore,
          messageStore: widget.messageStore,
          replyService: widget.replyService,
          speechPlaybackController: widget.speechPlaybackController,
          clipboardImageReader: widget.clipboardImageReader,
          clipboardImageSaver: widget.clipboardImageSaver,
          cameraSessionFactory: widget.cameraSessionFactory,
          cameraImageSaver: widget.cameraImageSaver,
          cameraCacheCleaner: widget.cameraCacheCleaner,
          notificationService: widget.notificationService,
          notificationSoundPlayer: widget.notificationSoundPlayer,
        ),
      ),
    );
  }
}

class ChatPage extends StatefulWidget {
  const ChatPage({
    super.key,
    this.configStore = const SecureAiConfigStore(),
    this.messageStore,
    this.replyService,
    this.speechPlaybackController,
    this.clipboardImageReader,
    this.clipboardImageSaver,
    this.cameraSessionFactory,
    this.cameraImageSaver,
    this.cameraCacheCleaner,
    this.notificationService,
    this.notificationSoundPlayer,
  });

  final AiConfigStore configStore;
  final MessageStore? messageStore;
  final AiReplyService? replyService;
  final SpeechPlaybackController? speechPlaybackController;
  final Future<Uint8List?> Function()? clipboardImageReader;
  final Future<ChatAttachment> Function(Uint8List bytes)? clipboardImageSaver;
  final CameraSessionFactory? cameraSessionFactory;
  final Future<ChatAttachment> Function(Uint8List bytes)? cameraImageSaver;
  final Future<void> Function(MessageStore messageStore)? cameraCacheCleaner;
  final DesktopNotificationService? notificationService;
  final Future<void> Function(String assetPath)? notificationSoundPlayer;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> with WidgetsBindingObserver {
  final _messageController = _EmojiAwareTextEditingController();
  final _messageFocus = FocusNode();
  final _scrollController = ScrollController();
  final _composerKey = GlobalKey<_ComposerState>();
  final List<ChatMessage> _messages = [];
  final Map<String, ChatMessage> _repliesNeedingSave = {};
  final Set<String> _messagesNeedingOnlySave = {};
  final Map<String, String> _retryErrors = {};
  final Map<String, List<ChatAttachment>> _attachmentsByMessage = {};
  final Map<String, int> _assistantFeedback = {};
  final Map<String, String> _assistantReactions = {};
  final Map<String, List<TerminalCommandHistoryEntry>>
  _terminalActivitiesByResponse = {};
  Map<String, MessageBranchNavigation> _messageBranches = {};
  Timer? _attachmentExpiryTimer;
  MessageStore? _messageStore;
  AiReplyService? _replyService;
  bool _cameraEnabled = false;
  bool _saraCameraActive = false;
  final ValueNotifier<bool> _saraCameraActiveListenable = ValueNotifier(false);
  final Set<Object> _activeSaraCameraUses = {};
  final TerminalCommandRunner _terminalCommandRunner = TerminalCommandRunner();
  _PendingTerminalCommandApproval? _pendingTerminalCommandApproval;
  TerminalCommandRequest? _terminalCommandActivity;
  String _terminalCommandStdout = '';
  String _terminalCommandStderr = '';
  bool _terminalCommandRunning = false;
  bool _terminalCommandAutomaticallyAllowed = false;
  bool _applicationDetached = false;
  bool _applicationForeground = true;
  bool _chatRoomVisible = true;
  final Set<CameraPreviewSession> _saraCameraSessions = {};
  late final Future<void> Function(String message) _unseenErrorHandler;
  bool _isLoadingHistory = true;
  bool _isSending = false;
  bool _proactiveModeAllows = false;
  Completer<void>? _proactiveAppendCompletion;
  bool _isDraggingFiles = false;
  bool _hasStreamedReply = false;
  bool _showScrollToBottom = false;
  bool _followLatestDuringStreaming = true;
  String? _searchResultsMessageId;
  String? _regeneratingMessageId;
  String? _regeneratingUserMessageId;
  String? _streamingResponseMessageId;
  String? _activeReplyResponseMessageId;
  late final SpeechPlaybackController _speechPlaybackController;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _speechPlaybackController =
        widget.speechPlaybackController ?? SoundOfTextPlaybackController();
    _unseenErrorHandler = (message) =>
        _notifyWhenUnavailable(message, title: appText('Sara desktop app'));
    _notifyUnseenError = _unseenErrorHandler;
    _scrollController.addListener(_handleScroll);
    _initialize();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (identical(_notifyUnseenError, _unseenErrorHandler)) {
      _notifyUnseenError = null;
    }
    _activeToastTimer?.cancel();
    _activeToastTimer = null;
    if (_activeToast?.mounted ?? false) _activeToast!.remove();
    _activeToast = null;
    _messageController.dispose();
    _messageFocus.dispose();
    _attachmentExpiryTimer?.cancel();
    final replyService = _replyService;
    if (replyService is GeminiReplyService) {
      replyService.disposeConversationBackgroundTasks();
    }
    _pendingTerminalCommandApproval?.complete(TerminalApprovalDecision.skip);
    unawaited(_terminalCommandRunner.stop());
    for (final cameraSession in _saraCameraSessions) {
      unawaited(cameraSession.dispose());
    }
    _saraCameraSessions.clear();
    _speechPlaybackController.dispose();
    _saraCameraActiveListenable.dispose();
    _scrollController.removeListener(_handleScroll);
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _applicationForeground = state == AppLifecycleState.resumed;
    if (state == AppLifecycleState.detached) {
      _applicationDetached = true;
      unawaited(_stopSaraCameraUse());
      _pendingTerminalCommandApproval?.complete(TerminalApprovalDecision.skip);
      unawaited(_terminalCommandRunner.stop());
      final messageStore = _messageStore;
      if (messageStore != null) {
        unawaited(
          _clearCameraCaptureCache(messageStore).catchError((error) {
            debugPrint(
              'Could not clear camera cache on application exit: $error',
            );
          }),
        );
      }
    }
  }

  Future<void> _toggleSpeech(String messageId, String text) async {
    try {
      await _speechPlaybackController.toggle(
        messageId: messageId,
        text: text,
        voice: 'id-ID',
      );
    } catch (error) {
      if (!mounted) return;
      _showMessage(
        appText('Speech playback failed: {error}', values: {'error': error}),
      );
    }
  }

  Future<void> _playNotificationSound(String assetPath) async {
    try {
      await (widget.notificationSoundPlayer ?? _playNotificationSoundAsset)(
        assetPath,
      );
    } catch (error) {
      debugPrint('Could not play notification sound "$assetPath": $error');
    }
  }

  Future<void> _initialize() async {
    try {
      final messageStore =
          widget.messageStore ?? await SqliteMessageStore.open();
      final preferences = await SharedPreferences.getInstance();
      final replyService =
          widget.replyService ??
          GeminiReplyService(
            configStore: widget.configStore,
            preferences: preferences,
            messageStore: messageStore,
            onProactiveMessage: _appendProactiveMessage,
            onBackgroundError: (error) {
              if (mounted) {
                _showMessage(
                  appText(
                    'Could not save conversation memory: {error}',
                    values: {'error': error},
                  ),
                );
              }
            },
          );
      Object? expiryError;
      try {
        await _clearCameraCaptureCache(messageStore);
        await _expireStoredAttachments(messageStore);
      } catch (error) {
        expiryError = error;
      }
      final history = await messageStore.loadActiveMessages();
      final terminalActivities = {
        for (final message in history)
          if (message.terminalActivities.isNotEmpty)
            message.id: message.terminalActivities,
      };
      final attachments = await messageStore.loadAttachments();
      final assistantFeedback = await messageStore.loadAssistantFeedback();
      final assistantReactions = await messageStore.loadAssistantReactions();
      final branches = await messageStore.loadMessageBranches();
      if (!mounted) return;
      setState(() {
        _messageStore = messageStore;
        _replyService = replyService;
        _cameraEnabled = preferences.getBool('sara_camera_enabled') ?? false;
        _messages
          ..clear()
          ..addAll(history);
        _attachmentsByMessage
          ..clear()
          ..addAll(attachments);
        _assistantFeedback
          ..clear()
          ..addAll(assistantFeedback);
        _assistantReactions
          ..clear()
          ..addAll(assistantReactions);
        _messageBranches = branches;
        _terminalActivitiesByResponse
          ..clear()
          ..addAll(terminalActivities);
        _isLoadingHistory = false;
      });
      if (replyService is GeminiReplyService) {
        unawaited(replyService.startConversationBackgroundTasks());
      }
      _attachmentExpiryTimer ??= Timer.periodic(
        const Duration(minutes: 1),
        (_) => unawaited(_expireAttachmentsWhileOpen(messageStore)),
      );
      if (expiryError != null) {
        _showMessage(
          appText(
            'Could not clean up attachment cache: {error}',
            values: {'error': expiryError},
          ),
        );
      }
      if (history.isNotEmpty) _scrollToInitialLatest();
    } catch (error) {
      if (!mounted) return;
      setState(() => _isLoadingHistory = false);
      _showMessage(
        appText(
          'Could not open local chat storage: {error}',
          values: {'error': error},
        ),
      );
    }
  }

  bool get _cameraToolAvailable => _cameraEnabled && !_applicationDetached;

  void _recordConversationProactiveMode(bool allowProactive) {
    _proactiveModeAllows = allowProactive;
    final replyService = _replyService;
    if (replyService is GeminiReplyService) {
      replyService.recordConversationUserActivity(
        allowProactive: allowProactive,
      );
    }
  }

  void _refreshSaraCameraActive() {
    final active = _activeSaraCameraUses.isNotEmpty;
    _saraCameraActive = active;
    if (!mounted) return;
    _saraCameraActiveListenable.value = active;
    setState(() {});
  }

  Future<void> _setCameraEnabled(bool enabled) async {
    final preferences = await SharedPreferences.getInstance();
    final saved = await preferences.setBool('sara_camera_enabled', enabled);
    if (!saved)
      throw StateError('Could not save Sara’s camera access setting.');
    if (!mounted) return;
    setState(() => _cameraEnabled = enabled);
    if (!enabled) await _stopSaraCameraUse();
  }

  Future<void> _stopSaraCameraUse() async {
    final sessions = List<CameraPreviewSession>.of(_saraCameraSessions);
    _saraCameraSessions.clear();
    Object? disposalError;
    for (final session in sessions) {
      try {
        await session.dispose();
      } catch (error) {
        disposalError ??= error;
      }
    }
    _activeSaraCameraUses.clear();
    _refreshSaraCameraActive();
    if (disposalError != null) {
      throw StateError(
        'Could not close the active Sara camera: $disposalError',
      );
    }
  }

  Future<CameraFrame> _captureFrameForSara() async {
    if (!_cameraToolAvailable) {
      throw StateError('Sara’s camera access is disabled or unavailable.');
    }
    final cameraUse = Object();
    _activeSaraCameraUses.add(cameraUse);
    _refreshSaraCameraActive();
    CameraPreviewSession? session;
    File? frameFile;
    try {
      session =
          await (widget.cameraSessionFactory ?? CameraPreviewSession.open)();
      _saraCameraSessions.add(session);
      if (!_cameraToolAvailable) {
        throw StateError('Sara’s camera access is no longer available.');
      }
      final frameBytes = await session.frames.first.timeout(
        const Duration(seconds: 8),
        onTimeout: () =>
            throw TimeoutException('Timed out waiting for a camera frame.'),
      );
      if (!_cameraToolAvailable) {
        throw StateError('Sara’s camera access is no longer available.');
      }
      await session.dispose();
      _saraCameraSessions.remove(session);
      session = null;

      final cacheDirectory = await getApplicationCacheDirectory();
      final saraCameraDirectory = Directory(
        path.join(cacheDirectory.path, 'Sara', 'camera-capture'),
      );
      await saraCameraDirectory.create(recursive: true);
      final capturedFile = File(
        path.join(saraCameraDirectory.path, '${_uuid.v4()}.jpg'),
      );
      frameFile = capturedFile;
      await capturedFile.writeAsBytes(frameBytes, flush: true);
      final bytes = await capturedFile.readAsBytes();
      return CameraFrame(
        bytes: bytes,
        dispose: () async {
          try {
            final absolutePath = path.normalize(
              path.absolute(capturedFile.path),
            );
            final absoluteDirectory = path.normalize(
              path.absolute(saraCameraDirectory.path),
            );
            if (!path.isWithin(absoluteDirectory, absolutePath)) {
              throw StateError(
                'Refusing to delete an camera frame outside app cache.',
              );
            }
            if (await capturedFile.exists()) await capturedFile.delete();
          } finally {
            _activeSaraCameraUses.remove(cameraUse);
            _refreshSaraCameraActive();
          }
        },
      );
    } catch (_) {
      try {
        if (session != null) {
          _saraCameraSessions.remove(session);
          await session.dispose();
        }
        if (frameFile != null && await frameFile.exists()) {
          await frameFile.delete();
        }
      } finally {
        _activeSaraCameraUses.remove(cameraUse);
        _refreshSaraCameraActive();
      }
      rethrow;
    }
  }

  Future<TerminalApprovalDecision> _requestTerminalCommandApproval(
    TerminalCommandRequest request,
  ) async {
    if (!mounted || _applicationDetached) {
      return TerminalApprovalDecision.skip;
    }
    final pending = _PendingTerminalCommandApproval(request);
    setState(() => _pendingTerminalCommandApproval = pending);
    unawaited(
      _notifyWhenUnavailable(
        appText(
          'Sara wants permission to run this terminal command:\n{command}',
          values: {'command': request.command},
        ),
        title: appText('Sara needs your approval'),
      ),
    );
    try {
      return await pending.decision.future;
    } finally {
      if (mounted && identical(_pendingTerminalCommandApproval, pending)) {
        setState(() => _pendingTerminalCommandApproval = null);
      }
    }
  }

  void _decideTerminalCommand(TerminalApprovalDecision decision) {
    _pendingTerminalCommandApproval?.complete(decision);
  }

  Future<TerminalCommandResult> _executeTerminalCommand(
    TerminalCommandRequest request,
  ) {
    return _terminalCommandRunner.run(
      request,
      onOutput: (stdout, stderr) {
        if (!mounted) return;
        setState(() {
          _terminalCommandStdout = stdout;
          _terminalCommandStderr = stderr;
        });
      },
    );
  }

  void _updateTerminalCommandActivity(
    TerminalCommandRequest request, {
    required String ownerMessageId,
    required bool running,
    required bool automaticallyAllowed,
  }) {
    if (!mounted) return;
    final responseMessageId = request.responseMessageId ?? ownerMessageId;
    setState(() {
      if (running) {
        _upsertPendingTerminalActivity(request, responseMessageId, 'Running');
        _terminalCommandActivity = request;
        _terminalCommandRunning = true;
        _terminalCommandAutomaticallyAllowed = automaticallyAllowed;
        _terminalCommandStdout = '';
        _terminalCommandStderr = '';
      } else if (_terminalCommandActivity == request) {
        _terminalCommandRunning = false;
        _terminalCommandAutomaticallyAllowed = false;
        _terminalCommandActivity = null;
        _terminalCommandStdout = '';
        _terminalCommandStderr = '';
      } else {
        _upsertPendingTerminalActivity(
          request,
          responseMessageId,
          'Awaiting approval',
        );
      }
    });
  }

  void _upsertPendingTerminalActivity(
    TerminalCommandRequest request,
    String ownerMessageId,
    String status,
  ) {
    final activities = [...?_terminalActivitiesByResponse[ownerMessageId]];
    final matchingIndex = activities.lastIndexWhere(
      (activity) =>
          activity.command == request.command &&
          activity.error != null &&
          const {'Awaiting approval', 'Running'}.contains(activity.error),
    );
    final pending = TerminalCommandHistoryEntry(
      responseMessageId: request.responseMessageId,
      taskContext: request.taskContext,
      command: request.command,
      workingDirectory: request.workingDirectory,
      exitCode: null,
      stdout: '',
      stderr: '',
      error: status,
      timedOut: false,
      cancelled: false,
      skipped: false,
      outputTruncated: false,
      createdAtUtc: DateTime.now().toUtc().millisecondsSinceEpoch,
    );
    if (matchingIndex >= 0) {
      activities[matchingIndex] = pending;
    } else {
      activities.add(pending);
    }
    _terminalActivitiesByResponse[ownerMessageId] = activities;
  }

  Future<void> _recordTerminalCommandResult(
    TerminalCommandResult result,
    String ownerMessageId,
  ) async {
    final entry = TerminalCommandHistoryEntry.fromResult(result);
    final responseMessageId =
        result.request.responseMessageId ?? ownerMessageId;
    final activities = [...?_terminalActivitiesByResponse[responseMessageId]];
    final pendingIndex = activities.lastIndexWhere(
      (activity) =>
          activity.command == entry.command &&
          activity.error != null &&
          const {'Awaiting approval', 'Running'}.contains(activity.error),
    );
    if (pendingIndex >= 0) {
      activities[pendingIndex] = entry;
    } else {
      activities.add(entry);
    }
    if (mounted) {
      setState(() {
        _terminalActivitiesByResponse[responseMessageId] = activities;
      });
    }
    final messageStore = _messageStore;
    if (messageStore == null) {
      if (mounted) {
        _showMessage(appText('Message storage is unavailable.'));
      }
      return;
    }
    try {
      await messageStore.saveTerminalCommandActivities(
        ownerMessageId,
        activities,
      );
    } catch (error) {
      if (!mounted) return;
      _showMessage(
        appText(
          'Could not save terminal activity: {error}',
          values: {'error': error},
        ),
      );
    }
  }

  Future<void> _stopTerminalCommand() async {
    try {
      await _terminalCommandRunner.stop();
    } catch (error) {
      if (!mounted) return;
      _showMessage(
        appText(
          'Could not stop terminal command: {error}',
          values: {'error': error},
        ),
      );
    }
  }

  Future<void> _stopCameraFromIndicator() async {
    try {
      await _setCameraEnabled(false);
    } catch (error) {
      if (!mounted) return;
      _showMessage(
        appText(
          'Could not update Sara’s camera access setting: {error}',
          values: {'error': error},
        ),
      );
    }
  }

  Future<void> _expireStoredAttachments(MessageStore messageStore) async {
    final nowUtc = DateTime.now().toUtc().millisecondsSinceEpoch;
    final expired = await messageStore.loadExpiredAttachments(nowUtc);
    if (expired.isEmpty) return;
    final expiredClipboard = expired
        .where((item) => item.isClipboardCopy)
        .toList(growable: false);
    if (expiredClipboard.isNotEmpty) {
      final supportDirectory = await getApplicationSupportDirectory();
      final clipboardDirectory = path.normalize(
        path.absolute(
          path.join(supportDirectory.path, 'Sara', 'clipboard-attachments'),
        ),
      );
      for (final attachment in expiredClipboard) {
        final filePath = attachment.path;
        if (filePath == null) continue;
        final absoluteFilePath = path.normalize(path.absolute(filePath));
        if (!path.isWithin(clipboardDirectory, absoluteFilePath)) {
          throw StateError(
            'Refusing to delete clipboard attachment outside the app folder.',
          );
        }
        final file = File(absoluteFilePath);
        if (await file.exists()) await file.delete();
      }
    }
    await messageStore.expireAttachments(nowUtc);
    final refreshedAttachments = await messageStore.loadAttachments();
    if (!mounted) return;
    setState(() {
      _attachmentsByMessage
        ..clear()
        ..addAll(refreshedAttachments);
    });
  }

  Future<void> _clearCameraCaptureCache(MessageStore messageStore) async {
    final cleaner = widget.cameraCacheCleaner;
    if (cleaner != null) {
      await cleaner(messageStore);
      return;
    }
    final supportDirectory = await getApplicationSupportDirectory();
    final cacheDirectory = await getApplicationCacheDirectory();
    await CameraCaptureCache.clear(
      messageStore: messageStore,
      supportDirectory: supportDirectory,
      cacheDirectory: cacheDirectory,
    );
  }

  Future<void> _expireAttachmentsWhileOpen(MessageStore messageStore) async {
    try {
      await _expireStoredAttachments(messageStore);
    } catch (error) {
      debugPrint('Attachment expiry cleanup failed: $error');
      if (mounted) {
        _showMessage(
          appText(
            'Could not remove expired attachment paths: {error}',
            values: {'error': error},
          ),
        );
      }
    }
  }

  Future<ChatMessage?> _appendProactiveMessage(
    String content,
    String expectedLeafId,
  ) async {
    final messageStore = _messageStore;
    if (!mounted ||
        _isSending ||
        !_proactiveModeAllows ||
        _messageController.text.trim().isNotEmpty ||
        messageStore == null) {
      return null;
    }
    final completion = Completer<void>();
    _proactiveAppendCompletion = completion;
    try {
      final message = _newMessage(
        role: 'model',
        content: content,
        parentMessageId: expectedLeafId,
      );
      if (!await messageStore.appendMessageIfActiveLeaf(
        message,
        expectedLeafId: expectedLeafId,
      )) {
        return null;
      }
      await _refreshActivePath(messageStore);
      if (!mounted) return message;
      unawaited(_playNotificationSound('assets/sound/received.mp3'));
      unawaited(
        _notifyWhenUnavailable(
          content,
          title: appText('Sara sent you a message'),
        ),
      );
      return message;
    } finally {
      if (identical(_proactiveAppendCompletion, completion)) {
        _proactiveAppendCompletion = null;
      }
      completion.complete();
    }
  }

  Future<void> _waitForProactiveAppend() async {
    await _proactiveAppendCompletion?.future;
  }

  Future<void> _sendMessage(
    String? suggestion, [
    List<ChatAttachment> attachments = const [],
    bool allowAiReply = true,
  ]) async {
    await _waitForProactiveAppend();
    if (_isSending) return;
    final text = (suggestion ?? _messageController.text).trim();
    if (text.isEmpty && attachments.isEmpty) return;

    final messageStore = _messageStore;
    final replyService = _replyService;
    if (messageStore == null || replyService == null) {
      _showMessage(
        appText('Local chat storage is not ready. Please try again shortly.'),
      );
      return;
    }

    final userMessage = _newMessage(
      role: 'user',
      content: text,
      parentMessageId: _messages.isEmpty ? null : _messages.last.id,
    );
    setState(() {
      _isSending = true;
      _hasStreamedReply = false;
      _messages.add(userMessage);
      if (attachments.isNotEmpty) {
        _attachmentsByMessage[userMessage.id] = attachments;
      }
      _messageController.clear();
    });
    _scrollToLatest();

    try {
      await messageStore.appendMessage(userMessage);
      await messageStore.saveMessageAttachments(userMessage.id, attachments);
    } catch (error) {
      _retryErrors[userMessage.id] = appText(
        'Message could not be saved: {error}',
        values: {'error': error},
      );
      _messagesNeedingOnlySave.add(userMessage.id);
      if (mounted) {
        setState(() => _isSending = false);
      }
      return;
    }
    unawaited(_playNotificationSound('assets/sound/send.mp3'));

    if (!allowAiReply) {
      if (replyService is GeminiReplyService) {
        _recordConversationProactiveMode(false);
        replyService.enqueueConversationMemory(
          userMessage: userMessage,
          modelMessage: null,
        );
      }
      if (mounted) setState(() => _isSending = false);
      return;
    }
    await _generateReplyFor(userMessage, messageStore, replyService);
  }

  Future<void> _submitEditedMessage(
    String messageId,
    String content,
    List<ChatAttachment> attachments,
    bool allowAiReply,
  ) async {
    await _waitForProactiveAppend();
    if (_isSending) return;
    final messageStore = _messageStore;
    final replyService = _replyService;
    final sourceIndex = _messages.indexWhere(
      (message) => message.id == messageId,
    );
    if (messageStore == null ||
        replyService == null ||
        sourceIndex < 0 ||
        _messages[sourceIndex].role != 'user') {
      return;
    }

    final text = content.trim();
    if (text.isEmpty && attachments.isEmpty) return;
    final original = _messages[sourceIndex];
    setState(() => _isSending = true);
    late final List<ChatAttachment> branchAttachments;
    try {
      branchAttachments = await _duplicateAttachmentsForEditedBranch(
        attachments,
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _isSending = false);
      _showMessage(
        appText(
          'Could not prepare edited message attachments: {error}',
          values: {'error': error},
        ),
      );
      return;
    }
    final editedMessage = _newMessage(
      role: 'user',
      content: text,
      parentMessageId: original.parentMessageId,
    );
    setState(() {
      _isSending = true;
      _hasStreamedReply = false;
      _messages
        ..removeRange(sourceIndex, _messages.length)
        ..add(editedMessage);
      _attachmentsByMessage[editedMessage.id] = branchAttachments;
      _messageController.clear();
    });
    _scrollToLatest();

    try {
      await messageStore.appendMessage(editedMessage);
      await messageStore.saveMessageAttachments(
        editedMessage.id,
        branchAttachments,
      );
      await _refreshActivePath(messageStore);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _messagesNeedingOnlySave.add(editedMessage.id);
        _retryErrors[editedMessage.id] = appText(
          'Message could not be saved: {error}',
          values: {'error': error},
        );
        _isSending = false;
      });
      _showMessage(
        appText(
          'Message could not be saved: {error}',
          values: {'error': error},
        ),
      );
      return;
    }

    if (!allowAiReply) {
      if (replyService is GeminiReplyService) {
        _recordConversationProactiveMode(false);
        replyService.enqueueConversationMemory(
          userMessage: editedMessage,
          modelMessage: null,
        );
      }
      if (mounted) setState(() => _isSending = false);
      return;
    }
    await _generateReplyFor(editedMessage, messageStore, replyService);
  }

  Future<List<ChatAttachment>> _duplicateAttachmentsForEditedBranch(
    List<ChatAttachment> attachments,
  ) async {
    if (attachments.isEmpty) return const [];
    final clipboardAttachments = attachments
        .where(
          (attachment) => attachment.isClipboardCopy && attachment.path != null,
        )
        .toList(growable: false);
    if (clipboardAttachments.isEmpty) {
      return attachments
          .map(
            (attachment) => ChatAttachment(
              id: _uuid.v4(),
              path: attachment.path,
              name: attachment.name,
              mimeType: attachment.mimeType,
              expiresAtUtc: attachment.expiresAtUtc,
              isClipboardCopy: attachment.isClipboardCopy,
            ),
          )
          .toList(growable: false);
    }
    final supportDirectory = await getApplicationSupportDirectory();
    final cacheDirectory = await getApplicationCacheDirectory();
    final clipboardDirectory = path.normalize(
      path.absolute(
        path.join(supportDirectory.path, 'Sara', 'clipboard-attachments'),
      ),
    );
    final cameraDirectory = path.normalize(
      path.absolute(
        path.join(cacheDirectory.path, 'Sara', 'camera-attachments'),
      ),
    );
    final legacyCameraDirectory = path.normalize(
      path.absolute(
        path.join(supportDirectory.path, 'Sara', 'camera-attachments'),
      ),
    );
    final copiedFiles = <File>[];
    try {
      final result = <ChatAttachment>[];
      for (final attachment in attachments) {
        var attachmentPath = attachment.path;
        if (attachment.isClipboardCopy && attachmentPath != null) {
          final sourcePath = path.normalize(path.absolute(attachmentPath));
          if (!path.isWithin(clipboardDirectory, sourcePath) &&
              !path.isWithin(cameraDirectory, sourcePath) &&
              !path.isWithin(legacyCameraDirectory, sourcePath)) {
            throw StateError(
              'Refusing to duplicate an app-managed attachment outside the app folder.',
            );
          }
          final sourceFile = File(sourcePath);
          if (await sourceFile.exists()) {
            await Directory(clipboardDirectory).create(recursive: true);
            attachmentPath = path.join(
              clipboardDirectory,
              '${_uuid.v4()}${path.extension(sourcePath)}',
            );
            final copiedFile = await sourceFile.copy(attachmentPath);
            copiedFiles.add(copiedFile);
          } else {
            attachmentPath = null;
          }
        }
        result.add(
          ChatAttachment(
            id: _uuid.v4(),
            path: attachmentPath,
            name: attachment.name,
            mimeType: attachment.mimeType,
            expiresAtUtc: attachment.expiresAtUtc,
            isClipboardCopy: attachment.isClipboardCopy,
          ),
        );
      }
      return result;
    } catch (error) {
      final cleanupErrors = <Object>[];
      for (final file in copiedFiles) {
        try {
          if (await file.exists()) await file.delete();
        } catch (cleanupError) {
          cleanupErrors.add(cleanupError);
        }
      }
      if (cleanupErrors.isNotEmpty) {
        throw StateError(
          '$error. Copied attachment cleanup failed: ${cleanupErrors.join('; ')}',
        );
      }
      rethrow;
    }
  }

  Future<void> _retryMessage(String messageId) async {
    if (_isSending) return;
    final messageStore = _messageStore;
    final replyService = _replyService;
    final index = _messages.indexWhere((message) => message.id == messageId);
    if (messageStore == null || replyService == null || index == -1) return;

    final userMessage = _messages[index];
    final persistedUserMessage = userMessage.withTerminalActivities(
      _terminalActivitiesByResponse[messageId] ??
          userMessage.terminalActivities,
    );
    final cachedReply = _repliesNeedingSave[messageId];
    setState(() {
      _isSending = true;
      _hasStreamedReply = cachedReply != null;
    });
    if (cachedReply != null) {
      try {
        await messageStore.saveExchangeWithAttachments(
          [persistedUserMessage, cachedReply],
          userMessage.id,
          _attachmentsByMessage[userMessage.id] ?? const [],
          additionalAttachments: {
            if (_attachmentsByMessage[cachedReply.id]?.isNotEmpty ?? false)
              cachedReply.id: _attachmentsByMessage[cachedReply.id]!,
          },
        );
        if (cachedReply.terminalActivities.isNotEmpty) {
          await messageStore.moveTerminalCommandActivities(
            userMessage.id,
            cachedReply.id,
          );
        }
        await _refreshActivePath(messageStore);
        if (!mounted) return;
        setState(() {
          _repliesNeedingSave.remove(messageId);
          _retryErrors.remove(messageId);
          _isSending = false;
        });
        _showMessage(appText('Message saved successfully.'), isError: false);
      } catch (error) {
        if (!mounted) return;
        setState(() {
          _retryErrors[messageId] = appText(
            'Could not save message: {error}',
            values: {'error': error},
          );
          _isSending = false;
        });
        _showMessage(
          appText('Could not save message. Tap retry to try again.'),
        );
      }
      return;
    }
    if (_messagesNeedingOnlySave.contains(messageId)) {
      try {
        await messageStore.saveExchangeWithAttachments(
          [persistedUserMessage],
          userMessage.id,
          _attachmentsByMessage[messageId] ?? const [],
        );
        await _refreshActivePath(messageStore);
        if (!mounted) return;
        setState(() {
          _messagesNeedingOnlySave.remove(messageId);
          _retryErrors.remove(messageId);
          _isSending = false;
        });
        _showMessage(appText('Message saved successfully.'), isError: false);
      } catch (error) {
        if (!mounted) return;
        setState(() {
          _retryErrors[messageId] = appText(
            'Message could not be saved: {error}',
            values: {'error': error},
          );
          _isSending = false;
        });
      }
      return;
    }
    try {
      await messageStore.saveExchangeWithAttachments(
        [persistedUserMessage],
        userMessage.id,
        _attachmentsByMessage[messageId] ?? const [],
      );
      if (mounted) {
        setState(() => _retryErrors.remove(messageId));
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _retryErrors[messageId] = appText(
            'Message could not be saved: {error}',
            values: {'error': error},
          );
        });
      }
    }
    await _generateReplyFor(userMessage, messageStore, replyService);
  }

  Future<void> _deleteMessageAndFollowing(String messageId) async {
    await _waitForProactiveAppend();
    if (_isSending) return;
    final messageStore = _messageStore;
    final index = _messages.indexWhere((message) => message.id == messageId);
    if (messageStore == null || index < 0) {
      return;
    }
    if (_messages[index].role != 'user') return;

    final shouldDelete = await _showIosConfirmation(
      context: context,
      title: appText('Delete messages?'),
      message: appText(
        'This message and every reply and branch after it will be permanently deleted.',
      ),
      cancelLabel: appText('Cancel'),
      confirmLabel: appText('Delete'),
      destructive: true,
    );
    if (shouldDelete != true || !mounted) return;

    late final List<String> ids;
    try {
      ids = await messageStore.loadSubtreeMessageIds(messageId);
    } catch (error) {
      if (!mounted) return;
      _showMessage(
        appText('Could not delete message: {error}', values: {'error': error}),
      );
      return;
    }
    final clipboardAttachments = ids
        .expand((id) => _attachmentsByMessage[id] ?? const <ChatAttachment>[])
        .where((attachment) => attachment.isClipboardCopy)
        .toList(growable: false);
    try {
      await messageStore.deleteMessages(ids);
    } catch (error) {
      if (!mounted) return;
      _showMessage(
        appText('Could not delete message: {error}', values: {'error': error}),
      );
      return;
    }

    for (final id in ids) {
      _attachmentsByMessage.remove(id);
      _assistantFeedback.remove(id);
      _assistantReactions.remove(id);
      _repliesNeedingSave.remove(id);
      _messagesNeedingOnlySave.remove(id);
      _retryErrors.remove(id);
    }
    await _refreshActivePath(messageStore);

    try {
      await _deleteClipboardAttachmentFiles(clipboardAttachments);
      if (mounted) {
        _showMessage(
          appText('Message and following history deleted.'),
          isError: false,
        );
      }
    } catch (error) {
      if (!mounted) return;
      _showMessage(
        appText(
          'Messages deleted, but copied attachment cleanup failed: {error}',
          values: {'error': error},
        ),
      );
    }
  }

  Future<void> _refreshActivePath(MessageStore messageStore) async {
    final messages = await messageStore.loadActiveMessages();
    final terminalActivities = {
      for (final message in messages)
        if (message.terminalActivities.isNotEmpty)
          message.id: message.terminalActivities,
    };
    final branches = await messageStore.loadMessageBranches();
    final attachments = await messageStore.loadAttachments();
    final feedback = await messageStore.loadAssistantFeedback();
    final reactions = await messageStore.loadAssistantReactions();
    if (!mounted) return;
    setState(() {
      _messages
        ..clear()
        ..addAll(messages);
      _messageBranches = branches;
      _terminalActivitiesByResponse
        ..clear()
        ..addAll(terminalActivities);
      _attachmentsByMessage
        ..clear()
        ..addAll(attachments);
      _assistantFeedback
        ..clear()
        ..addAll(feedback);
      _assistantReactions
        ..clear()
        ..addAll(reactions);
    });
    _scrollToLatest();
  }

  Future<void> _activateMessageBranch(String messageId) async {
    await _waitForProactiveAppend();
    final messageStore = _messageStore;
    if (_isSending || messageStore == null) return;
    try {
      await messageStore.activateMessageBranch(messageId);
      await _refreshActivePath(messageStore);
      if (_searchResultsMessageId != null && mounted) {
        setState(() => _searchResultsMessageId = null);
      }
      final replyService = _replyService;
      if (replyService is GeminiReplyService) {
        replyService.scheduleActiveBranchTopicBackfill();
      }
    } catch (error) {
      if (mounted) {
        _showMessage(
          appText(
            'Could not switch conversation branch: {error}',
            values: {'error': error},
          ),
        );
      }
    }
  }

  Future<void> _openSearchResultLink(String href) async {
    final uri = Uri.tryParse(href);
    if (uri == null ||
        (uri.scheme != 'https' && uri.scheme != 'http') ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      return;
    }
    try {
      final result = await Process.run('xdg-open', [uri.toString()]);
      if (result.exitCode != 0) {
        throw ProcessException(
          'xdg-open',
          [uri.toString()],
          result.stderr.toString(),
          result.exitCode,
        );
      }
    } catch (error) {
      if (!mounted) return;
      _showMessage(
        appText('Could not open link: {error}', values: {'error': error}),
      );
    }
  }

  Future<void> _regenerateMessage(String responseMessageId) async {
    await _waitForProactiveAppend();
    if (_isSending) return;
    final responseIndex = _messages.indexWhere(
      (message) => message.id == responseMessageId,
    );
    if (responseIndex <= 0 ||
        _messages[responseIndex].role != 'model' ||
        _messages[responseIndex - 1].role != 'user') {
      return;
    }
    final messageStore = _messageStore;
    final replyService = _replyService;
    if (messageStore == null || replyService == null) return;
    final userMessage = _messages[responseIndex - 1];
    setState(() {
      _isSending = true;
      _hasStreamedReply = false;
      _regeneratingMessageId = responseMessageId;
      _regeneratingUserMessageId = userMessage.id;
      _streamingResponseMessageId = null;
    });
    late final List<ChatMessage> alternatives;
    try {
      alternatives = (await messageStore.loadMessages())
          .where(
            (message) =>
                message.role == 'model' &&
                message.parentMessageId == userMessage.id,
          )
          .toList(growable: false);
    } catch (error) {
      if (mounted) {
        setState(() {
          _isSending = false;
          _clearRegenerationState();
        });
      }
      if (mounted) {
        _showMessage(
          appText(
            'Could not load previous branch replies: {error}',
            values: {'error': error},
          ),
        );
      }
      return;
    }
    await _generateReplyFor(
      userMessage,
      messageStore,
      replyService,
      isRegenerate: true,
      previousBranchReplies: alternatives,
    );
  }

  Future<void> _setAssistantFeedback(
    String userMessageId,
    String responseMessageId,
    int? rating,
  ) async {
    final messageStore = _messageStore;
    if (_isSending || messageStore == null) return;
    try {
      await messageStore.saveAssistantFeedback(
        userMessageId,
        responseMessageId,
        rating,
      );
      if (!mounted) return;
      setState(() {
        if (rating == null) {
          _assistantFeedback.remove(responseMessageId);
        } else {
          _assistantFeedback[responseMessageId] = rating;
        }
      });
    } catch (error) {
      if (!mounted) return;
      _showMessage(
        appText(
          'Could not save response feedback: {error}',
          values: {'error': error},
        ),
      );
    }
  }

  Future<void> _setAssistantReaction(
    String userMessageId,
    String responseMessageId,
    String? reaction,
  ) async {
    final messageStore = _messageStore;
    if (_isSending || messageStore == null) return;
    try {
      await messageStore.saveAssistantReaction(
        userMessageId,
        responseMessageId,
        reaction,
      );
      if (!mounted) return;
      setState(() {
        if (reaction == null) {
          _assistantReactions.remove(responseMessageId);
        } else {
          _assistantReactions[responseMessageId] = reaction;
        }
      });
    } catch (error) {
      if (!mounted) return;
      _showMessage(
        appText(
          'Could not save response reaction: {error}',
          values: {'error': error},
        ),
      );
    }
  }

  Future<void> _generateReplyFor(
    ChatMessage userMessage,
    MessageStore messageStore,
    AiReplyService replyService, {
    bool isRegenerate = false,
    List<ChatMessage> previousBranchReplies = const [],
  }) async {
    _followLatestDuringStreaming = true;
    if (replyService is GeminiReplyService) {
      replyService.recordConversationUserActivity(
        allowProactive: _proactiveModeAllows,
      );
    }
    final responseMessageId = _uuid.v4();
    if (mounted) {
      setState(() => _activeReplyResponseMessageId = responseMessageId);
    }
    ChatMessage? streamedMessage;
    Timer? typewriterTimer;
    final visibleRunes = <int>[];
    var pendingRunes = <int>[];
    void updateStreamedMessage(String content) {
      if (!mounted) return;
      setState(() {
        _hasStreamedReply = true;
        if (streamedMessage == null) {
          if (isRegenerate) {
            _streamingResponseMessageId = responseMessageId;
          }
          streamedMessage = _newMessage(
            role: 'model',
            content: content,
            parentMessageId: userMessage.id,
            id: responseMessageId,
          );
          _messages.add(streamedMessage!);
        } else {
          streamedMessage = ChatMessage(
            id: streamedMessage!.id,
            role: 'model',
            content: content,
            timestamp: streamedMessage!.timestamp,
            createdAtUtc: streamedMessage!.createdAtUtc,
            parentMessageId: streamedMessage!.parentMessageId,
          );
          final index = _messages.indexWhere(
            (message) => message.id == streamedMessage!.id,
          );
          if (index >= 0) _messages[index] = streamedMessage!;
        }
      });
      _scrollToLatestDuringStreaming();
    }

    void receiveStreamedText(String text) {
      if (text.isEmpty) {
        typewriterTimer?.cancel();
        typewriterTimer = null;
        visibleRunes.clear();
        pendingRunes = [];
        if (streamedMessage != null && mounted) {
          setState(() {
            _hasStreamedReply = false;
            _streamingResponseMessageId = null;
            _messages.removeWhere(
              (message) => message.id == streamedMessage!.id,
            );
            streamedMessage = null;
          });
        }
        return;
      }
      pendingRunes = text.runes.toList(growable: false);
      typewriterTimer ??= Timer.periodic(const Duration(milliseconds: 60), (
        timer,
      ) {
        if (!mounted) {
          timer.cancel();
          typewriterTimer = null;
          return;
        }
        final start = visibleRunes.length;
        final end = math.min(start + 5, pendingRunes.length);
        if (end > start) {
          visibleRunes.addAll(pendingRunes.getRange(start, end));
          updateStreamedMessage(String.fromCharCodes(visibleRunes));
        }
        if (visibleRunes.length >= pendingRunes.length) {
          timer.cancel();
          typewriterTimer = null;
        }
      });
    }

    void finishTypewriter() {
      typewriterTimer?.cancel();
      typewriterTimer = null;
      if (visibleRunes.length < pendingRunes.length) {
        visibleRunes
          ..clear()
          ..addAll(pendingRunes);
        updateStreamedMessage(String.fromCharCodes(visibleRunes));
      }
    }

    List<ChatAttachment> generatedAttachments = const [];
    try {
      final personalName = await messageStore.readPersonalName();
      final persistedHistory = await messageStore.loadActiveMessages();
      final userIndex = persistedHistory.indexWhere(
        (message) => message.id == userMessage.id,
      );
      final history = List<ChatMessage>.unmodifiable(
        userIndex < 0
            ? [...persistedHistory, userMessage]
            : persistedHistory.take(userIndex + 1).toList(growable: false),
      );
      final historyAttachments = <String, List<ChatAttachment>>{
        for (final message in history)
          if (_attachmentsByMessage.containsKey(message.id))
            message.id: _attachmentsByMessage[message.id]!,
      };
      final reply = await replyService.generateReply(
        history,
        personalName: personalName,
        responseMessageId: responseMessageId,
        previousBranchReplies: previousBranchReplies,
        attachmentsByMessage: historyAttachments,
        onMemoryError: (error) {
          if (mounted) {
            _showMessage(
              appText(
                'Could not retrieve conversation memory: {error}',
                values: {'error': error},
              ),
            );
          }
        },
        onText: receiveStreamedText,
        onMedia: (attachments) => generatedAttachments = attachments,
        captureCameraFrame: _cameraToolAvailable ? _captureFrameForSara : null,
        approveTerminalCommand: _requestTerminalCommandApproval,
        executeTerminalCommand: _executeTerminalCommand,
        onTerminalCommandActivity:
            (request, {required running, required automaticallyAllowed}) =>
                _updateTerminalCommandActivity(
                  request,
                  ownerMessageId: userMessage.id,
                  running: running,
                  automaticallyAllowed: automaticallyAllowed,
                ),
        onTerminalCommandResult: (result) =>
            _recordTerminalCommandResult(result, userMessage.id),
      );
      finishTypewriter();
      if (reply.trim().isEmpty && generatedAttachments.isEmpty) {
        if (replyService is GeminiReplyService) {
          try {
            await replyService.saveConversationMemory(
              responseMessageId: responseMessageId,
              userMessage: userMessage,
              modelMessage: null,
            );
          } catch (error) {
            if (mounted) {
              _showMessage(
                appText(
                  'Could not save conversation memory: {error}',
                  values: {'error': error},
                ),
              );
            }
          }
        }
        if (mounted) {
          setState(() {
            if (_retryErrors.containsKey(userMessage.id)) {
              _messagesNeedingOnlySave.add(userMessage.id);
            }
            if (streamedMessage != null) {
              _messages.removeWhere(
                (message) => message.id == streamedMessage!.id,
              );
            }
            _isSending = false;
            _clearRegenerationState();
          });
        }
        return;
      }
      final modelMessage = streamedMessage == null
          ? _newMessage(
              role: 'model',
              content: reply,
              parentMessageId: userMessage.id,
              id: responseMessageId,
            )
          : ChatMessage(
              id: streamedMessage!.id,
              role: 'model',
              content: reply,
              timestamp: streamedMessage!.timestamp,
              createdAtUtc: streamedMessage!.createdAtUtc,
              parentMessageId: userMessage.id,
            );
      final terminalActivities =
          _terminalActivitiesByResponse[responseMessageId] ??
          _terminalActivitiesByResponse[userMessage.id] ??
          userMessage.terminalActivities;
      final savedModelMessage = modelMessage.withTerminalActivities(
        terminalActivities,
      );
      final savedUserMessage = userMessage.withTerminalActivities(
        terminalActivities,
      );
      if (!mounted) return;
      setState(() {
        if (streamedMessage == null) {
          _messages.add(savedModelMessage);
        } else {
          final index = _messages.indexWhere(
            (message) => message.id == savedModelMessage.id,
          );
          if (index >= 0) _messages[index] = savedModelMessage;
        }
        if (terminalActivities.isNotEmpty) {
          _terminalActivitiesByResponse.remove(userMessage.id);
          _terminalActivitiesByResponse[responseMessageId] = terminalActivities;
        }
        if (generatedAttachments.isNotEmpty) {
          _attachmentsByMessage[savedModelMessage.id] = generatedAttachments;
        }
      });
      unawaited(_playNotificationSound('assets/sound/received.mp3'));
      unawaited(
        _notifyWhenUnavailable(
          savedModelMessage.content.trim().isEmpty
              ? appText('Sara shared something with you.')
              : savedModelMessage.content.trim(),
          title: appText('Sara sent you a message'),
        ),
      );
      try {
        await messageStore.saveExchangeWithAttachments(
          [savedUserMessage, savedModelMessage],
          userMessage.id,
          _attachmentsByMessage[userMessage.id] ?? const [],
          additionalAttachments: {
            if (generatedAttachments.isNotEmpty)
              savedModelMessage.id: generatedAttachments,
          },
        );
        if (terminalActivities.isNotEmpty) {
          await messageStore.moveTerminalCommandActivities(
            userMessage.id,
            responseMessageId,
          );
        }
        await _refreshActivePath(messageStore);
        if (!mounted) return;
        setState(() {
          _repliesNeedingSave.remove(userMessage.id);
          _messagesNeedingOnlySave.remove(userMessage.id);
          _retryErrors.remove(userMessage.id);
          _isSending = false;
          _clearRegenerationState();
        });
        if (replyService is GeminiReplyService) {
          try {
            await replyService.saveConversationMemory(
              responseMessageId: responseMessageId,
              userMessage: savedUserMessage,
              modelMessage: savedModelMessage,
            );
          } catch (error) {
            if (mounted) {
              _showMessage(
                appText(
                  'Could not save conversation memory: {error}',
                  values: {'error': error},
                ),
              );
            }
          }
        }
      } catch (error) {
        if (replyService is GeminiReplyService) {
          replyService.discardConversationMemoryContext(responseMessageId);
        }
        if (isRegenerate) {
          final activeMessages = await messageStore.loadActiveMessages();
          if (mounted) {
            setState(() {
              _messages
                ..clear()
                ..addAll(activeMessages)
                ..add(savedModelMessage);
            });
          }
        }
        if (!mounted) return;
        setState(() {
          _repliesNeedingSave[userMessage.id] = modelMessage;
          _retryErrors[userMessage.id] = appText(
            'Reply is ready, but could not be saved: {error}',
            values: {'error': error},
          );
          _isSending = false;
          _clearRegenerationState();
        });
        _showMessage(appText('Reply is ready. Tap retry to save it.'));
      }
      _scrollToLatest();
    } catch (error) {
      typewriterTimer?.cancel();
      if (replyService is GeminiReplyService) {
        replyService.discardConversationMemoryContext(responseMessageId);
      }
      String? cleanupError;
      try {
        final hasCommandActivities =
            _terminalActivitiesByResponse[responseMessageId]?.isNotEmpty ??
            _terminalActivitiesByResponse[userMessage.id]?.isNotEmpty ??
            false;
        if (!isRegenerate && !hasCommandActivities) {
          await messageStore.deleteMessage(userMessage.id);
        }
      } catch (deleteError) {
        cleanupError = deleteError.toString();
      }
      if (!mounted) return;
      setState(() {
        if (streamedMessage != null) {
          _messages.removeWhere((message) => message.id == streamedMessage!.id);
        }
        _clearRegenerationState();
        if (!isRegenerate) {
          _retryErrors[userMessage.id] = cleanupError == null
              ? appText('Request failed: {error}', values: {'error': error})
              : appText(
                  'Request failed: {error}. The SQL message was not removed: {cleanupError}',
                  values: {'error': error, 'cleanupError': cleanupError},
                );
        }

        _isSending = false;
      });
      _showMessage(
        isRegenerate
            ? appText('Regeneration failed: {error}', values: {'error': error})
            : cleanupError == null
            ? appText(
                'AI request failed: {error}. Tap retry beside the message to try again.',
                values: {'error': error},
              )
            : appText(
                'Request failed: {error}. The SQL message was not removed: {cleanupError}',
                values: {'error': error, 'cleanupError': cleanupError},
              ),
      );
    } finally {
      if (mounted && _activeReplyResponseMessageId == responseMessageId) {
        setState(() => _activeReplyResponseMessageId = null);
      }
    }
  }

  void _clearRegenerationState() {
    _regeneratingMessageId = null;
    _regeneratingUserMessageId = null;
    _streamingResponseMessageId = null;
  }

  ChatMessage _newMessage({
    required String role,
    required String content,
    String? parentMessageId,
    String? id,
  }) {
    final createdAtUtc = DateTime.now().toUtc().millisecondsSinceEpoch;
    return ChatMessage(
      id: id ?? _uuid.v4(),
      role: role,
      content: content,
      timestamp: formatJakartaTimestamp(createdAtUtc),
      createdAtUtc: createdAtUtc,
      parentMessageId: parentMessageId,
    );
  }

  void _scrollToLatest() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController
          .animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOut,
          )
          .whenComplete(() {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted || !_scrollController.hasClients) return;
              final position = _scrollController.position;
              if (position.extentAfter > 1) {
                _scrollController.jumpTo(position.maxScrollExtent);
              }
              _handleScroll();
            });
          });
    });
  }

  void _scrollToLatestDuringStreaming() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final position = _scrollController.position;
      if (_followLatestDuringStreaming && position.extentAfter > 1) {
        _scrollController.jumpTo(position.maxScrollExtent);
      }
      _handleScroll();
    });
  }

  void _scrollToInitialLatest() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scrollController.hasClients) {
        _settleScrollAtLatest(0);
      }
    });
  }

  void _settleScrollAtLatest(int attempt) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final position = _scrollController.position;
      if (position.extentAfter > 1 && attempt < 40) {
        _scrollController.jumpTo(position.maxScrollExtent);
        _settleScrollAtLatest(attempt + 1);
        return;
      }
      _handleScroll();
    });
  }

  void _handleScroll() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    final shouldShow = position.extentAfter > 80;
    if (_showScrollToBottom != shouldShow && mounted) {
      setState(() => _showScrollToBottom = shouldShow);
    }
  }

  void _handleUserScroll() {
    if (!_scrollController.hasClients) return;
    _followLatestDuringStreaming = _scrollController.position.extentAfter <= 80;
  }

  Future<void> _notifyWhenUnavailable(
    String message, {
    required String title,
  }) async {
    if (_applicationDetached || (_applicationForeground && _chatRoomVisible)) {
      return;
    }
    await (widget.notificationService ?? const DesktopNotificationService())
        .show(title: title, body: message);
  }

  void _showMessage(String message, {bool isError = true}) {
    if (isError) {
      unawaited(
        _notifyWhenUnavailable(message, title: appText('Sara desktop app')),
      );
    }
    _showToast(context, message, isError: isError, notifyDesktop: false);
  }

  Future<void> _openSettings() async {
    final messageStore = _messageStore;
    if (messageStore == null) {
      _showMessage(
        appText('Local chat storage is not ready. Please try again shortly.'),
      );
      return;
    }
    _chatRoomVisible = false;
    try {
      await showDialog<void>(
        context: context,
        builder: (context) => _SettingsDialog(
          configStore: widget.configStore,
          messageStore: messageStore,
          onClearChat: _clearChat,
          onExportBackup: _exportBackup,
          onImportBackup: _importBackup,
          isSending: _isSending,
          cameraEnabled: _cameraEnabled,
          onCameraChanged: _setCameraEnabled,
          saraCameraActive: _saraCameraActiveListenable,
          onStopSaraCamera: _stopCameraFromIndicator,
          onErrorNotification: (message) => unawaited(
            _notifyWhenUnavailable(message, title: appText('Sara desktop app')),
          ),
        ),
      );
    } finally {
      _chatRoomVisible = true;
    }
  }

  Future<void> _exportBackup() async {
    if (_isSending) {
      _showMessage(
        appText('Wait for Sara to finish replying before exporting a backup.'),
      );
      return;
    }
    final messageStore = _messageStore;
    if (messageStore == null) {
      _showMessage(
        appText('Local chat storage is not ready. Please try again shortly.'),
      );
      return;
    }
    try {
      final bytes = await SaraBackupService().createBackup(messageStore);
      final savedFile = await FilePicker.saveFile(
        fileName: 'Sara-backup.json',
        bytes: bytes,
        mimeType: 'application/json',
        dialogTitle: appText('Export Sara backup'),
      );
      if (savedFile != null && mounted) {
        _showMessage(appText('Backup exported successfully.'), isError: false);
      }
    } catch (error) {
      if (mounted) {
        _showMessage(
          appText('Could not export backup: {error}', values: {'error': error}),
        );
      }
    }
  }

  Future<void> _importBackup() async {
    if (_isSending) {
      _showMessage(
        appText('Wait for Sara to finish replying before importing a backup.'),
      );
      return;
    }
    final messageStore = _messageStore;
    if (messageStore == null) {
      _showMessage(
        appText('Local chat storage is not ready. Please try again shortly.'),
      );
      return;
    }
    var backupRestored = false;
    try {
      final selectedFiles = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['json'],
        dialogTitle: appText('Import Sara backup'),
      );
      if (selectedFiles.isEmpty || !mounted) return;
      final backupPath = selectedFiles.single.path;
      if (backupPath == null) {
        throw const FormatException('Could not read the selected backup file.');
      }
      final backupBytes = await File(backupPath).readAsBytes();
      if (!mounted) return;
      final shouldImport = await _showIosConfirmation(
        context: context,
        title: appText('Replace local data?'),
        message: appText(
          'Importing this backup replaces all local conversation data and personal name. Your Gemini API keys stay unchanged.',
        ),
        cancelLabel: appText('Cancel'),
        confirmLabel: appText('Import backup'),
        destructive: true,
      );
      if (shouldImport != true || !mounted) return;

      final restoreResult = await SaraBackupService().restoreBackup(
        messageStore,
        Uint8List.fromList(backupBytes),
      );
      backupRestored = true;
      final history = await messageStore.loadActiveMessages();
      final attachments = await messageStore.loadAttachments();
      final feedback = await messageStore.loadAssistantFeedback();
      final reactions = await messageStore.loadAssistantReactions();
      final branches = await messageStore.loadMessageBranches();
      if (!mounted) return;
      setState(() {
        _messages
          ..clear()
          ..addAll(history);
        _attachmentsByMessage
          ..clear()
          ..addAll(attachments);
        _assistantFeedback
          ..clear()
          ..addAll(feedback);
        _assistantReactions
          ..clear()
          ..addAll(reactions);
        _messageBranches = branches;
        _repliesNeedingSave.clear();
        _messagesNeedingOnlySave.clear();
        _retryErrors.clear();
      });
      if (history.isNotEmpty) _scrollToInitialLatest();
      _showMessage(appText('Backup imported successfully.'), isError: false);
      if (restoreResult.cleanupErrors.isNotEmpty) {
        _showMessage(
          appText(
            'Attachment cleanup failed after backup import: {error}',
            values: {'error': restoreResult.cleanupErrors.join('\n')},
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        _showMessage(
          appText(
            backupRestored
                ? 'Backup was imported, but chat could not be refreshed: {error}'
                : 'Could not import backup: {error}',
            values: {'error': error},
          ),
        );
      }
    }
  }

  Future<void> _clearChat() async {
    if (_isSending) {
      _showMessage(
        appText('Wait for Sara to finish replying before clearing the chat.'),
      );
      return;
    }
    final messageStore = _messageStore;
    if (messageStore == null) {
      _showMessage(
        appText('Local chat storage is not ready. Please try again shortly.'),
      );
      return;
    }
    final clipboardAttachments = _attachmentsByMessage.values
        .expand((attachments) => attachments)
        .where((attachment) => attachment.isClipboardCopy)
        .toList(growable: false);
    try {
      await messageStore.clearMessages();
    } catch (error) {
      if (!mounted) return;
      _showMessage(
        appText('Could not delete chat: {error}', values: {'error': error}),
      );
      return;
    }

    if (mounted) {
      setState(() {
        _messages.clear();
        _messageBranches = {};
        _repliesNeedingSave.clear();
        _messagesNeedingOnlySave.clear();
        _retryErrors.clear();
        _attachmentsByMessage.clear();
        _assistantFeedback.clear();
        _assistantReactions.clear();
        _terminalActivitiesByResponse.clear();
      });
    }
    try {
      await _deleteClipboardAttachmentFiles(clipboardAttachments);
      if (mounted) {
        _showMessage(appText('Chat deleted successfully.'), isError: false);
      }
    } catch (error) {
      if (!mounted) return;
      _showMessage(
        appText(
          'Chat cleared, but copied attachment cleanup failed: {error}',
          values: {'error': error},
        ),
      );
    }
  }

  Future<void> _deleteClipboardAttachmentFiles(
    List<ChatAttachment> attachments,
  ) async {
    final paths = attachments
        .map((attachment) => attachment.path)
        .whereType<String>()
        .toSet();
    if (paths.isEmpty) return;

    final supportDirectory = await getApplicationSupportDirectory();
    final cacheDirectory = await getApplicationCacheDirectory();
    final clipboardDirectory = path.normalize(
      path.absolute(
        path.join(supportDirectory.path, 'Sara', 'clipboard-attachments'),
      ),
    );
    final cameraDirectory = path.normalize(
      path.absolute(
        path.join(cacheDirectory.path, 'Sara', 'camera-attachments'),
      ),
    );
    final legacyCameraDirectory = path.normalize(
      path.absolute(
        path.join(supportDirectory.path, 'Sara', 'camera-attachments'),
      ),
    );
    final failures = <String>[];
    for (final filePath in paths) {
      final absoluteFilePath = path.normalize(path.absolute(filePath));
      if (!path.isWithin(clipboardDirectory, absoluteFilePath) &&
          !path.isWithin(cameraDirectory, absoluteFilePath) &&
          !path.isWithin(legacyCameraDirectory, absoluteFilePath)) {
        failures.add(
          '$filePath: refusing to delete a file outside app-managed folders',
        );
        continue;
      }
      try {
        final file = File(absoluteFilePath);
        if (await file.exists()) await file.delete();
      } catch (error) {
        failures.add('$filePath: $error');
      }
    }
    if (failures.isNotEmpty) {
      throw StateError(failures.join('\n'));
    }
  }

  @override
  Widget build(BuildContext context) {
    var visibleMessages = _messages;
    final regeneratingUserId = _regeneratingUserMessageId;
    if (regeneratingUserId != null) {
      final userIndex = _messages.indexWhere(
        (message) => message.id == regeneratingUserId,
      );
      if (userIndex >= 0) {
        final streamingId = _streamingResponseMessageId;
        visibleMessages = [
          ..._messages.take(userIndex + 1),
          if (streamingId != null && streamingId != _regeneratingMessageId)
            ..._messages.where((message) => message.id == streamingId),
        ];
      }
    }
    final activeResponseId = _activeReplyResponseMessageId;
    if (activeResponseId != null &&
        !visibleMessages.any((message) => message.id == activeResponseId) &&
        (_terminalActivitiesByResponse[activeResponseId]?.isNotEmpty ??
            false)) {
      final parent = visibleMessages.reversed.cast<ChatMessage?>().firstWhere(
        (message) => message?.role == 'user',
        orElse: () => null,
      );
      if (parent != null) {
        final createdAtUtc = DateTime.now().toUtc().millisecondsSinceEpoch;
        visibleMessages = [
          ...visibleMessages,
          ChatMessage(
            id: activeResponseId,
            role: 'model',
            content: '',
            timestamp: formatJakartaTimestamp(createdAtUtc),
            createdAtUtc: createdAtUtc,
            parentMessageId: parent.id,
          ),
        ];
      }
    }
    ChatMessage? selectedSearchMessage;
    for (final message in visibleMessages) {
      if (message.id == _searchResultsMessageId) {
        selectedSearchMessage = message;
        break;
      }
    }
    final selectedSearchSources = selectedSearchMessage == null
        ? const <_SearchResultSource>[]
        : _messageResultSources(selectedSearchMessage.content);
    final showSearchResultsPanel = selectedSearchSources.length >= 2;
    final selectedSearchDate = selectedSearchMessage == null
        ? ''
        : _searchResultDate(selectedSearchMessage.createdAtUtc);
    final showInlineSettings =
        MediaQuery.sizeOf(context).width < 680 && !showSearchResultsPanel;
    return Scaffold(
      backgroundColor: _canvas,
      body: SafeArea(
        child: Column(
          children: [
            if (Platform.isLinux) const _LinuxWindowTitleBar(),
            Expanded(
              child: DropTarget(
                key: const ValueKey('room-file-drop-target'),
                onDragEntered: (_) => setState(() => _isDraggingFiles = true),
                onDragExited: (_) {
                  if (mounted) setState(() => _isDraggingFiles = false);
                },
                onDragDone: (details) {
                  setState(() => _isDraggingFiles = false);
                  _composerKey.currentState?.addDroppedFiles(details.files);
                },
                child: ColoredBox(
                  color: _canvas,
                  child: Stack(
                    children: [
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        height: 24,
                        child: IgnorePointer(
                          child: ColoredBox(
                            key: const ValueKey('footer-bottom-background'),
                            color: _canvas,
                          ),
                        ),
                      ),
                      Positioned.fill(
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final panelWidth = constraints.maxWidth < 800
                                ? constraints.maxWidth * 0.42
                                : 390.0;
                            return Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    children: [
                                      Expanded(
                                        child: _isLoadingHistory
                                            ? const Center(
                                                child:
                                                    CircularProgressIndicator(),
                                              )
                                            : visibleMessages.isEmpty
                                            ? const _WelcomeView()
                                            : ListenableBuilder(
                                                listenable: Listenable.merge([
                                                  _speechPlaybackController
                                                      .speakingMessageId,
                                                  _speechPlaybackController
                                                      .loadingMessageId,
                                                ]),
                                                builder: (context, _) => _ConversationView(
                                                  messages: visibleMessages,
                                                  scrollController:
                                                      _scrollController,
                                                  isSending: _isSending,
                                                  showReplyIndicator:
                                                      _isSending &&
                                                      !_hasStreamedReply,
                                                  retryErrors: _retryErrors,
                                                  onRetryMessage: _retryMessage,
                                                  onDeleteMessage:
                                                      _deleteMessageAndFollowing,
                                                  onEditMessage:
                                                      _submitEditedMessage,
                                                  onProactiveModeChanged:
                                                      _recordConversationProactiveMode,
                                                  messageBranches:
                                                      _messageBranches,
                                                  onActivateBranch:
                                                      _activateMessageBranch,
                                                  onRegenerateMessage:
                                                      _regenerateMessage,
                                                  attachmentsByMessage:
                                                      _attachmentsByMessage,
                                                  terminalActivitiesByResponse:
                                                      _terminalActivitiesByResponse,
                                                  activeReplyResponseMessageId:
                                                      _activeReplyResponseMessageId,
                                                  assistantFeedback:
                                                      _assistantFeedback,
                                                  onSetAssistantFeedback:
                                                      _setAssistantFeedback,
                                                  assistantReactions:
                                                      _assistantReactions,
                                                  onSetAssistantReaction:
                                                      _setAssistantReaction,
                                                  speakingMessageId:
                                                      _speechPlaybackController
                                                          .speakingMessageId
                                                          .value,
                                                  loadingSpeechMessageId:
                                                      _speechPlaybackController
                                                          .loadingMessageId
                                                          .value,
                                                  onToggleSpeech: _toggleSpeech,
                                                  showScrollToBottom:
                                                      _showScrollToBottom,
                                                  onScrollToBottom:
                                                      _scrollToLatest,
                                                  onScrollMetricsChanged:
                                                      _handleScroll,
                                                  onUserScroll:
                                                      _handleUserScroll,
                                                  onShowSearchResults:
                                                      (
                                                        messageId,
                                                      ) => setState(() {
                                                        _searchResultsMessageId =
                                                            messageId;
                                                      }),
                                                ),
                                              ),
                                      ),
                                      ConstrainedBox(
                                        constraints: BoxConstraints(
                                          maxHeight: constraints.maxHeight,
                                        ),
                                        child: _Composer(
                                          key: _composerKey,
                                          controller: _messageController,
                                          focusNode: _messageFocus,
                                          onSend: _sendMessage,
                                          onModeChanged:
                                              _recordConversationProactiveMode,
                                          isWaitingForReply:
                                              _isSending && !_hasStreamedReply,
                                          showInlineSettings:
                                              showInlineSettings,
                                          onOpenSettings: _openSettings,
                                          clipboardImageReader:
                                              widget.clipboardImageReader,
                                          clipboardImageSaver:
                                              widget.clipboardImageSaver,
                                          cameraSessionFactory:
                                              widget.cameraSessionFactory,
                                          cameraImageSaver:
                                              widget.cameraImageSaver,
                                          pendingTerminalCommandApproval:
                                              _pendingTerminalCommandApproval,
                                          terminalCommandActivity:
                                              _terminalCommandActivity,
                                          terminalCommandOutput: [
                                            if (_terminalCommandStdout
                                                .isNotEmpty)
                                              _terminalCommandStdout,
                                            if (_terminalCommandStderr
                                                .isNotEmpty)
                                              'stderr:\n$_terminalCommandStderr',
                                          ].join('\n'),
                                          terminalCommandRunning:
                                              _terminalCommandRunning,
                                          terminalCommandAutomaticallyAllowed:
                                              _terminalCommandAutomaticallyAllowed,
                                          onTerminalCommandDecision:
                                              _decideTerminalCommand,
                                          onStopTerminalCommand:
                                              _stopTerminalCommand,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                AnimatedContainer(
                                  duration: const Duration(milliseconds: 220),
                                  curve: Curves.easeInOut,
                                  width: showSearchResultsPanel
                                      ? panelWidth
                                      : 0,
                                  child: showSearchResultsPanel
                                      ? _SearchResultsPanel(
                                          sources: selectedSearchSources,
                                          messageDate: selectedSearchDate,
                                          onClose: () => setState(
                                            () =>
                                                _searchResultsMessageId = null,
                                          ),
                                          onOpen: _openSearchResultLink,
                                        )
                                      : const SizedBox.shrink(),
                                ),
                              ],
                            );
                          },
                        ),
                      ),
                      if (!showInlineSettings)
                        Positioned(
                          right: 18,
                          bottom: 14,
                          child: Material(
                            color: _surfaceRaised,
                            shape: const CircleBorder(),
                            elevation: 3,
                            child: IconButton(
                              tooltip: appText('Settings'),
                              onPressed: _openSettings,
                              icon: const Icon(LucideIcons300.settings),
                              color: _muted,
                            ),
                          ),
                        ),
                      if (_saraCameraActive)
                        Positioned(
                          top: 10,
                          left: 0,
                          right: 0,
                          child: Center(
                            child: Material(
                              key: const ValueKey(
                                'sara-camera-active-indicator',
                              ),
                              color: const Color(0xF02B303A),
                              borderRadius: BorderRadius.circular(20),
                              child: Padding(
                                padding: const EdgeInsets.only(
                                  left: 12,
                                  right: 4,
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(
                                      LucideIcons300.video,
                                      size: 17,
                                      color: Color(0xFFFF8585),
                                    ),
                                    const SizedBox(width: 7),
                                    Text(
                                      appText(
                                        'Sara is looking through the camera',
                                      ),
                                      style: const TextStyle(
                                        color: _text,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                    const SizedBox(width: 5),
                                    IconButton(
                                      key: const ValueKey('stop-sara-camera'),
                                      tooltip: appText('Stop camera access'),
                                      onPressed: _stopCameraFromIndicator,
                                      icon: const Icon(LucideIcons300.x),
                                      color: _muted,
                                      iconSize: 16,
                                      visualDensity: VisualDensity.compact,
                                      constraints:
                                          const BoxConstraints.tightFor(
                                            width: 28,
                                            height: 28,
                                          ),
                                      padding: EdgeInsets.zero,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      if (_isDraggingFiles)
                        Positioned.fill(
                          child: IgnorePointer(
                            child: Container(
                              margin: const EdgeInsets.all(14),
                              decoration: BoxDecoration(
                                color: const Color(0x332D5798),
                                border: Border.all(color: _accent, width: 2),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Center(
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: _surfaceRaised,
                                    borderRadius: BorderRadius.all(
                                      Radius.circular(14),
                                    ),
                                  ),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 20,
                                      vertical: 14,
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const Icon(
                                          LucideIcons300.upload,
                                          color: _accent,
                                        ),
                                        const SizedBox(width: 10),
                                        Text(
                                          appText(
                                            'Drop files or media here to attach',
                                          ),
                                          style: const TextStyle(
                                            color: _text,
                                            fontSize: 13,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LinuxWindowTitleBar extends StatefulWidget {
  const _LinuxWindowTitleBar();

  @override
  State<_LinuxWindowTitleBar> createState() => _LinuxWindowTitleBarState();
}

class _LinuxWindowTitleBarState extends State<_LinuxWindowTitleBar> {
  static const _windowChannel = MethodChannel('personal.sara/window');

  bool _isMaximized = false;

  Future<void> _runWindowAction(
    String action, {
    Map<String, Object?>? arguments,
  }) async {
    try {
      final maximized = await _windowChannel.invokeMethod<bool>(
        action,
        arguments,
      );
      if (action == 'toggleMaximize' && maximized != null && mounted) {
        setState(() => _isMaximized = maximized);
      }
    } catch (error) {
      debugPrint('Could not $action Sara window: $error');
    }
  }

  void _startDragging(DragStartDetails details) {
    unawaited(
      _runWindowAction(
        'startDragging',
        arguments: {
          'x': details.globalPosition.dx.round(),
          'y': details.globalPosition.dy.round(),
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF24262A),
      child: Container(
        key: const ValueKey('linux-window-title-bar'),
        height: 36,
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: Color(0xFF34363B))),
        ),
        child: Row(
          children: [
            const SizedBox(width: 10),
            Image.asset(
              'assets/flutter_logo.png',
              key: const ValueKey('linux-window-app-icon'),
              width: 27,
              height: 27,
              fit: BoxFit.contain,
              filterQuality: FilterQuality.medium,
            ),
            const SizedBox(width: 8),
            const Text(
              'Sara',
              style: TextStyle(
                color: Color(0xFFE6E8EB),
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanStart: _startDragging,
                onDoubleTap: () =>
                    unawaited(_runWindowAction('toggleMaximize')),
                child: MouseRegion(
                  cursor: SystemMouseCursors.move,
                  child: Center(
                    child: Text(
                      appText('Personal AI Chat'),
                      style: const TextStyle(
                        color: Color(0xFFB6BAC2),
                        fontSize: 12,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            _LinuxWindowControl(
              key: const ValueKey('linux-window-minimize'),
              icon: _WindowControlIcon.minimize,
              onPressed: () => unawaited(_runWindowAction('minimize')),
              height: 36,
            ),
            _LinuxWindowControl(
              key: const ValueKey('linux-window-maximize'),
              icon: _isMaximized
                  ? _WindowControlIcon.restore
                  : _WindowControlIcon.maximize,
              onPressed: () => unawaited(_runWindowAction('toggleMaximize')),
              height: 36,
            ),
            _LinuxWindowControl(
              key: const ValueKey('linux-window-close'),
              icon: _WindowControlIcon.close,
              hoverColor: const Color(0xFFC42B1C),
              onPressed: () => unawaited(_runWindowAction('close')),
              height: 36,
            ),
          ],
        ),
      ),
    );
  }
}

enum _WindowControlIcon { minimize, maximize, restore, close }

class _LinuxWindowControl extends StatefulWidget {
  const _LinuxWindowControl({
    super.key,
    required this.icon,
    required this.onPressed,
    this.hoverColor = const Color(0xFF3A3C41),
    required this.height,
  });

  final _WindowControlIcon icon;
  final VoidCallback onPressed;
  final Color hoverColor;
  final double height;

  @override
  State<_LinuxWindowControl> createState() => _LinuxWindowControlState();
}

class _LinuxWindowControlState extends State<_LinuxWindowControl> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 42,
      height: widget.height,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          child: ColoredBox(
            color: _hovered ? widget.hoverColor : Colors.transparent,
            child: Center(
              child: CustomPaint(
                key: ValueKey('window-control-icon-${widget.icon.name}'),
                size: const Size.square(14),
                painter: _WindowControlPainter(
                  widget.icon,
                  _hovered ? widget.hoverColor : const Color(0xFF24262A),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _WindowControlPainter extends CustomPainter {
  const _WindowControlPainter(this.icon, this.backgroundColor);

  final _WindowControlIcon icon;
  final Color backgroundColor;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFFD4D7DC)
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.square
      ..style = PaintingStyle.stroke;

    switch (icon) {
      case _WindowControlIcon.minimize:
        canvas.drawLine(
          Offset(2.5, size.height / 2),
          Offset(size.width - 2.5, size.height / 2),
          paint,
        );
      case _WindowControlIcon.maximize:
        final path = Path()
          ..moveTo(5, 2.5)
          ..lineTo(2.5, 2.5)
          ..lineTo(2.5, 5)
          ..moveTo(size.width - 5, 2.5)
          ..lineTo(size.width - 2.5, 2.5)
          ..lineTo(size.width - 2.5, 5)
          ..moveTo(2.5, size.height - 5)
          ..lineTo(2.5, size.height - 2.5)
          ..lineTo(5, size.height - 2.5)
          ..moveTo(size.width - 5, size.height - 2.5)
          ..lineTo(size.width - 2.5, size.height - 2.5)
          ..lineTo(size.width - 2.5, size.height - 5);
        canvas.drawPath(path, paint);
      case _WindowControlIcon.restore:
        final rear = Rect.fromLTWH(5, 2, 7, 7);
        final front = Rect.fromLTWH(2, 5, 8, 8);
        canvas.drawRect(rear, paint);
        canvas.drawRect(
          front,
          Paint()
            ..color = backgroundColor
            ..style = PaintingStyle.fill,
        );
        canvas.drawRect(front, paint);
      case _WindowControlIcon.close:
        canvas.drawLine(
          const Offset(3, 3),
          Offset(size.width - 3, size.height - 3),
          paint,
        );
        canvas.drawLine(
          Offset(size.width - 3, 3),
          Offset(3, size.height - 3),
          paint,
        );
    }
  }

  @override
  bool shouldRepaint(_WindowControlPainter oldDelegate) =>
      icon != oldDelegate.icon ||
      backgroundColor != oldDelegate.backgroundColor;
}

class _SettingsDialog extends StatefulWidget {
  const _SettingsDialog({
    required this.configStore,
    required this.messageStore,
    required this.onClearChat,
    required this.onExportBackup,
    required this.onImportBackup,
    required this.isSending,
    required this.cameraEnabled,
    required this.onCameraChanged,
    required this.saraCameraActive,
    required this.onStopSaraCamera,
    required this.onErrorNotification,
  });

  final AiConfigStore configStore;
  final MessageStore messageStore;
  final Future<void> Function() onClearChat;
  final Future<void> Function() onExportBackup;
  final Future<void> Function() onImportBackup;
  final bool isSending;
  final bool cameraEnabled;
  final Future<void> Function(bool enabled) onCameraChanged;
  final ValueListenable<bool> saraCameraActive;
  final VoidCallback onStopSaraCamera;
  final void Function(String message) onErrorNotification;

  @override
  State<_SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<_SettingsDialog> {
  int _section = 0;
  final _personalNameController = TextEditingController();
  final _apiKeyController = TextEditingController();
  final _tavilyApiKeyController = TextEditingController();
  final _tinyFishApiKeyController = TextEditingController();
  final _firecrawlApiKeyController = TextEditingController();
  String _modelName = _defaultModel;
  List<String> _apiKeys = [];
  bool _webSearchEnabled = false;
  bool _isSavingWebSearchConfig = false;
  bool _isLoadingPersonal = true;
  bool _isSavingPersonal = false;
  bool _isLoadingAiConfig = true;
  bool _isSavingAiConfig = false;
  bool _isBackingUpData = false;
  bool _showConfigureHelp = false;
  late bool _cameraEnabled;

  @override
  void initState() {
    super.initState();
    _cameraEnabled = widget.cameraEnabled;
    _loadAiConfig();
    _loadPersonal();
  }

  Future<void> _setCameraEnabled(bool enabled) async {
    final previous = _cameraEnabled;
    setState(() => _cameraEnabled = enabled);
    try {
      await widget.onCameraChanged(enabled);
    } catch (error) {
      if (mounted) setState(() => _cameraEnabled = previous);
      _showMessage(
        appText(
          'Could not update Sara’s camera access setting: {error}',
          values: {'error': error},
        ),
      );
    }
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    _tavilyApiKeyController.dispose();
    _tinyFishApiKeyController.dispose();
    _firecrawlApiKeyController.dispose();
    _personalNameController.dispose();
    super.dispose();
  }

  Future<void> _loadPersonal() async {
    try {
      final name = await widget.messageStore.readPersonalName();
      if (!mounted) return;
      setState(() {
        _personalNameController.text = name ?? '';
        _isLoadingPersonal = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _isLoadingPersonal = false);
      _showMessage(
        appText(
          'Error reading personal data: {error}',
          values: {'error': error},
        ),
      );
    }
  }

  Future<void> _savePersonal() async {
    final name = _personalNameController.text.trim();
    setState(() => _isSavingPersonal = true);
    try {
      if (name.isEmpty) {
        await widget.messageStore.clearPersonalName();
      } else {
        await widget.messageStore.writePersonalName(name);
      }
      if (!mounted) return;
      setState(() => _isSavingPersonal = false);
      _showMessage(
        appText(name.isEmpty ? 'Personal name removed.' : 'Name saved.'),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _isSavingPersonal = false);
      _showMessage(
        appText(
          'Could not save personal name: {error}',
          values: {'error': error},
        ),
      );
    }
  }

  Future<void> _setLanguage(AppLanguage language) async {
    try {
      await AppLanguageController.set(language);
    } catch (error) {
      _showMessage(
        appText(
          'Could not save selected language: {error}',
          values: {'error': error},
        ),
      );
    }
  }

  Future<void> _confirmClearChat() async {
    final shouldClear = await _showIosConfirmation(
      context: context,
      title: appText('Clear chat?'),
      message: appText('All chat messages will be permanently deleted.'),
      cancelLabel: appText('Cancel'),
      confirmLabel: appText('Clear chat'),
      destructive: true,
    );
    if (shouldClear == true) await widget.onClearChat();
  }

  Future<void> _runBackupAction(
    Future<void> Function() action, {
    bool reloadPersonal = false,
  }) async {
    if (_isBackingUpData) return;
    setState(() => _isBackingUpData = true);
    try {
      await action();
      if (mounted && reloadPersonal) await _loadPersonal();
    } finally {
      if (mounted) setState(() => _isBackingUpData = false);
    }
  }

  Future<void> _loadAiConfig() async {
    try {
      final provider = await widget.configStore.read(_providerStorageKey);
      final model = await widget.configStore.read(_modelStorageKey);
      final apiKeys = await widget.configStore.readApiKeys();
      final webSearchEnabled = await widget.configStore.read(
        WebSearchConfigKeys.enabled,
      );
      final tavilyApiKey = await widget.configStore.read(
        WebSearchConfigKeys.tavilyApiKey,
      );
      final tinyFishApiKey = await widget.configStore.read(
        WebSearchConfigKeys.tinyFishApiKey,
      );
      final firecrawlApiKey = await widget.configStore.read(
        WebSearchConfigKeys.firecrawlApiKey,
      );
      if (!mounted) return;
      setState(() {
        _modelName = model ?? _defaultModel;
        _apiKeys = apiKeys;
        _webSearchEnabled = webSearchEnabled == 'true';
        _tavilyApiKeyController.text = tavilyApiKey ?? '';
        _tinyFishApiKeyController.text = tinyFishApiKey ?? '';
        _firecrawlApiKeyController.text = firecrawlApiKey ?? '';
        _isLoadingAiConfig = false;
      });
      if (provider != null && provider != 'Gemini') {
        _showMessage(appText('Unknown saved provider. Using Gemini.'));
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _isLoadingAiConfig = false);
      _showMessage(
        appText(
          'Could not read AI settings from the keyring: {error}',
          values: {'error': error},
        ),
      );
    }
  }

  void _onWebSearchEnabledChanged(bool enabled) {
    setState(() => _webSearchEnabled = enabled);
  }

  Future<void> _saveWebSearchConfig() async {
    final tavilyApiKey = _tavilyApiKeyController.text.trim();
    final tinyFishApiKey = _tinyFishApiKeyController.text.trim();
    final firecrawlApiKey = _firecrawlApiKeyController.text.trim();
    if (_webSearchEnabled && tavilyApiKey.isEmpty && tinyFishApiKey.isEmpty) {
      _showMessage(
        appText('Add a Tavily or TinyFish API key to enable web search.'),
      );
      return;
    }

    setState(() => _isSavingWebSearchConfig = true);
    try {
      await _writeOptionalSecret(
        WebSearchConfigKeys.tavilyApiKey,
        tavilyApiKey,
      );
      await _writeOptionalSecret(
        WebSearchConfigKeys.tinyFishApiKey,
        tinyFishApiKey,
      );
      await _writeOptionalSecret(
        WebSearchConfigKeys.firecrawlApiKey,
        firecrawlApiKey,
      );
      await widget.configStore.write(
        WebSearchConfigKeys.enabled,
        _webSearchEnabled.toString(),
      );
      if (!mounted) return;
      setState(() => _isSavingWebSearchConfig = false);
      _showMessage(appText('Web search settings saved.'), isError: false);
    } catch (error) {
      if (!mounted) return;
      setState(() => _isSavingWebSearchConfig = false);
      _showMessage(
        appText(
          'Could not save web search settings: {error}',
          values: {'error': error},
        ),
      );
    }
  }

  Future<void> _writeOptionalSecret(String key, String value) async {
    if (value.isEmpty) {
      await widget.configStore.delete(key);
    } else {
      await widget.configStore.write(key, value);
    }
  }

  Future<void> _saveAiConfig() async {
    final apiKey = _apiKeyController.text.trim();
    if (apiKey.isEmpty) {
      _showMessage(appText('Enter an API key to add.'));
      return;
    }
    if (apiKey.isNotEmpty && _apiKeys.contains(apiKey)) {
      _showMessage(appText('That API key has already been added.'));
      return;
    }

    final updatedKeys = apiKey.isEmpty ? _apiKeys : [..._apiKeys, apiKey];
    setState(() => _isSavingAiConfig = true);
    try {
      await widget.configStore.writeApiKeys(updatedKeys);
      if (!mounted) return;
      setState(() {
        _apiKeys = updatedKeys;
        _apiKeyController.clear();
        _isSavingAiConfig = false;
      });
      _showMessage(
        appText('Gemini API key added to the desktop keyring.'),
        isError: false,
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _isSavingAiConfig = false);
      _showMessage(
        appText(
          'Could not save Gemini settings: {error}',
          values: {'error': error},
        ),
      );
    }
  }

  Future<void> _removeApiKey(int index) async {
    if (index < 0 || index >= _apiKeys.length) return;
    setState(() => _isSavingAiConfig = true);
    try {
      final updatedKeys = [..._apiKeys]..removeAt(index);
      await widget.configStore.writeApiKeys(updatedKeys);
      if (!mounted) return;
      setState(() {
        _apiKeys = updatedKeys;
        _apiKeyController.clear();
        _isSavingAiConfig = false;
      });
      _showMessage(
        appText('Gemini API key removed from the desktop keyring.'),
        isError: false,
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _isSavingAiConfig = false);
      _showMessage(
        appText(
          'Could not remove Gemini API key: {error}',
          values: {'error': error},
        ),
      );
    }
  }

  Future<void> _confirmRemoveApiKey(int index) async {
    if (index < 0 || index >= _apiKeys.length) return;
    final shouldRemove = await _showIosConfirmation(
      context: context,
      title: appText('Remove API key?'),
      message: appText(
        'This API key will be removed from the desktop keyring.',
      ),
      cancelLabel: appText('Cancel'),
      confirmLabel: appText('Remove key'),
      destructive: true,
    );
    if (shouldRemove == true && mounted) await _removeApiKey(index);
  }

  Future<void> _openGoogleAiStudio() async {
    try {
      final result = await Process.run('xdg-open', [
        'https://aistudio.google.com/app/apikey',
      ]);
      if (result.exitCode != 0) {
        throw ProcessException(
          'xdg-open',
          ['https://aistudio.google.com/app/apikey'],
          result.stderr.toString(),
          result.exitCode,
        );
      }
    } catch (error) {
      _showMessage(
        appText(
          'Could not open Google AI Studio: {error}',
          values: {'error': error},
        ),
      );
    }
  }

  void _showMessage(String message, {bool isError = true}) {
    if (isError) widget.onErrorNotification(message);
    _showToast(context, message, isError: isError, notifyDesktop: false);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF24262A),
      insetPadding: const EdgeInsets.all(24),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: Color(0xFF3A3E47)),
      ),
      child: SizedBox(
        width: 920,
        height: 680,
        child: Column(
          children: [
            Container(
              height: 68,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              color: const Color(0xFF2B2D31),
              child: Row(
                children: [
                  _MacWindowControls(
                    onClose: () => Navigator.of(context).pop(),
                  ),
                  const SizedBox(width: 20),
                  Text(
                    appText('Settings'),
                    style: TextStyle(
                      color: _text,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  const Icon(
                    LucideIcons300.slidersHorizontal,
                    color: _muted,
                    size: 17,
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: appText('Close settings'),
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(LucideIcons300.x, size: 18),
                    color: _muted,
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: _border),
            Expanded(
              child: Row(
                children: [
                  Container(
                    width: 204,
                    color: const Color(0xFF202225),
                    padding: const EdgeInsets.fromLTRB(14, 20, 12, 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(10, 0, 0, 10),
                          child: Text(
                            appText('PREFERENCES'),
                            style: const TextStyle(
                              color: _muted,
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1,
                            ),
                          ),
                        ),
                        _SettingsNavItem(
                          icon: const Icon(LucideIcons300.userRound),
                          label: appText('Personal'),
                          selected: _section == 0,
                          onTap: () => setState(() => _section = 0),
                        ),
                        const SizedBox(height: 5),
                        _SettingsNavItem(
                          key: const ValueKey('settings-nav-configure'),
                          icon: const Icon(LucideIcons300.slidersHorizontal),
                          label: appText('Configure'),
                          selected: _section == 1,
                          onTap: () => setState(() {
                            _section = 1;
                            _showConfigureHelp = false;
                          }),
                        ),
                        const SizedBox(height: 5),
                        _SettingsNavItem(
                          icon: const _DatabaseStackIcon(size: 18),
                          label: appText('Data'),
                          selected: _section == 2,
                          onTap: () => setState(() => _section = 2),
                        ),
                        const Spacer(),
                        Container(
                          key: const ValueKey('developer-brand-banner'),
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(color: Colors.transparent),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text(
                                'From',
                                style: TextStyle(
                                  color: _muted,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              const SizedBox(height: 4),
                              ColorFiltered(
                                colorFilter: const ColorFilter.mode(
                                  Colors.white,
                                  BlendMode.srcIn,
                                ),
                                child: Image.asset(
                                  'assets/brand.png',
                                  key: const ValueKey('developer-brand-logo'),
                                  width: 140,
                                  fit: BoxFit.contain,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const VerticalDivider(width: 1, color: _border),
                  Expanded(
                    child: Container(
                      key: const ValueKey('settings-content-panel'),
                      color: const Color(0xFF24262A),
                      padding: const EdgeInsets.fromLTRB(26, 22, 26, 22),
                      child: Align(
                        alignment: Alignment.topLeft,
                        child: switch (_section) {
                          0 => SingleChildScrollView(
                            child: _PersonalSettings(
                              nameController: _personalNameController,
                              isLoading: _isLoadingPersonal,
                              isSaving: _isSavingPersonal,
                              onSave: _savePersonal,
                              onLanguageChanged: _setLanguage,
                            ),
                          ),
                          1 => _ConfigureSettings(
                            showHelp: _showConfigureHelp,
                            onToggleHelp: () => setState(
                              () => _showConfigureHelp = !_showConfigureHelp,
                            ),
                            onOpenGoogleAiStudio: _openGoogleAiStudio,
                            aiApiSettings: _AiApiSettings(
                              modelName: _modelName,
                              apiKeyController: _apiKeyController,
                              apiKeys: _apiKeys,
                              webSearchEnabled: _webSearchEnabled,
                              tavilyApiKeyController: _tavilyApiKeyController,
                              tinyFishApiKeyController:
                                  _tinyFishApiKeyController,
                              firecrawlApiKeyController:
                                  _firecrawlApiKeyController,
                              isLoading: _isLoadingAiConfig,
                              isSaving: _isSavingAiConfig,
                              isSavingWebSearch: _isSavingWebSearchConfig,
                              onSave: _saveAiConfig,
                              onWebSearchEnabledChanged:
                                  _onWebSearchEnabledChanged,
                              onSaveWebSearch: _saveWebSearchConfig,
                              onRemoveApiKey: _confirmRemoveApiKey,
                            ),
                          ),
                          _ => SingleChildScrollView(
                            child: _DataSettings(
                              onClearChat: _confirmClearChat,
                              onExportBackup: () =>
                                  _runBackupAction(widget.onExportBackup),
                              onImportBackup: () => _runBackupAction(
                                widget.onImportBackup,
                                reloadPersonal: true,
                              ),
                              isBusy: widget.isSending || _isBackingUpData,
                              isSending: widget.isSending,
                              cameraEnabled: _cameraEnabled,
                              onCameraChanged: _setCameraEnabled,
                              saraCameraActive: widget.saraCameraActive,
                              onStopSaraCamera: widget.onStopSaraCamera,
                            ),
                          ),
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MacWindowControls extends StatelessWidget {
  const _MacWindowControls({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    const colors = [Color(0xFFFF5F57), Color(0xFFFFBD2E), Color(0xFF28C840)];
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var index = 0; index < colors.length; index++) ...[
          if (index > 0) const SizedBox(width: 8),
          Material(
            color: colors[index],
            shape: const CircleBorder(),
            child: InkWell(
              key: ValueKey('mac-window-control-$index'),
              onTap: index == 0 ? onClose : null,
              customBorder: const CircleBorder(),
              child: const SizedBox(width: 12, height: 12),
            ),
          ),
        ],
      ],
    );
  }
}

class _DatabaseStackIcon extends StatelessWidget {
  const _DatabaseStackIcon({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.square(size),
      painter: _DatabaseStackPainter(IconTheme.of(context).color ?? _muted),
    );
  }
}

class _DatabaseStackPainter extends CustomPainter {
  const _DatabaseStackPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.width * 0.075;
    final bounds = Rect.fromLTWH(
      size.width * 0.16,
      size.height * 0.20,
      size.width * 0.68,
      size.height * 0.62,
    );
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawOval(
      Rect.fromLTWH(bounds.left, bounds.top, bounds.width, size.height * 0.20),
      paint,
    );
    canvas.drawLine(
      Offset(bounds.left, bounds.top + size.height * 0.10),
      Offset(bounds.left, bounds.bottom - size.height * 0.10),
      paint,
    );
    canvas.drawLine(
      Offset(bounds.right, bounds.top + size.height * 0.10),
      Offset(bounds.right, bounds.bottom - size.height * 0.10),
      paint,
    );
    for (final y in [0.48, 0.68]) {
      canvas.drawArc(
        Rect.fromLTWH(
          bounds.left,
          size.height * y - size.height * 0.10,
          bounds.width,
          size.height * 0.20,
        ),
        0,
        math.pi,
        false,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_DatabaseStackPainter oldDelegate) =>
      oldDelegate.color != color;
}

class _TrashCanIcon extends StatelessWidget {
  const _TrashCanIcon({required this.color, required this.size});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.square(size),
      painter: _TrashCanPainter(color),
    );
  }
}

class _TrashCanPainter extends CustomPainter {
  const _TrashCanPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.075
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawLine(
      Offset(size.width * 0.20, size.height * 0.25),
      Offset(size.width * 0.80, size.height * 0.25),
      paint,
    );
    canvas.drawLine(
      Offset(size.width * 0.39, size.height * 0.15),
      Offset(size.width * 0.61, size.height * 0.15),
      paint,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTRB(
          size.width * 0.28,
          size.height * 0.33,
          size.width * 0.72,
          size.height * 0.84,
        ),
        Radius.circular(size.width * 0.07),
      ),
      paint,
    );
    for (final x in [0.43, 0.57]) {
      canvas.drawLine(
        Offset(size.width * x, size.height * 0.43),
        Offset(size.width * x, size.height * 0.73),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_TrashCanPainter oldDelegate) =>
      oldDelegate.color != color;
}

class _SettingsNavItem extends StatelessWidget {
  const _SettingsNavItem({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final Widget icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 11),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFF29364C) : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? const Color(0xFF3B5279) : Colors.transparent,
            ),
          ),
          child: Row(
            children: [
              IconTheme(
                data: IconThemeData(
                  size: 18,
                  color: selected ? const Color(0xFF91B2FF) : _muted,
                ),
                child: icon,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: selected ? const Color(0xFFB7CCFF) : _text,
                    fontSize: 12.5,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MacSettingsCard extends StatelessWidget {
  const _MacSettingsCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF292B30),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF393C42)),
      ),
      child: child,
    );
  }
}

class _SettingsGlyph extends StatelessWidget {
  const _SettingsGlyph({required this.icon, required this.tint});

  final Widget icon;
  final Color tint;

  @override
  Widget build(BuildContext context) {
    return IconTheme(
      data: IconThemeData(color: tint, size: 28),
      child: icon,
    );
  }
}

class _SettingsSectionHeader extends StatelessWidget {
  const _SettingsSectionHeader({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.iconSize = 30,
    this.trailing,
  });

  final Widget icon;
  final String title;
  final String subtitle;
  final double iconSize;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Row(
        children: [
          Container(
            key: const ValueKey('settings-section-icon-frame'),
            width: 48,
            height: 48,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: const Color(0xFF29364C),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFF435B83)),
            ),
            child: Center(
              child: IconTheme(
                data: IconThemeData(color: Color(0xFF91B2FF), size: iconSize),
                child: icon,
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: _text,
                    fontSize: 21,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.3,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: const TextStyle(color: _muted, fontSize: 12),
                ),
              ],
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

class _PersonalSettings extends StatelessWidget {
  const _PersonalSettings({
    required this.nameController,
    required this.isLoading,
    required this.isSaving,
    required this.onSave,
    required this.onLanguageChanged,
  });

  final TextEditingController nameController;
  final bool isLoading;
  final bool isSaving;
  final VoidCallback onSave;
  final ValueChanged<AppLanguage> onLanguageChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SettingsSectionHeader(
          icon: const Icon(LucideIcons300.userRound),
          iconSize: 30,
          title: appText('Personal'),
          subtitle: appText('Make Sara feel more like yours.'),
        ),
        if (isLoading)
          const Center(child: CircularProgressIndicator())
        else ...[
          _MacSettingsCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  appText('What should Sara call you?'),
                  style: const TextStyle(
                    color: _text,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  key: const ValueKey('personal-name-field'),
                  controller: nameController,
                  textCapitalization: TextCapitalization.words,
                  decoration: InputDecoration(
                    hintText: appText('Your name'),
                    prefixIcon: const Icon(LucideIcons300.userRound, size: 17),
                    filled: true,
                    fillColor: const Color(0xFF22262D),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 13,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(11),
                      borderSide: const BorderSide(color: Color(0xFF414957)),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(11),
                      borderSide: const BorderSide(color: Color(0xFF414957)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(11),
                      borderSide: const BorderSide(color: _accent),
                    ),
                  ),
                  style: const TextStyle(color: _text, fontSize: 13),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        appText('Your preferences stay on this device.'),
                        style: const TextStyle(color: _muted, fontSize: 11),
                      ),
                    ),
                    Tooltip(
                      message: appText('Save name'),
                      child: FilledButton.icon(
                        key: const ValueKey('save-personal-name'),
                        onPressed: isSaving ? null : onSave,
                        icon: isSaving
                            ? const SizedBox(
                                width: 15,
                                height: 15,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(LucideIcons300.save, size: 16),
                        label: Text(
                          appText(isSaving ? 'Saving...' : 'Save name'),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          _MacSettingsCard(
            child: Row(
              children: [
                const _SettingsGlyph(
                  icon: Icon(
                    LucideIcons300.globe,
                    key: ValueKey('settings-language-icon'),
                    size: 28,
                  ),
                  tint: Color(0xFF9AB7FF),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        appText('Language'),
                        style: const TextStyle(
                          color: _text,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        appText('Choose the language used throughout Sara.'),
                        style: const TextStyle(color: _muted, fontSize: 11),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 14),
                CupertinoSlidingSegmentedControl<AppLanguage>(
                  key: const ValueKey('app-language-selector'),
                  groupValue: AppLanguageController.language.value,
                  backgroundColor: const Color(0xFF252932),
                  thumbColor: const Color(0xFF416BC5),
                  padding: const EdgeInsets.all(3),
                  children: {
                    AppLanguage.english: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      child: Text(
                        appText('English'),
                        style: TextStyle(
                          color:
                              AppLanguageController.language.value ==
                                  AppLanguage.english
                              ? Colors.white
                              : _muted,
                          fontSize: 12,
                          fontWeight:
                              AppLanguageController.language.value ==
                                  AppLanguage.english
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                    ),
                    AppLanguage.indonesian: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      child: Text(
                        appText('Indonesian'),
                        style: TextStyle(
                          color:
                              AppLanguageController.language.value ==
                                  AppLanguage.indonesian
                              ? Colors.white
                              : _muted,
                          fontSize: 12,
                          fontWeight:
                              AppLanguageController.language.value ==
                                  AppLanguage.indonesian
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                    ),
                  },
                  onValueChanged: (language) {
                    if (language != null) onLanguageChanged(language);
                  },
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _DataSettings extends StatelessWidget {
  const _DataSettings({
    required this.onClearChat,
    required this.onExportBackup,
    required this.onImportBackup,
    required this.isBusy,
    required this.isSending,
    required this.cameraEnabled,
    required this.onCameraChanged,
    required this.saraCameraActive,
    required this.onStopSaraCamera,
  });

  final VoidCallback onClearChat;
  final VoidCallback onExportBackup;
  final VoidCallback onImportBackup;
  final bool isBusy;
  final bool isSending;
  final bool cameraEnabled;
  final Future<void> Function(bool enabled) onCameraChanged;
  final ValueListenable<bool> saraCameraActive;
  final VoidCallback onStopSaraCamera;

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const ValueKey('data-settings-content'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SettingsSectionHeader(
          icon: const _DatabaseStackIcon(size: 36),
          iconSize: 30,
          title: appText('Data'),
          subtitle: appText('Manage your local chat data.'),
        ),
        ValueListenableBuilder<bool>(
          valueListenable: saraCameraActive,
          builder: (context, isCameraActive, _) => isCameraActive
              ? Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _MacSettingsCard(
                    child: Row(
                      children: [
                        const Icon(
                          LucideIcons300.video,
                          size: 18,
                          color: Color(0xFFFF8585),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            appText('Sara is looking through the camera'),
                            style: const TextStyle(color: _text, fontSize: 11),
                          ),
                        ),
                        TextButton(
                          onPressed: onStopSaraCamera,
                          child: Text(appText('Stop camera access')),
                        ),
                      ],
                    ),
                  ),
                )
              : const SizedBox.shrink(),
        ),
        _MacSettingsCard(
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      appText('Allow camera access'),
                      style: const TextStyle(
                        color: _text,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      appText(
                        'When enabled, Sara can use a temporary camera frame to answer your request. The frame is sent to Gemini and deleted after analysis.',
                      ),
                      style: const TextStyle(color: _muted, fontSize: 11),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Switch(
                key: const ValueKey('camera-access-switch'),
                value: cameraEnabled,
                onChanged: isBusy
                    ? null
                    : (enabled) => unawaited(onCameraChanged(enabled)),
                thumbColor: WidgetStateProperty.resolveWith(
                  (states) => states.contains(WidgetState.selected)
                      ? const Color(0xFFDCE4F5)
                      : const Color(0xFFB4BAC7),
                ),
                trackColor: WidgetStateProperty.resolveWith(
                  (states) => states.contains(WidgetState.selected)
                      ? const Color(0xFF46536D)
                      : const Color(0xFF414752),
                ),
                trackOutlineColor: WidgetStateProperty.resolveWith(
                  (states) => states.contains(WidgetState.selected)
                      ? const Color(0xFF46536D)
                      : const Color(0xFF687080),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _MacSettingsCard(
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      appText('Backup and restore'),
                      style: const TextStyle(
                        color: _text,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      appText(
                        'Export or import your local data as a Sara JSON backup.',
                      ),
                      style: const TextStyle(color: _muted, fontSize: 11),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              _BackupActionButton(
                key: const ValueKey('import-backup-button'),
                icon: LucideIcons300.upload,
                label: appText('Import'),
                onPressed: isBusy ? null : onImportBackup,
              ),
              const SizedBox(width: 8),
              _BackupActionButton(
                key: const ValueKey('export-backup-button'),
                icon: LucideIcons300.download,
                label: appText('Export'),
                onPressed: isBusy ? null : onExportBackup,
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _MacSettingsCard(
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      appText('Clear chat'),
                      style: const TextStyle(
                        color: _text,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      appText('Clear chat removes all local messages.'),
                      style: const TextStyle(color: _muted, fontSize: 11),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              FilledButton(
                key: const ValueKey('clear-chat-button'),
                onPressed: isBusy ? null : onClearChat,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const _TrashCanIcon(color: Color(0xFFFFE9E9), size: 17),
                    const SizedBox(width: 7),
                    Text(
                      appText(
                        isSending
                            ? 'Wait for response to finish'
                            : 'Clear chat',
                      ),
                    ),
                  ],
                ),
                style: FilledButton.styleFrom(
                  foregroundColor: const Color(0xFFFFE9E9),
                  backgroundColor: const Color(0xFF8F323A),
                  side: const BorderSide(color: Color(0xFFB94A55)),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _BackupActionButton extends StatelessWidget {
  const _BackupActionButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final isEnabled = onPressed != null;
    return Tooltip(
      message: label,
      child: Material(
        color: isEnabled ? _surfaceRaised : const Color(0xFF252830),
        borderRadius: BorderRadius.circular(9),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(9),
          child: Container(
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(9),
              border: Border.all(
                color: isEnabled ? _border : const Color(0xFF30343C),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 16, color: isEnabled ? _accent : _muted),
                const SizedBox(width: 7),
                Text(
                  label,
                  style: TextStyle(
                    color: isEnabled ? _text : _muted,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ConfigureSettings extends StatelessWidget {
  const _ConfigureSettings({
    required this.aiApiSettings,
    required this.showHelp,
    required this.onToggleHelp,
    required this.onOpenGoogleAiStudio,
  });

  final Widget aiApiSettings;
  final bool showHelp;
  final VoidCallback onToggleHelp;
  final VoidCallback onOpenGoogleAiStudio;

  @override
  Widget build(BuildContext context) {
    return ListView(
      key: const ValueKey('configure-settings-scroll-view'),
      padding: EdgeInsets.zero,
      children: [
        _SettingsSectionHeader(
          icon: const Icon(LucideIcons300.slidersHorizontal),
          iconSize: 30,
          title: appText('Configure'),
          subtitle: appText('Adjust your AI connection settings.'),
          trailing: IconButton(
            key: const ValueKey('configure-help-toggle'),
            tooltip: appText(
              showHelp ? 'Back to configuration' : 'Configuration help',
            ),
            onPressed: onToggleHelp,
            icon: const Text(
              '?',
              style: TextStyle(
                color: _muted,
                fontSize: 21,
                fontWeight: FontWeight.w600,
              ),
            ),
            color: _muted,
          ),
        ),
        if (showHelp)
          _ConfigureHelp(onOpenGoogleAiStudio: onOpenGoogleAiStudio)
        else
          aiApiSettings,
      ],
    );
  }
}

class _ConfigureHelp extends StatelessWidget {
  const _ConfigureHelp({required this.onOpenGoogleAiStudio});

  final VoidCallback onOpenGoogleAiStudio;

  @override
  Widget build(BuildContext context) {
    return _MacSettingsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            appText('Set up Google Gemini'),
            style: const TextStyle(
              color: _text,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            appText('Follow these steps to connect Sara to the Gemini API:'),
            style: const TextStyle(color: _muted, fontSize: 12, height: 1.5),
          ),
          const SizedBox(height: 14),
          _ConfigurationHelpStep(
            number: '1',
            text: appText(
              'Open Google AI Studio and sign in to your Google account.',
            ),
          ),
          _ConfigurationHelpStep(
            number: '2',
            text: appText('Create a Gemini API key from the API keys page.'),
          ),
          _ConfigurationHelpStep(
            number: '3',
            text: appText(
              'Copy the key, return to Configure, paste it into Gemini API keys, then select Add API key.',
            ),
          ),
          _ConfigurationHelpStep(
            number: '4',
            text: appText(
              'Sara stores the key in the Linux keyring. It is not stored with chat messages.',
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            key: const ValueKey('open-google-ai-studio'),
            onPressed: onOpenGoogleAiStudio,
            icon: const Icon(LucideIcons300.externalLink, size: 16),
            label: Text(appText('Open Google AI Studio')),
          ),
        ],
      ),
    );
  }
}

class _ConfigurationHelpStep extends StatelessWidget {
  const _ConfigurationHelpStep({required this.number, required this.text});

  final String number;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              color: Color(0xFF29364C),
              shape: BoxShape.circle,
            ),
            child: Text(
              number,
              style: const TextStyle(
                color: Color(0xFF91B2FF),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(color: _text, fontSize: 12, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}

class _AiApiSettings extends StatelessWidget {
  const _AiApiSettings({
    required this.modelName,
    required this.apiKeyController,
    required this.apiKeys,
    required this.webSearchEnabled,
    required this.tavilyApiKeyController,
    required this.tinyFishApiKeyController,
    required this.firecrawlApiKeyController,
    required this.isLoading,
    required this.isSaving,
    required this.isSavingWebSearch,
    required this.onSave,
    required this.onWebSearchEnabledChanged,
    required this.onSaveWebSearch,
    required this.onRemoveApiKey,
  });

  final String modelName;
  final TextEditingController apiKeyController;
  final List<String> apiKeys;
  final bool webSearchEnabled;
  final TextEditingController tavilyApiKeyController;
  final TextEditingController tinyFishApiKeyController;
  final TextEditingController firecrawlApiKeyController;
  final bool isLoading;
  final bool isSaving;
  final bool isSavingWebSearch;
  final VoidCallback onSave;
  final ValueChanged<bool> onWebSearchEnabledChanged;
  final VoidCallback onSaveWebSearch;
  final ValueChanged<int> onRemoveApiKey;

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _SettingsValueCard(
                title: appText('Provider'),
                icon: LucideIcons300.sparkles,
                value: 'Google Gemini',
                detail: 'Gemini API',
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _SettingsValueCard(
                title: appText('Model'),
                icon: LucideIcons300.brain,
                value: modelName,
                valueKey: const ValueKey('ai-current-model'),
                monospace: true,
                detail: appText('Default'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        _MacSettingsCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      appText('Gemini API keys'),
                      style: const TextStyle(
                        color: _text,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF2C3038),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      appText(
                        '{count} added',
                        values: {'count': apiKeys.length},
                      ),
                      style: const TextStyle(color: _muted, fontSize: 10.5),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (apiKeys.isEmpty)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(11),
                  decoration: BoxDecoration(
                    color: _surfaceRaised,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: _border),
                  ),
                  child: Text(
                    appText(
                      'No API keys added yet. Sara cannot send messages without a key.',
                    ),
                    style: const TextStyle(color: _muted, fontSize: 11),
                  ),
                )
              else
                _ApiKeyList(apiKeys: apiKeys, onRemoveApiKey: onRemoveApiKey),
              const SizedBox(height: 10),
              _FieldLabel(appText('Add another API key')),
              const SizedBox(height: 7),
              TextField(
                key: const ValueKey('ai-api-key-field'),
                controller: apiKeyController,
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
                decoration: _settingsInputDecoration(
                  hintText: appText('Paste Gemini API key'),
                  prefixIcon: const Icon(LucideIcons300.keyRound, size: 18),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const Icon(
                    LucideIcons300.shield,
                    size: 15,
                    color: Color(0xFF65C993),
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      appText(
                        'Keys are stored in the Linux keyring and rotated automatically when one fails.',
                      ),
                      style: const TextStyle(color: _muted, fontSize: 10.5),
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton.icon(
                    onPressed: isSaving ? null : onSave,
                    icon: isSaving
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(LucideIcons300.plus, size: 16),
                    label: Text(
                      appText(isSaving ? 'Saving...' : 'Add API key'),
                    ),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF416BC5),
                      foregroundColor: Colors.white,
                      textStyle: const TextStyle(fontSize: 11.5),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        _MacSettingsCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      appText('Web search'),
                      style: const TextStyle(
                        color: _text,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Switch(
                    key: const ValueKey('web-search-enabled-switch'),
                    value: webSearchEnabled,
                    onChanged: onWebSearchEnabledChanged,
                    thumbColor: WidgetStateProperty.resolveWith(
                      (states) => states.contains(WidgetState.selected)
                          ? const Color(0xFFDCE4F5)
                          : const Color(0xFFB4BAC7),
                    ),
                    trackColor: WidgetStateProperty.resolveWith(
                      (states) => states.contains(WidgetState.selected)
                          ? const Color(0xFF46536D)
                          : const Color(0xFF414752),
                    ),
                    trackOutlineColor: WidgetStateProperty.resolveWith(
                      (states) => states.contains(WidgetState.selected)
                          ? const Color(0xFF46536D)
                          : const Color(0xFF687080),
                    ),
                  ),
                ],
              ),
              Text(
                appText(
                  'Allow Sara to search the web with tools when current information is needed.',
                ),
                style: const TextStyle(color: _muted, fontSize: 11),
              ),
              if (webSearchEnabled) ...[
                const SizedBox(height: 14),
                _FieldLabel(appText('Tavily API key')),
                const SizedBox(height: 7),
                TextField(
                  key: const ValueKey('web-search-tavily-key-field'),
                  controller: tavilyApiKeyController,
                  obscureText: true,
                  enableSuggestions: false,
                  autocorrect: false,
                  decoration: _settingsInputDecoration(
                    hintText: appText('Enter Tavily API key'),
                    prefixIcon: const Icon(LucideIcons300.keyRound, size: 18),
                  ),
                ),
                const SizedBox(height: 12),
                _FieldLabel(appText('TinyFish API key')),
                const SizedBox(height: 7),
                TextField(
                  key: const ValueKey('web-search-tinyfish-key-field'),
                  controller: tinyFishApiKeyController,
                  obscureText: true,
                  enableSuggestions: false,
                  autocorrect: false,
                  decoration: _settingsInputDecoration(
                    hintText: appText('Enter TinyFish API key'),
                    prefixIcon: const Icon(LucideIcons300.keyRound, size: 18),
                  ),
                ),
                const SizedBox(height: 12),
                _FieldLabel(appText('Firecrawl API key (optional)')),
                const SizedBox(height: 7),
                TextField(
                  key: const ValueKey('web-search-firecrawl-key-field'),
                  controller: firecrawlApiKeyController,
                  obscureText: true,
                  enableSuggestions: false,
                  autocorrect: false,
                  decoration: _settingsInputDecoration(
                    hintText: appText('Leave blank to search without a key'),
                    prefixIcon: const Icon(LucideIcons300.keyRound, size: 18),
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  appText(
                    'Add at least one Tavily or TinyFish key. Firecrawl can be used without a key, with lower request limits.',
                  ),
                  style: const TextStyle(color: _muted, fontSize: 10.5),
                ),
              ],
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  key: const ValueKey('save-web-search-settings'),
                  onPressed: isSavingWebSearch ? null : onSaveWebSearch,
                  icon: isSavingWebSearch
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(LucideIcons300.save, size: 16),
                  label: Text(
                    appText(
                      isSavingWebSearch
                          ? 'Saving...'
                          : 'Save web search settings',
                    ),
                  ),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF416BC5),
                    foregroundColor: Colors.white,
                    textStyle: const TextStyle(fontSize: 11.5),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SettingsValueCard extends StatelessWidget {
  const _SettingsValueCard({
    required this.title,
    required this.icon,
    required this.value,
    required this.detail,
    this.valueKey,
    this.monospace = false,
  });

  final String title;
  final IconData icon;
  final String value;
  final String detail;
  final Key? valueKey;
  final bool monospace;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 104),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF222730),
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: const Color(0xFF394352)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 20, color: const Color(0xFF9AB7FF)),
              const SizedBox(width: 9),
              Text(title, style: const TextStyle(color: _muted, fontSize: 11)),
              const Spacer(),
              const Icon(LucideIcons300.lockKeyhole, size: 13, color: _muted),
            ],
          ),
          const SizedBox(height: 13),
          Text(
            value,
            key: valueKey,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: _text,
              fontSize: 12.5,
              fontWeight: FontWeight.w500,
              fontFamily: monospace ? 'monospace' : null,
            ),
          ),
          const SizedBox(height: 4),
          Text(detail, style: const TextStyle(color: _muted, fontSize: 10)),
        ],
      ),
    );
  }
}

class _ApiKeyTile extends StatelessWidget {
  const _ApiKeyTile({
    required this.index,
    required this.apiKey,
    required this.onRemove,
  });

  final int index;
  final String apiKey;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final visibleSuffix = apiKey.length <= 4
        ? apiKey
        : apiKey.substring(apiKey.length - 4);
    return Container(
      key: ValueKey('api-key-tile-${index + 1}'),
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(8, 5, 5, 5),
      decoration: BoxDecoration(
        color: const Color(0xFF222730),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: const Color(0xFF394352)),
      ),
      child: Row(
        children: [
          const Icon(
            LucideIcons300.keyRound,
            size: 18,
            color: Color(0xFF9AB7FF),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              '${appText('API key')} ${index + 1}  ••••$visibleSuffix',
              style: const TextStyle(color: _text, fontSize: 11.5),
            ),
          ),
          IconButton(
            tooltip: appText(
              'Remove API key {index}',
              values: {'index': index + 1},
            ),
            onPressed: onRemove,
            icon: const Icon(LucideIcons300.x, size: 16),
            color: _muted,
            constraints: const BoxConstraints.tightFor(width: 30, height: 30),
            padding: EdgeInsets.zero,
            style: IconButton.styleFrom(
              backgroundColor: const Color(0xFF2B3039),
              shape: const CircleBorder(),
            ),
          ),
        ],
      ),
    );
  }
}

class _ApiKeyList extends StatefulWidget {
  const _ApiKeyList({required this.apiKeys, required this.onRemoveApiKey});

  final List<String> apiKeys;
  final ValueChanged<int> onRemoveApiKey;

  @override
  State<_ApiKeyList> createState() => _ApiKeyListState();
}

class _ApiKeyListState extends State<_ApiKeyList> {
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final visibleCount = math.min(widget.apiKeys.length, 3);
    final canScroll = widget.apiKeys.length > visibleCount;
    return SizedBox(
      key: const ValueKey('api-key-list-viewport'),
      height: visibleCount.toDouble() * 46,
      child: Scrollbar(
        controller: _scrollController,
        thumbVisibility: canScroll,
        trackVisibility: canScroll,
        interactive: true,
        child: ListView.builder(
          key: const ValueKey('api-key-scroll-list'),
          controller: _scrollController,
          primary: false,
          padding: const EdgeInsets.only(right: 8),
          physics: const ClampingScrollPhysics(),
          itemCount: widget.apiKeys.length,
          itemExtent: 46,
          itemBuilder: (context, index) => _ApiKeyTile(
            index: index,
            apiKey: widget.apiKeys[index],
            onRemove: () => widget.onRemoveApiKey(index),
          ),
        ),
      ),
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: const TextStyle(
        color: _text,
        fontSize: 12,
        fontWeight: FontWeight.w500,
      ),
    );
  }
}

InputDecoration _settingsInputDecoration({
  required String hintText,
  required Widget prefixIcon,
}) {
  return InputDecoration(
    hintText: hintText,
    hintStyle: const TextStyle(color: _muted, fontSize: 11.5),
    prefixIcon: prefixIcon,
    isDense: true,
    filled: true,
    fillColor: _surfaceRaised,
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: const BorderSide(color: _border),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: const BorderSide(color: _border),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: const BorderSide(color: _accent),
    ),
  );
}

class _SearchResultSource {
  const _SearchResultSource({required this.title, required this.uri});

  final String title;
  final Uri uri;
}

List<_SearchResultSource> _searchResultSources(String content) {
  final heading = RegExp(r'\*\*(?:Search sources|Sumber pencarian)\*\*');
  final headingMatch = heading.firstMatch(content);
  if (headingMatch == null) return const [];
  final sourceSection = content.substring(headingMatch.end);
  final sourcePattern = RegExp(
    r'^-\s+\[(.*)\]\((https?://[^)\s]+)\)\s*$',
    multiLine: true,
  );
  final sources = <_SearchResultSource>[];
  final seenUris = <String>{};
  for (final match in sourcePattern.allMatches(sourceSection)) {
    final uri = Uri.tryParse(match.group(2)!);
    if (uri == null || !_isValidWebUri(uri) || !seenUris.add(uri.toString())) {
      continue;
    }
    sources.add(
      _SearchResultSource(
        title: match
            .group(1)!
            .replaceAll(r'\[', '[')
            .replaceAll(r'\]', ']')
            .replaceAll(r'\(', '(')
            .replaceAll(r'\)', ')'),
        uri: uri,
      ),
    );
  }
  return sources;
}

List<_SearchResultSource> _messageResultSources(String content) {
  final sources = _searchResultSources(content);
  final sourceUrls = {for (final source in sources) source.uri.toString()};
  final linkTitles = <String, String>{};
  final markdownLinks = RegExp(
    r'\[(.*)\]\((https?://[^)\s]+)\)',
  ).allMatches(content);
  for (final match in markdownLinks) {
    final uri = Uri.tryParse(match.group(2)!);
    if (uri == null || !_isValidWebUri(uri)) continue;
    linkTitles.putIfAbsent(
      uri.toString(),
      () => match
          .group(1)!
          .replaceAll(r'\[', '[')
          .replaceAll(r'\]', ']')
          .replaceAll(r'\(', '(')
          .replaceAll(r'\)', ')'),
    );
  }
  for (final uri in _messageWebUris(content)) {
    if (!sourceUrls.add(uri.toString())) continue;
    sources.add(
      _SearchResultSource(title: linkTitles[uri.toString()] ?? '', uri: uri),
    );
  }
  return sources;
}

bool _isValidWebUri(Uri uri) {
  if ((uri.scheme != 'http' && uri.scheme != 'https') ||
      !uri.hasAuthority ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    return false;
  }
  try {
    return uri.port > 0 && uri.port <= 65535;
  } on FormatException {
    return false;
  }
}

List<Uri> _messageWebUris(String content) {
  final plainText = content
      .replaceAll(RegExp(r'```[\s\S]*?```'), '')
      .replaceAll(RegExp(r'`[^`]*`'), '');
  final seenUris = <String>{};
  final uris = <Uri>[];
  for (final match in RegExp(r'https?://[^\s<>()\]]+').allMatches(plainText)) {
    final link = match.group(0)!.replaceFirst(RegExp(r'[.,!?;:"]+$'), '');
    final uri = Uri.tryParse(link);
    if (uri != null && _isValidWebUri(uri) && seenUris.add(uri.toString())) {
      uris.add(uri);
    }
  }
  return uris;
}

String _searchResultDate(int createdAtUtc) {
  final jakarta = DateTime.fromMillisecondsSinceEpoch(
    createdAtUtc,
    isUtc: true,
  ).add(const Duration(hours: 7));
  final year = jakarta.year.toString().padLeft(4, '0');
  final month = jakarta.month.toString().padLeft(2, '0');
  final day = jakarta.day.toString().padLeft(2, '0');
  return '$year/$month/$day';
}

String _messageContentWithoutSearchSources(String content) {
  final heading = RegExp(r'\*\*(?:Search sources|Sumber pencarian)\*\*');
  final headingMatch = heading.firstMatch(content);
  return headingMatch == null
      ? content
      : content.substring(0, headingMatch.start).trimRight();
}

class _ConversationView extends StatelessWidget {
  const _ConversationView({
    required this.messages,
    required this.scrollController,
    required this.isSending,
    required this.showReplyIndicator,
    required this.retryErrors,
    required this.onRetryMessage,
    required this.onDeleteMessage,
    required this.onEditMessage,
    required this.onProactiveModeChanged,
    required this.messageBranches,
    required this.onActivateBranch,
    required this.onRegenerateMessage,
    required this.attachmentsByMessage,
    required this.terminalActivitiesByResponse,
    required this.activeReplyResponseMessageId,
    required this.assistantFeedback,
    required this.onSetAssistantFeedback,
    required this.assistantReactions,
    required this.onSetAssistantReaction,
    required this.speakingMessageId,
    required this.loadingSpeechMessageId,
    required this.onToggleSpeech,
    required this.showScrollToBottom,
    required this.onScrollToBottom,
    required this.onScrollMetricsChanged,
    required this.onUserScroll,
    required this.onShowSearchResults,
  });

  final List<ChatMessage> messages;
  final ScrollController scrollController;
  final bool isSending;
  final bool showReplyIndicator;
  final Map<String, String> retryErrors;
  final ValueChanged<String> onRetryMessage;
  final ValueChanged<String> onDeleteMessage;
  final Future<void> Function(
    String messageId,
    String content,
    List<ChatAttachment> attachments,
    bool allowAiReply,
  )
  onEditMessage;
  final ValueChanged<bool> onProactiveModeChanged;
  final Map<String, MessageBranchNavigation> messageBranches;
  final ValueChanged<String> onActivateBranch;
  final ValueChanged<String> onRegenerateMessage;
  final Map<String, List<ChatAttachment>> attachmentsByMessage;
  final Map<String, List<TerminalCommandHistoryEntry>>
  terminalActivitiesByResponse;
  final String? activeReplyResponseMessageId;
  final Map<String, int> assistantFeedback;
  final void Function(
    String userMessageId,
    String responseMessageId,
    int? rating,
  )
  onSetAssistantFeedback;
  final Map<String, String> assistantReactions;
  final void Function(
    String userMessageId,
    String responseMessageId,
    String? reaction,
  )
  onSetAssistantReaction;
  final String? speakingMessageId;
  final String? loadingSpeechMessageId;
  final Future<void> Function(String messageId, String text) onToggleSpeech;
  final bool showScrollToBottom;
  final VoidCallback onScrollToBottom;
  final VoidCallback onScrollMetricsChanged;
  final VoidCallback onUserScroll;
  final ValueChanged<String> onShowSearchResults;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => Stack(
        children: [
          Scrollbar(
            controller: scrollController,
            child: NotificationListener<ScrollNotification>(
              onNotification: (notification) {
                if (notification is UserScrollNotification ||
                    (notification is ScrollUpdateNotification &&
                        notification.dragDetails != null)) {
                  onUserScroll();
                }
                return false;
              },
              child: NotificationListener<ScrollMetricsNotification>(
                onNotification: (_) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    onScrollMetricsChanged();
                  });
                  return false;
                },
                child: ScrollConfiguration(
                  behavior: ScrollConfiguration.of(
                    context,
                  ).copyWith(scrollbars: false),
                  child: ListView.builder(
                    controller: scrollController,
                    padding: const EdgeInsets.fromLTRB(0, 42, 0, 24),
                    itemCount: messages.length + (showReplyIndicator ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (index == messages.length) {
                        return Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 760),
                            child: Padding(
                              padding: EdgeInsets.symmetric(horizontal: 24),
                              child: _ThinkingIndicator(),
                            ),
                          ),
                        );
                      }
                      final message = messages[index];
                      final feedbackUserMessageId = _previousUserMessageId(
                        index,
                      );
                      final hasUserParent =
                          message.role == 'model' &&
                          index > 0 &&
                          messages[index - 1].role == 'user';
                      final canReactToMessage =
                          message.role == 'model' &&
                          feedbackUserMessageId != null;
                      return Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 760),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 24),
                            child: _MessageRow(
                              key: ValueKey(message.id),
                              message: message,
                              retryError: retryErrors[message.id],
                              onRetry: () => onRetryMessage(message.id),
                              retryEnabled: !isSending,
                              onDelete: () => onDeleteMessage(message.id),
                              deleteEnabled: !isSending,
                              onEditMessage: onEditMessage,
                              onProactiveModeChanged: onProactiveModeChanged,
                              editEnabled: !isSending,
                              branch: messageBranches[message.id],
                              onActivateBranch: onActivateBranch,
                              onRegenerate: () =>
                                  onRegenerateMessage(message.id),
                              regenerateEnabled: !isSending && hasUserParent,
                              attachments:
                                  attachmentsByMessage[message.id] ??
                                  const <ChatAttachment>[],
                              terminalActivities:
                                  terminalActivitiesByResponse[message.id] ??
                                  const <TerminalCommandHistoryEntry>[],
                              isActiveReply:
                                  activeReplyResponseMessageId == message.id,
                              feedbackUserMessageId: feedbackUserMessageId,
                              feedbackRating: assistantFeedback[message.id],
                              feedbackEnabled: !isSending && hasUserParent,
                              reactionEnabled: !isSending && canReactToMessage,
                              onSetFeedback: onSetAssistantFeedback,
                              reaction: assistantReactions[message.id],
                              onSetReaction: onSetAssistantReaction,
                              isSpeechPlaying: speakingMessageId == message.id,
                              isSpeechLoading:
                                  loadingSpeechMessageId == message.id,
                              onToggleSpeech: () =>
                                  onToggleSpeech(message.id, message.content),
                              onShowSearchResults: () =>
                                  onShowSearchResults(message.id),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
          if (showScrollToBottom)
            Positioned(
              right: ((constraints.maxWidth - 760) / 2).clamp(
                16.0,
                double.infinity,
              ),
              bottom: 0,
              child: Material(
                color: const Color(0xFF20242B),
                shape: const CircleBorder(),
                elevation: 1,
                child: SizedBox(
                  width: 32,
                  height: 32,
                  child: IconButton(
                    key: const ValueKey('scroll-to-bottom-button'),
                    tooltip: appText('Scroll to bottom'),
                    onPressed: onScrollToBottom,
                    icon: const CustomPaint(
                      key: ValueKey('scroll-to-bottom-icon'),
                      size: Size(17, 17),
                      painter: _ScrollDownIconPainter(),
                    ),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 32,
                      height: 32,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  String? _previousUserMessageId(int messageIndex) {
    for (var index = messageIndex - 1; index >= 0; index--) {
      if (messages[index].role == 'user') return messages[index].id;
    }
    return null;
  }
}

class _PendingTerminalCommandApproval {
  _PendingTerminalCommandApproval(this.request);

  final TerminalCommandRequest request;
  final Completer<TerminalApprovalDecision> decision =
      Completer<TerminalApprovalDecision>();

  void complete(TerminalApprovalDecision value) {
    if (!decision.isCompleted) decision.complete(value);
  }
}

class _TerminalActivityDisclosure extends StatelessWidget {
  const _TerminalActivityDisclosure({
    required this.activities,
    required this.expanded,
    required this.onToggle,
  });

  final List<TerminalCommandHistoryEntry> activities;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          key: const ValueKey('terminal-activity-toggle'),
          onTap: onToggle,
          borderRadius: BorderRadius.circular(4),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Terminal activity',
                  style: TextStyle(
                    color: _muted,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(width: 3),
                CustomPaint(
                  key: ValueKey(
                    expanded
                        ? 'terminal-activity-arrow-down'
                        : 'terminal-activity-arrow-right',
                  ),
                  size: const Size(14, 14),
                  painter: _TerminalDisclosureArrow(
                    expanded: expanded,
                    color: _muted,
                  ),
                ),
              ],
            ),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 150),
          alignment: Alignment.topLeft,
          child: expanded
              ? Container(
                  key: const ValueKey('terminal-activity-content'),
                  width: double.infinity,
                  constraints: const BoxConstraints(maxWidth: 760),
                  decoration: BoxDecoration(
                    color: const Color(0xFF202124),
                    border: Border.all(color: _border),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (
                        var index = 0;
                        index < activities.length;
                        index++
                      ) ...[
                        if (index > 0) const Divider(height: 1, color: _border),
                        _TerminalActivityItem(activity: activities[index]),
                      ],
                    ],
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}

final _terminalCommandHighlightTheme = <String, TextStyle>{...atomOneDarkTheme}
  ..['root'] = const TextStyle(
    color: Color(0xFFC9D5E8),
    backgroundColor: Colors.transparent,
  )
  ..['built_in'] = const TextStyle(
    color: Color(0xFF61AFEF),
    fontWeight: FontWeight.w600,
  )
  ..['variable'] = const TextStyle(color: Color(0xFFE5C07B));

class _TerminalDisclosureArrow extends CustomPainter {
  const _TerminalDisclosureArrow({required this.expanded, required this.color});

  final bool expanded;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.7
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    final path = Path();
    if (expanded) {
      path
        ..moveTo(size.width * 0.22, size.height * 0.36)
        ..lineTo(size.width * 0.5, size.height * 0.64)
        ..lineTo(size.width * 0.78, size.height * 0.36);
    } else {
      path
        ..moveTo(size.width * 0.38, size.height * 0.2)
        ..lineTo(size.width * 0.66, size.height * 0.5)
        ..lineTo(size.width * 0.38, size.height * 0.8);
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_TerminalDisclosureArrow oldDelegate) =>
      oldDelegate.expanded != expanded || oldDelegate.color != color;
}

class _TerminalActivityItem extends StatelessWidget {
  const _TerminalActivityItem({required this.activity});

  final TerminalCommandHistoryEntry activity;

  String get _status {
    if (activity.error == 'Awaiting approval') return 'Awaiting approval';
    if (activity.error == 'Running') return 'Running';
    if (activity.skipped) return 'Skipped';
    if (activity.timedOut) return 'Timed out';
    if (activity.cancelled) return 'Stopped';
    if (activity.error != null) return 'Failed';
    if (activity.exitCode == 0) return 'Completed';
    return 'Failed';
  }

  String get _output {
    final parts = <String>[
      if (activity.stdout.isNotEmpty) activity.stdout,
      if (activity.stderr.isNotEmpty) activity.stderr,
      if (activity.error != null &&
          activity.error != 'Awaiting approval' &&
          activity.error != 'Running')
        activity.error!,
    ];
    if (activity.exitCode != null) {
      parts.add('Exit code: ${activity.exitCode}');
    }
    if (activity.outputTruncated) parts.add('Output truncated');
    return parts.join('\n');
  }

  Color get _statusColor {
    if (activity.error == 'Awaiting approval') return _accent;
    if (activity.error == 'Running') return const Color(0xFFE5C07B);
    if (activity.skipped) return _muted;
    if (activity.error == null &&
        !activity.timedOut &&
        !activity.cancelled &&
        !activity.skipped &&
        activity.exitCode == 0) {
      return const Color(0xFF98C379);
    }
    return const Color(0xFFE06C75);
  }

  @override
  Widget build(BuildContext context) {
    final output = _output;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: HighlightView(
                    activity.command,
                    language: 'bash',
                    theme: _terminalCommandHighlightTheme,
                    padding: EdgeInsets.zero,
                    textStyle: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      height: 1.4,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                _status,
                style: TextStyle(color: _statusColor, fontSize: 11),
              ),
            ],
          ),
          if (output.isNotEmpty) ...[
            const SizedBox(height: 5),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 104),
              child: SingleChildScrollView(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SelectableText(
                    output,
                    style: const TextStyle(
                      color: _text,
                      fontFamily: 'monospace',
                      fontSize: 11,
                      height: 1.4,
                    ),
                    maxLines: null,
                    textWidthBasis: TextWidthBasis.longestLine,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _TerminalCommandApprovalCard extends StatelessWidget {
  const _TerminalCommandApprovalCard({
    required this.approval,
    required this.activity,
    required this.output,
    required this.isRunning,
    required this.automaticallyAllowed,
    required this.onDecision,
    required this.onStop,
  });

  final _PendingTerminalCommandApproval? approval;
  final TerminalCommandRequest? activity;
  final String output;
  final bool isRunning;
  final bool automaticallyAllowed;
  final ValueChanged<TerminalApprovalDecision> onDecision;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final request = approval?.request ?? activity;
    if (request == null) return const SizedBox.shrink();
    return Container(
      key: const ValueKey('terminal-command-approval'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: const Color(0xFF20252E),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF3B4658)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Icon(LucideIcons300.terminal, color: _accent, size: 18),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  appText(
                    isRunning
                        ? automaticallyAllowed
                              ? 'Running command (All allow)'
                              : 'Running command'
                        : 'Allow this terminal command?',
                  ),
                  style: const TextStyle(
                    color: _text,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (isRunning)
                TextButton(
                  key: const ValueKey('terminal-command-stop'),
                  onPressed: onStop,
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 30),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    visualDensity: VisualDensity.compact,
                  ),
                  child: Text(appText('Stop')),
                ),
            ],
          ),
          const SizedBox(height: 5),
          Container(
            constraints: const BoxConstraints(maxHeight: 54),
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
            decoration: const BoxDecoration(),
            child: SingleChildScrollView(
              scrollDirection: Axis.vertical,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: KeyedSubtree(
                  key: const ValueKey('terminal-command-text'),
                  child: HighlightView(
                    request.command,
                    language: 'bash',
                    theme: _terminalCommandHighlightTheme,
                    padding: EdgeInsets.zero,
                    textStyle: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      height: 1.35,
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: RichText(
              text: TextSpan(
                style: const TextStyle(fontSize: 9),
                children: [
                  TextSpan(
                    text: '${appText('Working directory')}: ',
                    style: const TextStyle(color: _muted),
                  ),
                  TextSpan(
                    text: request.workingDirectory,
                    style: const TextStyle(
                      color: Color(0xFF8DA8D8),
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (isRunning) ...[
            const SizedBox(height: 5),
            Container(
              constraints: const BoxConstraints(maxHeight: 66),
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
              decoration: const BoxDecoration(),
              child: SingleChildScrollView(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SelectableText(
                    output.isEmpty ? appText('Running command') : output,
                    key: const ValueKey('terminal-command-output'),
                    style: const TextStyle(
                      color: Color(0xFFB8C6D9),
                      fontFamily: 'monospace',
                      fontSize: 10,
                      height: 1.3,
                    ),
                  ),
                ),
              ),
            ),
          ],
          if (approval != null) ...[
            const SizedBox(height: 7),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                FilledButton(
                  key: const ValueKey('terminal-command-allow'),
                  onPressed: () => onDecision(TerminalApprovalDecision.allow),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 32),
                    padding: const EdgeInsets.symmetric(horizontal: 13),
                    visualDensity: VisualDensity.compact,
                  ),
                  child: Text(appText('Allow')),
                ),
                OutlinedButton(
                  key: const ValueKey('terminal-command-skip'),
                  onPressed: () => onDecision(TerminalApprovalDecision.skip),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 32),
                    padding: const EdgeInsets.symmetric(horizontal: 13),
                    visualDensity: VisualDensity.compact,
                  ),
                  child: Text(appText('Skip')),
                ),
                TextButton(
                  key: const ValueKey('terminal-command-allow-all'),
                  onPressed: () =>
                      onDecision(TerminalApprovalDecision.allowAll),
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 32),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    visualDensity: VisualDensity.compact,
                  ),
                  child: Text(appText('All allow')),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _ThinkingIndicator extends StatelessWidget {
  const _ThinkingIndicator();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Row(
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          Text(
            appText('Thinking...'),
            style: const TextStyle(color: _muted, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _AnimatedEmojiMessage extends StatelessWidget {
  const _AnimatedEmojiMessage({super.key, required this.emoji});

  final String emoji;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 760),
      builder: (context, progress, child) {
        final bounce = math.sin(progress * math.pi * 4) * (1 - progress);
        final tilt = math.sin(progress * math.pi * 6) * (1 - progress) * 0.13;
        return Transform.translate(
          offset: Offset(0, -bounce * 9),
          child: Transform.rotate(
            angle: tilt,
            child: Transform.scale(scale: 1 + bounce * 0.08, child: child),
          ),
        );
      },
      child: Text(
        emoji,
        textAlign: TextAlign.center,
        style: const TextStyle(
          fontFamily: _emojiFontFamily,
          fontSize: 48,
          height: 1.15,
        ),
      ),
    );
  }
}

class _MessageRow extends StatefulWidget {
  const _MessageRow({
    super.key,
    required this.message,
    required this.retryError,
    required this.onRetry,
    required this.retryEnabled,
    required this.onDelete,
    required this.deleteEnabled,
    required this.onEditMessage,
    required this.onProactiveModeChanged,
    required this.editEnabled,
    this.branch,
    required this.onActivateBranch,
    required this.onRegenerate,
    required this.regenerateEnabled,
    required this.attachments,
    required this.terminalActivities,
    required this.isActiveReply,
    this.feedbackUserMessageId,
    this.feedbackRating,
    this.reaction,
    required this.feedbackEnabled,
    required this.reactionEnabled,
    required this.onSetFeedback,
    required this.onSetReaction,
    required this.isSpeechPlaying,
    required this.isSpeechLoading,
    required this.onToggleSpeech,
    required this.onShowSearchResults,
  });

  final ChatMessage message;
  final String? retryError;
  final VoidCallback onRetry;
  final bool retryEnabled;
  final VoidCallback onDelete;
  final bool deleteEnabled;
  final Future<void> Function(
    String messageId,
    String content,
    List<ChatAttachment> attachments,
    bool allowAiReply,
  )
  onEditMessage;
  final ValueChanged<bool> onProactiveModeChanged;
  final bool editEnabled;
  final MessageBranchNavigation? branch;
  final ValueChanged<String> onActivateBranch;
  final VoidCallback onRegenerate;
  final bool regenerateEnabled;
  final List<ChatAttachment> attachments;
  final List<TerminalCommandHistoryEntry> terminalActivities;
  final bool isActiveReply;
  final String? feedbackUserMessageId;
  final int? feedbackRating;
  final String? reaction;
  final bool feedbackEnabled;
  final bool reactionEnabled;
  final void Function(
    String userMessageId,
    String responseMessageId,
    int? rating,
  )
  onSetFeedback;
  final void Function(
    String userMessageId,
    String responseMessageId,
    String? reaction,
  )
  onSetReaction;
  final bool isSpeechPlaying;
  final bool isSpeechLoading;
  final VoidCallback onToggleSpeech;
  final VoidCallback onShowSearchResults;

  @override
  State<_MessageRow> createState() => _MessageRowState();
}

class _MessageRowState extends State<_MessageRow> {
  bool _isCopied = false;
  bool _isHovered = false;
  bool _isEditing = false;
  bool _terminalActivityExpanded = false;
  bool _ventMode = false;
  bool _isPickingEditAttachments = false;
  final _editController = _EmojiAwareTextEditingController();
  final List<ChatAttachment> _editAttachments = [];
  final Map<String, Future<LinkPreview?>> _linkPreviews = {};
  final _linkPreviewService = LinkPreviewService();
  Timer? _copyResetTimer;

  @override
  void initState() {
    super.initState();
    _terminalActivityExpanded = widget.isActiveReply;
  }

  @override
  void didUpdateWidget(covariant _MessageRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isActiveReply && !widget.isActiveReply) {
      _terminalActivityExpanded = false;
    }
    if (oldWidget.message.content != widget.message.content) {
      _linkPreviews.clear();
    }
    if (oldWidget.message.id != widget.message.id) {
      _isEditing = false;
    }
  }

  @override
  void dispose() {
    _copyResetTimer?.cancel();
    _editController.dispose();
    super.dispose();
  }

  void _startEditing() {
    _editController.text = widget.message.content;
    _editAttachments
      ..clear()
      ..addAll(widget.attachments);
    widget.onProactiveModeChanged(false);
    setState(() {
      _isEditing = true;
      _ventMode = false;
    });
  }

  Future<void> _pickEditAttachments() async {
    if (_isPickingEditAttachments) return;
    setState(() => _isPickingEditAttachments = true);
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.any,
        dialogTitle: appText('Choose files'),
      );
      if (!mounted || result.isEmpty) return;
      final added = <ChatAttachment>[];
      for (final file in result) {
        final filePath = file.path;
        if (filePath == null) {
          _showToast(
            context,
            appText(
              'Could not read file location: {name}.',
              values: {'name': file.name},
            ),
            isError: true,
          );
          continue;
        }
        if (isSensitiveAttachmentPath(filePath)) {
          _showToast(
            context,
            appText(
              'Sensitive file cannot be uploaded: {name}.',
              values: {'name': file.name},
            ),
            isError: true,
          );
          continue;
        }
        added.add(
          ChatAttachment(
            id: _uuid.v4(),
            path: filePath,
            name: path.basename(filePath),
            mimeType: attachmentMimeType(filePath),
            expiresAtUtc: DateTime.now()
                .toUtc()
                .add(const Duration(hours: 24))
                .millisecondsSinceEpoch,
          ),
        );
      }
      if (added.isNotEmpty) {
        setState(() => _editAttachments.addAll(added));
      }
    } catch (error) {
      if (mounted) {
        _showToast(
          context,
          appText(
            'Could not select attachment: {error}',
            values: {'error': error},
          ),
          isError: true,
        );
      }
    } finally {
      if (mounted) setState(() => _isPickingEditAttachments = false);
    }
  }

  Future<void> _sendEditedMessage() async {
    final text = _editController.text.trim();
    if ((text.isEmpty && _editAttachments.isEmpty) ||
        !widget.editEnabled ||
        _isPickingEditAttachments) {
      return;
    }
    await widget.onEditMessage(
      widget.message.id,
      text,
      List<ChatAttachment>.unmodifiable(_editAttachments),
      !_ventMode,
    );
    if (mounted) setState(() => _isEditing = false);
  }

  Widget _buildInlineEditor(BuildContext context) {
    final canSend =
        _editController.text.trim().isNotEmpty || _editAttachments.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_editAttachments.isNotEmpty) ...[
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: _AttachmentGrid(
              attachments: _editAttachments,
              onRemove: (id) => setState(
                () => _editAttachments.removeWhere((item) => item.id == id),
              ),
              onPreview: (attachment) =>
                  _openAttachmentPreview(context, attachment),
              compact: true,
              compactRows: 1,
              composerStyle: true,
            ),
          ),
          const SizedBox(height: 8),
        ],
        Focus(
          onKeyEvent: (_, event) =>
              _handleEnterSubmission(event, _editController, () {
                if (_editController.text.trim().isNotEmpty ||
                    _editAttachments.isNotEmpty) {
                  _sendEditedMessage();
                }
              }),
          child: TextField(
            key: ValueKey('edit-input-${widget.message.id}'),
            controller: _editController,
            inputFormatters: [SmartTextInputFormatter()],
            autofocus: true,
            minLines: 1,
            maxLines: 6,
            textCapitalization: TextCapitalization.sentences,
            textInputAction: TextInputAction.send,
            style: const TextStyle(color: _text, fontSize: 14, height: 1.4),
            decoration: const InputDecoration(
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              isDense: true,
              contentPadding: EdgeInsets.zero,
            ),
            onChanged: (_) {
              setState(() {});
              widget.onProactiveModeChanged(!_ventMode);
            },
            onSubmitted: (_) {
              if (_editController.text.trim().isNotEmpty ||
                  _editAttachments.isNotEmpty) {
                _sendEditedMessage();
              }
            },
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            IconButton(
              key: ValueKey('edit-attachment-${widget.message.id}'),
              tooltip: appText('Add attachment'),
              onPressed: _isPickingEditAttachments
                  ? null
                  : _pickEditAttachments,
              icon: _isPickingEditAttachments
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(LucideIcons300.plus, size: 22),
              color: _text,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 32, height: 32),
            ),
            const SizedBox(width: 4),
            _ComposerMode(
              key: ValueKey('edit-mode-${widget.message.id}'),
              icon: LucideIcons300.volumeX,
              label: appText('Vent'),
              selected: _ventMode,
              onTap: () {
                final newMode = !_ventMode;
                setState(() => _ventMode = newMode);
                widget.onProactiveModeChanged(!newMode);
              },
            ),
            const Spacer(),
            TextButton(
              key: ValueKey('cancel-edit-${widget.message.id}'),
              onPressed: () => setState(() => _isEditing = false),
              child: Text(appText('Cancel')),
            ),
            const SizedBox(width: 6),
            FilledButton(
              key: ValueKey('send-edit-${widget.message.id}'),
              onPressed: canSend ? _sendEditedMessage : null,
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF536A96),
                foregroundColor: Colors.white,
                minimumSize: const Size(58, 34),
                padding: const EdgeInsets.symmetric(horizontal: 12),
              ),
              child: Text(appText('Send')),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _copyMessage() async {
    try {
      await Clipboard.setData(ClipboardData(text: widget.message.content));
      if (!mounted) return;
      _copyResetTimer?.cancel();
      setState(() => _isCopied = true);
      _showToast(context, appText('Message copied'));
      _copyResetTimer = Timer(const Duration(seconds: 2), () {
        if (mounted) setState(() => _isCopied = false);
      });
    } catch (error) {
      if (!mounted) return;
      _showToast(
        context,
        appText('Unable to copy message: {error}', values: {'error': error}),
        isError: true,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final message = widget.message;
    final resultSources = message.role == 'model'
        ? _messageResultSources(message.content)
        : const <_SearchResultSource>[];
    final messageWebUris = _messageWebUris(message.content);
    final hasSearchResultsButton = resultSources.length >= 2;
    final showInlineUrlPreview = messageWebUris.length == 1;
    final displayContent = hasSearchResultsButton
        ? _messageContentWithoutSearchSources(message.content)
        : message.content;
    final emojiOnlyMessage = widget.attachments.isEmpty
        ? _singleEmoji(message.content)
        : null;
    final waitingForTerminalReply =
        message.role == 'model' &&
        message.content.trim().isEmpty &&
        widget.attachments.isEmpty &&
        widget.terminalActivities.isNotEmpty;
    if (message.role == 'user') {
      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Align(
          alignment: Alignment.centerRight,
          child: IntrinsicWidth(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    if (widget.retryError != null) ...[
                      IconButton(
                        key: ValueKey('retry-${message.id}'),
                        tooltip: appText('Retry message'),
                        onPressed: widget.retryEnabled ? widget.onRetry : null,
                        icon: const Icon(LucideIcons300.refreshCw, size: 20),
                        color: _accent,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints.tightFor(
                          width: 26,
                          height: 26,
                        ),
                      ),
                      const SizedBox(width: 4),
                    ],
                    IntrinsicWidth(
                      child: MouseRegion(
                        onEnter: (_) => setState(() => _isHovered = true),
                        onExit: (_) => setState(() => _isHovered = false),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            if (!_isEditing &&
                                widget.attachments.isNotEmpty) ...[
                              ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 480,
                                ),
                                child: KeyedSubtree(
                                  key: const ValueKey('sent-attachment-grid'),
                                  child: _AttachmentGrid(
                                    attachments: widget.attachments,
                                    onPreview: (attachment) =>
                                        _openAttachmentPreview(
                                          context,
                                          attachment,
                                        ),
                                  ),
                                ),
                              ),
                              if (message.content.isNotEmpty)
                                const SizedBox(height: 8),
                            ],
                            if (message.content.isNotEmpty)
                              ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 640,
                                ),
                                child: AnimatedContainer(
                                  key: const ValueKey('user-message-bubble'),
                                  duration: const Duration(milliseconds: 140),
                                  curve: Curves.easeOut,
                                  transform: Matrix4.translationValues(
                                    0,
                                    _isHovered ? -2 : 0,
                                    0,
                                  ),
                                  transformAlignment: Alignment.center,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 7,
                                  ),
                                  decoration: BoxDecoration(
                                    color: _isHovered
                                        ? const Color(0xFF2B313D)
                                        : const Color(0xFF252A34),
                                    border: Border.all(
                                      color: _isEditing
                                          ? _accent
                                          : _isHovered
                                          ? const Color(0xFF596A86)
                                          : const Color(0xFF3B4351),
                                    ),
                                    borderRadius: BorderRadius.circular(17),
                                  ),
                                  child: _isEditing
                                      ? _buildInlineEditor(context)
                                      : emojiOnlyMessage != null
                                      ? _AnimatedEmojiMessage(
                                          key: ValueKey(
                                            'animated-emoji-${message.id}',
                                          ),
                                          emoji: emojiOnlyMessage,
                                        )
                                      : MarkdownBody(
                                          data: message.content,
                                          selectable: true,
                                          inlineSyntaxes: [
                                            _EmojiMarkdownSyntax(),
                                          ],
                                          builders: {
                                            'pre': _CodeBlockBuilder(),
                                            'saraEmoji':
                                                _MarkdownEmojiBuilder(),
                                          },
                                          styleSheet:
                                              MarkdownStyleSheet.fromTheme(
                                                Theme.of(context),
                                              ).copyWith(
                                                p: const TextStyle(
                                                  color: _text,
                                                  fontSize: 14,
                                                  height: 1.4,
                                                ),
                                                pPadding: EdgeInsets.zero,
                                                h1: const TextStyle(
                                                  color: _text,
                                                  fontSize: 20,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                                h2: const TextStyle(
                                                  color: _text,
                                                  fontSize: 18,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                                h3: const TextStyle(
                                                  color: _text,
                                                  fontSize: 16,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                                code: const TextStyle(
                                                  color: _text,
                                                  backgroundColor: Color(
                                                    0xFF343A46,
                                                  ),
                                                  fontFamily: 'monospace',
                                                  fontSize: 13,
                                                ),
                                                codeblockDecoration:
                                                    const BoxDecoration(),
                                                blockquoteDecoration:
                                                    const BoxDecoration(
                                                      border: Border(
                                                        left: BorderSide(
                                                          color: Color(
                                                            0xFF596273,
                                                          ),
                                                          width: 3,
                                                        ),
                                                      ),
                                                    ),
                                              ),
                                        ),
                                ),
                              ),
                            AnimatedSize(
                              duration: const Duration(milliseconds: 140),
                              curve: Curves.easeOut,
                              alignment: Alignment.topCenter,
                              child: _isHovered && !_isEditing
                                  ? Container(
                                      key: const ValueKey(
                                        'user-message-actions',
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          IconButton(
                                            key: ValueKey(
                                              'delete-${message.id}',
                                            ),
                                            tooltip: appText('Delete'),
                                            onPressed: widget.deleteEnabled
                                                ? widget.onDelete
                                                : null,
                                            icon: const Icon(
                                              LucideIcons300.trash2,
                                              size: 20,
                                            ),
                                            color: const Color(0xFFFF8585),
                                            visualDensity:
                                                VisualDensity.compact,
                                            constraints:
                                                const BoxConstraints.tightFor(
                                                  width: 32,
                                                  height: 32,
                                                ),
                                            style: IconButton.styleFrom(
                                              backgroundColor:
                                                  Colors.transparent,
                                              foregroundColor: const Color(
                                                0xFFFF8585,
                                              ),
                                              hoverColor: const Color(
                                                0x22343A46,
                                              ),
                                              disabledForegroundColor:
                                                  const Color(
                                                    0xFFFF8585,
                                                  ).withValues(alpha: .5),
                                            ),
                                            padding: EdgeInsets.zero,
                                          ),
                                          IconButton(
                                            key: ValueKey(
                                              'copy-user-${message.id}',
                                            ),
                                            tooltip: appText(
                                              _isCopied ? 'Copied' : 'Copy',
                                            ),
                                            onPressed: _copyMessage,
                                            icon: Icon(
                                              _isCopied
                                                  ? LucideIcons300.check
                                                  : LucideIcons300.copy,
                                              size: 16,
                                            ),
                                            color: _muted,
                                            visualDensity:
                                                VisualDensity.compact,
                                            constraints:
                                                const BoxConstraints.tightFor(
                                                  width: 32,
                                                  height: 32,
                                                ),
                                            style: IconButton.styleFrom(
                                              backgroundColor:
                                                  Colors.transparent,
                                              foregroundColor: _muted,
                                              hoverColor: const Color(
                                                0x22343A46,
                                              ),
                                            ),
                                            padding: EdgeInsets.zero,
                                          ),
                                          IconButton(
                                            key: ValueKey('edit-${message.id}'),
                                            tooltip: appText('Edit'),
                                            onPressed: widget.editEnabled
                                                ? _startEditing
                                                : null,
                                            icon: const Icon(
                                              LucideIcons300.pencil,
                                              size: 20,
                                            ),
                                            color: _muted,
                                            visualDensity:
                                                VisualDensity.compact,
                                            constraints:
                                                const BoxConstraints.tightFor(
                                                  width: 32,
                                                  height: 32,
                                                ),
                                            style: IconButton.styleFrom(
                                              backgroundColor:
                                                  Colors.transparent,
                                              foregroundColor: _muted,
                                              hoverColor: const Color(
                                                0x22343A46,
                                              ),
                                            ),
                                            padding: EdgeInsets.zero,
                                          ),
                                          if (widget.branch != null) ...[
                                            const SizedBox(width: 2),
                                            _BranchNavigationButton(
                                              key: ValueKey(
                                                'branch-user-previous-${message.id}',
                                              ),
                                              direction:
                                                  _BranchArrowDirection.left,
                                              tooltip: appText(
                                                'Previous response',
                                              ),
                                              onPressed:
                                                  widget.branch!.activeIndex > 0
                                                  ? () => widget.onActivateBranch(
                                                      widget
                                                          .branch!
                                                          .alternatives[widget
                                                              .branch!
                                                              .activeIndex -
                                                          1],
                                                    )
                                                  : null,
                                            ),
                                            SizedBox(
                                              key: ValueKey(
                                                'branch-user-position-${message.id}',
                                              ),
                                              width: 28,
                                              height: 30,
                                              child: Center(
                                                child: Text(
                                                  '${widget.branch!.activeIndex + 1}/${widget.branch!.alternatives.length}',
                                                  style: const TextStyle(
                                                    color: _muted,
                                                    fontSize: 14,
                                                    fontWeight: FontWeight.w500,
                                                  ),
                                                ),
                                              ),
                                            ),
                                            _BranchNavigationButton(
                                              key: ValueKey(
                                                'branch-user-next-${message.id}',
                                              ),
                                              direction:
                                                  _BranchArrowDirection.right,
                                              tooltip: appText('Next response'),
                                              onPressed:
                                                  widget.branch!.activeIndex +
                                                          1 <
                                                      widget
                                                          .branch!
                                                          .alternatives
                                                          .length
                                                  ? () => widget.onActivateBranch(
                                                      widget
                                                          .branch!
                                                          .alternatives[widget
                                                              .branch!
                                                              .activeIndex +
                                                          1],
                                                    )
                                                  : null,
                                            ),
                                          ],
                                        ],
                                      ),
                                    )
                                  : const SizedBox(
                                      key: ValueKey(
                                        'user-message-actions-hidden',
                                      ),
                                    ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                if (widget.retryError != null) ...[
                  const SizedBox(height: 4),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 460),
                    child: Text(
                      widget.retryError!,
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                        color: Color(0xFFFF8585),
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
                if (widget.terminalActivities.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 520),
                    child: _TerminalActivityDisclosure(
                      activities: widget.terminalActivities,
                      expanded: _terminalActivityExpanded,
                      onToggle: () => setState(
                        () => _terminalActivityExpanded =
                            !_terminalActivityExpanded,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: SizedBox(
        width: double.infinity,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (message.role == 'model' &&
                widget.terminalActivities.isNotEmpty) ...[
              _TerminalActivityDisclosure(
                activities: widget.terminalActivities,
                expanded: _terminalActivityExpanded,
                onToggle: () => setState(
                  () => _terminalActivityExpanded = !_terminalActivityExpanded,
                ),
              ),
              const SizedBox(height: 2),
            ],
            if (widget.attachments.isNotEmpty) ...[
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: _AttachmentGrid(
                  key: const ValueKey('model-attachment-grid'),
                  attachments: widget.attachments,
                  onPreview: (attachment) =>
                      _openAttachmentPreview(context, attachment),
                  largeMedia: true,
                ),
              ),
              const SizedBox(height: 8),
            ],
            if (message.content.trim().isNotEmpty)
              emojiOnlyMessage != null
                  ? _AnimatedEmojiMessage(
                      key: ValueKey('animated-emoji-${message.id}'),
                      emoji: emojiOnlyMessage,
                    )
                  : MarkdownBody(
                      key: ValueKey('assistant-message-content-${message.id}'),
                      data: displayContent,
                      selectable: true,
                      onTapLink: (text, href, title) {
                        unawaited(_openExternalLink(href));
                      },
                      inlineSyntaxes: [_EmojiMarkdownSyntax()],
                      builders: {
                        'pre': _CodeBlockBuilder(),
                        'saraEmoji': _MarkdownEmojiBuilder(),
                      },
                      styleSheet:
                          MarkdownStyleSheet.fromTheme(
                            Theme.of(context),
                          ).copyWith(
                            p: const TextStyle(
                              color: _text,
                              fontSize: 14,
                              height: 1.75,
                            ),
                            code: const TextStyle(
                              color: _text,
                              backgroundColor: _surfaceRaised,
                              fontFamily: 'monospace',
                              fontSize: 13,
                            ),
                            codeblockDecoration: const BoxDecoration(),
                          ),
                    ),
            if (hasSearchResultsButton)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Material(
                    key: ValueKey(
                      'search-results-button-surface-${message.id}',
                    ),
                    color: Colors.transparent,
                    shape: const StadiumBorder(
                      side: BorderSide(color: _border),
                    ),
                    child: InkWell(
                      key: ValueKey('search-results-button-${message.id}'),
                      borderRadius: BorderRadius.circular(22),
                      onTap: widget.onShowSearchResults,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 11,
                          vertical: 6,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _StackedWebsiteIcons(
                              sources: resultSources.take(4).toList(),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              appText(
                                '{count} web pages',
                                values: {'count': resultSources.length},
                              ),
                              style: const TextStyle(
                                color: _text,
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            if (showInlineUrlPreview) ..._buildLinkPreviews(displayContent),
            if (!waitingForTerminalReply) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  if (widget.branch != null) ...[
                    _BranchNavigationButton(
                      key: ValueKey('branch-previous-${message.id}'),
                      direction: _BranchArrowDirection.left,
                      tooltip: appText('Previous response'),
                      onPressed: widget.branch!.activeIndex > 0
                          ? () => widget.onActivateBranch(
                              widget
                                  .branch!
                                  .alternatives[widget.branch!.activeIndex - 1],
                            )
                          : null,
                    ),
                    SizedBox(
                      key: ValueKey('branch-position-${message.id}'),
                      width: 28,
                      height: 30,
                      child: Center(
                        child: Text(
                          '${widget.branch!.activeIndex + 1}/${widget.branch!.alternatives.length}',
                          style: const TextStyle(
                            color: _muted,
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                    _BranchNavigationButton(
                      key: ValueKey('branch-next-${message.id}'),
                      direction: _BranchArrowDirection.right,
                      tooltip: appText('Next response'),
                      onPressed:
                          widget.branch!.activeIndex + 1 <
                              widget.branch!.alternatives.length
                          ? () => widget.onActivateBranch(
                              widget
                                  .branch!
                                  .alternatives[widget.branch!.activeIndex + 1],
                            )
                          : null,
                    ),
                    const SizedBox(width: 4),
                  ],
                  _IconButton(
                    icon: _isCopied
                        ? LucideIcons300.check
                        : LucideIcons300.copy,
                    tooltip: appText(_isCopied ? 'Copied' : 'Copy'),
                    onPressed: _copyMessage,
                    size: 18,
                  ),
                  const SizedBox(width: 7),
                  _IconButton(
                    key: ValueKey('like-${message.id}'),
                    icon: LucideIcons300.thumbsUp,
                    tooltip: appText(
                      widget.feedbackRating == 1 ? 'Liked' : 'Like',
                    ),
                    color: widget.feedbackRating == 1
                        ? const Color(0xFFB5BAC4)
                        : _muted,
                    selectedFill: widget.feedbackRating == 1
                        ? _FeedbackThumb.up
                        : null,
                    onPressed: _feedbackAction(1),
                    size: 18,
                  ),
                  const SizedBox(width: 7),
                  _IconButton(
                    key: ValueKey('dislike-${message.id}'),
                    icon: LucideIcons300.thumbsDown,
                    tooltip: appText(
                      widget.feedbackRating == -1 ? 'Disliked' : 'Dislike',
                    ),
                    color: widget.feedbackRating == -1
                        ? const Color(0xFFB5BAC4)
                        : _muted,
                    selectedFill: widget.feedbackRating == -1
                        ? _FeedbackThumb.down
                        : null,
                    onPressed: _feedbackAction(-1),
                    size: 18,
                  ),
                  const SizedBox(width: 7),
                  _AssistantReactionControl(
                    key: ValueKey('reaction-${message.id}'),
                    reaction: widget.reaction,
                    enabled:
                        widget.reactionEnabled &&
                        widget.feedbackUserMessageId != null,
                    onSelected: (reaction) {
                      final userMessageId = widget.feedbackUserMessageId;
                      if (userMessageId != null) {
                        widget.onSetReaction(
                          userMessageId,
                          message.id,
                          reaction,
                        );
                      }
                    },
                  ),
                  const SizedBox(width: 7),
                  _IconButton(
                    key: ValueKey('speech-${message.id}'),
                    icon: LucideIcons300.volume2,
                    activeIcon: LucideIcons300.volume2,
                    tooltip: appText(
                      widget.isSpeechPlaying
                          ? 'Stop speech'
                          : widget.isSpeechLoading
                          ? 'Preparing speech'
                          : 'Speech',
                    ),
                    onPressed: message.content.trim().isEmpty
                        ? null
                        : widget.onToggleSpeech,
                    color: widget.isSpeechPlaying || widget.isSpeechLoading
                        ? _accent
                        : _muted,
                    size: widget.isSpeechPlaying ? 20 : 19,
                    isActive: widget.isSpeechPlaying,
                    isLoading: widget.isSpeechLoading,
                  ),
                  const Spacer(),
                  _IconButton(
                    key: ValueKey('regenerate-${message.id}'),
                    icon: LucideIcons300.refreshCw,
                    tooltip: appText('Regenerate'),
                    onPressed: widget.regenerateEnabled
                        ? widget.onRegenerate
                        : null,
                    size: 19,
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  VoidCallback? _feedbackAction(int rating) {
    final userMessageId = widget.feedbackUserMessageId;
    if (!widget.feedbackEnabled || userMessageId == null) return null;
    return () => widget.onSetFeedback(
      userMessageId,
      widget.message.id,
      widget.feedbackRating == rating ? null : rating,
    );
  }

  List<Widget> _buildLinkPreviews(String content) {
    final links = _messageWebUris(content).take(5);
    return [
      for (final uri in links)
        FutureBuilder<LinkPreview?>(
          key: ValueKey('link-preview-request-$uri'),
          future: _linkPreviews.putIfAbsent(
            uri.toString(),
            () => _linkPreviewService.load(uri),
          ),
          builder: (context, snapshot) {
            if (snapshot.hasError || !snapshot.hasData) {
              return snapshot.connectionState == ConnectionState.waiting
                  ? const Padding(
                      padding: EdgeInsets.only(top: 10),
                      child: SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 1.5),
                      ),
                    )
                  : const SizedBox.shrink();
            }
            final preview = snapshot.data!;
            return _LinkPreviewCard(
              key: ValueKey(preview.uri.toString()),
              preview: preview,
            );
          },
        ),
    ];
  }

  Future<void> _openExternalLink(String? href) async {
    final uri = href == null ? null : Uri.tryParse(href);
    if (uri == null ||
        (uri.scheme != 'https' && uri.scheme != 'http') ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      return;
    }
    try {
      final result = await Process.run('xdg-open', [uri.toString()]);
      if (result.exitCode != 0) {
        throw ProcessException(
          'xdg-open',
          [uri.toString()],
          result.stderr.toString(),
          result.exitCode,
        );
      }
    } catch (error) {
      if (!mounted) return;
      _showToast(
        context,
        appText('Could not open link: {error}', values: {'error': error}),
        isError: true,
      );
    }
  }
}

class _WebsiteBadge extends StatefulWidget {
  const _WebsiteBadge({
    required this.uri,
    required this.size,
    required this.outlineColor,
    this.faviconBytes,
    this.loadFavicon = true,
  });

  final Uri uri;
  final double size;
  final Color outlineColor;
  final Uint8List? faviconBytes;
  final bool loadFavicon;

  @override
  State<_WebsiteBadge> createState() => _WebsiteBadgeState();
}

class _WebsiteBadgeState extends State<_WebsiteBadge> {
  late Future<Uint8List?> _faviconFuture;

  @override
  void initState() {
    super.initState();
    _faviconFuture = _loadFavicon();
  }

  @override
  void didUpdateWidget(covariant _WebsiteBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.uri != widget.uri ||
        oldWidget.faviconBytes != widget.faviconBytes) {
      _faviconFuture = _loadFavicon();
    }
  }

  Future<Uint8List?> _loadFavicon() async {
    final bytes =
        widget.faviconBytes ??
        (widget.loadFavicon
            ? await LinkPreviewService().loadFavicon(widget.uri)
            : null);
    if (bytes == null) return null;
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return bytes;
    final resized = img.copyResize(decoded, width: 32, height: 32);
    return Uint8List.fromList(img.encodePng(resized));
  }

  Widget _initial(String host) {
    return Text(
      host.isEmpty ? 'W' : host[0].toUpperCase(),
      style: TextStyle(
        color: Colors.white,
        fontSize: widget.size * 0.48,
        fontWeight: FontWeight.w600,
        height: 1,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final host = widget.uri.host.replaceFirst(RegExp(r'^www\.'), '');
    return FutureBuilder<Uint8List?>(
      future: _faviconFuture,
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        return Container(
          key: ValueKey('website-badge-${widget.uri}'),
          width: widget.size,
          height: widget.size,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: _surfaceRaised,
            shape: BoxShape.circle,
            border: Border.all(color: widget.outlineColor, width: 1.5),
          ),
          child: bytes == null
              ? _initial(host)
              : ClipOval(
                  child: Image.memory(
                    bytes,
                    width: widget.size,
                    height: widget.size,
                    fit: BoxFit.cover,
                    cacheWidth: widget.size.round() * 2,
                    cacheHeight: widget.size.round() * 2,
                    errorBuilder: (context, error, stackTrace) =>
                        _initial(host),
                  ),
                ),
        );
      },
    );
  }
}

class _StackedWebsiteIcons extends StatelessWidget {
  const _StackedWebsiteIcons({required this.sources});

  final List<_SearchResultSource> sources;

  @override
  Widget build(BuildContext context) {
    final visibleSources = sources.take(4).toList(growable: false);
    final width = visibleSources.isEmpty
        ? 20.0
        : 20.0 + (visibleSources.length - 1) * 11.0;
    return SizedBox(
      width: width,
      height: 20,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (var index = 0; index < visibleSources.length; index++)
            Positioned(
              left: index * 11,
              child: _WebsiteBadge(
                uri: visibleSources[index].uri,
                size: 20,
                outlineColor: _surfaceRaised,
              ),
            ),
        ],
      ),
    );
  }
}

class _SearchResultsPanel extends StatelessWidget {
  const _SearchResultsPanel({
    required this.sources,
    required this.messageDate,
    required this.onClose,
    required this.onOpen,
  });

  final List<_SearchResultSource> sources;
  final String messageDate;
  final VoidCallback onClose;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('search-results-panel'),
      decoration: const BoxDecoration(
        color: _surface,
        border: Border(left: BorderSide(color: _border)),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 15, 8, 13),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    appText('Search results'),
                    style: const TextStyle(
                      color: _text,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  key: const ValueKey('close-search-results'),
                  tooltip: appText('Close search results'),
                  onPressed: onClose,
                  icon: const Icon(LucideIcons300.x, size: 18),
                  color: _muted,
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: _border),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 88),
              itemCount: sources.length,
              separatorBuilder: (context, index) => const SizedBox(height: 4),
              itemBuilder: (context, index) => _SearchResultCard(
                source: sources[index],
                messageDate: messageDate,
                onOpen: onOpen,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SearchResultCard extends StatefulWidget {
  const _SearchResultCard({
    required this.source,
    required this.messageDate,
    required this.onOpen,
  });

  final _SearchResultSource source;
  final String messageDate;
  final ValueChanged<String> onOpen;

  @override
  State<_SearchResultCard> createState() => _SearchResultCardState();
}

class _SearchResultCardState extends State<_SearchResultCard> {
  late Future<LinkPreview?> _preview;

  @override
  void initState() {
    super.initState();
    _preview = LinkPreviewService().load(widget.source.uri);
  }

  @override
  void didUpdateWidget(covariant _SearchResultCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source.uri != widget.source.uri) {
      _preview = LinkPreviewService().load(widget.source.uri);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<LinkPreview?>(
      future: _preview,
      builder: (context, snapshot) {
        final preview = snapshot.data;
        final pageTitle = preview?.title.trim();
        final sourceTitle = widget.source.title.trim();
        final title =
            pageTitle != null &&
                pageTitle.isNotEmpty &&
                pageTitle != widget.source.uri.host
            ? pageTitle
            : sourceTitle.isNotEmpty && sourceTitle != widget.source.uri.host
            ? sourceTitle
            : widget.source.uri.toString();
        final siteName = preview?.siteName?.trim();
        final sourceLabel = siteName != null && siteName.isNotEmpty
            ? siteName
            : widget.source.uri.toString();
        final description = preview?.description;
        return Material(
          color: Colors.transparent,
          child: InkWell(
            key: ValueKey('search-result-card-${widget.source.uri}'),
            borderRadius: BorderRadius.circular(6),
            onTap: () => widget.onOpen(widget.source.uri.toString()),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      _WebsiteBadge(
                        uri: widget.source.uri,
                        size: 19,
                        outlineColor: _surface,
                        faviconBytes: preview?.faviconBytes,
                        loadFavicon: false,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '$sourceLabel | ${widget.messageDate}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: _muted, fontSize: 11),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: _text,
                      fontSize: 13,
                      height: 1.45,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (description != null && description.isNotEmpty) ...[
                    const SizedBox(height: 5),
                    Text(
                      description,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: _muted,
                        fontSize: 12,
                        height: 1.5,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _CodeBlockBuilder extends MarkdownElementBuilder {
  @override
  bool isBlockElement() => true;

  @override
  Widget visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final code = element.children?.whereType<md.Element>().firstWhere(
      (child) => child.tag == 'code',
      orElse: () => element,
    );
    final languageClass = code?.attributes['class'] ?? '';
    final language = languageClass.startsWith('language-')
        ? languageClass.substring('language-'.length).toLowerCase()
        : null;
    final source = element.textContent;
    return _CodeBlock(
      code: source.endsWith('\n')
          ? source.substring(0, source.length - 1)
          : source,
      language: language,
    );
  }
}

class _CodeBlock extends StatefulWidget {
  const _CodeBlock({required this.code, this.language});

  final String code;
  final String? language;

  @override
  State<_CodeBlock> createState() => _CodeBlockState();
}

class _CodeBlockState extends State<_CodeBlock> {
  bool _showCopy = false;
  bool _isCopied = false;
  Timer? _copyResetTimer;

  @override
  void dispose() {
    _copyResetTimer?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    try {
      await Clipboard.setData(ClipboardData(text: widget.code));
      _copyResetTimer?.cancel();
      if (mounted) setState(() => _isCopied = true);
      _showToast(context, appText('Code copied'));
      _copyResetTimer = Timer(const Duration(seconds: 2), () {
        if (mounted) setState(() => _isCopied = false);
      });
    } catch (error) {
      if (!mounted) return;
      _showToast(
        context,
        appText('Unable to copy code: {error}', values: {'error': error}),
        isError: true,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final lines = '\n'.allMatches(widget.code).length + 1;
    final height = (lines.clamp(1, 10) * 19.5 + 18).toDouble();
    final normalizedLanguage = _normalizeCodeLanguage(widget.language);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Focus(
        onFocusChange: (focused) => setState(() => _showCopy = focused),
        child: MouseRegion(
          onEnter: (_) => setState(() => _showCopy = true),
          onExit: (_) => setState(() => _showCopy = false),
          child: Stack(
            children: [
              Container(
                key: const ValueKey('markdown-code-block'),
                width: double.infinity,
                height: height,
                decoration: BoxDecoration(
                  color: const Color(0xFF1D2129),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: _border),
                ),
                clipBehavior: Clip.antiAlias,
                child: SingleChildScrollView(
                  scrollDirection: Axis.vertical,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: HighlightView(
                        widget.code,
                        language: normalizedLanguage,
                        theme: {
                          ...atomOneDarkTheme,
                          'root': const TextStyle(
                            color: Color(0xFFC9D5E8),
                            backgroundColor: Colors.transparent,
                          ),
                        },
                        padding: EdgeInsets.zero,
                        textStyle: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 13,
                          height: 1.5,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 5,
                right: 5,
                child: AnimatedOpacity(
                  opacity: _showCopy ? 1 : 0,
                  duration: const Duration(milliseconds: 120),
                  child: IgnorePointer(
                    ignoring: !_showCopy,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: _surfaceRaised,
                        border: Border.all(color: _border),
                        borderRadius: BorderRadius.circular(7),
                      ),
                      child: IconButton(
                        key: const ValueKey('copy-code-button'),
                        tooltip: appText(_isCopied ? 'Copied' : 'Copy code'),
                        onPressed: _copy,
                        visualDensity: VisualDensity.compact,
                        constraints: const BoxConstraints.tightFor(
                          width: 32,
                          height: 32,
                        ),
                        padding: EdgeInsets.zero,
                        icon: Icon(
                          _isCopied
                              ? LucideIcons300.check
                              : LucideIcons300.copy,
                          size: 15,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _normalizeCodeLanguage(String? language) {
  const aliases = <String, String>{
    'c++': 'cpp',
    'cxx': 'cpp',
    'cc': 'cpp',
    'h++': 'cpp',
    'c#': 'csharp',
    'cs': 'csharp',
    'fs': 'fsharp',
    'f#': 'fsharp',
    'js': 'javascript',
    'jsx': 'javascript',
    'mjs': 'javascript',
    'cjs': 'javascript',
    'ts': 'typescript',
    'tsx': 'typescript',
    'py': 'python',
    'py3': 'python',
    'rb': 'ruby',
    'rs': 'rust',
    'golang': 'go',
    'sh': 'bash',
    'shell': 'bash',
    'zsh': 'bash',
    'yml': 'yaml',
    'html': 'xml',
    'xhtml': 'xml',
    'svg': 'xml',
    'objc': 'objectivec',
    'obj-c': 'objectivec',
    'objective-c': 'objectivec',
    'kt': 'kotlin',
    'kts': 'kotlin',
    'md': 'markdown',
    'mdx': 'markdown',
    'ps1': 'powershell',
    'dockerfile': 'docker',
    'tf': 'hcl',
    'terraform': 'hcl',
    'make': 'makefile',
    'mk': 'makefile',
    'plaintext': 'plaintext',
    'text': 'plaintext',
    'txt': 'plaintext',
  };
  final normalized = language?.trim().toLowerCase();
  if (normalized == null || normalized.isEmpty) return 'plaintext';
  return aliases[normalized] ?? normalized;
}

class _LinkPreviewCard extends StatefulWidget {
  const _LinkPreviewCard({super.key, required this.preview});

  final LinkPreview preview;

  @override
  State<_LinkPreviewCard> createState() => _LinkPreviewCardState();
}

class _LinkPreviewCardState extends State<_LinkPreviewCard> {
  Player? _player;
  VideoController? _videoController;
  String? _videoError;
  double _mediaAspectRatio = 16 / 9;

  @override
  void initState() {
    super.initState();
    final videoUri = widget.preview.videoUri;
    final imageBytes = widget.preview.imageBytes;
    if (imageBytes != null) unawaited(_measureImage(imageBytes));
    if (videoUri != null) {
      try {
        MediaKit.ensureInitialized();
        final player = Player();
        _player = player;
        _videoController = VideoController(player);
        unawaited(_openVideo(player, videoUri));
      } catch (error) {
        _videoError = appText(
          'Unable to open video preview: {error}',
          values: {'error': error},
        );
      }
    }
  }

  Future<void> _measureImage(Uint8List bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      try {
        final frame = await codec.getNextFrame();
        final image = frame.image;
        final aspectRatio = image.width / image.height;
        image.dispose();
        if (!mounted) return;
        setState(() => _mediaAspectRatio = aspectRatio);
      } finally {
        codec.dispose();
      }
    } catch (error) {
      debugPrint('Unable to determine link preview image dimensions: $error');
    }
  }

  Future<void> _openVideo(Player player, Uri uri) async {
    try {
      await player.open(Media(uri.toString()), play: false);
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _videoError = appText(
          'Unable to play video preview: {error}',
          values: {'error': error},
        ),
      );
    }
  }

  @override
  void dispose() {
    final player = _player;
    if (player != null) unawaited(player.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final preview = widget.preview;
    final hasRichMedia = preview.imageBytes != null || preview.videoUri != null;
    if (!hasRichMedia) {
      return Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 580),
          child: Container(
            width: double.infinity,
            margin: const EdgeInsets.only(top: 10),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: _surface,
              borderRadius: BorderRadius.circular(11),
              border: Border.all(color: _border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  preview.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _text,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (preview.description case final description?) ...[
                  const SizedBox(height: 5),
                  Text(
                    description,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: _muted,
                      fontSize: 12,
                      height: 1.4,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = math.min(560.0, constraints.maxWidth);
          final height = (width / _mediaAspectRatio)
              .clamp(240.0, 315.0)
              .toDouble();
          return Container(
            key: const ValueKey('link-preview-rich-card'),
            width: width,
            height: height,
            margin: const EdgeInsets.only(top: 10),
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: const Color(0xFF1D2129),
              border: Border.all(color: _border),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Stack(
              alignment: Alignment.bottomLeft,
              children: [
                Positioned.fill(child: _buildMedia()),
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          Colors.black.withValues(alpha: 0.78),
                        ],
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        preview.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (preview.description case final description?) ...[
                        const SizedBox(height: 4),
                        Text(
                          description,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildMedia() {
    if (_videoError case final error?) {
      return ColoredBox(
        color: _surfaceRaised,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              error,
              style: const TextStyle(color: _muted, fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }
    final controller = _videoController;
    if (controller != null) {
      return Stack(
        alignment: Alignment.center,
        children: [
          Video(
            controller: controller,
            fit: BoxFit.cover,
            controls: NoVideoControls,
          ),
          if (_player case final player?)
            StreamBuilder<bool>(
              stream: player.stream.playing,
              initialData: false,
              builder: (context, snapshot) {
                final isPlaying = snapshot.data ?? false;
                return IconButton.filled(
                  tooltip: appText(isPlaying ? 'Pause video' : 'Play video'),
                  onPressed: () async {
                    if (isPlaying) {
                      await player.pause();
                    } else {
                      await player.play();
                    }
                  },
                  icon: Icon(
                    isPlaying ? LucideIcons300.pause : LucideIcons300.play,
                  ),
                );
              },
            ),
        ],
      );
    }
    final imageBytes = widget.preview.imageBytes;
    return imageBytes == null
        ? const ColoredBox(
            color: _surfaceRaised,
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          )
        : Image.memory(imageBytes, fit: BoxFit.cover);
  }
}

class _WelcomeView extends StatelessWidget {
  const _WelcomeView();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: const Color(0xFF263650),
              borderRadius: BorderRadius.circular(15),
            ),
            child: Image.asset(
              'assets/flutter_logo.png',
              key: const ValueKey('sara-app-logo'),
              width: 30,
              height: 30,
              fit: BoxFit.contain,
            ),
          ),
          const SizedBox(height: 19),
          Text(
            appText('What would you like to talk about?'),
            style: const TextStyle(
              color: _text,
              fontSize: 22,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.45,
            ),
          ),
          const SizedBox(height: 7),
          Text(
            appText('Write a question or idea. Sara is ready to help.'),
            style: const TextStyle(color: _muted, fontSize: 13),
          ),
        ],
      ),
    );
  }
}

class _Composer extends StatefulWidget {
  const _Composer({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onSend,
    required this.onModeChanged,
    required this.isWaitingForReply,
    required this.showInlineSettings,
    required this.onOpenSettings,
    required this.pendingTerminalCommandApproval,
    required this.terminalCommandActivity,
    required this.terminalCommandOutput,
    required this.terminalCommandRunning,
    required this.terminalCommandAutomaticallyAllowed,
    required this.onTerminalCommandDecision,
    required this.onStopTerminalCommand,
    this.clipboardImageReader,
    this.clipboardImageSaver,
    this.cameraSessionFactory,
    this.cameraImageSaver,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final Future<void> Function(
    String? text,
    List<ChatAttachment> attachments,
    bool allowAiReply,
  )
  onSend;
  final ValueChanged<bool> onModeChanged;
  final bool isWaitingForReply;
  final bool showInlineSettings;
  final VoidCallback onOpenSettings;
  final _PendingTerminalCommandApproval? pendingTerminalCommandApproval;
  final TerminalCommandRequest? terminalCommandActivity;
  final String terminalCommandOutput;
  final bool terminalCommandRunning;
  final bool terminalCommandAutomaticallyAllowed;
  final ValueChanged<TerminalApprovalDecision> onTerminalCommandDecision;
  final VoidCallback onStopTerminalCommand;
  final Future<Uint8List?> Function()? clipboardImageReader;
  final Future<ChatAttachment> Function(Uint8List bytes)? clipboardImageSaver;
  final CameraSessionFactory? cameraSessionFactory;
  final Future<ChatAttachment> Function(Uint8List bytes)? cameraImageSaver;

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  bool _ventMode = false;
  bool _isPastingClipboard = false;
  final List<ChatAttachment> _attachments = [];
  final _attachmentLink = LayerLink();
  final _emojiLink = LayerLink();
  OverlayEntry? _attachmentMenu;
  OverlayEntry? _emojiPicker;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_handleInputChanged);
  }

  void _handleInputChanged() {
    if (!mounted) return;
    setState(() {});
    widget.onModeChanged(!_ventMode);
  }

  Future<void> addDroppedFiles(List<DropItem> files) async {
    final selected = <ChatAttachment>[];
    for (final item in files) {
      final filePath = item.path;
      if (filePath.isEmpty || !File(filePath).existsSync()) {
        _showAttachmentError(appText('Dropped file cannot be accessed.'));
        continue;
      }
      if (isSensitiveAttachmentPath(filePath)) {
        _showAttachmentError(
          appText(
            'Sensitive file cannot be uploaded: {name}.',
            values: {'name': path.basename(filePath)},
          ),
        );
        continue;
      }
      final attachment = _attachmentFromPath(filePath);
      if (attachment == null) {
        _showAttachmentError(
          appText(
            'Unsupported file format: {name}.',
            values: {'name': path.basename(filePath)},
          ),
        );
        continue;
      }
      selected.add(attachment);
    }
    _appendAttachments(selected);
  }

  void _appendAttachments(List<ChatAttachment> selected) {
    if (!mounted || selected.isEmpty) return;
    final existingPaths = _attachments
        .map((item) => item.path)
        .whereType<String>()
        .toSet();
    final additions = selected
        .where((item) => item.path != null && existingPaths.add(item.path!))
        .toList(growable: false);
    if (additions.isNotEmpty) {
      setState(() => _attachments.addAll(additions));
    }
  }

  ChatAttachment? _attachmentFromPath(String filePath) {
    if (isSensitiveAttachmentPath(filePath)) return null;
    return ChatAttachment(
      id: _uuid.v4(),
      path: filePath,
      name: path.basename(filePath),
      mimeType: attachmentMimeType(filePath),
      expiresAtUtc: DateTime.now()
          .toUtc()
          .add(const Duration(hours: 24))
          .millisecondsSinceEpoch,
    );
  }

  Future<void> _pasteClipboardContent() async {
    if (_isPastingClipboard) return;
    _isPastingClipboard = true;
    try {
      if (Platform.isLinux) {
        final clipboardData = await Clipboard.getData(Clipboard.kTextPlain);
        final text = clipboardData?.text;
        if (text != null && text.isNotEmpty) {
          _pasteTextOrFiles(text);
          return;
        }

        final imageBytes =
            await (widget.clipboardImageReader ??
                _readClipboardImageFromSystem)();
        if (imageBytes != null) {
          final attachment = widget.clipboardImageSaver == null
              ? await _saveClipboardImage(imageBytes)
              : await widget.clipboardImageSaver!(imageBytes);
          _appendAttachments([attachment]);
        }
        return;
      }

      final clipboard = await ClipboardReader.readClipboard();
      final selected = <ChatAttachment>[];
      var foundImage = false;
      for (final item in clipboard.items) {
        const imageFormats = [
          Formats.png,
          Formats.jpeg,
          Formats.webp,
          Formats.gif,
          Formats.tiff,
        ];
        DataFormat<Uint8List>? imageFormat;
        for (final format in imageFormats) {
          if (item.hasValue(format)) {
            imageFormat = format;
            break;
          }
        }
        if (imageFormat != null) {
          final imageBytes = await item.readValue(imageFormat);
          if (imageBytes != null) {
            selected.add(await _saveClipboardImage(imageBytes));
            foundImage = true;
            continue;
          }
        }
        final fileUri = await item.readValue(Formats.fileUri);
        if (fileUri?.scheme == 'file') {
          final attachment = _attachmentFromPath(fileUri!.toFilePath());
          if (attachment != null) {
            selected.add(attachment);
            continue;
          }
        }
        final plainText = await item.readValue(Formats.plainText);
        if (plainText != null) {
          for (final line in plainText.split(RegExp(r'[\r\n]+'))) {
            final value = line.trim();
            final uri = Uri.tryParse(value);
            final filePath = uri?.scheme == 'file' ? uri!.toFilePath() : value;
            if (File(filePath).existsSync()) {
              final attachment = _attachmentFromPath(filePath);
              if (attachment != null) selected.add(attachment);
            }
          }
        }
      }

      if (selected.isNotEmpty) {
        _appendAttachments(selected);
        return;
      }
      if (!foundImage) {
        final text = await clipboard.readValue(Formats.plainText);
        if (text != null) _pasteTextOrFiles(text);
      }
    } catch (error) {
      debugPrint('Could not read clipboard contents: $error');
      if (mounted) {
        _showAttachmentError(
          appText(
            'Could not read the clipboard: {error}',
            values: {'error': error},
          ),
        );
      }
    } finally {
      _isPastingClipboard = false;
    }
  }

  void _pasteTextOrFiles(String text) {
    final selected = <ChatAttachment>[];
    for (final line in text.split(RegExp(r'[\r\n]+'))) {
      final value = line.trim();
      if (value.isEmpty) continue;
      final uri = Uri.tryParse(value);
      final filePath = uri?.scheme == 'file' ? uri!.toFilePath() : value;
      if (!File(filePath).existsSync()) continue;
      final attachment = _attachmentFromPath(filePath);
      if (attachment != null) selected.add(attachment);
    }
    if (selected.isNotEmpty) {
      _appendAttachments(selected);
    } else {
      _insertPastedText(text);
    }
  }

  Future<ChatAttachment> _saveClipboardImage(Uint8List bytes) async {
    return _saveAppManagedImage(
      bytes,
      name: 'clipboard-image.png',
      directoryName: 'clipboard-attachments',
      expiresAtUtc: DateTime.now()
          .toUtc()
          .add(const Duration(hours: 24))
          .millisecondsSinceEpoch,
    );
  }

  Future<ChatAttachment> _saveCameraImage(Uint8List bytes) async {
    return _saveAppManagedImage(
      bytes,
      name: 'camera-photo.png',
      directoryName: 'camera-attachments',
      inApplicationCache: true,
    );
  }

  Future<ChatAttachment> _saveAppManagedImage(
    Uint8List bytes, {
    required String name,
    required String directoryName,
    int? expiresAtUtc,
    bool inApplicationCache = false,
  }) async {
    final supportDirectory = inApplicationCache
        ? await getApplicationCacheDirectory()
        : await getApplicationSupportDirectory();
    final directory = Directory(
      path.join(supportDirectory.path, 'Sara', directoryName),
    );
    await directory.create(recursive: true);
    final file = File(path.join(directory.path, '${_uuid.v4()}.png'));
    final decodedImage = img.decodeImage(bytes);
    if (decodedImage == null) {
      throw StateError('Clipboard image could not be decoded.');
    }
    await file.writeAsBytes(img.encodePng(decodedImage), flush: true);
    return ChatAttachment(
      id: _uuid.v4(),
      path: file.path,
      name: name,
      mimeType: 'image/png',
      expiresAtUtc: expiresAtUtc,
      isClipboardCopy: true,
    );
  }

  void _insertPastedText(String text) {
    final controller = widget.controller;
    final selection = controller.selection;
    final start = selection.isValid
        ? selection.start.clamp(0, controller.text.length).toInt()
        : controller.text.length;
    final end = selection.isValid
        ? selection.end.clamp(0, controller.text.length).toInt()
        : controller.text.length;
    final updatedText = controller.text.replaceRange(start, end, text);
    controller.value = TextEditingValue(
      text: updatedText,
      selection: TextSelection.collapsed(offset: start + text.length),
    );
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleInputChanged);
    _attachmentMenu?.remove();
    _attachmentMenu = null;
    _emojiPicker?.remove();
    _emojiPicker = null;
    super.dispose();
  }

  void _toggleAttachmentMenu() {
    if (_attachmentMenu != null) {
      _closeAttachmentMenu();
      return;
    }
    _closeEmojiPicker();

    _attachmentMenu = OverlayEntry(
      builder: (context) => Stack(
        children: [
          Positioned.fill(
            child: Listener(
              onPointerSignal: (event) {
                if (event is PointerScrollEvent) _closeAttachmentMenu();
              },
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _closeAttachmentMenu,
                onVerticalDragStart: (_) => _closeAttachmentMenu(),
                child: const SizedBox.expand(),
              ),
            ),
          ),
          CompositedTransformFollower(
            link: _attachmentLink,
            showWhenUnlinked: false,
            targetAnchor: Alignment.topLeft,
            followerAnchor: Alignment.bottomLeft,
            offset: const Offset(0, -12),
            child: SizedBox(
              width: 252,
              child: _AttachmentMenu(
                onOpenCamera: _openCamera,
                onPickMedia: () {
                  _closeAttachmentMenu();
                  _pickAttachments(mediaOnly: true);
                },
                onPickFile: () {
                  _closeAttachmentMenu();
                  _pickAttachments(mediaOnly: false);
                },
              ),
            ),
          ),
        ],
      ),
    );
    Overlay.of(context).insert(_attachmentMenu!);
    setState(() {});
  }

  void _toggleEmojiPicker() {
    if (_emojiPicker != null) {
      _closeEmojiPicker();
      return;
    }
    _closeAttachmentMenu();

    _emojiPicker = OverlayEntry(
      builder: (context) => Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _closeEmojiPicker,
              child: const SizedBox.expand(),
            ),
          ),
          CompositedTransformFollower(
            link: _emojiLink,
            showWhenUnlinked: false,
            targetAnchor: Alignment.topLeft,
            followerAnchor: Alignment.bottomLeft,
            offset: const Offset(0, -12),
            child: _EmojiPicker(onSelected: _insertEmoji),
          ),
        ],
      ),
    );
    Overlay.of(context).insert(_emojiPicker!);
    setState(() {});
  }

  void _closeEmojiPicker() {
    final picker = _emojiPicker;
    if (picker == null) return;
    picker.remove();
    _emojiPicker = null;
    if (mounted) setState(() {});
  }

  void _insertEmoji(String emoji) {
    final controller = widget.controller;
    final selection = controller.selection;
    final start = selection.isValid
        ? selection.start.clamp(0, controller.text.length).toInt()
        : controller.text.length;
    final end = selection.isValid
        ? selection.end.clamp(0, controller.text.length).toInt()
        : controller.text.length;
    final updatedText = controller.text.replaceRange(start, end, emoji);
    controller.value = TextEditingValue(
      text: updatedText,
      selection: TextSelection.collapsed(offset: start + emoji.length),
    );
    widget.focusNode.requestFocus();
  }

  void _closeAttachmentMenu() {
    _attachmentMenu?.remove();
    _attachmentMenu = null;
    if (mounted) setState(() {});
  }

  Future<void> _pickAttachments({required bool mediaOnly}) async {
    try {
      final result = await FilePicker.pickFiles(
        type: mediaOnly ? FileType.media : FileType.any,
        dialogTitle: appText(
          mediaOnly ? 'Choose photos or videos' : 'Choose files',
        ),
      );
      if (result.isEmpty || !mounted) return;
      final selected = <ChatAttachment>[];
      for (final pickedFile in result) {
        final filePath = pickedFile.path;
        if (filePath == null) {
          _showAttachmentError(
            appText(
              'Could not read file location: {name}.',
              values: {'name': pickedFile.name},
            ),
          );
          continue;
        }
        if (isSensitiveAttachmentPath(filePath)) {
          _showAttachmentError(
            appText(
              'Sensitive file cannot be uploaded: {name}.',
              values: {'name': pickedFile.name},
            ),
          );
          continue;
        }
        final attachment = _attachmentFromPath(filePath);
        if (attachment == null) continue;
        if (mediaOnly &&
            !attachment.mimeType.startsWith('image/') &&
            !attachment.mimeType.startsWith('video/')) {
          continue;
        }
        if (!File(filePath).existsSync()) {
          _showAttachmentError(
            appText(
              'File not found: {name}',
              values: {'name': pickedFile.name},
            ),
          );
          continue;
        }
        selected.add(attachment);
      }
      _appendAttachments(selected);
    } catch (error) {
      if (mounted) {
        _showAttachmentError(
          appText(
            'Could not select attachment: {error}',
            values: {'error': error},
          ),
        );
      }
    }
  }

  Future<void> _openCamera() async {
    _closeAttachmentMenu();
    final capturedBytes = await showDialog<Uint8List>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _CameraCaptureDialog(
        sessionFactory:
            widget.cameraSessionFactory ?? CameraPreviewSession.open,
      ),
    );
    if (capturedBytes == null || !mounted) return;
    try {
      final saver = widget.cameraImageSaver ?? _saveCameraImage;
      final attachment = await saver(capturedBytes);
      if (mounted) _appendAttachments([attachment]);
    } catch (error) {
      if (mounted) {
        _showAttachmentError(
          appText(
            'Could not save camera photo: {error}',
            values: {'error': error},
          ),
        );
      }
    }
  }

  void _showAttachmentError(String message) {
    _showToast(context, message, isError: true);
  }

  void _removeAttachment(String id) {
    setState(() => _attachments.removeWhere((item) => item.id == id));
  }

  void _submitMessage() {
    final text = widget.controller.text;
    if (text.trim().isEmpty && _attachments.isEmpty) return;
    _closeEmojiPicker();
    _closeAttachmentMenu();
    widget.onSend(
      text,
      List<ChatAttachment>.unmodifiable(_attachments),
      !_ventMode,
    );
    setState(_attachments.clear);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact =
            constraints.maxHeight < 560 || constraints.maxWidth < 680;
        final canSubmit =
            widget.controller.text.trim().isNotEmpty || _attachments.isNotEmpty;
        return Padding(
          padding: EdgeInsets.fromLTRB(
            24,
            compact ? 4 : 10,
            24,
            compact ? 6 : 14,
          ),
          child: Center(
            heightFactor: 1,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.pendingTerminalCommandApproval != null ||
                      widget.terminalCommandActivity != null) ...[
                    _TerminalCommandApprovalCard(
                      approval: widget.pendingTerminalCommandApproval,
                      activity: widget.terminalCommandActivity,
                      output: widget.terminalCommandOutput,
                      isRunning: widget.terminalCommandRunning,
                      automaticallyAllowed:
                          widget.terminalCommandAutomaticallyAllowed,
                      onDecision: widget.onTerminalCommandDecision,
                      onStop: widget.onStopTerminalCommand,
                    ),
                    const SizedBox(height: 8),
                  ],
                  ClipRRect(
                    key: const ValueKey('footer-backdrop'),
                    borderRadius: BorderRadius.circular(22),
                    child: Container(
                      key: const ValueKey('chat-composer'),
                      decoration: BoxDecoration(
                        color: const Color(0xFF2A2B2F),
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(color: const Color(0xFF55565B)),
                      ),
                      padding: EdgeInsets.fromLTRB(
                        12,
                        compact ? 10 : 17,
                        12,
                        compact ? 8 : 11,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (_attachments.isNotEmpty) ...[
                            _AttachmentGrid(
                              attachments: _attachments,
                              onRemove: _removeAttachment,
                              onPreview: (attachment) =>
                                  _openAttachmentPreview(context, attachment),
                              compact: true,
                              compactRows: 1,
                              composerStyle: true,
                            ),
                            const SizedBox(width: 2),
                            SizedBox(height: compact ? 6 : 10),
                          ],
                          Focus(
                            onKeyEvent: (_, event) {
                              final enterResult = _handleEnterSubmission(
                                event,
                                widget.controller,
                                _submitMessage,
                              );
                              if (enterResult != KeyEventResult.ignored) {
                                return enterResult;
                              }
                              if (event is KeyDownEvent &&
                                  event.logicalKey == LogicalKeyboardKey.keyV &&
                                  (HardwareKeyboard.instance.isControlPressed ||
                                      HardwareKeyboard
                                          .instance
                                          .isMetaPressed)) {
                                unawaited(_pasteClipboardContent());
                                return KeyEventResult.handled;
                              }
                              return KeyEventResult.ignored;
                            },
                            child: TextField(
                              controller: widget.controller,
                              focusNode: widget.focusNode,
                              inputFormatters: [SmartTextInputFormatter()],
                              minLines: 1,
                              maxLines: compact ? 2 : 5,
                              textInputAction: TextInputAction.send,
                              textCapitalization: TextCapitalization.sentences,
                              onSubmitted: (_) => _submitMessage(),
                              decoration: InputDecoration(
                                hintText: appText(
                                  'Where your thoughts find a home...',
                                ),
                                hintStyle: TextStyle(
                                  color: _muted,
                                  fontSize: 14,
                                ),
                                filled: false,
                                fillColor: Colors.transparent,
                                border: InputBorder.none,
                                enabledBorder: InputBorder.none,
                                focusedBorder: InputBorder.none,
                                disabledBorder: InputBorder.none,
                                errorBorder: InputBorder.none,
                                focusedErrorBorder: InputBorder.none,
                                isDense: true,
                                contentPadding: EdgeInsets.zero,
                              ),
                              style: const TextStyle(
                                color: _text,
                                fontSize: 14,
                                height: 1.5,
                              ),
                            ),
                          ),
                          SizedBox(height: compact ? 6 : 14),
                          Row(
                            children: [
                              SizedBox(
                                width: 36,
                                height: 48,
                                child: CompositedTransformTarget(
                                  link: _attachmentLink,
                                  child: Tooltip(
                                    message: appText('Add attachment'),
                                    child: IconButton(
                                      key: const ValueKey(
                                        'composer-attachment-button',
                                      ),
                                      onPressed: _toggleAttachmentMenu,
                                      icon: Icon(
                                        _attachmentMenu == null
                                            ? LucideIcons300.plus
                                            : LucideIcons300.x,
                                        size: 26,
                                        color: _text,
                                      ),
                                      style: IconButton.styleFrom(
                                        backgroundColor: _surfaceRaised,
                                        foregroundColor: _text,
                                        padding: EdgeInsets.zero,
                                        tapTargetSize:
                                            MaterialTapTargetSize.shrinkWrap,
                                        minimumSize: const Size(36, 36),
                                        fixedSize: const Size(36, 36),
                                        shape: const CircleBorder(
                                          side: BorderSide.none,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 4),
                              SizedBox(
                                width: 36,
                                height: 48,
                                child: CompositedTransformTarget(
                                  link: _emojiLink,
                                  child: Tooltip(
                                    message: appText('Choose emoji'),
                                    child: IconButton(
                                      key: const ValueKey(
                                        'emoji-picker-button',
                                      ),
                                      onPressed: _toggleEmojiPicker,
                                      icon: Icon(
                                        LucideIcons300.smile,
                                        size: 20,
                                        color: Colors.white,
                                      ),
                                      style: IconButton.styleFrom(
                                        backgroundColor: Colors.transparent,
                                        overlayColor: Colors.transparent,
                                        padding: EdgeInsets.zero,
                                        tapTargetSize:
                                            MaterialTapTargetSize.shrinkWrap,
                                        minimumSize: const Size(36, 36),
                                        fixedSize: const Size(36, 36),
                                        shape: const CircleBorder(
                                          side: BorderSide.none,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              _ComposerMode(
                                key: const ValueKey('composer-mode-button'),
                                icon: LucideIcons300.volumeX,
                                label: appText('Vent'),
                                selected: _ventMode,
                                onTap: () {
                                  final newMode = !_ventMode;
                                  setState(() => _ventMode = newMode);
                                  widget.onModeChanged(!newMode);
                                },
                              ),
                              if (widget.showInlineSettings)
                                IconButton(
                                  tooltip: appText('Settings'),
                                  onPressed: widget.onOpenSettings,
                                  icon: const Icon(LucideIcons300.settings),
                                  color: _muted,
                                  visualDensity: VisualDensity.compact,
                                  constraints: const BoxConstraints.tightFor(
                                    width: 34,
                                    height: 34,
                                  ),
                                  padding: EdgeInsets.zero,
                                ),
                              const Spacer(),
                              SizedBox(
                                width: 40,
                                height: 40,
                                child: Tooltip(
                                  message: appText('Send message'),
                                  child: FilledButton(
                                    key: const ValueKey(
                                      'submit-message-button',
                                    ),
                                    onPressed: _submitMessage,
                                    style: FilledButton.styleFrom(
                                      backgroundColor: canSubmit
                                          ? const Color(0xFF3D70D8)
                                          : const Color(0xFF3A4B6A),
                                      foregroundColor: canSubmit
                                          ? const Color(0xFFE7EEFF)
                                          : const Color(0xFFA9B8D3),
                                      padding: EdgeInsets.zero,
                                      minimumSize: Size.zero,
                                      elevation: 0,
                                      shadowColor: Colors.transparent,
                                      side: BorderSide(
                                        color: canSubmit
                                            ? const Color(0xFF6388CB)
                                            : Colors.transparent,
                                        width: canSubmit ? 0.25 : 0,
                                      ),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(50),
                                      ),
                                    ),
                                    child: widget.isWaitingForReply
                                        ? const SizedBox(
                                            key: ValueKey(
                                              'submit-message-spinner',
                                            ),
                                            width: 20,
                                            height: 20,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2.4,
                                              color: Colors.white,
                                            ),
                                          )
                                        : const Icon(
                                            LucideIcons300.arrowUp,
                                            key: ValueKey(
                                              'submit-message-icon',
                                            ),
                                            size: 27,
                                          ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ComposerMode extends StatelessWidget {
  const _ComposerMode({
    super.key,
    required this.icon,
    required this.label,
    this.selected = false,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: label,
      child: Material(
        color: selected ? const Color(0xFF263650) : _surfaceRaised,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: selected ? _accent : const Color(0xFF3B4351),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 18, color: selected ? _accent : _text),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    color: selected ? _accent : _text,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EmojiChoice {
  const _EmojiChoice(this.emoji);

  final emoji_picker.Emoji emoji;

  String get characters => emoji.emoji;
}

final _emojiChoices = emojiSetEnglish
    .expand((group) => group.emoji.map((item) => _EmojiChoice(item)))
    .toList(growable: false);

class _EmojiPicker extends StatefulWidget {
  const _EmojiPicker({required this.onSelected});

  final ValueChanged<String> onSelected;

  @override
  State<_EmojiPicker> createState() => _EmojiPickerState();
}

class _EmojiPickerState extends State<_EmojiPicker> {
  String _query = '';

  List<_EmojiChoice> get _filteredChoices {
    final query = _query.trim().toLowerCase();
    return _emojiChoices
        .where(
          (choice) =>
              (query.isEmpty ||
              choice.emoji.keywords.any(
                (keyword) => keyword.toLowerCase().contains(query),
              ) ||
              choice.characters.contains(query)),
        )
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final width = math.min(348.0, MediaQuery.sizeOf(context).width - 32);
    final choices = _filteredChoices;
    return Material(
      color: const Color(0xFF25272C),
      borderRadius: BorderRadius.circular(16),
      elevation: 16,
      child: Container(
        key: const ValueKey('emoji-picker-panel'),
        width: width,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: const Color(0xFF25272C),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFF4A4D55)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: 38,
              child: TextField(
                key: const ValueKey('emoji-picker-search'),
                onChanged: (value) => setState(() => _query = value),
                style: const TextStyle(color: _text, fontSize: 13),
                decoration: InputDecoration(
                  hintText: appText('Search emoji'),
                  hintStyle: const TextStyle(color: _muted, fontSize: 13),
                  prefixIcon: const Icon(LucideIcons300.search, size: 16),
                  prefixIconColor: _muted,
                  filled: true,
                  fillColor: _surface,
                  contentPadding: const EdgeInsets.symmetric(vertical: 8),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: _border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: _border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: _accent),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 210,
              child: choices.isEmpty
                  ? Center(
                      child: Text(
                        appText('No emoji found'),
                        style: const TextStyle(color: _muted, fontSize: 12),
                      ),
                    )
                  : GridView.builder(
                      key: const ValueKey('emoji-picker-grid'),
                      padding: EdgeInsets.zero,
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 8,
                            mainAxisSpacing: 2,
                            crossAxisSpacing: 2,
                          ),
                      itemCount: choices.length,
                      itemBuilder: (context, index) {
                        final choice = choices[index];
                        return IconButton(
                          key: ValueKey(
                            'emoji-picker-item-${choice.characters}',
                          ),
                          onPressed: () => widget.onSelected(choice.characters),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints.expand(),
                          icon: Text(
                            choice.characters,
                            style: const TextStyle(
                              fontFamily: _emojiFontFamily,
                              fontSize: 22,
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AssistantReactionControl extends StatefulWidget {
  const _AssistantReactionControl({
    super.key,
    required this.reaction,
    required this.enabled,
    required this.onSelected,
  });

  final String? reaction;
  final bool enabled;
  final ValueChanged<String?> onSelected;

  @override
  State<_AssistantReactionControl> createState() =>
      _AssistantReactionControlState();
}

class _AssistantReactionControlState extends State<_AssistantReactionControl> {
  static const _quickReactions = ['👍', '❤️', '😂', '😮', '😢', '🙏'];
  final Object _tapRegionGroup = Object();
  OverlayEntry? _overlayEntry;
  Timer? _closeTimer;
  Offset _pickerOffset = Offset.zero;
  bool _showFullPicker = false;
  bool _pinnedOpen = false;

  void _openQuickReactions() {
    if (!widget.enabled) return;
    _closeTimer?.cancel();
    if (_overlayEntry != null) {
      if (!_showFullPicker) _overlayEntry!.markNeedsBuild();
      return;
    }
    _pickerOffset = _pickerPosition(width: 252, height: 46);
    _showFullPicker = false;
    _overlayEntry = OverlayEntry(builder: _buildOverlay);
    Overlay.of(context).insert(_overlayEntry!);
  }

  Offset _pickerPosition({required double width, required double height}) {
    final target = context.findRenderObject();
    if (target is! RenderBox || !target.hasSize) return Offset.zero;
    final targetTopLeft = target.localToGlobal(Offset.zero);
    final targetBottom = targetTopLeft.dy + target.size.height;
    final screenSize = MediaQuery.sizeOf(context);
    final below = targetTopLeft.dy < height + 16;
    return Offset(
      targetTopLeft.dx.clamp(8.0, screenSize.width - width - 8),
      (below ? targetBottom + 8 : targetTopLeft.dy - height - 8).clamp(
        8.0,
        screenSize.height - height - 8,
      ),
    );
  }

  void _handleTap() {
    if (widget.reaction != null) {
      _closePicker();
      widget.onSelected(null);
      return;
    }
    if (_overlayEntry != null && _pinnedOpen && !_showFullPicker) {
      _closePicker();
      return;
    }
    _pinnedOpen = true;
    _openQuickReactions();
  }

  void _openFullPicker() {
    _closeTimer?.cancel();
    _pickerOffset = _pickerPosition(
      width: math.min(348, MediaQuery.sizeOf(context).width - 32),
      height: 360,
    );
    _pinnedOpen = true;
    _showFullPicker = true;
    _overlayEntry?.markNeedsBuild();
  }

  void _selectReaction(String reaction) {
    _closePicker();
    widget.onSelected(widget.reaction == reaction ? null : reaction);
  }

  void _scheduleClose() {
    if (_pinnedOpen || _showFullPicker) return;
    _closeTimer?.cancel();
    _closeTimer = Timer(const Duration(milliseconds: 220), _closePicker);
  }

  void _closePicker() {
    _closeTimer?.cancel();
    _closeTimer = null;
    _overlayEntry?.remove();
    _overlayEntry = null;
    _showFullPicker = false;
    _pinnedOpen = false;
  }

  Widget _buildOverlay(BuildContext context) {
    return Stack(
      children: [
        const Positioned.fill(child: IgnorePointer(child: SizedBox.expand())),
        Positioned(
          left: _pickerOffset.dx,
          top: _pickerOffset.dy,
          child: TapRegion(
            groupId: _tapRegionGroup,
            onTapOutside: (_) => _closePicker(),
            child: _showFullPicker
                ? _EmojiPicker(onSelected: _selectReaction)
                : MouseRegion(
                    onEnter: (_) {
                      _closeTimer?.cancel();
                      _closeTimer = null;
                    },
                    onExit: (_) => _scheduleClose(),
                    child: _QuickReactionCapsule(
                      reactions: _quickReactions,
                      selectedReaction: widget.reaction,
                      onSelected: _selectReaction,
                      onMore: _openFullPicker,
                    ),
                  ),
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _closeTimer?.cancel();
    _overlayEntry?.remove();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TapRegion(
      groupId: _tapRegionGroup,
      child: MouseRegion(
        onEnter: (_) => _openQuickReactions(),
        onExit: (_) => _scheduleClose(),
        child: IconButton(
          key: const ValueKey('assistant-reaction-button'),
          tooltip: appText('Reaction'),
          onPressed: widget.enabled ? _handleTap : null,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 28, height: 30),
          icon: widget.reaction == null
              ? Icon(
                  LucideIcons300.smile,
                  size: 18,
                  color: widget.enabled ? _muted : _muted.withValues(alpha: .5),
                )
              : Text(
                  widget.reaction!,
                  style: const TextStyle(
                    fontFamily: _emojiFontFamily,
                    fontSize: 17,
                  ),
                ),
        ),
      ),
    );
  }
}

class _QuickReactionCapsule extends StatelessWidget {
  const _QuickReactionCapsule({
    required this.reactions,
    required this.selectedReaction,
    required this.onSelected,
    required this.onMore,
  });

  final List<String> reactions;
  final String? selectedReaction;
  final ValueChanged<String> onSelected;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF25272C),
      elevation: 12,
      shape: const StadiumBorder(side: BorderSide(color: Color(0xFF4A4D55))),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(
          key: const ValueKey('assistant-reaction-capsule'),
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final reaction in reactions)
              InkWell(
                key: ValueKey('quick-reaction-$reaction'),
                borderRadius: BorderRadius.circular(20),
                onTap: () => onSelected(reaction),
                child: Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: selectedReaction == reaction
                        ? const Color(0xFF3B4351)
                        : Colors.transparent,
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    reaction,
                    style: const TextStyle(
                      fontFamily: _emojiFontFamily,
                      fontSize: 19,
                    ),
                  ),
                ),
              ),
            IconButton(
              key: const ValueKey('more-reactions-button'),
              tooltip: appText('More emoji'),
              onPressed: onMore,
              icon: const Icon(LucideIcons300.plus, size: 18),
              color: _text,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 34, height: 34),
            ),
          ],
        ),
      ),
    );
  }
}

class _AttachmentGrid extends StatefulWidget {
  const _AttachmentGrid({
    super.key,
    required this.attachments,
    this.onRemove,
    this.onPreview,
    this.compact = false,
    this.compactRows = 1,
    this.largeMedia = false,
    this.composerStyle = false,
  });

  final List<ChatAttachment> attachments;
  final ValueChanged<String>? onRemove;
  final ValueChanged<ChatAttachment>? onPreview;
  final bool compact;
  final int compactRows;
  final bool largeMedia;
  final bool composerStyle;

  @override
  State<_AttachmentGrid> createState() => _AttachmentGridState();
}

class _AttachmentGridState extends State<_AttachmentGrid> {
  final String _thumbnailCacheId = _uuid.v4();
  final Map<String, bool> _fileExists = {};
  final Map<String, Size> _imageSizes = {};
  final Map<String, String> _videoThumbnails = {};
  final Set<String> _loadingImageSizes = {};
  final Set<String> _loadingVideoThumbnails = {};
  final Map<String, StreamSubscription<FileSystemEvent>> _directoryWatchers =
      {};

  @override
  void initState() {
    super.initState();
    _refreshFileStatus();
    _syncDirectoryWatchers();
  }

  @override
  void didUpdateWidget(covariant _AttachmentGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    _refreshFileStatus();
    _syncDirectoryWatchers();
  }

  @override
  void dispose() {
    for (final watcher in _directoryWatchers.values) {
      unawaited(watcher.cancel());
    }
    for (final thumbnailPath in _videoThumbnails.values) {
      try {
        File(thumbnailPath).deleteSync();
      } on FileSystemException catch (error) {
        debugPrint('Unable to remove temporary video thumbnail: $error');
      }
    }
    super.dispose();
  }

  Future<void> _deleteVideoThumbnail(String thumbnailPath) async {
    try {
      final thumbnail = File(thumbnailPath);
      if (await thumbnail.exists()) await thumbnail.delete();
    } on FileSystemException catch (error) {
      debugPrint('Unable to remove temporary video thumbnail: $error');
    }
  }

  void _syncDirectoryWatchers() {
    final directories = widget.attachments
        .map((attachment) => attachment.path)
        .whereType<String>()
        .map(path.dirname)
        .toSet();
    for (final directory in _directoryWatchers.keys.toList()) {
      if (!directories.contains(directory)) {
        unawaited(_directoryWatchers.remove(directory)!.cancel());
      }
    }
    for (final directory in directories) {
      if (_directoryWatchers.containsKey(directory) ||
          !Directory(directory).existsSync()) {
        continue;
      }
      try {
        _directoryWatchers[directory] = Directory(directory).watch().listen(
          (_) => _refreshFileStatus(),
          onError: (Object error, StackTrace stackTrace) {
            debugPrint('Attachment file watcher failed: $error');
          },
        );
      } on FileSystemException catch (error) {
        debugPrint('Attachment file watcher failed: $error');
      }
    }
  }

  void _refreshFileStatus() {
    var changed = false;
    for (final attachment in widget.attachments) {
      final filePath = attachment.path;
      final exists =
          filePath != null &&
          !attachment.isExpiredAt(
            DateTime.now().toUtc().millisecondsSinceEpoch,
          ) &&
          File(filePath).existsSync();
      if (exists &&
          attachment.mimeType.startsWith('image/') &&
          !_imageSizes.containsKey(filePath) &&
          _loadingImageSizes.add(filePath)) {
        unawaited(_loadImageSize(filePath));
      }
      if (exists &&
          attachment.mimeType.startsWith('video/') &&
          !_videoThumbnails.containsKey(attachment.id) &&
          _loadingVideoThumbnails.add(attachment.id)) {
        unawaited(_loadVideoThumbnail(attachment, filePath));
      }
      if (_fileExists[attachment.id] != exists) {
        _fileExists[attachment.id] = exists;
        changed = true;
      }
    }
    if (changed && mounted) setState(() {});
  }

  Future<void> _loadVideoThumbnail(
    ChatAttachment attachment,
    String filePath,
  ) async {
    final thumbnailPath = path.join(
      Directory.systemTemp.path,
      'sara-video-$_thumbnailCacheId-${attachment.id}.jpg',
    );
    final thumbnail = File(thumbnailPath);
    try {
      final result = await Process.run('ffmpeg', [
        '-hide_banner',
        '-loglevel',
        'error',
        '-ss',
        '0.1',
        '-i',
        filePath,
        '-frames:v',
        '1',
        '-vf',
        'scale=320:320:force_original_aspect_ratio=decrease',
        '-q:v',
        '4',
        '-y',
        thumbnailPath,
      ]);
      if (result.exitCode != 0) {
        throw ProcessException(
          'ffmpeg',
          const [],
          '${result.stderr}'.trim(),
          result.exitCode,
        );
      }
      if (!await thumbnail.exists() || await thumbnail.length() == 0) {
        throw FileSystemException(
          'ffmpeg did not produce a video thumbnail.',
          thumbnailPath,
        );
      }
      final stillAttached = widget.attachments.any(
        (item) => item.id == attachment.id && item.path == filePath,
      );
      if (!mounted || !stillAttached) {
        await thumbnail.delete();
        return;
      }
      setState(() => _videoThumbnails[attachment.id] = thumbnailPath);
    } on ProcessException catch (error) {
      debugPrint('Unable to generate video thumbnail: $error');
      await _deleteVideoThumbnail(thumbnailPath);
    } on FileSystemException catch (error) {
      debugPrint('Unable to generate video thumbnail: $error');
      await _deleteVideoThumbnail(thumbnailPath);
    } finally {
      _loadingVideoThumbnails.remove(attachment.id);
    }
  }

  Future<void> _loadImageSize(String filePath) async {
    try {
      final codec = await ui.instantiateImageCodec(
        await File(filePath).readAsBytes(),
      );
      try {
        final frame = await codec.getNextFrame();
        final image = frame.image;
        final size = Size(image.width.toDouble(), image.height.toDouble());
        image.dispose();
        if (mounted && File(filePath).existsSync()) {
          setState(() => _imageSizes[filePath] = size);
        }
      } finally {
        codec.dispose();
      }
    } catch (error) {
      debugPrint('Unable to read attachment dimensions for $filePath: $error');
    } finally {
      _loadingImageSizes.remove(filePath);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.compact) {
      return SizedBox(
        height: widget.composerStyle
            ? 68
            : widget.compactRows == 1
            ? 92
            : 192,
        child: ListView.builder(
          scrollDirection: Axis.horizontal,
          itemCount: (widget.attachments.length / widget.compactRows).ceil(),
          itemBuilder: (context, index) {
            final start = index * widget.compactRows;
            final end = math.min(
              start + widget.compactRows,
              widget.attachments.length,
            );
            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var itemIndex = start; itemIndex < end; itemIndex++) ...[
                    if (itemIndex > start) const SizedBox(height: 8),
                    if (widget.composerStyle &&
                        !widget.attachments[itemIndex].mimeType.startsWith(
                          'image/',
                        ) &&
                        !widget.attachments[itemIndex].mimeType.startsWith(
                          'video/',
                        ))
                      SizedBox(
                        height: 68,
                        child: Center(
                          child: _buildTile(widget.attachments[itemIndex]),
                        ),
                      )
                    else
                      _buildTile(widget.attachments[itemIndex]),
                  ],
                ],
              ),
            );
          },
        ),
      );
    }
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final attachment in widget.attachments) _buildTile(attachment),
      ],
    );
  }

  Widget _buildTile(ChatAttachment attachment) {
    final filePath = attachment.path;
    final exists = _fileExists[attachment.id] ?? false;
    final isImage = attachment.mimeType.startsWith('image/');
    final isVideo = attachment.mimeType.startsWith('video/');
    final tileSize = _tileSize(attachment, exists);
    return SizedBox(
      key: ValueKey('attachment-preview-tile-${attachment.id}'),
      width: tileSize.width,
      height: tileSize.height,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Material(
              color: const Color(0xFF1D2129),
              child: InkWell(
                key: ValueKey('preview-attachment-${attachment.id}'),
                onTap: exists ? () => widget.onPreview?.call(attachment) : null,
                child: widget.composerStyle && !isImage && !isVideo
                    ? _ComposerFileAttachmentTile(
                        attachment: attachment,
                        missing: !exists,
                      )
                    : !exists
                    ? _AttachmentFileTile(attachment: attachment, missing: true)
                    : isImage
                    ? Image.file(
                        File(filePath!),
                        fit: BoxFit.contain,
                        errorBuilder: (context, error, stackTrace) =>
                            _AttachmentFileTile(
                              attachment: attachment,
                              missing: true,
                            ),
                      )
                    : isVideo
                    ? _VideoAttachmentTile(
                        key: ValueKey(
                          'video-attachment-thumbnail-${attachment.id}',
                        ),
                        thumbnailPath: _videoThumbnails[attachment.id],
                      )
                    : _AttachmentFileTile(attachment: attachment),
              ),
            ),
          ),
          if (!widget.composerStyle ||
              isImage ||
              attachment.mimeType.startsWith('video/'))
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Color(0xCC000000)],
                  ),
                  borderRadius: BorderRadius.vertical(
                    bottom: Radius.circular(10),
                  ),
                ),
                child: Text(
                  attachment.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 10),
                ),
              ),
            ),
          if (widget.onRemove case final remove?)
            Positioned(
              top: 3,
              right: 3,
              child: Material(
                color: Colors.black54,
                shape: const CircleBorder(),
                child: InkWell(
                  key: ValueKey('remove-attachment-${attachment.id}'),
                  customBorder: const CircleBorder(),
                  onTap: () => remove(attachment.id),
                  child: const SizedBox(
                    width: 24,
                    height: 24,
                    child: Icon(
                      LucideIcons300.x,
                      color: Colors.white,
                      size: 15,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Size _tileSize(ChatAttachment attachment, bool exists) {
    if (widget.composerStyle) {
      if (attachment.mimeType.startsWith('image/') ||
          attachment.mimeType.startsWith('video/')) {
        return const Size.square(68);
      }
      return const Size(224, 52);
    }
    if (!exists) {
      return widget.largeMedia ? const Size(220, 150) : const Size(116, 92);
    }
    if (!attachment.mimeType.startsWith('image/')) {
      if (widget.largeMedia && attachment.mimeType.startsWith('video/')) {
        return const Size(320, 180);
      }
      if (widget.largeMedia) return const Size(220, 150);
      return attachment.mimeType.startsWith('video/')
          ? const Size(136, 77)
          : const Size(116, 92);
    }
    final filePath = attachment.path;
    final imageSize = filePath == null ? null : _imageSizes[filePath];
    if (imageSize == null || imageSize.width <= 0 || imageSize.height <= 0) {
      return widget.largeMedia ? const Size(220, 220) : const Size(92, 92);
    }
    final maxWidth = widget.largeMedia
        ? 320.0
        : widget.compact
        ? 136.0
        : 140.0;
    final maxHeight = widget.largeMedia
        ? 300.0
        : widget.compact
        ? 92.0
        : 160.0;
    final scale = math.min(
      maxWidth / imageSize.width,
      maxHeight / imageSize.height,
    );
    return Size(imageSize.width * scale, imageSize.height * scale);
  }
}

class _AttachmentFileTile extends StatelessWidget {
  const _AttachmentFileTile({required this.attachment, this.missing = false});

  final ChatAttachment attachment;
  final bool missing;

  @override
  Widget build(BuildContext context) {
    final isVideo = attachment.mimeType.startsWith('video/');
    return Container(
      color: const Color(0xFF1D2129),
      alignment: Alignment.center,
      child: missing
          ? const Icon(
              LucideIcons300.triangleAlert,
              color: Color(0xFFFFC857),
              size: 34,
            )
          : isVideo
          ? const Icon(LucideIcons300.circlePlay, color: Colors.white, size: 34)
          : const CustomPaint(
              key: ValueKey('attachment-preview-document-icon'),
              size: Size(28, 32),
              painter: _DocumentIconPainter(color: Colors.white),
            ),
    );
  }
}

class _DocumentIconPainter extends CustomPainter {
  const _DocumentIconPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final document = Path()
      ..moveTo(size.width * 0.2, size.height * 0.08)
      ..lineTo(size.width * 0.62, size.height * 0.08)
      ..lineTo(size.width * 0.84, size.height * 0.3)
      ..lineTo(size.width * 0.84, size.height * 0.9)
      ..quadraticBezierTo(
        size.width * 0.84,
        size.height * 0.96,
        size.width * 0.77,
        size.height * 0.96,
      )
      ..lineTo(size.width * 0.2, size.height * 0.96)
      ..quadraticBezierTo(
        size.width * 0.14,
        size.height * 0.96,
        size.width * 0.14,
        size.height * 0.9,
      )
      ..lineTo(size.width * 0.14, size.height * 0.14)
      ..quadraticBezierTo(
        size.width * 0.14,
        size.height * 0.08,
        size.width * 0.2,
        size.height * 0.08,
      )
      ..moveTo(size.width * 0.62, size.height * 0.08)
      ..lineTo(size.width * 0.62, size.height * 0.29)
      ..lineTo(size.width * 0.84, size.height * 0.29)
      ..moveTo(size.width * 0.29, size.height * 0.54)
      ..lineTo(size.width * 0.68, size.height * 0.54)
      ..moveTo(size.width * 0.29, size.height * 0.7)
      ..lineTo(size.width * 0.68, size.height * 0.7);
    canvas.drawPath(document, paint);
  }

  @override
  bool shouldRepaint(_DocumentIconPainter oldDelegate) =>
      oldDelegate.color != color;
}

class _VideoAttachmentTile extends StatelessWidget {
  const _VideoAttachmentTile({super.key, this.thumbnailPath});

  final String? thumbnailPath;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        if (thumbnailPath != null)
          Image.file(
            File(thumbnailPath!),
            key: const ValueKey('video-attachment-thumbnail-image'),
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) {
              debugPrint('Unable to display video thumbnail: $error');
              return const ColoredBox(color: Color(0xFF1D2129));
            },
          )
        else
          const ColoredBox(color: Color(0xFF1D2129)),
        const Center(
          child: Icon(
            LucideIcons300.circlePlay,
            color: Colors.white,
            size: 30,
            shadows: [Shadow(color: Colors.black87, blurRadius: 5)],
          ),
        ),
      ],
    );
  }
}

class _ComposerFileAttachmentTile extends StatelessWidget {
  const _ComposerFileAttachmentTile({
    required this.attachment,
    required this.missing,
  });

  final ChatAttachment attachment;
  final bool missing;

  @override
  Widget build(BuildContext context) {
    final extension = path.extension(attachment.name).toLowerCase();
    return Container(
      key: ValueKey('attachment-file-tile$extension'),
      decoration: BoxDecoration(
        color: const Color(0xFF303135),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF414247), width: 0.7),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: const Color(0xFF42444A),
              borderRadius: BorderRadius.circular(8),
            ),
            alignment: Alignment.center,
            child: missing
                ? const Icon(
                    LucideIcons300.triangleAlert,
                    color: Colors.white,
                    size: 21,
                  )
                : const CustomPaint(
                    key: const ValueKey('attachment-generic-file-icon'),
                    size: Size(23, 26),
                    painter: _DocumentIconPainter(color: Colors.white),
                  ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  attachment.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _text,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  missing ? appText('File unavailable') : extension,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: _muted, fontSize: 10),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

void _openAttachmentPreview(BuildContext context, ChatAttachment attachment) {
  final filePath = attachment.path;
  if (filePath == null ||
      attachment.isExpiredAt(DateTime.now().toUtc().millisecondsSinceEpoch) ||
      !File(filePath).existsSync()) {
    return;
  }
  showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (_) => _AttachmentPreviewDialog(attachment: attachment),
  );
}

class _AttachmentPreviewDialog extends StatefulWidget {
  const _AttachmentPreviewDialog({required this.attachment});

  final ChatAttachment attachment;

  @override
  State<_AttachmentPreviewDialog> createState() =>
      _AttachmentPreviewDialogState();
}

class _AttachmentPreviewDialogState extends State<_AttachmentPreviewDialog> {
  Player? _player;
  VideoController? _videoController;
  String? _playbackError;
  bool _isLoadingVideo = false;
  final _previewFocusNode = FocusNode();

  bool get _isVideo => widget.attachment.mimeType.startsWith('video/');

  @override
  void initState() {
    super.initState();
    if (_isVideo) {
      _isLoadingVideo = true;
      try {
        MediaKit.ensureInitialized();
        final player = Player();
        _player = player;
        _videoController = VideoController(player);
        unawaited(_openVideo(player));
      } catch (error) {
        _isLoadingVideo = false;
        _playbackError = appText(
          'Video cannot be played: {error}',
          values: {'error': error},
        );
      }
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _previewFocusNode.requestFocus();
    });
  }

  Future<void> _openVideo(Player player) async {
    try {
      final filePath = widget.attachment.path;
      if (filePath == null) return;
      await player.open(Media(Uri.file(filePath).toString()));
      if (mounted) setState(() => _isLoadingVideo = false);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isLoadingVideo = false;
        _playbackError = appText(
          'Video cannot be played: {error}',
          values: {'error': error},
        );
      });
    }
  }

  Future<void> _seekBy(int seconds) async {
    final player = _player;
    if (player == null) return;
    final duration = player.state.duration;
    final position = player.state.position + Duration(seconds: seconds);
    await player.seek(
      position < Duration.zero
          ? Duration.zero
          : position > duration
          ? duration
          : position,
    );
  }

  Future<void> _togglePlayback() async {
    final player = _player;
    if (player == null || _isLoadingVideo || _playbackError != null) return;
    await player.playOrPause();
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || !_isVideo) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.space) {
      unawaited(_togglePlayback());
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      unawaited(_seekBy(5));
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      unawaited(_seekBy(-5));
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    _previewFocusNode.dispose();
    final player = _player;
    if (player != null) unawaited(player.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final isImage = widget.attachment.mimeType.startsWith('image/');
    return Dialog(
      key: const ValueKey('attachment-preview-dialog'),
      backgroundColor: _surface,
      insetPadding: const EdgeInsets.all(24),
      child: Focus(
        focusNode: _previewFocusNode,
        onKeyEvent: _handleKey,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: screen.width * 0.88,
            maxHeight: screen.height * 0.88,
          ),
          child: Stack(
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          minWidth: 280,
                          maxWidth: math.min(640, screen.width * 0.84),
                          maxHeight: math.min(480, screen.height * 0.72),
                        ),
                        child: Center(
                          child: isImage
                              ? Image.file(
                                  key: const ValueKey(
                                    'attachment-preview-media',
                                  ),
                                  File(widget.attachment.path!),
                                  fit: BoxFit.contain,
                                  errorBuilder: (context, error, stackTrace) =>
                                      const _MissingAttachmentPreview(),
                                )
                              : _isVideo
                              ? _buildVideoPreview()
                              : _AttachmentFileTile(
                                  attachment: widget.attachment,
                                ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Positioned(
                top: 4,
                right: 4,
                child: IconButton(
                  key: const ValueKey('close-attachment-preview'),
                  tooltip: appText('Close preview'),
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(LucideIcons300.x),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildVideoPreview() {
    if (_playbackError case final error?) {
      return Center(
        child: Text(
          error,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Color(0xFFFF8585)),
        ),
      );
    }
    if (_isLoadingVideo || _videoController == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: Video(controller: _videoController!, controls: NoVideoControls),
    );
  }
}

class _MissingAttachmentPreview extends StatelessWidget {
  const _MissingAttachmentPreview();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(LucideIcons300.triangleAlert, color: Color(0xFFD99000), size: 44),
        SizedBox(height: 8),
        Text(appText('Attachment file not found.')),
      ],
    );
  }
}

class _CameraCaptureDialog extends StatefulWidget {
  const _CameraCaptureDialog({required this.sessionFactory});

  final CameraSessionFactory sessionFactory;

  @override
  State<_CameraCaptureDialog> createState() => _CameraCaptureDialogState();
}

class _CameraCaptureDialogState extends State<_CameraCaptureDialog> {
  CameraPreviewSession? _session;
  StreamSubscription<Uint8List>? _frameSubscription;
  Uint8List? _frame;
  String? _error;
  bool _isOpening = true;
  bool _isClosing = false;

  @override
  void initState() {
    super.initState();
    unawaited(_openSession());
  }

  Future<void> _openSession() async {
    CameraPreviewSession? session;
    try {
      session = await widget.sessionFactory();
      if (!mounted) {
        await session.dispose();
        return;
      }
      _session = session;
      _frameSubscription = session.frames.listen(
        (frame) {
          if (mounted) setState(() => _frame = frame);
        },
        onError: (Object error) {
          if (mounted) {
            setState(
              () => _error = appText(
                'Camera preview failed: {error}',
                values: {'error': error},
              ),
            );
          }
        },
        onDone: () {
          if (mounted && !_isClosing) {
            setState(() {
              _error ??= appText('Camera preview stopped unexpectedly.');
            });
          }
        },
      );
      if (mounted) setState(() => _isOpening = false);
    } catch (error) {
      var failure = error;
      if (session != null) {
        try {
          await session.dispose();
        } catch (closeError) {
          failure = StateError('$error; camera cleanup failed: $closeError');
        }
      }
      if (mounted) {
        setState(() {
          _isOpening = false;
          _error = appText(
            'Could not open camera: {error}',
            values: {'error': failure},
          );
        });
      }
    }
  }

  Future<void> _finish([Uint8List? capturedFrame]) async {
    if (_isClosing) return;
    setState(() => _isClosing = true);
    try {
      await _frameSubscription?.cancel();
      _frameSubscription = null;
      final session = _session;
      _session = null;
      await session?.dispose();
      if (mounted) Navigator.of(context).pop(capturedFrame);
    } catch (error) {
      if (mounted) {
        setState(() {
          _isClosing = false;
          _error = appText(
            'Could not close camera: {error}',
            values: {'error': error},
          );
        });
      }
    }
  }

  @override
  void dispose() {
    _frameSubscription?.cancel();
    final session = _session;
    if (session != null) {
      unawaited(
        session.dispose().catchError((Object error) {
          debugPrint('Could not close camera preview session: $error');
        }),
      );
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.sizeOf(context);
    final width = math.min(screenSize.width - 80, 1120.0);
    final height = math.min(screenSize.height - 80, 700.0);
    return Dialog(
      key: const ValueKey('camera-dialog'),
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(40),
      child: Container(
        key: const ValueKey('camera-frame'),
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: const Color(0xFF101113),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: const Color(0xFF55565B), width: 1.2),
          boxShadow: const [
            BoxShadow(
              color: Color(0x66000000),
              blurRadius: 28,
              offset: Offset(0, 12),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(17),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (_frame != null)
                Image.memory(
                  _frame!,
                  key: const ValueKey('camera-preview-image'),
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                )
              else
                Center(
                  child: _isOpening
                      ? const CircularProgressIndicator()
                      : Padding(
                          padding: const EdgeInsets.all(32),
                          child: Text(
                            _error ?? appText('Waiting for camera.'),
                            key: const ValueKey('camera-error'),
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Color(0xFFFF8585)),
                          ),
                        ),
                ),
              if (_error != null && _frame != null)
                Align(
                  alignment: Alignment.topCenter,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(80, 18, 80, 0),
                    child: Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Color(0xFFFF8585)),
                    ),
                  ),
                ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 20,
                child: Center(
                  child: IconButton(
                    key: const ValueKey('camera-capture'),
                    tooltip: appText('Capture photo'),
                    onPressed: _frame == null || _isClosing
                        ? null
                        : () => _finish(_frame),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 88,
                      height: 88,
                    ),
                    splashRadius: 48,
                    icon: const _CameraShutterIcon(),
                  ),
                ),
              ),
              Positioned(
                top: 8,
                right: 8,
                child: IconButton(
                  key: const ValueKey('camera-close'),
                  tooltip: appText('Close camera'),
                  onPressed: _isClosing ? null : () => _finish(),
                  style: IconButton.styleFrom(
                    shape: const CircleBorder(),
                    side: const BorderSide(color: Color(0xCCFFFFFF)),
                    backgroundColor: const Color(0x88000000),
                    foregroundColor: Colors.white,
                    fixedSize: const Size(40, 40),
                    padding: EdgeInsets.zero,
                  ),
                  icon: const Icon(LucideIcons300.x, size: 22),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CameraShutterIcon extends StatelessWidget {
  const _CameraShutterIcon();

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('camera-shutter-icon'),
      width: 72,
      height: 72,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0x66000000),
        border: Border.all(color: Colors.white, width: 4),
        boxShadow: const [BoxShadow(color: Color(0x99000000), blurRadius: 8)],
      ),
      alignment: Alignment.center,
      child: Container(
        width: 54,
        height: 54,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white,
        ),
      ),
    );
  }
}

class _AttachmentMenu extends StatelessWidget {
  const _AttachmentMenu({
    required this.onOpenCamera,
    required this.onPickMedia,
    required this.onPickFile,
  });

  final VoidCallback onOpenCamera;
  final VoidCallback onPickMedia;
  final VoidCallback onPickFile;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF202124),
      borderRadius: BorderRadius.circular(18),
      child: Container(
        key: const ValueKey('attachment-menu'),
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: const Color(0xFF34363A)),
          boxShadow: const [
            BoxShadow(
              color: Color(0x26000000),
              blurRadius: 28,
              offset: Offset(0, 10),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _AttachmentOption(
              icon: LucideIcons300.camera,
              label: appText('Camera'),
              onTap: onOpenCamera,
            ),
            _AttachmentOption(
              icon: LucideIcons300.image,
              label: appText('Photo'),
              onTap: onPickMedia,
            ),
            _AttachmentOption(
              icon: LucideIcons300.paperclip,
              label: appText('File'),
              onTap: onPickFile,
            ),
          ],
        ),
      ),
    );
  }
}

class _AttachmentOption extends StatelessWidget {
  const _AttachmentOption({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          height: 38,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              children: [
                Icon(icon, size: 18, color: const Color(0xFFE4E5E7)),
                const SizedBox(width: 12),
                Text(
                  label,
                  style: const TextStyle(
                    color: Color(0xFFE4E5E7),
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _IconButton extends StatelessWidget {
  const _IconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.color = _muted,
    this.activeIcon,
    this.selectedFill,
    this.size = 18,
    this.isActive = false,
    this.isLoading = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final Color color;
  final IconData? activeIcon;
  final _FeedbackThumb? selectedFill;
  final double size;
  final bool isActive;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: SizedBox(
        width: 30,
        height: 30,
        child: IconButton(
          onPressed: onPressed,
          icon: SizedBox(
            width: size,
            height: size,
            child: Stack(
              alignment: Alignment.center,
              children: [
                if (selectedFill != null)
                  CustomPaint(
                    key: ValueKey('feedback-fill-${selectedFill!.name}'),
                    size: Size.square(size),
                    painter: _FeedbackThumbFillPainter(selectedFill!),
                  ),
                if (isLoading)
                  SizedBox(
                    width: size - 2,
                    height: size - 2,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.8,
                      color: color,
                    ),
                  )
                else
                  Icon(
                    isActive ? activeIcon ?? icon : icon,
                    size: size,
                    color: color,
                  ),
              ],
            ),
          ),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 30, height: 30),
          splashRadius: 16,
          visualDensity: VisualDensity.compact,
        ),
      ),
    );
  }
}

enum _BranchArrowDirection { left, right }

class _BranchNavigationButton extends StatelessWidget {
  const _BranchNavigationButton({
    super.key,
    required this.direction,
    required this.tooltip,
    required this.onPressed,
  });

  final _BranchArrowDirection direction;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: SizedBox(
        width: 30,
        height: 30,
        child: IconButton(
          key: ValueKey('branch-arrow-${direction.name}'),
          onPressed: onPressed,
          tooltip: null,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 30, height: 30),
          splashRadius: 16,
          visualDensity: VisualDensity.compact,
          icon: CustomPaint(
            size: const Size.square(18),
            painter: _BranchArrowPainter(
              direction: direction,
              color: onPressed == null ? const Color(0xFF59616E) : _muted,
            ),
          ),
        ),
      ),
    );
  }
}

class _BranchArrowPainter extends CustomPainter {
  const _BranchArrowPainter({required this.direction, required this.color});

  final _BranchArrowDirection direction;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final centerY = size.height / 2;
    final headX = direction == _BranchArrowDirection.left
        ? size.width * 0.30
        : size.width * 0.70;
    final tailX = direction == _BranchArrowDirection.left
        ? size.width * 0.70
        : size.width * 0.30;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final path = Path()
      ..moveTo(tailX, size.height * 0.20)
      ..lineTo(headX, centerY)
      ..lineTo(tailX, size.height * 0.80);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_BranchArrowPainter oldDelegate) =>
      oldDelegate.direction != direction || oldDelegate.color != color;
}

enum _FeedbackThumb { up, down }

class _FeedbackThumbFillPainter extends CustomPainter {
  const _FeedbackThumbFillPainter(this.direction);

  final _FeedbackThumb direction;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 24;
    canvas.save();
    canvas.scale(scale);
    if (direction == _FeedbackThumb.down) {
      canvas.translate(24, 24);
      canvas.rotate(math.pi);
    }
    final path = Path()
      ..moveTo(1, 21)
      ..lineTo(5, 21)
      ..lineTo(5, 9)
      ..lineTo(1, 9)
      ..close()
      ..moveTo(23, 10)
      ..cubicTo(23, 8.9, 22.1, 8, 21, 8)
      ..lineTo(14.69, 8)
      ..lineTo(15.64, 3.43)
      ..lineTo(15.67, 3.11)
      ..cubicTo(15.67, 2.7, 15.5, 2.32, 15.23, 2.05)
      ..lineTo(13.83, 0.65)
      ..lineTo(7.25, 7.23)
      ..cubicTo(6.88, 7.59, 6.66, 8.09, 6.66, 8.64)
      ..lineTo(6.66, 18.64)
      ..cubicTo(6.66, 19.74, 7.56, 20.64, 8.66, 20.64)
      ..lineTo(17.66, 20.64)
      ..cubicTo(18.49, 20.64, 19.2, 20.14, 19.5, 19.42)
      ..lineTo(22.52, 12.37)
      ..cubicTo(22.61, 12.14, 22.66, 11.9, 22.66, 11.64)
      ..lineTo(22.66, 10)
      ..close();
    canvas.drawPath(
      path,
      Paint()..color = const Color(0xFFB5BAC4).withValues(alpha: 0.62),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_FeedbackThumbFillPainter oldDelegate) =>
      oldDelegate.direction != direction;
}

class _ScrollDownIconPainter extends CustomPainter {
  const _ScrollDownIconPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    final chevron = Path()
      ..moveTo(size.width * 0.2, size.height * 0.38)
      ..lineTo(size.width * 0.5, size.height * 0.68)
      ..lineTo(size.width * 0.8, size.height * 0.38);
    canvas.drawPath(chevron, paint);
  }

  @override
  bool shouldRepaint(covariant _ScrollDownIconPainter oldDelegate) => false;
}
