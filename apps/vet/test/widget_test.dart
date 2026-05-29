import 'package:flutter_test/flutter_test.dart';

import 'package:cav_vet/src/app.dart';

void main() {
  testWidgets('renders vet splash shell', (WidgetTester tester) async {
    await tester.pumpWidget(const VetApp());
    await tester.pump(const Duration(milliseconds: 2300));

    expect(find.text('Call a Vet Pro'), findsNothing);
    expect(find.text('empezar'), findsOneWidget);
  });
}
