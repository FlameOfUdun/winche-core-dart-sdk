/// The stack-wide configuration carried by a `WincheApp`.
///
/// Only what more than one party needs lives here: the server's address and
/// the directory root. Each service knows its own path on the server and asks
/// [endpointFor] for its endpoint, so a new package needs no change here.
///
/// ```dart
/// Winche.initializeApp(
///   options: WincheOptions(
///     baseUrl: Uri.parse('https://api.example.com'),
///     directoryResolver: () async => (await getApplicationSupportDirectory()).path,
///   ),
/// );
/// ```
///
/// `winche configure` writes these for every platform an app runs on, as
/// `DefaultWincheOptions.currentPlatform`.
///
/// A split setup overrides single services:
///
/// ```dart
/// WincheOptions(
///   baseUrl: Uri.parse('https://api.example.com'),
///   endpoints: {'storage': Uri.parse('https://files.example.com/files/v1')},
/// );
/// ```
final class WincheOptions {
  /// Which project these options are for, as `winche configure` names it.
  /// Informational: the server is chosen by [baseUrl].
  final String? projectId;

  /// This app's id in the project (Project settings → Your apps in the
  /// console), written by `winche configure --app`. Sent with every request
  /// (header `X-Winche-App`; on WebSockets, the query parameter `winche_app`) so
  /// the console can count each app's requests, and so a project that accepts
  /// only registered apps lets this one in. Not a secret.
  final String? appId;

  /// Public client ids by sign-in provider (`google`, `apple`, …) for this
  /// platform, for the provider's own SDK (e.g. `google_sign_in`'s `clientId`).
  /// Written by `winche configure`.
  final Map<String, String> clientIds;

  /// The Winche server, e.g. `https://api.example.com`. Every service's endpoint
  /// is its own path under it unless [endpoints] says otherwise.
  final Uri? baseUrl;

  /// Endpoints for single services by their id (`database`, `storage`, `auth`,
  /// `functions`, or a package's own), used instead of the path under [baseUrl].
  final Map<String, Uri> endpoints;

  /// The parent directory every service creates its on-disk state under.
  ///
  /// Core hands out this root and nothing more; how a service composes a path
  /// beneath it, and what it names an IndexedDB database, is the service's
  /// business. Resolved lazily by the service that uses it.
  ///
  /// Null means no durable state — or, on the web, IndexedDB, which needs no
  /// directory.
  final Future<String> Function()? directoryResolver;

  final Uri? _databaseEndpoint;
  final Uri? _storageEndpoint;
  final Uri? _authEndpoint;
  final Uri? _functionsEndpoint;

  final Uri? _emulator;
  final Set<String>? _emulatorFor;

  /// Creates a set of options. Every field is optional: supply what this app
  /// actually uses, usually just [baseUrl].
  const WincheOptions({
    this.projectId,
    this.appId,
    this.clientIds = const {},
    this.baseUrl,
    this.endpoints = const {},
    this.directoryResolver,
    @Deprecated('Use baseUrl, or endpoints[\'database\']. Removed in winche_core 2.0.') Uri? databaseEndpoint,
    @Deprecated('Use baseUrl, or endpoints[\'storage\']. Removed in winche_core 2.0.') Uri? storageEndpoint,
    @Deprecated('Use baseUrl, or endpoints[\'auth\']. Removed in winche_core 2.0.') Uri? authEndpoint,
    @Deprecated('Use baseUrl, or endpoints[\'functions\']. Removed in winche_core 2.0.') Uri? functionsEndpoint,
  }) : _databaseEndpoint = databaseEndpoint,
       _storageEndpoint = storageEndpoint,
       _authEndpoint = authEndpoint,
       _functionsEndpoint = functionsEndpoint,
       _emulator = null,
       _emulatorFor = null;

  WincheOptions._redirected(WincheOptions from, Uri emulator, Set<String>? only)
    : projectId = from.projectId,
      appId = from.appId,
      clientIds = from.clientIds,
      baseUrl = from.baseUrl,
      endpoints = from.endpoints,
      directoryResolver = from.directoryResolver,
      _databaseEndpoint = from._databaseEndpoint,
      _storageEndpoint = from._storageEndpoint,
      _authEndpoint = from._authEndpoint,
      _functionsEndpoint = from._functionsEndpoint,
      _emulator = emulator,
      _emulatorFor = only == null ? null : Set.unmodifiable(only);

  /// The local Winche emulator (`winche emulators start`) at [host] and [port],
  /// without TLS.
  ///
  /// On an Android emulator the host machine is `10.0.2.2`, not `localhost`.
  /// To keep a generated `DefaultWincheOptions` and switch to the emulator in
  /// debug builds, use `WincheApp.useEmulator` instead.
  factory WincheOptions.emulator({String host = 'localhost', int port = 9090, Future<String> Function()? directoryResolver}) {
    return WincheOptions(
      baseUrl: Uri(scheme: 'http', host: host, port: port),
      directoryResolver: directoryResolver,
    );
  }

  /// A copy with the given fields replaced; everything else, an emulator
  /// redirect included, carries over.
  WincheOptions copyWith({
    String? projectId,
    String? appId,
    Map<String, String>? clientIds,
    Uri? baseUrl,
    Map<String, Uri>? endpoints,
    Future<String> Function()? directoryResolver,
  }) => WincheOptions._copy(
    this,
    projectId: projectId ?? this.projectId,
    appId: appId ?? this.appId,
    clientIds: clientIds ?? this.clientIds,
    baseUrl: baseUrl ?? this.baseUrl,
    endpoints: endpoints ?? this.endpoints,
    directoryResolver: directoryResolver ?? this.directoryResolver,
  );

  WincheOptions._copy(
    WincheOptions from, {
    required this.projectId,
    required this.appId,
    required this.clientIds,
    required this.baseUrl,
    required this.endpoints,
    required this.directoryResolver,
  }) : _databaseEndpoint = from._databaseEndpoint,
       _storageEndpoint = from._storageEndpoint,
       _authEndpoint = from._authEndpoint,
       _functionsEndpoint = from._functionsEndpoint,
       _emulator = from._emulator,
       _emulatorFor = from._emulatorFor;

  /// These options with the services in [only] (every service when null) sent
  /// to the emulator at [emulator] instead, overrides included. What
  /// `WincheApp.useEmulator` uses.
  WincheOptions redirectedTo(Uri emulator, {Set<String>? only}) => WincheOptions._redirected(this, emulator, only);

  /// The emulator these options send services to, if any.
  Uri? get emulator => _emulator;

  /// The endpoint of the service [id] (e.g. `functions`) whose path under
  /// [baseUrl] is [path] (e.g. `/functions/v1`). [webSocket] turns `http`/`https`
  /// into `ws`/`wss`.
  ///
  /// Throws a [StateError] naming what to set when neither [baseUrl] nor an
  /// override for [id] is configured.
  Uri endpointFor(String id, {required String path, bool webSocket = false}) =>
      maybeEndpointFor(id, path: path, webSocket: webSocket) ??
      (throw StateError(
        'No address for the $id service: set WincheOptions.baseUrl '
        '(e.g. https://api.example.com), or WincheOptions.endpoints[\'$id\'].',
      ));

  /// [endpointFor], or null when nothing is configured for [id].
  Uri? maybeEndpointFor(String id, {required String path, bool webSocket = false}) {
    final emulated = _emulator != null && (_emulatorFor == null || _emulatorFor.contains(id));
    final explicit = emulated ? null : endpoints[id] ?? _legacy(id);
    if (explicit != null) return explicit;
    final base = emulated ? _emulator : baseUrl;
    if (base == null) return null;
    final joined = '${base.path.replaceAll(RegExp(r'/+$'), '')}/${path.replaceAll(RegExp(r'^/+'), '')}';
    final scheme = webSocket ? (base.scheme == 'https' ? 'wss' : base.scheme == 'http' ? 'ws' : base.scheme) : base.scheme;
    // A WebSocket can't carry the X-Winche-App header from a browser: the app's id goes in the query.
    final query = webSocket && appId != null ? {...base.queryParameters, 'winche_app': appId!} : null;
    return query == null ? base.replace(scheme: scheme, path: joined) : base.replace(scheme: scheme, path: joined, queryParameters: query);
  }

  Uri? _legacy(String id) => switch (id) {
    'database' => _databaseEndpoint,
    'storage' => _storageEndpoint,
    'auth' => _authEndpoint,
    'functions' => _functionsEndpoint,
    _ => null,
  };

  /// The database's WebSocket endpoint, e.g. `wss://host/documents/v1/ws`.
  @Deprecated('Use endpointFor(\'database\', path: \'/documents/v1/ws\', webSocket: true). Removed in winche_core 2.0.')
  Uri? get databaseEndpoint => maybeEndpointFor('database', path: '/documents/v1/ws', webSocket: true);

  /// Storage's REST endpoint, e.g. `https://host/files/v1`.
  @Deprecated('Use endpointFor(\'storage\', path: \'/files/v1\'). Removed in winche_core 2.0.')
  Uri? get storageEndpoint => maybeEndpointFor('storage', path: '/files/v1');

  /// Winche Auth's REST endpoint, e.g. `https://host/auth/v1`.
  @Deprecated('Use endpointFor(\'auth\', path: \'/auth/v1\'). Removed in winche_core 2.0.')
  Uri? get authEndpoint => maybeEndpointFor('auth', path: '/auth/v1');

  /// The functions endpoint, e.g. `https://host/functions/v1`.
  @Deprecated('Use endpointFor(\'functions\', path: \'/functions/v1\'). Removed in winche_core 2.0.')
  Uri? get functionsEndpoint => maybeEndpointFor('functions', path: '/functions/v1');

  /// Addresses and ids compare by value; [directoryResolver] compares by
  /// identity, because Dart compares closures that way.
  ///
  /// This matters only for `Winche.initializeApp`, which rejects a repeat call
  /// whose options disagree with the app's: hoist the options into a variable
  /// if they must be passed twice.
  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is WincheOptions &&
        other.projectId == projectId &&
        _sameMap(other.clientIds, clientIds) &&
        other.baseUrl == baseUrl &&
        _sameMap(other.endpoints, endpoints) &&
        other._databaseEndpoint == _databaseEndpoint &&
        other._storageEndpoint == _storageEndpoint &&
        other._authEndpoint == _authEndpoint &&
        other._functionsEndpoint == _functionsEndpoint &&
        other._emulator == _emulator &&
        _sameSet(other._emulatorFor, _emulatorFor) &&
        other.directoryResolver == directoryResolver;
  }

  static bool _sameMap<V>(Map<String, V> a, Map<String, V> b) => a.length == b.length && a.entries.every((e) => b[e.key] == e.value);

  static bool _sameSet(Set<String>? a, Set<String>? b) => identical(a, b) || (a != null && b != null && a.length == b.length && a.containsAll(b));

  @override
  int get hashCode => Object.hash(
    projectId,
    Object.hashAllUnordered(clientIds.entries.map((e) => Object.hash(e.key, e.value))),
    baseUrl,
    Object.hashAllUnordered(endpoints.entries.map((e) => Object.hash(e.key, e.value))),
    _databaseEndpoint,
    _storageEndpoint,
    _authEndpoint,
    _functionsEndpoint,
    _emulator,
    directoryResolver,
  );

  @override
  String toString() {
    final overrides = {
      ...endpoints.map((k, v) => MapEntry(k, v.toString())),
      for (final id in const ['database', 'storage', 'auth', 'functions'])
        if (_legacy(id) case final uri?) id: uri.toString(),
    };
    return 'WincheOptions(${projectId == null ? '' : 'projectId: $projectId, '}baseUrl: $baseUrl, '
        'endpoints: ${overrides.isEmpty ? '{}' : overrides}, '
        '${_emulator == null ? '' : 'emulator: $_emulator${_emulatorFor == null ? '' : ' for $_emulatorFor'}, '}'
        'directoryResolver: ${directoryResolver == null ? 'null' : 'set'})';
  }
}
