import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dart_sentencepiece_tokenizer/dart_sentencepiece_tokenizer.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

class _DigestCollector implements Sink<Digest> {
  Digest? digest;

  @override
  void add(Digest value) => digest = value;

  @override
  void close() {}
}

class LocalEmbeddingDownloadProgress {
  const LocalEmbeddingDownloadProgress({
    required this.assetName,
    required this.receivedBytes,
    required this.totalBytes,
  });

  final String assetName;
  final int receivedBytes;
  final int totalBytes;

  double? get fraction => totalBytes > 0 ? receivedBytes / totalBytes : null;
}

abstract interface class ConversationEmbeddingProvider {
  String get embeddingModelId;
  bool get isReady;
  Future<void> ensureReady();
  Future<List<double>> embedQuery(String text);
  Future<List<List<double>>> embedDocuments(List<String> texts);
  Future<void> dispose();
}

class LocalE5EmbeddingProvider implements ConversationEmbeddingProvider {
  LocalE5EmbeddingProvider({
    http.Client? client,
    void Function(LocalEmbeddingDownloadProgress progress)? onProgress,
    Future<Directory> Function()? supportDirectoryProvider,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       _onProgress = onProgress,
       _supportDirectoryProvider =
           supportDirectoryProvider ?? getApplicationSupportDirectory;

  static const modelId = 'intfloat/multilingual-e5-small-int8-v1';
  static const _repositoryRevision = '761b726dd34fb83930e26aab4e9ac3899aa1fa78';
  static const _modelFileName = 'model_quantized.onnx';
  static const _tokenizerFileName = 'tokenizer.json';
  static const _modelSize = 118308185;
  static const _tokenizerSize = 17082730;
  static const _modelSha256 =
      'f80102d3f2a1229f387d3c81909990d8945513e347b0eab049f7de3c6f98c193';
  static const _tokenizerSha256 =
      '0b44a9d7b51c3c62626640cda0e2c2f70fdacdc25bbbd68038369d14ebdf4c39';
  static const _modelUrl =
      'https://huggingface.co/Xenova/multilingual-e5-small/resolve/'
      '$_repositoryRevision/onnx/$_modelFileName';
  static const _tokenizerUrl =
      'https://huggingface.co/Xenova/multilingual-e5-small/resolve/'
      '$_repositoryRevision/$_tokenizerFileName';
  static const _maximumSequenceLength = 512;

  final http.Client _client;
  final bool _ownsClient;
  final void Function(LocalEmbeddingDownloadProgress progress)? _onProgress;
  final Future<Directory> Function() _supportDirectoryProvider;
  final OnnxRuntime _runtime = OnnxRuntime();
  Future<void>? _readyFuture;
  OrtSession? _session;
  SentencePieceTokenizer? _tokenizer;

  @override
  String get embeddingModelId => modelId;

  @override
  bool get isReady => _session != null && _tokenizer != null;

  @override
  Future<void> ensureReady() {
    if (isReady) return Future<void>.value();
    final pending = _readyFuture;
    if (pending != null) return pending;
    final future = _load();
    late final Future<void> tracked;
    tracked = future.whenComplete(() {
      if (!isReady && identical(_readyFuture, tracked)) {
        _readyFuture = null;
      }
    });
    _readyFuture = tracked;
    return tracked;
  }

  Future<void> _load() async {
    if (!Platform.isLinux && !Platform.isWindows && !Platform.isMacOS) {
      throw UnsupportedError(
        'Local conversation embeddings are not supported on this platform.',
      );
    }

    final supportDirectory = await _supportDirectoryProvider();
    final modelDirectory = Directory(
      path.join(supportDirectory.path, 'Sara', 'models', modelId),
    );
    await modelDirectory.create(recursive: true);
    final modelFile = File(path.join(modelDirectory.path, _modelFileName));
    final tokenizerFile = File(
      path.join(modelDirectory.path, _tokenizerFileName),
    );

    await Future.wait([
      _ensureAsset(
        file: modelFile,
        url: _modelUrl,
        expectedSize: _modelSize,
        expectedSha256: _modelSha256,
      ),
      _ensureAsset(
        file: tokenizerFile,
        url: _tokenizerUrl,
        expectedSize: _tokenizerSize,
        expectedSha256: _tokenizerSha256,
      ),
    ]);

    final tokenizer = await TokenizerJsonLoader.fromJsonFile(
      tokenizerFile.path,
    );
    tokenizer.enableTruncation(
      maxLength: _maximumSequenceLength,
      direction: SpTruncationDirection.right,
    );
    final session = await _runtime.createSession(
      modelFile.path,
      options: OrtSessionOptions(
        intraOpNumThreads: 2,
        interOpNumThreads: 1,
        useArena: true,
      ),
    );
    _tokenizer = tokenizer;
    _session = session;
  }

  Future<void> _ensureAsset({
    required File file,
    required String url,
    required int expectedSize,
    required String expectedSha256,
  }) async {
    if (await _isValidAsset(file, expectedSize, expectedSha256)) return;
    if (await file.exists()) await file.delete();

    final partialFile = File('${file.path}.part');
    if (await partialFile.exists()) await partialFile.delete();
    final request = http.Request('GET', Uri.parse(url));
    final response = await _client
        .send(request)
        .timeout(const Duration(minutes: 5));
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException(
        'Embedding model download failed (HTTP ${response.statusCode}).',
        uri: Uri.parse(url),
      );
    }

    final sink = partialFile.openWrite();
    var receivedBytes = 0;
    try {
      await for (final chunk in response.stream.timeout(
        const Duration(minutes: 2),
      )) {
        sink.add(chunk);
        receivedBytes += chunk.length;
        _onProgress?.call(
          LocalEmbeddingDownloadProgress(
            assetName: path.basename(file.path),
            receivedBytes: receivedBytes,
            totalBytes: response.contentLength ?? expectedSize,
          ),
        );
      }
      await sink.flush();
      await sink.close();
    } catch (_) {
      await sink.close();
      if (await partialFile.exists()) await partialFile.delete();
      rethrow;
    }

    if (!await _isValidAsset(partialFile, expectedSize, expectedSha256)) {
      await partialFile.delete();
      throw const FormatException(
        'Downloaded local embedding model failed integrity verification.',
      );
    }
    await partialFile.rename(file.path);
  }

  Future<bool> _isValidAsset(
    File file,
    int expectedSize,
    String expectedSha256,
  ) async {
    if (!await file.exists() || await file.length() != expectedSize) {
      return false;
    }
    final digestSink = _DigestCollector();
    final digestInput = sha256.startChunkedConversion(digestSink);
    await for (final chunk in file.openRead()) {
      digestInput.add(chunk);
    }
    digestInput.close();
    return digestSink.digest?.toString() == expectedSha256;
  }

  @override
  Future<List<double>> embedQuery(String text) => _embed('query: ', text);

  @override
  Future<List<List<double>>> embedDocuments(List<String> texts) async {
    if (texts.isEmpty) return const [];
    final vectors = <List<double>>[];
    for (final text in texts) {
      vectors.add(await _embed('passage: ', text));
    }
    return vectors;
  }

  Future<List<double>> _embed(String prefix, String text) async {
    await ensureReady();
    final tokenizer = _tokenizer!;
    final session = _session!;
    final encoding = tokenizer.encode('$prefix${text.trim()}');
    final tokenIds = Int64List.fromList(encoding.ids);
    final attentionMask = Int64List.fromList(encoding.attentionMask);
    final inputs = <String, OrtValue>{};
    final outputs = <String, OrtValue>{};
    try {
      inputs['input_ids'] = await OrtValue.fromList(tokenIds, [
        1,
        tokenIds.length,
      ]);
      if (session.inputNames.contains('attention_mask')) {
        inputs['attention_mask'] = await OrtValue.fromList(attentionMask, [
          1,
          attentionMask.length,
        ]);
      }
      if (session.inputNames.contains('token_type_ids')) {
        inputs['token_type_ids'] = await OrtValue.fromList(
          Int64List(attentionMask.length),
          [1, attentionMask.length],
        );
      }

      outputs.addAll(await session.run(inputs));
      final tokenOutput = outputs.values.cast<OrtValue?>().firstWhere(
        (output) => output!.shape.length == 3,
        orElse: () => null,
      );
      if (tokenOutput != null) {
        final shape = tokenOutput.shape;
        if (shape[0] != 1 || shape[1] != tokenIds.length || shape[2] <= 0) {
          throw const FormatException(
            'Local embedding model returned an invalid token tensor shape.',
          );
        }
        final flattened = await tokenOutput.asFlattenedList();
        return _meanPoolAndNormalize(
          flattened.map((value) => (value as num).toDouble()).toList(),
          attentionMask,
          hiddenSize: shape[2],
        );
      }

      final pooledOutput = outputs.values.cast<OrtValue?>().firstWhere(
        (output) => output!.shape.length == 2,
        orElse: () => null,
      );
      if (pooledOutput == null || pooledOutput.shape.first != 1) {
        throw const FormatException(
          'Local embedding model returned no usable embedding tensor.',
        );
      }
      final flattened = await pooledOutput.asFlattenedList();
      return _normalize(
        flattened.map((value) => (value as num).toDouble()).toList(),
      );
    } finally {
      for (final tensor in inputs.values) {
        await tensor.dispose();
      }
      for (final tensor in outputs.values) {
        await tensor.dispose();
      }
    }
  }

  static List<double> meanPoolAndNormalize(
    List<double> tokenValues,
    List<int> attentionMask, {
    required int hiddenSize,
  }) {
    if (hiddenSize <= 0 ||
        tokenValues.length != attentionMask.length * hiddenSize) {
      throw const FormatException(
        'Token embedding tensor has an invalid size.',
      );
    }
    final pooled = List<double>.filled(hiddenSize, 0);
    var tokenCount = 0;
    for (var token = 0; token < attentionMask.length; token++) {
      if (attentionMask[token] == 0) continue;
      tokenCount++;
      for (var dimension = 0; dimension < hiddenSize; dimension++) {
        pooled[dimension] += tokenValues[token * hiddenSize + dimension];
      }
    }
    if (tokenCount == 0) {
      throw const FormatException('Cannot pool an empty token sequence.');
    }
    for (var dimension = 0; dimension < hiddenSize; dimension++) {
      pooled[dimension] /= tokenCount;
    }
    return _normalize(pooled);
  }

  static List<double> _meanPoolAndNormalize(
    List<double> tokenValues,
    Int64List attentionMask, {
    required int hiddenSize,
  }) =>
      meanPoolAndNormalize(tokenValues, attentionMask, hiddenSize: hiddenSize);

  static List<double> _normalize(List<double> values) {
    final magnitude = math.sqrt(
      values.fold<double>(0, (sum, value) => sum + value * value),
    );
    if (magnitude == 0 || !magnitude.isFinite) {
      throw const FormatException(
        'Local embedding model returned an invalid vector.',
      );
    }
    return values.map((value) => value / magnitude).toList(growable: false);
  }

  @override
  Future<void> dispose() async {
    await _session?.close();
    _session = null;
    _tokenizer = null;
    _readyFuture = null;
    if (_ownsClient) _client.close();
  }
}
