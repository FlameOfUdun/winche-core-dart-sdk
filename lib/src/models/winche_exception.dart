/// What kind of failure a [WincheException] is: one list for every Winche
/// package and every Winche API.
///
/// Switch on it instead of on exception types:
///
/// ```dart
/// try {
///   …
/// } on WincheException catch (e) {
///   switch (e.code) {
///     case WincheErrorCode.notFound: …
///     case WincheErrorCode.permissionDenied: …
///     default: if (e.isTransient) retryLater();
///   }
/// }
/// ```
enum WincheErrorCode {
  /// The operation was cancelled, usually by the caller.
  cancelled('cancelled'),

  /// Nothing more is known.
  unknown('unknown'),

  /// The request itself is wrong: a bad value, a malformed query, a weak password.
  invalidArgument('invalid-argument'),

  /// No answer in time.
  deadlineExceeded('deadline-exceeded'),

  /// What was asked for isn't there.
  notFound('not-found'),

  /// What was to be created already exists.
  alreadyExists('already-exists'),

  /// The caller may not do this.
  permissionDenied('permission-denied'),

  /// A limit was reached: too many attempts, too many subscriptions, out of quota.
  resourceExhausted('resource-exhausted'),

  /// The system isn't in the state this needs (e.g. a sign-in method that is off).
  failedPrecondition('failed-precondition'),

  /// A conflict, such as a transaction that lost to another; trying again may work.
  aborted('aborted'),

  /// A value is outside its valid range.
  outOfRange('out-of-range'),

  /// The server doesn't do this.
  unimplemented('unimplemented'),

  /// The server failed; a bug on its side.
  internal('internal'),

  /// The server can't be reached right now; trying again later may work.
  unavailable('unavailable'),

  /// Data was lost or corrupted.
  dataLoss('data-loss'),

  /// Nobody is signed in, or the sign-in isn't valid.
  unauthenticated('unauthenticated');

  const WincheErrorCode(this.wireName);

  /// The name on the wire: `not-found`, `permission-denied`, …
  final String wireName;

  /// Whether trying again later, unchanged, may work.
  bool get isTransient => this == unavailable || this == deadlineExceeded || this == aborted || this == resourceExhausted;

  /// The code named [name] (`not-found`), or null when it isn't one.
  static WincheErrorCode? tryParse(String? name) {
    for (final code in values) {
      if (code.wireName == name) return code;
    }
    return null;
  }

  /// The code for an HTTP [status], for answers that carry no code.
  static WincheErrorCode fromHttpStatus(int status) => switch (status) {
    400 || 413 => invalidArgument,
    401 => unauthenticated,
    403 => permissionDenied,
    404 => notFound,
    409 => alreadyExists,
    412 => failedPrecondition,
    429 => resourceExhausted,
    499 => cancelled,
    501 => unimplemented,
    502 || 503 => unavailable,
    504 => deadlineExceeded,
    >= 500 => internal,
    _ => unknown,
  };
}

/// The root of every exception the Winche stack throws: a [code] from the one
/// shared list, and a [message] for people.
///
/// Each package has one subclass (`WincheAuthException`,
/// `WincheDatabaseException`, `WincheStorageException`,
/// `WincheFunctionsException`), with fields of its own only where its errors
/// carry more. So `on WincheException` catches anything from any Winche SDK,
/// `on WincheStorageException` asks "did storage fail?", and [code] says how.
abstract class WincheException implements Exception {
  /// Creates an exception of kind [code].
  const WincheException(this.code, this.message);

  /// What kind of failure this is.
  final WincheErrorCode code;

  /// What went wrong, for people.
  final String message;

  /// Whether trying again later, unchanged, may work.
  bool get isTransient => code.isTransient;

  @override
  String toString() => '$runtimeType(${code.wireName}): $message';
}

/// Thrown when a service is used while no identity is bound to its app.
///
/// Every Winche service is bound to a session and unbound by a sign-out, so
/// "there is nobody to do this as" is a condition all of them share. It lives
/// in core so it has one name across the stack. Its [code] is
/// [WincheErrorCode.unauthenticated]: signing in is what fixes it, so gate on
/// sign-in state rather than retrying.
///
/// Services report it two ways, matching how the call is shaped. A
/// future-returning operation rejects with it. A stream-returning one emits it
/// as a stream error and then closes, rather than throwing at the call site —
/// that call site is typically inside a `build()` method, where a synchronous
/// throw tears down the widget tree instead of reaching an error branch.
final class WincheUnboundException extends WincheException {
  /// Creates the exception.
  WincheUnboundException()
    : super(WincheErrorCode.unauthenticated, 'no identity is bound to this app. Wait for sign in before using this service.');
}
