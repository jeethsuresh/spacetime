import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:spacetime/main.dart';
import 'package:spacetime/native_platform.dart';
import 'package:spacetime/desktop_platform_io.dart' show DesktopFiles;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native bundle loads plugins, credentials, storage and the real UI',
    (tester) async {
      final support = await getApplicationSupportDirectory();
      final file = File('${support.path}/desktop-smoke.txt');
      await file.parent.create(recursive: true);
      await file.writeAsString('durable desktop data', flush: true);
      expect(await file.readAsString(), 'durable desktop data');
      await file.delete();
      const secrets = FlutterSecureStorage(
        mOptions: MacOsOptions(usesDataProtectionKeychain: false),
      );
      await secrets.write(
        key: 'desktop-smoke-only',
        value: 'encrypted desktop credential',
      );
      expect(
        await secrets.read(key: 'desktop-smoke-only'),
        'encrypted desktop credential',
      );
      await secrets.delete(key: 'desktop-smoke-only');
      final directory = await Directory.systemTemp.createTemp(
        'spacetime-calendar-',
      );
      final storage = DesktopFiles(directory);
      await storage.write(
        'calendar.json',
        '{"entries":[{"title":"Offline desktop event"}]}',
      );
      expect(
        await DesktopFiles(directory).read('calendar.json'),
        contains('Offline desktop event'),
      );
      await directory.delete(recursive: true);
      await initializeNativePlatform();
      expect(nativePlatformReady, isTrue);
      expect(nativeTimeZone, isNotEmpty);
      await tester.pumpWidget(const SpacetimeApp());
      await tester.pump(const Duration(seconds: 2));
      expect(find.byType(MaterialApp), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );
}
