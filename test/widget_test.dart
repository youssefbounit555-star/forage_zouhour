import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:forage/main.dart' hide MaterialType;
import 'package:forage/main.dart' as forage show MaterialType;

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  testWidgets('requires creation of a unique administrator on first startup',
      (WidgetTester tester) async {
    final directory = await Directory.systemTemp.createTemp('forage-first-run-test-');
    final database = AppDatabase(
      databasePath: path.join(directory.path, 'forage-test.db'),
    );
    try {
      await tester.pumpWidget(ForageApp(database: database));
      await tester.pumpAndSettle();

      expect(find.text('Créer le compte administrateur'), findsOneWidget);
      expect(find.byType(TextFormField), findsNWidgets(4));
    } finally {
      await database.close();
      await Directory(directory.path).delete(recursive: true);
    }
  });

  test('converts centimetres and millimetres before calculating kilograms', () {
    // 930 cm = 9.30 m and 5 mm = 0.005 m.
    expect(
      kilogramsForDimensions(
        widthMeters: 1.5,
        lengthMeters: 930 * LengthUnit.centimeter.metres,
        thicknessMillimetres: 5 * ThicknessUnit.millimeter.millimetres,
        densityKilogramsPerCubicMeter: forage.MaterialType.steel.density,
      ),
      closeTo(547.5375, 0.0001),
    );

    // If the intended length is 930 mm rather than 930 cm, it is ten times
    // shorter and therefore weighs ten times less.
    expect(
      kilogramsForDimensions(
        widthMeters: 1.5,
        lengthMeters: 930 * LengthUnit.millimeter.metres,
        thicknessMillimetres: 5,
        densityKilogramsPerCubicMeter: forage.MaterialType.steel.density,
      ),
      closeTo(54.75375, 0.0001),
    );
  });

  test('a newly created administrator can log in with the same credentials',
      () async {
    final directory = await Directory.systemTemp.createTemp('forage-auth-test-');
    final database = AppDatabase(
      databasePath: path.join(directory.path, 'forage-test.db'),
    );
    const username = 'Admin.Test';
    const password = 'Correct_password_2026';

    try {
      final created = await database.insertUser(
        AppUser(
          id: 'test-admin',
          username: username,
          password: password,
          fullName: 'Test Administrator',
          admin: true,
          role: UserRole.admin,
          roles: {UserRole.admin},
        ),
      );

      expect(created.password, isNot(password));
      expect(CredentialSecurity.isHash(created.password), isTrue);
      expect(await database.authenticate(username, password).then((result) => result.succeeded), isTrue);
      expect(await database.authenticate(username.toLowerCase(), password).then((result) => result.succeeded), isTrue);
      expect(await database.authenticate(username, 'incorrect-password').then((result) => result.succeeded), isFalse);

      final rotated = await database.updateUser(
        created.copyWith(password: 'New_secure_password_2026'),
      );
      expect(CredentialSecurity.isHash(rotated.password), isTrue);
      expect(await database.authenticate(username, password).then((result) => result.succeeded), isFalse);
      expect(await database.authenticate(username, 'New_secure_password_2026').then((result) => result.succeeded), isTrue);
    } finally {
      await database.close();
      await Directory(directory.path).delete(recursive: true);
    }
  });

  testWidgets('a first-run administrator chooses the credential',
      (WidgetTester tester) async {
    final directory = await Directory.systemTemp.createTemp('forage-setup-test-');
    final database = AppDatabase(
      databasePath: path.join(directory.path, 'forage-setup-test.db'),
    );
    try {
      await tester.pumpWidget(ForageApp(database: database));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextFormField).at(0), 'Responsible Admin');
      await tester.enterText(find.byType(TextFormField).at(1), 'responsible.admin');
      await tester.enterText(find.byType(TextFormField).at(2), 'Correct_password_2026');
      await tester.enterText(find.byType(TextFormField).at(3), 'Correct_password_2026');
      await tester.tap(find.widgetWithText(FilledButton, 'Créer et continuer'));
      await tester.pumpAndSettle(const Duration(seconds: 10));

      expect(find.text('Accueil'), findsOneWidget);
      expect(await database.authenticate('responsible.admin', 'Correct_password_2026').then((result) => result.succeeded), isTrue);
      expect(await database.authenticate('former-default-user', 'not-usable-password').then((result) => result.succeeded), isFalse);
    } finally {
      await database.close();
      await Directory(directory.path).delete(recursive: true);
    }
  });

  test('reset does not recreate a default administrator', () async {
    final directory = await Directory.systemTemp.createTemp('forage-reset-test-');
    final database = AppDatabase(
      databasePath: path.join(directory.path, 'forage-reset-test.db'),
    );

    try {
      await database.insertUser(
        AppUser(
          id: 'existing-admin',
          username: 'existing-admin',
          password: 'Correct_password_2026',
          fullName: 'Existing Administrator',
          admin: true,
          role: UserRole.admin,
          roles: {UserRole.admin},
        ),
      );
      await database.resetApplication();

      expect(await database.loadUsers(), isEmpty);
      expect(await database.authenticate('former-default-user', 'not-usable-password').then((result) => result.succeeded), isFalse);
    } finally {
      await database.close();
      await Directory(directory.path).delete(recursive: true);
    }
  });

  test('locks an account after repeated failed login attempts', () async {
    final directory = await Directory.systemTemp.createTemp('forage-lockout-test-');
    final database = AppDatabase(
      databasePath: path.join(directory.path, 'forage-test.db'),
    );
    try {
      await database.insertUser(
        AppUser(
          id: 'lockout-user',
          username: 'lockout.user',
          password: 'Correct_password_2026',
          fullName: 'Lockout Test',
        ),
      );

      for (var attempt = 0; attempt < 4; attempt++) {
        expect(
          (await database.authenticate('lockout.user', 'incorrect-password')).failure,
          LoginFailure.invalidCredentials,
        );
      }
      expect(
        (await database.authenticate('lockout.user', 'incorrect-password')).failure,
        LoginFailure.temporarilyLocked,
      );
      expect(
        (await database.authenticate('lockout.user', 'Correct_password_2026')).failure,
        LoginFailure.temporarilyLocked,
      );
    } finally {
      await database.close();
      await Directory(directory.path).delete(recursive: true);
    }
  });
}
