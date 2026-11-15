# winche_core

Core primitives for the Winche Dart stack — the piece every other `winche_*`
package depends on, and the only one that knows nothing about them.

It provides four things:

- **An app registry.** `Winche.initializeApp()` creates a named `WincheApp`
  holding your backend configuration. Services attach themselves to it by
  constructor, and it dispatches sessions to them as sign-in state changes.
- **A session model.** One service announces who is signed in; core turns
  that into a `WincheSession` and hands it to every other service, in order,
  waiting for each to finish before the next session can begin.
- **Service roles.** Any package's service extends `WincheService` and picks
  its role: `with WincheIdentitySource` if it produces the identity (an app
  has one), `implements WincheSessionConsumer` if it follows the session. Core
  lists no service kinds, so a new package needs no core change.
- **One client for the server.** `app.http` adds the signed-in user's token,
  refreshes it once on a 401, retries what is safe to retry, and turns
  failures into `WincheHttpException`.

What it deliberately is **not**: a service locator. `WincheApp` does not hand
out services by type — a package that needs its own service reaches it
through whatever `instance` / `instanceFor` accessor that package's own class
exposes, not through the app. Core also defines no sign-in surface — no
`signIn`, no `signOut`, no credentials type — because how a backend
authenticates is that backend's business, not core's.

Pure Dart, no Flutter dependency — the same code runs in a Flutter app, a
server, or a CLI.

## Installation

```yaml
dependencies:
  winche_core: ^1.0.0
```

## Getting started

```dart
import 'package:winche_core/winche_core.dart';

void main() {
  Winche.initializeApp(
    options: WincheOptions(
      baseUrl: Uri.parse('https://api.example.com'),
      directoryResolver: () async => (await getApplicationSupportDirectory()).path,
    ),
  );

  // Registering a service attaches it to the app passed to its constructor.
  final auth = MyAuthService(Winche.app);
  MyDatabaseService(Winche.app);

  // However MyAuthService exposes signing in, it ends by calling
  // notifyIdentityChanged — core takes it from there.
  auth.signInWithPassword(email: '…', password: '…');
}
```

`initializeApp` is synchronous: it constructs the app, registers it, and
returns — there is nothing to await. Most programs need exactly one app, and
`Winche.app` returns it from anywhere:

```dart
Winche.initializeApp();   // registered as 'default'
Winche.app;                // the same instance, from anywhere
```

Talk to two backends at once by naming them:

```dart
final prod = Winche.initializeApp(name: 'prod', options: prodOptions);
final staging = Winche.initializeApp(name: 'staging', options: stagingOptions);
```

`initializeApp` is also idempotent — calling it again with the same name
returns the existing app. Passing *different* options for an existing name
throws a `StateError` rather than silently ignoring them; omitting `options`
on a repeat call always returns the existing app unchanged.

Look an app up by name with `Winche.appFor(name)` (throws if absent) or
`Winche.maybeAppFor(name)` (null if absent). `Winche.apps` lists every
currently initialized app.

Tear an app down with `Winche.deinitializeApp([name])`, which disposes every
service attached to it and removes it from the registry. `Winche.deinitializeAll()`
does the same for all of them — useful in a test `tearDown`.

## Options

`WincheOptions` carries the configuration more than one service needs, and
nothing a single service could own for itself:

| Field | |
|---|---|
| `baseUrl` | the Winche server, e.g. `https://api.example.com`; each service is its own path under it |
| `endpoints` | per-service overrides by id, e.g. `{'storage': Uri.parse('https://files.example.com/files/v1')}` |
| `directoryResolver` | resolves the parent directory every service creates its on-disk state under |
| `projectId` | which project, as `winche configure` names it (informational) |
| `appId` | this app's id in the project, written by `winche configure --app`; sent with every request (header `X-Winche-App`, or the `winche_app` query parameter on WebSockets). Not a secret |
| `clientIds` | public client ids by sign-in provider for this platform, e.g. `{'google': '….apps.googleusercontent.com'}` |

A service asks for its endpoint by id and path, so a new package needs no
field here:

```dart
final endpoint = app.options!.endpointFor('functions', path: '/functions/v1');
// database: endpointFor('database', path: '/documents/v1/ws', webSocket: true) → wss://…
```

| Service | Path |
|---|---|
| `database` | `/documents/v1/ws` (WebSocket) |
| `storage` | `/files/v1` |
| `auth` | `/auth/v1` |
| `functions` | `/functions/v1` |

`endpointFor` throws a `StateError` saying what to set when neither `baseUrl`
nor an override is configured; `maybeEndpointFor` returns null instead.
`options.copyWith(…)` replaces single fields and keeps the rest. `WincheOptions.emulator()` is just a `baseUrl`
of `http://localhost:9090` (pass `host: '10.0.2.2'` from an Android emulator).

### Setup, and the emulator

`winche configure` (in the Winche CLI) asks the server for its public settings
and writes `lib/winche_options.dart`, with a `DefaultWincheOptions` for every
platform; `winche_flutter` picks the current one:

```dart
final app = await WincheFlutter.initializeApp(options: DefaultWincheOptions.currentPlatform);
if (kDebugMode) app.useEmulator();   // winche emulators start
```

`app.useEmulator({host, port, only})` sends that app's services (or only those
named, e.g. `{'database'}`) to the local emulator, overrides included. It is per
app, so a second app keeps its own server. On Android, `localhost` becomes
`10.0.2.2`. Call it straight after creating the app: it throws once a service
is attached or a request has been sent.

The 0.x fields `databaseEndpoint`, `storageEndpoint`, `authEndpoint` and
`functionsEndpoint` still work as overrides, deprecated, until 2.0.

Core hands out the directory root and nothing more. How a service composes a
path beneath it — a subdirectory per identity, a filename for its cache — is
that service's own business, not core's; the same goes for what it names an
IndexedDB database on the web, where `directoryResolver` typically has
nothing to resolve. This is deliberate: it means adding a knob to
`winche_database` never forces a `winche_core` release, because the knob
lives on that service, configured however that package chooses.

`WincheOptions` compares its addresses by value, but `directoryResolver` by
identity (Dart compares closures that way) — which is what `initializeApp`
checks when refusing a repeat call with disagreeing options. Hoist the
options into a variable if they need to be passed more than once.

## Errors

Every exception a Winche package throws is a `WincheException` with a `code`
from one shared list, `WincheErrorCode`, the same codes every Winche API sends
(`not-found`, `permission-denied`, `unauthenticated`, …), and a `message`:

```dart
try {
  await doc.get();
} on WincheException catch (e) {
  switch (e.code) {
    case WincheErrorCode.notFound: …
    case WincheErrorCode.permissionDenied: …
    default:
      if (e.isTransient) retryLater();   // unavailable, deadlineExceeded, aborted, resourceExhausted
  }
}
```

Each package has one exception type of its own (`WincheAuthException`,
`WincheDatabaseException`, `WincheStorageException`,
`WincheFunctionsException`), with extra fields only where its errors carry
more, such as an auth error's `reason` (`INVALID_CREDENTIALS`).

## Sessions

A session (`WincheSession`) is who is signed in, together with the means to
fetch a token for as long as that stays true. Core constructs and invalidates
sessions itself; nothing outside core ever calls `WincheSession`'s
constructor.

`isActive` exists because a session can outlive its usefulness without a
consuming service knowing it yet: a user switch, or a sign-out, invalidates
the *old* session object before the new one exists, but a consumer holding a
reference to the old one — mid-request, say — has no other way to notice.
Calling `session.token()` on an inactive session throws `WincheSessionExpired`
(code `aborted`). Core's other exceptions are `WincheUnboundException`
(code `unauthenticated`: no one is signed in) and `WincheHttpException`; all
extend `WincheException`:

```dart
try {
  final token = await session.token();
  // use token
} on WincheSessionExpired {
  // this operation outlived its session; abandon it
}
```

Two things about `token()` are worth knowing before you call it:

- The first check is **synchronous** — if the session is already inactive,
  the exception is thrown before a `Future` even exists, so
  `session.token().catchError(...)` will never see it. Always wrap the
  `await` in `try`/`catch`.
- It checks again after the fetch resolves, because the fetcher underneath
  reads whoever is signed in *at the moment it runs* — not at the moment
  `token()` was called. Without the second check, a call that straddled a
  user switch could return the next user's token under the previous user's
  name. That is the exact cross-identity contamination `WincheSessionExpired`
  exists to prevent, so treat it as a normal, expected outcome — not a bug —
  and let the operation abandon its work when it happens.

## Calling the server

Every package sends its requests through `app.http`, so they all behave the
same way:

```dart
final endpoint = app.options!.endpointFor('functions', path: '/functions/v1');
final response = await app.http.send(WincheRequest.post(
  Uri.parse('$endpoint/call/hello'),
  json: {'data': {'name': 'Ann'}},
  service: 'functions',
));
final data = (response.json as Map)['data'];
```

- **Token.** `Authorization: Bearer …` from the current session. Pass
  `auth: WincheRequestAuth.none` for sign-in calls and signed links, or
  `.required` to fail with `WincheUnboundException` when no one is signed in.
- **Refresh once.** On a 401 it refreshes the token and tries once more.
  Requests refused at the same time share one refresh.
- **Retries.** Requests that are safe to repeat (GET, HEAD, PUT, DELETE, or
  `idempotent: true`) get up to three tries on network errors and 502/503/504,
  with growing gaps and jitter. Others, such as a POST, are never retried.
- **Timeouts.** 30 s a try unless the request or `app.http.timeout` says
  otherwise.
- **Errors.** Anything but a 2xx throws `WincheHttpException` with the
  server's `code`, `message`, `status`, and its whole error object in
  `details`. It understands `{error: {code, message}}`, `{error: "…"}` and
  problem details.
- **Uploads and downloads.** `WincheRequest.streamed(…, body: () => file.openRead(),
  length: …, onSendProgress: …)` streams a body (reopened on each try);
  `app.http.stream(request)` hands back the response body as it arrives.
- **A named session.** A service bound to a session passes `session:`, so a
  request that straddles a user switch fails with `WincheSessionExpired`
  instead of carrying the next user's token.
- **Abandoning a request.** `abortTrigger:` (a future) abandons it, even
  mid-body; it fails with code `cancelled`. For pausing and cancelling transfers.
- **Without an app.** `WincheHttp.standalone()` for requests that carry no
  token or name their session, such as transfers to signed links.
- **Interceptors.** `app.http.addInterceptor(…)` sees every request and
  response, for logging, tracing or an extra header.
- **Tests.** `app.http.useClient(MockClient(…))` replaces the network.

## Writing an auth service

Extend `WincheService with WincheIdentitySource` and expose whatever sign-in shape your backend
needs — password, OIDC redirect, refresh token, device code, anything. There
is no `signIn` or `signOut` on the base class to override; add your own
methods with whatever names and parameters make sense, and call
`notifyIdentityChanged` / `notifyTokenRotated` — both `@protected`, so only
subclasses can call them — to tell core what happened.

```dart
final class MyAuthService extends WincheService with WincheIdentitySource {
  MyAuthService(super.app);

  WincheIdentity? _identity;
  String? _token;

  @override
  WincheIdentity? get activeIdentity => _identity;

  @override
  Future<String?> getAuthToken({bool forceRefresh = false}) async {
    if (_identity == null) return null;
    if (forceRefresh) _token = await _refresh();
    return _token;
  }

  Future<void> signInWithPassword({required String email, required String password}) async {
    final result = await _backend.signIn(email, password);
    _identity = WincheIdentity(result.userId, claims: result.claims);
    _token = result.token;
    notifyIdentityChanged(_identity);
  }

  Future<void> signOut() async {
    await _backend.signOut();
    _identity = null;
    _token = null;
    notifyIdentityChanged(null);
  }

  Future<String> _refresh() async => (await _backend.refresh()).token;

  @override
  Future<void> dispose() async {
    // release backend resources here
    await super.dispose(); // always last
  }
}
```

Two rules bind an implementation, neither one the type system can enforce:

1. `notifyIdentityChanged(null)` means an **authoritative** sign-out —
   explicit logout, an invalid refresh token, an expired session. A
   transient refresh failure must not announce anything, or a flaky
   connection would tear down every session on the device.
2. `getAuthToken` returns null when signed out and **throws** when a token
   cannot currently be obtained. It must never report a transient failure as
   a sign-out either.

Call `notifyIdentityChanged` only after `activeIdentity` already reflects the
new value — core reads it synchronously as part of handling the
notification.

## Writing a consuming service

Extend `WincheService`, add `implements WincheSessionConsumer`, and implement
both of its members. Neither has a default: `onTokenChanged` in
particular, because a no-op inherited silently is a service that never reacts
to a token rotation, and that fails only once a token expires in the field. An
empty body is a fine answer — it just has to be one you gave.

```dart
final class MyDatabaseService extends WincheService implements WincheSessionConsumer {
  MyDatabaseService(super.app);

  MyStore? _store;

  @override
  Future<void> onSessionChanged(WincheSession? session) async {
    await _store?.close();
    _store = null;

    if (session == null) return; // signed out; stay closed

    final root = await app.options?.directoryResolver?.call();
    final directory = root == null ? null : '$root/${session.identity.storageKey}';

    _store = await MyStore.open(
      directory: directory,
      tokenProvider: session.token, // read at request time, not captured now
    );
  }

  @override
  Future<void> onTokenChanged() async {
    // the identity did not change, only the token did — nudge, don't rebuild
    await _store?.notifyTokenRotated();
  }

  @override
  Future<void> dispose() async {
    await _store?.close();
    await super.dispose(); // always last
  }
}
```

A few things about this shape are load-bearing:

- **Pass `session.token`, not a token value.** A snapshot taken inside
  `onSessionChanged` would go stale the moment the token rotates; `token()`
  re-fetches (and re-checks the session is still active) every time it is
  called.
- **Compose the storage path from the resolved root plus `identity.storageKey`
  — not `identity.id`.** Core hands out the root only; deciding the
  subdirectory, and what to name an IndexedDB database on the web where there
  is no filesystem, is this service's job. But use `storageKey` for the name:
  `id` validation cannot rule out *case* collisions, and on NTFS and default
  macOS APFS `User1` and `user1` are two identities that resolve to one
  directory. Backends really do issue case-sensitive ids (mixed-case
  base62 is common), so using `id` raw would let one user read another's
  cached state. `storageKey` is the first 128 bits of a SHA-256 digest of
  `id`, as 32 lowercase hex characters: always a safe name, whatever the id.
- **`onTokenChanged` carries no payload** on purpose. It fires when the
  identity stayed the same but the token rotated; a snapshot passed here
  would just be one this service should ignore in favor of calling
  `session.token()` itself, so the hook does not tempt anyone into keeping
  one.
- **Get your per-app singleton from `WincheService.instanceFor`**, not from a
  static map of your own:

  ```dart
  static MyDatabase get instance => instanceFor(Winche.app);

  static MyDatabase instanceFor(WincheApp app) =>
      WincheService.instanceFor(app, () => MyDatabase._(app));
  ```

  It returns the instance already attached to that app, or builds one. A
  hand-rolled cache keyed by `WincheApp` has to remember to evict itself in
  `dispose()`, and silently gets it wrong when it forgets — deinitializing an
  app and initializing a new one under the same name then hands back the
  previous, disposed service. Core's registry is per-app and cleared on
  teardown, so routing through it makes that bug unrepresentable rather than
  merely documented.

## Registration order

Registration order does not matter. A consumer created before the app's auth
service is simply not bound to anything yet; the moment the auth service
registers and announces its `activeIdentity`, core catches every
already-registered consumer up to it. Symmetrically, a consumer registered
*after* sign-in already happened is dispatched to the current session as
soon as it registers — nobody has to remember to call anything to "catch it
up" by hand.

## Failure handling

Core awaits each consumer's `onSessionChanged` before moving on, so an
outgoing session is always fully torn down before the incoming one is built:
two session swaps can never interleave inside one consumer, and consumers
never see the intermediate identity of a swap that happened while an earlier
one was still finishing.

Rapid changes reconcile to the latest value rather than queueing every one.
An `A -> B -> C` sequence dispatched faster than consumers can keep up ends
at `C`; `B` is simply never dispatched to anyone. `A -> null -> A` collapses
the same way, to "still `A`" — from a consumer's point of view nothing
happened, because nothing needs to.

If a consumer's hook throws, core reports it on `app.errors` (a broadcast
`Stream<WincheSessionConsumerError>`, open until the app is disposed) and
leaves that one service unbound — it is retried automatically on the next session
change — while every other registered service still receives its dispatch
normally. Core does not track a service's health or latch the failure; a
service that fails once and then succeeds on the next change is
indistinguishable from one that never failed.

```dart
Winche.app.errors.listen((error) {
  log.warning('${error.consumer.runtimeType} failed: ${error.error}', error.stackTrace);
});
```

Each hook (`onSessionChanged`, `onTokenChanged`, `dispose`) may run for
`hookTimeout` (30 s by default, set on `initializeApp`); one that runs longer
is abandoned and treated as failed. `await app.settled` completes once no
dispatch is in flight, so after a sign-in it tells you every service has
finished reacting.

## Lifecycle

`dispose()` is async everywhere, idempotent, and any override must call
`super.dispose()` last. Disposing a service deregisters it from its app;
disposing an app disposes every service it holds and removes itself from the
registry, so a disposed app is never reachable through `Winche.appFor`.

Consumers are disposed before the auth service — deterministically,
regardless of registration order — so a consumer can still read a token
while shutting down. Every service is disposed even if an earlier one
throws; the first error is rethrown once teardown finishes, so one broken
service's teardown does not leave the rest of the app's resources leaked.

## Testing a service

`package:winche_core/testing.dart` has conformance suites for a service you
write, `WincheServiceContract` and `WincheAuthContract`, and a
`ScriptedAuthService` to drive sign-in in tests. A suite returns a
`WincheContractReport` instead of calling `expect`, so it works with any test
framework:

```dart
import 'package:test/test.dart';
import 'package:winche_core/testing.dart';

test('honours the service contract', () async {
  final report = await WincheServiceContract.check(create: MyDatabase.new);
  expect(report.isSuccess, isTrue, reason: report.toString());
});
```

## Additional information

Issues and contributions are welcome on the project tracker.

## License

Released under the [MIT License](LICENSE).
