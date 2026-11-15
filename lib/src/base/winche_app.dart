import 'dart:async';

import 'package:meta/meta.dart';

import '../models/winche_identity.dart';
import '../models/winche_options.dart';
import 'session_consumer.dart';
import '../models/winche_session.dart';
import 'session_dispatcher.dart';
import '../http/winche_http.dart';
import '../platform/platform.dart' as platform;
import 'winche_service.dart';

/// A named, isolated configuration of the Winche stack and the services
/// attached to it.
///
/// Most programs need one app and reach it through `Winche.app`. Multiple apps
/// let a single process address two backends — production and staging, or two
/// tenants — each with its own [options] and its own services.
///
/// The app is **not** a service-lookup surface: services expose their own
/// `instance` and `instanceFor` accessors. What the app exposes is [options],
/// [errors] and [dispose].
final class WincheApp {
  /// The name this app is registered under.
  final String name;

  /// Stack-wide configuration, or null if none was supplied; redirected to the
  /// emulator after [useEmulator].
  WincheOptions? get options => _options;
  WincheOptions? _options;

  /// The options this app was created with, before [useEmulator].
  @internal
  final WincheOptions? givenOptions;

  /// Invoked once, after this app has torn down its services.
  ///
  /// `Winche` uses this to drop the app from the global registry, so calling
  /// [dispose] directly can never leave a disposed app reachable.
  @internal
  void Function(WincheApp app)? onDisposed;

  final Map<Type, WincheService> _services = {};
  final StreamController<WincheSessionConsumerError> _errors = StreamController<WincheSessionConsumerError>.broadcast();

  /// How long a single service hook may run before it is abandoned.
  ///
  /// Applies to `onSessionChanged`, `onTokenChanged` and `dispose`. Dispatch is
  /// sequential and teardown awaits it, so without a deadline one hook that
  /// never returns starves every other service and hangs the app. An abandoned
  /// hook is treated as a failed one: reported on [errors] and left unbound.
  ///
  /// The default is generous — a first connection on a cold network is slow,
  /// and a false positive costs a spurious rebind. Lower it in tests.
  final Duration hookTimeout;

  late final SessionDispatcher _dispatcher = SessionDispatcher(
    consumers: () => _services.values.whereType<WincheSessionConsumer>().toList(),
    onError: _reportError,
    hookTimeout: hookTimeout,
  );

  void _reportError(WincheSessionConsumerError error) {
    // dispose() closes this controller, and adding to a closed one throws.
    if (!_errors.isClosed) _errors.add(error);
  }

  bool _disposed = false;

  /// Creates a standalone app. Prefer `Winche.initializeApp`.
  WincheApp(this.name, {WincheOptions? options, this.hookTimeout = const Duration(seconds: 30)})
    : _options = options,
      givenOptions = options;

  /// Sends this app's services to the local Winche emulator
  /// (`winche emulators start`) at [host] and [port] instead of the server in
  /// [options] — every service, or only those whose ids are in [only]
  /// (`database`, `storage`, `auth`, `functions`, …).
  ///
  /// ```dart
  /// final app = Winche.initializeApp(options: DefaultWincheOptions.currentPlatform);
  /// if (kDebugMode) app.useEmulator();
  /// ```
  ///
  /// On Android, `localhost` means the device itself, so it becomes `10.0.2.2`:
  /// the computer an Android emulator runs on.
  ///
  /// Call it straight after creating the app: it throws a [StateError] once a
  /// service that talks to the server is attached or a request has been sent,
  /// rather than switching half the app mid-session.
  void useEmulator({String host = 'localhost', int port = 9090, Set<String>? only}) {
    if (_disposed) throw StateError('Winche app `$name` has been disposed.');
    final attached = _services.values.where((s) => s is WincheSessionConsumer || s is WincheIdentitySource).map((s) => s.runtimeType);
    if (attached.isNotEmpty || (_http?.hasSent ?? false)) {
      throw StateError(
        'Winche app `$name` is already in use${attached.isEmpty ? '' : ' (${attached.join(', ')})'}: '
        'call useEmulator straight after initializeApp, before using any service.',
      );
    }
    final resolved = host == 'localhost' && platform.isAndroid ? '10.0.2.2' : host;
    _options = (_options ?? const WincheOptions()).redirectedTo(Uri(scheme: 'http', host: resolved, port: port), only: only);
  }

  /// The app's client for calls to the Winche server, shared by every package:
  /// it adds the signed-in user's token, refreshes it once on a 401, and retries
  /// what is safe to retry.
  WincheHttp get http => _http ??= WincheHttp(this);
  WincheHttp? _http;

  /// Whether [dispose] has run.
  bool get isDisposed => _disposed;

  /// Failures raised by service hooks.
  ///
  /// Broadcast and open until [dispose]. Events emitted with no listener are
  /// dropped: this exists for logging, not correctness.
  Stream<WincheSessionConsumerError> get errors => _errors.stream;

  /// The session consumers are being reconciled towards.
  @internal
  WincheSession? get session => _dispatcher.desired;

  /// This app's auth service, or null if none is registered.
  @internal
  WincheIdentitySource? get authService => _services.values.whereType<WincheIdentitySource>().firstOrNull;

  /// Completes once no dispatch is in flight.
  ///
  /// After changing sign-in state, awaiting this is how you know every service
  /// has finished reacting — useful for gating UI on a fully rebound stack, and
  /// the only reliable way for a service package's tests to wait for a dispatch
  /// without racing the wall clock.
  ///
  /// Bounded by [hookTimeout]: a service that never finishes cannot make this
  /// hang forever.
  Future<void> get settled => _dispatcher.settled;

  /// Registers [service]. Called by the [WincheService] constructor.
  ///
  /// Throws a [StateError] if this app is disposed, or if a *different* service
  /// of the same runtime type is already registered — silently shadowing one
  /// would make lookups depend on construction order.
  @internal
  void registerService(WincheService service) {
    if (_disposed) {
      throw StateError('Winche app `$name` has been disposed.');
    }

    final existing = _services[service.runtimeType];
    if (existing != null && !identical(existing, service)) {
      throw StateError('A ${service.runtimeType} is already registered with Winche app `$name`.');
    }
    _services[service.runtimeType] = service;

    // Dispatched by role, so a package's own service kinds need nothing here.
    if (service is WincheIdentitySource) {
      final other = _services.values.whereType<WincheIdentitySource>().where((s) => !identical(s, service)).firstOrNull;
      if (other != null) {
        _services.remove(service.runtimeType);
        throw StateError(
          'Winche app `$name` already has an identity source (${other.runtimeType}); '
          'an app has one. Use a second app for a second backend.',
        );
      }
      handleIdentityChanged(service.activeIdentity);
    }
    if (service is WincheSessionConsumer) _dispatcher.catchUp();
  }

  /// Removes [service]. Called by [WincheService.dispose].
  @internal
  void unregisterService(WincheService service) {
    if (identical(_services[service.runtimeType], service)) {
      _services.remove(service.runtimeType);
    }
    // Switched, not `is WincheSessionConsumer`: that tests a type unrelated to
    // WincheService, which Dart does not promote through, so `service` would
    // still be a WincheService at the call. Matching the sealed subtypes
    // promotes and stays exhaustiveness-checked, as in registerService.
    //
    // The two consumer cases repeat their body rather than sharing one: a
    // shared body joins the patterns back to WincheService and loses the
    // promotion this switch exists to get.
    if (service is WincheSessionConsumer) _dispatcher.forget(service as WincheSessionConsumer);
  }

  /// Returns the single registered service assignable to [T], or null.
  ///
  /// Throws a [StateError] if more than one matches.
  @internal
  T? maybeService<T extends WincheService>() {
    T? found;
    for (final service in _services.values) {
      if (service is! T) continue;
      if (found != null) {
        throw StateError(
          'More than one $T is registered with Winche app `$name`; '
          'request a more specific type to disambiguate.',
        );
      }
      found = service;
    }
    return found;
  }

  /// Turns an identity change into a session change. Called by the auth
  /// service via `notifyIdentityChanged`.
  ///
  /// A new session is constructed only when the identity **id** differs. The
  /// comparison is on `id` alone, not on [WincheIdentity] equality: claims
  /// equality is shallow, so an identity carrying a collection-valued claim
  /// such as `roles` never compares equal to a structurally identical peer,
  /// and using `==` would turn every token refresh into a full session swap.
  @internal
  void handleIdentityChanged(WincheIdentity? identity) {
    // An auth implementation may well announce a sign-out from its own
    // dispose(). Teardown has already awaited the dispatcher, so scheduling
    // more work here would dispatch against services that are being torn down.
    // Today that happens to be harmless -- auth is disposed last, by which
    // point the consumer set is empty -- but that is an accident of ordering,
    // not an invariant worth resting on.
    if (_disposed) return;

    final current = _dispatcher.desired;
    if (identity != null && current != null && current.identity.id == identity.id && current.isActive) {
      return;
    }

    current?.invalidate();
    _dispatcher.setSession(identity == null ? null : WincheSession(identity, _fetchToken));
  }

  /// Schedules a token nudge. Called by the auth service via
  /// `notifyTokenRotated`.
  @internal
  void handleTokenRotated() {
    if (_disposed) return;
    _dispatcher.markTokenRotated();
  }

  Future<String?> _fetchToken({bool forceRefresh = false}) async {
    final auth = authService;
    if (auth == null) return null;
    return auth.getAuthToken(forceRefresh: forceRefresh);
  }

  /// Disposes every registered service and marks this app unusable.
  ///
  /// Consumers are disposed before the auth service, deterministically and
  /// regardless of registration order, so a consumer can still read a token
  /// while shutting down. Every service is disposed even if an earlier one
  /// throws; the first error is rethrown once teardown completes.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;

    await _dispatcher.settled;
    _dispatcher.desired?.invalidate();

    final ordered = <WincheService>[
      ..._services.values.whereType<WincheSessionConsumer>().cast<WincheService>(),
      ..._services.values.whereType<WincheIdentitySource>(),
      ..._services.values.where((s) => s is! WincheSessionConsumer && s is! WincheIdentitySource),
    ];

    Object? error;
    StackTrace? stackTrace;
    try {
      for (final service in ordered) {
        try {
          // Bounded for the same reason dispatch is: a service whose teardown
          // never returns would otherwise strand every service after it.
          await service.dispose().timeout(hookTimeout);
        } catch (e, s) {
          error ??= e;
          stackTrace ??= s;
        }
      }
    } finally {
      _services.clear();
      _http?.close();
      await _errors.close();
      onDisposed?.call(this);
    }

    if (error != null) Error.throwWithStackTrace(error, stackTrace!);
  }

  @override
  String toString() => 'WincheApp($name)';
}
