import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quickdesk_android/api/host_api.dart';
import 'package:quickdesk_android/controller/host_page.dart';
import 'package:quickdesk_android/host/host_controller.dart';
import 'package:quickdesk_android/host/host_credential_store.dart';
import 'package:quickdesk_android/l10n/app_strings.dart';

import 'host_lifecycle_test.dart' show LifecycleCapture, LifecycleInput;

class RotationStore extends HostCredentialStore {
  RotationStore() : super(signalingUrl: 'https://rotation.example');
  String code = '123456';
  int saves = 0;
  @override
  Future<HostCredentials> load() async => HostCredentials(
    deviceUuid: 'uuid',
    deviceId: 'device',
    deviceSecret: 'secret',
    accessCode: code,
  );
  @override
  Future<void> saveAccessCode(String value) async {
    code = value;
    saves++;
  }
}

class RotationApi extends HostApi {
  RotationApi() : super('https://rotation.example');
  Completer<void> gate = Completer<void>();
  int changes = 0;
  String? requestedCode;
  @override
  Future<void> setAccessCode({
    required String deviceId,
    required String deviceSecret,
    required String accessCode,
  }) {
    changes++;
    requestedCode = accessCode;
    return gate.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'rotation blocks repeated rotation and startup until server commits code',
    () async {
      final store = RotationStore();
      final api = RotationApi();
      final input = LifecycleInput();
      final controller = HostController(
        signalingUrl: 'https://rotation.example',
        credentialStore: store,
        api: api,
        injector: input,
        capture: LifecycleCapture(),
      );
      await controller.loadCredentials();
      final rotation = controller.regenerateAccessCode();
      await controller.regenerateAccessCode();
      await controller.start();
      expect(api.changes, 1);
      expect(input.checks, 0);
      expect(store.code, '123456');
      expect(store.saves, 0);
      api.gate.complete();
      await rotation;
      expect(store.saves, 1);
      expect(store.code, api.requestedCode);
      controller.dispose();
    },
  );

  test(
    'failed rotation retains previous code and clears busy guard for retry',
    () async {
      final store = RotationStore();
      final api = RotationApi();
      final controller = HostController(
        signalingUrl: 'https://rotation.example',
        credentialStore: store,
        api: api,
        injector: LifecycleInput(),
        capture: LifecycleCapture(),
      );
      await controller.loadCredentials();
      final rotation = controller.regenerateAccessCode();
      final failure = expectLater(rotation, throwsStateError);
      api.gate.completeError(StateError('offline'));
      await failure;
      expect(store.code, '123456');
      expect(store.saves, 0);
      api.gate = Completer<void>()..complete();
      await controller.regenerateAccessCode();
      expect(api.changes, 2);
      expect(store.saves, 1);
      controller.dispose();
    },
  );

  HostController customCodeController(RotationStore store, RotationApi api) =>
      HostController(
        signalingUrl: 'https://rotation.example',
        credentialStore: store,
        api: api,
        injector: LifecycleInput(),
        capture: LifecycleCapture(),
      );

  test('custom code validator accepts exactly six ASCII digits', () {
    expect(HostCredentialStore.isValidCustomAccessCode('123456'), isTrue);
    expect(HostCredentialStore.isValidCustomAccessCode(' 001234 '), isTrue);
    for (final invalid in [
      '12345',
      '1234567',
      '12345a',
      'abcdef',
      '',
      '１２３４５６',
      '12 456',
    ]) {
      expect(
        HostCredentialStore.isValidCustomAccessCode(invalid),
        isFalse,
        reason: invalid,
      );
    }
  });

  test('setCustomAccessCode uploads the exact code and persists it', () async {
    final store = RotationStore();
    final api = RotationApi();
    api.gate.complete();
    final controller = customCodeController(store, api);
    await controller.loadCredentials();

    await controller.setCustomAccessCode(' 654321 ');

    expect(api.changes, 1);
    expect(api.requestedCode, '654321');
    expect(store.saves, 1);
    expect(store.code, '654321');
    expect(controller.accessCode, '654321');
    controller.dispose();
  });

  test('malformed custom code is rejected before any network call', () async {
    final store = RotationStore();
    final api = RotationApi();
    api.gate.complete();
    final controller = customCodeController(store, api);
    await controller.loadCredentials();

    await expectLater(
      controller.setCustomAccessCode('12a456'),
      throwsArgumentError,
    );

    expect(api.changes, 0);
    expect(store.saves, 0);
    expect(store.code, '123456');
    controller.dispose();
  });

  test('failed custom code upload keeps the previous code', () async {
    final store = RotationStore();
    final api = RotationApi();
    final controller = customCodeController(store, api);
    await controller.loadCredentials();

    final pending = controller.setCustomAccessCode('999999');
    final failure = expectLater(pending, throwsStateError);
    api.gate.completeError(StateError('offline'));
    await failure;

    expect(store.code, '123456');
    expect(store.saves, 0);
    controller.dispose();
  });

  Widget dialogHarness(void Function(BuildContext context) onOpen) =>
      MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => onOpen(context),
            child: const Text('open'),
          ),
        ),
      );

  testWidgets(
    'custom code dialog returns the entered code and closes cleanly',
    (tester) async {
      late Future<String?> dialogResult;
      await tester.pumpWidget(
        dialogHarness(
          (context) => dialogResult = showCustomAccessCodeDialog(
            context,
            initialCode: '616157',
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('616157'), findsOneWidget);

      await tester.enterText(find.byType(TextFormField), '123456');
      await tester.tap(find.text(L10n.t('host.customCodeSave')));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(await dialogResult, '123456');
      // Regression guard: disposing a controller shared with the dialog
      // before its pop animation ends trips `_dependents.isEmpty` in
      // ChangeNotifier and turns the whole screen red.
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('custom code dialog rejects malformed codes', (tester) async {
    late Future<String?> dialogResult;
    await tester.pumpWidget(
      dialogHarness(
        (context) => dialogResult = showCustomAccessCodeDialog(
          context,
          initialCode: '',
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '12a');
    await tester.tap(find.text(L10n.t('host.customCodeSave')));
    await tester.pump();

    expect(find.text(L10n.t('host.customCodeInvalid')), findsOneWidget);
    expect(find.byType(CustomAccessCodeDialog), findsOneWidget);

    await tester.tap(find.text(L10n.t('common.cancel')));
    await tester.pumpAndSettle();
    expect(await dialogResult, isNull);
    expect(tester.takeException(), isNull);
  });
}
