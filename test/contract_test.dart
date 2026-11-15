import 'dart:async';

import 'package:test/test.dart';
import 'package:winche_core/testing.dart';
import 'package:winche_core/winche_core.dart';

/// The contract suites are only worth shipping if they fail a broken
/// implementation. Each group below feeds them one deliberate defect and
/// asserts the corresponding check catches it — a suite that passes everything
/// is worse than no suite, because it certifies nothing while looking like it
/// certifies something.

/// Stands in for whatever a real service opens — a store, a socket.
final class FakeStore {
  FakeStore(this.owner);
  final String owner;
}

/// A well-behaved consumer: swaps on identity change, nudges on rotation.
final class GoodService extends WincheService implements WincheSessionConsumer {
  GoodService(super.app);

  FakeStore? store;
  int nudges = 0;

  @override
  Future<void> onSessionChanged(WincheSession? session) async {
    store = session == null ? null : FakeStore(session.identity.id);
  }

  @override
  Future<void> onTokenChanged() async => nudges++;
}

/// Ignores its hooks entirely.
final class InertService extends WincheService implements WincheSessionConsumer {
  InertService(super.app);
  FakeStore? get store => null;

  @override
  Future<void> onSessionChanged(WincheSession? session) async {}

  @override
  Future<void> onTokenChanged() async {}
}

/// Binds, but never lets go on sign-out.
final class StickyService extends WincheService implements WincheSessionConsumer {
  StickyService(super.app);
  FakeStore? store;

  @override
  Future<void> onSessionChanged(WincheSession? session) async {
    if (session != null) store = FakeStore(session.identity.id);
  }

  @override
  Future<void> onTokenChanged() async {}
}

/// Reopens its store on a token rotation instead of nudging — the expensive
/// mistake the rotation check exists to catch.
final class RebuildingService extends WincheService implements WincheSessionConsumer {
  RebuildingService(super.app);
  FakeStore? store;

  @override
  Future<void> onSessionChanged(WincheSession? session) async {
    store = session == null ? null : FakeStore(session.identity.id);
  }

  @override
  Future<void> onTokenChanged() async => store = FakeStore(store!.owner);
}

/// Throws from its session hook.
final class BrokenService extends WincheService implements WincheSessionConsumer {
  BrokenService(super.app);
  FakeStore? get store => null;

  @override
  Future<void> onSessionChanged(WincheSession? session) async => throw StateError('nope');

  @override
  Future<void> onTokenChanged() async {}
}

Future<WincheContractReport> checkService(WincheService Function(WincheApp) create, Object? Function(WincheService) handle) =>
    WincheServiceContract.check(create: create, sessionHandle: handle);

void main() {
  group('WincheServiceContract', () {
    test('passes a conforming service', () async {
      final report = await checkService(GoodService.new, (s) => (s as GoodService).store);
      expect(report.isSuccess, isTrue, reason: report.toString());
      expect(report.skipped, isEmpty);
    });

    test('fails a service that ignores its hooks', () async {
      final report = await checkService(InertService.new, (s) => (s as InertService).store);
      expect(report.isSuccess, isFalse);
      expect(report.failures.map((f) => f.check), contains('binds when an identity arrives'));
    });

    test('fails a service that never unbinds', () async {
      final report = await checkService(StickyService.new, (s) => (s as StickyService).store);
      expect(report.isSuccess, isFalse);
      expect(report.failures.map((f) => f.check), contains('unbinds on sign-out'));
    });

    test('fails a service that rebuilds on a token rotation', () async {
      final report = await checkService(RebuildingService.new, (s) => (s as RebuildingService).store);
      expect(report.isSuccess, isFalse);
      expect(report.failures.map((f) => f.check), contains('does not rebuild on a token rotation'));
    });

    test('fails a service whose hook throws', () async {
      final report = await checkService(BrokenService.new, (s) => (s as BrokenService).store);
      expect(report.isSuccess, isFalse);
      expect(report.failures.map((f) => f.check), contains('completes its hooks within the deadline'));
    });

    test('skips the binding checks without a sessionHandle driver', () async {
      final report = await WincheServiceContract.check(create: GoodService.new);
      expect(report.skipped.keys, contains('binds when an identity arrives'));
      expect(report.isSuccess, isTrue);
    });
  });

  group('WincheAuthContract', () {
    test('passes a conforming auth service', () async {
      final report = await WincheAuthContract.check(
        create: ScriptedAuthService.new,
        signIn: (auth) async => (auth as ScriptedAuthService).announce(WincheIdentity('alice')),
        signOut: (auth) async => (auth as ScriptedAuthService).announce(null),
        induceTransientTokenFailure: (auth) async => (auth as ScriptedAuthService).tokenError = StateError('network down'),
      );
      expect(report.isSuccess, isTrue, reason: report.toString());
    });

    test('fails an auth service that never announces', () async {
      final report = await WincheAuthContract.check(
        create: _SilentAuthService.new,
        signIn: (auth) async => (auth as _SilentAuthService).signInWithoutTelling(),
        signOut: (auth) async => (auth as _SilentAuthService).signOutWithoutTelling(),
      );
      expect(report.isSuccess, isFalse);
      expect(report.failures.map((f) => f.detail).join(), contains('notifyIdentityChanged'));
    });

    test('fails an auth service that reports a transient failure as a sign-out', () async {
      final report = await WincheAuthContract.check(
        create: _FlakyAuthService.new,
        signIn: (auth) async => (auth as _FlakyAuthService).signIn(),
        signOut: (auth) async => (auth as _FlakyAuthService).signOutNow(),
        induceTransientTokenFailure: (auth) async => (auth as _FlakyAuthService).dropConnection(),
      );
      expect(report.isSuccess, isFalse);
      expect(report.failures.map((f) => f.check), contains('a transient token failure is not reported as a sign-out'));
    });

    test('skips the transient-failure check without a driver', () async {
      final report = await WincheAuthContract.check(
        create: ScriptedAuthService.new,
        signIn: (auth) async => (auth as ScriptedAuthService).announce(WincheIdentity('alice')),
        signOut: (auth) async => (auth as ScriptedAuthService).announce(null),
      );
      expect(report.skipped.keys, contains('a transient token failure is not reported as a sign-out'));
      expect(report.isSuccess, isTrue);
    });
  });
}

/// Changes its identity without telling core.
final class _SilentAuthService extends WincheService with WincheIdentitySource {
  _SilentAuthService(super.app);
  WincheIdentity? _identity;

  @override
  WincheIdentity? get activeIdentity => _identity;

  @override
  Future<String?> getAuthToken({bool forceRefresh = false}) async => _identity == null ? null : 'tok';

  void signInWithoutTelling() => _identity = WincheIdentity('alice');
  void signOutWithoutTelling() => _identity = null;
}

/// Treats a dropped connection as a sign-out — the failure rule 2 exists for.
final class _FlakyAuthService extends WincheService with WincheIdentitySource {
  _FlakyAuthService(super.app);
  WincheIdentity? _identity;

  @override
  WincheIdentity? get activeIdentity => _identity;

  @override
  Future<String?> getAuthToken({bool forceRefresh = false}) async => _identity == null ? null : 'tok';

  void signIn() {
    _identity = WincheIdentity('alice');
    notifyIdentityChanged(_identity);
  }

  void signOutNow() {
    _identity = null;
    notifyIdentityChanged(null);
  }

  /// The bug: a network blip is reported as an authoritative sign-out, which
  /// tears down every service on the device.
  void dropConnection() {
    _identity = null;
    notifyIdentityChanged(null);
  }
}
