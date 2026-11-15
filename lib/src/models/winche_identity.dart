import 'dart:convert';

import 'package:crypto/crypto.dart';

/// The principal an app is signed in as.
///
/// One concrete class, no subclassing: backend-specific fields ride in
/// [claims], and consumers only ever need [id], because [id] is what scopes
/// their storage — through [storageKey], never raw.
///
/// [id] is taken as the backend issues it. Whatever shape that is — an email,
/// a UUID with colons, an LDAP distinguished name, mixed case — it is a valid
/// id, because nothing downstream depends on its shape: [storageKey] hashes it
/// before it ever reaches a filesystem.
///
/// Two things are still rejected, and only these two. An id that is empty or
/// only whitespace is never a real principal. An id containing a control
/// character is refused because [id] appears verbatim in [toString] and in
/// `WincheSessionExpired`'s message, where an embedded newline would let a
/// backend-supplied value forge a log entry. Validating here — at the auth
/// boundary where a bad value originated — is why this class is not `const`.
final class WincheIdentity {
  /// The backend-assigned, stable identifier for this principal.
  final String id;

  /// Backend-specific extras. Unmodifiable.
  ///
  /// Equality over [claims] is shallow: collection
  /// values are compared with `!=`, so two identities carrying
  /// structurally-identical collection claims (e.g. the same `roles` list
  /// built separately) will not compare equal. Callers needing a stable
  /// comparison should compare [id] instead.
  final Map<String, Object?> claims;

  /// Creates an identity.
  ///
  /// Throws an [ArgumentError] if [id] is empty or whitespace-only, or if it
  /// contains a control character.
  WincheIdentity(this.id, {Map<String, Object?> claims = const {}}) : claims = Map.unmodifiable(claims) {
    if (id.trim().isEmpty || _hasControlCharacter(id)) {
      throw ArgumentError.value(
        id,
        'id',
        'must not be empty or whitespace-only, and must not contain control '
            'characters',
      );
    }
  }

  /// A name safe to use as a directory or database-name component.
  ///
  /// A 128-bit SHA-256 digest of [id], rendered as 32 lowercase hex
  /// characters. Three properties make it the right thing to put on disk, and
  /// none of them hold for [id] itself:
  ///
  /// * **Case-insensitive filesystems cannot collapse it.** On NTFS and
  ///   default macOS APFS, `User1` and `user1` are one directory. Backends do
  ///   issue case-sensitive ids (mixed-case base62 is common), so a
  ///   service using [id] raw would let one user read another's cached state.
  ///   An all-lowercase key cannot be folded onto anything.
  /// * **Every id yields a usable name.** An email, a DN, a path separator —
  ///   all hash to the same 32-character alphabet, which is why [id] no longer
  ///   has to be constrained to a filesystem-safe shape.
  /// * **The length is fixed.** Path components stay short regardless of how
  ///   long an id a backend issues, which keeps composed paths clear of
  ///   Windows' `MAX_PATH`.
  ///
  /// SHA-256 rather than a hand-rolled hash because this value becomes a
  /// directory name: it must be identical across Dart releases, across
  /// platforms, and between native and web, or an SDK upgrade silently orphans
  /// every user's local state. A specified digest guarantees that;
  /// `String.hashCode` explicitly does not.
  ///
  /// Truncation to 128 bits is deliberate — collision resistance here only has
  /// to separate the handful of identities that share one device, which is
  /// astronomically below the birthday bound.
  ///
  /// One-way: a directory cannot be mapped back to the [id] that made it. To
  /// find a known user's directory, recompute this from their id.
  ///
  /// Use this, not [id], whenever the value becomes a filesystem path or an
  /// IndexedDB database name.
  late final String storageKey = sha256.convert(utf8.encode(id)).toString().substring(0, 32);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is WincheIdentity && other.id == id && _claimsEqual(other.claims, claims);
  }

  @override
  int get hashCode {
    return Object.hash(id, Object.hashAllUnordered(claims.entries.map((e) => Object.hash(e.key, e.value))));
  }

  @override
  String toString() => 'WincheIdentity($id)';

  /// Whether [value] contains a C0 control (U+0000–U+001F), DEL (U+007F), or a
  /// C1 control (U+0080–U+009F).
  ///
  /// Compares code points rather than matching a regex so the range bounds are
  /// written as numbers: a pattern would carry them as escape sequences, which
  /// are easy to mangle and impossible to read once mangled.
  static bool _hasControlCharacter(String value) {
    for (final rune in value.runes) {
      if (rune <= 0x1F || (rune >= 0x7F && rune <= 0x9F)) return true;
    }
    return false;
  }

  static bool _claimsEqual(Map<String, Object?> a, Map<String, Object?> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (!b.containsKey(entry.key) || b[entry.key] != entry.value) {
        return false;
      }
    }
    return true;
  }
}
