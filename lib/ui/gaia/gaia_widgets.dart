import 'package:flutter/material.dart';

import 'gaia_bicolour.dart';
import 'gaia_colors.dart';
import 'gaia_spacing.dart';
import 'gaia_type.dart';

/// The GAIA primitives.
///
/// These are the Gaia halves of the Fork* widgets — `ForkCard.build` and
/// friends delegate here when the design system is on, which is what lets a
/// module render in either language untouched. They are public in their own
/// right too, for screens built Gaia-first.
///
/// Every one of them obeys the same three rules, read off the mockup CSS:
///
///  * **Flat.** No gradient, no shadow. Depth is the `bg -> surface -> raised`
///    ground ladder and nothing else.
///  * **Hairlined.** 1px `--line` between things; 1px `--line-2` around
///    controls. A border is how this design says "edge", everywhere.
///  * **Square.** 2px corners, or a true circle. Never in between.

// ─────────────────────────────────────────────────────────────────────
// Card — `.card{background:var(--surface);border:1px solid var(--line);
//              border-radius:2px;padding:18px 18px 16px}`
// ─────────────────────────────────────────────────────────────────────

/// Gaia's surface. The mockup's variants ride along: `.card.raised`,
/// `.card.warn` (a 2px coral left rail), `.card.dash`.
class GaiaCard extends StatefulWidget {
  const GaiaCard({
    super.key,
    required this.child,
    this.padding = GaiaSpacing.cardPad,
    this.onTap,
    this.selected = false,
    this.raised = false,
    this.dashed = false,
    this.railColor,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;

  /// Draws the champagne outline — the mockup's `.plan.cur` / `.cf.c`.
  final bool selected;

  /// `.card.raised` — one step up the ground ladder.
  final bool raised;

  /// `.card.dash` — the "nothing here yet" placeholder.
  final bool dashed;

  /// `.card.warn` — a 2px status rail down the left edge.
  final Color? railColor;

  @override
  State<GaiaCard> createState() => _GaiaCardState();
}

class _GaiaCardState extends State<GaiaCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final g = GaiaColors.ground;
    final interactive = widget.onTap != null;

    final border = widget.railColor ??
        (widget.selected
            ? GaiaColors.champagneDim
            : _hovered && interactive
                ? g.line2
                : (widget.dashed ? g.line2 : g.line));

    // No lift, no shadow: hover brightens the hairline and the ground, which
    // is the whole of this design's hover vocabulary (`.pk:hover`).
    Widget card = AnimatedContainer(
      duration: GaiaDurations.fast,
      curve: Curves.easeOut,
      padding: widget.padding,
      decoration: BoxDecoration(
        color: widget.raised || (_hovered && interactive) ? g.raised : g.surface,
        borderRadius: GaiaRadius.all,
        border: widget.railColor != null
            // `.card.warn{border-left:2px solid var(--coral)}` — the rail
            // replaces the left hairline, it does not sit inside it.
            ? Border(
                left: BorderSide(color: widget.railColor!, width: GaiaRadius.railStroke),
                top: BorderSide(color: g.line),
                right: BorderSide(color: g.line),
                bottom: BorderSide(color: g.line),
              )
            : Border.all(color: border),
      ),
      child: widget.child,
    );

    if (widget.dashed) {
      card = CustomPaint(
        painter: _DashedBorderPainter(color: g.line2),
        child: Container(
          padding: widget.padding,
          child: widget.child,
        ),
      );
    }

    if (!interactive) return card;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: card,
      ),
    );
  }
}

class _DashedBorderPainter extends CustomPainter {
  const _DashedBorderPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = GaiaRadius.hairline;
    const dash = 4.0;
    const gap = 3.0;
    final rect = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(GaiaRadius.edge),
    );
    final path = Path()..addRRect(rect);
    for (final metric in path.computeMetrics()) {
      var d = 0.0;
      while (d < metric.length) {
        canvas.drawPath(
          metric.extractPath(d, (d + dash).clamp(0, metric.length)),
          paint,
        );
        d += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorderPainter old) => old.color != color;
}

// ─────────────────────────────────────────────────────────────────────
// Button — `.btn{height:52px;padding:0 24px;font-size:12px;letter-spacing:.2em;
//                text-transform:uppercase;border:1px solid var(--champagne);
//                color:var(--champagne);border-radius:2px}`
// ─────────────────────────────────────────────────────────────────────

enum GaiaButtonKind {
  /// `.btn.primary` — champagne fill, ink label.
  primary,

  /// `.btn` — champagne hairline, champagne label, no fill.
  ghost,

  /// `.card .acts .go` — a bare tracked uppercase word, no box at all.
  subtle,
}

class GaiaButton extends StatefulWidget {
  const GaiaButton({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
    this.kind = GaiaButtonKind.primary,
    this.dense = false,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final GaiaButtonKind kind;
  final bool dense;

  @override
  State<GaiaButton> createState() => _GaiaButtonState();
}

class _GaiaButtonState extends State<GaiaButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final primary = widget.kind == GaiaButtonKind.primary;
    final subtle = widget.kind == GaiaButtonKind.subtle;

    // Carried over from ForkButton, deliberately: a null onPressed MUST look
    // disabled. That rule is about honesty, not about which design system is
    // on, so both languages hold it.
    final enabled = widget.onPressed != null;
    final hovered = _hovered && enabled;

    // `.bico .btn{border-color:var(--ink);color:var(--ink)}` — on the BICOLOUR
    // slab the button's whole palette swaps sides. Without this branch a
    // champagne-outlined button on a champagne ground is invisible, which is
    // the dead-looking-control failure this app keeps meeting.
    final bico = GaiaBicolour.of(context);
    final accent = bico ? GaiaBicolourColors.ink : GaiaColors.champagne;
    final accentHi = bico ? GaiaBicolourColors.ink : GaiaColors.champagne2;
    final onAccent = bico ? GaiaColors.champagne : GaiaColors.ink;

    final fg = primary ? onAccent : accent;

    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Opacity(
        opacity: enabled ? 1 : 0.42,
        child: GestureDetector(
          onTap: widget.onPressed,
          child: AnimatedContainer(
            duration: GaiaDurations.fast,
            height: subtle
                ? null
                : (widget.dense
                    ? GaiaSpacing.buttonHeightDense
                    : GaiaSpacing.buttonHeight),
            padding: EdgeInsets.symmetric(
              horizontal: subtle ? 0 : (widget.dense ? 16 : 24),
              vertical: subtle ? 4 : 0,
            ),
            decoration: BoxDecoration(
              color: primary
                  ? (hovered ? accentHi : accent)
                  : (hovered && !subtle
                      ? accent.withValues(alpha: 0.08)
                      : Colors.transparent),
              borderRadius: GaiaRadius.all,
              border: subtle ? null : Border.all(color: accent),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (widget.icon != null) ...[
                  Icon(widget.icon, size: widget.dense ? 14 : 15, color: fg),
                  const SizedBox(width: 8),
                ],
                Flexible(
                  child: Text(
                    widget.label.toUpperCase(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GaiaType.button(color: fg, dense: widget.dense),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The quiet square icon control. `.print-empty .ico` geometry: a hairline box
/// with a centred glyph, no fill.
class GaiaIconButton extends StatefulWidget {
  const GaiaIconButton({
    super.key,
    required this.icon,
    this.onPressed,
    this.tooltip,
    this.badge = false,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final bool badge;

  @override
  State<GaiaIconButton> createState() => _GaiaIconButtonState();
}

class _GaiaIconButtonState extends State<GaiaIconButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final g = GaiaColors.ground;
    final bico = GaiaBicolour.of(context);
    final enabled = widget.onPressed != null;
    final hovered = _hovered && enabled;

    Widget child = MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Opacity(
        opacity: enabled ? 1 : 0.42,
        child: GestureDetector(
          onTap: widget.onPressed,
          child: AnimatedContainer(
            duration: GaiaDurations.fast,
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: Colors.transparent,
              borderRadius: GaiaRadius.all,
              border: Border.all(
                  color: bico
                      ? (hovered ? GaiaBicolourColors.ink : GaiaBicolourColors.line2)
                      : (hovered ? GaiaColors.champagneDim : g.line2)),
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                Icon(
                  widget.icon,
                  size: 16,
                  color: bico
                      ? (hovered ? GaiaBicolourColors.ink : GaiaBicolourColors.body)
                      : (hovered ? GaiaColors.champagne : GaiaColors.text2),
                ),
                if (widget.badge)
                  Positioned(
                    top: 7,
                    right: 7,
                    child: GaiaDot(
                        color: bico ? GaiaBicolourColors.ink : GaiaColors.champagne),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    if (widget.tooltip != null) {
      child = Tooltip(message: widget.tooltip!, child: child);
    }
    return child;
  }
}

// ─────────────────────────────────────────────────────────────────────
// Micro pieces
// ─────────────────────────────────────────────────────────────────────

/// `.dot{width:6px;height:6px;border-radius:50%}` — the design's status mark.
class GaiaDot extends StatelessWidget {
  const GaiaDot({super.key, this.color = GaiaColors.champagne, this.size = 6});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      );
}

/// `.eyebrow` — the tracked uppercase micro label that opens a section.
class GaiaEyebrow extends StatelessWidget {
  const GaiaEyebrow(this.text, {super.key, this.color});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) => Text(
        text.toUpperCase(),
        // text3 by default: an eyebrow names the section its own contents
        // already spell out, so it is the one place the sub-AA faint ink is
        // honest (see GaiaColors' contrast note).
        style: GaiaType.eyebrow(color: color ?? GaiaColors.text3),
      );
}

/// `.rule{height:1px;background:var(--line);margin:22px 24px 0}`.
class GaiaRule extends StatelessWidget {
  const GaiaRule({super.key, this.margin = const EdgeInsets.only(top: 22)});

  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) => Container(
        margin: margin,
        height: GaiaRadius.hairline,
        color: GaiaColors.line,
      );
}

/// `.pill` — a tracked uppercase label in a hairline box, outlined in its own
/// status colour.
class GaiaPill extends StatelessWidget {
  const GaiaPill(this.label, {super.key, this.color});

  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        borderRadius: GaiaRadius.all,
        border: Border.all(color: c ?? GaiaColors.line2),
      ),
      child: Text(
        label.toUpperCase(),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: GaiaType.pill(color: c ?? GaiaColors.text2),
      ),
    );
  }
}

/// The mockup's status chip: `.dot` + label, no fill, no capsule. Status is
/// still never colour-alone — the label always ships, same contract the
/// Rustic StatusChip holds.
class GaiaStatusChip extends StatelessWidget {
  const GaiaStatusChip({
    super.key,
    required this.label,
    required this.color,
    this.dense = false,
  });

  final String label;
  final Color color;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    // On the BICOLOUR slab the dark-ground status inks are not merely low
    // contrast, they are invisible — coral 1.71:1, sage 1.02:1 on champagne.
    // A chip that stops existing is worse than a wrong colour, so the ink is
    // remapped rather than carried across.
    final c = GaiaBicolour.of(context) ? GaiaBicolour.status(color) : color;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? 8 : 9,
        vertical: dense ? 4 : 5,
      ),
      decoration: BoxDecoration(
        borderRadius: GaiaRadius.all,
        border: Border.all(color: c),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          GaiaDot(color: c, size: dense ? 5 : 6),
          SizedBox(width: dense ? 6 : 7),
          Flexible(
            child: Text(
              label.toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GaiaType.pill(color: c),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// Numerals — the serif figure with its sans unit, the design's signature
// ─────────────────────────────────────────────────────────────────────

/// `.big` — the hero figure, with the currency mark raised and the decimal
/// tail dropped to `--champagne-dim`.
///
/// The split is done here rather than at call sites because it is a TYPESETTING
/// rule of the design, not a per-screen choice: a hero number in this system
/// always reads ₹(small, dim) 1,77,213 (large, bright) .93 (small, dim).
class GaiaBigNumber extends StatelessWidget {
  const GaiaBigNumber(this.value, {super.key, this.color});

  /// Already formatted — "₹1,77,213.93", "4,820", "87%".
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final parts = splitNumber(value);
    return RichText(
      maxLines: 1,
      overflow: TextOverflow.clip,
      text: TextSpan(children: [
        if (parts.prefix.isNotEmpty)
          TextSpan(text: parts.prefix, style: GaiaType.bigCurrency()),
        TextSpan(text: parts.whole, style: GaiaType.big(color: color)),
        if (parts.tail.isNotEmpty)
          TextSpan(text: parts.tail, style: GaiaType.bigDecimal()),
      ]),
    );
  }

  /// Split "₹1,77,213.93" into ("₹", "1,77,213", ".93"). Leading non-digits are
  /// the currency mark; a trailing decimal group (and any unit that follows it)
  /// is the tail. A string with neither comes back whole.
  static ({String prefix, String whole, String tail}) splitNumber(String v) {
    var i = 0;
    while (i < v.length && !_isDigit(v.codeUnitAt(i))) {
      i++;
    }
    final prefix = v.substring(0, i);
    final rest = v.substring(i);
    final dot = rest.lastIndexOf('.');
    if (dot < 0) return (prefix: prefix, whole: rest, tail: '');
    return (prefix: prefix, whole: rest.substring(0, dot), tail: rest.substring(dot));
  }

  static bool _isDigit(int c) => c >= 0x30 && c <= 0x39;
}

/// `.stats` — the three-across figure rail under a hero, divided by verticals
/// and closed top and bottom by hairlines. The most recognisable block in the
/// mockup's Overview.
class GaiaStatRail extends StatelessWidget {
  const GaiaStatRail({super.key, required this.stats});

  final List<GaiaStat> stats;

  @override
  Widget build(BuildContext context) {
    if (stats.isEmpty) return const SizedBox.shrink();
    return Container(
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: GaiaColors.line),
          bottom: BorderSide(color: GaiaColors.line),
        ),
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < stats.length; i++)
              Expanded(
                child: Container(
                  padding: EdgeInsets.only(
                    top: 16,
                    bottom: 14,
                    left: i == 0 ? 0 : 16,
                  ),
                  decoration: i == 0
                      ? null
                      : BoxDecoration(
                          border: Border(left: BorderSide(color: GaiaColors.line)),
                        ),
                  child: stats[i],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// One cell of a [GaiaStatRail]: `.stats .n` over `.stats .l`.
class GaiaStat extends StatelessWidget {
  const GaiaStat({
    super.key,
    required this.value,
    required this.label,
    this.unit,
    this.color,
  });

  final String value;
  final String label;
  final String? unit;
  final Color? color;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          RichText(
            maxLines: 1,
            overflow: TextOverflow.clip,
            text: TextSpan(
              text: value,
              style: GaiaType.statNumber(color: color),
              children: [
                if (unit != null)
                  TextSpan(text: ' $unit', style: GaiaType.unit()),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Text(label.toUpperCase(), style: GaiaType.eyebrow()),
        ],
      );
}

// ─────────────────────────────────────────────────────────────────────
// List row — `.item{display:flex;padding:16px 0;border-top:1px solid var(--line)}`
// ─────────────────────────────────────────────────────────────────────

/// The hairline list row: a dot, a title, a detail line, a serif value at the
/// end and a chevron. No card, no fill — rows are separated by a rule, which
/// is how this design lists things.
class GaiaListRow extends StatefulWidget {
  const GaiaListRow({
    super.key,
    required this.title,
    this.detail,
    this.value,
    this.valueUnit,
    this.dotColor,
    this.onTap,
    this.first = false,
  });

  final String title;
  final String? detail;
  final String? value;
  final String? valueUnit;
  final Color? dotColor;
  final VoidCallback? onTap;

  /// `.item:first-child{border-top:0}` — the top rule is suppressed on the
  /// first row so a list does not double up with the section above it.
  final bool first;

  @override
  State<GaiaListRow> createState() => _GaiaListRowState();
}

class _GaiaListRowState extends State<GaiaListRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final interactive = widget.onTap != null;

    Widget row = AnimatedContainer(
      duration: GaiaDurations.fast,
      padding: const EdgeInsets.symmetric(vertical: GaiaSpacing.rowY),
      decoration: BoxDecoration(
        color: _hovered && interactive
            ? GaiaColors.champagne.withValues(alpha: 0.03)
            : Colors.transparent,
        border: widget.first
            ? null
            : Border(top: BorderSide(color: GaiaColors.line)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    if (widget.dotColor != null) ...[
                      GaiaDot(color: widget.dotColor!),
                      const SizedBox(width: 10),
                    ],
                    Expanded(
                      child: Text(
                        widget.title,
                        style: GaiaType.rowTitle(),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                if (widget.detail != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    widget.detail!,
                    style: GaiaType.detail(),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          if (widget.value != null) ...[
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(widget.value!, style: GaiaType.rowValue()),
                if (widget.valueUnit != null) ...[
                  const SizedBox(height: 4),
                  Text(widget.valueUnit!.toUpperCase(), style: GaiaType.unit()),
                ],
              ],
            ),
          ],
          if (interactive) ...[
            const SizedBox(width: 8),
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(Icons.chevron_right,
                  size: 18,
                  color: _hovered ? GaiaColors.champagne : GaiaColors.text3),
            ),
          ],
        ],
      ),
    );

    if (!interactive) return row;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: row,
      ),
    );
  }
}

/// `.kv` — a label/value pair on its own hairline. The quiet sibling of
/// [GaiaListRow]: no dot, no chevron, value in the serif.
class GaiaKeyValue extends StatelessWidget {
  const GaiaKeyValue({
    super.key,
    required this.label,
    required this.value,
    this.sub,
    this.first = false,
    this.serifValue = true,
    this.valueColor,
  });

  final String label;
  final String value;
  final String? sub;
  final bool first;

  /// `.kv .v.sage` / `.kv .v.coral` — the mockup colours a handful of key/value
  /// figures by their state (a clean recovery queue is sage, an open one is
  /// coral). Never the only carrier: the label beside it always says what the
  /// number is.
  final Color? valueColor;

  /// `.kv .v.sans` — some values are words, not figures, and words stay sans.
  final bool serifValue;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(vertical: GaiaSpacing.kvY),
        decoration: first
            ? null
            : BoxDecoration(border: Border(top: BorderSide(color: GaiaColors.line))),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(label, style: GaiaType.body(color: GaiaColors.text2)),
                  if (sub != null)
                    Text(sub!, style: GaiaType.sans(size: 12, color: GaiaColors.text3AA)),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Text(
              value,
              textAlign: TextAlign.right,
              style: serifValue
                  ? GaiaType.kvValue(color: valueColor)
                  : GaiaType.body(color: valueColor ?? GaiaColors.text),
            ),
          ],
        ),
      );
}

// ─────────────────────────────────────────────────────────────────────
// Tabs — `.tabs{border-bottom:1px solid var(--line)}` with an underlined
//        champagne current tab. Not pills.
// ─────────────────────────────────────────────────────────────────────

class GaiaTabs extends StatelessWidget {
  const GaiaTabs({
    super.key,
    required this.tabs,
    required this.selected,
    required this.onSelected,
  });

  final List<String> tabs;
  final int selected;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: GaiaColors.line)),
        ),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < tabs.length; i++)
                Padding(
                  padding: EdgeInsets.only(right: i == tabs.length - 1 ? 0 : 20),
                  child: _GaiaTab(
                    label: tabs[i],
                    active: i == selected,
                    onTap: () => onSelected(i),
                  ),
                ),
            ],
          ),
        ),
      );
}

class _GaiaTab extends StatefulWidget {
  const _GaiaTab({required this.label, required this.active, required this.onTap});

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  State<_GaiaTab> createState() => _GaiaTabState();
}

class _GaiaTabState extends State<_GaiaTab> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final color = widget.active
        ? GaiaColors.champagne
        : (_hovered ? GaiaColors.text : GaiaColors.text2);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.only(bottom: 12),
          decoration: widget.active
              // -1px margin in the CSS so the tab's rule SITS ON the row's
              // rule rather than under it; here the container simply overdraws
              // the parent border at the same y.
              ? const BoxDecoration(
                  border: Border(
                    bottom: BorderSide(color: GaiaColors.champagne, width: 1),
                  ),
                )
              : null,
          child: Text(
            widget.label.toUpperCase(),
            style: GaiaType.tabLabel(color: color),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// Toggle + slider — hand-drawn, because the mockup's geometry is exact
// ─────────────────────────────────────────────────────────────────────

/// `.toggle{width:40px;height:22px;border-radius:11px;border:1px solid
/// var(--line-2)}` with a 14px knob at 3px inset that travels to 21px and
/// flips from `--text-3` to `--ink` as the track fills champagne.
class GaiaToggle extends StatelessWidget {
  const GaiaToggle({super.key, required this.value, this.onChanged});

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final enabled = onChanged != null;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
      child: Opacity(
        opacity: enabled ? 1 : 0.42,
        child: GestureDetector(
          onTap: enabled ? () => onChanged!(!value) : null,
          child: AnimatedContainer(
            duration: GaiaDurations.fast,
            width: 40,
            height: 22,
            decoration: BoxDecoration(
              color: value ? GaiaColors.champagne : Colors.transparent,
              borderRadius: BorderRadius.circular(11),
              border: Border.all(
                  color: value ? GaiaColors.champagne : GaiaColors.line2),
            ),
            child: Stack(
              children: [
                AnimatedPositioned(
                  duration: GaiaDurations.fast,
                  curve: Curves.easeOut,
                  top: 3,
                  left: value ? 21 : 3,
                  child: Container(
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(
                      color: value ? GaiaColors.ink : GaiaColors.text3,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// `.slider` — a 1px rule with a 10px SQUARE champagne-outlined handle sitting
/// on it. The squareness is the point: a round knob would be the only soft
/// shape on the screen.
class GaiaSlider extends StatelessWidget {
  const GaiaSlider({
    super.key,
    required this.value,
    this.min = 0,
    this.max = 1,
    this.onChanged,
  });

  final double value;
  final double min;
  final double max;
  final ValueChanged<double>? onChanged;

  @override
  Widget build(BuildContext context) {
    return SliderTheme(
      data: SliderThemeData(
        trackHeight: GaiaRadius.hairline,
        activeTrackColor: GaiaColors.champagne,
        inactiveTrackColor: GaiaColors.line2,
        thumbShape: const _GaiaSquareThumb(),
        overlayShape: SliderComponentShape.noOverlay,
        trackShape: const RectangularSliderTrackShape(),
      ),
      child: Slider(
        value: value.clamp(min, max),
        min: min,
        max: max,
        onChanged: onChanged,
      ),
    );
  }
}

class _GaiaSquareThumb extends SliderComponentShape {
  const _GaiaSquareThumb();

  @override
  Size getPreferredSize(bool enabled, bool isDiscrete) => const Size(10, 10);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final canvas = context.canvas;
    final rect = Rect.fromCenter(center: center, width: 10, height: 10);
    canvas.drawRect(rect, Paint()..color = GaiaColors.bg);
    canvas.drawRect(
      rect,
      Paint()
        ..color = GaiaColors.champagne
        ..style = PaintingStyle.stroke
        ..strokeWidth = GaiaRadius.hairline,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// Section header + progress
// ─────────────────────────────────────────────────────────────────────

/// The Gaia section head. No copper tick, no pill count: an eyebrow, and the
/// count folded into it the way `.tabs span b` folds a count into a tab.
class GaiaSectionHeader extends StatelessWidget {
  const GaiaSectionHeader({
    super.key,
    required this.title,
    this.count,
    this.trailing,
    this.padding = const EdgeInsets.only(bottom: 14),
  });

  final String title;
  final int? count;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => Padding(
        padding: padding,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: RichText(
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                text: TextSpan(
                  text: title.toUpperCase(),
                  style: GaiaType.eyebrow(color: GaiaColors.champagneDim),
                  children: [
                    if (count != null)
                      TextSpan(
                        text: '  $count',
                        style: GaiaType.eyebrow(color: GaiaColors.text3),
                      ),
                  ],
                ),
              ),
            ),
            if (trailing != null) ...[const SizedBox(width: 8), trailing!],
          ],
        ),
      );
}

/// `.bar{height:3px;background:var(--line)}` with a champagne fill.
class GaiaBar extends StatelessWidget {
  const GaiaBar({super.key, required this.fraction, this.color});

  final double fraction;
  final Color? color;

  @override
  Widget build(BuildContext context) => Container(
        height: 3,
        decoration: BoxDecoration(
          color: GaiaColors.line,
          borderRadius: GaiaRadius.all,
        ),
        child: FractionallySizedBox(
          alignment: Alignment.centerLeft,
          widthFactor: fraction.clamp(0.0, 1.0),
          child: Container(
            decoration: BoxDecoration(
              color: color ?? GaiaColors.champagne,
              borderRadius: GaiaRadius.all,
            ),
          ),
        ),
      );
}

/// `.wordmark` — GAIA, letter-spaced to .42em, with an optional section name
/// trailing it at a tighter track.
class GaiaWordmark extends StatelessWidget {
  const GaiaWordmark({super.key, this.text = 'GAIA', this.section});

  final String text;
  final String? section;

  @override
  Widget build(BuildContext context) => RichText(
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        text: TextSpan(
          text: text.toUpperCase(),
          style: GaiaType.wordmark(),
          children: [
            if (section != null)
              TextSpan(
                text: '  ${section!.toUpperCase()}',
                style: GaiaType.serif(
                  size: 14,
                  weight: 500,
                  color: GaiaColors.text2,
                  letterSpacing: GaiaType.track(0.3, 14),
                ),
              ),
          ],
        ),
      );
}
