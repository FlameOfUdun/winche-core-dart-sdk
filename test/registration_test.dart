import 'package:test/test.dart';
import 'package:winche_core/winche_core.dart';

import 'support/fakes.dart';

void main() {
  late WincheApp app;
  late List<String> log;

  setUp(() {
    log = [];
    app = WincheApp('test');
  });

  test('a service registers itself on construction', () {
    final db = RecordingDatabaseService(app, log: log);
    expect(app.maybeService<RecordingDatabaseService>(), same(db));
  });

  test('registering the same runtime type twice throws', () {
    RecordingDatabaseService(app, log: log);
    expect(() => RecordingDatabaseService(app, log: log), throwsStateError);
  });

  test('two different types coexist', () {
    final db = RecordingDatabaseService(app, log: log);
    final st = RecordingStorageService(app, log: log);
    expect(app.maybeService<RecordingDatabaseService>(), same(db));
    expect(app.maybeService<RecordingStorageService>(), same(st));
  });

  test('maybeService returns null when absent and throws when ambiguous', () {
    expect(app.maybeService<RecordingDatabaseService>(), isNull);

    RecordingDatabaseService(app, log: log);
    RecordingStorageService(app, log: log);
    expect(() => app.maybeService<WincheService>(), throwsStateError);
  });

  test('authService finds the registered auth service', () {
    expect(app.authService, isNull);
    final auth = FakeAuthService(app);
    expect(app.authService, same(auth));
  });

  test('disposing a service deregisters it', () async {
    final db = RecordingDatabaseService(app, log: log);
    await db.dispose();

    expect(app.maybeService<RecordingDatabaseService>(), isNull);
    expect(db.isDisposed, isTrue);

    await db.dispose(); // idempotent
    expect(log.where((e) => e == 'db:dispose').length, 1);
  });

  test('registering with a disposed app throws', () async {
    await app.dispose();
    expect(() => RecordingDatabaseService(app, log: log), throwsStateError);
  });

  group('WincheService.instanceFor', () {
    test('constructs once, then returns the registered instance', () {
      var built = 0;
      RecordingDatabaseService create() {
        built++;
        return RecordingDatabaseService(app, log: log);
      }

      final first = WincheService.instanceFor<RecordingDatabaseService>(app, create);
      final second = WincheService.instanceFor<RecordingDatabaseService>(app, create);

      expect(second, same(first));
      expect(built, 1);
    });

    test('rebuilds after the previous instance is disposed', () async {
      RecordingDatabaseService create() => RecordingDatabaseService(app, log: log);

      final first = WincheService.instanceFor<RecordingDatabaseService>(app, create);
      await first.dispose();
      final second = WincheService.instanceFor<RecordingDatabaseService>(app, create);

      expect(second, isNot(same(first)));
      expect(second.isDisposed, isFalse);
    });

    test('never hands back an instance from a torn-down app', () async {
      // The bug a hand-rolled static cache has to remember to avoid: core's
      // registry is per-app and cleared on dispose, so it cannot happen here.
      final oldApp = Winche.initializeApp(name: 'scoped');
      final stale = WincheService.instanceFor<RecordingDatabaseService>(oldApp, () => RecordingDatabaseService(oldApp, log: log));
      await Winche.deinitializeApp('scoped');

      final newApp = Winche.initializeApp(name: 'scoped');
      final fresh = WincheService.instanceFor<RecordingDatabaseService>(newApp, () => RecordingDatabaseService(newApp, log: log));

      expect(fresh, isNot(same(stale)));
      expect(stale.isDisposed, isTrue);
      expect(fresh.isDisposed, isFalse);
      await Winche.deinitializeAll();
    });
  });

  test('a consumer disposed mid-dispatch is never dispatched to', () async {
    final auth = FakeAuthService(app);
    final slow = RecordingDatabaseService(app, log: log, delay: const Duration(milliseconds: 20));
    final st = RecordingStorageService(app, log: log);
    await app.settled;
    st.sessions.clear();
    log.clear();

    // `slow` is dispatched first and blocks; `st` is later in the same
    // snapshot. Disposing it now means the loop still reaches it.
    auth.emitIdentity(WincheIdentity('a'));
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await st.dispose();
    await app.settled;

    // Had it been dispatched, it would have built a session its own dispose()
    // can no longer tear down.
    expect(st.sessions, isEmpty);
    expect(slow.sessions.last?.identity.id, 'a');
  });

  test('a disposed consumer stops receiving dispatches', () async {
    final auth = FakeAuthService(app);
    final db = RecordingDatabaseService(app, log: log);
    await app.settled;
    await db.dispose();
    db.sessions.clear();

    auth.emitIdentity(WincheIdentity('a'));
    await app.settled;

    expect(db.sessions, isEmpty);
  });
}
