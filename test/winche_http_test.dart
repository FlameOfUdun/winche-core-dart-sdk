import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:winche_core/winche_core.dart';

/// Auth whose refreshed token sticks, counting refreshes.
final class RefreshingAuth extends WincheService with WincheIdentitySource {
  RefreshingAuth(super.app);
  WincheIdentity? _identity;
  int version = 1;
  int refreshes = 0;
  Completer<void>? holdRefresh;

  @override
  WincheIdentity? get activeIdentity => _identity;

  @override
  Future<String?> getAuthToken({bool forceRefresh = false}) async {
    if (_identity == null) return null;
    if (forceRefresh) {
      refreshes++;
      await holdRefresh?.future;
      version++;
    }
    return 't$version';
  }

  void signIn() {
    _identity = WincheIdentity('alice');
    notifyIdentityChanged(_identity);
  }
}

void main() {
  final url = Uri.parse('https://api.example.com/things');
  late WincheApp app;
  late RefreshingAuth auth;
  late List<http.BaseRequest> sent;

  void serve(FutureOr<http.Response> Function(http.Request request) handler) {
    app.http.useClient(
      MockClient((request) {
        sent.add(request);
        return Future.value(handler(request));
      }),
    );
  }

  setUp(() async {
    app = WincheApp('http');
    app.http.retryDelay = Duration.zero;
    auth = RefreshingAuth(app);
    sent = [];
  });
  tearDown(() => app.dispose());

  Future<void> signIn() async {
    auth.signIn();
    await app.settled;
  }

  test("adds the signed-in user's token, and none when signed out or asked not to", () async {
    serve((_) => http.Response('{}', 200));
    await app.http.send(WincheRequest.get(url));
    await signIn();
    await app.http.send(WincheRequest.get(url));
    await app.http.send(WincheRequest.get(url, auth: WincheRequestAuth.none));
    expect(sent.map((r) => r.headers['authorization']), [null, 'Bearer t1', null]);
  });

  test("names the app (options.appId) on every request", () async {
    final named = WincheApp('named', options: const WincheOptions(appId: 'app-abc123def456'));
    named.http.useClient(MockClient((request) async {
      sent.add(request);
      return http.Response('{}', 200);
    }));
    await named.http.send(WincheRequest.get(url));
    expect(sent.single.headers['x-winche-app'], 'app-abc123def456');
    await named.dispose();

    serve((_) => http.Response('{}', 200));
    await app.http.send(WincheRequest.get(url));   // no appId: no header
    expect(sent.last.headers.containsKey('x-winche-app'), isFalse);
  });

  test('a request that needs a user fails at once when no one is signed in', () async {
    serve((_) => http.Response('{}', 200));
    await expectLater(app.http.send(WincheRequest.get(url, auth: WincheRequestAuth.required)), throwsA(isA<WincheUnboundException>()));
    expect(sent, isEmpty);
  });

  test('a 401 refreshes the token and tries once more', () async {
    await signIn();
    serve((r) => r.headers['authorization'] == 'Bearer t2' ? http.Response('{"ok":true}', 200) : http.Response('', 401));
    final response = await app.http.send(WincheRequest.post(url, json: {'a': 1}));
    expect(response.json, {'ok': true});
    expect(auth.refreshes, 1);
    expect(sent.map((r) => r.headers['authorization']), ['Bearer t1', 'Bearer t2']);
  });

  test('a second 401 after refreshing is an error, not a loop', () async {
    await signIn();
    serve((_) => http.Response('{"error":{"code":"unauthenticated","message":"No."}}', 401));
    await expectLater(
      app.http.send(WincheRequest.get(url)),
      throwsA(isA<WincheHttpException>().having((e) => e.code, 'code', WincheErrorCode.unauthenticated).having((e) => e.status, 'status', 401)),
    );
    expect(sent, hasLength(2));
  });

  test('requests refused together share one refresh', () async {
    await signIn();
    auth.holdRefresh = Completer();
    serve((r) => r.headers['authorization'] == 'Bearer t2' ? http.Response('{}', 200) : http.Response('', 401));
    final all = Future.wait([for (var i = 0; i < 10; i++) app.http.send(WincheRequest.get(url))]);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    auth.holdRefresh!.complete();
    await all;
    expect(auth.refreshes, 1);
  });

  test('safe requests are retried on 502/503/504 and network errors; others are not', () async {
    var calls = 0;
    serve((_) => ++calls < 3 ? http.Response('', 503) : http.Response('{}', 200));
    await app.http.send(WincheRequest.get(url));
    expect(calls, 3);

    calls = 0;
    app.http.useClient(MockClient((_) async => ++calls < 2 ? throw http.ClientException('reset') : http.Response('{}', 200)));
    await app.http.send(WincheRequest.delete(url));
    expect(calls, 2);

    calls = 0;
    serve((_) {
      calls++;
      return http.Response('', 503);
    });
    await expectLater(app.http.send(WincheRequest.post(url, json: {})), throwsA(isA<WincheHttpException>().having((e) => e.status, 'status', 503)));
    expect(calls, 1);
  });

  test('gives up after three tries', () async {
    var calls = 0;
    app.http.useClient(
      MockClient((_) async {
        calls++;
        throw http.ClientException('down');
      }),
    );
    await expectLater(
      app.http.send(WincheRequest.get(url, service: 'storage')),
      throwsA(isA<WincheHttpException>().having((e) => e.code, 'code', WincheErrorCode.unavailable).having((e) => e.service, 'service', 'storage')),
    );
    expect(calls, 3);
  });

  test('a try that takes too long times out', () async {
    app.http.useClient(MockClient((_) => Completer<http.Response>().future));
    await expectLater(
      app.http.send(WincheRequest.post(url, timeout: const Duration(milliseconds: 20))),
      throwsA(isA<WincheHttpException>().having((e) => e.code, 'code', WincheErrorCode.deadlineExceeded)),
    );
  });

  group('errors', () {
    Future<WincheHttpException> failWith(int status, String body) async {
      serve((_) => http.Response(body, status));
      try {
        await app.http.send(WincheRequest.post(url));
      } on WincheHttpException catch (e) {
        return e;
      }
      fail('did not throw');
    }

    test('{error: {code, reason, message, details}} keeps every field', () async {
      final e = await failWith(401, '{"error":{"code":"unauthenticated","reason":"MFA_REQUIRED","message":"Enter your code.","details":{"mfaToken":"m"}}}');
      expect([e.code, e.reason, e.message, e.details['mfaToken']], [WincheErrorCode.unauthenticated, 'MFA_REQUIRED', 'Enter your code.', 'm']);
    });

    test('a code outside the shared list is kept as the reason, the kind from the status', () async {
      final e = await failWith(409, '{"error":{"code":"EMAIL_EXISTS","message":"Taken."}}');
      expect([e.code, e.reason], [WincheErrorCode.alreadyExists, 'EMAIL_EXISTS']);
    });

    test('{error: "text"}', () async {
      final e = await failWith(404, '{"error":"No such file."}');
      expect([e.code, e.message], [WincheErrorCode.notFound, 'No such file.']);
    });

    test('problem details', () async {
      final e = await failWith(400, '{"title":"Bad request","detail":"path is required","status":400}');
      expect([e.code, e.message], [WincheErrorCode.invalidArgument, 'path is required']);
    });

    test('anything else', () async {
      final e = await failWith(500, '<html>oops</html>');
      expect(e.code, WincheErrorCode.internal);
    });
  });

  test('interceptors see and can change requests', () async {
    serve((_) => http.Response('{}', 200));
    final seen = <int>[];
    app.http.addInterceptor(_Tag(seen));
    await app.http.send(WincheRequest.get(url));
    expect(sent.single.headers['x-trace'], 'abc');
    expect(seen, [200]);
  });

  test('a streamed body is sent from the start on every try, with progress', () async {
    final bodies = <String>[];
    var calls = 0;
    app.http.useClient(
      MockClient.streaming((request, body) async {
        bodies.add(utf8.decode(await body.toBytes()));
        return http.StreamedResponse(Stream.value(utf8.encode('{}')), ++calls < 2 ? 503 : 200);
      }),
    );
    final progress = <int>[];
    await app.http.send(
      WincheRequest.streamed(
        'PUT',
        url,
        body: () => Stream.fromIterable([utf8.encode('ab'), utf8.encode('cd')]),
        length: 4,
        onSendProgress: (sent, _) => progress.add(sent),
      ),
    );
    expect(bodies, ['abcd', 'abcd']);
    expect(progress, [2, 4, 2, 4]);
  });

  test('stream() hands the body over as it arrives', () async {
    app.http.useClient(
      MockClient.streaming(
        (_, _) async => http.StreamedResponse(
          Stream.fromIterable([
            [1, 2],
            [3],
          ]),
          200,
          contentLength: 3,
        ),
      ),
    );
    final response = await app.http.stream(WincheRequest.get(url));
    expect(response.contentLength, 3);
    expect(await response.body.toList(), [
      [1, 2],
      [3],
    ]);
  });

  test("a request naming a session uses that session's token, and fails once it has ended", () async {
    await signIn();
    final session = app.session!;
    serve((_) => http.Response('{}', 200));
    await app.http.send(WincheRequest.get(url, session: session));
    expect(sent.single.headers['authorization'], 'Bearer t1');
    app.handleIdentityChanged(null);
    await app.settled;
    await expectLater(app.http.send(WincheRequest.get(url, session: session)), throwsA(isA<WincheSessionExpired>()));
  });

  test('an aborted request fails as aborted and is not retried', () async {
    var calls = 0;
    app.http.useClient(_AbortingClient(() => calls++));
    final already = Completer<void>()..complete();
    await expectLater(app.http.send(WincheRequest.get(url, abortTrigger: already.future)),
        throwsA(isA<WincheHttpException>().having((e) => e.code, 'code', WincheErrorCode.cancelled)));
    expect(calls, 1);
  });

  test('an abort mid-body errors the body as aborted', () async {
    final chunks = StreamController<List<int>>();
    app.http.useClient(MockClient.streaming((_, _) async => http.StreamedResponse(chunks.stream, 200)));
    final response = await app.http.stream(WincheRequest.get(url));
    chunks.add([1]);
    chunks.addError(http.RequestAbortedException(url));
    unawaited(chunks.close());
    await expectLater(response.body.toList(), throwsA(isA<WincheHttpException>().having((e) => e.code, 'code', WincheErrorCode.cancelled)));
  });

  test('a dropped connection mid-body is unavailable', () async {
    final chunks = StreamController<List<int>>();
    app.http.useClient(MockClient.streaming((_, _) async => http.StreamedResponse(chunks.stream, 200)));
    final response = await app.http.stream(WincheRequest.get(url));
    chunks.addError(http.ClientException('reset'));
    unawaited(chunks.close());
    await expectLater(response.body.toList(), throwsA(isA<WincheHttpException>().having((e) => e.code, 'code', WincheErrorCode.unavailable)));
  });

  test('a standalone client sends no token unless told which session', () async {
    final standalone = WincheHttp.standalone(client: MockClient((r) async {
      sent.add(r);
      return http.Response('{}', 200);
    }));
    await signIn();
    await standalone.send(WincheRequest.get(url));
    await standalone.send(WincheRequest.get(url, session: app.session));
    expect(sent.map((r) => r.headers['authorization']), [null, 'Bearer t1']);
    standalone.close();
  });
}

/// Fails every request the way a real client does once its abort trigger fired.
final class _AbortingClient extends http.BaseClient {
  _AbortingClient(this.onSend);
  final void Function() onSend;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    onSend();
    throw http.RequestAbortedException(request.url);
  }
}

final class _Tag extends WincheHttpInterceptor {
  _Tag(this.seen);
  final List<int> seen;
  @override
  WincheRequest onRequest(WincheRequest request) => request.withHeaders({'x-trace': 'abc'});
  @override
  void onResponse(WincheRequest request, int status) => seen.add(status);
}
