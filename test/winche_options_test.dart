import 'package:test/test.dart';
// The deprecated endpoint fields are exercised on purpose: they must keep working for a release.
// ignore_for_file: deprecated_member_use_from_same_package
import 'package:winche_core/winche_core.dart';

void main() {
  group('WincheOptions', () {
    test('carries both endpoints and the directory root', () async {
      Future<String> root() async => '/tmp/winche';
      final options = WincheOptions(
        databaseEndpoint: Uri.parse('wss://api.winche.dev/documents/ws'),
        storageEndpoint: Uri.parse('https://api.winche.dev/files'),
        directoryResolver: root,
      );

      expect(options.databaseEndpoint.toString(), 'wss://api.winche.dev/documents/ws');
      expect(options.storageEndpoint.toString(), 'https://api.winche.dev/files');
      expect(await options.directoryResolver?.call(), '/tmp/winche');
    });

    test('an unused endpoint stays null', () {
      final options = WincheOptions(storageEndpoint: Uri.parse('https://api.winche.dev/files'));
      expect(options.databaseEndpoint, isNull);
      expect(options.directoryResolver, isNull);
    });

    test('compares endpoints by value and the resolver by identity', () {
      final uri = Uri.parse('wss://api.winche.dev/documents/ws');
      Future<String> root() async => '/tmp/winche';

      expect(WincheOptions(databaseEndpoint: uri), WincheOptions(databaseEndpoint: uri));
      expect(WincheOptions(databaseEndpoint: uri).hashCode, WincheOptions(databaseEndpoint: uri).hashCode);
      expect(WincheOptions(databaseEndpoint: uri), isNot(WincheOptions(databaseEndpoint: Uri.parse('wss://other/ws'))));
      expect(WincheOptions(directoryResolver: root), WincheOptions(directoryResolver: root));
    });

    test('the auth endpoint takes part in equality', () {
      final auth = Uri.parse('https://api.winche.dev/auth/v1');
      expect(WincheOptions(authEndpoint: auth), WincheOptions(authEndpoint: auth));
      expect(WincheOptions(authEndpoint: auth), isNot(const WincheOptions()));
      expect(WincheOptions(authEndpoint: auth).toString(), contains('auth: https://api.winche.dev/auth/v1'));
    });

    test('emulator() points every service at one local host and port', () {
      final options = WincheOptions.emulator();
      expect(options.databaseEndpoint.toString(), 'ws://localhost:9090/documents/v1/ws');
      expect(options.storageEndpoint.toString(), 'http://localhost:9090/files/v1');
      expect(options.authEndpoint.toString(), 'http://localhost:9090/auth/v1');
      expect(WincheOptions.emulator(host: '10.0.2.2', port: 9191).authEndpoint.toString(), 'http://10.0.2.2:9191/auth/v1');
      expect(WincheOptions.emulator(), WincheOptions.emulator());
    });
  });

  group('baseUrl', () {
    final base = Uri.parse('https://api.example.com');

    test("the app's id goes in WebSocket addresses (browsers can't set headers there), and copyWith keeps it", () {
      final options = WincheOptions(baseUrl: base, appId: 'app-abc123def456');
      expect(options.endpointFor('database', path: '/documents/v1/ws', webSocket: true).toString(),
          'wss://api.example.com/documents/v1/ws?winche_app=app-abc123def456');
      expect(options.endpointFor('database', path: '/documents/v1').toString(), 'https://api.example.com/documents/v1');
      expect(options.copyWith(projectId: 'p').appId, 'app-abc123def456');
      expect(options.redirectedTo(Uri.parse('http://localhost:9090')).appId, 'app-abc123def456');
    });

    test('every service is its own path under one address; the database gets wss', () {
      final options = WincheOptions(baseUrl: base);
      expect(options.endpointFor('functions', path: '/functions/v1').toString(), 'https://api.example.com/functions/v1');
      expect(options.endpointFor('database', path: '/documents/v1/ws', webSocket: true).toString(), 'wss://api.example.com/documents/v1/ws');
      expect(options.endpointFor('messaging', path: 'messages/v1').toString(), 'https://api.example.com/messages/v1'); // a package core doesn't know
      expect(WincheOptions(baseUrl: Uri.parse('http://host:9090/winche/')).endpointFor('auth', path: '/auth/v1').toString(), 'http://host:9090/winche/auth/v1');
    });

    test('an override wins for its service only', () {
      final options = WincheOptions(baseUrl: base, endpoints: {'storage': Uri.parse('https://files.example.com/files/v1')});
      expect(options.endpointFor('storage', path: '/files/v1').toString(), 'https://files.example.com/files/v1');
      expect(options.endpointFor('auth', path: '/auth/v1').toString(), 'https://api.example.com/auth/v1');
    });

    test('nothing configured says what to set', () {
      expect(
        () => const WincheOptions().endpointFor('functions', path: '/functions/v1'),
        throwsA(isA<StateError>().having((e) => e.message, 'message', allOf(contains('baseUrl'), contains("endpoints['functions']")))),
      );
      expect(const WincheOptions().maybeEndpointFor('functions', path: '/functions/v1'), isNull);
    });

    test('the old fields still work, and are filled in from baseUrl for packages that read them', () {
      final old = WincheOptions(storageEndpoint: Uri.parse('https://old.example.com/files'));
      expect(old.endpointFor('storage', path: '/files/v1').toString(), 'https://old.example.com/files');
      final options = WincheOptions(baseUrl: base);
      expect(options.databaseEndpoint.toString(), 'wss://api.example.com/documents/v1/ws');
      expect(options.storageEndpoint.toString(), 'https://api.example.com/files/v1');
      expect(options.functionsEndpoint.toString(), 'https://api.example.com/functions/v1');
    });

    test('compares baseUrl and overrides by value', () {
      expect(WincheOptions(baseUrl: base, endpoints: {'a': base}), WincheOptions(baseUrl: base, endpoints: {'a': base}));
      expect(WincheOptions(baseUrl: base, endpoints: {'a': base}).hashCode, WincheOptions(baseUrl: base, endpoints: {'a': base}).hashCode);
      expect(WincheOptions(baseUrl: base), isNot(WincheOptions(baseUrl: Uri.parse('https://other.example.com'))));
      expect(WincheOptions(baseUrl: base).toString(), contains('baseUrl: https://api.example.com'));
    });
  });
}
