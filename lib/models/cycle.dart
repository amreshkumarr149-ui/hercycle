import 'package:cloud_firestore/cloud_firestore.dart';

class Cycle {
  final String id;
  final DateTime startDate;
  final DateTime? endDate;
  final int? length;
  final bool isOvulationLocked;
  final DateTime? confirmedOvulationDate;
  final String stateStatus;

  Cycle({
    required this.id,
    required this.startDate,
    this.endDate,
    this.length,
    this.isOvulationLocked = false,
    this.confirmedOvulationDate,
    this.stateStatus = 'preOvulation',
  });

  static DateTime? _parseDate(dynamic value) {
    if (value is Timestamp) return value.toDate();
    if (value is String) return DateTime.tryParse(value);
    return null;
  }

  factory Cycle.fromFirestore(String id, Map<String, dynamic> data) {
    return Cycle(
      id: id,
      startDate: _parseDate(data['startDate']) ?? DateTime.now(),
      endDate: _parseDate(data['endDate']),
      length: data['length'],
      isOvulationLocked: data['isOvulationLocked'] ?? false,
      confirmedOvulationDate: _parseDate(data['confirmedOvulationDate']),
      stateStatus: data['stateStatus'] ?? 'preOvulation',
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'startDate': Timestamp.fromDate(startDate),
      if (endDate != null) 'endDate': Timestamp.fromDate(endDate!),
      if (length != null) 'length': length,
      'isOvulationLocked': isOvulationLocked,
      if (confirmedOvulationDate != null) 'confirmedOvulationDate': Timestamp.fromDate(confirmedOvulationDate!),
      'stateStatus': stateStatus,
    };
  }
}
