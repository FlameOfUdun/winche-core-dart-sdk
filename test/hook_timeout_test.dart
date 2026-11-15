import 'dart:async';

import 'package:test/test.dart';
import 'package:winche_core/winche_core.dart';

import 'support/fakes.dart';

/// Dispatch is strictly sequential and teardown awaits it, so before the
/// deadline existed a single hook that never returned starved every other
/// service *and* hung the app forever. A consuming service's hook opens sockets
/// and stores, so this is the failure a backend that accepts a connection and
/// never answers would produce.
void main() {
  const short = Duration(milliseconds: 100);

  late WincheApp app;
  late List<String> log;
  late List<WincheSessionConsumerError> errors;

  setUp(() {
    log = [];
    errors = [];
    app = WincheApp('test', hookTimeout: short);
    app.errors.listen(errors.add);
  });

  tearDown(() async {
    if (!app.isDisposed) await app.dispose();
  });

  test('a wedged hook does not starve the services behind it', () async {
    final auth = FakeAuthService(app);
    StuckDatabaseService(app);
    final other = RecordingStorageService(app, log: log);

    auth.emitIdentity(WincheIdentity('a'));
    await app.settled;

    expect(other.sessions.last?.identity.id, 'a');
  });

  test('a wedged hook is reported like any other failure', () async {
    final auth = FakeAuthService(app);
    StuckDatabaseService(app);

    auth.emitIdentity(WincheIdentity('a'));
    await app.settled;
    await Future<void>.delayed(Duration.zero);

    expect(errors, isNotEmpty);
    expect(errors.first.consumer, isA<StuckDatabaseService>());
    expect(errors.first.error, isA<TimeoutException>());
  });

  test('a wedged hook is retried on the next change, not latched', () async {
    final auth = FakeAuthService(app);
    StuckDatabaseService(app);

    auth.emitIdentity(WincheIdentity('a'));
    await app.settled;
    await Future<void>.delayed(Duration.zero);
    final afterFirst = errors.length;

    auth.emitIdentity(WincheIdentity('b'));
    await app.settled;
    await Future<void>.delayed(Duration.zero);

    expect(errors.length, greaterThan(afterFirst));
  });

  test('a wedged hook does not hang app teardown', () async {
    final auth = FakeAuthService(app);
    StuckDatabaseService(app);
    auth.emitIdentity(WincheIdentity('a'));

    // Without the deadline this never completes.
    await app.dispose().timeout(const Duration(seconds: 5));

    expect(app.isDisposed, isTrue);
  });

  test('a wedged dispose does not strand the services behind it', () async {
    StuckDatabaseService(app, stuckOnDispose: true);
    final after = RecordingStorageService(app, log: log);
    await app.settled;

    await expectLater(app.dispose().timeout(const Duration(seconds: 5)), throwsA(isA<TimeoutException>()));

    expect(after.isDisposed, isTrue, reason: 'teardown stopped at the wedged service');
  });

  test('the deadline does not fire for a hook that merely takes a while', () async {
    final auth = FakeAuthService(app);
    final slow = RecordingDatabaseService(app, log: log, delay: const Duration(milliseconds: 10));

    auth.emitIdentity(WincheIdentity('a'));
    await app.settled;
    await Future<void>.delayed(Duration.zero);

    expect(slow.sessions.last?.identity.id, 'a');
    expect(errors, isEmpty);
  });
}
