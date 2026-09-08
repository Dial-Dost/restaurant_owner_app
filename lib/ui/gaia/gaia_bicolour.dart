import 'package:flutter/material.dart';

import 'gaia_colors.dart';
import 'gaia_spacing.dart';
import 'gaia_type.dart';

/// BICOLOUR — the signature treatment for Simulation.
///
/// The mockup does something no other screen in the system does: it turns the
/// ground inside out. Half of the header is the forest ground the whole app
/// stands on and half is filled champagne, and the levers panel below is a
/// solid champagne slab with ink type on it.
///
/// ```
/// .bico{background:var(--champagne);color:var(--ink);padding:26px 24px 24px}
/// .bico .lever{border-top:1px solid rgba(26,20,16,.16)}
/// .bico .slider{background:rgba(26,20,16,.28)}
/// .bico .btn{border-color:var(--ink);color:var(--ink)}
/// .bico .btn.primary{background:var(--ink);color:var(--champagne)}
/// ```
///
/// That inversion is the whole idea, and it is a good one for THIS screen
/// specifically: Simulation is the only page in the app where nothing is real.
/// The champagne slab is what says "you are in the sandbox now" without a
/// banner, and the split header is the comparison itself — your restaurant on
/// the dark side, the hypothesis on the bright side.
///
/// ## Why this needs an InheritedWidget rather than a colour argument
///
/// Inverting the ground inverts EVERYTHING inside it. A button, a chip, a
/// slider, a change dot and every line of type on that slab all have to swap
/// ink, and they are drawn by shared primitives with call sites far from here.
/// Passing a flag down through each would mean touching every one of them; so
/// [GaiaBicolour] publishes "the ground under you is champagne" and the
/// primitives ask. [GaiaBicolourPanel] additionally installs a [Theme] whose
/// text slots are already re-inked, which is what lets a screen's existing
/// `Theme.of(context).textTheme.bodySmall` land on the slab correctly with no
/// edit at all.
///
/// ## Status colour does not survive the inversion, and that is a bug class
///
/// Coral on champagne measures **1.71:1** and sage **1.02:1** — not "low", but
/// invisible. Any primitive that carries its dark-ground status ink onto this
/// slab silently stops existing, which on a screen projecting money is the
/// worst possible failure: a red delta that renders as champagne-on-champagne
/// reads as "no change". [GaiaBicolour.status] is the mapping every status ink
/// must go through inside the panel.
class GaiaBicolour extends InheritedWidget {
  const GaiaBicolour({super.key, required super.child});

  /// True when the widget asking is drawn on the champagne slab.
  ///
  /// Uses `dependOnInheritedWidgetOfExactType`, so a primitive that reads it
  /// is registered as a dependent and repaints if the panel ever appears or
  /// disappears above it — the same reason [Gaia.of] exists rather than a
  /// static read.
  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<GaiaBicolour>() != null;

  /// Map a dark-ground status ink onto the champagne slab.
  ///
  /// This is a SAFETY NET, not a lookup table, and it is written that way on
  /// purpose. `StatusChip(color: ...)` is called with a caller-chosen colour at
  /// well over a hundred sites, in both palettes: `AppColors.danger` measures
  /// **1.68:1** on champagne, `AppColors.warning` **1.12:1**, `success`
  /// **1.25:1**, `info` **1.36:1** — every one of them invisible, not merely
  /// low. A table of the four inks this file happens to know about would leave
  /// every other call site silently blank.
  ///
  /// So the rule is: anything that ALREADY reads on champagne is kept exactly
  /// as the caller chose it; anything that does not is replaced by the nearest
  /// meaning from the slab's own set, chosen by hue. A near-grey carries no
  /// hue meaning, so it becomes plain ink. Nothing gets through unchanged that
  /// cannot be seen — that is the invariant, and `gaia_signatures_test.dart`
  /// fuzzes the whole colour wheel against it.
  static Color status(Color onDark) {
    // Identity first, so the design's own inks map to the exact companions
    // that were measured for them rather than to a hue bucket.
    if (onDark == GaiaColors.coral || onDark == GaiaStrataColors.tagCoral) {
      return GaiaBicolourColors.statusBad;
    }
    if (onDark == GaiaColors.sage) return GaiaBicolourColors.statusGood;
    if (onDark == GaiaColors.amber) return GaiaBicolourColors.statusWarn;
    if (onDark == GaiaColors.champagne ||
        onDark == GaiaColors.champagne2 ||
        onDark == GaiaColors.champagneDim) {
      // The accent inverts on its own ground: on champagne, champagne IS ink.
      return GaiaBicolourColors.ink;
    }
    // A colour the caller chose that already reads here is left alone.
    if (contrastOnGround(onDark) >= 4.5) return onDark;

    final hsl = HSLColor.fromColor(onDark);
    // Champagne itself sits at hue 37.5, so hue alone cannot separate "amber"
    // from "the ground"; saturation does. A near-grey is quiet type, not a
    // status.
    if (hsl.saturation < 0.12) return GaiaBicolourColors.ink;
    final h = hsl.hue;
    if (h < 25 || h >= 340) return GaiaBicolourColors.statusBad;
    if (h < 70) return GaiaBicolourColors.statusWarn;
    if (h < 170) return GaiaBicolourColors.statusGood;
    if (h < 265) return GaiaBicolourColors.statusInfo;
    return GaiaBicolourColors.ink;
  }

  /// WCAG 2.1 contrast of [c] against the champagne slab. Exposed because the
  /// rule above is worth checking from a test rather than trusting.
  static double contrastOnGround(Color c) {
    final a = c.computeLuminance();
    final b = GaiaBicolourColors.ground.computeLuminance();
    final hi = a > b ? a : b;
    final lo = a > b ? b : a;
    return (hi + 0.05) / (lo + 0.05);
  }

  /// The text ink for a given role on the slab.
  static Color ink(BuildContext context, {GaiaInk role = GaiaInk.primary}) {
    if (!of(context)) {
      return switch (role) {
        GaiaInk.primary => GaiaColors.text,
        GaiaInk.secondary => GaiaColors.text2,
        GaiaInk.label => GaiaColors.text2,
        GaiaInk.accent => GaiaColors.champagne,
      };
    }
    return switch (role) {
      GaiaInk.primary => GaiaBicolourColors.ink,
      GaiaInk.secondary => GaiaBicolourColors.body,
      GaiaInk.label => GaiaBicolourColors.label,
      GaiaInk.accent => GaiaBicolourColors.ink,
    };
  }

  @override
  bool updateShouldNotify(GaiaBicolour oldWidget) => false;
}

enum GaiaInk { primary, secondary, label, accent }

/// `.bico` — the champagne slab.
///
/// Installs both the inherited flag and a re-inked [Theme], so anything inside
/// that reads the text theme is already correct. Nothing here changes layout;
/// it is a ground swap and nothing more, which is what makes it safe to wrap
/// around a screen's existing content.
class GaiaBicolourPanel extends StatelessWidget {
  const GaiaBicolourPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.fromLTRB(24, 26, 24, 24),
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context);
    final t = base.textTheme;

    TextStyle? re(TextStyle? s, Color c) => s?.copyWith(color: c);
    const ink = GaiaBicolourColors.ink;
    const body = GaiaBicolourColors.body;
    const label = GaiaBicolourColors.label;

    return GaiaBicolour(
      child: Theme(
        data: base.copyWith(
          colorScheme: base.colorScheme.copyWith(
            primary: ink,
            onPrimary: GaiaColors.champagne,
            surface: GaiaBicolourColors.ground,
            onSurface: ink,
            onSurfaceVariant: body,
            outline: GaiaBicolourColors.line2,
            outlineVariant: GaiaBicolourColors.line,
            error: GaiaBicolourColors.statusBad,
          ),
          textTheme: t.copyWith(
            displayLarge: re(t.displayLarge, ink),
            displayMedium: re(t.displayMedium, ink),
            displaySmall: re(t.displaySmall, ink),
            headlineLarge: re(t.headlineLarge, ink),
            headlineMedium: re(t.headlineMedium, ink),
            headlineSmall: re(t.headlineSmall, ink),
            titleLarge: re(t.titleLarge, ink),
            titleMedium: re(t.titleMedium, ink),
            titleSmall: re(t.titleSmall, ink),
            bodyLarge: re(t.bodyLarge, ink),
            bodyMedium: re(t.bodyMedium, body),
            bodySmall: re(t.bodySmall, body),
            labelLarge: re(t.labelLarge, ink),
            labelMedium: re(t.labelMedium, label),
            labelSmall: re(t.labelSmall, label),
          ),
          dividerColor: GaiaBicolourColors.line,
          iconTheme: base.iconTheme.copyWith(color: ink),
        ),
        child: Container(
          width: double.infinity,
          color: GaiaBicolourColors.ground,
          padding: padding,
          child: DefaultTextStyle(
            style: GaiaType.body(color: ink),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// `.bico-head` — the slab's own heading, serif and ink, with a caption to its
/// right in the slab's label ink.
class GaiaBicolourHeading extends StatelessWidget {
  const GaiaBicolourHeading({super.key, required this.title, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Text(
                title,
                style: GaiaType.serif(
                    size: 30, weight: 500, height: 1, color: GaiaBicolourColors.ink),
              ),
            ),
            ?trailing,
          ],
        ),
      );
}

/// One half of the split header.
@immutable
class GaiaBicolourFace {
  const GaiaBicolourFace({
    required this.eyebrow,
    required this.value,
    this.detail,
    this.valueColor,
    this.pending = false,
  });

  final String eyebrow;

  /// Already formatted — "−₹2,510".
  final String value;
  final String? detail;

  /// Overridden ONLY on the dark half; the champagne half re-inks through
  /// [GaiaBicolour.status] so a red figure cannot come out invisible.
  final Color? valueColor;

  /// "Nothing has been run yet" — draws the face at rest rather than showing a
  /// zero that would read as a projection of zero.
  final bool pending;
}

/// The two-up header: the live number on the forest ground, the hypothesis on
/// champagne. The split IS the comparison — same eyebrow, same figure size,
/// same detail line, so the only thing that differs between the halves is the
/// number and which side of the fence it is on.
class GaiaBicolourSplit extends StatelessWidget {
  const GaiaBicolourSplit({
    super.key,
    required this.current,
    required this.scenario,
    this.stacked = false,
  });

  final GaiaBicolourFace current;
  final GaiaBicolourFace scenario;

  /// One above the other. On a 320dp phone two 40px figures do not share a
  /// line, and shrinking them to fit is how a money screen becomes unreadable.
  final bool stacked;

  @override
  Widget build(BuildContext context) {
    final dark = _Half(
      face: current,
      ground: GaiaBicolourColors.darkGround,
      // text2, not the spec's --text-3 (4.20:1 on the forest ground). Most
      // eyebrows in this design repeat a heading their own contents already
      // spell out, which is what makes the faint ink honest there. THIS one is
      // the only thing that says which half is your restaurant and which is the
      // hypothesis — losing it loses the whole comparison.
      eyebrowInk: GaiaColors.text2,
      valueInk: current.valueColor ?? GaiaColors.text,
      detailInk: GaiaColors.text2,
      topRule: true,
    );
    final bright = GaiaBicolour(
      child: _Half(
        face: scenario,
        ground: GaiaBicolourColors.ground,
        eyebrowInk: GaiaBicolourColors.label,
        valueInk: scenario.valueColor == null
            ? GaiaBicolourColors.ink
            : GaiaBicolour.status(scenario.valueColor!),
        detailInk: GaiaBicolourColors.body,
        topRule: false,
      ),
    );

    if (stacked) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [dark, bright]);
    }
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [Expanded(child: dark), Expanded(child: bright)],
      ),
    );
  }
}

class _Half extends StatelessWidget {
  const _Half({
    required this.face,
    required this.ground,
    required this.eyebrowInk,
    required this.valueInk,
    required this.detailInk,
    required this.topRule,
  });

  final GaiaBicolourFace face;
  final Color ground;
  final Color eyebrowInk;
  final Color valueInk;
  final Color detailInk;
  final bool topRule;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(20, 22, 20, 22),
        decoration: BoxDecoration(
          color: ground,
          border: topRule
              ? Border(top: BorderSide(color: GaiaColors.line))
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(face.eyebrow.toUpperCase(),
                style: GaiaType.eyebrow(color: eyebrowInk)),
            const SizedBox(height: 10),
            Text(
              face.pending ? '—' : face.value,
              maxLines: 1,
              overflow: TextOverflow.fade,
              softWrap: false,
              style: GaiaType.serif(
                size: 40,
                weight: 500,
                height: 1,
                color: face.pending ? detailInk : valueInk,
              ),
            ),
            if (face.detail != null) ...[
              const SizedBox(height: 8),
              Text(face.detail!, style: GaiaType.detail(color: detailInk)),
            ],
          ],
        ),
      );
}

/// One `.delta-row`: metric, current, scenario, delta.
///
/// `.delta-row .sim` is the serif champagne column — the projected figure is
/// the only one set in the display face, which is what makes a table of four
/// numeric columns scannable without a rule between them.
///
/// The delta cell never relies on its colour, and the glyph that makes sure of
/// that tracks the NUMBER, not the judgement.
///
/// That distinction cost a render to learn. The first version pointed the arrow
/// at "better or worse", which is what the colour means — so a labour cost
/// rising by ₹6,150 came out as `▼ +₹6,150`: an arrow saying down beside a sign
/// saying up, on the row where an owner is deciding whether to roster another
/// shift. Two channels that disagree are worse than one channel, however
/// well-meant the second one is.
///
/// So [rise] is the sign of the delta and nothing else. At 12px a `+` and a `−`
/// differ by a couple of pixels and these are the cells people actually read,
/// which is why the sign gets a shape as well as a glyph. Whether that rise is
/// good news stays with [deltaColor] — and it is not carried by colour alone
/// either, because the metric's own name says which direction is welcome.
class GaiaDeltaRow extends StatelessWidget {
  const GaiaDeltaRow({
    super.key,
    required this.metric,
    required this.current,
    required this.scenario,
    required this.delta,
    this.deltaColor,
    this.header = false,
    this.first = false,
    this.rise = 0,
  });

  final String metric;
  final String current;
  final String scenario;
  final String delta;
  final Color? deltaColor;
  final bool header;
  final bool first;

  /// +1 the figure rose, -1 it fell, 0 unchanged. The sign of the delta, never
  /// a verdict on it — see the class doc.
  final int rise;

  @override
  Widget build(BuildContext context) {
    final on = GaiaBicolour.of(context);
    // The header names the columns and nothing else does, so it clears AA on
    // both grounds — text2 (8.19:1) on the dark one rather than the spec's
    // --text-3 (4.20:1), and the lifted label ink (4.59:1) on champagne.
    final labelInk = on ? GaiaBicolourColors.label : GaiaColors.text2;
    final bodyInk = on ? GaiaBicolourColors.ink : GaiaColors.text;
    final simInk = on ? GaiaBicolourColors.ink : GaiaColors.champagne2;
    final line = on ? GaiaBicolourColors.line : GaiaColors.line;

    final style = header
        ? GaiaType.eyebrow(color: labelInk)
        : GaiaType.sans(size: 14, color: bodyInk);

    Widget cell(String t, {TextStyle? s, TextAlign align = TextAlign.right}) => Text(
          t,
          textAlign: align,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.fade,
          style: s ?? style,
        );

    final dColor = deltaColor == null
        ? (on ? GaiaBicolourColors.body : GaiaColors.text2)
        : (on ? GaiaBicolour.status(deltaColor!) : deltaColor!);

    // ▲ / ▼ — legible at a glance and legible in greyscale, and always
    // pointing the same way as the sign printed immediately after it.
    final glyph = rise > 0 ? '▲ ' : (rise < 0 ? '▼ ' : '');

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 11),
      decoration: BoxDecoration(
        border: first ? null : Border(top: BorderSide(color: line)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(flex: 13, child: cell(metric, align: TextAlign.left)),
          Expanded(flex: 10, child: cell(current)),
          Expanded(
            flex: 10,
            child: cell(
              scenario,
              s: header
                  ? style
                  : GaiaType.serif(size: 19, weight: 500, color: simInk),
            ),
          ),
          Expanded(
            flex: 9,
            child: cell(
              header ? delta : '$glyph$delta',
              s: header ? style : GaiaType.sans(size: 14, weight: 600, color: dColor),
            ),
          ),
        ],
      ),
    );
  }
}

/// `.bico .btn` — the slab's own button. Ink outline, or ink fill with
/// champagne type for the primary.
class GaiaBicolourButton extends StatelessWidget {
  const GaiaBicolourButton({
    super.key,
    required this.label,
    this.onPressed,
    this.primary = false,
    this.icon,
    this.dense = true,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool primary;
  final IconData? icon;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final fg = primary ? GaiaColors.champagne : GaiaBicolourColors.ink;
    final bg = primary ? GaiaBicolourColors.ink : Colors.transparent;
    final content = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, size: dense ? 14 : 16, color: fg),
          const SizedBox(width: 8),
        ],
        Text(label.toUpperCase(), style: GaiaType.button(color: fg, dense: dense)),
      ],
    );
    return Opacity(
      opacity: enabled ? 1 : 0.42,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        child: GestureDetector(
          onTap: onPressed,
          child: Container(
            height: dense
                ? GaiaSpacing.buttonHeightDense
                : GaiaSpacing.buttonHeight,
            padding: EdgeInsets.symmetric(horizontal: dense ? 16 : 24),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: GaiaRadius.all,
              border: Border.all(color: GaiaBicolourColors.ink),
            ),
            child: content,
          ),
        ),
      ),
    );
  }
}
