import 'package:cloud_firestore/cloud_firestore.dart';

class UserProfile {
  final String name;
  final String email;
  final DateTime? dateOfBirth;
  final DateTime? lastPeriodStartDate;
  final DateTime? lastPeriodEndDate;
  final int typicalCycleLength;
  final int typicalPeriodLength;
  final String? bloodGroup;
  final String? hadSexRecently;
  /// Trying-to-conceive mode: reframes Home around fertility. Opt-in,
  /// default off.
  final bool ttcMode;

  UserProfile({
    required this.name,
    required this.email,
    this.dateOfBirth,
    this.lastPeriodStartDate,
    this.lastPeriodEndDate,
    this.typicalCycleLength = 28,
    this.typicalPeriodLength = 5,
    this.bloodGroup,
    this.hadSexRecently,
    this.ttcMode = false,
  });

  Map<String, dynamic> toFirestore() {
    return {
      'name': name,
      'email': email,
      if (dateOfBirth != null) 'dateOfBirth': Timestamp.fromDate(dateOfBirth!),
      if (lastPeriodStartDate != null) 'lastPeriodStartDate': Timestamp.fromDate(lastPeriodStartDate!),
      if (lastPeriodEndDate != null) 'lastPeriodEndDate': Timestamp.fromDate(lastPeriodEndDate!),
      'typicalCycleLength': typicalCycleLength,
      'typicalPeriodLength': typicalPeriodLength,
      if (bloodGroup != null) 'bloodGroup': bloodGroup,
      if (hadSexRecently != null) 'hadSexRecently': hadSexRecently,
      'ttcMode': ttcMode,
    };
  }

  static DateTime? _parseDate(dynamic value) {
    if (value is Timestamp) return value.toDate();
    if (value is String) return DateTime.tryParse(value);
    return null;
  }

  factory UserProfile.fromFirestore(Map<String, dynamic> data) {
    return UserProfile(
      name: data['name']?.toString() ?? '',
      email: data['email']?.toString() ?? '',
      dateOfBirth: _parseDate(data['dateOfBirth']),
      lastPeriodStartDate: _parseDate(data['lastPeriodStartDate']),
      lastPeriodEndDate: _parseDate(data['lastPeriodEndDate']),
      typicalCycleLength: data['typicalCycleLength'] ?? 28,
      typicalPeriodLength: data['typicalPeriodLength'] ?? 5,
      bloodGroup: data['bloodGroup'],
      hadSexRecently: data['hadSexRecently'],
      ttcMode: data['ttcMode'] == true,
    );
  }
}
