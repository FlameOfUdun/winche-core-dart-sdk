// The deprecated base classes are exercised on purpose: they must keep working for a release.
// ignore_for_file: deprecated_member_use_from_same_package
import 'package:test/test.dart';
import 'package:winche_core/winche_core.dart';

import 'support/fakes.dart';

/// A package's own service kind, unknown to core, following the session.
final class Messaging extends WincheService implements WincheSessionConsumer {
  Messaging(super.app);
  final List<String?> seen = [];
  @override
  Future<void> onSessionChanged(WincheSession? session) async => seen.add(session?.identity.id);
  @override
  Future<void> onTokenChanged() async => seen.add('rotated');
}

final class OldStyleAuth extends WincheAuthService {
  OldStyleAuth(super.app);
  WincheIdentity? _identity;
  @override
  WincheIdentity? get activeIdentity => _identity;
  @override
  Future<String?> getAuthToken({bool forceRefresh = false}) async => _identity == null ? null : 'old-${_identity!.id}';
  void signIn(String id) {
    _identity = WincheIdentity(id);
    notifyIdentityChanged(_identity);
  }
}

final class OldStyleStorage extends WincheStorageService {
  OldStyleStorage(super.app);
  WincheSession? session;
  @override
  Future<void> onSessionChanged(WincheSession? session) async => this.session = session;
  @override
  Future<void> onTokenChanged() async {}
}

final class SecondAuth extends WincheService with WincheIdentitySource {
  SecondAuth(super.app);
  @override
  WincheIdentity? get activeIdentity => null;
  @override
  Future<String?> getAuthToken({bool forceRefresh = false}) async => null;
}

final class Plain extends WincheService {
  Plain(super.app);
  bool disposed = false;
  @override
  Future<void> dispose() async {
    disposed = true;
    await super.dispose();
  }
}

void main() {
  late WincheApp app;
  setUp(() => app = WincheApp('roles'));
  tearDown(() async {
    if (!app.isDisposed) await app.dispose();
  });

  test("a package's own service kind follows the session with no core change", () async {
    final auth = FakeAuthService(app);
    final messaging = Messaging(app);
    auth.emitIdentity(WincheIdentity('alice'), token: 't1');
    await app.settled;
    auth.emitTokenRotation('t2');
    await app.settled;
    auth.emitIdentity(null);
    await app.settled;
    expect(messaging.seen, [null, 'alice', 'rotated', null]); // told it's signed out on registering, as every consumer is
  });

  test('an app has one identity source; a second is refused and left unregistered', () {
    FakeAuthService(app);
    expect(() => SecondAuth(app), throwsA(isA<StateError>().having((e) => e.message, 'message', contains('already has an identity source'))));
    expect(app.maybeService<SecondAuth>(), isNull);
  });

  test('services that play no role are held and disposed with the app', () async {
    final plain = Plain(app);
    await app.dispose();
    expect(plain.disposed, isTrue);
  });

  test('the deprecated base classes still work', () async {
    final auth = OldStyleAuth(app);
    final storage = OldStyleStorage(app);
    auth.signIn('bob');
    await app.settled;
    expect(storage.session?.identity.id, 'bob');
    expect(await storage.session?.token(), 'old-bob');
  });
}
