import 'package:cloud_firestore/cloud_firestore.dart';

enum LhEntryType { aiScan, manual }
enum LhManualResult { positive, negative }
enum LhSurgeStatus { low, high, peak }

class LhTestEntry {
  final String id;
  final String userId;
  final DateTime timestamp;
  final LhEntryType entryType;
  final String? imageUrl;
  final double? tcRatio;
  final LhManualResult? manualResult;
  final LhSurgeStatus surgeStatus;
  final double? surgeVelocity;
  final String? notes;

  const LhTestEntry({
    required this.id,
    required this.userId,
    required this.timestamp,
    required this.entryType,
    this.imageUrl,
    this.tcRatio,
    this.manualResult,
    required this.surgeStatus,
    this.surgeVelocity,
    this.notes,
  });

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
      }
    }

    return LhTestEntry(
      id: data['id']?.toString() ?? '',
      userId: data['user_id']?.toString() ?? '',
      timestamp: ts,
      entryType: type,
      imageUrl: data['image_url']?.toString(),
      tcRatio: data['tc_ratio'] != null ? (data['tc_ratio'] as num).toDouble() : null,
      manualResult: manual,
      surgeStatus: surge,
      surgeVelocity: data['surge_velocity'] != null ? (data['surge_velocity'] as num).toDouble() : null,
      notes: data['notes']?.toString(),
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'id': id,
      'user_id': userId,
      'timestamp': Timestamp.fromDate(timestamp),
      'entry_type': entryType == LhEntryType.aiScan ? 'AI_SCAN' : 'MANUAL',
      'image_url': imageUrl,
      'tc_ratio': tcRatio,
      'manual_result': manualResult == null
          ? null
          : (manualResult == LhManualResult.positive ? 'POSITIVE' : 'NEGATIVE'),
      'surge_status': surgeStatus == LhSurgeStatus.peak
          ? 'PEAK'
          : (surgeStatus == LhSurgeStatus.high ? 'HIGH' : 'LOW'),
      'surge_velocity': surgeVelocity,
      'notes': notes,
    };
  }
}
