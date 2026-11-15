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

  test('consumers are disposed before the auth service', () async {
    // Auth is registered FIRST, so passing this cannot be an accident of
    // insertion order.
    FakeAuthService(app, log: log);
    RecordingDatabaseService(app, log: log, label: 'db');
    RecordingStorageService(app, log: log, label: 'st');
    await app.settled;
    log.clear();

    await app.dispose();

    expect(log, ['db:dispose', 'st:dispose', 'auth:dispose']);
  });

  test('teardown continues past a throwing service', () async {
    // `after` is registered AFTER the exploder, so it is only reached if the
    // loop keeps going. Asserting on a service registered *before* the throw
    // would pass even if teardown stopped at the first exception.
    ExplodingStorageService(app);
    final after = RecordingDatabaseService(app, log: log, label: 'after');
    await app.settled;
    log.clear();

    await expectLater(app.dispose(), throwsStateError);

    expect(after.isDisposed, isTrue);
    expect(log, contains('after:dispose'));
  });

  test('dispose is idempotent', () async {
    RecordingDatabaseService(app, log: log);
    await app.settled;

    await app.dispose();
    await app.dispose();

    expect(log.where((e) => e == 'db:dispose').length, 1);
  });

  test('the active session is invalidated on dispose', () async {
    final auth = FakeAuthService(app);
    final db = RecordingDatabaseService(app, log: log);
    auth.emitIdentity(WincheIdentity('a'));
    await app.settled;
    final session = db.sessions.last!;

    await app.dispose();

    expect(session.isActive, isFalse);
    expect(() => session.token(), throwsA(isA<WincheSessionExpired>()));
  });

  test('the errors stream closes on dispose', () async {
    var closed = false;
    app.errors.listen(null, onDone: () => closed = true);

    await app.dispose();
    await Future<void>.delayed(Duration.zero);

    expect(closed, isTrue);
  });
}
