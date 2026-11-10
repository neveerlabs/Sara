import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sara_desktop/sound_of_text_service.dart';

void main() {
  test('creates Sound of Text audio and polls until it is ready', () async {
    final requests = <http.Request>[];
    var statusRequestCount = 0;
    final client = MockClient((request) async {
      requests.add(request);
      if (request.method == 'POST') {
        return http.Response(
          jsonEncode({'success': true, 'id': 'sound-id'}),
          200,
        );
      }
      statusRequestCount++;
      return http.Response(
        jsonEncode(statusRequestCount == 1
            ? {'status': 'Pending'}
            : {
                'status': 'Done',
                'location': 'https://cdn.soundoftext.com/audio.mp3',
              }),
        200,
      );
    });
    final service = SoundOfTextService(
      client: client,
      apiBaseUri: Uri.https('api.soundoftext.test', ''),
      pollInterval: Duration.zero,
    );
    addTearDown(service.dispose);

    final audioUri =
        await service.createAudioUri(text: 'Hello Sara', voice: 'en-US');

    expect(audioUri, Uri.https('cdn.soundoftext.com', '/audio.mp3'));
    expect(requests, hasLength(3));
    expect(requests.first.url.path, '/sounds');
    expect(jsonDecode(requests.first.body), {
      'engine': 'Google',
      'data': {'text': 'Hello Sara', 'voice': 'en-US'},
    });
    expect(requests[1].url.path, '/sounds/sound-id');
  });

  test('reports errors and rejects non-HTTPS audio locations', () async {
    final errorClient = MockClient((_) async => http.Response(
          jsonEncode({'success': false, 'message': 'service unavailable'}),
          503,
        ));
    final errorService = SoundOfTextService(
      client: errorClient,
      apiBaseUri: Uri.https('api.soundoftext.test', ''),
    );
    addTearDown(errorService.dispose);
    await expectLater(
      errorService.createAudioUri(text: 'Hello', voice: 'en-US'),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'service unavailable',
        ),
      ),
    );

    final invalidLocationService = SoundOfTextService(
      client: MockClient((_) async {
        if (_.method == 'POST') {
          return http.Response(
              jsonEncode({'success': true, 'id': 'sound'}), 200);
        }
        return http.Response(
          jsonEncode(
              {'status': 'Done', 'location': 'http://example.test/a.mp3'}),
          200,
        );
      }),
      apiBaseUri: Uri.https('api.soundoftext.test', ''),
      pollInterval: Duration.zero,
    );
    addTearDown(invalidLocationService.dispose);
    await expectLater(
      invalidLocationService.createAudioUri(text: 'Hello', voice: 'en-US'),
      throwsA(isA<StateError>()),
    );
  });
}
