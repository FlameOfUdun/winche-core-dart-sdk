import 'package:test/test.dart';
import 'package:winche_core/winche_core.dart';

import 'support/fakes.dart';

void main() {
  tearDown(() async => Winche.deinitializeAll());

  test('initializeApp is idempotent and appFor finds the app', () {
    final app = Winche.initializeApp();
    expect(Winche.initializeApp(), same(app));
    expect(Winche.app, same(app));
    expect(Winche.appFor(Winche.defaultAppName), same(app));
    expect(Winche.apps, [app]);
  });

  test('appFor throws for an unknown name, maybeAppFor returns null', () {
    expect(() => Winche.appFor('nope'), throwsArgumentError);
    expect(Winche.maybeAppFor('nope'), isNull);
  });

  test('named apps are independent', () {
    final a = Winche.initializeApp(name: 'a');
    final b = Winche.initializeApp(name: 'b');
    expect(a, isNot(same(b)));

    FakeAuthService(a);
    expect(a.authService, isNotNull);
    expect(b.authService, isNull);
  });

  test('re-initializing with conflicting options throws', () {
    final one = WincheOptions(databaseEndpoint: Uri.parse('wss://one/ws'));
    final two = WincheOptions(databaseEndpoint: Uri.parse('wss://two/ws'));

    Winche.initializeApp(options: one);
    expect(() => Winche.initializeApp(options: two), throwsStateError);
    expect(Winche.initializeApp(options: one), same(Winche.app));
    expect(Winche.initializeApp(), same(Winche.app));
  });

  test('deinitializeApp removes the app so the next init is fresh', () async {
    final first = Winche.initializeApp();
    await Winche.deinitializeApp();

    expect(Winche.maybeAppFor(Winche.defaultAppName), isNull);

    final second = Winche.initializeApp();
    expect(second, isNot(same(first)));
    expect(second.isDisposed, isFalse);
  });

  test('disposing an app directly also drops it from the registry', () async {
    final app = Winche.initializeApp();
    await app.dispose();
    expect(Winche.maybeAppFor(Winche.defaultAppName), isNull);
  });

  test('a failing service does not strand the app in the registry', () async {
    final app = Winche.initializeApp();
    ExplodingStorageService(app);

    await expectLater(Winche.deinitializeApp(), throwsStateError);
    expect(Winche.maybeAppFor(Winche.defaultAppName), isNull);
  });

  test('deinitializeAll tears down every app', () async {
    Winche.initializeApp(name: 'a');
    Winche.initializeApp(name: 'b');
    await Winche.deinitializeAll();
    expect(Winche.apps, isEmpty);
  });
}
