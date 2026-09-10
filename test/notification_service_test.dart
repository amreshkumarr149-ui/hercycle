import 'package:flutter_test/flutter_test.dart';
import 'package:hercycle/core/notification_service.dart';

void main() {
  test('period reminder never throws without plugins or backend', () async {
    // No Firebase, no notification plugin here: every path must resolve
    // quietly instead of throwing.
    await NotificationService.syncPeriodReminder('no-such-user', null);
    await NotificationService.syncPeriodReminder(
        'no-such-user', DateTime.now().subtract(const Duration(days: 1)));
    await NotificationService.syncPeriodReminder(
        'no-such-user', DateTime.now().add(const Duration(days: 30)));
    await NotificationService.cancelPeriodReminder();
    await NotificationService.cancelDailyReminder();
    await NotificationService.scheduleDailyReminder(hour: 21, minute: 0);
    expect(NotificationService.isWetMucus('Creamy / lotion'), isTrue);
    expect(NotificationService.isWetMucus('Dry / nothing'), isFalse);
  });
}
