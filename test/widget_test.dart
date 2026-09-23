import 'package:flutter_test/flutter_test.dart';

import 'package:wgkczs/main.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const NfcToolApp());
    await tester.pump();
    expect(find.text('NFC Tool'), findsNothing);
  });
}
