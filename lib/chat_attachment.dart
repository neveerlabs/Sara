class ChatAttachment {
  const ChatAttachment({
    required this.id,
    required this.path,
    required this.name,
    required this.mimeType,
    this.expiresAtUtc,
    this.isClipboardCopy = false,
  });

  final String id;
  final String? path;
  final String name;
  final String mimeType;
  final int? expiresAtUtc;
  final bool isClipboardCopy;

  bool isExpiredAt(int utcMilliseconds) =>
      path == null ||
      (expiresAtUtc != null && expiresAtUtc! <= utcMilliseconds);

  Map<String, Object?> toMap(String messageId) => {
        'id': id,
        'message_id': messageId,
        'path': path,
        'name': name,
        'mime_type': mimeType,
        'expires_at_utc': expiresAtUtc,
        'is_clipboard_copy': isClipboardCopy ? 1 : 0,
      };

  factory ChatAttachment.fromMap(Map<String, Object?> map) {
    final clipboardFlag = map['is_clipboard_copy'];
    return ChatAttachment(
      id: map['id']! as String,
      path: map['path'] as String?,
      name: map['name']! as String,
      mimeType: map['mime_type']! as String,
      expiresAtUtc: map['expires_at_utc'] as int?,
      isClipboardCopy: clipboardFlag == true || clipboardFlag == 1,
    );
  }
}
