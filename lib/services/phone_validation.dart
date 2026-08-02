/// Client-side twin of the backend's `phone_validation.ts`, so a bad mobile
/// number is caught in the form instead of coming back as a 400.
///
/// Product rule (Indian mobile): a guest/staff mobile number is EXACTLY 10
/// digits. Nothing shorter, nothing longer. Formatting noise (spaces, dashes,
/// brackets, a leading "+91" / "0091" / "0") is stripped before the length is
/// checked, so a number pasted from a contacts app still validates.
///
/// Deliberately NOT enforced: a leading 6-9 series check — neither client nor
/// server ever had one, and inventing it here would start rejecting numbers the
/// product accepted yesterday.
///
/// Scope: fields where a PERSON's mobile is captured. Business phone fields
/// (restaurant profile, outlet, vendor) are intentionally excluded — a landline
/// with an STD code is legitimately 11+ digits, and the backend accepts those.
library;

import 'package:flutter/services.dart';

/// The one message shown for a bad mobile number — byte-for-byte the backend's
/// 400 body (`{"error":"Enter a 10-digit mobile number"}`), so the app and the
/// server never disagree about what is wrong.
const String mobile10Error = 'Enter a 10-digit mobile number';

/// Strip formatting and return the number only when it is exactly 10 digits.
///
/// Accepts an Indian country prefix and/or a trunk 0 before the 10 digits
/// ("+91 98765 43210", "0091-9876543210", "09876543210") and returns the bare
/// 10-digit form. Anything else — 9 digits, 11 digits, letters only, empty —
/// returns null.
String? normalizeMobile10(String? raw) {
  if (raw == null) return null;
  var digits = raw.replaceAll(RegExp(r'[^0-9]'), '');
  // Peel a country code / trunk prefix so the *subscriber* number is measured.
  // Only ever peels down TO 10 digits — never below, so a 9-digit number stays
  // 9 digits and is rejected.
  if (digits.length == 13 && digits.startsWith('0091')) digits = digits.substring(4);
  if (digits.length == 12 && digits.startsWith('91')) digits = digits.substring(2);
  if (digits.length == 11 && digits.startsWith('0')) digits = digits.substring(1);
  return digits.length == 10 ? digits : null;
}

/// True when [raw] is a valid 10-digit mobile number.
bool isMobile10(String? raw) => normalizeMobile10(raw) != null;

/// Validator for a REQUIRED mobile field: null when valid, else [mobile10Error].
/// Shape matches `TextFormField.validator`.
String? validateMobile10(String? raw) => isMobile10(raw) ? null : mobile10Error;

/// Validator for an OPTIONAL mobile field: blank is fine, but anything typed
/// must be exactly 10 digits.
String? validateOptionalMobile10(String? raw) {
  final s = (raw ?? '').trim();
  if (s.isEmpty) return null;
  return isMobile10(s) ? null : mobile10Error;
}

/// Input formatters for a mobile field: digits only, hard-capped at 10, so the
/// field cannot even hold an invalid length.
List<TextInputFormatter> mobile10Formatters() => <TextInputFormatter>[
      FilteringTextInputFormatter.digitsOnly,
      LengthLimitingTextInputFormatter(10),
    ];
