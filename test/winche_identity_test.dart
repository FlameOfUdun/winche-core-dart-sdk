import 'package:test/test.dart';
import 'package:winche_core/winche_core.dart';

void main() {
  group('WincheIdentity', () {
    test('accepts ids made of letters, digits, dot, underscore and dash', () {
      expect(WincheIdentity('user-1').id, 'user-1');
      expect(WincheIdentity('a.b_c-9').id, 'a.b_c-9');
    });

    test('accepts whatever shape a backend issues, since storageKey hashes it '
        'before it reaches a filesystem', () {
      // Every one of these was rejected before storageKey became a digest,
      // which meant a backend issuing them could not sign in at all.
      for (final id in [
        'user@example.com',
        'cn=alice,ou=people,dc=example,dc=com',
        'auth0|5f3c2b1a',
        'a/b',
        r'a\b',
        'first last',
        'abc.',
        '.',
        '..',
        'ユーザー1',
        'a' * 4096,
      ]) {
        expect(WincheIdentity(id).id, id, reason: 'id "$id" should be accepted');
      }
    });

    test('rejects an id that is empty or only whitespace', () {
      expect(() => WincheIdentity(''), throwsArgumentError);
      expect(() => WincheIdentity(' '), throwsArgumentError);
      expect(() => WincheIdentity('\t  '), throwsArgumentError);
    });

    test('rejects control characters, which would forge a line in any log '
        'that prints an identity', () {
      // `id` is interpolated verbatim into toString() and into
      // WincheSessionExpired's message.
      expect(() => WincheIdentity('a\nb'), throwsArgumentError);
      expect(() => WincheIdentity('ab\n'), throwsArgumentError);
      expect(() => WincheIdentity('\nab'), throwsArgumentError);
      expect(() => WincheIdentity('a\rb'), throwsArgumentError);
      expect(() => WincheIdentity('a\tb'), throwsArgumentError);
      // Built from code points rather than written as literals: the exact
      // bytes are the point of the test, and an editor or a patch that
      // normalises them would silently weaken it.
      for (final code in [0x00, 0x1F, 0x7F, 0x80, 0x9F]) {
        final id = 'a${String.fromCharCode(code)}b';
        expect(
          () => WincheIdentity(id),
          throwsArgumentError,
          reason:
              'U+${code.toRadixString(16).toUpperCase().padLeft(4, '0')} '
              'should be rejected',
        );
      }
    });

    test('accepts the printable characters bordering the control ranges', () {
      // Pins the bounds from the outside: an off-by-one in either direction
      // would start rejecting a space, a tilde, or a non-breaking space.
      for (final code in [0x20, 0x7E, 0xA0]) {
        final id = 'a${String.fromCharCode(code)}b';
        expect(
          WincheIdentity(id).id,
          id,
          reason:
              'U+${code.toRadixString(16).toUpperCase().padLeft(4, '0')} '
              'should be accepted',
        );
      }
    });

    test('throws an ArgumentError naming "id" and carrying the bad value', () {
      try {
        WincheIdentity('bad\nid');
        fail('expected an ArgumentError');
      } on ArgumentError catch (e) {
        expect(e.name, 'id');
        expect(e.invalidValue, 'bad\nid');
      }
    });

    test('compares by id and claims', () {
      expect(WincheIdentity('u1'), WincheIdentity('u1'));
      expect(WincheIdentity('u1'), isNot(WincheIdentity('u2')));
      expect(WincheIdentity('u1', claims: {'role': 'admin'}), WincheIdentity('u1', claims: {'role': 'admin'}));
      expect(WincheIdentity('u1', claims: {'role': 'admin'}), isNot(WincheIdentity('u1', claims: {'role': 'user'})));
      expect(WincheIdentity('u1').hashCode, WincheIdentity('u1').hashCode);
    });

    test('hashCode matches for equal non-empty claims regardless of '
        'insertion order', () {
      final a = WincheIdentity('u1', claims: {'role': 'admin', 'aud': 'app', 'sub': 'u1'});
      final b = WincheIdentity('u1', claims: {'sub': 'u1', 'role': 'admin', 'aud': 'app'});
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    group('storageKey', () {
      test('is 32 lowercase hex characters, whatever the id', () {
        final hex = RegExp(r'^[0-9a-f]{32}$');
        for (final id in ['user-1', 'User1', 'user@example.com', 'cn=alice,ou=people', 'a/b', 'ユーザー1', 'a' * 4096]) {
          expect(WincheIdentity(id).storageKey, matches(hex), reason: 'id "$id"');
        }
      });

      test('keeps ids apart that differ only in case', () {
        // Raw, these collide as directory names on NTFS and default macOS
        // APFS, which is the leak this getter exists to prevent.
        final keys = {
          WincheIdentity('User1').storageKey,
          WincheIdentity('user1').storageKey,
          WincheIdentity('USER1').storageKey,
          WincheIdentity('uSeR1').storageKey,
        };
        expect(keys, hasLength(4));
      });

      test('cannot be collapsed by a case-insensitive filesystem', () {
        // The property the previous test depends on: distinct keys stay
        // distinct after the filesystem folds their case. base64 would fail
        // exactly here -- its alphabet is mixed-case, so distinct encodings
        // can fold together.
        final folded = {
          for (final id in ['User1', 'user1', 'USER1', 'uSeR1']) WincheIdentity(id).storageKey.toLowerCase(),
        };
        expect(folded, hasLength(4));
      });

      test('is stable across calls and instances', () {
        expect(WincheIdentity('User1').storageKey, WincheIdentity('User1').storageKey);
      });

      test('is the documented digest, pinned against an accidental change', () {
        // A changed algorithm silently orphans every user's on-disk state, so
        // the value is pinned rather than merely described. Independently
        // reproducible: the first 32 hex chars of SHA-256("alice").
        expect(WincheIdentity('alice').storageKey, '2bd806c97f0e00af1a1fc3328fa763a9');
      });

      test('stays a short path component however long the id', () {
        expect(WincheIdentity('A' * 4096).storageKey.length, 32);
      });
    });

    test('claims are unmodifiable', () {
      final identity = WincheIdentity('u1', claims: {'role': 'admin'});
      expect(() => identity.claims['role'] = 'user', throwsUnsupportedError);
    });

    test('claims are defensively copied from the source map at construction', () {
      final source = {'role': 'admin'};
      final identity = WincheIdentity('u1', claims: source);
      source['role'] = 'user';
      source['extra'] = 'value';
      expect(identity.claims, {'role': 'admin'});
    });
  });
}
