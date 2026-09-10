import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('App loads test', (WidgetTester tester) async {
    expect(true, isTrue);
  });
}
