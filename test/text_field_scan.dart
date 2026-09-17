import 'dart:io';

/// A reader for the app's own source, shared by the item 3 (2.0.1) guards
/// (test/order_search_clear_test.dart and
/// test/row_remove_keeps_fields_in_step_test.dart). Not a test itself: the
/// runner only picks up `*_test.dart`.
///
/// Both guards ask the same kind of question: where is a text field's text
/// kept, and can the buttons around it reach it? A regex over the raw file
/// answers that badly. It matches the fixes' own comments, it only sees an
/// argument where the regex expected it (`TextFormField(\s*initialValue:`
/// missed `TextFormField(key: k, initialValue: x)`), and it cannot say which
/// widget a field sits inside. So this reads the source the way the compiler
/// would, as far as brackets go:
///
///   * comments are blanked (offsets and line numbers kept), string literals
///     and their `${...}` parts are stepped over, so a `(` or `,` inside text
///     never counts;
///   * every bracket is paired with its close and with the bracket around it;
///   * a call's top-level NAMED arguments are read wherever they fall;
///   * a field's key is the nearest `key:` at or above it: its own, else the
///     closest enclosing call that has one.
///
/// It is not a parser. It does not know what a widget is, only a name followed
/// by `(`; that is enough for these guards, and each of them also checks the
/// scan found what it should (a field count, a pinned inventory), so a reader
/// that silently saw nothing fails loudly.
class DartSource {
  DartSource._(this.path, this.code, this._close, this._parent, this._stringEnd);

  /// `lib/...`, forward slashes.
  final String path;

  /// The file with every comment replaced by spaces (newlines kept).
  final String code;

  /// Open bracket offset → the offset just past its matching close.
  final Map<int, int> _close;

  /// Open bracket offset → the offset of the bracket around it (-1 at the top).
  final Map<int, int> _parent;

  /// String literal start (its first quote) → the offset just past its end.
  final Map<int, int> _stringEnd;

  static DartSource read(File file) {
    final path = file.path.replaceAll('\\', '/');
    return DartSource._lex(path.substring(path.indexOf('lib/')), file.readAsStringSync());
  }

  factory DartSource._lex(String path, String src) {
    final out = StringBuffer();
    final close = <int, int>{};
    final parent = <int, int>{};
    final stringEnd = <int, int>{};
    // One frame per open bracket or string; an interpolation's `{` is a
    // bracket frame above its string's, so its `}` hands control back to it.
    final stack = <_Frame>[];
    int enclosing() {
      for (var k = stack.length - 1; k >= 0; k--) {
        if (!stack[k].isString) return stack[k].at;
      }
      return -1;
    }

    var i = 0;
    while (i < src.length) {
      final c = src[i];
      final top = stack.isEmpty ? null : stack.last;
      if (top != null && top.isString) {
        if (!top.raw && c == r'\' && i + 1 < src.length) {
          out.write(src.substring(i, i + 2));
          i += 2;
          continue;
        }
        final quote = top.triple ? top.quote * 3 : top.quote;
        if (src.startsWith(quote, i)) {
          out.write(quote);
          i += quote.length;
          stack.removeLast();
          stringEnd[top.at] = i;
          continue;
        }
        if (!top.raw && c == r'$' && i + 1 < src.length && src[i + 1] == '{') {
          out.write(r'${');
          parent[i + 1] = enclosing();
          stack.add(_Frame.bracket(i + 1));
          i += 2;
          continue;
        }
        out.write(c);
        i++;
        continue;
      }
      // Code.
      if (src.startsWith('//', i)) {
        final end = src.indexOf('\n', i);
        final stop = end < 0 ? src.length : end;
        out.write(' ' * (stop - i));
        i = stop;
        continue;
      }
      if (src.startsWith('/*', i)) {
        final end = src.indexOf('*/', i + 2);
        final stop = end < 0 ? src.length : end + 2;
        out.write(src.substring(i, stop).replaceAll(RegExp(r'[^\n]'), ' '));
        i = stop;
        continue;
      }
      if (c == "'" || c == '"') {
        final raw = i > 0 && src[i - 1] == 'r' && (i < 2 || !RegExp(r'\w').hasMatch(src[i - 2]));
        final triple = src.startsWith(c * 3, i);
        stack.add(_Frame.string(i, c, triple: triple, raw: raw));
        out.write(triple ? c * 3 : c);
        i += triple ? 3 : 1;
        continue;
      }
      if (c == '(' || c == '[' || c == '{') {
        parent[i] = enclosing();
        stack.add(_Frame.bracket(i));
      } else if (c == ')' || c == ']' || c == '}') {
        if (stack.isNotEmpty && !stack.last.isString) {
          close[stack.removeLast().at] = i + 1;
        }
      }
      out.write(c);
      i++;
    }
    return DartSource._(path, out.toString(), close, parent, stringEnd);
  }

  int lineOf(int offset) => '\n'.allMatches(code.substring(0, offset)).length + 1;

  /// The top-level named arguments of the call whose `(` is at [open]
  /// (name → source text, whitespace collapsed). Positional ones are skipped.
  Map<String, String> namedArgs(int open) {
    final end = _close[open]! - 1;
    final parts = <String>[];
    var from = open + 1;
    var j = open + 1;
    while (j < end) {
      final skip = _close[j] ?? _stringEnd[j];
      if (skip != null) {
        j = skip;
        continue;
      }
      if (code[j] == ',') {
        parts.add(code.substring(from, j));
        from = j + 1;
      }
      j++;
    }
    parts.add(code.substring(from, end));
    final named = <String, String>{};
    for (final p in parts) {
      final m = RegExp(r'^\s*(\w+)\s*:([\s\S]*)$').firstMatch(p);
      if (m != null) named[m.group(1)!] = m.group(2)!.trim().replaceAll(RegExp(r'\s+'), ' ');
    }
    return named;
  }

  /// Every call to one of [names] in code (not in a comment or a string),
  /// with its named arguments.
  Iterable<Call> calls(Set<String> names) sync* {
    final ctor = RegExp('(?<![\\w.])(${names.join('|')})\\s*\\(');
    for (final m in ctor.allMatches(code)) {
      final open = m.end - 1;
      if (!_close.containsKey(open)) continue; // inside a string
      yield Call._(this, m.group(1)!, m.start, open);
    }
  }

  /// The body of a no-argument function or method declared in this file — the
  /// `{ ... }` block or the `=> ...;` expression — or null. Used to follow a
  /// tear-off (`onClear: _clearSearch`) to what it does.
  String? bodyOf(String name) {
    for (final m in RegExp('(?<![\\w.])${RegExp.escape(name)}\\s*\\(\\s*\\)\\s*(async\\s*)?(\\{|=>)').allMatches(code)) {
      final at = m.end - m.group(2)!.length;
      if (code[at] == '{') {
        final end = _close[at];
        if (end != null) return code.substring(at, end);
      } else {
        final end = code.indexOf(';', at);
        if (end > 0) return code.substring(at, end + 1);
      }
    }
    return null;
  }

  /// The innermost call whose argument list holds [offset], or null when that
  /// bracket is not a call's (a list, a block, or a `(` with no name before it).
  Call? callAround(int offset) {
    for (var j = offset - 1; j >= 0; j--) {
      final end = _close[j];
      if (end == null || end <= offset) continue;
      if (code[j] != '(') return null;
      var k = j;
      while (k > 0 && code[k - 1].trim().isEmpty) {
        k--;
      }
      final nameEnd = k;
      while (k > 0 && RegExp(r'\w').hasMatch(code[k - 1])) {
        k--;
      }
      return k == nameEnd ? null : Call._(this, code.substring(k, nameEnd), k, j);
    }
    return null;
  }
}

class Call {
  Call._(this.source, this.name, this.start, this.open);

  final DartSource source;
  final String name;
  final int start;
  final int open;

  late final Map<String, String> args = source.namedArgs(open);

  /// The call's whole argument text (comments blanked).
  String get argText => source.code.substring(open + 1, source._close[open]! - 1);

  String get where => '${source.path}:${source.lineOf(start)}';

  /// The nearest `key:` at or above this call: its own, else the closest
  /// enclosing call's that has one.
  String? get nearestKey {
    if (args['key'] != null) return args['key'];
    for (var p = source._parent[open]!; p >= 0; p = source._parent[p]!) {
      if (source.code[p] != '(') continue;
      final key = source.namedArgs(p)['key'];
      if (key != null) return key;
    }
    return null;
  }
}

class _Frame {
  _Frame.bracket(this.at)
      : isString = false,
        quote = '',
        triple = false,
        raw = false;
  _Frame.string(this.at, this.quote, {required this.triple, required this.raw}) : isString = true;

  final int at;
  final bool isString;
  final String quote;
  final bool triple;
  final bool raw;
}

/// Every Dart file under lib/, read once per test run.
final List<DartSource> libSources = [
  for (final f in (Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart')).toList()
    ..sort((a, b) => a.path.compareTo(b.path))))
    DartSource.read(f),
];

/// Every `TextField(` and `TextFormField(` in lib/.
List<Call> get libTextFields => [
      for (final s in libSources) ...s.calls(const {'TextField', 'TextFormField'}),
    ];
