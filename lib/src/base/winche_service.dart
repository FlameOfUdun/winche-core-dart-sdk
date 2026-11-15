import 'package:meta/meta.dart';

import '../models/winche_identity.dart';
import 'session_consumer.dart';
import 'winche_app.dart';

/// Anything that attaches itself to a [WincheApp].
///
/// Open to every package: a service picks the roles it plays rather than a
/// base class core has to know about.
///
/// - [WincheIdentitySource]: it *produces* the signed-in identity
///   (`winche_auth`, a Keycloak adapter, …). An app holds at most one.
/// - [WincheSessionConsumer]: it *follows* the session — database, storage,
///   functions, or any package of your own. The app hands it each session and
///   token rotation.
/// - Neither: a plain service the app only holds and disposes.
///
/// ```dart
/// final class WincheMessaging extends WincheService implements WincheSessionConsumer {
///   WincheMessaging(super.app);
///   @override
///   Future<void> onSessionChanged(WincheSession? session) async { … }
///   @override
///   Future<void> onTokenChanged() async {}
/// }
/// ```
///
/// The contract tests in `package:winche_core/testing.dart` check that a
/// service plays its role correctly.
abstract class WincheService {
  /// The app this service is attached to.
  final WincheApp app;

  bool _disposed = false;

  /// Creates the service and registers it with [app].
  ///
  /// Throws a [StateError] if [app] has been disposed, or already holds a
  /// service of this exact runtime type.
  WincheService(this.app) {
    app.registerService(this);
  }

  /// The [T] attached to [app], constructing it with [create] if there is none.
  ///
  /// Use this rather than caching instances in a static map of your own. Core's
  /// registry already drops a service when it is disposed and clears when its
  /// app is, so an instance obtained here can never be a stale one left over
  /// from a previous app registered under the same name — which a hand-rolled
  /// cache has to remember to evict, and silently gets wrong when it forgets.
  ///
  /// ```dart
  /// final class WincheDatabase extends WincheDatabaseService {
  ///   WincheDatabase._(super.app);
  ///
  ///   static WincheDatabase get instance => instanceFor(Winche.app);
  ///
  ///   static WincheDatabase instanceFor(WincheApp app) =>
  ///       WincheService.instanceFor(app, () => WincheDatabase._(app));
  /// }
  /// ```
  static T instanceFor<T extends WincheService>(WincheApp app, T Function() create) {
    return app.maybeService<T>() ?? create();
  }

  /// Whether [dispose] has run.
  bool get isDisposed => _disposed;

  /// Releases this service and deregisters it from [app].
  ///
  /// Safe to call more than once. Overrides must call `super.dispose()` last.
  @mustCallSuper
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    app.unregisterService(this);
  }
}

/// The role of the service that owns authentication for an app.
///
/// It announces changes to core through [notifyIdentityChanged] and
/// [notifyTokenRotated]; core turns those into sessions and dispatches them.
///
/// Core defines no sign-in surface: there is no `signIn`, no `signOut` and no
/// credentials type. How a backend authenticates — password, OIDC redirect,
/// refresh token, device code — is the auth package's concern. Expose whatever
/// shape that backend needs and announce the result.
///
/// Two rules bind implementers, neither expressible in the type system:
///
/// 1. `notifyIdentityChanged(null)` means an **authoritative** sign-out —
///    explicit logout, invalid refresh token, expired session. A transient
///    refresh failure announces nothing.
/// 2. [getAuthToken] returns null when signed out and **throws** when a token
///    cannot currently be obtained. It must never report a transient failure
///    as a sign-out.
///
/// Together these stop a flaky connection from tearing down every session on
/// the device.
mixin WincheIdentitySource on WincheService {
  /// The identity currently signed in, or null.
  WincheIdentity? get activeIdentity;

  /// The current token, or null when signed out.
  ///
  /// Throws when a token cannot currently be obtained — see rule 2 above.
  Future<String?> getAuthToken({bool forceRefresh = false});

  /// Announce that [activeIdentity] changed.
  ///
  /// Call this *after* [activeIdentity] reflects the new value.
  @protected
  void notifyIdentityChanged(WincheIdentity? identity) {
    app.handleIdentityChanged(identity);
  }

  /// Announce that the token rotated while the identity stayed the same.
  @protected
  void notifyTokenRotated() {
    app.handleTokenRotated();
  }
}

/// A service that produces the identity, as a base class.
@Deprecated('Use `extends WincheService with WincheIdentitySource`. Removed in winche_core 2.0.')
abstract class WincheAuthService extends WincheService with WincheIdentitySource {
  /// Creates the auth service and registers it with [app].
  WincheAuthService(super.app);
}

/// The database's service kind.
@Deprecated('Use `extends WincheService implements WincheSessionConsumer`. Removed in winche_core 2.0.')
abstract class WincheDatabaseService extends WincheService implements WincheSessionConsumer {
  /// Registers the service with [app].
  WincheDatabaseService(super.app);
}

/// Storage's service kind.
@Deprecated('Use `extends WincheService implements WincheSessionConsumer`. Removed in winche_core 2.0.')
abstract class WincheStorageService extends WincheService implements WincheSessionConsumer {
  /// Registers the service with [app].
  WincheStorageService(super.app);
}

/// The functions client's service kind.
@Deprecated('Use `extends WincheService implements WincheSessionConsumer`. Removed in winche_core 2.0.')
abstract class WincheFunctionsService extends WincheService implements WincheSessionConsumer {
  /// Registers the service with [app].
  WincheFunctionsService(super.app);
}
