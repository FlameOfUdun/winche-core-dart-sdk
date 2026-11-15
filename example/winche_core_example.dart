// A runnable end-to-end tour of winche_core: an auth service that produces
// identity, a consuming service that reacts to it, and core sequencing between
// them.
//
//   dart run example/winche_core_example.dart
//
// Both services here are toys. A real one would open a WebSocket and a local
// store instead of printing, but the shape is exactly the same.

import 'package:winche_core/winche_core.dart';

/// The identity producer.
///
/// Core defines no sign-in surface — no `signIn`, no credentials type — so this
/// exposes whatever shape its backend needs and announces the result. A real
/// implementation would be doing OIDC or a password exchange here.
final class ExampleAuthService extends WincheAuthService {
  ExampleAuthService(super.app);

  static ExampleAuthService get instance => WincheService.instanceFor(Winche.app, () => ExampleAuthService(Winche.app));

  WincheIdentity? _identity;
  var _refreshCount = 0;

  @override
  WincheIdentity? get activeIdentity => _identity;

  @override
  Future<String?> getAuthToken({bool forceRefresh = false}) async {
    if (_identity == null) return null;
    // Rule: throw when a token cannot currently be obtained. Returning null
    // means "signed out", and reporting a network blip that way would unbind
    // every service on the device.
    return 'token-${_identity!.id}-$_refreshCount';
  }

  Future<void> signIn(String userId) async {
    _identity = WincheIdentity(userId, claims: {'plan': 'pro'});
    _refreshCount = 0;
    notifyIdentityChanged(_identity); // core builds the session
  }

  Future<void> refreshToken() async {
    _refreshCount++;
    notifyTokenRotated(); // same session, fresh token — a nudge, not a swap
  }

  Future<void> signOut() async {
    _identity = null;
    notifyIdentityChanged(null); // authoritative sign-out only
  }
}

/// A consuming service. Core hands it a session; it builds and tears down its
/// own state around that.
final class ExampleDatabase extends WincheDatabaseService {
  ExampleDatabase(super.app);

  static ExampleDatabase get instance => WincheService.instanceFor(Winche.app, () => ExampleDatabase(Winche.app));

  _Store? _store;

  @override
  Future<void> onSessionChanged(WincheSession? session) async {
    await _store?.close();
    _store = null;
    if (session == null) {
      print('  [db] no identity — nothing open');
      return;
    }

    final root = await app.options?.directoryResolver?.call();
    // storageKey, not id: `User1` and `user1` are one directory on NTFS and
    // default macOS APFS, so a case-sensitive backend id used raw would let one
    // user read another's cached state.
    final directory = root == null ? null : '$root/${session.identity.storageKey}';

    _store = _Store(directory, session);
    print('  [db] opened store at $directory');
    print('  [db] first token: ${await session.token()}');
  }

  @override
  Future<void> onTokenChanged() async {
    // Nudge. Tearing the store down and reopening it on every token refresh is
    // exactly what this hook exists to avoid.
    print('  [db] token rotated — reconnecting in place, store untouched');
    await _store?.reconnect();
  }

  @override
  Future<void> dispose() async {
    await _store?.close();
    await super.dispose(); // always last
  }
}

class _Store {
  _Store(this.directory, this.session);
  final String? directory;
  final WincheSession session;

  Future<void> reconnect() async {
    // Read the token at dial time, never a snapshot captured earlier: it may
    // have rotated, and the session may have been superseded.
    print('  [db] redialled with ${await session.token()}');
  }

  Future<void> close() async => print('  [db] store closed');
}

Future<void> main() async {
  Winche.initializeApp(
    options: WincheOptions(
      databaseEndpoint: Uri.parse('wss://api.example.dev/documents/ws'),
      storageEndpoint: Uri.parse('https://api.example.dev/files'),
      // A Flutter app would use getApplicationSupportDirectory() here.
      directoryResolver: () async => '/tmp/winche-example',
    ),
  );

  Winche.app.errors.listen((e) => print('  [!] ${e.consumer.runtimeType}: ${e.error}'));

  // Registration order is irrelevant: the database is created before auth, so
  // it simply stays unbound until an identity exists.
  ExampleDatabase.instance;
  final auth = ExampleAuthService.instance;
  await Winche.app.settled;

  print('\nsign in as alice');
  await auth.signIn('alice');
  await Winche.app.settled;

  print('\nrotate the token');
  await auth.refreshToken();
  await Winche.app.settled;

  print('\nswitch to Bob (note the capital B — see storageKey)');
  final aliceSession = Winche.app.session;
  await auth.signIn('Bob');
  await Winche.app.settled;

  // Alice's session is now dead. Work that outlived the switch fails loudly
  // rather than silently reading Bob's token.
  try {
    await aliceSession!.token();
  } on WincheSessionExpired catch (e) {
    print('  [!] $e');
  }

  print('\nsign out');
  await auth.signOut();
  await Winche.app.settled;

  print('\nteardown');
  await Winche.deinitializeApp();
  print('done');
}
