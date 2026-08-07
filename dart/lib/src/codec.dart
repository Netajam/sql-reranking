/// Turning a rank's continued-fraction terms into a sortable string, and back.
///
/// A rank is a positive rational, and every positive rational is a node of the
/// Stern-Brocot tree reached by a unique path of L and R moves. That path is
/// runs — some R's, then some L's, then R's again — and the run lengths are the
/// continued-fraction terms. Encoding *terms* rather than *moves* is what keeps
/// the key short: a rank sitting a trillion moves down a spine is one term.
///
/// Ordering falls out of two rules:
///
///  * More R moves descend toward larger values, more L moves toward smaller.
///    So terms at even positions sort ascending and terms at odd positions sort
///    descending — every other code is complemented.
///  * A key that stops early would be a prefix of a longer one and would always
///    sort first, which is wrong exactly half the time. A terminator fixes it.
///
/// Codes are self-delimiting: `d - 1` leading '9's announce a `d`-digit base-9
/// numeral. Since base-9 digits never reach '9', the prefix is unambiguous, and
/// because the code is prefix-free a comparison is always settled inside the
/// term where two keys first differ.
///
/// Digits only, so no collation can reorder a key.
library;

const int _base = 9;

/// Encodes one term. Larger terms sort later.
String _ascending(int term) {
  assert(term >= 0);
  var digits = '';
  var value = term;
  do {
    digits = '${value % _base}$digits';
    value ~/= _base;
  } while (value != 0);
  return '9' * (digits.length - 1) + digits;
}

/// Encodes one term so that larger terms sort *earlier*.
String _descending(int term) => _complement(_ascending(term));

String _complement(String code) {
  final out = StringBuffer();
  for (var i = 0; i < code.length; i++) {
    out.writeCharCode(0x39 - (code.codeUnitAt(i) - 0x30));
  }
  return out.toString();
}

/// Encodes a term for [position], choosing the direction from its parity.
String encodeTerm(int term, int position) =>
    position.isEven ? _ascending(term) : _descending(term);

/// The full key for a term vector, terminator included.
String encodeKey(List<int> terms) {
  final out = StringBuffer();
  for (var i = 0; i < terms.length; i++) {
    out.write(encodeTerm(terms[i], i));
  }
  // The terminator is a zero term at the next position — it makes a short key
  // sort correctly against any longer key that shares its prefix.
  out.write(encodeTerm(0, terms.length));
  return out.toString();
}

/// Recovers the term vector from a key, terminator dropped.
///
/// Throws [FormatException] on anything this codec did not produce.
List<int> decodeKey(String key) {
  final terms = <int>[];
  var at = 0;
  var position = 0;

  while (at < key.length) {
    final ascending = position.isEven;
    // Leading markers announce the numeral's length: '9's when ascending, and
    // their complement '0's when descending.
    final marker = ascending ? 0x39 : 0x30;
    var run = 0;
    while (at + run < key.length && key.codeUnitAt(at + run) == marker) {
      run++;
    }

    final start = at + run;
    final end = start + run + 1;
    if (end > key.length) {
      throw FormatException('truncated term at $at', key, at);
    }

    var value = 0;
    for (var i = start; i < end; i++) {
      final digit = ascending
          ? key.codeUnitAt(i) - 0x30
          : 0x39 - key.codeUnitAt(i);
      if (digit < 0 || digit >= _base) {
        throw FormatException('digit out of range at $i', key, i);
      }
      value = value * _base + digit;
    }

    terms.add(value);
    at = end;
    position++;
  }

  if (terms.isEmpty) throw FormatException('empty key', key);
  // The last term is the terminator, which carries no path.
  return terms.sublist(0, terms.length - 1);
}
