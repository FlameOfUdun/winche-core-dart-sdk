/// One contract expectation that an implementation did not meet.
final class WincheContractFailure {
  /// The behaviour that was checked.
  final String check;

  /// What went wrong, in enough detail to act on.
  final String detail;

  /// Creates a failure.
  const WincheContractFailure(this.check, this.detail);

  @override
  String toString() => '$check\n    $detail';
}

/// The outcome of running a contract suite against an implementation.
final class WincheContractReport {
  /// Names of the checks that held.
  final List<String> passed;

  /// Every check that did not.
  final List<WincheContractFailure> failures;

  /// Checks that could not run because the caller did not supply the driver
  /// they need, with the reason.
  final Map<String, String> skipped;

  /// Creates a report.
  const WincheContractReport({required this.passed, required this.failures, required this.skipped});

  /// Whether the implementation upholds every check that ran.
  bool get isSuccess => failures.isEmpty;

  @override
  String toString() {
    final buffer = StringBuffer()
      ..writeln('${passed.length} passed, ${failures.length} failed, ${skipped.length} skipped');
    for (final name in passed) {
      buffer.writeln('  PASS  $name');
    }
    for (final entry in skipped.entries) {
      buffer.writeln('  SKIP  ${entry.key} — ${entry.value}');
    }
    for (final failure in failures) {
      buffer.writeln('  FAIL  $failure');
    }
    return buffer.toString();
  }
}

/// Accumulates results while a contract suite runs.
final class ContractRecorder {
  final List<String> _passed = [];
  final List<WincheContractFailure> _failures = [];
  final Map<String, String> _skipped = {};

  /// Runs [body] under [check], recording whether it held.
  ///
  /// A thrown error is a failure rather than an abort, so one broken behaviour
  /// does not hide the rest.
  Future<void> expect(String check, Future<void> Function() body) async {
    try {
      await body();
      _passed.add(check);
    } on _ContractViolation catch (violation) {
      _failures.add(WincheContractFailure(check, violation.message));
    } catch (error) {
      _failures.add(WincheContractFailure(check, 'threw $error'));
    }
  }

  /// Records that [check] could not run, and why.
  void skip(String check, String reason) => _skipped[check] = reason;

  /// Fails the check in progress.
  Never fail(String detail) => throw _ContractViolation(detail);

  /// Fails the check in progress unless [condition] holds.
  void require(bool condition, String detail) {
    if (!condition) fail(detail);
  }

  /// The accumulated result.
  WincheContractReport get report =>
      WincheContractReport(passed: _passed, failures: _failures, skipped: Map.unmodifiable(_skipped));
}

final class _ContractViolation implements Exception {
  final String message;
  _ContractViolation(this.message);
}
