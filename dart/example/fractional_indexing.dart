/// A faithful Dart port of the reference fractional-indexing implementation,
/// used as the opponent in `compare.dart`.
///
/// Ported from https://github.com/rocicorp/fractional-indexing (License: CC0,
/// no rights reserved), itself based on David Greenspan's
/// https://observablehq.com/@dgreensp/implementing-fractional-indexing — the
/// algorithm behind Figma's ordering keys.
///
/// This is included so the comparison runs against the real thing. An earlier
/// draft used only the `midpoint` core and omitted the integer-part machinery,
/// which would have handicapped it exactly where the comparison is most
/// interesting: appending past the end, where a real key increments a counter
/// instead of lengthening a fraction.
///
/// A key is an integer part — whose first character is a "head" encoding that
/// part's own length — followed by an optional fractional tail. The invariant
/// that keeps the scheme dense is that no key may end in the smallest digit;
/// break it and there is genuinely nothing between "a" and "a0".
library;

const String base62Digits =
    '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';

/// Head markers: A-Z are the long ("negative") integer parts, a-z the positive.
final String base52Digits = base62Digits.substring(10);

/// A string strictly between [a] and [b], neither of which may end in the
/// smallest digit. [b] null means an open upper end.
String _midpoint(String a, String? b, String digits) {
  final zero = digits[0];
  if (b != null && a.compareTo(b) >= 0) {
    throw ArgumentError('$a >= $b');
  }
  if (a.isNotEmpty && a.endsWith(zero)) {
    throw ArgumentError('trailing zero: $a');
  }
  if (b != null && b.isNotEmpty && b.endsWith(zero)) {
    throw ArgumentError('trailing zero: $b');
  }

  if (b != null && b.isNotEmpty) {
    // Strip the longest common prefix, padding `a` with zeros as we go. `b`
    // needs no padding: it cannot run out before `a` while they still agree.
    var n = 0;
    while (n < b.length && (n < a.length ? a[n] : zero) == b[n]) {
      n++;
    }
    if (n > 0) {
      return b.substring(0, n) +
          _midpoint(n < a.length ? a.substring(n) : '', b.substring(n), digits);
    }
  }

  // The first digits differ (or one side has run out).
  final digitA = a.isNotEmpty ? digits.indexOf(a[0]) : 0;
  final digitB =
      (b != null && b.isNotEmpty) ? digits.indexOf(b[0]) : digits.length;

  if (digitB - digitA > 1) {
    return digits[(0.5 * (digitA + digitB)).round()];
  }
  // The first digits are consecutive, so descend into the tail.
  if (b != null && b.length > 1) {
    return b.substring(0, 1);
  }
  return digits[digitA] +
      _midpoint(a.isNotEmpty ? a.substring(1) : '', null, digits);
}

int _integerLength(String head, String intDigits) {
  final i = intDigits.indexOf(head);
  if (i < 0) throw ArgumentError('invalid order key head: $head');
  final half = intDigits.length ~/ 2;
  return i < half ? half - i + 1 : i - half + 2;
}

void _validateInteger(String x, String intDigits) {
  if (x.length != _integerLength(x[0], intDigits)) {
    throw ArgumentError('invalid integer part of order key: $x');
  }
}

String _integerPart(String key, String intDigits) {
  final length = _integerLength(key[0], intDigits);
  if (length > key.length) throw ArgumentError('invalid order key: $key');
  return key.substring(0, length);
}

bool _isSmallestInteger(String key, String digits, String intDigits) =>
    key == intDigits[0] + digits[0] * (intDigits.length ~/ 2);

void _validateOrderKey(String key, String digits, String intDigits) {
  if (_isSmallestInteger(key, digits, intDigits)) {
    throw ArgumentError('invalid order key: $key');
  }
  final integer = _integerPart(key, intDigits);
  final fraction = key.substring(integer.length);
  if (fraction.isNotEmpty && fraction.endsWith(digits[0])) {
    throw ArgumentError('invalid order key: $key');
  }
}

/// Null when [x] is already the largest integer part.
String? _incrementInteger(String x, String digits, String intDigits) {
  _validateInteger(x, intDigits);
  final head = x[0];
  final zero = digits[0];

  var trailing = '';
  for (var i = x.length - 1; i >= 1; i--) {
    final d = digits.indexOf(x[i]) + 1;
    if (d == digits.length) {
      trailing = zero + trailing;
    } else {
      return head + x.substring(1, i) + digits[d] + trailing;
    }
  }

  // The whole digit run carried; move the head one step and resize to match.
  final headIndex = intDigits.indexOf(head);
  if (headIndex == intDigits.length - 1) return null;
  final nextHead = intDigits[headIndex + 1];
  final delta =
      _integerLength(nextHead, intDigits) - _integerLength(head, intDigits);
  return nextHead +
      (delta > 0
          ? trailing + zero
          : delta < 0
              ? trailing.substring(1)
              : trailing);
}

/// Null when [x] is already the smallest integer part.
String? _decrementInteger(String x, String digits, String intDigits) {
  _validateInteger(x, intDigits);
  final head = x[0];
  final last = digits[digits.length - 1];

  var trailing = '';
  for (var i = x.length - 1; i >= 1; i--) {
    final d = digits.indexOf(x[i]) - 1;
    if (d == -1) {
      trailing = last + trailing;
    } else {
      return head + x.substring(1, i) + digits[d] + trailing;
    }
  }

  final headIndex = intDigits.indexOf(head);
  if (headIndex == 0) return null;
  final prevHead = intDigits[headIndex - 1];
  final delta =
      _integerLength(prevHead, intDigits) - _integerLength(head, intDigits);
  return prevHead +
      (delta > 0
          ? trailing + last
          : delta < 0
              ? trailing.substring(1)
              : trailing);
}

/// An order key sorting strictly between [a] and [b]; null means an open end.
String generateKeyBetween(String? a, String? b,
    {String digits = base62Digits, String? intDigits}) {
  final heads = intDigits ?? base52Digits;

  if (a != null) _validateOrderKey(a, digits, heads);
  if (b != null) _validateOrderKey(b, digits, heads);
  if (a != null && b != null && a.compareTo(b) > 0) {
    final swap = a;
    a = b;
    b = swap;
  }

  if (a == null) {
    if (b == null) {
      // The shortest positive head, followed by a zero digit: "a0".
      return heads[heads.length ~/ 2] + digits[0];
    }
    final ib = _integerPart(b, heads);
    final fb = b.substring(ib.length);
    if (_isSmallestInteger(ib, digits, heads)) {
      return ib + _midpoint('', fb, digits);
    }
    if (ib.compareTo(b) < 0) return ib;
    final decremented = _decrementInteger(ib, digits, heads);
    if (decremented == null) throw StateError('cannot decrement any more');
    return decremented;
  }

  if (b == null) {
    final ia = _integerPart(a, heads);
    final fa = a.substring(ia.length);
    final incremented = _incrementInteger(ia, digits, heads);
    return incremented ?? ia + _midpoint(fa, null, digits);
  }

  final ia = _integerPart(a, heads);
  final fa = a.substring(ia.length);
  final ib = _integerPart(b, heads);
  final fb = b.substring(ib.length);
  if (ia == ib) return ia + _midpoint(fa, fb, digits);

  final incremented = _incrementInteger(ia, digits, heads);
  if (incremented == null) throw StateError('cannot increment any more');
  if (incremented.compareTo(b) < 0) return incremented;
  return ia + _midpoint(fa, null, digits);
}

/// [n] distinct keys in ascending order, spread between [a] and [b].
List<String> generateNKeysBetween(String? a, String? b, int n,
    {String digits = base62Digits, String? intDigits}) {
  if (n == 0) return [];
  if (n == 1) {
    return [generateKeyBetween(a, b, digits: digits, intDigits: intDigits)];
  }

  if (b == null) {
    var current = generateKeyBetween(a, b, digits: digits, intDigits: intDigits);
    final out = [current];
    for (var i = 0; i < n - 1; i++) {
      current =
          generateKeyBetween(current, b, digits: digits, intDigits: intDigits);
      out.add(current);
    }
    return out;
  }
  if (a == null) {
    var current = generateKeyBetween(a, b, digits: digits, intDigits: intDigits);
    final out = [current];
    for (var i = 0; i < n - 1; i++) {
      current =
          generateKeyBetween(a, current, digits: digits, intDigits: intDigits);
      out.add(current);
    }
    return out.reversed.toList();
  }

  final mid = n ~/ 2;
  final middle = generateKeyBetween(a, b, digits: digits, intDigits: intDigits);
  return [
    ...generateNKeysBetween(a, middle, mid, digits: digits, intDigits: intDigits),
    middle,
    ...generateNKeysBetween(middle, b, n - mid - 1,
        digits: digits, intDigits: intDigits),
  ];
}
