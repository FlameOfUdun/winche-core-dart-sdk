import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:winche_core/winche_core.dart';

import 'support/fakes.dart';

void main() {
  final production = WincheOptions(
    projectId: 'demo',
    clientIds: {'google': 'g.apps.googleusercontent.com'},
    baseUrl: Uri.parse('https://api.example.com'),
    endpoints: {'storage': Uri.parse('https://files.example.com/files/v1')},
  );
  tearDown(Winche.deinitializeAll);

  test('sends every service to the emulator, overrides included, keeping ids', () {
    final app = Winche.initializeApp(options: production)..useEmulator();
    final options = app.options!;
    expect(options.endpointFor('functions', path: '/functions/v1').toString(), 'http://localhost:9090/functions/v1');
    expect(options.endpointFor('storage', path: '/files/v1').toString(), 'http://localhost:9090/files/v1');
    expect(options.endpointFor('database', path: '/documents/v1/ws', webSocket: true).toString(), 'ws://localhost:9090/documents/v1/ws');
    expect([options.projectId, options.clientIds['google']], ['demo', 'g.apps.googleusercontent.com']);
    expect(options.emulator.toString(), 'http://localhost:9090');
  });

  test('only: some services go to the emulator, the rest stay', () {
    final app = Winche.initializeApp(options: production)..useEmulator(host: '192.168.1.5', port: 9191, only: {'database'});
    expect(app.options!.endpointFor('database', path: '/documents/v1/ws', webSocket: true).toString(), 'ws://192.168.1.5:9191/documents/v1/ws');
    expect(app.options!.endpointFor('auth', path: '/auth/v1').toString(), 'https://api.example.com/auth/v1');
    expect(app.options!.endpointFor('storage', path: '/files/v1').toString(), 'https://files.example.com/files/v1');
  });

  test('works without options, and initializeApp still accepts the original options', () {
    final bare = WincheApp('bare')..useEmulator();
    expect(bare.options!.endpointFor('auth', path: '/auth/v1').toString(), 'http://localhost:9090/auth/v1');
    final app = Winche.initializeApp(options: production)..useEmulator();
    expect(identical(Winche.initializeApp(options: production), app), isTrue);
  });

  test('refused once a service is attached or a request was sent', () async {
    final withAuth = WincheApp('with-auth');
    FakeAuthService(withAuth);
    expect(withAuth.useEmulator, throwsA(isA<StateError>().having((e) => e.message, 'message', contains('FakeAuthService'))));

    final used = WincheApp('used', options: production);
    used.http.useClient(MockClient((_) async => http.Response('{}', 200)));
    await used.http.send(WincheRequest.get(Uri.parse('https://api.example.com/x'), auth: WincheRequestAuth.none));
    expect(used.useEmulator, throwsA(isA<StateError>()));
    await withAuth.dispose();
    await used.dispose();
  });

  test('projectId and clientIds take part in equality', () {
    expect(WincheOptions(projectId: 'a'), WincheOptions(projectId: 'a'));
    expect(WincheOptions(projectId: 'a'), isNot(WincheOptions(projectId: 'b')));
    expect(WincheOptions(clientIds: {'google': 'x'}), isNot(WincheOptions(clientIds: {'google': 'y'})));
    expect(WincheOptions(clientIds: {'google': 'x'}).hashCode, WincheOptions(clientIds: {'google': 'x'}).hashCode);
  });

  test('copyWith replaces what it is given and keeps the rest, a redirect included', () {
    Future<String> dir() async => '/tmp';
    final copy = production.redirectedTo(Uri.parse('http://localhost:9090')).copyWith(directoryResolver: dir, projectId: 'other');
    expect(copy.directoryResolver, same(dir));
    expect(copy.projectId, 'other');
    expect(copy.clientIds, production.clientIds);
    expect(copy.emulator.toString(), 'http://localhost:9090');
    expect(copy.endpointFor('storage', path: '/files/v1').toString(), 'http://localhost:9090/files/v1');
    expect(production.copyWith(), production);
  });
}
