/// Core primitives for the Winche Dart stack: the app registry, the session,
/// the service contracts every Winche package implements, and the shared
/// identity and options models.
library;

import 'src/base/winche_app.dart';
import 'src/models/winche_options.dart';

export 'src/base/winche_app.dart';
export 'src/base/session_consumer.dart';
export 'src/base/winche_service.dart';
export 'src/http/winche_http.dart';
export 'src/models/winche_identity.dart';
export 'src/models/winche_options.dart';
export 'src/models/winche_session.dart' show WincheSession, WincheSessionExpired;
export 'src/models/winche_exception.dart';

/// The global registry of [WincheApp]s.
///
/// Initialize once at startup, then reach the app from anywhere:
///
/// ```dart
/// void main() {
///   Winche.initializeApp(
///     options: WincheOptions(
///       databaseEndpoint: Uri.parse('wss://api.winche.dev/documents/ws'),
///       storageEndpoint: Uri.parse('https://api.winche.dev/files'),
///     ),
///   );
///
///   WincheAuth.instance;       // the identity producer
///   WincheDatabase.instance;   // consumers; registration order does not matter
///   WincheStorage.instance;
/// }
/// ```
abstract final class Winche {
  /// The name used when [initializeApp] is called without one.
  static const String defaultAppName = 'default';

  static final Map<String, WincheApp> _apps = {};

  /// The app registered under [defaultAppName].
  ///
  /// Throws an [ArgumentError] if [initializeApp] has not been called.
  static WincheApp get app => appFor(defaultAppName);

  /// Every currently initialized app.
  static List<WincheApp> get apps => List.unmodifiable(_apps.values);

  /// The app registered under [name].
  ///
  /// Throws an [ArgumentError] if there is none. Use [maybeAppFor] when its
  /// absence is a normal condition.
  static WincheApp appFor(String name) {
    return _apps[name] ?? (throw ArgumentError.value(name, 'name', 'No Winche app has been initialized under this name'));
  }

  /// The app registered under [name], or null if there is none.
  static WincheApp? maybeAppFor(String name) => _apps[name];

  /// Initializes the app registered under [name], or returns it if it already
  /// exists.
  ///
  /// Passing [options] that disagree with those an existing app was
  /// initialized with throws a [StateError] rather than silently ignoring
  /// them; use a different [name] to talk to a second backend. Omitting
  /// [options] on a repeat call always returns the existing app.
  static WincheApp initializeApp({String name = defaultAppName, WincheOptions? options, Duration hookTimeout = const Duration(seconds: 30)}) {
    final existing = _apps[name];
    if (existing != null) {
      if (options != null && existing.givenOptions != options) {
        throw StateError(
          'Winche app `$name` is already initialized with different options. '
          'Deinitialize it first, or initialize a second app under another name.',
        );
      }
      return existing;
    }

    final app = WincheApp(name, options: options, hookTimeout: hookTimeout)..onDisposed = _forget;
    _apps[name] = app;
    return app;
  }

  /// Disposes the app registered under [name] and removes it from the
  /// registry.
  ///
  /// Does nothing if no such app exists. The app is removed before its
  /// services are torn down, so a service that throws on dispose cannot leave
  /// a dead app reachable — the error still propagates to the caller.
  static Future<void> deinitializeApp([String name = defaultAppName]) async {
    final app = _apps.remove(name);
    if (app == null) return;
    await app.dispose();
  }

  /// Disposes every initialized app.
  ///
  /// Every app is torn down even if one throws; the first error is rethrown
  /// afterwards.
  static Future<void> deinitializeAll() async {
    Object? error;
    StackTrace? stackTrace;
    for (final name in _apps.keys.toList()) {
      try {
        await deinitializeApp(name);
      } catch (e, s) {
        error ??= e;
        stackTrace ??= s;
      }
    }
    if (error != null) Error.throwWithStackTrace(error, stackTrace!);
  }

  static void _forget(WincheApp app) {
    if (identical(_apps[app.name], app)) _apps.remove(app.name);
  }
}
