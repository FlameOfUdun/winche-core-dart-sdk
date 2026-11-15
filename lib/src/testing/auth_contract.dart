import '../base/winche_app.dart';
import '../base/winche_service.dart';
import '../models/winche_options.dart';
import 'contract_report.dart';

/// Drives a [WincheIdentitySource] implementation and reports whether it honours
/// the two behavioural rules core depends on.
///
/// Both rules are unexpressible in the type system, and getting either wrong is
/// quiet and expensive:
///
/// 1. `notifyIdentityChanged(null)` means an **authoritative** sign-out. An
///    implementation that announces it on a transient refresh failure tears
///    down every session on the device on a flaky connection.
/// 2. `getAuthToken()` throws when a token cannot currently be obtained, and
///    returns null only when genuinely signed out. Reporting a network blip as
///    "signed out" has the same effect.
///
/// ```dart
/// test('WincheAuth honours the auth contract', () async {
///   final report = await WincheAuthContract.check(
///     create: (app) => WincheAuth(app, backend: FakeBackend()),
///     signIn: (auth) => (auth as WincheAuth).signInWithPassword('a@b.c', 'pw'),
///     signOut: (auth) => (auth as WincheAuth).signOut(),
///     induceTransientTokenFailure: (auth) async =>
///         (auth as WincheAuth).backend.failNextRefresh(),
///   );
///   expect(report.isSuccess, isTrue, reason: report.toString());
/// });
/// ```
abstract final class WincheAuthContract {
  /// Runs every check against an auth service built by [create].
  ///
  /// [signIn] and [signOut] drive the implementation's own sign-in surface —
  /// core defines none, so the caller must supply them.
  ///
  /// [induceTransientTokenFailure] should put the backend into a state where a
  /// token cannot currently be fetched but the user is still signed in — a
  /// dropped connection, not a revoked session. Rule 2 cannot be checked
  /// without it, and that check is skipped if it is omitted.
  static Future<WincheContractReport> check({
    required WincheIdentitySource Function(WincheApp app) create,
    required Future<void> Function(WincheIdentitySource auth) signIn,
    required Future<void> Function(WincheIdentitySource auth) signOut,
    Future<void> Function(WincheIdentitySource auth)? induceTransientTokenFailure,
    WincheOptions? options,
  }) async {
    final recorder = ContractRecorder();

    Future<void> withApp(Future<void> Function(WincheApp app, WincheIdentitySource auth) body) async {
      final app = WincheApp('winche-auth-contract', options: options, hookTimeout: const Duration(seconds: 5));
      final auth = create(app);
      try {
        await body(app, auth);
      } finally {
        if (!app.isDisposed) {
          try {
            await app.dispose();
          } catch (_) {
            // Reported by its own check.
          }
        }
      }
    }

    await recorder.expect('announces the identity on sign-in', () async {
      await withApp((app, auth) async {
        recorder.require(auth.activeIdentity == null, 'reported an identity before signing in');

        await signIn(auth);
        await app.settled;

        recorder.require(auth.activeIdentity != null, 'activeIdentity was still null after signing in');
        recorder.require(app.session != null, 'core never received the identity — did the implementation call notifyIdentityChanged?');
        recorder.require(app.session!.identity.id == auth.activeIdentity!.id, 'core built a session for a different identity than activeIdentity reports');
      });
    });

    await recorder.expect('supplies a token while signed in', () async {
      await withApp((app, auth) async {
        await signIn(auth);
        await app.settled;
        final token = await auth.getAuthToken();
        recorder.require(token != null, 'returned a null token while signed in');
      });
    });

    await recorder.expect('announces the sign-out', () async {
      await withApp((app, auth) async {
        await signIn(auth);
        await app.settled;
        await signOut(auth);
        await app.settled;

        recorder.require(auth.activeIdentity == null, 'still reported an identity after signing out');
        recorder.require(app.session == null, 'core still holds a session — did the implementation call notifyIdentityChanged(null)?');
        recorder.require(await auth.getAuthToken() == null, 'still returned a token after signing out');
      });
    });

    if (induceTransientTokenFailure == null) {
      recorder.skip('a transient token failure is not reported as a sign-out', 'no induceTransientTokenFailure driver was provided');
    } else {
      await recorder.expect('a transient token failure is not reported as a sign-out', () async {
        await withApp((app, auth) async {
          await signIn(auth);
          await app.settled;
          final sessionBefore = app.session;

          await induceTransientTokenFailure(auth);

          var threw = false;
          try {
            await auth.getAuthToken(forceRefresh: true);
          } catch (_) {
            threw = true;
          }

          recorder.require(
            threw,
            'returned instead of throwing when a token could not be obtained; a null return means '
            '"signed out", which would unbind every service on a network blip',
          );
          recorder.require(auth.activeIdentity != null, 'dropped activeIdentity on a transient failure — the user is still signed in');
          recorder.require(
            identical(app.session, sessionBefore),
            'core\'s session changed on a transient failure; the implementation announced a sign-out '
            'it should not have',
          );
        });
      });
    }

    return recorder.report;
  }
}
