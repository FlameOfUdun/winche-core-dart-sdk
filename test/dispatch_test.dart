import 'dart:async';

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

  tearDown(() async {
    if (!app.isDisposed) await app.dispose();
  });

  group('binding', () {
    test('a consumer registered after auth binds to the current session', () async {
      final auth = FakeAuthService(app);
      auth.emitIdentity(WincheIdentity('a'));
      await app.settled;

      final db = RecordingDatabaseService(app, log: log);
      await app.settled;

      expect(db.sessions, hasLength(1));
      expect(db.sessions.single?.identity.id, 'a');
    });

    test('a consumer registered BEFORE auth binds when auth arrives', () async {
      final db = RecordingDatabaseService(app, log: log);
      await app.settled;
      expect(db.sessions, [null]);

      final auth = FakeAuthService(app);
      auth.emitIdentity(WincheIdentity('a'));
      await app.settled;

      expect(db.sessions.last?.identity.id, 'a');
    });

    test('a late consumer is dispatched without re-dispatching the others', () async {
      final auth = FakeAuthService(app);
      auth.emitIdentity(WincheIdentity('a'));
      RecordingDatabaseService(app, log: log);
      await app.settled;
      log.clear();

      final st = RecordingStorageService(app, log: log);
      await app.settled;

      expect(st.sessions.single?.identity.id, 'a');
      expect(log, ['st:enter:a', 'st:exit:a']);
    });
  });

  group('transitions', () {
    test('null to A binds, A to B swaps, B to null unbinds', () async {
      final auth = FakeAuthService(app);
      final db = RecordingDatabaseService(app, log: log);
      await app.settled;

      auth.emitIdentity(WincheIdentity('a'));
      await app.settled;
      auth.emitIdentity(WincheIdentity('b'));
      await app.settled;
      auth.emitIdentity(null);
      await app.settled;

      expect(db.sessions.map((s) => s?.identity.id).toList(), [null, 'a', 'b', null]);
    });

    test('re-announcing the same identity dispatches nothing', () async {
      final auth = FakeAuthService(app);
      final db = RecordingDatabaseService(app, log: log);
      auth.emitIdentity(WincheIdentity('a'));
      await app.settled;
      log.clear();

      auth.emitIdentity(WincheIdentity('a'));
      await app.settled;

      expect(log, isEmpty);
      expect(db.sessions, hasLength(2));
    });

    test('a swap invalidates the outgoing session', () async {
      final auth = FakeAuthService(app);
      final db = RecordingDatabaseService(app, log: log);
      auth.emitIdentity(WincheIdentity('a'));
      await app.settled;
      final sessionA = db.sessions.last!;

      auth.emitIdentity(WincheIdentity('b'));
      await app.settled;

      expect(sessionA.isActive, isFalse);
      expect(() => sessionA.token(), throwsA(isA<WincheSessionExpired>()));
      expect(db.sessions.last!.isActive, isTrue);
    });

    test('the session reads tokens through the auth service', () async {
      final auth = FakeAuthService(app);
      final db = RecordingDatabaseService(app, log: log);
      auth.emitIdentity(WincheIdentity('a'), token: 'tok');
      await app.settled;

      final session = db.sessions.last!;
      expect(await session.token(), 'tok');
      expect(await session.token(forceRefresh: true), 'tok-fresh');
      expect(auth.tokenCalls, 2);
    });
  });

  group('token rotation', () {
    test('nudges bound consumers without swapping', () async {
      final auth = FakeAuthService(app);
      final db = RecordingDatabaseService(app, log: log);
      auth.emitIdentity(WincheIdentity('a'));
      await app.settled;
      final session = db.sessions.last;
      log.clear();

      auth.emitTokenRotation('tok-2');
      await app.settled;

      expect(log, ['db:token']);
      expect(db.sessions.last, same(session));
      expect(session!.isActive, isTrue);
    });

    test('does not nudge a consumer that failed to bind', () async {
      final auth = FakeAuthService(app);
      ThrowingDatabaseService(app, log: log); // dropped from _bound on every bind
      RecordingStorageService(app, log: log); // binds normally
      auth.emitIdentity(WincheIdentity('a'));
      await app.settled;
      log.clear();

      auth.emitTokenRotation('tok-2');
      await app.settled;

      // Only the bound consumer is nudged. Nudging an unbound one would hand a
      // "your token rotated" signal to a service that has no session to rotate
      // it on.
      expect(log, ['st:token']);
    });
  });

  group('reconcile to latest', () {
    test('superseded states are never dispatched', () async {
      final auth = FakeAuthService(app);
      final db = RecordingDatabaseService(app, log: log);
      await app.settled;
      log.clear();
      db.sessions.clear();

      // A parks at the gate synchronously, so B and C are queued behind a
      // dispatch that is provably still in flight -- no wall-clock race.
      final gate = Completer<void>();
      db.gate = gate;
      auth.emitIdentity(WincheIdentity('a'));
      auth.emitIdentity(WincheIdentity('b'));
      auth.emitIdentity(WincheIdentity('c'));
      gate.complete();
      await app.settled;

      expect(db.sessions.map((s) => s?.identity.id).toList(), ['a', 'c']);
      expect(log, ['db:enter:a', 'db:exit:a', 'db:enter:c', 'db:exit:c']);
    });

    test('a swap supersedes a nudge queued behind an in-flight dispatch', () async {
      final auth = FakeAuthService(app);
      final db = RecordingDatabaseService(app, log: log);
      auth.emitIdentity(WincheIdentity('a'));
      await app.settled;
      log.clear();

      // The nudge must be *queued* to be superseded: announced with no dispatch
      // in flight it would be delivered immediately, which is correct.
      final gate = Completer<void>();
      db.gate = gate;
      auth.emitIdentity(WincheIdentity('b'));
      auth.emitTokenRotation('tok-2');
      auth.emitIdentity(WincheIdentity('c'));
      gate.complete();
      await app.settled;

      expect(log, ['db:enter:b', 'db:exit:b', 'db:enter:c', 'db:exit:c']);
      expect(log, isNot(contains('db:token')));
    });
  });

  group('serialisation', () {
    test('two dispatches never interleave', () async {
      final auth = FakeAuthService(app);
      final db = RecordingDatabaseService(app, log: log);
      await app.settled;
      log.clear();

      // B is announced while A's dispatch is provably still parked at the gate.
      final gate = Completer<void>();
      db.gate = gate;
      auth.emitIdentity(WincheIdentity('a'));
      auth.emitIdentity(WincheIdentity('b'));
      gate.complete();
      await app.settled;

      // Every enter is immediately followed by its own exit.
      for (var i = 0; i < log.length; i += 2) {
        final enter = log[i].split(':');
        final exit = log[i + 1].split(':');
        expect(enter[1], 'enter');
        expect(exit[1], 'exit');
        expect(exit[2], enter[2]);
      }
    });

    test('consumers are dispatched in registration order', () async {
      final auth = FakeAuthService(app);
      RecordingDatabaseService(app, log: log, label: 'first');
      RecordingStorageService(app, log: log, label: 'second');
      await app.settled;
      log.clear();

      auth.emitIdentity(WincheIdentity('a'));
      await app.settled;

      expect(log, ['first:enter:a', 'first:exit:a', 'second:enter:a', 'second:exit:a']);
    });
  });

  group('failure isolation', () {
    test('a thrower does not stop the others and reaches errors', () async {
      final errors = <WincheSessionConsumerError>[];
      app.errors.listen(errors.add);

      final auth = FakeAuthService(app);
      ThrowingDatabaseService(app, log: log);
      final st = RecordingStorageService(app, log: log);
      await app.settled;
      await Future<void>.delayed(Duration.zero); // let the initial failure land
      errors.clear();

      auth.emitIdentity(WincheIdentity('a'));
      await app.settled;
      await Future<void>.delayed(Duration.zero); // let the stream deliver

      expect(st.sessions.last?.identity.id, 'a');
      expect(errors, hasLength(1));
      expect(errors.single.consumer, isA<ThrowingDatabaseService>());
      expect(errors.single.error, isA<StateError>());
    });

    test('a thrower is re-dispatched on the next change', () async {
      final auth = FakeAuthService(app);
      ThrowingDatabaseService(app, log: log);
      await app.settled;
      log.clear();

      auth.emitIdentity(WincheIdentity('a'));
      await app.settled;
      auth.emitIdentity(WincheIdentity('b'));
      await app.settled;

      expect(log.where((e) => e == 'throwing:enter').length, 2);
    });
  });
}
