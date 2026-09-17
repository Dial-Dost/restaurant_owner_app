import 'dart:async';

import 'package:flutter/material.dart';

/// PLANTED BUGS for the search contract (test/search_contract.dart). Test code
/// only — nothing under lib/ may look like this, and the registry guard makes
/// sure nothing does.
///
/// Each is a search box broken the way one of the app's own boxes was, and the
/// contract has to catch every one of them. The first three are the boxes the
/// 2.0.1 source sweep let through; the rest are the shapes the item-6
/// investigation found live in 2.0.1.
enum PlantedBug {
  /// The 2.0.0 order pad, but with a controller: the x resets the filter and
  /// leaves the word in the box. (C3)
  filterOnlyX,

  /// The x clears the box but leaves the debounce running, which puts the old
  /// word back a moment later. (C8)
  staleDebounce,

  /// A close glyph in the decoration that is not a button at all. (C2, C3)
  decorativeX,

  /// 2.0.1's Menu: the query is a local of a function the parent calls on
  /// every build, and the box re-seeds itself from it. Any rebuild — the
  /// keyboard going down — wipes the search. (C9)
  reseedOnRebuild,

  /// 2.0.1's Gaia Guests box: a 16px glyph beside the field instead of a
  /// button in it. (C2)
  xBesideTheField,

  /// 2.0.1's Settled bills: the x keyed on the debounced term, so it turns up
  /// only after the debounce. (C1)
  lateX,

  /// A box with no x at all. (C1)
  noX,
}

/// One planted box, with what it has applied (`planted-applied`) and a button
/// that rebuilds the screen around it (`planted-rebuild`). The box itself is
/// keyed `planted`.
class PlantedSearch extends StatefulWidget {
  const PlantedSearch({super.key, required this.bug});

  final PlantedBug bug;

  @override
  State<PlantedSearch> createState() => _PlantedSearchState();
}

class _PlantedSearchState extends State<PlantedSearch> {
  final _c = TextEditingController();
  String _applied = '';
  Timer? _debounce;
  int _rebuilds = 0;

  @override
  void dispose() {
    _debounce?.cancel();
    _c.dispose();
    super.dispose();
  }

  void _apply(String v) => setState(() => _applied = v.trim());

  @override
  Widget build(BuildContext context) {
    // Like HomeShell: a screen that depends on the MediaQuery rebuilds when the
    // phone keyboard comes and goes.
    MediaQuery.of(context);
    return Column(children: [
      if (widget.bug == PlantedBug.reseedOnRebuild)
        // The query lives in the function's closure, and so does what it shows.
        _reseedingModule()
      else ...[
        Padding(padding: const EdgeInsets.all(16), child: _box()),
        Text('applied=$_applied', key: const ValueKey('planted-applied')),
      ],
      TextButton(
        key: const ValueKey('planted-rebuild'),
        onPressed: () => setState(() => _rebuilds++),
        child: Text('rebuild $_rebuilds'),
      ),
    ]);
  }

  Widget _box() {
    const key = ValueKey('planted');
    switch (widget.bug) {
      case PlantedBug.filterOnlyX:
        return TextField(
          key: key,
          controller: _c,
          decoration: InputDecoration(
            hintText: 'Planted',
            suffixIcon: _applied.isEmpty
                ? null
                : IconButton(icon: const Icon(Icons.clear), onPressed: () => _apply('')),
          ),
          onChanged: _apply,
        );
      case PlantedBug.staleDebounce:
        return TextField(
          key: key,
          controller: _c,
          decoration: InputDecoration(
            hintText: 'Planted',
            suffixIcon: _c.text.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.clear),
                    onPressed: () {
                      _c.clear();
                      _apply('');
                    },
                  ),
          ),
          onChanged: (v) {
            setState(() {});
            _debounce?.cancel();
            _debounce = Timer(const Duration(milliseconds: 300), () => _apply(v));
          },
        );
      case PlantedBug.decorativeX:
        return TextField(
          key: key,
          controller: _c,
          decoration: const InputDecoration(hintText: 'Planted', suffixIcon: Icon(Icons.close)),
          onChanged: _apply,
        );
      case PlantedBug.reseedOnRebuild:
        throw StateError('built by _reseedingModule');
      case PlantedBug.xBesideTheField:
        return Container(
          height: 46,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(border: Border.all(color: Colors.grey)),
          child: Row(children: [
            Expanded(
              child: TextField(
                key: key,
                controller: _c,
                decoration: const InputDecoration(
                  hintText: 'Planted',
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  isDense: true,
                ),
                onChanged: _apply,
              ),
            ),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _c,
              builder: (context, v, _) => v.text.isEmpty
                  ? const SizedBox.shrink()
                  : GestureDetector(
                      onTap: () {
                        _c.clear();
                        _apply('');
                      },
                      behavior: HitTestBehavior.opaque,
                      child: const Padding(
                        padding: EdgeInsets.only(left: 8),
                        child: Icon(Icons.close, size: 16),
                      ),
                    ),
            ),
          ]),
        );
      case PlantedBug.lateX:
        return TextField(
          key: key,
          controller: _c,
          decoration: InputDecoration(
            hintText: 'Planted',
            suffixIcon: _applied.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () {
                      _debounce?.cancel();
                      _c.clear();
                      _apply('');
                    },
                  ),
          ),
          onChanged: (v) {
            _debounce?.cancel();
            _debounce = Timer(const Duration(milliseconds: 350), () => _apply(v));
          },
        );
      case PlantedBug.noX:
        return TextField(
          key: key,
          controller: _c,
          decoration: const InputDecoration(hintText: 'Planted'),
          onChanged: _apply,
        );
    }
  }
}

/// The 2.0.1 Menu module's shape, verbatim in miniature: the query is a local
/// of the function the parent calls on every build.
Widget _reseedingModule() {
  var query = '';
  return StatefulBuilder(
    builder: (context, setInner) => Column(children: [
      Padding(
        padding: const EdgeInsets.all(16),
        child: _ReseedingField(initial: query, onChanged: (v) => setInner(() => query = v)),
      ),
      Text('applied=${query.trim()}', key: const ValueKey('planted-applied')),
    ]),
  );
}

class _ReseedingField extends StatefulWidget {
  const _ReseedingField({required this.initial, required this.onChanged});

  final String initial;
  final ValueChanged<String> onChanged;

  @override
  State<_ReseedingField> createState() => _ReseedingFieldState();
}

class _ReseedingFieldState extends State<_ReseedingField> {
  late final TextEditingController _c = TextEditingController(text: widget.initial);

  @override
  void didUpdateWidget(_ReseedingField old) {
    super.didUpdateWidget(old);
    if (widget.initial != _c.text) _c.text = widget.initial;
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _set(String v) {
    widget.onChanged(v);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      key: const ValueKey('planted'),
      controller: _c,
      decoration: InputDecoration(
        hintText: 'Planted',
        suffixIcon: _c.text.isEmpty
            ? null
            : IconButton(
                icon: const Icon(Icons.clear),
                onPressed: () {
                  _c.clear();
                  _set('');
                },
              ),
      ),
      onChanged: _set,
    );
  }
}
