import 'package:meta/meta.dart';

import 'winche_exception.dart';
import 'winche_identity.dart';

/// Fetches the current token for a session.
typedef WincheTokenFetcher = Future<String?> Function({bool forceRefresh});

/// Thrown by [WincheSession.token] once the session has been superseded by a
/// user switch or ended by a sign-out.
///
/// Reaching this means an operation outlived the session it started under.
/// Without it the operation would silently read the *next* user's token.
final class WincheSessionExpired extends WincheException {
  /// The identity the expired session belonged to.
  final WincheIdentity identity;

  /// Creates the exception.
  /// Its code is [WincheErrorCode.aborted]: the operation outlived its session; abandon it.
  WincheSessionExpired(this.identity) : super(WincheErrorCode.aborted, 'the session for ${identity.id} is no longer active');
}

/// A signed-in identity together with token access scoped to its lifetime.
///
/// Constructed and invalidated by core, never by an auth implementation.
/// Services receive one through `WincheSessionConsumer.onSessionChanged` and
/// hold it for as long as the session lasts.
final class WincheSession {
  /// Who this session belongs to.
  final WincheIdentity identity;

  final WincheTokenFetcher _fetchToken;
  bool _active = true;

  /// Creates a session. Called by core.
  @internal
  WincheSession(this.identity, this._fetchToken);

  /// False once this session has been superseded or signed out.
  bool get isActive => _active;

  /// Ends this session. Called by core. Idempotent.
  @internal
  void invalidate() => _active = false;

  /// The current token for this session.
  ///
  /// Throws [WincheSessionExpired] if this session is already inactive, and
  /// again if it is invalidated *while* the fetch is in flight. The second
  /// check is not redundant: core's fetcher resolves the token of whoever is
  /// signed in at the moment it runs, so a call that straddles a user switch
  /// would otherwise hand back the next user's token — the exact
  /// cross-identity contamination this type exists to prevent.
  ///
  /// The first throw is **synchronous**, so `session.token().catchError(...)`
  /// will not observe it: the exception escapes before a future exists. Wrap
  /// `await session.token()` in `try`/`catch`, which catches both.
  Future<String?> token({bool forceRefresh = false}) {
    if (!_active) throw WincheSessionExpired(identity);
    return _fetchToken(forceRefresh: forceRefresh).then((token) {
      if (!_active) throw WincheSessionExpired(identity);
      return token;
    });
  }

  @override
  String toString() => 'WincheSession(${identity.id}, active: $_active)';
}
