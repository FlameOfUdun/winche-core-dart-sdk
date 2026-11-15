import '../models/winche_session.dart';

/// What `SessionDispatcher` needs from the things it reconciles.
///
/// Three members, and deliberately not a fourth: the dispatcher decides *what*
/// each consumer should be bound to, and knows nothing about what a consumer
/// is, what it connects to, or which app it belongs to. Stating that as an
/// interface keeps the dependency pointing one way — the dispatcher does not
/// reach into the service hierarchy, and the service hierarchy does not have
/// to be present to test the dispatcher.
///
/// The database, storage and functions services implement this, and in
/// production every consumer is one of them. The interface exists so that fact
/// is a coincidence the dispatcher does not rely on.
///
/// Implement rather than extend — this is an `interface class`, so it carries
/// no state or behaviour to inherit.
abstract interface class WincheSessionConsumer {
  /// Whether this consumer has been disposed.
  ///
  /// Checked immediately before every hook, not merely once per dispatch.
  /// Dispatch is sequential and a hook can dispose its own consumer, or a
  /// sibling's, while later consumers are still waiting their turn — so a
  /// consumer that was live when the pass began may not be when its turn
  /// arrives. Dispatching to it would have it build a session whose teardown
  /// has already run.
  bool get isDisposed;

  /// Make this consumer match [session]. Null means signed out.
  ///
  /// The dispatcher awaits this and dispatches nothing else, to any consumer,
  /// until it completes — so an outgoing session is always fully torn down
  /// before the incoming one is built.
  Future<void> onSessionChanged(WincheSession? session);

  /// The token rotated but the session did not. Nudge; do not rebuild.
  Future<void> onTokenChanged();
}

/// A failure raised by a consumer hook, reported on `WincheApp.errors`.
///
/// Dispatch isolates hook failures: the throwing consumer is left unbound and
/// every other consumer still receives its dispatch. This carries the failure
/// out for logging.
///
/// Deliberately **not** an exception. It is produced by the dispatcher and
/// delivered as a value on a stream; nothing throws it, and typing it as an
/// exception invites `catch` sites that will never fire. What was thrown is
/// [error], which is the thing worth catching or rethrowing.
///
/// [error] is not narrowed: a hook can throw anything at all, including a
/// plain `StateError` or a value from a package core has never heard of.
/// Handlers should inspect [error], not this wrapper, when deciding what
/// happened.
final class WincheSessionConsumerError {
  /// The consumer whose hook threw.
  ///
  /// Typed as the interface the dispatcher works through, since that is all it
  /// knows about what it drives.
  final WincheSessionConsumer consumer;

  /// What the hook threw.
  final Object error;

  /// Where it threw.
  final StackTrace stackTrace;

  /// Creates a consumer error.
  WincheSessionConsumerError(this.consumer, this.error, this.stackTrace);

  @override
  String toString() => 'WincheSessionConsumerError(${consumer.runtimeType}): $error';
}
