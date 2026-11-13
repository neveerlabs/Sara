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
    );
  }
}
