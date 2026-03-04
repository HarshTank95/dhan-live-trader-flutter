import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_app/main.dart';

void main() {
  testWidgets('App builds without crashing', (WidgetTester tester) async {
    await tester.pumpWidget(MyApp(savedCredentials: null, isDark: false));
    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
