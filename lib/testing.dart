/// Conformance suites and test doubles for packages that implement a Winche
/// service.
///
/// Core guarantees *sequencing* — that hooks are awaited, ordered and isolated.
/// It cannot guarantee that an implementation actually swaps when told to, or
/// that an auth backend reports a dropped connection as a failure rather than a
/// sign-out. Those behaviours are what make every Winche service interchangeable,
/// and this library is what turns them from documentation into a test.
///
/// Deliberately free of any test-framework dependency: a suite returns a
/// [WincheContractReport] rather than calling `expect` itself, so `winche_core`
/// stays a `meta`-only package and you assert with whatever framework you use.
///
/// ```dart
/// import 'package:test/test.dart';
/// import 'package:winche_core/testing.dart';
///
/// test('honours the service contract', () async {
///   final report = await WincheServiceContract.check(create: MyDatabase.new);
///   expect(report.isSuccess, isTrue, reason: report.toString());
/// });
/// ```
library;

export 'src/testing/auth_contract.dart';
export 'src/testing/contract_report.dart' show WincheContractFailure, WincheContractReport;
export 'src/testing/scripted_auth_service.dart';
export 'src/testing/service_contract.dart';
