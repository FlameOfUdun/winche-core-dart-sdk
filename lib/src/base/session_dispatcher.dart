import 'dart:async';

import 'package:meta/meta.dart';

import '../models/winche_session.dart';
import 'session_consumer.dart';

/// Reconciles every registered consumer to the latest desired session.
///
/// Events arriving during a dispatch overwrite the pending slot rather than
/// queueing, so a rapid `A -> B -> C` ends at C and B is never dispatched. This
/// is correct because a consumer's hook is written as "make yourself match this
/// session", which is idempotent, and it keeps work bounded no matter how noisy
/// the auth service is.
///
/// The per-service [_bound] map is what makes registration order irrelevant: a
/// newly registered consumer is absent from it, so it is dispatched while every
/// consumer already at the target is skipped.
@internal
final class SessionDispatcher {
  /// Every registered consumer, in registration order.
  final List<WincheSessionConsumer> Function() consumers;

  /// Sink for hook failures.
  final void Function(WincheSessionConsumerError error) onError;

  /// How long a single hook may run before it is abandoned.
  ///
  /// Dispatch is strictly sequential, so without a deadline one hook that
  /// never completes starves every other consumer *and* wedges teardown, which
  /// awaits [settled]. A consumer's hook opens sockets and stores — the two
  /// things that hang — so this is a live hazard, not a theoretical one.
  ///
  /// Dart futures cannot be cancelled, so the abandoned hook keeps running; we
  /// simply stop waiting on it. It is then treated exactly like a hook that
  /// threw: reported and left unbound, to be retried on the next change.
  final Duration hookTimeout;

  /// Creates a dispatcher.
  SessionDispatcher({required this.consumers, required this.onError, required this.hookTimeout});

  final Map<WincheSessionConsumer, WincheSession?> _bound = {};

  WincheSession? _desired;
  bool _sessionDirty = false;
  bool _tokenDirty = false;
  bool _running = false;
  Future<void> _drained = Future.value();

  /// The session consumers are being reconciled towards.
  WincheSession? get desired => _desired;

  /// Completes once no dispatch is in flight.
  Future<void> get settled => _drained;

  /// Sets the target session and schedules a dispatch.
  void setSession(WincheSession? session) {
    _desired = session;
    _sessionDirty = true;
    _schedule();
  }

  /// Schedules a token nudge to every bound consumer.
  void markTokenRotated() {
    _tokenDirty = true;
    _schedule();
  }

  /// Schedules a dispatch so a newly registered consumer is caught up.
  void catchUp() {
    _sessionDirty = true;
    _schedule();
  }

  /// Forgets a consumer that has been unregistered.
  void forget(WincheSessionConsumer service) => _bound.remove(service);

  void _schedule() {
    if (_running) return;
    _drained = _drain();
  }

  Future<void> _drain() async {
    _running = true;
    try {
      while (_sessionDirty || _tokenDirty) {
        if (_sessionDirty) {
          _sessionDirty = false;
          _tokenDirty = false; // a swap supersedes a queued nudge
          final target = _desired;
          for (final service in consumers()) {
            // The list was snapshotted before the first await, so a service
            // disposed during an earlier hook is still in it. Dispatching to it
            // would have it build a session -- socket, store, transfer queue --
            // that nothing will ever close, because its dispose() already ran.
            if (service.isDisposed) continue;
            if (_bound.containsKey(service) && identical(_bound[service], target)) {
              continue;
            }
            try {
              await service.onSessionChanged(target).timeout(hookTimeout);
              // It may have disposed itself inside its own hook; re-binding
              // would leave a stale entry keyed on an unreachable service.
              if (!service.isDisposed) _bound[service] = target;
            } catch (error, stackTrace) {
              _bound.remove(service); // leave unbound; retried on next change
              onError(WincheSessionConsumerError(service, error, stackTrace));
            }
          }
        } else {
          _tokenDirty = false;
          for (final service in consumers()) {
            if (service.isDisposed) continue;
            if (!_bound.containsKey(service)) continue;
            try {
              await service.onTokenChanged().timeout(hookTimeout);
            } catch (error, stackTrace) {
              onError(WincheSessionConsumerError(service, error, stackTrace));
            }
          }
        }
      }
    } finally {
      _running = false;
    }
  }
}
