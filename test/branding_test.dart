import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thingsboard_app/core/auth/login/widgets/header/ce_login_header.dart';
import 'package:thingsboard_app/widgets/schwatech_logo.dart';

void main() {
  testWidgets('login wordmark is horizontally centered', (tester) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Column(children: [LoginHeader()]),
          ),
        ),
      ),
    );
    expect(tester.getCenter(find.byType(SchwaTechLogo)).dx, 180);
    expect(tester.takeException(), isNull);
  });

  testWidgets('SchwaTech wordmark fits login and compact header', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              SchwaTechLogo(),
              SizedBox(height: 40, child: SchwaTechLogo(compact: true)),
            ],
          ),
        ),
      ),
    );
    expect(find.text('SCHWATECH'), findsNWidgets(2));
    expect(find.text('complex simplicity'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
