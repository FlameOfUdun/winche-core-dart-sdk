import 'package:test/test.dart';
import 'package:winche_core/src/base/session_dispatcher.dart';
import 'package:winche_core/winche_core.dart';

/// A consumer that is deliberately **not** a `WincheService`.
///
/// This is the whole point of extracting the interface: if the dispatcher
/// still required the service hierarchy, this file would not compile.
final class _BareConsumer implements WincheSessionConsumer {
  final List<String> log;
  final Object? throws;

  _BareConsumer(this.log, {this.throws});

  @override
  bool isDisposed = false;

  @override
  Future<void> onSessionChanged(WincheSession? session) async {
    log.add('session:${session?.identity.id ?? 'null'}');
    if (throws != null) throw throws!;
  }

  @override
  Future<void> onTokenChanged() async => log.add('token');
}

WincheSession _session(String id) => WincheSession(WincheIdentity(id), ({bool forceRefresh = false}) async => 't');

void main() {
  group('WincheSessionConsumer', () {
    late List<String> log;
    late List<WincheSessionConsumerError> errors;
    late _BareConsumer consumer;
    late SessionDispatcher dispatcher;

    SessionDispatcher dispatcherFor(List<WincheSessionConsumer> consumers) =>
        SessionDispatcher(consumers: () => consumers, onError: errors.add, hookTimeout: const Duration(seconds: 5));

    setUp(() {
      log = [];
      errors = [];
      consumer = _BareConsumer(log);
      dispatcher = dispatcherFor([consumer]);
    });

    test('the dispatcher drives anything implementing the interface', () async {
      dispatcher.setSession(_session('alice'));
      await dispatcher.settled;
      expect(log, ['session:alice']);
    });

    test('a token nudge reaches a bound consumer', () async {
      dispatcher.setSession(_session('alice'));
      await dispatcher.settled;
      dispatcher.markTokenRotated();
      await dispatcher.settled;
      expect(log, ['session:alice', 'token']);
    });

    test('a disposed consumer is skipped', () async {
      consumer.isDisposed = true;
      dispatcher.setSession(_session('alice'));
      await dispatcher.settled;
      expect(log, isEmpty);
    });

    test('a throwing consumer is reported and left unbound, so the next '
        'change retries it', () async {
      final thrower = _BareConsumer(log, throws: StateError('boom'));
      final d = dispatcherFor([thrower]);

      d.setSession(_session('alice'));
      await d.settled;
      expect(errors, hasLength(1));
      expect(errors.single.consumer, same(thrower));

      // Unbound, so re-announcing the SAME session dispatches again rather
      // than being skipped as already-at-target.
      d.catchUp();
      await d.settled;
      expect(log, ['session:alice', 'session:alice']);
    });

    test('WincheSessionConsumerError reports the consumer through the interface, not '
        'the service hierarchy', () {
      // `consumer` is typed as the interface, not the service hierarchy. A
      // bare consumer has no `WincheService` to report, so narrowing it back
      // would make this unrepresentable.
      final error = WincheSessionConsumerError(consumer, StateError('boom'), StackTrace.empty);
      expect(error.consumer, isA<WincheSessionConsumer>());
      expect(error.consumer, isNot(isA<WincheService>()));
    });

    test('WincheSessionConsumerError is not an exception', () {
      // It is delivered as a value on WincheApp.errors and never thrown, so
      // typing it as one would invite `catch` sites that never fire. What is
      // worth catching is `error`, which it carries.
      final error = WincheSessionConsumerError(consumer, StateError('boom'), StackTrace.empty);
      expect(error, isNot(isA<Exception>()));
      expect(error, isNot(isA<WincheException>()));
    });

    test('WincheSessionConsumerError names the consumer and quotes what it threw', () {
      final error = WincheSessionConsumerError(consumer, StateError('boom'), StackTrace.empty);
      expect(error.toString(), contains('_BareConsumer'));
      expect(error.toString(), contains('boom'));
    });

    test('WincheSessionConsumerError keeps the original error and stack, unnarrowed', () {
      // A hook can throw anything -- a plain StateError, a value from a
      // package core has never heard of -- so handlers inspect `error`, not
      // the wrapper. Narrowing it would drop most of them.
      final thrown = StateError('boom');
      final stack = StackTrace.current;
      final error = WincheSessionConsumerError(consumer, thrown, stack);
      expect(error.error, same(thrown));
      expect(error.stackTrace, same(stack));
      expect(error.error, isNot(isA<WincheException>()));
    });

    test('a real service implements the interface, so it still qualifies', () {
      final app = WincheApp('session-consumer');
      addTearDown(app.dispose);
      expect(RecordingConsumer(app), isA<WincheSessionConsumer>());
    });
  });
}

/// A real service, to pin that the production hierarchy satisfies the
/// interface — the property `WincheApp` relies on when it collects consumers.
final class RecordingConsumer extends WincheService implements WincheSessionConsumer {
  RecordingConsumer(super.app);

  @override
  Future<void> onSessionChanged(WincheSession? session) async {}

  @override
  Future<void> onTokenChanged() async {}
}
