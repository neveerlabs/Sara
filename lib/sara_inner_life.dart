import 'dart:convert';
import 'dart:math' as math;

const saraMoodOptions = {
  'calm',
  'warm',
  'joyful',
  'angry',
  'curious',
  'playful',
  'worried',
  'sad',
  'frustrated',
  'tired',
};

const saraDriveOptions = {
  'connection',
  'curiosity',
  'autonomy',
  'security',
};

class SaraInnerLife {
  const SaraInnerLife({
    required this.mood,
    required this.moodIntensity,
    required this.energy,
    required this.drives,
    required this.selfReflection,
    required this.sourceMessageIds,
    required this.updatedAtUtc,
  });

  factory SaraInnerLife.initial(int nowUtc) => SaraInnerLife(
        mood: 'calm',
        moodIntensity: 25,
        energy: 65,
        drives: const {
          'connection': 50,
          'curiosity': 50,
          'autonomy': 50,
          'security': 50,
        },
        selfReflection: '',
        sourceMessageIds: const [],
        updatedAtUtc: nowUtc,
      );

  final String mood;
  final int moodIntensity;
  final int energy;
  final Map<String, int> drives;
  final String selfReflection;
  final List<String> sourceMessageIds;
  final int updatedAtUtc;

  SaraInnerLife asOf(int nowUtc) {
    final elapsedHours =
        math.max(0, nowUtc - updatedAtUtc) / Duration.millisecondsPerHour;
    final moodDecay = math.pow(0.5, elapsedHours / 12).toDouble();
    final energyRecovery = math.pow(0.5, elapsedHours / 6).toDouble();
    final driveDrift = math.pow(0.5, elapsedHours / 24).toDouble();
    final intensity = (25 + (moodIntensity - 25) * moodDecay).round();
    final updatedDrives = {
      for (final entry in drives.entries)
        entry.key: (50 + (entry.value - 50) * driveDrift).round().clamp(0, 100),
    };
    final recoveredEnergy =
        (65 + (energy - 65) * energyRecovery).round().clamp(0, 100);
    return SaraInnerLife(
      mood: intensity < 30 ? 'calm' : mood,
      moodIntensity: intensity.clamp(0, 100),
      energy: recoveredEnergy,
      drives: updatedDrives,
      selfReflection: selfReflection,
      sourceMessageIds: sourceMessageIds,
      updatedAtUtc: updatedAtUtc,
    );
  }

  Map<String, Object?> toMap() => {
        'id': 1,
        'mood': mood,
        'mood_intensity': moodIntensity,
        'energy': energy,
        'drives_json': jsonEncode(drives),
        'self_reflection': selfReflection,
        'source_message_ids': sourceMessageIds.join('\n'),
        'updated_at_utc': updatedAtUtc,
      };

  factory SaraInnerLife.fromMap(Map<String, Object?> map) {
    final decodedDrives = jsonDecode(map['drives_json']! as String);
    if (decodedDrives is! Map<String, dynamic>) {
      throw const FormatException('Stored Sara inner-life drives are invalid.');
    }
    final decodedSourceIds = (map['source_message_ids']! as String).split('\n');
    return SaraInnerLife(
      mood: map['mood']! as String,
      moodIntensity: map['mood_intensity']! as int,
      energy: map['energy']! as int,
      drives: {
        for (final entry in decodedDrives.entries)
          entry.key: entry.value as int,
      },
      selfReflection: map['self_reflection']! as String,
      sourceMessageIds:
          decodedSourceIds.where((id) => id.isNotEmpty).toList(growable: false),
      updatedAtUtc: map['updated_at_utc']! as int,
    );
  }
}
