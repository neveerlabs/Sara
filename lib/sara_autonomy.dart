import 'dart:convert';
import 'camera_capture.dart';

import 'sara_inner_life.dart';

const saraMaxAutonomyDelayMinutes =
    0x7fffffffffffffff ~/ Duration.microsecondsPerMinute;
const saraMaxAutonomyReflectionLength = 4000;

class SaraPrivateThought {
  const SaraPrivateThought({
    required this.id,
    required this.reflection,
    required this.action,
    required this.isRemembered,
    required this.sourceMessageIds,
    required this.createdAtUtc,
  });

  final String id;
  final String reflection;
  final String action;
  final bool isRemembered;
  final List<String> sourceMessageIds;
  final int createdAtUtc;

  Map<String, Object?> toMap() => {
        'id': id,
        'reflection': reflection,
        'action': action,
        'is_remembered': isRemembered ? 1 : 0,
        'source_message_ids': jsonEncode(sourceMessageIds),
        'created_at_utc': createdAtUtc,
      };

  factory SaraPrivateThought.fromMap(Map<String, Object?> map) {
    final decodedIds = jsonDecode(map['source_message_ids']! as String);
    if (decodedIds is! List || decodedIds.any((id) => id is! String)) {
      throw const FormatException('Stored Sara thought sources are invalid.');
    }
    return SaraPrivateThought(
      id: map['id']! as String,
      reflection: map['reflection']! as String,
      action: map['action']! as String,
      isRemembered: map['is_remembered'] == 1,
      sourceMessageIds: decodedIds.cast<String>(),
      createdAtUtc: map['created_at_utc']! as int,
    );
  }
}

class SaraResponseHandoff {
  const SaraResponseHandoff({
    required this.userIntent,
    required this.responseApproach,
    this.openThread = '',
    this.sourceMessageIds = const [],
  });

  final String userIntent;
  final String responseApproach;
  final String openThread;
  final List<String> sourceMessageIds;

  bool isValidForPath(Iterable<String> activeMessageIds) {
    final activeIds = activeMessageIds.toSet();
    return sourceMessageIds.isNotEmpty &&
        sourceMessageIds.every(activeIds.contains);
  }

  Map<String, Object?> toJson() => {
        'userIntent': userIntent,
        'responseApproach': responseApproach,
        'openThread': openThread,
        'sourceMessageIds': sourceMessageIds,
      };
}

class SaraAutonomyDecision {
  const SaraAutonomyDecision({
    required this.reflection,
    required this.remember,
    required this.sourceMessageIds,
    required this.action,
    required this.message,
    required this.nextCheckMinutes,
    required this.innerLife,
    required this.goalUpdates,
  });

  final String reflection;
  final bool remember;
  final List<String> sourceMessageIds;
  final String action;
  final String? message;
  final int nextCheckMinutes;
  final SaraAutonomyInnerLife innerLife;
  final List<SaraAutonomyGoalUpdate> goalUpdates;
}

class SaraAutonomyInnerLife {
  const SaraAutonomyInnerLife({
    required this.mood,
    required this.moodIntensity,
    required this.energy,
    required this.drives,
  });

  final String mood;
  final int moodIntensity;
  final int energy;
  final Map<String, int> drives;

  factory SaraAutonomyInnerLife.fromJson(
    Object? value, {
    SaraAutonomyInnerLife? fallback,
    void Function(List<String> fields)? onInvalidFields,
  }) {
    int? boundedInteger(Object? raw) {
      final number = raw is num ? raw : num.tryParse(raw?.toString() ?? '');
      if (number == null || !number.isFinite || number < 0 || number > 100) {
        return null;
      }
      return number.round();
    }

    if (fallback == null) {
      if (value is! Map<String, dynamic>) {
        throw const FormatException('Sara inner-life proposal is invalid.');
      }
      final mood = value['mood'];
      final rawDrives = value['drives'];
      final moodIntensity = boundedInteger(value['moodIntensity']);
      final energy = boundedInteger(value['energy']);
      if (mood is! String ||
          !saraMoodOptions.contains(mood) ||
          rawDrives is! Map<String, dynamic> ||
          rawDrives.length != saraDriveOptions.length ||
          moodIntensity == null ||
          energy == null ||
          !saraDriveOptions.every(
            (drive) => boundedInteger(rawDrives[drive]) != null,
          )) {
        throw const FormatException('Sara inner-life proposal is invalid.');
      }
      return SaraAutonomyInnerLife(
        mood: mood,
        moodIntensity: moodIntensity,
        energy: energy,
        drives: {
          for (final drive in saraDriveOptions)
            drive: boundedInteger(rawDrives[drive])!,
        },
      );
    }

    final invalidFields = <String>[];
    final state = value is Map<String, dynamic> ? value : const {};
    if (value is! Map<String, dynamic>) invalidFields.add('innerLife');
    final rawMood = state['mood'];
    final mood = rawMood is String && saraMoodOptions.contains(rawMood)
        ? rawMood
        : fallback.mood;
    if (mood != rawMood) invalidFields.add('mood');
    final moodIntensity = boundedInteger(state['moodIntensity']);
    if (moodIntensity == null) invalidFields.add('moodIntensity');
    final energy = boundedInteger(state['energy']);
    if (energy == null) invalidFields.add('energy');
    final rawDrives = state['drives'];
    final drives = <String, int>{};
    for (final drive in saraDriveOptions) {
      final parsed = rawDrives is Map<String, dynamic>
          ? boundedInteger(rawDrives[drive])
          : null;
      if (parsed == null) invalidFields.add('drives.$drive');
      drives[drive] = parsed ?? fallback.drives[drive]!;
    }
    if (invalidFields.isNotEmpty) onInvalidFields?.call(invalidFields);
    return SaraAutonomyInnerLife(
      mood: mood,
      moodIntensity: moodIntensity ?? fallback.moodIntensity,
      energy: energy ?? fallback.energy,
      drives: drives,
    );
  }

  factory SaraAutonomyInnerLife.fromSummary(String summary) {
    const defaultState = SaraAutonomyInnerLife(
      mood: 'calm',
      moodIntensity: 25,
      energy: 65,
      drives: {
        'connection': 50,
        'curiosity': 50,
        'autonomy': 50,
        'security': 50,
      },
    );
    final decoded = jsonDecode(summary);
    if (decoded is! Map<String, dynamic>) return defaultState;
    final rawDrives = decoded['drives_json'];
    final drivesValue = rawDrives is String ? jsonDecode(rawDrives) : rawDrives;
    final drives = drivesValue is Map<String, dynamic> ? drivesValue : null;
    int readBounded(Object? raw, int defaultValue) {
      final number = raw is num ? raw : num.tryParse(raw?.toString() ?? '');
      return number != null && number.isFinite && number >= 0 && number <= 100
          ? number.round()
          : defaultValue;
    }

    final mood = decoded['mood'];
    return SaraAutonomyInnerLife(
      mood: mood is String && saraMoodOptions.contains(mood)
          ? mood
          : defaultState.mood,
      moodIntensity: readBounded(
        decoded['mood_intensity'] ?? decoded['moodIntensity'],
        defaultState.moodIntensity,
      ),
      energy: readBounded(decoded['energy'], defaultState.energy),
      drives: {
        for (final drive in saraDriveOptions)
          drive: readBounded(
            drives?[drive],
            defaultState.drives[drive]!,
          ),
      },
    );
  }
}

class SaraAutonomyGoal {
  const SaraAutonomyGoal({
    required this.id,
    required this.title,
    required this.description,
    required this.status,
    required this.sourceMessageIds,
    required this.updatedAtUtc,
    required this.branchMessageId,
  });

  final String id;
  final String title;
  final String description;
  final String status;
  final List<String> sourceMessageIds;
  final int updatedAtUtc;
  final String? branchMessageId;

  Map<String, Object?> toMap() => {
        'id': id,
        'title': title,
        'description': description,
        'status': status,
        'source_message_ids': jsonEncode(sourceMessageIds),
        'updated_at_utc': updatedAtUtc,
        'branch_message_id': branchMessageId,
      };

  factory SaraAutonomyGoal.fromMap(Map<String, Object?> map) {
    final decodedIds = jsonDecode(map['source_message_ids']! as String);
    if (decodedIds is! List || decodedIds.any((id) => id is! String)) {
      throw const FormatException('Stored Sara goal sources are invalid.');
    }
    return SaraAutonomyGoal(
      id: map['id']! as String,
      title: map['title']! as String,
      description: map['description']! as String,
      status: map['status']! as String,
      sourceMessageIds: decodedIds.cast<String>(),
      updatedAtUtc: map['updated_at_utc']! as int,
      branchMessageId: map['branch_message_id'] as String?,
    );
  }
}

class SaraAutonomyGoalUpdate {
  const SaraAutonomyGoalUpdate({
    required this.id,
    required this.title,
    required this.description,
    required this.status,
    required this.sourceMessageIds,
  });

  final String? id;
  final String title;
  final String description;
  final String status;
  final List<String> sourceMessageIds;
}

abstract interface class SaraAutonomousService {
  void cancelAutonomousThinking();

  Future<SaraAutonomyDecision> thinkAutonomously({
    required List<String> activeMessageIds,
    required String? personalName,
    required String innerLifeSummary,
    required List<SaraAutonomyGoal> currentGoals,
    SaraResponseHandoff? responseHandoff,
    Future<CameraFrame> Function()? captureCameraFrame,
  });
}
