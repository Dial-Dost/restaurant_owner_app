/// WHAT THE SERVER SAYS WHEN A PARTY IS BIGGER THAN THE TABLE.
///
/// Client item 3, reported from the floor: *"More than the covers defined on
/// the table, the KOT won't get punched."* Six people sat at a two-top, the pad
/// seats before it sends — it must, or the bill predates the seating it belongs
/// to and every APC reading is attributed to the previous party — and
/// `POST /occupy-table` refused the seating with a 400. The send stopped there
/// and the kitchen never got the order.
///
/// The backend now seats them, records the TRUE head count (clamping 6 down to
/// 2 would double the APC on every bill that table ever settles) and returns
/// `covers_warning`: a sentence saying the table is set for fewer, with the two
/// things a host can actually do about it.
///
/// This is a NOTE, not a question. By the time it is on screen the order is
/// with the kitchen, and a confirm dialog here would be the old refusal wearing
/// a hat.
class CoversWarning {
  const CoversWarning(this.message);

  /// One sentence, written by the server, safe to show verbatim.
  final String message;

  /// Read `covers_warning` off a seat / covers-change response.
  ///
  /// Null means SAY NOTHING, and every shape that is not a sentence lands
  /// there: an older backend without the field, the ordinary case of a party
  /// that fits, a response the outbox queued offline (no body at all), or a
  /// `null` the route sends when the seating was inside capacity. Null must
  /// never be rendered as "no warning" — the floor reads silence as normal.
  static CoversWarning? parse(Object? raw) {
    if (raw is! Map) return null;
    final message = '${raw['covers_warning'] ?? ''}'.trim();
    if (message.isEmpty || message == 'null') return null;
    return CoversWarning(message);
  }
}
