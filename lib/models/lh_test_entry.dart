import 'package:cloud_firestore/cloud_firestore.dart';

enum LhEntryType { aiScan, manual }
enum LhManualResult { positive, negative }

/// PRD §26 + §7/§28 — LOW / RISING / HIGH / PEAK.
/// RISING = mid-range calibrated ratio with positive velocity.
enum LhSurgeStatus { low, rising, high, peak }

class LhTestEntry {
  final String id;
  final String userId;
  final DateTime timestamp;

  /// PRD §40 — cycle linkage + cycle day.
  final String? cycleId;
  final int? cycleDay;

  final LhEntryType entryType;
  final String? imageUrl;

  /// PRD §15–16 — raw CV ratio vs calibrated T/C.
  /// [tcRatio] is the legacy alias of the calibrated ratio (kept so old
  /// records and callers keep working; new writes store both keys).
  final double? rawRatio;
  final double? calibratedRatio;
  double? get tcRatio => calibratedRatio;

  final LhManualResult? manualResult;
  final LhSurgeStatus surgeStatus;
  final double? surgeVelocity;
  final String? notes;

  /// PRD §42 — reliability of this measurement (0–1). Poor-quality points
  /// must not strongly influence personalization.
  final double? reliability;

  // PRD §41 — prediction state.
  final DateTime? baselineOvulationDate;
  final DateTime? predictedOvulationDate;
  final double? predictionConfidence;
  final DateTime? predictionUpdatedAt;
  final double? expectedVelocity;
  final double? velocityDifference;

  // PRD §44 — model versioning (every result records what produced it).
  final String? detectionVersion;
  final String? calibrationVersion;
  final String? interpretationVersion;
  final String? personalizationVersion;

  final DateTime? createdAt;
  final DateTime? updatedAt;

  LhTestEntry({
    required this.id,
    required this.userId,
    required this.timestamp,
    this.cycleId,
    this.cycleDay,
    required this.entryType,
    this.imageUrl,
    this.rawRatio,
    double? calibratedRatio,
    double? tcRatio,
    this.manualResult,
    required this.surgeStatus,
    this.surgeVelocity,
    this.notes,
    this.reliability,
    this.baselineOvulationDate,
    this.predictedOvulationDate,
    this.predictionConfidence,
    this.predictionUpdatedAt,
    this.expectedVelocity,
    this.velocityDifference,
    this.detectionVersion,
    this.calibrationVersion,
    this.interpretationVersion,
    this.personalizationVersion,
    this.createdAt,
    this.updatedAt,
  }) : calibratedRatio = calibratedRatio ?? tcRatio;

  /// Legacy alias constructor param: `tcRatio:` maps to calibratedRatio.
  factory LhTestEntry.legacy({
    required String id,
    required String userId,
    required DateTime timestamp,
    required LhEntryType entryType,
    String? imageUrl,
    double? tcRatio,
    LhManualResult? manualResult,
    required LhSurgeStatus surgeStatus,
    double? surgeVelocity,
    String? notes,
  }) {
    return LhTestEntry(
      id: id,
      userId: userId,
      timestamp: timestamp,
      entryType: entryType,
      imageUrl: imageUrl,
      calibratedRatio: tcRatio,
      manualResult: manualResult,
      surgeStatus: surgeStatus,
      surgeVelocity: surgeVelocity,
      notes: notes,
    );
  }

  factory LhTestEntry.fromFirestore(Map<String, dynamic> data) {
    DateTime ts;
    final rawTs = data['timestamp'];
    if (rawTs is Timestamp) {
      ts = rawTs.toDate();
    } else if (rawTs is String) {
      ts = DateTime.tryParse(rawTs) ?? DateTime.now();
    } else {
      ts = DateTime.now();
    }

    LhEntryType type = LhEntryType.manual;
    if (data['entry_type'] == 'AI_SCAN' || data['entry_type'] == 'aiScan') {
      type = LhEntryType.aiScan;
    }

    LhManualResult? manual;
    final rawManual = data['manual_result'];
    if (rawManual != null) {
      final s = rawManual.toString().toUpperCase();
      if (s.contains('POS')) {
        manual = LhManualResult.positive;
      } else if (s.contains('NEG')) {
        manual = LhManualResult.negative;
      }
    }

    LhSurgeStatus surge = LhSurgeStatus.low;
    final rawSurge = data['surge_status'];
    if (rawSurge != null) {
      final s = rawSurge.toString().toUpperCase();
      if (s.contains('PEAK')) {
        surge = LhSurgeStatus.peak;
      } else if (s.contains('HIGH')) {
        surge = LhSurgeStatus.high;
      } else if (s.contains('RIS')) {
        surge = LhSurgeStatus.rising;
      }
    }

    DateTime? parseDate(dynamic raw) {
      if (raw is Timestamp) return raw.toDate();
      if (raw is String) return DateTime.tryParse(raw);
      if (raw is DateTime) return raw;
      return null;
    }

    double? parseDouble(dynamic raw) {
      if (raw == null) return null;
      if (raw is num) return raw.toDouble();
      return null;
    }

    // New schema (§40) with legacy fallbacks — historical records are NOT
    // reinterpreted (PRD §46): missing version fields stay null.
    final calibrated =
        parseDouble(data['calibrated_ratio']) ?? parseDouble(data['tc_ratio']);
    final raw = parseDouble(data['raw_ratio']);

    return LhTestEntry(
      id: (data['id'] ?? data['testId'] ?? '').toString(),
      userId: (data['user_id'] ?? data['userId'] ?? '').toString(),
      timestamp: ts,
      cycleId: data['cycle_id']?.toString() ?? data['cycleId']?.toString(),
      cycleDay: data['cycle_day'] is num
          ? (data['cycle_day'] as num).toInt()
          : data['cycleDay'] is num
              ? (data['cycleDay'] as num).toInt()
              : null,
      entryType: type,
      imageUrl: (data['image_url'] ?? data['imageUrl'])?.toString(),
      rawRatio: raw,
      calibratedRatio: calibrated,
      manualResult: manual,
      surgeStatus: surge,
      surgeVelocity: parseDouble(data['surge_velocity']) ??
          parseDouble(data['lhVelocity']) ??
          parseDouble(data['lh_velocity']),
      notes: data['notes']?.toString(),
      reliability: parseDouble(data['reliability']),
      baselineOvulationDate: parseDate(
          data['baseline_ovulation_date'] ?? data['prediction']?['baselineDate']),
      predictedOvulationDate: parseDate(
          data['predicted_ovulation_date'] ?? data['prediction']?['predictedDate']),
      predictionConfidence: parseDouble(data['prediction_confidence']) ??
          parseDouble(data['prediction']?['confidence']),
      predictionUpdatedAt: parseDate(data['prediction_updated_at']),
      expectedVelocity: parseDouble(data['expected_velocity']) ??
          parseDouble(data['expectedVelocity']),
      velocityDifference: parseDouble(data['velocity_difference']) ??
          parseDouble(data['velocityDifference']),
      detectionVersion: data['detection_version']?.toString() ??
          data['detectionModel']?.toString(),
      calibrationVersion: data['calibration_version']?.toString() ??
          data['calibrationVersion']?.toString(),
      interpretationVersion: data['interpretation_version']?.toString() ??
          data['interpretationVersion']?.toString(),
      personalizationVersion: data['personalization_version']?.toString(),
      createdAt: parseDate(data['created_at'] ?? data['createdAt']),
      updatedAt: parseDate(data['updated_at'] ?? data['updatedAt']),
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'id': id,
      'testId': id,
      'user_id': userId,
      'userId': userId,
      'timestamp': Timestamp.fromDate(timestamp),
      if (cycleId != null) 'cycle_id': cycleId,
      if (cycleDay != null) 'cycle_day': cycleDay,
      'entry_type': entryType == LhEntryType.aiScan ? 'AI_SCAN' : 'MANUAL',
      'entryType': entryType == LhEntryType.aiScan ? 'AI_SCAN' : 'MANUAL',
      'image_url': imageUrl,
      if (rawRatio != null) 'raw_ratio': rawRatio,
      if (calibratedRatio != null) ...{
        'calibrated_ratio': calibratedRatio,
        'tc_ratio': calibratedRatio,
      },
      'manual_result': manualResult == null
          ? null
          : (manualResult == LhManualResult.positive ? 'POSITIVE' : 'NEGATIVE'),
      'surge_status': switch (surgeStatus) {
        LhSurgeStatus.peak => 'PEAK',
        LhSurgeStatus.high => 'HIGH',
        LhSurgeStatus.rising => 'RISING',
        LhSurgeStatus.low => 'LOW',
      },
      'surge_velocity': surgeVelocity,
      'lhVelocity': surgeVelocity,
      'notes': notes,
      if (reliability != null) 'reliability': reliability,
      if (baselineOvulationDate != null)
        'baseline_ovulation_date': Timestamp.fromDate(baselineOvulationDate!),
      if (predictedOvulationDate != null)
        'predicted_ovulation_date': Timestamp.fromDate(predictedOvulationDate!),
      if (predictionConfidence != null) 'prediction_confidence': predictionConfidence,
      'prediction': {
        if (baselineOvulationDate != null)
          'baselineDate': Timestamp.fromDate(baselineOvulationDate!),
        if (predictedOvulationDate != null)
          'predictedDate': Timestamp.fromDate(predictedOvulationDate!),
        if (predictionConfidence != null) 'confidence': predictionConfidence,
      },
      if (predictionUpdatedAt != null)
        'prediction_updated_at': Timestamp.fromDate(predictionUpdatedAt!),
      if (expectedVelocity != null) 'expected_velocity': expectedVelocity,
      if (velocityDifference != null) 'velocity_difference': velocityDifference,
      if (detectionVersion != null) 'detection_version': detectionVersion,
      if (calibrationVersion != null) 'calibration_version': calibrationVersion,
      if (interpretationVersion != null)
        'interpretation_version': interpretationVersion,
      if (personalizationVersion != null)
        'personalization_version': personalizationVersion,
      'modelVersion': interpretationVersion,
      'calibrationVersion': calibrationVersion,
      'interpretationVersion': interpretationVersion,
      if (createdAt != null) 'created_at': Timestamp.fromDate(createdAt!),
      if (updatedAt != null) 'updated_at': Timestamp.fromDate(updatedAt!),
    };
  }

  LhTestEntry withPrediction({
    DateTime? baselineOvulationDate,
    DateTime? predictedOvulationDate,
    double? predictionConfidence,
    DateTime? predictionUpdatedAt,
    double? expectedVelocity,
    double? velocityDifference,
    double? surgeVelocity,
    LhSurgeStatus? surgeStatus,
    double? calibratedRatio,
    double? rawRatio,
    double? reliability,
    int? cycleDay,
    String? cycleId,
  }) {
    return LhTestEntry(
      id: id,
      userId: userId,
      timestamp: timestamp,
      cycleId: cycleId ?? this.cycleId,
      cycleDay: cycleDay ?? this.cycleDay,
      entryType: entryType,
      imageUrl: imageUrl,
      rawRatio: rawRatio ?? this.rawRatio,
      calibratedRatio: calibratedRatio ?? this.calibratedRatio,
      manualResult: manualResult,
      surgeStatus: surgeStatus ?? this.surgeStatus,
      surgeVelocity: surgeVelocity ?? this.surgeVelocity,
      notes: notes,
      reliability: reliability ?? this.reliability,
      baselineOvulationDate: baselineOvulationDate ?? this.baselineOvulationDate,
      predictedOvulationDate: predictedOvulationDate ?? this.predictedOvulationDate,
      predictionConfidence: predictionConfidence ?? this.predictionConfidence,
      predictionUpdatedAt: predictionUpdatedAt ?? this.predictionUpdatedAt,
      expectedVelocity: expectedVelocity ?? this.expectedVelocity,
      velocityDifference: velocityDifference ?? this.velocityDifference,
      detectionVersion: detectionVersion,
      calibrationVersion: calibrationVersion,
      interpretationVersion: interpretationVersion,
      personalizationVersion: personalizationVersion,
      createdAt: createdAt,
      updatedAt: DateTime.now(),
    );
  }
}
