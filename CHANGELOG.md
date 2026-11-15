# CHANGELOG

## 1.0.0

Any package can add a service, an app is configured with one address, and
every package calls the server the same way. Everything 0.2.1 added (never
published) is included.

### Breaking

* **`WincheService` is no longer sealed.** A service extends it and picks its
  role: **`with WincheIdentitySource`** (produces the identity; one per app, a
  second throws) or **`implements WincheSessionConsumer`** (follows the
  session). Services with neither role are held and disposed with the app.
  `WincheAuthService`, `WincheDatabaseService`, `WincheStorageService` and
  `WincheFunctionsService` remain, deprecated, until 2.0.
* **`http` is a new dependency.**
* **One error shape.** `WincheException(code, message)`: every Winche
  exception has a `code` from **`WincheErrorCode`** (the shared list every
  Winche API sends, kebab-case on the wire: `not-found`,
  `permission-denied`, …) and `isTransient`. `WincheUnboundException` is
  `unauthenticated`, `WincheSessionExpired` `aborted`. `WincheHttpException`
  reads `{error: {code, message, reason?, details?}}` and keeps `reason`,
  `status`, `details`; no answer is `unavailable`, too late
  `deadlineExceeded`, an abort `cancelled`.

### New

* **`WincheOptions(baseUrl:, endpoints:)`** and **`endpointFor(id, path:,
  webSocket:)`**: one server address, each service its own path under it,
  with per-service overrides. `emulator()` is now a `baseUrl`. The four
  `…Endpoint` fields remain, deprecated, as overrides until 2.0.
* **`app.http`** (`WincheHttp`): the token, one shared refresh on a 401,
  up to three tries for requests that are safe to repeat, timeouts,
  **`WincheHttpException`**, streamed uploads with progress and streamed
  downloads, interceptors, and `useClient` for tests. A request can name its
  `session` and carry an `abortTrigger`; `WincheHttp.standalone()` serves
  requests outside an app. Needs `http` 1.5.
* **Generated setup.** `WincheOptions.projectId` and `clientIds` (written
  by `winche configure`), and **`app.useEmulator({host, port, only})`**: the
  app's services, or only some, go to the local emulator; `localhost` becomes
  `10.0.2.2` on Android; refused once the app is in use.
* **`WincheOptions.appId`**: the registered app's id (written by `winche
  configure --app`), sent with every request as `X-Winche-App` (on
  WebSockets, the `winche_app` query parameter). **`copyWith`** replaces
  single fields.
* Standard paths: database `/documents/v1/ws`, storage `/files/v1`.

## 0.2.1 (not published; part of 1.0.0)

* **`WincheOptions.authEndpoint`**: the REST endpoint `winche_auth` signs in
  against, e.g. `https://host/auth/v1`. Null when the app uses another identity
  provider or none.
* **`WincheOptions.emulator({host, port})`**: the database, storage and auth
  endpoints of a local Winche emulator in one call (`localhost:9090` by
  default; `10.0.2.2` from an Android emulator).

* **`WincheOptions.functionsEndpoint`** and **`WincheFunctionsService`**: the
  REST endpoint and service contract `winche_functions` uses to call the
  backend's functions as the signed-in identity (in `emulator()` too).

Additive: nothing existing changes.

## 0.2.0

A shared exception root, an identity that accepts whatever a backend issues,
and a `storageKey` that is a digest rather than a derived name.

### Breaking

* **`WincheIdentity.storageKey` is now a 128-bit SHA-256 digest of `id`,
  rendered as 32 lowercase hex characters.** It was the id itself when already
  lowercase, and a case-folded stem plus a short hand-rolled hash otherwise.
  **Every service keying on-disk state by `storageKey` will look in a new
  location and find nothing.** For `winche_database` that means cached
  documents are re-fetched and **pending writes that never reached the server
  are lost**. There is no migration: services adopting this must decide for
  themselves whether to move the old directory or abandon it.

  The change buys three properties the old scheme could not have at once. A
  key can no longer be collapsed by a case-insensitive filesystem, because it
  is all lowercase — the property that lets `User1` and `user1` stay apart on
  NTFS and default macOS APFS. Every id yields a usable name, which is what
  allows the validation relaxed below. And the length is fixed at 32
  characters however long the id, keeping composed paths clear of Windows'
  `MAX_PATH`.

  SHA-256 rather than a hand-rolled hash because this value is a directory
  name: it has to be identical across Dart releases, platforms, and between
  native and web, or an upgrade silently orphans local state. Adds a
  dependency on `package:crypto`.

* **`WincheSessionExpired` now extends `WincheException`** rather than
  implementing `Exception` directly. Its message and `toString` output are
  unchanged; only its supertype is new.

* **The exported types of `winche_core.dart` are now prefixed `Winche`.** Two
  were not:

  | 0.1.0 | 0.2.0 |
  |---|---|
  | `SessionConsumer` | `WincheSessionConsumer` |
  | `SessionConsumerError` | `WincheSessionConsumerError` |

  A rename only — no behaviour changes with it.

  Three names are deliberately left alone. `SessionDispatcher`,
  `ContractRecorder` and `WincheTokenFetcher` are not exported from either
  barrel and appear in no exported signature, so no consumer can reach them.
  `ScriptedAuthService`, from `testing.dart`, keeps its name: it is a test
  double rather than part of the runtime API, and the prefix earns nothing in
  a file you only import from a test.

* **`WincheNonAuthService` is gone.** `WincheDatabaseService` and
  `WincheStorageService` now extend `WincheService` directly and implement
  `WincheSessionConsumer`. Anything extending one of those two — every real
  service — is unaffected. Anything referring to `WincheNonAuthService` by
  name, as a variable type or a type argument, needs one of those two or
  `WincheService`.

  The intermediate class existed to carry two method declarations. Those are
  the interface now, so it was a level of hierarchy that named nothing.

* **`WincheSessionConsumer.onTokenChanged` has no default implementation.**
  It was an empty body on `WincheNonAuthService`, inherited silently. A
  consumer that never reacts to a token rotation is a real bug — it does not
  re-dial, or never retries work a stale token paused — and it failed only in
  the field, once a token actually expired. Every concrete service must now
  write the method. An empty body is a fine answer; it just has to be one you
  gave.

* **`WincheServiceError` is now `WincheSessionConsumerError`**, and lives with
  `WincheSessionConsumer` rather than among the models. Its `service` field
  is renamed `consumer` and retyped from `WincheService` to
  `WincheSessionConsumer`: only a consumer has hooks that can fail this way,
  so the old type was never accurate. `error` and `stackTrace` are unchanged,
  and `error` is still `Object` rather than narrowed — a hook can throw
  anything, so handlers should inspect it rather than the wrapper.

  It is **not** an exception, and was briefly made one during this release
  before being reverted. It is produced by the dispatcher and delivered as a
  value on `WincheApp.errors`; nothing throws it, so typing it as an exception
  only invites `catch` sites that never fire. The thing worth catching is
  `error`, which it carries.

  `WincheApp.errors` is therefore now a `Stream<WincheSessionConsumerError>`.

### Added

* **`WincheSessionConsumer`, the interface the session dispatcher works
  through.** Exactly three members — `isDisposed`, `onSessionChanged`,
  `onTokenChanged` — and deliberately not a fourth: the dispatcher decides
  what each consumer should be bound to and knows nothing about what a
  consumer is, what it connects to, or which app it belongs to.
  `WincheDatabaseService` and `WincheStorageService` implement it, so every
  production consumer already qualifies; the interface exists so that fact is
  a coincidence the dispatcher does not rely on, and so it can be tested
  without the service hierarchy present.

* **`WincheException`, the root of every exception the stack throws.** One
  root across every package, so `on WincheException` catches everything from
  the SDK — including from a Winche package added to the app later, the case a
  per-package hierarchy always misses. It carries a `message` and derives
  `toString` from the runtime type, so a downstream exception cannot forget to
  name itself in its own output. Downstream packages should extend this
  instead of implementing `Exception`, and group wire errors under one
  intermediate subclass rather than spreading them directly beneath it.
* **`WincheUnboundException`**, moved in from `winche_database`. "No identity
  is bound to this app" is a condition every service shares, so it belongs
  where every service can name it: a consumer using two Winche packages writes
  one `catch`, and a third package does not make it three. Deliberately not a
  wire error — it never crossed the wire, and unlike a `PERMISSION_DENIED` it
  is fixed by signing in rather than by handling it.

### Changed

* **`WincheIdentity` accepts almost any id.** The
  `[A-Za-z0-9._-]{1,128}` rule, along with the `.`, `..` and trailing-dot
  checks, existed solely to keep `id` usable as a path component; `storageKey`
  now guarantees that regardless. Emails, LDAP distinguished names, provider
  ids like `auth0|5f3c2b1a`, non-ASCII ids and ids far longer than 128
  characters are all valid, so a backend issuing them can sign in at all —
  previously it could not.

  Two rejections remain. An id that is empty or whitespace-only is never a
  real principal. An id containing a control character (C0, DEL, or C1) is
  refused because `id` is interpolated verbatim into `toString` and into
  `WincheSessionExpired`'s message, where an embedded newline would let a
  backend-supplied value forge a log entry.

  Relaxing validation is source-compatible: every id valid in 0.1.0 is still
  valid.

## 0.1.0

A breaking redesign of the whole package around a session model, replacing
the stream-based auth contract and service-lookup app of 0.0.1. Nothing from
0.0.1 is source-compatible with this release.

* **Session model.** A `WincheSession` (`identity`, `isActive`,
  `token({forceRefresh})`) is now the unit core hands consumers, instead of
  raw identity/token streams. `isActive` lets a consumer notice that an
  operation has outlived the session it started under, and `token()` throws
  the package's only exception, `WincheSessionExpired`, once that happens —
  checked both synchronously up front and again after the fetch resolves, so
  a call straddling a user switch can never return the next user's token.
* **Two-hook consumer contract.** `WincheNonAuthService` is now exactly
  `onSessionChanged(WincheSession?)` and `onTokenChanged()`, replacing
  `onAuthTokenChanged` / `onActiveIdentityChanged`. A session change tears
  down and rebuilds; a token rotation with the same identity only nudges.
* **Reconcile-to-latest dispatch.** Sessions changing faster than consumers
  can keep up no longer queue every intermediate value — a rapid
  `A -> B -> C` now ends at `C` with `B` never dispatched, and
  `A -> null -> A` collapses to "still `A`". Core also awaits every
  consumer's hook before starting the next dispatch, so two session swaps can
  never interleave inside one consumer.
* **Failure isolation.** A consumer whose hook throws is reported on the
  app's new `errors` stream (`Stream<WincheServiceError>`) and left unbound
  — retried automatically on the next change — while every other consumer
  still receives its dispatch. Core does not track service health or latch
  failures.
* **Notify-based auth seam.** `WincheAuthService` no longer exposes
  `authTokenChanges` / `identityChanges` streams, nor `signIn` / `signOut`.
  It now announces changes through two `@protected` methods,
  `notifyIdentityChanged(WincheIdentity?)` and `notifyTokenRotated()`, and
  exposes no sign-in surface of its own: how a backend authenticates —
  password, OIDC redirect, refresh token, device code — is entirely up to
  the implementing package, which is free to add whatever methods its
  backend needs.
* **`WincheCredentials` and `signIn`/`signOut` removed.** There is no
  credentials type and no sign-in method on the base class; see above.
* **`WincheIdentity` is now a single concrete class**, replacing the abstract
  `WincheIdentity` plus `SimpleIdentity`. `id` is validated against
  `^[A-Za-z0-9._-]{1,128}$` and rejects `.`, `..`, and a trailing dot — an
  identity's `id` becomes a path and IndexedDB database-name component in
  every consuming service, and NTFS strips a trailing dot, so `abc.` and
  `abc` would otherwise silently collide. The class is not `const` because
  that validation is not const-evaluable. Claims equality is shallow.
* **`WincheOptions` narrowed** to `databaseEndpoint`, `storageEndpoint`, and
  a new `directoryResolver`. Core hands out only the directory root; how a
  service composes a path beneath it, and what it names an IndexedDB
  database, is that service's business, not core's.
* **`WincheApp` is no longer a service-lookup surface.** `service<T>()` and
  `maybeService<T>()` are gone from the public API; the service registry,
  `session`, and `authService` are now `@internal`. The public surface is
  `name`, `options`, `errors`, `isDisposed`, and `dispose()`. Each service
  package is expected to expose its own `instance` / `instanceFor` accessor
  rather than routing lookups through the app.
* **`Winche.initializeApp` is synchronous.**
* **A hook deadline.** Dispatch is sequential and teardown awaits it, so one
  `onSessionChanged` that never returned starved every other service *and* hung
  the app forever — and a consuming service's hook opens sockets and stores, the
  two things that hang. `WincheApp.hookTimeout` (30s by default, also on
  `Winche.initializeApp`) bounds every hook and every `dispose`. An abandoned
  hook is treated exactly like one that threw: reported and left unbound.
* **`WincheApp.settled` is public.** Awaiting it is how you know every service
  has finished reacting to a sign-in change — for gating UI, and so a service
  package's tests can wait for a dispatch without racing the wall clock.
* **`package:winche_core/testing.dart`** — conformance suites
  (`WincheServiceContract`, `WincheAuthContract`) and a `ScriptedAuthService`
  double. The two auth rules and the swap-vs-nudge distinction cannot be
  expressed in types; these turn them into a test any implementation can run.
  Deliberately free of a test-framework dependency: a suite returns a
  `WincheContractReport` rather than calling `expect` itself.
* **`WincheIdentity.storageKey`** — the name to use when an identity becomes a
  directory or IndexedDB database component. `id` validation cannot rule out
  case collisions, and on NTFS and default macOS APFS `User1` and `user1`
  resolve to the same directory, so a backend issuing case-sensitive ids would
  let one user read another's cached state. An all-lowercase id passes through
  unchanged; anything else is case-folded with a stable digest appended.
* **`WincheService.instanceFor(app, create)`** — returns the service already
  attached to `app`, or builds one. Service packages should route their
  `instance` / `instanceFor` accessors through this rather than keeping a
  static cache keyed by `WincheApp`, which has to remember to evict itself on
  dispose and hands back a disposed instance when it forgets.

## 0.0.1

Initial release.

* `Winche` app registry: `initializeApp`, `app`, `appFor`, `maybeAppFor`,
  `apps`, `deinitializeApp`, `deinitializeAll`.
* `WincheApp` with a service registry keyed by concrete type, plus
  `service<T>()` / `maybeService<T>()` lookups.
* `WincheOptions` carrying the backend endpoints — `databaseEndpoint` and
  `storageEndpoint`. Everything else, persistence included, is owned by the
  service it belongs to.
* Sealed service hierarchy: `WincheService`, split into `WincheAuthService`
  and `WincheNonAuthService`, with `WincheDatabaseService` and
  `WincheStorageService` provided as ready-made categories.
* Consuming services are wired to the app's auth service regardless of
  registration order, and inherit `getAuthToken()`, `activeIdentity`,
  `onAuthTokenChanged` and `onActiveIdentityChanged`.
* `WincheIdentity`, `SimpleIdentity` and `WincheCredentials<TIdentity>` models.
* Pure Dart — no Flutter dependency.
