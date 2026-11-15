import 'package:test/test.dart';
import 'package:winche_core/winche_core.dart';

/// Stands in for the exception a downstream package would declare.
final class _FakeServiceException extends WincheException {
  _FakeServiceException(String message) : super(WincheErrorCode.notFound, message);
}

void main() {
  group('WincheException', () {
    test('is an Exception, so it is caught by a bare `on Exception`', () {
      expect(_FakeServiceException('boom'), isA<Exception>());
    });

    test('toString is the runtime type and the message', () {
      // Subclasses get this for free, which is the point of holding `message`
      // on the base: a package adding an exception cannot forget to name
      // itself in its own error output.
      expect(_FakeServiceException('boom').toString(), '_FakeServiceException(not-found): boom');
    });

    test('can be extended from outside the library that declares it', () {
      // Pinned because the class modifier controls this. Making the base
      // `sealed`, `final` or `interface` would break every downstream package
      // at once, and nothing else in core's own tests would notice.
      expect(_FakeServiceException('boom'), isA<WincheException>());
    });

    test('catches every exception core itself throws', () {
      // The claim the doc comment makes. If a future exception in core forgets
      // to extend the root, it shows up here rather than in a consumer's app.
      //
      // WincheSessionConsumerError is deliberately absent: it is delivered as a
      // value on WincheApp.errors and never thrown, so it is not an exception
      // and belongs to no hierarchy. See session_consumer_test.dart.
      final all = <Object>[WincheUnboundException(), WincheSessionExpired(WincheIdentity('alice'))];
      for (final error in all) {
        expect(error, isA<WincheException>(), reason: '${error.runtimeType} escapes the root');
      }
    });
  });

  group('WincheUnboundException', () {
    test('is a WincheException', () {
      expect(WincheUnboundException(), isA<WincheException>());
    });

    test('is not a StateError, which would read as terminal', () {
      expect(WincheUnboundException(), isNot(isA<StateError>()));
    });

    test('explains how to recover', () {
      // A consumer hitting this has to be told the fix is signing in, not
      // handling the error where they handle server failures.
      expect(WincheUnboundException().toString(), contains('sign in'));
      expect(WincheUnboundException().toString(), startsWith('WincheUnboundException(unauthenticated):'));
      expect(WincheUnboundException().code, WincheErrorCode.unauthenticated);
    });
  });

  group('WincheSessionExpired', () {
    test('is a WincheException and keeps its identity reachable', () {
      final identity = WincheIdentity('alice');
      final error = WincheSessionExpired(identity);
      expect(error, isA<WincheException>());
      expect(error.identity, same(identity));
    });

    test('names the identity in its message, and is aborted', () {
      final error = WincheSessionExpired(WincheIdentity('alice'));
      expect(error.toString(), 'WincheSessionExpired(aborted): the session for alice is no longer active');
      expect(error.code, WincheErrorCode.aborted);
    });
  });

  group('WincheErrorCode', () {
    test('every code has its kebab-case wire name, and reads back', () {
      for (final code in WincheErrorCode.values) {
        expect(code.wireName, matches(RegExp(r'^[a-z]+(-[a-z]+)*$')));
        expect(WincheErrorCode.tryParse(code.wireName), code);
      }
      expect(WincheErrorCode.permissionDenied.wireName, 'permission-denied');
      expect(WincheErrorCode.tryParse('PERMISSION_DENIED'), isNull);
    });

    test('the transient ones are those a later, unchanged retry may fix', () {
      expect(WincheErrorCode.values.where((c) => c.isTransient).toSet(),
          {WincheErrorCode.unavailable, WincheErrorCode.deadlineExceeded, WincheErrorCode.aborted, WincheErrorCode.resourceExhausted});
      expect(_FakeServiceException('x').isTransient, isFalse);
    });

    test('an answer without a code gets one from its HTTP status', () {
      expect(
        [400, 401, 403, 404, 409, 412, 429, 500, 503, 504].map(WincheErrorCode.fromHttpStatus),
        [
          WincheErrorCode.invalidArgument, WincheErrorCode.unauthenticated, WincheErrorCode.permissionDenied, WincheErrorCode.notFound,
          WincheErrorCode.alreadyExists, WincheErrorCode.failedPrecondition, WincheErrorCode.resourceExhausted, WincheErrorCode.internal,
          WincheErrorCode.unavailable, WincheErrorCode.deadlineExceeded,
        ],
      );
    });
  });
}
