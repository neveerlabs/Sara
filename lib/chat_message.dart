import 'dart:convert';

import 'terminal_command.dart';

String formatJakartaTimestamp(int createdAtUtc) {
  const weekdays = [
    'Senin',
    'Selasa',
    'Rabu',
    'Kamis',
    'Jumat',
    'Sabtu',
    'Minggu',
  ];
  const months = [
    'Januari',
    'Februari',
    'Maret',
    'April',
    'Mei',
    'Juni',
    'Juli',
    'Agustus',
    'September',
    'Oktober',
    'November',
    'Desember',
  ];
  final jakarta = DateTime.fromMillisecondsSinceEpoch(
    createdAtUtc,
    isUtc: true,
  ).add(const Duration(hours: 7));
  final weekday = weekdays[jakarta.weekday - 1];
  final month = months[jakarta.month - 1];
  final hour = jakarta.hour.toString().padLeft(2, '0');
  final minute = jakarta.minute.toString().padLeft(2, '0');
  return '$weekday, ${jakarta.day} $month ${jakarta.year}, $hour:$minute';
}

class ClarificationQuestion {
  const ClarificationQuestion({required this.question, required this.options});

  final String question;
  final List<String> options;

  Map<String, Object?> toMap() => {'question': question, 'options': options};

  factory ClarificationQuestion.fromMap(Map<String, Object?> map) {
    final question = map['question'];
    final rawOptions = map['options'];
    if (question is! String ||
        question.trim().isEmpty ||
        question.length > 1000 ||
        rawOptions is! List ||
        rawOptions.length < 2 ||
        rawOptions.length > 5 ||
        rawOptions.any((option) => option is! String)) {
      throw const FormatException('Stored clarification prompt is invalid.');
    }
    final options = rawOptions.cast<String>().map((option) => option.trim());
    if (options.any((option) => option.isEmpty || option.length > 160) ||
        options.map((option) => option.toLowerCase()).toSet().length !=
            rawOptions.length) {
      throw const FormatException('Stored clarification prompt is invalid.');
    }
    return ClarificationQuestion(
      question: question.trim(),
      options: List<String>.unmodifiable(options),
    );
  }
}

class ClarificationPrompt {
  const ClarificationPrompt({required this.questions, this.answers = const []});

  final List<ClarificationQuestion> questions;
  final List<String?> answers;

  String get question => questions.first.question;
  List<String> get options => questions.first.options;

  bool get isComplete =>
      answers.length == questions.length &&
      answers.every((answer) => answer != null);

  String? answerAt(int index) =>
      index >= 0 && index < answers.length ? answers[index] : null;

  ClarificationPrompt withAnswer(int index, String answer) {
    if (index < 0 || index >= questions.length) {
      throw RangeError.index(index, questions, 'index');
    }
    final normalizedAnswer = answer.trim();
    if (normalizedAnswer.isEmpty || normalizedAnswer.length > 4000) {
      throw const FormatException('Clarification answer is invalid.');
    }
    return ClarificationPrompt(
      questions: questions,
      answers: List<String?>.unmodifiable([
        for (var answerIndex = 0; answerIndex < questions.length; answerIndex++)
          answerIndex < index
              ? answerAt(answerIndex)
              : answerIndex == index
              ? normalizedAnswer
              : null,
      ]),
    );
  }

  Map<String, Object?> toMap() => {
    'questions': questions.map((question) => question.toMap()).toList(),
    'answers': [
      for (var index = 0; index < questions.length; index++) answerAt(index),
    ],
  };

  factory ClarificationPrompt.fromMap(Map<String, Object?> map) {
    final rawQuestions = map['questions'];
    final questions = rawQuestions is List
        ? _decodeQuestions(rawQuestions)
        : [ClarificationQuestion.fromMap(map)];
    final rawAnswers = map['answers'];
    final answers = rawAnswers == null
        ? List<String?>.filled(questions.length, null)
        : _decodeAnswers(rawAnswers, questions.length);
    return ClarificationPrompt(
      questions: List<ClarificationQuestion>.unmodifiable(questions),
      answers: List<String?>.unmodifiable(answers),
    );
  }

  static List<ClarificationQuestion> _decodeQuestions(List rawQuestions) {
    if (rawQuestions.isEmpty ||
        rawQuestions.length > 5 ||
        rawQuestions.any(
          (question) =>
              question is! Map || question.keys.any((key) => key is! String),
        )) {
      throw const FormatException('Stored clarification prompt is invalid.');
    }
    return rawQuestions
        .map(
          (question) => ClarificationQuestion.fromMap(
            Map<String, Object?>.from(question as Map),
          ),
        )
        .toList(growable: false);
  }

  static List<String?> _decodeAnswers(Object rawAnswers, int questionCount) {
    if (rawAnswers is! List ||
        rawAnswers.length != questionCount ||
        rawAnswers.any(
          (answer) =>
              answer != null &&
              (answer is! String ||
                  answer.trim().isEmpty ||
                  answer.length > 4000),
        )) {
      throw const FormatException('Stored clarification answers are invalid.');
    }
    return rawAnswers
        .map((answer) => answer is String ? answer.trim() : null)
        .toList(growable: false);
  }
}

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.role,
    required this.content,
    required this.timestamp,
    required this.createdAtUtc,
    this.parentMessageId,
    this.rating,
    this.reaction,
    this.terminalActivities = const [],
    this.clarification,
  });

  final String id;
  final String role;
  final String content;
  final String timestamp;
  final int createdAtUtc;
  final String? parentMessageId;
  final int? rating;
  final String? reaction;
  final List<TerminalCommandHistoryEntry> terminalActivities;
  final ClarificationPrompt? clarification;

  Map<String, Object?> toMap() => {
    'id': id,
    'role': role,
    'content': content,
    'timestamp': timestamp,
    'created_at_utc': createdAtUtc,
    'rating': rating,
    'reaction': reaction,
    'parent_message_id': parentMessageId,
    'terminal_command_data': jsonEncode(
      terminalActivities.map((entry) => entry.toMap()).toList(),
    ),
    'clarification_data': clarification == null
        ? null
        : jsonEncode(clarification!.toMap()),
  };

  ChatMessage withTerminalActivities(
    List<TerminalCommandHistoryEntry> activities,
  ) => ChatMessage(
    id: id,
    role: role,
    content: content,
    timestamp: timestamp,
    createdAtUtc: createdAtUtc,
    parentMessageId: parentMessageId,
    rating: rating,
    reaction: reaction,
    terminalActivities: activities,
    clarification: clarification,
  );

  ChatMessage withClarification(ClarificationPrompt value) => ChatMessage(
    id: id,
    role: role,
    content: content,
    timestamp: timestamp,
    createdAtUtc: createdAtUtc,
    parentMessageId: parentMessageId,
    rating: rating,
    reaction: reaction,
    terminalActivities: terminalActivities,
    clarification: value,
  );

  factory ChatMessage.fromMap(Map<String, Object?> map) {
    final rawActivities = map['terminal_command_data'];
    final decodedActivities = switch (rawActivities) {
      null => const <Object?>[],
      String json => jsonDecode(json) as List<Object?>,
      List<Object?> list => list,
      _ => throw const FormatException(
        'Message terminal command data is invalid.',
      ),
    };
    final rawClarification = map['clarification_data'];
    final clarification = switch (rawClarification) {
      null => null,
      String json => _decodeClarification(json),
      _ => throw const FormatException(
        'Message clarification data is invalid.',
      ),
    };
    return ChatMessage(
      id: map['id']! as String,
      role: map['role']! as String,
      content: map['content']! as String,
      timestamp: map['timestamp']! as String,
      createdAtUtc: map['created_at_utc']! as int,
      parentMessageId: map['parent_message_id'] as String?,
      rating: map['rating'] as int?,
      reaction: map['reaction'] as String?,
      terminalActivities: decodedActivities
          .map((activity) {
            if (activity is! Map ||
                activity.keys.any((key) => key is! String)) {
              throw const FormatException(
                'Message terminal command data is invalid.',
              );
            }
            return TerminalCommandHistoryEntry.fromMap(
              Map<String, Object?>.from(activity),
            );
          })
          .toList(growable: false),
      clarification: clarification,
    );
  }

  static ClarificationPrompt _decodeClarification(String json) {
    final decoded = jsonDecode(json);
    if (decoded is! Map || decoded.keys.any((key) => key is! String)) {
      throw const FormatException('Message clarification data is invalid.');
    }
    return ClarificationPrompt.fromMap(Map<String, Object?>.from(decoded));
  }
}
