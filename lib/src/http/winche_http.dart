import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import '../base/winche_app.dart';
import '../models/winche_exception.dart';
import '../models/winche_session.dart';

/// Whether a request carries the signed-in user's token.
enum WincheRequestAuth {
  /// Never: sign-in calls, signed links.
  none,

  /// When someone is signed in; anonymous otherwise.
  ifSignedIn,

  /// Always: throws [WincheUnboundException] when no one is signed in.
  required,
}

/// A request to the Winche server, sent with [WincheHttp.send] or [WincheHttp.stream].
final class WincheRequest {
  /// `GET`, `POST`, …
  final String method;

  /// Where it goes, usually under `app.options!.endpointFor(…)`.
  final Uri url;

  /// Extra headers. `Authorization` is added for you, per [auth].
  final Map<String, String> headers;

  /// Whether the user's token is sent.
  final WincheRequestAuth auth;

  /// Whether sending it twice does no harm, which allows retries.
  final bool idempotent;

  /// How long one try may take, from sending to the response's headers;
  /// [WincheHttp.timeout] when null.
  final Duration? timeout;

  /// Which service sent it (`functions`, `storage`, …), copied into errors.
  final String? service;

  /// Called with the bytes sent so far and the total, while a [body] stream is sent.
  final void Function(int sent, int total)? onSendProgress;

  /// The session whose token is sent, instead of the app's current one: a
  /// service bound to a session passes it, so a request that straddles a user
  /// switch fails with [WincheSessionExpired] rather than carrying the next
  /// user's token.
  final WincheSession? session;

  /// Completing it abandons the request, even mid-body; it then fails with
  /// [WincheErrorCode.cancelled]. For pausing and cancelling transfers.
  final Future<void>? abortTrigger;

  final Object? _body;
  final int? _length;

  WincheRequest._(
    this.method,
    this.url,
    this._body,
    this._length, {
    Map<String, String>? headers,
    this.auth = WincheRequestAuth.ifSignedIn,
    bool? idempotent,
    this.timeout,
    this.service,
    this.onSendProgress,
    this.session,
    this.abortTrigger,
  }) : headers = Map.unmodifiable(headers ?? const {}),
       idempotent = idempotent ?? const {'GET', 'HEAD', 'PUT', 'DELETE', 'OPTIONS'}.contains(method);

  /// A request with no body, or a [json] body, or raw [bytes].
  ///
  /// GET, HEAD, PUT, DELETE and OPTIONS count as [idempotent] unless told otherwise.
  factory WincheRequest(
    String method,
    Uri url, {
    Object? json,
    List<int>? bytes,
    Map<String, String>? headers,
    WincheRequestAuth auth = WincheRequestAuth.ifSignedIn,
    bool? idempotent,
    Duration? timeout,
    String? service,
    WincheSession? session,
    Future<void>? abortTrigger,
  }) {
    assert(json == null || bytes == null, 'Send JSON or bytes, not both.');
    final body = json != null ? utf8.encode(jsonEncode(json)) : bytes;
    return WincheRequest._(
      method,
      url,
      body,
      body?.length,
      headers: {if (json != null) 'content-type': 'application/json', ...?headers},
      auth: auth,
      idempotent: idempotent,
      timeout: timeout,
      service: service,
      session: session,
      abortTrigger: abortTrigger,
    );
  }

  /// A GET.
  factory WincheRequest.get(
    Uri url, {
    Map<String, String>? headers,
    WincheRequestAuth auth = WincheRequestAuth.ifSignedIn,
    bool idempotent = true,
    Duration? timeout,
    String? service,
    WincheSession? session,
    Future<void>? abortTrigger,
  }) => WincheRequest(
    'GET',
    url,
    headers: headers,
    auth: auth,
    idempotent: idempotent,
    timeout: timeout,
    service: service,
    session: session,
    abortTrigger: abortTrigger,
  );

  /// A POST, not retried unless [idempotent].
  factory WincheRequest.post(
    Uri url, {
    Object? json,
    Map<String, String>? headers,
    WincheRequestAuth auth = WincheRequestAuth.ifSignedIn,
    bool idempotent = false,
    Duration? timeout,
    String? service,
    WincheSession? session,
  }) => WincheRequest(
    'POST',
    url,
    json: json,
    headers: headers,
    auth: auth,
    idempotent: idempotent,
    timeout: timeout,
    service: service,
    session: session,
  );

  /// A DELETE.
  factory WincheRequest.delete(
    Uri url, {
    Map<String, String>? headers,
    WincheRequestAuth auth = WincheRequestAuth.ifSignedIn,
    Duration? timeout,
    String? service,
    WincheSession? session,
  }) => WincheRequest('DELETE', url, headers: headers, auth: auth, timeout: timeout, service: service, session: session);

  /// A request whose body is streamed, e.g. a file upload. [body] is called once
  /// per try, so a retry starts again from the first byte; [length] is its size.
  factory WincheRequest.streamed(
    String method,
    Uri url, {
    required Stream<List<int>> Function() body,
    required int length,
    Map<String, String>? headers,
    WincheRequestAuth auth = WincheRequestAuth.ifSignedIn,
    bool? idempotent,
    Duration? timeout,
    String? service,
    void Function(int sent, int total)? onSendProgress,
    WincheSession? session,
    Future<void>? abortTrigger,
  }) => WincheRequest._(
    method,
    url,
    body,
    length,
    headers: headers,
    auth: auth,
    idempotent: idempotent,
    timeout: timeout,
    service: service,
    onSendProgress: onSendProgress,
    session: session,
    abortTrigger: abortTrigger,
  );

  /// A copy with [headers] added, for interceptors.
  WincheRequest withHeaders(Map<String, String> headers) => WincheRequest._(
    method,
    url,
    _body,
    _length,
    headers: {...this.headers, ...headers},
    auth: auth,
    idempotent: idempotent,
    timeout: timeout,
    service: service,
    onSendProgress: onSendProgress,
    session: session,
    abortTrigger: abortTrigger,
  );

  http.BaseRequest _build(String? token, String? appId) {
    final http.BaseRequest request;
    if (_body case final Stream<List<int>> Function() open) {
      final streamed = http.AbortableStreamedRequest(method, url, abortTrigger: abortTrigger)..contentLength = _length;
      _pipe(open(), streamed.sink);
      request = streamed;
    } else {
      request = http.AbortableRequest(method, url, abortTrigger: abortTrigger);
      if (_body case final List<int> bytes) (request as http.Request).bodyBytes = bytes;
    }
    request.headers.addAll(headers);
    if (token != null) request.headers['authorization'] = 'Bearer $token';
    if (appId != null && !request.headers.containsKey('x-winche-app')) request.headers['x-winche-app'] = appId;
    return request;
  }

  void _pipe(Stream<List<int>> source, EventSink<List<int>> sink) {
    var sent = 0;
    final total = _length ?? 0;
    source.listen(
      (chunk) {
        sink.add(chunk);
        sent += chunk.length;
        onSendProgress?.call(sent, total);
      },
      onError: sink.addError,
      onDone: sink.close,
      cancelOnError: true,
    );
  }

  @override
  String toString() => 'WincheRequest($method $url)';
}

/// The server's answer, read in full.
final class WincheResponse {
  /// The status code.
  final int status;

  /// The headers, lower-case names.
  final Map<String, String> headers;

  /// The body.
  final List<int> bodyBytes;

  /// Creates a response.
  WincheResponse(this.status, this.headers, this.bodyBytes);

  /// The body as text.
  String get text => utf8.decode(bodyBytes, allowMalformed: true);

  /// The body decoded from JSON, or null when empty.
  Object? get json => bodyBytes.isEmpty ? null : jsonDecode(text);
}

/// The server's answer, with the body still arriving: for downloads.
final class WincheStreamedResponse {
  /// The status code.
  final int status;

  /// The headers, lower-case names.
  final Map<String, String> headers;

  /// The body's size, when the server said.
  final int? contentLength;

  /// The body. Listen once.
  final Stream<List<int>> body;

  /// Creates a response.
  WincheStreamedResponse(this.status, this.headers, this.contentLength, this.body);
}

/// A request to the Winche server failed: core's own request error, which
/// each package turns into its own exception.
///
/// [code] is the kind from the server's `{error: {code, …}}`, or from the HTTP
/// status when it sent none; [WincheErrorCode.unavailable] when there was no
/// answer, [WincheErrorCode.deadlineExceeded] when none came in time,
/// [WincheErrorCode.cancelled] when the request's `abortTrigger` fired.
class WincheHttpException extends WincheException {
  /// Creates an exception.
  const WincheHttpException(super.code, super.message, {this.reason, this.status, this.service, this.details = const {}});

  /// The server's more precise code, when it sent one (`INVALID_CREDENTIALS`,
  /// `invalid-query`, …).
  final String? reason;

  /// The HTTP status, or null when there was no answer.
  final int? status;

  /// Which service sent the request.
  final String? service;

  /// The error's `details`.
  final Map<String, Object?> details;

  /// Reads a failed response: `{error: {code, message, reason?, details?}}`, as
  /// every Winche API answers; otherwise its message and the HTTP status.
  factory WincheHttpException.fromResponse(WincheResponse response, {String? service}) {
    Object? body;
    try {
      body = response.json;
    } on FormatException {
      body = null;
    }
    final byStatus = WincheErrorCode.fromHttpStatus(response.status);
    if (body is Map<String, Object?>) {
      final error = body['error'];
      if (error is Map<String, Object?>) {
        final named = error['code'] as String?;
        final code = WincheErrorCode.tryParse(named);
        return WincheHttpException(
          code ?? byStatus,
          error['message'] as String? ?? 'The request failed (${response.status}).',
          // A code outside the shared list is kept as the reason.
          reason: error['reason'] as String? ?? (code == null ? named : null),
          status: response.status,
          service: service,
          details: switch (error['details']) {
            final Map<String, Object?> d => d,
            _ => const {},
          },
        );
      }
      if (error is String) return WincheHttpException(byStatus, error, status: response.status, service: service);
      if ((body['detail'] ?? body['title']) case final String text) {
        return WincheHttpException(byStatus, text, status: response.status, service: service);
      }
    }
    final text = response.text.trim();
    return WincheHttpException(
      byStatus,
      text.isNotEmpty && text.length < 300 ? text : 'The server answered ${response.status}.',
      status: response.status,
      service: service,
    );
  }

  @override
  String toString() =>
      'WincheHttpException(${service == null ? '' : '$service, '}${code.wireName}${reason == null ? '' : '/$reason'}${status == null ? '' : ', $status'}): $message';
}

/// Sees every request before it is sent and every response, e.g. for logging,
/// tracing, or an extra header.
abstract class WincheHttpInterceptor {
  /// The request to send instead of [request]; [request] itself to change nothing.
  FutureOr<WincheRequest> onRequest(WincheRequest request) => request;

  /// Called with each answer (including ones that will be retried).
  FutureOr<void> onResponse(WincheRequest request, int status) {}

  /// Called when a try fails with no answer.
  FutureOr<void> onError(WincheRequest request, Object error) {}
}

/// Every Winche package's calls to the server: adds the user's token, refreshes
/// it once on a 401, retries what is safe to retry, and turns failures into
/// [WincheHttpException].
///
/// One per app, as `app.http`.
final class WincheHttp {
  final WincheApp? _app;
  http.Client _client;
  final List<WincheHttpInterceptor> _interceptors = [];

  /// How long one try may take, unless the request says otherwise.
  Duration timeout = const Duration(seconds: 30);

  /// How many times an idempotent request is tried in all.
  int maxAttempts = 3;

  /// The first gap between tries; it doubles each time, with jitter.
  Duration retryDelay = const Duration(milliseconds: 300);

  final Random _random = Random();

  Future<String?>? _refreshing;
  ({WincheSession session, String? from, String? to})? _refreshed;

  /// Creates the app's client. Use `app.http` rather than this.
  @internal
  WincheHttp(WincheApp this._app, {http.Client? client}) : _client = client ?? http.Client();

  /// A client of no app: for requests that carry no token or name their own
  /// `session`, such as transfers to signed links. Close it when done.
  WincheHttp.standalone({http.Client? client}) : _app = null, _client = client ?? http.Client();

  /// Sends requests through [client] from now on, e.g. a `MockClient` in tests.
  void useClient(http.Client client) {
    _client.close();
    _client = client;
  }

  /// Adds an interceptor; they run in the order added.
  void addInterceptor(WincheHttpInterceptor interceptor) => _interceptors.add(interceptor);

  /// Removes an interceptor.
  bool removeInterceptor(WincheHttpInterceptor interceptor) => _interceptors.remove(interceptor);

  /// Sends [request] and reads the answer in full. Throws [WincheHttpException]
  /// for anything but a 2xx.
  Future<WincheResponse> send(WincheRequest request) async {
    final streamed = await stream(request);
    final bytes = await _collect(streamed.body);
    return WincheResponse(streamed.status, streamed.headers, bytes);
  }

  /// Whether a request has been sent; `WincheApp.useEmulator` refuses after one.
  @internal
  bool get hasSent => _hasSent;
  bool _hasSent = false;

  /// Sends [request] and hands back the body as it arrives, for downloads.
  /// Throws [WincheHttpException] for anything but a 2xx.
  Future<WincheStreamedResponse> stream(WincheRequest request) async {
    _hasSent = true;
    for (final interceptor in _interceptors) {
      request = await interceptor.onRequest(request);
    }
    final session = switch (request.auth) {
      WincheRequestAuth.none => null,
      WincheRequestAuth.ifSignedIn => request.session ?? _app?.session,
      WincheRequestAuth.required => request.session ?? _app?.session ?? (throw WincheUnboundException()),
    };
    var token = session == null ? null : await session.token();
    if (token == null && request.auth == WincheRequestAuth.required) throw WincheUnboundException();
    var refreshed = false;
    for (var attempt = 1; ; attempt++) {
      final http.StreamedResponse response;
      try {
        response = await _client.send(request._build(token, _app?.options?.appId)).timeout(request.timeout ?? timeout);
      } catch (e) {
        for (final interceptor in _interceptors) {
          await interceptor.onError(request, e);
        }
        if (e is http.RequestAbortedException) throw _abortedError(request);
        final failure = e is TimeoutException
            ? WincheHttpException(
                WincheErrorCode.deadlineExceeded,
                'No answer from ${request.url} within ${(request.timeout ?? timeout).inSeconds} s.',
                service: request.service,
              )
            : WincheHttpException(
                WincheErrorCode.unavailable,
                "Couldn't reach ${request.url}: ${e is http.ClientException ? e.message : e}",
                service: request.service,
              );
        if (request.idempotent && attempt < maxAttempts) {
          await _wait(attempt, null);
          if (await _hasFired(request.abortTrigger)) throw _abortedError(request);
          continue;
        }
        throw failure;
      }
      for (final interceptor in _interceptors) {
        await interceptor.onResponse(request, response.statusCode);
      }
      final status = response.statusCode;
      if (status == 401 && session != null && !refreshed) {
        await response.stream.drain<void>();
        token = await _refresh(session, token);
        refreshed = true;
        attempt--; // the refreshed try doesn't count as a retry
        continue;
      }
      if (request.idempotent && attempt < maxAttempts && (status == 502 || status == 503 || status == 504)) {
        await response.stream.drain<void>();
        await _wait(attempt, response.headers['retry-after']);
        continue;
      }
      if (status < 200 || status >= 300) {
        final body = WincheResponse(status, response.headers, await _collect(response.stream));
        throw WincheHttpException.fromResponse(body, service: request.service);
      }
      return WincheStreamedResponse(
        status,
        response.headers,
        response.contentLength,
        response.stream.handleError(
          (Object e) => throw e is http.RequestAbortedException
              ? _abortedError(request)
              : WincheHttpException(
                  WincheErrorCode.unavailable,
                  'The connection to ${request.url} dropped: ${e is http.ClientException ? e.message : e}',
                  service: request.service,
                ),
          test: (e) => e is http.ClientException,
        ),
      );
    }
  }

  static WincheHttpException _abortedError(WincheRequest request) =>
      WincheHttpException(WincheErrorCode.cancelled, 'The request to ${request.url} was abandoned.', service: request.service);

  static Future<bool> _hasFired(Future<void>? trigger) async {
    if (trigger == null) return false;
    var fired = false;
    unawaited(trigger.then((_) => fired = true));
    await Future<void>.delayed(Duration.zero);
    return fired;
  }

  /// One refresh for every request that was refused the same token at once.
  Future<String?> _refresh(WincheSession session, String? refused) {
    final done = _refreshed;
    if (done != null && identical(done.session, session) && done.from == refused) return Future.value(done.to);
    return _refreshing ??= session
        .token(forceRefresh: true)
        .then((fresh) {
          _refreshed = (session: session, from: refused, to: fresh);
          return fresh;
        })
        .whenComplete(() => _refreshing = null);
  }

  Future<void> _wait(int attempt, String? retryAfter) {
    final asked = int.tryParse(retryAfter ?? '');
    if (asked != null) return Future.delayed(Duration(seconds: min(asked, 10)));
    final base = retryDelay * pow(2, attempt - 1);
    return Future.delayed(base * (0.5 + _random.nextDouble()));
  }

  static Future<List<int>> _collect(Stream<List<int>> body) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in body) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  /// Closes the connection pool. The app closes its own when disposed; close a
  /// standalone client when done with it.
  void close() => _client.close();
}
