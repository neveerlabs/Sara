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
    required this.type,
    required this.content,
    required this.timestamp,
    required this.createdAtUtc,
    this.parentMessageId,
  });

  final String id;
  final String role;
  final String type;
  final String content;
  final String timestamp;
  final int createdAtUtc;
  final String? parentMessageId;

  Map<String, Object?> toMap() => {
        'id': id,
        'role': role,
        'type': 'text',
        'content': content,
        'timestamp': timestamp,
        'created_at_utc': createdAtUtc,
        'parent_message_id': parentMessageId,
      };

  factory ChatMessage.fromMap(Map<String, Object?> map) => ChatMessage(
        id: map['id']! as String,
        role: map['role']! as String,
        type: 'text',
        content: map['content']! as String,
        timestamp: map['timestamp']! as String,
        createdAtUtc: map['created_at_utc']! as int,
        parentMessageId: map['parent_message_id'] as String?,
      );
}
