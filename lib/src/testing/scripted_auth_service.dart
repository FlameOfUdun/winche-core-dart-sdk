import '../base/winche_service.dart';
import '../models/winche_identity.dart';

/// A [WincheIdentitySource] driven directly by a test rather than a backend.
///
/// Contract suites use it to put an app into a chosen sign-in state without
/// needing a real auth implementation. It is also useful on its own, for a
/// service package's own tests.
final class ScriptedAuthService extends WincheService with WincheIdentitySource {
  /// Registers a scripted auth service with [app].
  ScriptedAuthService(super.app);

  WincheIdentity? _identity;
  int _rotation = 0;

  /// Set to make [getAuthToken] throw, standing in for a transient failure.
  Object? tokenError;

  @override
  WincheIdentity? get activeIdentity => _identity;

  @override
  Future<String?> getAuthToken({bool forceRefresh = false}) async {
    final error = tokenError;
    if (error != null) throw error;
    if (_identity == null) return null;
    return 'token-${_identity!.id}-$_rotation';
  }

  /// Announces [identity] as signed in, or null as an authoritative sign-out.
  void announce(WincheIdentity? identity) {
    _identity = identity;
    _rotation = 0;
    notifyIdentityChanged(identity);
  }

  /// Announces a token rotation without changing the identity.
  void rotate() {
    _rotation++;
    notifyTokenRotated();
  }
}
