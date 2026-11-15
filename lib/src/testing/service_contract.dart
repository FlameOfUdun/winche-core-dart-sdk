import 'dart:async';

import '../base/winche_app.dart';
import '../base/winche_service.dart';
import '../models/winche_identity.dart';
import '../models/winche_options.dart';
import '../base/session_consumer.dart';
import '../models/winche_session.dart';
import 'contract_report.dart';
import 'scripted_auth_service.dart';

/// Drives a [WincheService] implementation through the full identity
/// lifecycle and reports whether it honours the contract core relies on.
///
/// Core guarantees the *sequencing*; it cannot guarantee that a service
/// actually swaps when told to, or that it nudges instead of rebuilding on a
/// token rotation. Those are the behaviours every Winche service is supposed to
/// share, and this is what makes that true rather than aspirational.
///
/// ```dart
/// test('WincheDatabase honours the service contract', () async {
///   final report = await WincheServiceContract.check(
///     create: (app) => WincheDatabase.forTesting(app),
///     sessionHandle: (service) => (service as WincheDatabase).store,
///   );
///   expect(report.isSuccess, isTrue, reason: report.toString());
/// });
/// ```
abstract final class WincheServiceContract {
  /// Runs every check against a service built by [create].
  ///
  /// [sessionHandle] returns an opaque value standing for the service's
  /// *current internal session* — its store handle, its connection, or a build
  /// counter — and null when it holds none. It must be a different value after
  /// a user switch and the **same** value after a token rotation.
  ///
  /// Do not return core's [WincheSession] here. That object belongs to core, so
  /// it stays identical through an internal rebuild, and the rotation check
  /// could never fail — the suite would certify a service that tears down and
  /// reopens its store on every token refresh. Return something only your
  /// implementation could produce.
  ///
  /// Without it the binding checks are skipped, and only sequencing, failure
  /// and teardown behaviour are verified.
  ///
  /// [options] is passed to the app under test, for a service that needs an
  /// endpoint or directory root to build a session at all.
  static Future<WincheContractReport> check({
    required WincheService Function(WincheApp app) create,
    Object? Function(WincheService service)? sessionHandle,
    WincheOptions? options,
  }) async {
    final recorder = ContractRecorder();

    Future<void> withHarness(Future<void> Function(_Harness harness) body) async {
      final harness = _Harness(create: create, options: options);
      try {
        await body(harness);
      } finally {
        await harness.close();
      }
    }

    const bindingChecks = [
      'binds when an identity arrives',
      'unbinds on sign-out',
      'swaps its session on a user switch',
      'does not rebuild on a token rotation',
    ];

    if (sessionHandle == null) {
      for (final check in bindingChecks) {
        recorder.skip(check, 'no sessionHandle driver was provided');
      }
    } else {
      await recorder.expect(bindingChecks[0], () async {
        await withHarness((h) async {
          recorder.require(sessionHandle(h.service) == null, 'held a session before any identity was announced');
          await h.signIn('alice');
          recorder.require(
            sessionHandle(h.service) != null,
            'built nothing after an identity was announced — did onSessionChanged do anything?',
          );
        });
      });

      await recorder.expect(bindingChecks[1], () async {
        await withHarness((h) async {
          await h.signIn('alice');
          await h.signOut();
          recorder.require(
            sessionHandle(h.service) == null,
            'still held a session after sign-out; the previous user\'s store or connection is still open',
          );
        });
      });

      await recorder.expect(bindingChecks[2], () async {
        await withHarness((h) async {
          await h.signIn('alice');
          final alice = sessionHandle(h.service);
          await h.signIn('bob');
          final bob = sessionHandle(h.service);

          recorder.require(alice != null && bob != null, 'held nothing for one of the two users');
          recorder.require(
            alice != bob,
            'kept the same internal session across a user switch — bob would be reading alice\'s state',
          );
        });
      });

      await recorder.expect(bindingChecks[3], () async {
        await withHarness((h) async {
          await h.signIn('alice');
          final before = sessionHandle(h.service);
          await h.rotateToken();
          recorder.require(
            sessionHandle(h.service) == before,
            'rebuilt on a token rotation. A rotation must nudge: tearing down and reopening a store '
            'and socket on every token refresh is exactly what onTokenChanged exists to avoid',
          );
        });
      });
    }

    await recorder.expect('completes its hooks within the deadline', () async {
      await withHarness((h) async {
        await h.signIn('alice');
        await h.signOut();
        recorder.require(
          h.errors.isEmpty,
          'reported ${h.errors.length} failure(s) during a plain sign-in/sign-out: '
          '${h.errors.join(', ')}',
        );
      });
    });

    await recorder.expect('survives a sign-out it never bound for', () async {
      await withHarness((h) async {
        await h.signOut();
        recorder.require(h.errors.isEmpty, 'threw on a sign-out while already unbound');
      });
    });

    await recorder.expect('dispose is idempotent and deregisters', () async {
      await withHarness((h) async {
        await h.signIn('alice');
        await h.service.dispose();
        recorder.require(h.service.isDisposed, 'isDisposed was false after dispose()');
        await h.service.dispose();
      });
    });

    return recorder.report;
  }
}

final class _Harness {
  _Harness({required WincheService Function(WincheApp app) create, WincheOptions? options})
    : app = WincheApp('winche-contract', options: options, hookTimeout: const Duration(seconds: 5)) {
    _errorSubscription = app.errors.listen(errors.add);
    auth = ScriptedAuthService(app);
    service = create(app);
  }

  final WincheApp app;
  late final ScriptedAuthService auth;
  late final WincheService service;
  final List<WincheSessionConsumerError> errors = [];
  late final StreamSubscription<WincheSessionConsumerError> _errorSubscription;

  Future<void> signIn(String id) async {
    auth.announce(WincheIdentity(id));
    await app.settled;
  }

  Future<void> signOut() async {
    auth.announce(null);
    await app.settled;
  }

  Future<void> rotateToken() async {
    auth.rotate();
    await app.settled;
  }

  Future<void> close() async {
    if (!app.isDisposed) {
      try {
        await app.dispose();
      } catch (_) {
        // Teardown failures are reported by their own check.
      }
    }
    await _errorSubscription.cancel();
  }
}
