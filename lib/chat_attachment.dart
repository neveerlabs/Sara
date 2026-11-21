class ChatAttachment {
  const ChatAttachment({
    required this.id,
    required this.path,
    required this.name,
    required this.mimeType,
    this.expiresAtUtc,
    bool isClipboardCopy = false,
    bool? isAppManagedCopy,
  }) : isAppManagedCopy = isAppManagedCopy ?? isClipboardCopy;

  final String id;
  final String? path;
  final String name;
  final String mimeType;
  final int? expiresAtUtc;
  final bool isAppManagedCopy;
  bool get isClipboardCopy => isAppManagedCopy;

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
    'is_clipboard_copy': isAppManagedCopy ? 1 : 0,
  };

  factory ChatAttachment.fromMap(Map<String, Object?> map) {
    final clipboardFlag = map['is_clipboard_copy'];
    return ChatAttachment(
      id: map['id']! as String,
      path: map['path'] as String?,
      name: map['name']! as String,
      mimeType: map['mime_type']! as String,
      expiresAtUtc: map['expires_at_utc'] as int?,
      isAppManagedCopy: clipboardFlag == true || clipboardFlag == 1,
    );
  }
}
