/// SPEC-024 Phase 1, Step 1 — what a call to the ERP can come back as.
///
/// 🔴 **The distinction this type exists for: a 401 is not a 403.**
///
/// A **401** means the token is no longer accepted — the session is over, and
/// the app must sign the user out and say so. A **403** means *this job is not
/// yours*, which Phase 0 returns **deliberately** for a work order assigned to
/// another technician. Treating the second as the first would sign a man out
/// for tapping the wrong row.
///
/// The decision is made here, in the service layer, rather than in a screen —
/// otherwise every screen would have to remember it, and one of them would not.
enum ApiErrorKind {
  /// The request never reached the server, or the reply was unreadable.
  network,

  /// 401 — the session is over. The caller signs the user out.
  sessionExpired,

  /// 403 — the caller is authenticated and not entitled to this row.
  forbidden,

  /// 422 — the server refused the request and said why, per field.
  refused,

  /// Anything else, including 500.
  server,
}

sealed class ApiResult<T> {
  const ApiResult();
}

final class ApiSuccess<T> extends ApiResult<T> {
  const ApiSuccess(this.data);

  final T data;
}

final class ApiFailure<T> extends ApiResult<T> {
  const ApiFailure(this.kind, this.message, {this.fieldErrors});

  final ApiErrorKind kind;

  /// Shown to the user as-is, so it is written for them and never a status
  /// code or an exception's `toString()`.
  final String message;

  /// The ERP answers a domain refusal as `{"errors": {"<field>": ["…"]}}` —
  /// the shape SPEC-018 Phase 10 Step 2 chose so one mechanism serves a
  /// browser and a phone. Null unless [kind] is [ApiErrorKind.refused].
  final Map<String, String>? fieldErrors;
}
