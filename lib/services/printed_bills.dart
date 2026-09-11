import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// WHICH TABLES THIS DEVICE HAS ALREADY PRINTED A BILL FOR — the memory behind
/// requirement C3's "only once".
///
/// WHAT THIS IS, STATED BEFORE ANYONE RELIES ON IT.
///
/// It is a COURTESY, NOT A CONTROL, and it is now also a FALLBACK OF LAST
/// RESORT. The server has since grown both halves of the real answer:
/// `/bill-for-table` reports `print_count` / `bill_printed_at` / `printed_at`,
/// and POST /print/bill refuses a waiter-only identity's second print with a 403
/// naming who to ask. So the gate is the route, as it always had to be.
///
/// WHICH MEANS THIS FILE IS READ IN EXACTLY ONE CASE: the payload in hand
/// carries NO print state at all — a backend older than those fields. It is not
/// a second opinion and must never be consulted as one. `serverBillPrintState`
/// returns a THREE-valued answer precisely so that a server saying "not printed"
/// cannot be overruled by a tablet that remembers otherwise; folding the two
/// together with `||` is the defect that made this device the authority, and it
/// kept a table off one waiter's screen forever on one tablet only.
///
/// What it is still worth, when it is reached at all: it survives a
/// back-navigation and an app restart, and it does not survive a reinstall, a
/// second tablet, or a colleague's login.
///
/// WHY IT IS KEYED BY TABLE AND CLEARED BY OCCUPANCY.
///
/// The obvious key is the bill id — except a table often has no "Bills" row at
/// all until something generates one, so the id is null for exactly the tables a
/// waiter prints first. The next candidate is the order id list, which changes
/// the moment a guest orders a coffee, so the button would come back mid-sitting
/// for a reason nobody could see.
///
/// So the key is the TABLE, and the record is dropped the moment that table is
/// no longer occupied — which is precisely when the sitting ends, however it
/// ends (settled, released, merged away). One print per sitting, and the next
/// party at T4 gets a clean screen without anybody having to remember to reset
/// anything. [reconcile] is what does the dropping, and it is driven by the
/// floor read the module already performs, so there is no extra request.
///
/// PER OUTLET, because table names are only unique inside one. T4 in Bandra is
/// not T4 in Andheri and a shared record would retire the wrong table.
class PrintedBills {
  PrintedBills._();

  /// The single instance the app uses. A plain singleton rather than an injected
  /// dependency because the two readers (the floor grid and the table sheet)
  /// must agree instantly — the sheet prints, pops, and the grid behind it has
  /// to have already lost the row.
  static final PrintedBills instance = PrintedBills._();

  static const String _prefix = 'rd_printed_bills_v1:';

  /// Bumped by every change, so a widget can rebuild off it without polling.
  /// The grid listens; the sheet writes.
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// outlet key -> the table names printed in it, lower-cased.
  final Map<String, Set<String>> _byOutlet = <String, Set<String>>{};

  /// Outlet keys already read off disk this session, so a reload does not
  /// re-read the file on every floor poll.
  final Set<String> _loaded = <String>{};

  String _key(String resId, String outletId) =>
      '${resId.trim()}/${outletId.trim()}';

  Set<String> _set(String resId, String outletId) =>
      _byOutlet.putIfAbsent(_key(resId, outletId), () => <String>{});

  /// Reads this outlet's record off disk, once per session.
  ///
  /// Best-effort on purpose: a SharedPreferences that will not open must not
  /// stop a waiter printing a bill. The consequence of failing open here is one
  /// extra button on one screen, and the consequence of failing closed would be
  /// a waiter who cannot print at all.
  Future<void> load(String resId, String outletId) async {
    final key = _key(resId, outletId);
    if (_loaded.contains(key)) return;
    _loaded.add(key);
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getStringList('$_prefix$key') ?? const <String>[];
      if (stored.isEmpty) return;
      _set(resId, outletId).addAll(stored);
      revision.value++;
    } catch (_) {
      /* see the header: a store that will not open costs a button, not a print */
    }
  }

  /// Whether this device has printed [tableName]'s bill for the current sitting.
  bool printed(String resId, String outletId, String tableName) =>
      _set(resId, outletId).contains(tableName.trim().toLowerCase());

  /// Record that it has. Called AFTER the print request is accepted, never
  /// before: a print that failed is a print the waiter still has to make.
  Future<void> mark(String resId, String outletId, String tableName) async {
    final name = tableName.trim().toLowerCase();
    if (name.isEmpty) return;
    if (!_set(resId, outletId).add(name)) return;
    revision.value++;
    await _persist(resId, outletId);
  }

  /// Drop every remembered table that is no longer occupied.
  ///
  /// [occupied] is the set of table names the floor read just said are seated.
  /// A table that has left it has ended its sitting — settled, released or
  /// merged away — so the next party at that table starts with a print button.
  ///
  /// Deliberately driven by a read the caller already made. Asking the server a
  /// second question ("is T4 still open?") would be a second answer to a
  /// question the floor grid has just answered, which is the failure this whole
  /// block is about.
  Future<void> reconcile(String resId, String outletId, Iterable<String> occupied) async {
    final set = _set(resId, outletId);
    if (set.isEmpty) return;
    final live = {for (final n in occupied) n.trim().toLowerCase()};
    final stale = set.where((n) => !live.contains(n)).toList();
    if (stale.isEmpty) return;
    set.removeAll(stale);
    revision.value++;
    await _persist(resId, outletId);
  }

  /// Forget everything for this outlet. Used by the tests, and by a sign-out:
  /// the next person to hold this tablet is a different waiter.
  Future<void> clear(String resId, String outletId) async {
    final set = _set(resId, outletId);
    if (set.isEmpty) return;
    set.clear();
    revision.value++;
    await _persist(resId, outletId);
  }

  Future<void> _persist(String resId, String outletId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = '$_prefix${_key(resId, outletId)}';
      final set = _set(resId, outletId);
      if (set.isEmpty) {
        await prefs.remove(key);
      } else {
        await prefs.setStringList(key, set.toList());
      }
    } catch (_) {
      // In memory it still holds for this session, which is the case that
      // matters — the waiter is standing at the table right now.
    }
  }

  /// Drops the in-memory state AND the "already read from disk" marks. Tests
  /// only: every other caller wants the record to survive a rebuild.
  @visibleForTesting
  void resetForTest() {
    _byOutlet.clear();
    _loaded.clear();
    revision.value++;
  }
}
