import 'package:flutter/material.dart';

import '../models/floor_state.dart';
import '../models/next_party.dart';
import '../services/rest_client.dart';

/// CLIENT ITEM 6 — "THIS BILL WAS ALREADY PRINTED — REPRINT IT".
///
/// 2.0.2 (client items 1 and 2): the action says "Print updated bill". That is
/// what the print now is — the server stamps it UPDATED BILL, because the paper
/// no longer matches — and it is the one reprint a waiter who added to the
/// bill may make.
///
/// A senior role's write that put more on a printed bill (an order, a merge,
/// an item moved onto it) is answered with [ReprintNeeded]. The server has
/// written it; what is left is the paper in the guest's hand, which is now
/// short. This says so in the server's words, with a Reprint action that
/// sends exactly what the table sheet's own Print button sends — POST
/// /print/bill for the table's handle — so a manager can put the right total
/// in front of the guest without hunting for the table first.
///
/// Two shapes, because of where the write was sent from:
///
///  * [showReprintNeeded] — a snackbar, for a screen that closes as it sends
///    (the order pad). The messenger is captured BEFORE the route is popped, so
///    the line outlives the pad, on the floor the pad was opened over.
///  * [askToReprint] — a dialog, for the table sheet. The sheet is a modal
///    bottom sheet, and a snackbar is drawn on the page UNDER its barrier: the
///    line would be dimmed and its action untappable while the sheet is open.
///
void showReprintNeeded(ScaffoldMessengerState messenger, RestClient rest, ReprintNeeded notice) {
  messenger.showSnackBar(SnackBar(
    key: const ValueKey('reprint-needed'),
    duration: const Duration(seconds: 12),
    content: Text(notice.message),
    action: SnackBarAction(
      key: const ValueKey('reprint-needed-action'),
      label: printUpdatedBillLabel,
      onPressed: () async {
        try {
          await rest.post('/print/bill', {'table_name': notice.table});
          messenger.showSnackBar(const SnackBar(content: Text('Printing bill…'), duration: Duration(seconds: 3)));
        } catch (e) {
          messenger.showSnackBar(SnackBar(content: Text('$e')));
        }
      },
    ),
  ));
}

/// The table sheet's shape of the same line — see the header. [lead] is what
/// the sheet would have said anyway ("Merged Table 5 into 12."), kept in front
/// of the reprint line so one message says both. Answers whether
/// a reprint was sent. [printHere] is the sheet's own print, used when the
/// table to reprint is the one the sheet is open on, so the paper goes out
/// exactly as its Print button sends it; any other table is printed with the
/// same POST /print/bill.
Future<bool> askToReprint(
  BuildContext context,
  RestClient rest,
  ReprintNeeded notice, {
  required ScaffoldMessengerState messenger,
  String? lead,
  Future<bool> Function()? printHere,
}) async {
  final text = (lead ?? '').trim();
  final go = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      key: const ValueKey('reprint-needed'),
      title: const Text('Print the updated bill?'),
      content: Text(text.isEmpty ? notice.message : '$text ${notice.message}'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Not now')),
        FilledButton(
          key: const ValueKey('reprint-needed-action'),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text(printUpdatedBillLabel),
        ),
      ],
    ),
  );
  if (go != true) return false;
  if (printHere != null) return printHere();
  try {
    await rest.post('/print/bill', {'table_name': notice.table});
    messenger.showSnackBar(const SnackBar(content: Text('Printing bill…'), duration: Duration(seconds: 3)));
    return true;
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('$e')));
    return false;
  }
}
