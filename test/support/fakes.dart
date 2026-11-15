import 'dart:async';

import 'package:winche_core/winche_core.dart';

/// An auth service driven directly by tests.
final class FakeAuthService extends WincheService with WincheIdentitySource {
  /// Creates the fake, optionally sharing an ordering [log] with other fakes.
  FakeAuthService(super.app, {this.log});

  /// Shared ordering log, when a test needs to see this service's teardown.
  final List<String>? log;

  WincheIdentity? _identity;
  String? _token;

  /// How many times [getAuthToken] was called.
  int tokenCalls = 0;

  /// Set to make [getAuthToken] throw, simulating a transient failure.
  Object? tokenError;

  @override
  WincheIdentity? get activeIdentity => _identity;

  @override
  Future<String?> getAuthToken({bool forceRefresh = false}) async {
    tokenCalls++;
    final error = tokenError;
    if (error != null) throw error;
    return forceRefresh ? '$_token-fresh' : _token;
  }

  /// Announces [identity] as the new signed-in principal.
  void emitIdentity(WincheIdentity? identity, {String? token}) {
    _identity = identity;
    _token = identity == null ? null : (token ?? 'token-for-${identity.id}');
    notifyIdentityChanged(identity);
  }

  /// Announces a token rotation without an identity change.
  void emitTokenRotation(String token) {
    _token = token;
    notifyTokenRotated();
  }

  @override
  Future<void> dispose() async {
    if (isDisposed) return;
    log?.add('auth:dispose');
    await super.dispose();
  }
}

/// A consumer that records every hook call into a shared log.
final class RecordingDatabaseService extends WincheService implements WincheSessionConsumer {
  /// Creates the fake, recording hook calls into [log] under [label].
  RecordingDatabaseService(super.app, {required this.log, this.label = 'db', this.delay = Duration.zero});

  /// Shared ordering log, appended to by every recording service.
  final List<String> log;

  /// Prefix identifying this service in [log].
  final String label;

  /// Artificial delay inside [onSessionChanged], to widen the window a
  /// concurrent dispatch would have to interleave in.
  final Duration delay;

  /// Holds the *next* [onSessionChanged] open until the test completes it.
  ///
  /// Prefer this over [delay] for anything asserting on concurrency. A
  /// dispatch parks here synchronously — `onSessionChanged` runs up to its
  /// first `await` before `emitIdentity` even returns — so a test can queue
  /// further events behind a known-in-flight dispatch with no wall-clock race
  /// to lose. Consumed once, then cleared.
  Completer<void>? gate;

  /// Every session this service has been handed, in order.
  final List<WincheSession?> sessions = [];

  @override
  Future<void> onSessionChanged(WincheSession? session) async {
    log.add('$label:enter:${session?.identity.id}');
    final held = gate;
    if (held != null) {
      gate = null;
      await held.future;
    }
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    sessions.add(session);
    log.add('$label:exit:${session?.identity.id}');
  }

  @override
  Future<void> onTokenChanged() async => log.add('$label:token');

  @override
  Future<void> dispose() async {
    if (isDisposed) return;
    log.add('$label:dispose');
    await super.dispose();
  }
}

/// A second consumer type, so two can coexist on one app.
final class RecordingStorageService extends WincheService implements WincheSessionConsumer {
  /// Creates the fake, recording hook calls into [log] under [label].
  RecordingStorageService(super.app, {required this.log, this.label = 'st'});

  /// Shared ordering log.
  final List<String> log;

  /// Prefix identifying this service in [log].
  final String label;

  /// Every session this service has been handed, in order.
  final List<WincheSession?> sessions = [];

  @override
  Future<void> onSessionChanged(WincheSession? session) async {
    log.add('$label:enter:${session?.identity.id}');
    sessions.add(session);
    log.add('$label:exit:${session?.identity.id}');
  }

  @override
  Future<void> onTokenChanged() async => log.add('$label:token');

  @override
  Future<void> dispose() async {
    if (isDisposed) return;
    log.add('$label:dispose');
    await super.dispose();
  }
}

/// A consumer whose session hook always throws.
///
/// It records token nudges too, so a test can prove that a consumer which
/// failed to bind is *not* nudged.
final class ThrowingDatabaseService extends WincheService implements WincheSessionConsumer {
  /// Creates the fake, recording hook calls into [log].
  ThrowingDatabaseService(super.app, {required this.log});

  /// Shared ordering log.
  final List<String> log;

  @override
  Future<void> onTokenChanged() async => log.add('throwing:token');

  @override
  Future<void> onSessionChanged(WincheSession? session) async {
    log.add('throwing:enter');
    throw StateError('bind failed');
  }
}

/// A consumer whose session hook never completes.
final class StuckDatabaseService extends WincheService implements WincheSessionConsumer {
  /// Creates the fake.
  StuckDatabaseService(super.app, {this.stuckOnDispose = false});

  /// Whether [dispose] should also hang, rather than only [onSessionChanged].
  final bool stuckOnDispose;

  @override
  Future<void> onSessionChanged(WincheSession? session) => Completer<void>().future;

  // Only the session hook hangs, as the class name says. Kept a no-op so the
  // behaviour matches what this fake inherited before onTokenChanged became
  // abstract -- making it hang too would change what the timeout tests mean.
  @override
  Future<void> onTokenChanged() async {}

  @override
  Future<void> dispose() async {
    if (stuckOnDispose) await Completer<void>().future;
    await super.dispose();
  }
}

/// A consumer whose teardown always throws.
final class ExplodingStorageService extends WincheService implements WincheSessionConsumer {
  /// Creates the fake.
  ExplodingStorageService(super.app);

  @override
  Future<void> onSessionChanged(WincheSession? session) async {}

  @override
  Future<void> onTokenChanged() async {}

  @override
  Future<void> dispose() async {
    await super.dispose();
    throw StateError('teardown failed');
  }
}
