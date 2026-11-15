import 'package:test/test.dart';
import 'package:winche_core/winche_core.dart';

void main() {
  group('WincheSession', () {
    test('is active on construction and delegates token reads', () async {
      var calls = 0;
      final session = WincheSession(WincheIdentity('u1'), ({bool forceRefresh = false}) async {
        calls++;
        return forceRefresh ? 'fresh' : 'cached';
      });

      expect(session.isActive, isTrue);
      expect(await session.token(), 'cached');
      expect(await session.token(forceRefresh: true), 'fresh');
      expect(calls, 2);
    });

    test('token throws once invalidated', () async {
      final session = WincheSession(WincheIdentity('u1'), ({bool forceRefresh = false}) async => 'tok');

      session.invalidate();

      expect(session.isActive, isFalse);
      expect(() => session.token(), throwsA(isA<WincheSessionExpired>()));
    });

    test('invalidate is idempotent', () {
      final session = WincheSession(WincheIdentity('u1'), ({bool forceRefresh = false}) async => null);
      session.invalidate();
      session.invalidate();
      expect(session.isActive, isFalse);
    });

    test('the exception names the identity', () {
      final error = WincheSessionExpired(WincheIdentity('u1'));
      expect(error.toString(), contains('u1'));
    });

    test('token throws when the session is invalidated mid-fetch', () async {
      late final WincheSession session;
      session = WincheSession(WincheIdentity('a'), ({bool forceRefresh = false}) async {
        // The user switch lands while this fetch is in flight. Core's
        // fetcher resolves whoever is signed in *now*, so without the
        // post-fetch check this would hand user A's caller user B's token.
        session.invalidate();
        return 'user-b-token';
      });

      await expectLater(session.token(), throwsA(isA<WincheSessionExpired>()));
    });

    test('a mid-fetch invalidation never leaks the fetched value', () async {
      late final WincheSession session;
      session = WincheSession(WincheIdentity('a'), ({bool forceRefresh = false}) async {
        session.invalidate();
        return 'user-b-token';
      });

      String? leaked;
      try {
        leaked = await session.token();
      } on WincheSessionExpired {
        leaked = null;
      }
      expect(leaked, isNull);
    });
  });
}
