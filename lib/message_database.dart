import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'chat_attachment.dart';
import 'chat_message.dart';
import 'conversation_memory.dart';
import 'sara_autonomy.dart';
import 'sara_inner_life.dart';
import 'terminal_command.dart';

class MessageBranchNavigation {
  const MessageBranchNavigation({
    required this.parentMessageId,
    required this.alternatives,
    required this.activeIndex,
  });

  final String parentMessageId;
  final List<String> alternatives;
  final int activeIndex;
}

Set<String> _terminalHistoryTerms(String text) => RegExp(r'[a-z0-9_./-]{2,}')
    .allMatches(text.toLowerCase())
    .map((match) => match.group(0)!)
    .toSet();

String _terminalHistoryResultKey(TerminalCommandHistoryEntry entry) {
  final signature = jsonEncode([
    entry.command,
    entry.workingDirectory,
    entry.exitCode,
    entry.stdout,
    entry.stderr,
    entry.error,
    entry.timedOut,
    entry.cancelled,
    entry.skipped,
    entry.outputTruncated,
  ]);
  return sha256.convert(utf8.encode(signature)).toString();
}

abstract interface class MessageStore {
  Future<List<ChatMessage>> loadMessages();
  Future<List<ChatMessage>> loadActiveMessages();
  Future<Map<String, MessageBranchNavigation>> loadMessageBranches();
  Future<List<String>> loadSubtreeMessageIds(String messageId);
  Future<List<ChatMessage>> activateMessageBranch(String messageId);
  Future<Map<String, List<ChatAttachment>>> loadAttachments();
  Future<List<ConversationMemory>> loadConversationMemories();
  Future<void> saveConversationMemory(ConversationMemory memory);
  Future<SaraInnerLife> loadSaraInnerLife();
  Future<SaraInnerLife> loadSaraInnerLifeForPath(List<String> activeMessageIds);
  Future<void> saveSaraInnerLife(SaraInnerLife state);
  Future<void> saveSaraInnerLifeForBranch(
    SaraInnerLife state,
    String branchMessageId,
  );
  Future<List<SaraPrivateThought>> loadPrivateThoughts({int? limit = 20});
  Future<void> saveTerminalCommandHistory(TerminalCommandHistoryEntry entry);
  Future<Map<String, List<TerminalCommandHistoryEntry>>>
      loadTerminalCommandActivities(Set<String> responseMessageIds);
  Future<List<Map<String, Object?>>> searchTerminalCommandHistory(
    String query, {
    int limit = 3,
  });
  Future<void> savePrivateThought(SaraPrivateThought thought);
  Future<bool> savePrivateThoughtIfSourcesExist(SaraPrivateThought thought);
  Future<bool> savePrivateThoughtIfActiveLeaf(
    SaraPrivateThought thought, {
    required String? expectedLeafId,
  });
  Future<bool> saveSaraInnerLifeIfActiveLeaf(
    SaraInnerLife state, {
    required String expectedLeafId,
  });
  Future<Map<String, int>> loadAssistantFeedback();
  Future<String?> loadFeedbackPreferenceSummary({
    Set<String>? activeMessageIds,
  });
  Future<void> saveAssistantFeedback(
    String userMessageId,
    String responseMessageId,
    int? rating,
  );
  Future<List<SaraAutonomyGoal>> loadAutonomyGoalsForPath(
    List<String> activeMessageIds,
  );
  Future<void> saveAutonomyGoalsForBranch(
    List<SaraAutonomyGoal> goals,
    String branchMessageId,
  );
  Future<List<ChatAttachment>> loadExpiredAttachments(int nowUtc);
  Future<void> expireAttachments(int nowUtc);
  Future<void> clearAttachmentPaths(List<String> paths);
  Future<void> saveMessage(ChatMessage message);
  Future<void> appendMessage(ChatMessage message);
  Future<bool> appendMessageIfActiveLeaf(
    ChatMessage message, {
    required String? expectedLeafId,
  });
  Future<void> saveMessageAttachments(
      String messageId, List<ChatAttachment> attachments);
  Future<void> saveExchange(List<ChatMessage> messages);
  Future<void> saveExchangeWithAttachments(
    List<ChatMessage> messages,
    String userMessageId,
    List<ChatAttachment> attachments, {
    Map<String, List<ChatAttachment>> additionalAttachments =
        const <String, List<ChatAttachment>>{},
  });
  Future<void> deleteMessage(String id);
  Future<void> deleteMessages(List<String> ids);
  Future<String?> readPersonalName();
  Future<void> writePersonalName(String name);
  Future<void> clearPersonalName();
  Future<void> clearMessages();
  Future<Map<String, Object?>> exportBackupData();
  Future<void> importBackupData(
    Map<String, Object?> tables, {
    required Map<String, String> clipboardPaths,
  });
  Future<void> close();
}

class SqliteMessageStore implements MessageStore {
  SqliteMessageStore._(this._database);

  static const _backupTables = [
    'message',
    'personal',
    'message_attachment',
    'conversation_memory',
    'sara_inner_life',
    'assistant_feedback',
    'feedback_preference',
    'active_child',
    'conversation_state',
    'sara_inner_life_branch',
    'sara_private_thought',
    'sara_autonomy_goal',
    'terminal_command_history',
    'terminal_command_activity_link',
  ];

  final Database _database;

  static Future<SqliteMessageStore> open() async {
    final supportDirectory = await getApplicationSupportDirectory();
    final appDirectory = Directory(path.join(supportDirectory.path, 'Sara'));
    await appDirectory.create(recursive: true);
    return openAtPath(path.join(appDirectory.path, 'message.sql'));
  }

  static Future<SqliteMessageStore> openAtPath(String databasePath) async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final database = await databaseFactory.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(
        version: 17,
        onCreate: (database, version) async {
          await _createMessageTable(database);
          await _createPersonalTable(database);
          await _createAttachmentTable(database);
          await _createConversationMemoryTable(database);
          await _createSaraInnerLifeTable(database);
          await _createAssistantFeedbackTables(database);
          await _createBranchTables(database);
          await _createInnerLifeBranchTable(database);
          await _createPrivateThoughtTable(database);
          await _createAutonomyGoalTable(database);
          await _createTerminalCommandHistoryTable(database);
          await _createTerminalCommandActivityLinkTable(database);
        },
        onUpgrade: (database, oldVersion, newVersion) async {
          if (oldVersion < 2) await _createPersonalTable(database);
          if (oldVersion < 3) {
            final messages = await database.query(
              'message',
              columns: ['id', 'created_at_utc'],
            );
            for (final message in messages) {
              await database.update(
                'message',
                {
                  'timestamp':
                      formatJakartaTimestamp(message['created_at_utc']! as int),
                },
                where: 'id = ?',
                whereArgs: [message['id']],
              );
            }
          }
          if (oldVersion < 4) await _createLegacyAttachmentTable(database);
          if (oldVersion < 5) await _migrateAttachmentExpiry(database);
          if (oldVersion < 6) await _createConversationMemoryTable(database);
          if (oldVersion < 7) await _createSaraInnerLifeTable(database);
          if (oldVersion < 8) await _createAssistantFeedbackTables(database);
          if (oldVersion < 9) await _migrateConversationBranches(database);
          if (oldVersion < 10) await _createInnerLifeBranchTable(database);
          if (oldVersion < 11) await _migrateMessageTypeToText(database);
          if (oldVersion < 12) await _createPrivateThoughtTable(database);
          if (oldVersion < 13) await _createAutonomyGoalTable(database);
          if (oldVersion >= 12 && oldVersion < 14) {
            await database.execute(
              'ALTER TABLE sara_private_thought '
              'ADD COLUMN is_remembered INTEGER NOT NULL DEFAULT 0 '
              'CHECK (is_remembered IN (0, 1))',
            );
          }
          if (oldVersion < 15) {
            await _createTerminalCommandHistoryTable(database);
          }
          if (oldVersion == 15) {
            await database.execute(
              'ALTER TABLE terminal_command_history '
              'ADD COLUMN response_message_id TEXT',
            );
            await database.execute(
              'CREATE INDEX terminal_command_history_response '
              'ON terminal_command_history(response_message_id)',
            );
          }
          if (oldVersion < 17) {
            await _createTerminalCommandActivityLinkTable(database);
            await _deduplicateTerminalCommandHistory(database);
          }
        },
      ),
    );
    return SqliteMessageStore._(database);
  }

  static Future<void> _createMessageTable(DatabaseExecutor database) async {
    await database.execute('''
      CREATE TABLE message (
        id TEXT PRIMARY KEY NOT NULL,
        role TEXT NOT NULL CHECK (role IN ('user', 'model')),
        type TEXT NOT NULL CHECK (type = 'text'),
        content TEXT NOT NULL,
        timestamp TEXT NOT NULL,
        created_at_utc INTEGER NOT NULL,
        parent_message_id TEXT
      )
    ''');
    await database.execute(
      'CREATE INDEX message_order ON message(created_at_utc ASC, id ASC)',
    );
  }

  static Future<void> _migrateMessageTypeToText(
    DatabaseExecutor database,
  ) async {
    await database.execute('''
      CREATE TABLE message_v11 (
        id TEXT PRIMARY KEY NOT NULL,
        role TEXT NOT NULL CHECK (role IN ('user', 'model')),
        type TEXT NOT NULL CHECK (type = 'text'),
        content TEXT NOT NULL,
        timestamp TEXT NOT NULL,
        created_at_utc INTEGER NOT NULL,
        parent_message_id TEXT
      )
    ''');
    await database.execute('''
      INSERT INTO message_v11 (
        id, role, type, content, timestamp, created_at_utc, parent_message_id
      )
      SELECT id, role, 'text', content, timestamp, created_at_utc,
             parent_message_id
      FROM message
    ''');
    await database.execute('DROP TABLE message');
    await database.execute(
      'ALTER TABLE message_v11 RENAME TO message',
    );
    await database.execute(
      'CREATE INDEX message_order ON message(created_at_utc ASC, id ASC)',
    );
    await database.execute(
      'CREATE INDEX message_parent ON message(parent_message_id)',
    );
  }

  static Future<void> _createPersonalTable(DatabaseExecutor database) {
    return database.execute('''
      CREATE TABLE personal (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        name TEXT NOT NULL
      )
    ''');
  }

  static Future<void> _createAttachmentTable(DatabaseExecutor database) async {
    await database.execute('''
      CREATE TABLE message_attachment (
        id TEXT NOT NULL,
        message_id TEXT NOT NULL,
        path TEXT,
        name TEXT NOT NULL,
        mime_type TEXT NOT NULL,
        expires_at_utc INTEGER,
        is_clipboard_copy INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (message_id, id)
      )
    ''');
    await database.execute(
      'CREATE INDEX message_attachment_expiry '
      'ON message_attachment(expires_at_utc)',
    );
  }

  static Future<void> _createConversationMemoryTable(
      DatabaseExecutor database) async {
    await database.execute('''
      CREATE TABLE conversation_memory (
        id TEXT PRIMARY KEY NOT NULL,
        title TEXT NOT NULL,
        summary TEXT NOT NULL,
        source_message_ids TEXT NOT NULL,
        start_at_utc INTEGER NOT NULL,
        end_at_utc INTEGER NOT NULL,
        updated_at_utc INTEGER NOT NULL
      )
    ''');
    await database.execute(
      'CREATE INDEX conversation_memory_time '
      'ON conversation_memory(end_at_utc DESC)',
    );
  }

  static Future<void> _createTerminalCommandHistoryTable(
    DatabaseExecutor database,
  ) async {
    await database.execute('''
      CREATE TABLE terminal_command_history (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        response_message_id TEXT,
        task_context TEXT NOT NULL,
        command TEXT NOT NULL,
        working_directory TEXT NOT NULL,
        exit_code INTEGER,
        stdout TEXT NOT NULL,
        stderr TEXT NOT NULL,
        error TEXT,
        timed_out INTEGER NOT NULL CHECK (timed_out IN (0, 1)),
        cancelled INTEGER NOT NULL CHECK (cancelled IN (0, 1)),
        skipped INTEGER NOT NULL CHECK (skipped IN (0, 1)),
        output_truncated INTEGER NOT NULL CHECK (output_truncated IN (0, 1)),
        created_at_utc INTEGER NOT NULL
      )
    ''');
    await database.execute(
      'CREATE INDEX terminal_command_history_time '
      'ON terminal_command_history(created_at_utc DESC)',
    );
    await database.execute(
      'CREATE INDEX terminal_command_history_response '
      'ON terminal_command_history(response_message_id)',
    );
  }

  static Future<void> _createTerminalCommandActivityLinkTable(
    DatabaseExecutor database,
  ) async {
    await database.execute('''
      CREATE TABLE terminal_command_activity_link (
        terminal_history_id INTEGER NOT NULL,
        response_message_id TEXT NOT NULL,
        PRIMARY KEY (terminal_history_id, response_message_id)
      )
    ''');
    await database.execute(
      'CREATE INDEX terminal_command_activity_response '
      'ON terminal_command_activity_link(response_message_id)',
    );
  }

  static Future<void> _deduplicateTerminalCommandHistory(
    DatabaseExecutor database,
  ) async {
    final rows = await database.query(
      'terminal_command_history',
      orderBy: 'id ASC',
    );
    final canonicalIdsByResult = <String, int>{};
    const contextSeparator = '\n\n---\n\n';

    Future<void> linkResponse(int historyId, String? responseId) async {
      if (responseId == null) return;
      await database.insert(
        'terminal_command_activity_link',
        {
          'terminal_history_id': historyId,
          'response_message_id': responseId,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }

    for (final row in rows) {
      final entry = TerminalCommandHistoryEntry.fromMap(row);
      final historyId = entry.id!;
      final resultKey = _terminalHistoryResultKey(entry);
      final canonicalId = canonicalIdsByResult[resultKey];
      await linkResponse(historyId, entry.responseMessageId);
      if (canonicalId == null) {
        canonicalIdsByResult[resultKey] = historyId;
        continue;
      }

      final canonicalRows = await database.query(
        'terminal_command_history',
        columns: ['task_context'],
        where: 'id = ?',
        whereArgs: [canonicalId],
        limit: 1,
      );
      final existingContext = canonicalRows.single['task_context']! as String;
      final contexts = existingContext.split(contextSeparator);
      if (entry.taskContext.isNotEmpty &&
          !contexts.contains(entry.taskContext)) {
        contexts.add(entry.taskContext);
        await database.update(
          'terminal_command_history',
          {'task_context': contexts.join(contextSeparator)},
          where: 'id = ?',
          whereArgs: [canonicalId],
        );
      }

      final linkedResponses = await database.query(
        'terminal_command_activity_link',
        columns: ['response_message_id'],
        where: 'terminal_history_id = ?',
        whereArgs: [historyId],
      );
      for (final link in linkedResponses) {
        await linkResponse(canonicalId, link['response_message_id']! as String);
      }
      await database.delete(
        'terminal_command_activity_link',
        where: 'terminal_history_id = ?',
        whereArgs: [historyId],
      );
      await database.delete(
        'terminal_command_history',
        where: 'id = ?',
        whereArgs: [historyId],
      );
    }
  }

  static Future<void> _createSaraInnerLifeTable(
      DatabaseExecutor database) async {
    await database.execute('''
      CREATE TABLE sara_inner_life (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        mood TEXT NOT NULL,
        mood_intensity INTEGER NOT NULL,
        energy INTEGER NOT NULL,
        drives_json TEXT NOT NULL,
        self_reflection TEXT NOT NULL,
        source_message_ids TEXT NOT NULL,
        updated_at_utc INTEGER NOT NULL
      )
    ''');
  }

  static Future<void> _createAssistantFeedbackTables(
      DatabaseExecutor database) async {
    await database.execute('''
      CREATE TABLE assistant_feedback (
        response_message_id TEXT PRIMARY KEY NOT NULL,
        user_message_id TEXT NOT NULL,
        rating INTEGER NOT NULL CHECK (rating IN (-1, 1)),
        is_concise INTEGER NOT NULL,
        has_list INTEGER NOT NULL,
        has_code INTEGER NOT NULL,
        updated_at_utc INTEGER NOT NULL
      )
    ''');
    await database.execute('''
      CREATE TABLE feedback_preference (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        summary TEXT NOT NULL,
        updated_at_utc INTEGER NOT NULL
      )
    ''');
  }

  static Future<void> _createBranchTables(DatabaseExecutor database) async {
    await database.execute('''
      CREATE TABLE active_child (
        parent_message_id TEXT PRIMARY KEY NOT NULL,
        child_message_id TEXT NOT NULL
      )
    ''');
    await database.execute('''
      CREATE TABLE conversation_state (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        active_leaf_message_id TEXT
      )
    ''');
    await database.execute(
      'CREATE INDEX message_parent ON message(parent_message_id)',
    );
    await database.insert('conversation_state', {
      'id': 1,
      'active_leaf_message_id': null,
    });
  }

  static Future<void> _createInnerLifeBranchTable(DatabaseExecutor database) {
    return database.execute('''
      CREATE TABLE sara_inner_life_branch (
        branch_message_id TEXT PRIMARY KEY NOT NULL,
        mood TEXT NOT NULL,
        mood_intensity INTEGER NOT NULL,
        energy INTEGER NOT NULL,
        drives_json TEXT NOT NULL,
        self_reflection TEXT NOT NULL,
        source_message_ids TEXT NOT NULL,
        updated_at_utc INTEGER NOT NULL
      )
    ''');
  }

  static Future<void> _createPrivateThoughtTable(
      DatabaseExecutor database) async {
    await database.execute('''
      CREATE TABLE sara_private_thought (
        id TEXT PRIMARY KEY NOT NULL,
        reflection TEXT NOT NULL,
        action TEXT NOT NULL CHECK (action IN ('think', 'rest', 'reach_out')),
        is_remembered INTEGER NOT NULL DEFAULT 0 CHECK (is_remembered IN (0, 1)),
        source_message_ids TEXT NOT NULL,
        created_at_utc INTEGER NOT NULL
      )
    ''');
    await database.execute(
      'CREATE INDEX sara_private_thought_time '
      'ON sara_private_thought(created_at_utc DESC)',
    );
  }

  static Future<void> _createAutonomyGoalTable(
      DatabaseExecutor database) async {
    await database.execute('''
      CREATE TABLE sara_autonomy_goal (
        id TEXT NOT NULL,
        branch_message_id TEXT NOT NULL,
        title TEXT NOT NULL,
        description TEXT NOT NULL,
        status TEXT NOT NULL CHECK (status IN ('active', 'completed')),
        source_message_ids TEXT NOT NULL,
        updated_at_utc INTEGER NOT NULL,
        PRIMARY KEY (id, branch_message_id)
      )
    ''');
    await database.execute(
      'CREATE INDEX sara_autonomy_goal_branch '
      'ON sara_autonomy_goal(branch_message_id)',
    );
  }

  static Future<void> _migrateConversationBranches(
    DatabaseExecutor database,
  ) async {
    await database.execute(
      'ALTER TABLE message ADD COLUMN parent_message_id TEXT',
    );
    await _createBranchTables(database);
    final rows = await database.query(
      'message',
      columns: ['id'],
      orderBy: 'created_at_utc ASC, id ASC',
    );
    String? parentId;
    for (final row in rows) {
      final messageId = row['id']! as String;
      if (parentId != null) {
        await database.update(
          'message',
          {'parent_message_id': parentId},
          where: 'id = ?',
          whereArgs: [messageId],
        );
        await database.insert('active_child', {
          'parent_message_id': parentId,
          'child_message_id': messageId,
        });
      }
      parentId = messageId;
    }
    await database.update(
      'conversation_state',
      {'active_leaf_message_id': parentId},
      where: 'id = ?',
      whereArgs: [1],
    );
  }

  static Future<void> _createLegacyAttachmentTable(DatabaseExecutor database) {
    return database.execute('''
      CREATE TABLE message_attachment (
        id TEXT PRIMARY KEY NOT NULL,
        message_id TEXT NOT NULL,
        path TEXT NOT NULL,
        name TEXT NOT NULL,
        mime_type TEXT NOT NULL
      )
    ''');
  }

  static Future<void> _migrateAttachmentExpiry(
      DatabaseExecutor database) async {
    final legacyRows = await database.rawQuery('''
      SELECT attachment.*, message.created_at_utc
      FROM message_attachment AS attachment
      LEFT JOIN message ON message.id = attachment.message_id
    ''');
    final migrationTime = DateTime.now().toUtc().millisecondsSinceEpoch;
    await database.execute('''
      CREATE TABLE message_attachment_v5 (
        id TEXT NOT NULL,
        message_id TEXT NOT NULL,
        path TEXT,
        name TEXT NOT NULL,
        mime_type TEXT NOT NULL,
        expires_at_utc INTEGER,
        is_clipboard_copy INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (message_id, id)
      )
    ''');
    for (final row in legacyRows) {
      final uploadedAt = row['created_at_utc'] as int? ?? migrationTime;
      await database.insert('message_attachment_v5', {
        'id': row['id'],
        'message_id': row['message_id'],
        'path': row['path'],
        'name': row['name'],
        'mime_type': row['mime_type'],
        'expires_at_utc': uploadedAt + const Duration(hours: 24).inMilliseconds,
        'is_clipboard_copy': 0,
      });
    }
    await database.execute('DROP TABLE message_attachment');
    await database.execute(
      'ALTER TABLE message_attachment_v5 RENAME TO message_attachment',
    );
    await database.execute(
      'CREATE INDEX message_attachment_expiry '
      'ON message_attachment(expires_at_utc)',
    );
  }

  @override
  Future<List<ChatMessage>> loadMessages() async {
    final rows = await _database.query(
      'message',
      orderBy: 'created_at_utc ASC, id ASC',
    );
    return rows.map(ChatMessage.fromMap).toList(growable: false);
  }

  @override
  Future<List<ChatMessage>> loadActiveMessages() async =>
      _loadActiveMessages(_database);

  static Future<List<ChatMessage>> _loadActiveMessages(
    DatabaseExecutor database,
  ) async {
    final rows = await database.query(
      'message',
      orderBy: 'created_at_utc ASC, id ASC',
    );
    if (rows.isEmpty) return const [];
    final byId = {for (final row in rows) row['id']! as String: row};
    final children = <String, List<String>>{};
    for (final row in rows) {
      final parentId = row['parent_message_id'] as String?;
      if (parentId != null && byId.containsKey(parentId)) {
        children.putIfAbsent(parentId, () => []).add(row['id']! as String);
      }
    }
    final activeRows = await database.query('active_child');
    final activeChild = {
      for (final row in activeRows)
        row['parent_message_id']! as String: row['child_message_id']! as String,
    };
    final root = rows.firstWhere(
      (row) => row['parent_message_id'] == null,
      orElse: () => rows.first,
    );
    final result = <ChatMessage>[];
    var currentId = root['id']! as String;
    final visited = <String>{};
    while (visited.add(currentId)) {
      final row = byId[currentId];
      if (row == null) break;
      result.add(ChatMessage.fromMap(row));
      final availableChildren = children[currentId] ?? const <String>[];
      if (availableChildren.isEmpty) break;
      final chosen = activeChild[currentId];
      currentId =
          availableChildren.contains(chosen) ? chosen! : availableChildren.last;
    }
    return result;
  }

  @override
  Future<Map<String, MessageBranchNavigation>> loadMessageBranches() async {
    final rows = await _database.query(
      'message',
      columns: ['id', 'role', 'parent_message_id'],
      orderBy: 'created_at_utc ASC, id ASC',
    );
    final siblings = <String, List<String>>{};
    final parentByMessage = <String, String>{};
    for (final row in rows) {
      final parentId = row['parent_message_id'] as String?;
      if (parentId == null) continue;
      parentByMessage[row['id']! as String] = parentId;
      siblings.putIfAbsent(parentId, () => []).add(row['id']! as String);
    }
    final activeRows = await _database.query('active_child');
    final activeChild = {
      for (final row in activeRows)
        row['parent_message_id']! as String: row['child_message_id']! as String,
    };
    final result = <String, MessageBranchNavigation>{};
    for (final entry in parentByMessage.entries) {
      final alternatives = siblings[entry.value]!;
      if (alternatives.length <= 1) continue;
      final selectedIndex = alternatives.indexOf(
        activeChild[entry.value] ?? alternatives.last,
      );
      result[entry.key] = MessageBranchNavigation(
        parentMessageId: entry.value,
        alternatives: alternatives,
        activeIndex: selectedIndex < 0 ? 0 : selectedIndex,
      );
    }
    return result;
  }

  @override
  Future<List<String>> loadSubtreeMessageIds(String messageId) async {
    final rows = await _database.query(
      'message',
      columns: ['id', 'parent_message_id'],
      orderBy: 'created_at_utc ASC, id ASC',
    );
    final children = <String, List<String>>{};
    for (final row in rows) {
      final parentId = row['parent_message_id'] as String?;
      if (parentId != null) {
        children.putIfAbsent(parentId, () => []).add(row['id']! as String);
      }
    }
    if (!rows.any((row) => row['id'] == messageId)) return const [];
    final result = <String>[];
    final pending = <String>[messageId];
    while (pending.isNotEmpty) {
      final current = pending.removeLast();
      result.add(current);
      pending.addAll(children[current] ?? const <String>[]);
    }
    return result;
  }

  @override
  Future<List<ChatMessage>> activateMessageBranch(String messageId) async {
    await _database.transaction((transaction) async {
      final rows = await transaction.query(
        'message',
        columns: ['id', 'parent_message_id'],
        where: 'id = ?',
        whereArgs: [messageId],
        limit: 1,
      );
      if (rows.isEmpty) throw StateError('Message branch does not exist.');
      final parentId = rows.single['parent_message_id'] as String?;
      if (parentId == null) {
        throw StateError('The root message has no alternative branch.');
      }
      await transaction.insert(
        'active_child',
        {
          'parent_message_id': parentId,
          'child_message_id': messageId,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await _updateActiveLeaf(transaction);
    });
    return loadActiveMessages();
  }

  static Future<void> _updateActiveLeaf(Transaction transaction) async {
    final activePath = await _loadActiveMessages(transaction);
    await transaction.insert(
      'conversation_state',
      {
        'id': 1,
        'active_leaf_message_id':
            activePath.isEmpty ? null : activePath.last.id,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<Map<String, List<ChatAttachment>>> loadAttachments() async {
    final rows = await _database.query(
      'message_attachment',
      orderBy: 'rowid ASC',
    );
    final attachmentsByMessage = <String, List<ChatAttachment>>{};
    for (final row in rows) {
      final messageId = row['message_id']! as String;
      attachmentsByMessage
          .putIfAbsent(messageId, () => [])
          .add(ChatAttachment.fromMap(row));
    }

    return attachmentsByMessage;
  }

  @override
  Future<List<ConversationMemory>> loadConversationMemories() async {
    final rows = await _database.query(
      'conversation_memory',
      orderBy: 'end_at_utc DESC, updated_at_utc DESC',
    );
    return rows.map(ConversationMemory.fromMap).toList(growable: false);
  }

  @override
  Future<void> saveConversationMemory(ConversationMemory memory) async {
    await _database.insert(
      'conversation_memory',
      memory.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<SaraInnerLife> loadSaraInnerLife() async {
    final rows = await _database.query(
      'sara_inner_life',
      where: 'id = ?',
      whereArgs: [1],
      limit: 1,
    );
    if (rows.isEmpty) {
      return SaraInnerLife.initial(
        DateTime.now().toUtc().millisecondsSinceEpoch,
      );
    }
    return SaraInnerLife.fromMap(rows.single);
  }

  @override
  Future<SaraInnerLife> loadSaraInnerLifeForPath(
    List<String> activeMessageIds,
  ) async {
    if (activeMessageIds.isEmpty) return loadSaraInnerLife();
    final activeIndex = {
      for (var index = 0; index < activeMessageIds.length; index++)
        activeMessageIds[index]: index,
    };
    final rows = (await _database.query('sara_inner_life_branch'))
        .where((row) => activeIndex.containsKey(row['branch_message_id']))
        .toList();
    if (rows.isNotEmpty) {
      rows.sort(
        (a, b) => activeIndex[a['branch_message_id']]!
            .compareTo(activeIndex[b['branch_message_id']]!),
      );
      return SaraInnerLife.fromMap(rows.last);
    }
    final legacy = await loadSaraInnerLife();
    if (legacy.sourceMessageIds.every(activeMessageIds.contains)) return legacy;
    return SaraInnerLife.initial(DateTime.now().toUtc().millisecondsSinceEpoch);
  }

  @override
  Future<void> saveSaraInnerLife(SaraInnerLife state) async {
    await _database.insert(
      'sara_inner_life',
      state.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<void> saveSaraInnerLifeForBranch(
    SaraInnerLife state,
    String branchMessageId,
  ) async {
    final values = state.toMap()..remove('id');
    await _database.insert(
      'sara_inner_life_branch',
      {'branch_message_id': branchMessageId, ...values},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<bool> saveSaraInnerLifeIfActiveLeaf(
    SaraInnerLife state, {
    required String expectedLeafId,
  }) async {
    return _database.transaction((transaction) async {
      final rows = await transaction.query(
        'conversation_state',
        columns: ['active_leaf_message_id'],
        where: 'id = ?',
        whereArgs: [1],
        limit: 1,
      );
      final activeLeafId = rows.isEmpty
          ? null
          : rows.single['active_leaf_message_id'] as String?;
      if (activeLeafId != expectedLeafId) return false;
      final activeMessageIds = (await _loadActiveMessages(transaction))
          .map((message) => message.id)
          .toSet();
      if (!state.sourceMessageIds.every(activeMessageIds.contains)) {
        return false;
      }
      final values = state.toMap()..remove('id');
      await transaction.insert(
        'sara_inner_life_branch',
        {'branch_message_id': expectedLeafId, ...values},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      return true;
    });
  }

  @override
  Future<List<SaraPrivateThought>> loadPrivateThoughts(
      {int? limit = 20}) async {
    if (limit != null && limit <= 0) return const [];
    final rows = await _database.query(
      'sara_private_thought',
      orderBy: 'created_at_utc DESC',
      limit: limit,
    );
    return rows.map(SaraPrivateThought.fromMap).toList(growable: false);
  }

  @override
  Future<void> saveTerminalCommandHistory(
    TerminalCommandHistoryEntry entry,
  ) async {
    await _database.transaction((transaction) async {
      final whereClauses = [
        'command = ?',
        'working_directory = ?',
        entry.exitCode == null ? 'exit_code IS NULL' : 'exit_code = ?',
        'stdout = ?',
        'stderr = ?',
        entry.error == null ? 'error IS NULL' : 'error = ?',
        'timed_out = ?',
        'cancelled = ?',
        'skipped = ?',
        'output_truncated = ?',
      ];
      final whereArgs = <Object?>[
        entry.command,
        entry.workingDirectory,
        if (entry.exitCode != null) entry.exitCode,
        entry.stdout,
        entry.stderr,
        if (entry.error != null) entry.error,
        entry.timedOut ? 1 : 0,
        entry.cancelled ? 1 : 0,
        entry.skipped ? 1 : 0,
        entry.outputTruncated ? 1 : 0,
      ];
      final matchingRows = await transaction.query(
        'terminal_command_history',
        columns: ['id', 'task_context'],
        where: whereClauses.join(' AND '),
        whereArgs: whereArgs,
        orderBy: 'id ASC',
        limit: 1,
      );

      late final int historyId;
      if (matchingRows.isEmpty) {
        final values = entry.toMap()..remove('id');
        historyId =
            await transaction.insert('terminal_command_history', values);
      } else {
        final existing = matchingRows.single;
        historyId = existing['id']! as int;
        const contextSeparator = '\n\n---\n\n';
        final existingContext = existing['task_context']! as String;
        final contexts = existingContext.split(contextSeparator);
        if (entry.taskContext.isNotEmpty &&
            !contexts.contains(entry.taskContext)) {
          contexts.add(entry.taskContext);
          await transaction.update(
            'terminal_command_history',
            {'task_context': contexts.join(contextSeparator)},
            where: 'id = ?',
            whereArgs: [historyId],
          );
        }
      }

      final responseMessageId = entry.responseMessageId;
      if (responseMessageId != null) {
        await transaction.insert(
          'terminal_command_activity_link',
          {
            'terminal_history_id': historyId,
            'response_message_id': responseMessageId,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
    });
  }

  @override
  Future<Map<String, List<TerminalCommandHistoryEntry>>>
      loadTerminalCommandActivities(Set<String> responseMessageIds) async {
    if (responseMessageIds.isEmpty) return const {};
    final grouped = <String, List<TerminalCommandHistoryEntry>>{};
    final ids = responseMessageIds.toList(growable: false);
    for (var offset = 0; offset < ids.length; offset += 400) {
      final batch = ids.skip(offset).take(400).toList(growable: false);
      final placeholders = List.filled(batch.length, '?').join(', ');
      final directRows = await _database.query(
        'terminal_command_history',
        where: 'response_message_id IN ($placeholders)',
        whereArgs: batch,
        orderBy: 'created_at_utc ASC, id ASC',
      );
      for (final row in directRows) {
        final responseId = row['response_message_id']! as String;
        _addTerminalActivity(grouped, responseId, row);
      }

      final linkedRows = await _database.rawQuery(
        'SELECT history.*, activity_link.response_message_id '
        'AS linked_response_message_id '
        'FROM terminal_command_activity_link AS activity_link '
        'JOIN terminal_command_history AS history '
        'ON history.id = activity_link.terminal_history_id '
        'WHERE activity_link.response_message_id IN ($placeholders) '
        'ORDER BY history.created_at_utc ASC, history.id ASC',
        batch,
      );
      for (final row in linkedRows) {
        final responseId = row['linked_response_message_id']! as String;
        _addTerminalActivity(
          grouped,
          responseId,
          {...row, 'response_message_id': responseId},
        );
      }
    }
    return grouped;
  }

  void _addTerminalActivity(
    Map<String, List<TerminalCommandHistoryEntry>> grouped,
    String responseId,
    Map<String, Object?> row,
  ) {
    final activities = grouped.putIfAbsent(responseId, () => []);
    final historyId = row['id'];
    if (activities.any((activity) => activity.id == historyId)) return;
    activities.add(TerminalCommandHistoryEntry.fromMap(row));
  }

  @override
  Future<List<Map<String, Object?>>> searchTerminalCommandHistory(
    String query, {
    int limit = 3,
  }) async {
    if (limit <= 0) return const [];
    final queryTerms = _terminalHistoryTerms(query);
    if (queryTerms.isEmpty) return const [];
    final rows = await _database.query(
      'terminal_command_history',
      orderBy: 'created_at_utc DESC',
      limit: 250,
    );
    final matches = rows
        .map((row) {
          final entry = TerminalCommandHistoryEntry.fromMap(row);
          final searchable = [
            entry.taskContext,
            entry.command,
            entry.workingDirectory,
            entry.stdout,
            entry.stderr,
            entry.error ?? '',
          ].join(' ');
          final score =
              queryTerms.intersection(_terminalHistoryTerms(searchable)).length;
          return (entry: entry, score: score);
        })
        .where((match) => match.score > 0)
        .toList()
      ..sort((a, b) {
        final score = b.score.compareTo(a.score);
        return score != 0
            ? score
            : b.entry.createdAtUtc.compareTo(a.entry.createdAtUtc);
      });
    return matches
        .take(limit)
        .map((match) => match.entry.toSearchResult())
        .toList(growable: false);
  }

  @override
  Future<void> savePrivateThought(SaraPrivateThought thought) async {
    await _database.insert(
      'sara_private_thought',
      thought.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<bool> savePrivateThoughtIfSourcesExist(
    SaraPrivateThought thought,
  ) async {
    return _database.transaction((transaction) async {
      for (final sourceId in thought.sourceMessageIds.toSet()) {
        final rows = await transaction.query(
          'message',
          columns: ['id'],
          where: 'id = ?',
          whereArgs: [sourceId],
          limit: 1,
        );
        if (rows.isEmpty) return false;
      }
      await transaction.insert(
        'sara_private_thought',
        thought.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      return true;
    });
  }

  @override
  Future<bool> savePrivateThoughtIfActiveLeaf(
    SaraPrivateThought thought, {
    required String? expectedLeafId,
  }) async {
    return _database.transaction((transaction) async {
      final rows = await transaction.query(
        'conversation_state',
        columns: ['active_leaf_message_id'],
        where: 'id = ?',
        whereArgs: [1],
        limit: 1,
      );
      final activeLeafId = rows.isEmpty
          ? null
          : rows.single['active_leaf_message_id'] as String?;
      if (activeLeafId != expectedLeafId) return false;
      await transaction.insert(
        'sara_private_thought',
        thought.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      return true;
    });
  }

  @override
  Future<List<SaraAutonomyGoal>> loadAutonomyGoalsForPath(
    List<String> activeMessageIds,
  ) async {
    final activeIndex = {
      for (var index = 0; index < activeMessageIds.length; index++)
        activeMessageIds[index]: index,
    };
    final latestGoals = <String, (int, SaraAutonomyGoal)>{};
    for (final row in await _database.query('sara_autonomy_goal')) {
      final goal = SaraAutonomyGoal.fromMap(row);
      final index =
          goal.branchMessageId == '' ? -1 : activeIndex[goal.branchMessageId];
      if (index == null ||
          !goal.sourceMessageIds.every(activeIndex.containsKey)) {
        continue;
      }
      final current = latestGoals[goal.id];
      if (current == null || index >= current.$1) {
        latestGoals[goal.id] = (index, goal);
      }
    }
    return latestGoals.values.map((entry) => entry.$2).toList(growable: false);
  }

  @override
  Future<bool> saveAutonomyGoalsForBranch(
    List<SaraAutonomyGoal> goals,
    String branchMessageId,
  ) async {
    return _database.transaction((transaction) async {
      final stateRows = await transaction.query(
        'conversation_state',
        columns: ['active_leaf_message_id'],
        where: 'id = ?',
        whereArgs: [1],
        limit: 1,
      );
      if (stateRows.isEmpty ||
          stateRows.single['active_leaf_message_id'] != branchMessageId) {
        return false;
      }
      final activeMessageIds = (await _loadActiveMessages(transaction))
          .map((message) => message.id)
          .toSet();
      for (final goal in goals) {
        if (goal.branchMessageId != branchMessageId ||
            goal.title.trim().isEmpty ||
            goal.description.trim().isEmpty ||
            !const {'active', 'completed'}.contains(goal.status) ||
            !goal.sourceMessageIds.every(activeMessageIds.contains)) {
          throw const FormatException('Sara autonomy goal is invalid.');
        }
        for (final sourceId in goal.sourceMessageIds.toSet()) {
          final rows = await transaction.query(
            'message',
            columns: ['id'],
            where: 'id = ?',
            whereArgs: [sourceId],
            limit: 1,
          );
          if (rows.isEmpty) return false;
        }
        await transaction.insert(
          'sara_autonomy_goal',
          goal.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      return true;
    });
  }

  @override
  Future<Map<String, int>> loadAssistantFeedback() async {
    final rows = await _database.query('assistant_feedback');
    return {
      for (final row in rows)
        row['response_message_id']! as String: row['rating']! as int,
    };
  }

  @override
  Future<String?> loadFeedbackPreferenceSummary({
    Set<String>? activeMessageIds,
  }) async {
    if (activeMessageIds == null) {
      final rows = await _database.query(
        'feedback_preference',
        columns: ['summary'],
        where: 'id = ?',
        whereArgs: [1],
        limit: 1,
      );
      return rows.isEmpty ? null : rows.single['summary']! as String;
    }
    final rows = await _database.query('assistant_feedback');
    final activeRows = rows.where((row) =>
        activeMessageIds.contains(row['response_message_id']) &&
        activeMessageIds.contains(row['user_message_id']));
    final likes = activeRows.where((row) => row['rating'] == 1).toList();
    final dislikes = activeRows.where((row) => row['rating'] == -1).toList();
    final traits = <String>[];
    void addTrait(String label, String key) {
      final likedCount = likes.where((row) => row[key] == 1).length;
      final dislikedCount = dislikes.where((row) => row[key] == 1).length;
      if (likedCount >= 2 && likedCount - dislikedCount >= 2) {
        traits.add('often likes $label');
      } else if (dislikedCount >= 2 && dislikedCount - likedCount >= 2) {
        traits.add('often dislikes $label');
      }
    }

    addTrait('concise replies', 'is_concise');
    addTrait('structured lists', 'has_list');
    addTrait('code examples', 'has_code');
    if (likes.isEmpty && dislikes.isEmpty) return null;
    return traits.isEmpty
        ? 'Explicit feedback is mixed or too limited to show a stable style preference.'
        : 'From repeated explicit feedback, the user ${traits.join(', and ')}. These are weak style signals, not hard rules.';
  }

  @override
  Future<void> saveAssistantFeedback(
    String userMessageId,
    String responseMessageId,
    int? rating,
  ) async {
    if (rating != null && rating != -1 && rating != 1) {
      throw ArgumentError.value(rating, 'rating', 'Must be -1, 1, or null.');
    }

    await _database.transaction((transaction) async {
      if (rating == null) {
        await transaction.delete(
          'assistant_feedback',
          where: 'response_message_id = ?',
          whereArgs: [responseMessageId],
        );
      } else {
        final userRows = await transaction.query(
          'message',
          columns: ['role', 'created_at_utc'],
          where: 'id = ?',
          whereArgs: [userMessageId],
          limit: 1,
        );
        final responseRows = await transaction.query(
          'message',
          columns: ['role', 'content', 'created_at_utc'],
          where: 'id = ?',
          whereArgs: [responseMessageId],
          limit: 1,
        );
        if (userRows.isEmpty ||
            userRows.single['role'] != 'user' ||
            responseRows.isEmpty ||
            responseRows.single['role'] != 'model' ||
            (userRows.single['created_at_utc']! as int) >
                (responseRows.single['created_at_utc']! as int)) {
          throw StateError(
            'Feedback must reference a stored user message and AI response.',
          );
        }

        final content = responseRows.single['content']! as String;
        final features = _feedbackFeatures(content);
        await transaction.insert(
          'assistant_feedback',
          {
            'response_message_id': responseMessageId,
            'user_message_id': userMessageId,
            'rating': rating,
            ...features,
            'updated_at_utc': DateTime.now().toUtc().millisecondsSinceEpoch,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await _refreshFeedbackPreference(transaction);
    });
  }

  static Map<String, int> _feedbackFeatures(String content) {
    final normalized = content.trim();
    return {
      'is_concise': normalized.runes.length <= 320 ? 1 : 0,
      'has_list':
          RegExp(r'^\s*(?:[-*•]|\d+[.)])\s', multiLine: true).hasMatch(content)
              ? 1
              : 0,
      'has_code':
          content.contains('```') || RegExp(r'`[^`]+`').hasMatch(content)
              ? 1
              : 0,
    };
  }

  static Future<void> _refreshFeedbackPreference(
    Transaction transaction,
  ) async {
    final rows = await transaction.query('assistant_feedback');
    final likes = rows.where((row) => row['rating'] == 1).toList();
    final dislikes = rows.where((row) => row['rating'] == -1).toList();
    final traits = <String>[];
    void addTrait(String label, String key) {
      final likedCount = likes.where((row) => row[key] == 1).length;
      final dislikedCount = dislikes.where((row) => row[key] == 1).length;
      if (likedCount >= 2 && likedCount - dislikedCount >= 2) {
        traits.add('often likes $label');
      } else if (dislikedCount >= 2 && dislikedCount - likedCount >= 2) {
        traits.add('often dislikes $label');
      }
    }

    addTrait('concise replies', 'is_concise');
    addTrait('structured lists', 'has_list');
    addTrait('code examples', 'has_code');
    final summary = rows.isEmpty
        ? ''
        : traits.isEmpty
            ? 'Explicit feedback is mixed or too limited to show a stable style preference.'
            : 'From repeated explicit feedback, the user ${traits.join(', and ')}. These are weak style signals, not hard rules.';
    if (summary.isEmpty) {
      await transaction
          .delete('feedback_preference', where: 'id = ?', whereArgs: [1]);
    } else {
      await transaction.insert(
        'feedback_preference',
        {
          'id': 1,
          'summary': summary,
          'updated_at_utc': DateTime.now().toUtc().millisecondsSinceEpoch,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
  }

  @override
  Future<List<ChatAttachment>> loadExpiredAttachments(int nowUtc) async {
    final rows = await _database.query(
      'message_attachment',
      where: 'path IS NOT NULL AND expires_at_utc <= ?',
      whereArgs: [nowUtc],
    );
    return rows.map(ChatAttachment.fromMap).toList(growable: false);
  }

  @override
  Future<void> expireAttachments(int nowUtc) async {
    await _database.update(
      'message_attachment',
      {'path': null},
      where: 'path IS NOT NULL AND expires_at_utc <= ?',
      whereArgs: [nowUtc],
    );
  }

  @override
  Future<void> clearAttachmentPaths(List<String> paths) async {
    for (var offset = 0; offset < paths.length; offset += 500) {
      final batch = paths.skip(offset).take(500).toList(growable: false);
      if (batch.isEmpty) continue;
      final placeholders = List.filled(batch.length, '?').join(', ');
      await _database.rawUpdate(
        'UPDATE message_attachment SET path = NULL WHERE path IN ($placeholders)',
        batch,
      );
    }
  }

  @override
  Future<void> saveMessage(ChatMessage message) async {
    await _database.insert(
      'message',
      message.toMap(),
      conflictAlgorithm: ConflictAlgorithm.abort,
    );
  }

  @override
  Future<void> appendMessage(ChatMessage message) async {
    await _database.transaction((transaction) async {
      await transaction.insert(
        'message',
        message.toMap(),
        conflictAlgorithm: ConflictAlgorithm.abort,
      );
      final parentId = message.parentMessageId;
      if (parentId != null) {
        await transaction.insert(
          'active_child',
          {'parent_message_id': parentId, 'child_message_id': message.id},
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await _updateActiveLeaf(transaction);
    });
  }

  @override
  Future<bool> appendMessageIfActiveLeaf(
    ChatMessage message, {
    required String? expectedLeafId,
  }) async {
    return _database.transaction((transaction) async {
      final rows = await transaction.query(
        'conversation_state',
        columns: ['active_leaf_message_id'],
        where: 'id = ?',
        whereArgs: [1],
        limit: 1,
      );
      final activeLeafId = rows.isEmpty
          ? null
          : rows.single['active_leaf_message_id'] as String?;
      if (activeLeafId != expectedLeafId ||
          message.parentMessageId != expectedLeafId) {
        return false;
      }
      await transaction.insert(
        'message',
        message.toMap(),
        conflictAlgorithm: ConflictAlgorithm.abort,
      );
      final parentId = message.parentMessageId;
      if (parentId != null) {
        await transaction.insert(
          'active_child',
          {'parent_message_id': parentId, 'child_message_id': message.id},
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await _updateActiveLeaf(transaction);
      return true;
    });
  }

  @override
  Future<void> saveMessageAttachments(
    String messageId,
    List<ChatAttachment> attachments,
  ) async {
    await _database.transaction((transaction) async {
      await transaction.delete(
        'message_attachment',
        where: 'message_id = ?',
        whereArgs: [messageId],
      );
      for (final attachment in attachments) {
        await transaction.insert(
          'message_attachment',
          attachment.toMap(messageId),
          conflictAlgorithm: ConflictAlgorithm.abort,
        );
      }
    });
  }

  @override
  Future<void> saveExchange(List<ChatMessage> messages) async {
    await _database.transaction((transaction) async {
      for (final message in messages) {
        await transaction.insert(
          'message',
          message.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        final parentId = message.parentMessageId;
        if (parentId != null) {
          await transaction.insert(
            'active_child',
            {'parent_message_id': parentId, 'child_message_id': message.id},
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
      }
      await _updateActiveLeaf(transaction);
    });
  }

  @override
  Future<void> saveExchangeWithAttachments(
    List<ChatMessage> messages,
    String userMessageId,
    List<ChatAttachment> attachments, {
    Map<String, List<ChatAttachment>> additionalAttachments =
        const <String, List<ChatAttachment>>{},
  }) async {
    await _database.transaction((transaction) async {
      for (final message in messages) {
        await transaction.insert(
          'message',
          message.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        final parentId = message.parentMessageId;
        if (parentId != null) {
          await transaction.insert(
            'active_child',
            {'parent_message_id': parentId, 'child_message_id': message.id},
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
      }
      final attachmentsByMessage = <String, List<ChatAttachment>>{
        userMessageId: attachments,
        ...additionalAttachments,
      };
      for (final entry in attachmentsByMessage.entries) {
        await transaction.delete(
          'message_attachment',
          where: 'message_id = ?',
          whereArgs: [entry.key],
        );
        for (final attachment in entry.value) {
          await transaction.insert(
            'message_attachment',
            attachment.toMap(entry.key),
            conflictAlgorithm: ConflictAlgorithm.abort,
          );
        }
      }
      await _updateActiveLeaf(transaction);
    });
  }

  @override
  Future<void> deleteMessage(String id) async {
    await deleteMessages([id]);
  }

  @override
  Future<void> deleteMessages(List<String> ids) async {
    if (ids.isEmpty) return;
    await _database.transaction((transaction) async {
      final deletedIds = ids.toSet();
      final parentById = <String, String?>{};
      for (var offset = 0; offset < ids.length; offset += 400) {
        final batch = ids.skip(offset).take(400).toList(growable: false);
        final placeholders = List.filled(batch.length, '?').join(', ');
        for (final row in await transaction.query(
          'message',
          columns: ['id', 'parent_message_id'],
          where: 'id IN ($placeholders)',
          whereArgs: batch,
        )) {
          parentById[row['id']! as String] =
              row['parent_message_id'] as String?;
        }
      }

      String? retainedBranch(String branchId) {
        var current = branchId;
        while (deletedIds.contains(current)) {
          final parentId = parentById[current];
          if (parentId == null) return null;
          current = parentId;
        }
        return current;
      }

      final memories = await transaction.query('conversation_memory');
      for (final row in memories) {
        final memory = ConversationMemory.fromMap(row);
        if (memory.sourceMessageIds.any(deletedIds.contains)) {
          await transaction.delete(
            'conversation_memory',
            where: 'id = ?',
            whereArgs: [memory.id],
          );
        }
      }

      final innerLifeRows = await transaction.query(
        'sara_inner_life',
        where: 'id = ?',
        whereArgs: [1],
      );
      SaraInnerLife? preservedInnerLife;
      if (innerLifeRows.isNotEmpty) {
        final innerLife = SaraInnerLife.fromMap(innerLifeRows.single);
        if (innerLife.sourceMessageIds.any(deletedIds.contains)) {
          preservedInnerLife = SaraInnerLife(
            mood: innerLife.mood,
            moodIntensity: innerLife.moodIntensity,
            energy: innerLife.energy,
            drives: innerLife.drives,
            selfReflection: innerLife.selfReflection,
            sourceMessageIds: innerLife.sourceMessageIds
                .where((id) => !deletedIds.contains(id))
                .toList(growable: false),
            updatedAtUtc: innerLife.updatedAtUtc,
          );
          await transaction.insert(
            'sara_inner_life',
            preservedInnerLife.toMap(),
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
      }

      final innerLifeCheckpoints =
          await transaction.query('sara_inner_life_branch');
      for (final row in innerLifeCheckpoints) {
        final state = SaraInnerLife.fromMap(row);
        final branchId = row['branch_message_id']! as String;
        final affected = deletedIds.contains(branchId) ||
            state.sourceMessageIds.any(deletedIds.contains);
        if (!affected) continue;

        final retainedState = SaraInnerLife(
          mood: state.mood,
          moodIntensity: state.moodIntensity,
          energy: state.energy,
          drives: state.drives,
          selfReflection: state.selfReflection,
          sourceMessageIds: state.sourceMessageIds
              .where((id) => !deletedIds.contains(id))
              .toList(growable: false),
          updatedAtUtc: state.updatedAtUtc,
        );
        if (deletedIds.contains(branchId)) {
          final retainedBranchId = retainedBranch(branchId);
          await transaction.delete(
            'sara_inner_life_branch',
            where: 'branch_message_id = ?',
            whereArgs: [branchId],
          );
          if (retainedBranchId == null) {
            if (preservedInnerLife == null ||
                retainedState.updatedAtUtc > preservedInnerLife.updatedAtUtc) {
              preservedInnerLife = retainedState;
            }
          } else {
            final existingRows = await transaction.query(
              'sara_inner_life_branch',
              where: 'branch_message_id = ?',
              whereArgs: [retainedBranchId],
              limit: 1,
            );
            final existingState = existingRows.isEmpty
                ? null
                : SaraInnerLife.fromMap(existingRows.single);
            if (existingState == null ||
                retainedState.updatedAtUtc > existingState.updatedAtUtc) {
              final values = retainedState.toMap()..remove('id');
              await transaction.insert(
                'sara_inner_life_branch',
                {'branch_message_id': retainedBranchId, ...values},
                conflictAlgorithm: ConflictAlgorithm.replace,
              );
            }
          }
        } else {
          final existingRows = await transaction.query(
            'sara_inner_life_branch',
            where: 'branch_message_id = ?',
            whereArgs: [branchId],
            limit: 1,
          );
          if (existingRows.isEmpty ||
              (existingRows.single['updated_at_utc']! as int) <=
                  retainedState.updatedAtUtc) {
            await transaction.update(
              'sara_inner_life_branch',
              retainedState.toMap()..remove('id'),
              where: 'branch_message_id = ?',
              whereArgs: [branchId],
            );
          }
        }
      }
      if (preservedInnerLife != null) {
        await transaction.insert(
          'sara_inner_life',
          preservedInnerLife.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }

      final thoughts = await transaction.query('sara_private_thought');
      for (final row in thoughts) {
        final thought = SaraPrivateThought.fromMap(row);
        if (!thought.sourceMessageIds.any(deletedIds.contains)) continue;
        await transaction.insert(
          'sara_private_thought',
          SaraPrivateThought(
            id: thought.id,
            reflection: thought.reflection,
            action: thought.action,
            isRemembered: thought.isRemembered,
            sourceMessageIds: thought.sourceMessageIds
                .where((id) => !deletedIds.contains(id))
                .toList(growable: false),
            createdAtUtc: thought.createdAtUtc,
          ).toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }

      final goals = await transaction.query('sara_autonomy_goal');
      for (final row in goals) {
        final goal = SaraAutonomyGoal.fromMap(row);
        final branchId = goal.branchMessageId!;
        final branchDeleted = deletedIds.contains(branchId);
        if (!branchDeleted && !goal.sourceMessageIds.any(deletedIds.contains)) {
          continue;
        }
        final retainedGoal = SaraAutonomyGoal(
          id: goal.id,
          title: goal.title,
          description: goal.description,
          status: goal.status,
          sourceMessageIds: goal.sourceMessageIds
              .where((id) => !deletedIds.contains(id))
              .toList(growable: false),
          updatedAtUtc: goal.updatedAtUtc,
          branchMessageId:
              branchDeleted ? retainedBranch(branchId) ?? '' : branchId,
        );
        if (branchDeleted) {
          await transaction.delete(
            'sara_autonomy_goal',
            where: 'id = ? AND branch_message_id = ?',
            whereArgs: [goal.id, branchId],
          );
        }
        final targetRows = await transaction.query(
          'sara_autonomy_goal',
          where: 'id = ? AND branch_message_id = ?',
          whereArgs: [goal.id, retainedGoal.branchMessageId],
          limit: 1,
        );
        if (targetRows.isNotEmpty &&
            (targetRows.single['updated_at_utc']! as int) >
                retainedGoal.updatedAtUtc) {
          if (branchDeleted) {
            await transaction.delete(
              'sara_autonomy_goal',
              where: 'id = ? AND branch_message_id = ?',
              whereArgs: [goal.id, branchId],
            );
          }
          continue;
        }
        await transaction.insert(
          'sara_autonomy_goal',
          retainedGoal.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }

      for (var offset = 0; offset < ids.length; offset += 400) {
        final batch = ids.skip(offset).take(400).toList(growable: false);
        final placeholders = List.filled(batch.length, '?').join(', ');
        await transaction.delete(
          'assistant_feedback',
          where: 'response_message_id IN ($placeholders) '
              'OR user_message_id IN ($placeholders)',
          whereArgs: [...batch, ...batch],
        );
      }

      for (final id in ids) {
        await transaction.delete(
          'message_attachment',
          where: 'message_id = ?',
          whereArgs: [id],
        );
        await transaction.delete('message', where: 'id = ?', whereArgs: [id]);
      }
      for (final id in ids) {
        await transaction.delete(
          'active_child',
          where: 'parent_message_id = ? OR child_message_id = ?',
          whereArgs: [id, id],
        );
      }
      await _refreshFeedbackPreference(transaction);
      await _updateActiveLeaf(transaction);
    });
  }

  @override
  Future<String?> readPersonalName() async {
    final rows = await _database.query(
      'personal',
      columns: ['name'],
      where: 'id = ?',
      whereArgs: [1],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['name']! as String;
  }

  @override
  Future<void> writePersonalName(String name) async {
    await _database.insert(
      'personal',
      {'id': 1, 'name': name},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<void> clearPersonalName() async {
    await _database.delete('personal', where: 'id = ?', whereArgs: [1]);
  }

  @override
  Future<void> clearMessages() async {
    await _database.transaction((transaction) async {
      await transaction.delete('message_attachment');
      await transaction.delete('message');
      await transaction.delete('active_child');
      await transaction.delete('conversation_state');
      await transaction.insert('conversation_state', {
        'id': 1,
        'active_leaf_message_id': null,
      });
      await transaction.delete('conversation_memory');
      await transaction.delete('sara_inner_life');
      await transaction.delete('sara_inner_life_branch');
      await transaction.delete('sara_private_thought');
      await transaction.delete('sara_autonomy_goal');
      await transaction.delete('assistant_feedback');
      await transaction.delete('feedback_preference');
    });
  }

  @override
  Future<Map<String, Object?>> exportBackupData() async {
    return _database.transaction((transaction) async {
      final tables = <String, Object?>{};
      for (final table in _backupTables) {
        tables[table] = await transaction.query(table);
      }
      return tables;
    });
  }

  @override
  Future<void> importBackupData(
    Map<String, Object?> tables, {
    required Map<String, String> clipboardPaths,
  }) async {
    if (tables.keys.toSet().difference(_backupTables.toSet()).isNotEmpty ||
        _backupTables.any(
          (table) =>
              table != 'sara_private_thought' &&
              table != 'sara_autonomy_goal' &&
              table != 'terminal_command_history' &&
              table != 'terminal_command_activity_link' &&
              tables[table] is! List,
        ) ||
        (tables.containsKey('sara_private_thought') &&
            tables['sara_private_thought'] is! List) ||
        (tables.containsKey('sara_autonomy_goal') &&
            tables['sara_autonomy_goal'] is! List) ||
        (tables.containsKey('terminal_command_history') &&
            tables['terminal_command_history'] is! List) ||
        (tables.containsKey('terminal_command_activity_link') &&
            tables['terminal_command_activity_link'] is! List)) {
      throw const FormatException('Backup database tables are invalid.');
    }

    final rowsByTable = <String, List<Map<String, Object?>>>{};
    for (final table in _backupTables) {
      final rawRows = tables[table] as List? ?? const [];
      final rows = rawRows.map((row) {
        if (row is! Map ||
            row.keys.any((key) => key is! String) ||
            row.values.any(
              (value) =>
                  value != null &&
                  value is! String &&
                  value is! int &&
                  value is! double &&
                  value is! bool,
            )) {
          throw FormatException('Backup rows for "$table" are invalid.');
        }
        return Map<String, Object?>.from(row);
      }).toList(growable: false);
      rowsByTable[table] = rows;
    }

    final messages = rowsByTable['message']!;
    final messageIds = messages.map((row) => row['id']).toSet();
    final messageRows = {for (final row in messages) row['id']: row};
    for (final row in messages) {
      if (row['id'] is! String) {
        throw const FormatException('Backup contains an invalid message ID.');
      }
      final parentId = row['parent_message_id'];
      if (parentId != null && !messageIds.contains(parentId)) {
        throw const FormatException(
            'Backup contains a missing message parent.');
      }
    }
    for (final row in rowsByTable['active_child']!) {
      final parentId = row['parent_message_id'];
      final childId = row['child_message_id'];
      if (!messageIds.contains(parentId) ||
          !messageIds.contains(childId) ||
          messageRows[childId]?['parent_message_id'] != parentId) {
        throw const FormatException(
          'Backup contains an invalid active conversation branch.',
        );
      }
    }
    for (final row in rowsByTable['sara_private_thought']!) {
      final thought = SaraPrivateThought.fromMap(row);
      if (!thought.sourceMessageIds.every(messageIds.contains)) {
        throw const FormatException(
          'Backup contains a thought with a missing source message.',
        );
      }
    }
    for (final row in rowsByTable['sara_autonomy_goal']!) {
      final goal = SaraAutonomyGoal.fromMap(row);
      if ((goal.branchMessageId != '' &&
              !messageIds.contains(goal.branchMessageId)) ||
          !goal.sourceMessageIds.every(messageIds.contains) ||
          !const {'active', 'completed'}.contains(goal.status)) {
        throw const FormatException('Backup contains an invalid Sara goal.');
      }
    }
    for (final row in rowsByTable['terminal_command_history']!) {
      if (row['command'] is! String ||
          row['working_directory'] is! String ||
          row['task_context'] is! String ||
          row['stdout'] is! String ||
          row['stderr'] is! String ||
          (row['error'] != null && row['error'] is! String) ||
          (row['exit_code'] != null && row['exit_code'] is! int) ||
          row['created_at_utc'] is! int ||
          (row['response_message_id'] != null &&
              row['response_message_id'] is! String) ||
          ![0, 1].contains(row['timed_out']) ||
          ![0, 1].contains(row['cancelled']) ||
          ![0, 1].contains(row['skipped']) ||
          ![0, 1].contains(row['output_truncated'])) {
        throw const FormatException(
          'Backup contains an invalid terminal command history record.',
        );
      }
    }
    final historyIds = rowsByTable['terminal_command_history']!
        .map((row) => row['id'])
        .whereType<int>()
        .toSet();
    for (final row in rowsByTable['terminal_command_activity_link']!) {
      if (row['terminal_history_id'] is! int ||
          !historyIds.contains(row['terminal_history_id']) ||
          row['response_message_id'] is! String) {
        throw const FormatException(
          'Backup contains an invalid terminal command activity link.',
        );
      }
    }
    final conversationStates = rowsByTable['conversation_state']!;
    if (conversationStates.length != 1 ||
        conversationStates.single['id'] != 1 ||
        (conversationStates.single['active_leaf_message_id'] != null &&
            !messageIds.contains(
              conversationStates.single['active_leaf_message_id'],
            ))) {
      throw const FormatException(
        'Backup contains an invalid active conversation state.',
      );
    }
    for (final row in rowsByTable['message_attachment']!) {
      if (!messageIds.contains(row['message_id'])) {
        throw const FormatException(
          'Backup contains an attachment without its message.',
        );
      }
      final restoredPath = clipboardPaths['${row['message_id']}:${row['id']}'];
      if (restoredPath != null) {
        row['path'] = restoredPath;
        row['is_clipboard_copy'] = 1;
      } else if (row['is_clipboard_copy'] == 1) {
        row['path'] = null;
      }
    }

    await _database.transaction((transaction) async {
      for (final table in _backupTables.reversed) {
        await transaction.delete(table);
      }
      for (final table in _backupTables) {
        for (final row in rowsByTable[table]!) {
          await transaction.insert(table, row);
        }
      }
      await _deduplicateTerminalCommandHistory(transaction);
    });
  }

  @override
  Future<void> close() => _database.close();
}
