import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'chat_attachment.dart';
import 'chat_message.dart';
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

class ConversationTopicSummary {
  const ConversationTopicSummary({
    required this.id,
    required this.title,
    required this.summary,
    required this.throughMessageId,
    required this.updatedAtUtc,
    this.backgroundState = const {},
  });

  final String id;
  final String title;
  final String summary;
  final String throughMessageId;
  final int updatedAtUtc;
  final Map<String, Object?> backgroundState;

  Map<String, Object?> toMap() => {
    'id': id,
    'title': title,
    'summary': summary,
    'through_message_id': throughMessageId,
    'updated_at_utc': updatedAtUtc,
    'background_state': jsonEncode(backgroundState),
  };

  static ConversationTopicSummary fromMap(Map<String, Object?> row) {
    final rawState = row['background_state'];
    if (rawState != null && rawState is! String) {
      throw const FormatException('Conversation topic state is invalid.');
    }
    final decodedState = rawState == null
        ? const <String, Object?>{}
        : jsonDecode(rawState as String);
    if (decodedState is! Map ||
        decodedState.keys.any((key) => key is! String)) {
      throw const FormatException('Conversation topic state is invalid.');
    }
    return ConversationTopicSummary(
      id: row['id']! as String,
      title: row['title']! as String,
      summary: row['summary']! as String,
      throughMessageId: row['through_message_id']! as String,
      updatedAtUtc: row['updated_at_utc']! as int,
      backgroundState: Map<String, Object?>.from(decodedState),
    );
  }
}

class MessageEmbeddingRecord {
  const MessageEmbeddingRecord({
    required this.messageId,
    required this.topicId,
    required this.model,
    required this.values,
    required this.createdAtUtc,
  });

  final String messageId;
  final String? topicId;
  final String model;
  final List<double> values;
  final int createdAtUtc;
}

class ConversationTopicEmbeddingRecord {
  const ConversationTopicEmbeddingRecord({
    required this.topicId,
    required this.model,
    required this.values,
    required this.createdAtUtc,
  });

  final String topicId;
  final String model;
  final List<double> values;
  final int createdAtUtc;
}

class UserMemoryRecord {
  const UserMemoryRecord({
    required this.id,
    required this.kind,
    required this.memoryKey,
    required this.content,
    required this.confidence,
    required this.sourceMessageIds,
    required this.createdAtUtc,
    required this.updatedAtUtc,
    required this.embeddingModel,
    required this.embedding,
    this.expiresAtUtc,
  });

  final String id;
  final String kind;
  final String memoryKey;
  final String content;
  final double confidence;
  final List<String> sourceMessageIds;
  final int createdAtUtc;
  final int updatedAtUtc;
  final int? expiresAtUtc;
  final String embeddingModel;
  final List<double> embedding;

  Map<String, Object?> toMap() => {
    'id': id,
    'kind': kind,
    'memory_key': memoryKey,
    'content': content,
    'confidence': confidence,
    'source_message_ids': jsonEncode(sourceMessageIds),
    'created_at_utc': createdAtUtc,
    'updated_at_utc': updatedAtUtc,
    'expires_at_utc': expiresAtUtc,
    'embedding_model': embeddingModel,
    'embedding': jsonEncode(embedding),
  };

  static UserMemoryRecord fromMap(Map<String, Object?> row) {
    final rawSources = jsonDecode(row['source_message_ids']! as String);
    final rawEmbedding = jsonDecode(row['embedding']! as String);
    final confidence = row['confidence'];
    if (rawSources is! List ||
        rawSources.any((value) => value is! String) ||
        rawEmbedding is! List ||
        rawEmbedding.isEmpty ||
        rawEmbedding.any(
          (value) => value is! num || !value.toDouble().isFinite,
        ) ||
        confidence is! num ||
        !confidence.toDouble().isFinite ||
        confidence < 0 ||
        confidence > 1) {
      throw const FormatException('Stored user memory is invalid.');
    }
    return UserMemoryRecord(
      id: row['id']! as String,
      kind: row['kind']! as String,
      memoryKey: row['memory_key']! as String,
      content: row['content']! as String,
      confidence: confidence.toDouble(),
      sourceMessageIds: rawSources.cast<String>(),
      createdAtUtc: row['created_at_utc']! as int,
      updatedAtUtc: row['updated_at_utc']! as int,
      expiresAtUtc: row['expires_at_utc'] as int?,
      embeddingModel: row['embedding_model']! as String,
      embedding: rawEmbedding
          .map((value) => (value as num).toDouble())
          .toList(),
    );
  }
}

class ConversationMemoryJob {
  const ConversationMemoryJob({
    required this.id,
    required this.userMessageId,
    required this.modelMessageId,
    required this.queuedAtUtc,
    required this.forkTopicOnUpdate,
  });

  final String id;
  final String userMessageId;
  final String? modelMessageId;
  final int queuedAtUtc;
  final bool forkTopicOnUpdate;

  Map<String, Object?> toMap() => {
    'id': id,
    'user_message_id': userMessageId,
    'model_message_id': modelMessageId,
    'queued_at_utc': queuedAtUtc,
    'fork_topic_on_update': forkTopicOnUpdate ? 1 : 0,
  };

  static ConversationMemoryJob fromMap(Map<String, Object?> row) =>
      ConversationMemoryJob(
        id: row['id']! as String,
        userMessageId: row['user_message_id']! as String,
        modelMessageId: row['model_message_id'] as String?,
        queuedAtUtc: row['queued_at_utc']! as int,
        forkTopicOnUpdate: row['fork_topic_on_update'] == 1,
      );
}

abstract interface class MessageStore {
  Future<List<ChatMessage>> loadMessages();
  Future<List<ChatMessage>> loadActiveMessages();
  Future<Map<String, MessageBranchNavigation>> loadMessageBranches();
  Future<List<String>> loadSubtreeMessageIds(String messageId);
  Future<List<ChatMessage>> activateMessageBranch(String messageId);
  Future<Map<String, List<ChatAttachment>>> loadAttachments();
  Future<void> saveTerminalCommandActivities(
    String messageId,
    List<TerminalCommandHistoryEntry> activities,
  );
  Future<void> moveTerminalCommandActivities(
    String fromMessageId,
    String toMessageId,
  );
  Future<Map<String, int>> loadAssistantFeedback();
  Future<Map<String, String>> loadAssistantReactions();
  Future<void> saveAssistantFeedback(
    String userMessageId,
    String responseMessageId,
    int? rating,
  );
  Future<void> saveAssistantReaction(
    String userMessageId,
    String responseMessageId,
    String? reaction,
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
    String messageId,
    List<ChatAttachment> attachments,
  );
  Future<void> saveExchange(List<ChatMessage> messages);
  Future<void> saveExchangeWithAttachments(
    List<ChatMessage> messages,
    String userMessageId,
    List<ChatAttachment> attachments, {
    Map<String, List<ChatAttachment>> additionalAttachments =
        const <String, List<ChatAttachment>>{},
  });
  Future<List<ConversationTopicSummary>> loadConversationTopicSummaries();
  Future<List<MessageEmbeddingRecord>> loadMessageEmbeddings();
  Future<List<MessageEmbeddingRecord>> loadMessageEmbeddingsForMessages(
    List<String> messageIds,
  );
  Future<List<ConversationTopicEmbeddingRecord>>
  loadConversationTopicEmbeddings();
  Future<List<UserMemoryRecord>> loadUserMemories();
  Future<List<ConversationMemoryJob>> loadConversationMemoryJobs();
  Future<void> enqueueConversationMemoryJob(ConversationMemoryJob job);
  Future<void> deleteConversationMemoryJobs(List<String> jobIds);
  Future<void> saveMessageEmbeddings(List<MessageEmbeddingRecord> embeddings);
  Future<void> saveConversationTopicEmbeddings(
    List<ConversationTopicEmbeddingRecord> embeddings,
  );
  Future<void> saveConversationMemory({
    required ConversationTopicSummary topic,
    required List<MessageEmbeddingRecord> embeddings,
    List<String> topicSourceMessageIds = const [],
    List<ConversationTopicEmbeddingRecord> topicEmbeddings = const [],
    List<UserMemoryRecord> userMemories = const [],
    List<String> completedJobIds = const [],
    List<String> deletedMemoryIds = const [],
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
    'active_child',
    'conversation_topic',
    'message_embedding',
    'conversation_topic_embedding',
    'user_memory',
    'background_memory_job',
  ];
  static const _requiredBackupTables = [
    'message',
    'personal',
    'message_attachment',
    'active_child',
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
        version: 26,
        onCreate: (database, version) async {
          await _createMessageTable(database);
          await _createPersonalTable(database);
          await _createAttachmentTable(database);
          await _createBranchTables(database);
          await _createConversationRagTables(database);
          await _createUserMemoryTables(database);
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
                  'timestamp': formatJakartaTimestamp(
                    message['created_at_utc']! as int,
                  ),
                },
                where: 'id = ?',
                whereArgs: [message['id']],
              );
            }
          }

          if (oldVersion < 4) await _createLegacyAttachmentTable(database);
          if (oldVersion < 5) await _migrateAttachmentExpiry(database);
          if (oldVersion < 9) await _migrateConversationBranches(database);
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
          if (oldVersion < 19) {
            await database.execute(
              'DROP TABLE IF EXISTS sara_inner_life_branch',
            );
            await database.execute('DROP TABLE IF EXISTS sara_inner_life');
          }
          if (oldVersion < 20) {
            await _migrateAiDataOut(database);
          }
          if (oldVersion < 21) {
            await _migrateToSimplifiedSchema(database);
          }
          if (oldVersion < 22) {
            await _migrateTerminalCommandData(database);
          }
          if (oldVersion < 23) {
            await _createConversationRagTables(database);
          }
          if (oldVersion < 24 &&
              await _tableExists(database, 'conversation_topic') &&
              !await _columnExists(
                database,
                'conversation_topic',
                'background_state',
              )) {
            await database.execute(
              "ALTER TABLE conversation_topic ADD COLUMN "
              "background_state TEXT NOT NULL DEFAULT '{}'",
            );
          }
          if (oldVersion < 25) {
            await _migrateToVersion25(database);
          }
          if (oldVersion < 26) {
            await _createUserMemoryTables(database);
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
        content TEXT NOT NULL,
        timestamp TEXT NOT NULL,
        created_at_utc INTEGER NOT NULL,
        rating INTEGER CHECK (rating IN (-1, 1)),
        reaction TEXT,
        parent_message_id TEXT,
        terminal_command_data TEXT NOT NULL DEFAULT '[]'
      )
    ''');
    await database.execute(
      'CREATE INDEX message_order ON message(created_at_utc ASC, id ASC)',
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

  static Future<void> _createConversationRagTables(
    DatabaseExecutor database,
  ) async {
    await database.execute('''
      CREATE TABLE IF NOT EXISTS conversation_topic (
        id TEXT PRIMARY KEY NOT NULL,
        title TEXT NOT NULL,
        summary TEXT NOT NULL,
        through_message_id TEXT NOT NULL,
        updated_at_utc INTEGER NOT NULL,
        background_state TEXT NOT NULL DEFAULT '{}'
      )
    ''');
    await _createMessageEmbeddingTable(database);
    await _createConversationTopicEmbeddingTable(database);
  }

  static Future<void> _createUserMemoryTables(DatabaseExecutor database) async {
    await database.execute('''
      CREATE TABLE IF NOT EXISTS user_memory (
        id TEXT PRIMARY KEY NOT NULL,
        kind TEXT NOT NULL CHECK (
          kind IN ('habit', 'preference', 'wellbeing', 'follow_up')
        ),
        memory_key TEXT NOT NULL,
        content TEXT NOT NULL,
        confidence REAL NOT NULL CHECK (confidence BETWEEN 0 AND 1),
        source_message_ids TEXT NOT NULL,
        created_at_utc INTEGER NOT NULL,
        updated_at_utc INTEGER NOT NULL,
        expires_at_utc INTEGER,
        embedding_model TEXT NOT NULL,
        embedding TEXT NOT NULL
      )
    ''');
    await database.execute('''
      CREATE TABLE IF NOT EXISTS background_memory_job (
        id TEXT PRIMARY KEY NOT NULL,
        user_message_id TEXT NOT NULL,
        model_message_id TEXT,
        queued_at_utc INTEGER NOT NULL,
        fork_topic_on_update INTEGER NOT NULL DEFAULT 0
          CHECK (fork_topic_on_update IN (0, 1))
      )
    ''');
    await database.execute(
      'CREATE INDEX IF NOT EXISTS background_memory_job_order '
      'ON background_memory_job(queued_at_utc ASC)',
    );
  }

  static Future<void> _createMessageEmbeddingTable(
    DatabaseExecutor database,
  ) async {
    await database.execute('''
      CREATE TABLE IF NOT EXISTS message_embedding (
        message_id TEXT NOT NULL,
        topic_id TEXT,
        model TEXT NOT NULL,
        embedding TEXT NOT NULL,
        created_at_utc INTEGER NOT NULL,
        PRIMARY KEY (message_id, model)
      )
    ''');
    await database.execute(
      'CREATE INDEX IF NOT EXISTS message_embedding_topic '
      'ON message_embedding(topic_id)',
    );
  }

  static Future<void> _createConversationTopicEmbeddingTable(
    DatabaseExecutor database,
  ) async {
    await database.execute('''
      CREATE TABLE IF NOT EXISTS conversation_topic_embedding (
        topic_id TEXT NOT NULL,
        model TEXT NOT NULL,
        embedding TEXT NOT NULL,
        created_at_utc INTEGER NOT NULL,
        PRIMARY KEY (topic_id, model)
      )
    ''');
  }

  static Future<void> _migrateToVersion25(DatabaseExecutor database) async {
    if (!await _tableExists(database, 'message_embedding')) {
      await _createMessageEmbeddingTable(database);
    } else {
      final columns = await database.rawQuery(
        'PRAGMA table_info("message_embedding")',
      );
      final primaryKeyColumns =
          columns.where((column) => (column['pk']! as int) > 0).toList()..sort(
            (left, right) =>
                (left['pk']! as int).compareTo(right['pk']! as int),
          );
      final primaryKey = primaryKeyColumns
          .map((column) => column['name']! as String)
          .toList(growable: false);
      if (primaryKey.length != 2 ||
          primaryKey[0] != 'message_id' ||
          primaryKey[1] != 'model') {
        await database.execute('DROP INDEX IF EXISTS message_embedding_topic');
        await database.execute(
          'ALTER TABLE message_embedding RENAME TO message_embedding_v24',
        );
        await _createMessageEmbeddingTable(database);
        await database.execute('''
          INSERT INTO message_embedding
            (message_id, topic_id, model, embedding, created_at_utc)
          SELECT message_id, topic_id, model, embedding, created_at_utc
          FROM message_embedding_v24
        ''');
        await database.execute('DROP TABLE message_embedding_v24');
      }
    }
    if (!await _tableExists(database, 'conversation_topic_embedding')) {
      await _createConversationTopicEmbeddingTable(database);
    }
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

  static Future<bool> _columnExists(
    DatabaseExecutor database,
    String table,
    String column,
  ) async {
    final rows = await database.rawQuery('PRAGMA table_info("$table")');
    return rows.any((row) => row['name'] == column);
  }

  static Future<void> _migrateAiDataOut(DatabaseExecutor database) async {
    if (!await _columnExists(database, 'message', 'rating')) {
      await database.execute(
        'ALTER TABLE message ADD COLUMN rating INTEGER '
        'CHECK (rating IN (-1, 1))',
      );
    }
    if (!await _columnExists(database, 'message', 'reaction')) {
      await database.execute('ALTER TABLE message ADD COLUMN reaction TEXT');
    }
    final feedbackExists = await _columnExists(
      database,
      'assistant_feedback',
      'response_message_id',
    );
    if (feedbackExists) {
      final ratingExpression =
          await _columnExists(database, 'assistant_feedback', 'rating')
          ? '(SELECT rating FROM assistant_feedback '
                'WHERE response_message_id = message.id)'
          : 'NULL';
      final reactionExpression =
          await _columnExists(database, 'assistant_feedback', 'reaction')
          ? '(SELECT reaction FROM assistant_feedback '
                'WHERE response_message_id = message.id)'
          : 'NULL';
      await database.execute('''
        UPDATE message
        SET rating = $ratingExpression,
            reaction = $reactionExpression
        WHERE id IN (
          SELECT response_message_id FROM assistant_feedback
        )
      ''');
    }
    for (final table in [
      'conversation_memory',
      'sara_private_thought',
      'sara_autonomy_goal',
      'assistant_feedback',
      'feedback_preference',
    ]) {
      await database.execute('DROP TABLE IF EXISTS "$table"');
    }
  }

  static Future<bool> _tableExists(
    DatabaseExecutor database,
    String table,
  ) async {
    final rows = await database.rawQuery(
      "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
      [table],
    );
    return rows.isNotEmpty;
  }

  static Future<void> _migrateToSimplifiedSchema(
    DatabaseExecutor database,
  ) async {
    await database.execute('''
      CREATE TABLE message_v21 (
        id TEXT PRIMARY KEY NOT NULL,
        role TEXT NOT NULL CHECK (role IN ('user', 'model')),
        content TEXT NOT NULL,
        timestamp TEXT NOT NULL,
        created_at_utc INTEGER NOT NULL,
        rating INTEGER CHECK (rating IN (-1, 1)),
        reaction TEXT,
        parent_message_id TEXT
      )
    ''');
    await database.execute('''
      INSERT INTO message_v21 (
        id, role, content, timestamp, created_at_utc, rating, reaction,
        parent_message_id
      )
      SELECT id, role, content, timestamp, created_at_utc, rating, reaction,
             parent_message_id
      FROM message
    ''');
    await database.execute('DROP TABLE message');
    await database.execute('ALTER TABLE message_v21 RENAME TO message');
    await database.execute(
      'CREATE INDEX message_order ON message(created_at_utc ASC, id ASC)',
    );
    await database.execute(
      'CREATE INDEX message_parent ON message(parent_message_id)',
    );

    if (await _tableExists(database, 'conversation_state')) {
      await database.execute('DROP TABLE conversation_state');
    }

    if (await _tableExists(database, 'terminal_command_activity_link')) {
      final historyRows = await database.query(
        'terminal_command_history',
        orderBy: 'id ASC',
      );
      final links = await database.query('terminal_command_activity_link');
      final linkedResponses = <int, List<String>>{};
      for (final link in links) {
        linkedResponses
            .putIfAbsent(link['terminal_history_id']! as int, () => [])
            .add(link['response_message_id']! as String);
      }

      for (final row in historyRows) {
        final responseIds = <String>[];
        final directResponseId = row['response_message_id'] as String?;
        if (directResponseId != null) responseIds.add(directResponseId);
        for (final linkedResponseId
            in linkedResponses[row['id']! as int] ?? const <String>[]) {
          if (!responseIds.contains(linkedResponseId)) {
            responseIds.add(linkedResponseId);
          }
        }
        if (responseIds.isEmpty) continue;

        await database.update(
          'terminal_command_history',
          {'response_message_id': responseIds.first},
          where: 'id = ?',
          whereArgs: [row['id']],
        );
        for (final responseId in responseIds.skip(1)) {
          final duplicate = Map<String, Object?>.from(row)
            ..remove('id')
            ..['response_message_id'] = responseId;
          await database.insert('terminal_command_history', duplicate);
        }
      }
      await database.execute('DROP TABLE terminal_command_activity_link');
    }
  }

  static Future<void> _migrateTerminalCommandData(
    DatabaseExecutor database,
  ) async {
    if (!await _columnExists(database, 'message', 'terminal_command_data')) {
      await database.execute(
        "ALTER TABLE message ADD COLUMN terminal_command_data TEXT "
        "NOT NULL DEFAULT '[]'",
      );
    }

    if (!await _tableExists(database, 'terminal_command_history')) {
      if (await _tableExists(database, 'terminal_command_activity_link')) {
        await database.execute('DROP TABLE terminal_command_activity_link');
      }
      return;
    }

    final messageRows = await database.query(
      'message',
      columns: ['id', 'terminal_command_data'],
    );
    final messageIds = messageRows.map((row) => row['id']! as String).toSet();
    final histories = await database.query(
      'terminal_command_history',
      orderBy: 'created_at_utc ASC, id ASC',
    );
    final responseIdsByHistory = <int, List<String>>{};
    if (await _tableExists(database, 'terminal_command_activity_link')) {
      for (final link in await database.query(
        'terminal_command_activity_link',
      )) {
        final responseId = link['response_message_id'];
        if (responseId is String && messageIds.contains(responseId)) {
          responseIdsByHistory
              .putIfAbsent(link['terminal_history_id']! as int, () => [])
              .add(responseId);
        }
      }
    }

    final activitiesByMessage = <String, List<TerminalCommandHistoryEntry>>{};
    for (final row in histories) {
      final responseIds = <String>[];
      final directResponseId = row['response_message_id'];
      if (directResponseId is String && messageIds.contains(directResponseId)) {
        responseIds.add(directResponseId);
      }
      for (final responseId
          in responseIdsByHistory[row['id']! as int] ?? const <String>[]) {
        if (!responseIds.contains(responseId)) responseIds.add(responseId);
      }
      for (final responseId in responseIds) {
        activitiesByMessage
            .putIfAbsent(responseId, () => [])
            .add(
              TerminalCommandHistoryEntry.fromMap({
                ...row,
                'response_message_id': responseId,
              }),
            );
      }
    }

    for (final row in messageRows) {
      final messageId = row['id']! as String;
      final activities = activitiesByMessage[messageId];
      if (activities == null || activities.isEmpty) continue;
      final existing =
          jsonDecode(row['terminal_command_data']! as String) as List<dynamic>;
      final merged = [
        ...existing,
        ...activities.map((activity) => activity.toMap()),
      ];
      await database.update(
        'message',
        {'terminal_command_data': jsonEncode(merged)},
        where: 'id = ?',
        whereArgs: [messageId],
      );
    }
    if (await _tableExists(database, 'terminal_command_activity_link')) {
      await database.execute('DROP TABLE terminal_command_activity_link');
    }
    await database.execute('DROP TABLE terminal_command_history');
  }

  static Future<void> _createBranchTables(DatabaseExecutor database) async {
    await database.execute('''
      CREATE TABLE active_child (
        parent_message_id TEXT PRIMARY KEY NOT NULL,
        child_message_id TEXT NOT NULL
      )
    ''');
    await database.execute(
      'CREATE INDEX message_parent ON message(parent_message_id)',
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
    DatabaseExecutor database,
  ) async {
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
      currentId = availableChildren.contains(chosen)
          ? chosen!
          : availableChildren.last;
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
      await transaction.insert('active_child', {
        'parent_message_id': parentId,
        'child_message_id': messageId,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
    return loadActiveMessages();
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
  Future<void> saveTerminalCommandActivities(
    String messageId,
    List<TerminalCommandHistoryEntry> activities,
  ) async {
    final updated = await _database.update(
      'message',
      {
        'terminal_command_data': jsonEncode(
          activities.map((activity) => activity.toMap()).toList(),
        ),
      },
      where: 'id = ?',
      whereArgs: [messageId],
    );
    if (updated != 1) {
      throw StateError('The message for terminal activity is unavailable.');
    }
  }

  @override
  Future<void> moveTerminalCommandActivities(
    String fromMessageId,
    String toMessageId,
  ) async {
    if (fromMessageId == toMessageId) return;
    await _database.transaction((transaction) async {
      final rows = await transaction.query(
        'message',
        columns: ['id', 'terminal_command_data'],
        where: 'id IN (?, ?)',
        whereArgs: [fromMessageId, toMessageId],
      );
      final rowsById = {for (final row in rows) row['id']! as String: row};
      final source = rowsById[fromMessageId];
      final destination = rowsById[toMessageId];
      if (source == null || destination == null) {
        throw StateError('A message for terminal activity is unavailable.');
      }

      final sourceActivities =
          jsonDecode(source['terminal_command_data']! as String) as List;
      if (sourceActivities.isEmpty) return;
      final destinationActivities =
          jsonDecode(destination['terminal_command_data']! as String) as List;
      final signatures = destinationActivities.map(jsonEncode).toSet();
      for (final activity in sourceActivities) {
        if (signatures.add(jsonEncode(activity))) {
          destinationActivities.add(activity);
        }
      }
      await transaction.update(
        'message',
        {'terminal_command_data': jsonEncode(destinationActivities)},
        where: 'id = ?',
        whereArgs: [toMessageId],
      );
      await transaction.update(
        'message',
        {'terminal_command_data': '[]'},
        where: 'id = ?',
        whereArgs: [fromMessageId],
      );
    });
  }

  @override
  Future<Map<String, int>> loadAssistantFeedback() async {
    final rows = await _database.query(
      'message',
      columns: ['id', 'rating'],
      where: 'rating IS NOT NULL',
    );
    return {
      for (final row in rows) row['id']! as String: row['rating']! as int,
    };
  }

  @override
  Future<Map<String, String>> loadAssistantReactions() async {
    final rows = await _database.query(
      'message',
      columns: ['id', 'reaction'],
      where: 'reaction IS NOT NULL',
    );
    return {
      for (final row in rows) row['id']! as String: row['reaction']! as String,
    };
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
      await _validateFeedbackMessages(
        transaction,
        userMessageId,
        responseMessageId,
      );
      final updated = await transaction.update(
        'message',
        {'rating': rating},
        where: 'id = ?',
        whereArgs: [responseMessageId],
      );
      if (updated != 1) {
        throw StateError('The rated message is no longer available.');
      }
    });
  }

  @override
  Future<void> saveAssistantReaction(
    String userMessageId,
    String responseMessageId,
    String? reaction,
  ) async {
    if (reaction != null && reaction.trim().isEmpty) {
      throw ArgumentError.value(
        reaction,
        'reaction',
        'Must be an emoji or null.',
      );
    }

    if (reaction != null && reaction.trim().isEmpty) {
      throw ArgumentError.value(
        reaction,
        'reaction',
        'Must be an emoji or null.',
      );
    }
    await _database.transaction((transaction) async {
      await _validateFeedbackMessages(
        transaction,
        userMessageId,
        responseMessageId,
      );
      final updated = await transaction.update(
        'message',
        {'reaction': reaction},
        where: 'id = ?',
        whereArgs: [responseMessageId],
      );
      if (updated != 1) {
        throw StateError('The reacted message is no longer available.');
      }
    });
  }

  static Future<void> _validateFeedbackMessages(
    Transaction transaction,
    String userMessageId,
    String responseMessageId,
  ) async {
    final userRows = await transaction.query(
      'message',
      columns: ['role', 'created_at_utc'],
      where: 'id = ?',
      whereArgs: [userMessageId],
      limit: 1,
    );
    final responseRows = await transaction.query(
      'message',
      columns: ['role', 'created_at_utc'],
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
        await transaction.insert('active_child', {
          'parent_message_id': parentId,
          'child_message_id': message.id,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  @override
  Future<bool> appendMessageIfActiveLeaf(
    ChatMessage message, {
    required String? expectedLeafId,
  }) async {
    return _database.transaction((transaction) async {
      final activePath = await _loadActiveMessages(transaction);
      final activeLeafId = activePath.isEmpty ? null : activePath.last.id;
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
        await transaction.insert('active_child', {
          'parent_message_id': parentId,
          'child_message_id': message.id,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
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
          await transaction.insert('active_child', {
            'parent_message_id': parentId,
            'child_message_id': message.id,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
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
          await transaction.insert('active_child', {
            'parent_message_id': parentId,
            'child_message_id': message.id,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
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
    });
  }

  @override
  Future<List<ConversationTopicSummary>>
  loadConversationTopicSummaries() async {
    final rows = await _database.query('conversation_topic');
    return rows
        .map((row) => ConversationTopicSummary.fromMap(row))
        .toList(growable: false);
  }

  @override
  Future<List<MessageEmbeddingRecord>> loadMessageEmbeddings() async {
    final rows = await _database.query('message_embedding');
    return _decodeMessageEmbeddingRows(rows);
  }

  @override
  Future<List<MessageEmbeddingRecord>> loadMessageEmbeddingsForMessages(
    List<String> messageIds,
  ) async {
    final rows = <Map<String, Object?>>[];
    for (var offset = 0; offset < messageIds.length; offset += 500) {
      final batch = messageIds.skip(offset).take(500).toList(growable: false);
      rows.addAll(
        await _database.query(
          'message_embedding',
          where: 'message_id IN (${List.filled(batch.length, '?').join(', ')})',
          whereArgs: batch,
        ),
      );
    }
    return _decodeMessageEmbeddingRows(rows);
  }

  @override
  Future<List<ConversationTopicEmbeddingRecord>>
  loadConversationTopicEmbeddings() async {
    final rows = await _database.query('conversation_topic_embedding');
    return rows
        .map((row) {
          final decoded = jsonDecode(row['embedding']! as String);
          if (decoded is! List ||
              decoded.isEmpty ||
              decoded.any(
                (value) => value is! num || !value.toDouble().isFinite,
              )) {
            throw const FormatException(
              'Stored conversation topic embedding is invalid.',
            );
          }
          return ConversationTopicEmbeddingRecord(
            topicId: row['topic_id']! as String,
            model: row['model']! as String,
            values: decoded.map((value) => (value as num).toDouble()).toList(),
            createdAtUtc: row['created_at_utc']! as int,
          );
        })
        .toList(growable: false);
  }

  @override
  Future<List<UserMemoryRecord>> loadUserMemories() async {
    final rows = await _database.query('user_memory');
    return rows
        .map((row) => UserMemoryRecord.fromMap(row))
        .toList(growable: false);
  }

  @override
  Future<List<ConversationMemoryJob>> loadConversationMemoryJobs() async {
    final rows = await _database.query(
      'background_memory_job',
      orderBy: 'queued_at_utc ASC',
    );
    return rows
        .map((row) => ConversationMemoryJob.fromMap(row))
        .toList(growable: false);
  }

  @override
  Future<void> enqueueConversationMemoryJob(ConversationMemoryJob job) async {
    await _database.transaction((transaction) async {
      final userMessage = await transaction.query(
        'message',
        columns: ['role'],
        where: 'id = ?',
        whereArgs: [job.userMessageId],
        limit: 1,
      );
      if (userMessage.isEmpty || userMessage.single['role'] != 'user') {
        throw StateError(
          'Cannot queue memory work for a missing user message.',
        );
      }
      if (job.modelMessageId != null) {
        final modelMessage = await transaction.query(
          'message',
          columns: ['role', 'parent_message_id'],
          where: 'id = ?',
          whereArgs: [job.modelMessageId],
          limit: 1,
        );
        if (modelMessage.isEmpty ||
            modelMessage.single['role'] != 'model' ||
            modelMessage.single['parent_message_id'] != job.userMessageId) {
          throw StateError(
            'Cannot queue memory work for an unrelated model response.',
          );
        }
      }
      await transaction.insert(
        'background_memory_job',
        job.toMap(),
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    });
  }

  @override
  Future<void> deleteConversationMemoryJobs(List<String> jobIds) async {
    for (var offset = 0; offset < jobIds.length; offset += 500) {
      final batch = jobIds.skip(offset).take(500).toList(growable: false);
      if (batch.isEmpty) continue;
      await _database.delete(
        'background_memory_job',
        where: 'id IN (${List.filled(batch.length, '?').join(', ')})',
        whereArgs: batch,
      );
    }
  }

  static List<MessageEmbeddingRecord> _decodeMessageEmbeddingRows(
    List<Map<String, Object?>> rows,
  ) {
    return rows
        .map((row) {
          final decoded = jsonDecode(row['embedding']! as String);
          if (decoded is! List ||
              decoded.isEmpty ||
              decoded.any(
                (value) => value is! num || !value.toDouble().isFinite,
              )) {
            throw const FormatException(
              'Stored conversation embedding is invalid.',
            );
          }
          return MessageEmbeddingRecord(
            messageId: row['message_id']! as String,
            topicId: row['topic_id'] as String?,
            model: row['model']! as String,
            values: decoded.map((value) => (value as num).toDouble()).toList(),
            createdAtUtc: row['created_at_utc']! as int,
          );
        })
        .toList(growable: false);
  }

  @override
  Future<void> saveMessageEmbeddings(
    List<MessageEmbeddingRecord> embeddings,
  ) async {
    await _database.transaction((transaction) async {
      for (final embedding in embeddings) {
        final message = await transaction.query(
          'message',
          columns: ['id'],
          where: 'id = ?',
          whereArgs: [embedding.messageId],
          limit: 1,
        );
        if (message.isEmpty) continue;
        await transaction.insert('message_embedding', {
          'message_id': embedding.messageId,
          'topic_id': embedding.topicId,
          'model': embedding.model,
          'embedding': jsonEncode(embedding.values),
          'created_at_utc': embedding.createdAtUtc,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  @override
  Future<void> saveConversationTopicEmbeddings(
    List<ConversationTopicEmbeddingRecord> embeddings,
  ) async {
    await _database.transaction((transaction) async {
      for (final embedding in embeddings) {
        final topic = await transaction.query(
          'conversation_topic',
          columns: ['id'],
          where: 'id = ?',
          whereArgs: [embedding.topicId],
          limit: 1,
        );
        if (topic.isEmpty) continue;
        await transaction.insert('conversation_topic_embedding', {
          'topic_id': embedding.topicId,
          'model': embedding.model,
          'embedding': jsonEncode(embedding.values),
          'created_at_utc': embedding.createdAtUtc,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  @override
  Future<void> saveConversationMemory({
    required ConversationTopicSummary topic,
    required List<MessageEmbeddingRecord> embeddings,
    List<String> topicSourceMessageIds = const [],
    List<ConversationTopicEmbeddingRecord> topicEmbeddings = const [],
    List<UserMemoryRecord> userMemories = const [],
    List<String> completedJobIds = const [],
    List<String> deletedMemoryIds = const [],
  }) async {
    await _database.transaction((transaction) async {
      final throughMessage = await transaction.query(
        'message',
        columns: ['id'],
        where: 'id = ?',
        whereArgs: [topic.throughMessageId],
        limit: 1,
      );
      if (throughMessage.isEmpty) return;
      await transaction.insert(
        'conversation_topic',
        topic.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      for (final messageId in topicSourceMessageIds.toSet()) {
        await transaction.update(
          'message_embedding',
          {'topic_id': topic.id},
          where: 'message_id = ? AND topic_id IS NULL',
          whereArgs: [messageId],
        );
      }
      for (final embedding in embeddings) {
        final message = await transaction.query(
          'message',
          columns: ['id'],
          where: 'id = ?',
          whereArgs: [embedding.messageId],
          limit: 1,
        );
        if (message.isEmpty) continue;
        await transaction.insert('message_embedding', {
          'message_id': embedding.messageId,
          'topic_id': embedding.topicId,
          'model': embedding.model,
          'embedding': jsonEncode(embedding.values),
          'created_at_utc': embedding.createdAtUtc,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      for (final embedding in topicEmbeddings) {
        if (embedding.topicId != topic.id) continue;
        await transaction.insert('conversation_topic_embedding', {
          'topic_id': embedding.topicId,
          'model': embedding.model,
          'embedding': jsonEncode(embedding.values),
          'created_at_utc': embedding.createdAtUtc,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      for (final memory in userMemories) {
        if (memory.sourceMessageIds.isEmpty ||
            memory.sourceMessageIds.toSet().length !=
                memory.sourceMessageIds.length) {
          throw StateError('Cannot save user memory without unique evidence.');
        }
        for (final sourceMessageId in memory.sourceMessageIds.toSet()) {
          final sourceMessage = await transaction.query(
            'message',
            columns: ['role'],
            where: 'id = ?',
            whereArgs: [sourceMessageId],
            limit: 1,
          );
          if (sourceMessage.isEmpty || sourceMessage.single['role'] != 'user') {
            throw StateError(
              'Cannot save user memory without user-authored evidence.',
            );
          }
        }
        await transaction.insert(
          'user_memory',
          memory.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      for (final memoryId in deletedMemoryIds.toSet()) {
        await transaction.delete(
          'user_memory',
          where: 'id = ?',
          whereArgs: [memoryId],
        );
      }
      for (final jobId in completedJobIds.toSet()) {
        await transaction.delete(
          'background_memory_job',
          where: 'id = ?',
          whereArgs: [jobId],
        );
      }
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
      final affectedTopicIds = <String>{};
      final deletedIds = ids.toSet();
      final memories = await transaction.query('user_memory');
      for (final row in memories) {
        final memory = UserMemoryRecord.fromMap(row);
        if (!memory.sourceMessageIds.any(deletedIds.contains)) continue;
        final retainedSources = memory.sourceMessageIds
            .where((id) => !deletedIds.contains(id))
            .toList(growable: false);
        if (retainedSources.isEmpty) {
          await transaction.delete(
            'user_memory',
            where: 'id = ?',
            whereArgs: [memory.id],
          );
        } else {
          await transaction.update(
            'user_memory',
            {'source_message_ids': jsonEncode(retainedSources)},
            where: 'id = ?',
            whereArgs: [memory.id],
          );
        }
      }
      for (final id in ids) {
        final topics = await transaction.query(
          'conversation_topic',
          columns: ['id'],
          where: 'through_message_id = ?',
          whereArgs: [id],
        );
        for (final row in topics) {
          affectedTopicIds.add(row['id']! as String);
        }
        final embeddings = await transaction.query(
          'message_embedding',
          columns: ['topic_id'],
          where: 'message_id = ?',
          whereArgs: [id],
        );
        for (final row in embeddings) {
          final topicId = row['topic_id'];
          if (topicId is String) affectedTopicIds.add(topicId);
        }
        await transaction.delete(
          'message_embedding',
          where: 'message_id = ?',
          whereArgs: [id],
        );
        await transaction.delete(
          'message_attachment',
          where: 'message_id = ?',
          whereArgs: [id],
        );
        await transaction.delete(
          'background_memory_job',
          where: 'user_message_id = ? OR model_message_id = ?',
          whereArgs: [id, id],
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
      for (final topicId in affectedTopicIds) {
        await transaction.update(
          'message_embedding',
          {'topic_id': null},
          where: 'topic_id = ?',
          whereArgs: [topicId],
        );
        await transaction.delete(
          'conversation_topic_embedding',
          where: 'topic_id = ?',
          whereArgs: [topicId],
        );
        await transaction.delete(
          'conversation_topic',
          where: 'id = ?',
          whereArgs: [topicId],
        );
      }
      for (var offset = 0; offset < ids.length; offset += 500) {
        final batch = ids.skip(offset).take(500).toList(growable: false);
        final placeholders = List.filled(batch.length, '?').join(', ');
        await transaction.delete(
          'conversation_topic',
          where: 'through_message_id IN ($placeholders)',
          whereArgs: batch,
        );
      }
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
    await _database.insert('personal', {
      'id': 1,
      'name': name,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<void> clearPersonalName() async {
    await _database.delete('personal', where: 'id = ?', whereArgs: [1]);
  }

  @override
  Future<void> clearMessages() async {
    await _database.transaction((transaction) async {
      await transaction.delete('message_embedding');
      await transaction.delete('conversation_topic_embedding');
      await transaction.delete('conversation_topic');
      await transaction.delete('user_memory');
      await transaction.delete('background_memory_job');
      await transaction.delete('message_attachment');
      await transaction.delete('message');
      await transaction.delete('active_child');
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
    const legacyAiTables = {
      'conversation_memory',
      'sara_private_thought',
      'sara_autonomy_goal',
      'assistant_feedback',
      'feedback_preference',
      'sara_inner_life',
      'sara_inner_life_branch',
    };
    const legacySchemaTables = {
      'conversation_state',
      'terminal_command_activity_link',
      'terminal_command_history',
    };
    if (tables.keys.toSet().difference({
          ..._backupTables,
          ...legacyAiTables,
          ...legacySchemaTables,
        }).isNotEmpty ||
        _requiredBackupTables.any((table) => tables[table] is! List) ||
        _backupTables
            .where((table) => !_requiredBackupTables.contains(table))
            .any(
              (table) => tables.containsKey(table) && tables[table] is! List,
            ) ||
        legacyAiTables.any(
          (table) => tables.containsKey(table) && tables[table] is! List,
        ) ||
        legacySchemaTables.any(
          (table) => tables.containsKey(table) && tables[table] is! List,
        )) {
      throw const FormatException('Backup database tables are invalid.');
    }

    final rowsByTable = <String, List<Map<String, Object?>>>{};
    for (final table in _backupTables) {
      final rawRows = tables[table] as List? ?? const [];
      final rows = rawRows
          .map((row) {
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
          })
          .toList(growable: table == 'message');
      rowsByTable[table] = rows;
    }

    final messages = rowsByTable['message']!;
    for (final row in messages) {
      row.remove('type');
      row.putIfAbsent('terminal_command_data', () => '[]');
    }
    final messageIds = messages.map((row) => row['id']).toSet();
    final messageRows = {for (final row in messages) row['id']: row};
    for (final row in messages) {
      if (row['id'] is! String) {
        throw const FormatException('Backup contains an invalid message ID.');
      }
      if ((row['rating'] != null && ![-1, 1].contains(row['rating'])) ||
          (row['reaction'] != null && row['reaction'] is! String)) {
        throw const FormatException(
          'Backup contains invalid message feedback.',
        );
      }
      final parentId = row['parent_message_id'];
      if (parentId != null && !messageIds.contains(parentId)) {
        throw const FormatException(
          'Backup contains a missing message parent.',
        );
      }
    }
    final topicRows = rowsByTable['conversation_topic']!;
    final topicIds = <Object?>{};
    for (final row in topicRows) {
      row.putIfAbsent('background_state', () => '{}');
      if (row['background_state'] is! String) {
        throw const FormatException(
          'Backup contains invalid conversation topic state.',
        );
      }
      Object? backgroundState;
      try {
        backgroundState = jsonDecode(row['background_state']! as String);
      } on FormatException {
        throw const FormatException(
          'Backup contains invalid conversation topic state.',
        );
      }
      if (row['id'] is! String ||
          row['title'] is! String ||
          row['summary'] is! String ||
          row['through_message_id'] is! String ||
          !messageIds.contains(row['through_message_id']) ||
          row['updated_at_utc'] is! int ||
          backgroundState is! Map ||
          backgroundState.keys.any((key) => key is! String) ||
          !topicIds.add(row['id'])) {
        throw const FormatException(
          'Backup contains an invalid conversation topic summary.',
        );
      }
    }
    final embeddingKeys = <(Object?, Object?)>{};
    for (final row in rowsByTable['message_embedding']!) {
      if (row['message_id'] is! String ||
          !messageIds.contains(row['message_id']) ||
          (row['topic_id'] != null && !topicIds.contains(row['topic_id'])) ||
          row['model'] is! String ||
          !embeddingKeys.add((row['message_id'], row['model'])) ||
          row['embedding'] is! String ||
          row['created_at_utc'] is! int) {
        throw const FormatException(
          'Backup contains an invalid conversation embedding record.',
        );
      }
      final decodedEmbedding = jsonDecode(row['embedding']! as String);
      if (decodedEmbedding is! List ||
          decodedEmbedding.isEmpty ||
          decodedEmbedding.any(
            (value) => value is! num || !value.toDouble().isFinite,
          )) {
        throw const FormatException(
          'Backup contains an invalid conversation embedding vector.',
        );
      }
    }
    final topicEmbeddingKeys = <(Object?, Object?)>{};
    for (final row in rowsByTable['conversation_topic_embedding']!) {
      if (row['topic_id'] is! String ||
          !topicIds.contains(row['topic_id']) ||
          row['model'] is! String ||
          !topicEmbeddingKeys.add((row['topic_id'], row['model'])) ||
          row['embedding'] is! String ||
          row['created_at_utc'] is! int) {
        throw const FormatException(
          'Backup contains an invalid conversation topic embedding record.',
        );
      }
      final decodedEmbedding = jsonDecode(row['embedding']! as String);
      if (decodedEmbedding is! List ||
          decodedEmbedding.isEmpty ||
          decodedEmbedding.any(
            (value) => value is! num || !value.toDouble().isFinite,
          )) {
        throw const FormatException(
          'Backup contains an invalid conversation topic embedding vector.',
        );
      }
    }
    final memoryIds = <String>{};
    for (final row in rowsByTable['user_memory']!) {
      final sourcesJson = row['source_message_ids'];
      final vectorJson = row['embedding'];
      final confidence = row['confidence'];
      if (row['id'] is! String ||
          !memoryIds.add(row['id']! as String) ||
          !const {
            'habit',
            'preference',
            'wellbeing',
            'follow_up',
          }.contains(row['kind']) ||
          row['memory_key'] is! String ||
          row['content'] is! String ||
          confidence is! num ||
          !confidence.toDouble().isFinite ||
          confidence < 0 ||
          confidence > 1 ||
          sourcesJson is! String ||
          row['created_at_utc'] is! int ||
          row['updated_at_utc'] is! int ||
          (row['expires_at_utc'] != null && row['expires_at_utc'] is! int) ||
          row['embedding_model'] is! String ||
          vectorJson is! String) {
        throw const FormatException('Backup contains invalid user memory.');
      }
      final sources = jsonDecode(sourcesJson);
      final vector = jsonDecode(vectorJson);
      if (sources is! List ||
          sources.isEmpty ||
          sources.any(
            (sourceId) =>
                sourceId is! String ||
                !messageIds.contains(sourceId) ||
                messageRows[sourceId]?['role'] != 'user',
          ) ||
          vector is! List ||
          vector.isEmpty ||
          vector.any((value) => value is! num || !value.toDouble().isFinite)) {
        throw const FormatException('Backup contains invalid user memory.');
      }
    }
    final memoryJobIds = <String>{};
    for (final row in rowsByTable['background_memory_job']!) {
      final id = row['id'];
      final userId = row['user_message_id'];
      final modelId = row['model_message_id'];
      final user = messageRows[userId];
      final model = modelId == null ? null : messageRows[modelId];
      if (id is! String ||
          !memoryJobIds.add(id) ||
          userId is! String ||
          user?['role'] != 'user' ||
          (modelId != null &&
              (modelId is! String ||
                  model?['role'] != 'model' ||
                  model?['parent_message_id'] != userId)) ||
          row['queued_at_utc'] is! int ||
          ![0, 1].contains(row['fork_topic_on_update'])) {
        throw const FormatException(
          'Backup contains an invalid background memory job.',
        );
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
    final messageRowsById = {for (final row in messages) row['id']: row};
    for (final feedback in tables['assistant_feedback'] as List? ?? const []) {
      if (feedback is! Map ||
          feedback['response_message_id'] is! String ||
          (feedback['rating'] != null &&
              ![-1, 1].contains(feedback['rating'])) ||
          (feedback['reaction'] != null && feedback['reaction'] is! String)) {
        throw const FormatException(
          'Backup contains invalid message feedback.',
        );
      }
      final response = messageRowsById[feedback['response_message_id']];
      if (response == null) {
        throw const FormatException(
          'Backup feedback references a missing response message.',
        );
      }
      response['rating'] = feedback['rating'];
      response['reaction'] = feedback['reaction'];
    }
    final legacyHistory =
        tables['terminal_command_history'] as List? ?? const [];
    final historyRows = <Map<String, Object?>>[];
    for (final rawRow in legacyHistory) {
      if (rawRow is! Map ||
          rawRow.keys.any((key) => key is! String) ||
          rawRow.values.any(
            (value) =>
                value != null &&
                value is! String &&
                value is! int &&
                value is! double &&
                value is! bool,
          )) {
        throw const FormatException(
          'Backup contains an invalid terminal command history record.',
        );
      }
      final row = Map<String, Object?>.from(rawRow);
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
      historyRows.add(row);
    }
    final historyRowsById = {
      for (final row in historyRows)
        if (row['id'] is int) row['id'] as int: row,
    };
    final historyResponseIds = <int, List<String>>{};
    for (final rawLink
        in tables['terminal_command_activity_link'] as List? ?? const []) {
      if (rawLink is! Map ||
          rawLink['terminal_history_id'] is! int ||
          rawLink['response_message_id'] is! String) {
        throw const FormatException(
          'Backup contains an invalid terminal command activity link.',
        );
      }
      final historyId = rawLink['terminal_history_id']! as int;
      final responseId = rawLink['response_message_id']! as String;
      if (!historyRowsById.containsKey(historyId) ||
          !messageIds.contains(responseId)) {
        throw const FormatException(
          'Backup contains an invalid terminal command activity link.',
        );
      }
      historyResponseIds.putIfAbsent(historyId, () => []).add(responseId);
    }
    final expandedHistoryRows = <Map<String, Object?>>[];
    for (final row in historyRows) {
      final responseIds = <String>[];
      final directResponseId = row['response_message_id'];
      if (directResponseId != null) {
        if (directResponseId is! String ||
            !messageIds.contains(directResponseId)) {
          throw const FormatException(
            'Backup terminal history references a missing response.',
          );
        }
        responseIds.add(directResponseId);
      }
      for (final responseId
          in historyResponseIds[row['id']] ?? const <String>[]) {
        if (!responseIds.contains(responseId)) responseIds.add(responseId);
      }
      if (responseIds.isEmpty) {
        continue;
      }
      for (var index = 0; index < responseIds.length; index++) {
        final expandedRow = Map<String, Object?>.from(row)
          ..['response_message_id'] = responseIds[index];
        expandedHistoryRows.add(expandedRow);
      }
    }
    for (final row in messages) {
      final existingJson = row['terminal_command_data'] as String;
      final existing = jsonDecode(existingJson);
      if (existing is! List ||
          existing.any(
            (activity) =>
                activity is! Map || activity.keys.any((key) => key is! String),
          )) {
        throw const FormatException(
          'Backup contains invalid message terminal command data.',
        );
      }
    }
    for (final history in expandedHistoryRows) {
      final responseId = history['response_message_id']! as String;
      final response = messageRowsById[responseId]!;
      final activities =
          jsonDecode(response['terminal_command_data']! as String) as List;
      activities.add(TerminalCommandHistoryEntry.fromMap(history).toMap());
      response['terminal_command_data'] = jsonEncode(activities);
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
    });
  }

  @override
  Future<void> close() => _database.close();
}
