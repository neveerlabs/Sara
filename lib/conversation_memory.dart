class ConversationMemory {
  const ConversationMemory({
    required this.id,
    required this.title,
    required this.summary,
    required this.sourceMessageIds,
    required this.startAtUtc,
    required this.endAtUtc,
    required this.updatedAtUtc,
  });

  final String id;
  final String title;
  final String summary;
  final List<String> sourceMessageIds;
  final int startAtUtc;
  final int endAtUtc;
  final int updatedAtUtc;

  Map<String, Object?> toMap() => {
        'id': id,
        'title': title,
        'summary': summary,
        'source_message_ids': sourceMessageIds.join('\n'),
        'start_at_utc': startAtUtc,
        'end_at_utc': endAtUtc,
        'updated_at_utc': updatedAtUtc,
      };

  factory ConversationMemory.fromMap(Map<String, Object?> map) {
    final ids = (map['source_message_ids']! as String)
        .split('\n')
        .where((id) => id.isNotEmpty)
        .toList(growable: false);
    return ConversationMemory(
      id: map['id']! as String,
      title: map['title']! as String,
      summary: map['summary']! as String,
      sourceMessageIds: ids,
      startAtUtc: map['start_at_utc']! as int,
      endAtUtc: map['end_at_utc']! as int,
      updatedAtUtc: map['updated_at_utc']! as int,
    );
  }
}
