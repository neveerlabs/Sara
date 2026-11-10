import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:media_kit/media_kit.dart';

abstract interface class SpeechPlaybackController {
  ValueListenable<String?> get speakingMessageId;
  ValueListenable<String?> get loadingMessageId;

  Future<void> toggle({
    required String messageId,
    required String text,
    required String voice,
  });

  void dispose();
}

class SoundOfTextService {
  SoundOfTextService({
    http.Client? client,
    Uri? apiBaseUri,
    this.pollInterval = const Duration(milliseconds: 350),
    this.timeout = const Duration(seconds: 45),
  })  : apiBaseUri = apiBaseUri ?? Uri.https('api.soundoftext.com', ''),
        _client = client ?? http.Client();

  final http.Client _client;
  final Uri apiBaseUri;
  final Duration pollInterval;
  final Duration timeout;

  Future<Uri> createAudioUri({
    required String text,
    required String voice,
  }) async {
    final trimmedText = text.trim();
    if (trimmedText.isEmpty) {
      throw ArgumentError.value(text, 'text', 'Speech text cannot be empty.');
    }

    final createResponse = await _client
        .post(
          apiBaseUri.resolve('/sounds'),
          headers: const {'content-type': 'application/json'},
          body: jsonEncode({
            'engine': 'Google',
            'data': {'text': trimmedText, 'voice': voice},
          }),
        )
        .timeout(timeout);
    final createData = _decodeResponse(createResponse);
    final id = createData['id'];
    if (createResponse.statusCode < 200 ||
        createResponse.statusCode >= 300 ||
        createData['success'] != true ||
        id is! String ||
        id.isEmpty) {
      throw StateError(
        _errorMessage(createData, 'Sound of Text could not create speech.'),
      );
    }

    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(pollInterval);
      final response = await _client
          .get(apiBaseUri.resolve('/sounds/${Uri.encodeComponent(id)}'))
          .timeout(timeout);
      final data = _decodeResponse(response);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError(
          _errorMessage(data, 'Sound of Text could not retrieve speech.'),
        );
      }

      switch ((data['status'] as String? ?? '').toLowerCase()) {
        case 'pending':
          continue;
        case 'done':
          final location = data['location'];
          final uri = location is String ? Uri.tryParse(location) : null;
          if (uri == null ||
              uri.scheme != 'https' ||
              !uri.hasAuthority ||
              uri.host.isEmpty ||
              uri.userInfo.isNotEmpty) {
            throw StateError('Sound of Text returned an invalid audio URL.');
          }
          return uri;
        case 'error':
          throw StateError(
            _errorMessage(data, 'Sound of Text could not create speech.'),
          );
        default:
          throw StateError('Sound of Text returned an invalid status.');
      }
    }
    throw TimeoutException('Sound of Text took too long to create speech.');
  }

  void dispose() => _client.close();

  Map<String, dynamic> _decodeResponse(http.Response response) {
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Sound of Text returned invalid JSON.');
    }
    return decoded;
  }

  String _errorMessage(Map<String, dynamic> data, String fallback) {
    final message = data['message'];
    return message is String && message.isNotEmpty ? message : fallback;
  }
}

class SoundOfTextPlaybackController implements SpeechPlaybackController {
  SoundOfTextPlaybackController({SoundOfTextService? service})
      : _service = service ?? SoundOfTextService() {
    MediaKit.ensureInitialized();
    _player = Player();
    _completionSubscription = _player.stream.completed.listen((completed) {
      if (completed) _speakingMessageId.value = null;
    });
  }

  final SoundOfTextService _service;
  final ValueNotifier<String?> _speakingMessageId = ValueNotifier(null);
  final ValueNotifier<String?> _loadingMessageId = ValueNotifier(null);
  late final Player _player;
  StreamSubscription<bool>? _completionSubscription;
  int _requestGeneration = 0;

  @override
  ValueListenable<String?> get speakingMessageId => _speakingMessageId;

  @override
  ValueListenable<String?> get loadingMessageId => _loadingMessageId;

  @override
  Future<void> toggle({
    required String messageId,
    required String text,
    required String voice,
  }) async {
    final requestGeneration = ++_requestGeneration;
    if (_speakingMessageId.value == messageId ||
        _loadingMessageId.value == messageId) {
      _speakingMessageId.value = null;
      _loadingMessageId.value = null;
      await _player.stop();
      return;
    }

    _speakingMessageId.value = null;
    _loadingMessageId.value = messageId;
    try {
      await _player.stop();
      final audioUri = await _service.createAudioUri(text: text, voice: voice);
      if (requestGeneration != _requestGeneration) return;
      await _player.open(Media(audioUri.toString()), play: true);
      if (requestGeneration != _requestGeneration) {
        await _player.stop();
        return;
      }
      _loadingMessageId.value = null;
      _speakingMessageId.value = messageId;
    } catch (_) {
      if (requestGeneration == _requestGeneration) {
        _loadingMessageId.value = null;
        _speakingMessageId.value = null;
      }
      rethrow;
    }
  }

  @override
  void dispose() {
    _requestGeneration++;
    unawaited(_completionSubscription?.cancel());
    unawaited(_player.dispose());
    _service.dispose();
    _speakingMessageId.dispose();
    _loadingMessageId.dispose();
  }
}
