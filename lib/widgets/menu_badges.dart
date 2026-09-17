/// The owner app's badge surfaces: the chips on a menu tile, the CATALOGUE
/// editor (which badges exist, what they are called, whether they are on) and
/// the BULK TAGGER (which dishes carry them).
///
/// Two decisions this file makes visible.
///
///  * Tagging is a LIST, not a dialog per dish. A restaurant marking its veg
///    dishes is doing one job across sixty items; sixty edit dialogs is that
///    same job made unusable. So the tagger is the whole menu in one searchable
///    list, with "apply to everything shown".
///
///  * Dietary and safety badges are not decoration, and the UI says so before
///    the server has to. Kinds are grouped and labelled with what they promise,
///    removing one that dishes still carry asks a real question rather than
///    surfacing a 409, and an allergen-derived badge ("Contains nuts") is not
///    offered as a toggle at all — it follows the dish's allergen list, which is
///    edited in Recipe & cost. The UI explains that instead of hiding it.
library;

import 'package:flutter/material.dart';

import '../models/menu_badge.dart';
import '../services/api_client.dart';
import '../services/rest_client.dart';
import '../ui/theme/app_colors.dart';
import '../ui/theme/app_spacing.dart';
import '../ui/widgets/empty_state.dart';
import '../ui/widgets/fork_button.dart';
import '../ui/widgets/fork_card.dart';
import '../ui/widgets/status_chip.dart';

/// One badge pill. Outlined and tinted in its kind's colour, never filled — a
/// row of filled chips next to a copper price is louder than the dish name.
class MenuBadgePill extends StatelessWidget {
  const MenuBadgePill({super.key, required this.badge, this.dense = true, this.faded = false});

  final MenuBadge badge;
  final bool dense;

  /// An offered-but-not-applied chip in the tagger (dashed-looking, quiet).
  final bool faded;

  @override
  Widget build(BuildContext context) {
    final color = menuBadgeColor(badge.kind);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: dense ? 7 : 9, vertical: dense ? 2 : 4),
      decoration: BoxDecoration(
        color: faded ? Colors.transparent : AppColors.tint(color),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: faded ? AppColors.borderStrong : AppColors.edge(color)),
      ),
      // ChipLabel is a Flexible, so it has to sit directly in a Row — like every
      // other pill's label. Straight inside the Container it was a
      // ParentDataWidget error on every pill drawn (a failed assertion in
      // debug; in release the flex parent-data cast cannot succeed either).
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ChipLabel(
            badge.label,
            style: TextStyle(
              fontSize: dense ? 10 : 11.5,
              height: 1.35,
              fontWeight: FontWeight.w600,
              color: faded ? AppColors.textTertiary : color,
            ),
          ),
        ],
      ),
    );
  }
}

/// The badges one dish wears, resolved and ordered exactly as a guest sees them.
/// [promoLimit] trims only highlights; warnings and dietary badges always show.
class MenuBadgeChips extends StatelessWidget {
  const MenuBadgeChips({
    super.key,
    required this.catalogue,
    required this.item,
    this.promoLimit = 2,
  });

  final List<MenuBadge> catalogue;
  final Map<dynamic, dynamic> item;
  final int promoLimit;

  @override
  Widget build(BuildContext context) {
    final resolved = resolveMenuBadges(catalogue, item['badges'], item['allergens']);
    if (resolved.isEmpty) return const SizedBox.shrink();
    final capped = capMenuBadges(resolved, promoLimit);
    return Wrap(
      spacing: 5,
      runSpacing: 5,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final b in capped.shown) MenuBadgePill(badge: b),
        if (capped.hidden > 0)
          Text('+${capped.hidden}', style: TextStyle(fontSize: 10, color: AppColors.textTertiary)),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Catalogue editor
// ---------------------------------------------------------------------------

/// Manage the restaurant's badge catalogue. Pops `true` when anything was
/// saved, so the menu module reloads (a save can RELEASE tagged dishes).
class MenuBadgesDialog extends StatefulWidget {
  const MenuBadgesDialog({
    super.key,
    required this.rest,
    required this.initial,
    required this.presets,
    required this.labelMax,
    required this.usage,
  });

  final RestClient rest;
  final List<MenuBadge> initial;

  /// The starter set the server offers. Never applied on the tenant's behalf.
  final List<MenuBadge> presets;
  final int labelMax;

  /// How many dishes currently carry a badge id — drives the removal warning.
  final int Function(String id) usage;

  @override
  State<MenuBadgesDialog> createState() => _MenuBadgesDialogState();
}

class _MenuBadgesDialogState extends State<MenuBadgesDialog> {
  late List<MenuBadge> _badges;

  /// The last state the SERVER accepted. This editor saves on every action, so a
  /// refused or failed write has to roll the list back to this — otherwise the
  /// owner is left looking at a badge they think they disabled while the guest
  /// menu still shows it.
  late List<MenuBadge> _committed;
  final _add = TextEditingController();
  MenuBadgeKind _addKind = MenuBadgeKind.promo;
  bool _busy = false;
  bool _saved = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _badges = List<MenuBadge>.from(widget.initial);
    _committed = List<MenuBadge>.from(widget.initial);
  }

  @override
  void dispose() {
    _add.dispose();
    super.dispose();
  }

  Future<void> _persist({bool releaseTagged = false}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = await widget.rest.put('/menu/badges', {
        'badges': [for (final b in _badges) b.toJson()],
        if (releaseTagged) 'release_tagged': true,
      });
      if (!mounted) return;
      setState(() {
        _badges = res is Map ? parseMenuBadges(res['badges']) : _badges;
        _committed = List<MenuBadge>.from(_badges);
        _saved = true;
        _busy = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      // 409 = the server refuses to drop a dietary/safety badge dishes still
      // carry. Ask, then repeat the write with the release. Nothing was written
      // on the refused attempt, so answering "no" leaves the menu exactly as it
      // was rather than half-applied.
      if (e.status == 409 && !releaseTagged) {
        setState(() => _busy = false);
        final ok = await _ask(context, 'Dishes still carry that badge',
            '${e.message}\n\nRemove it from those dishes as well?');
        if (ok) {
          await _persist(releaseTagged: true);
        } else if (mounted) {
          // Declined: the server wrote NOTHING, so the list goes back to what it
          // actually holds rather than showing a change that never happened.
          setState(() => _badges = List<MenuBadge>.from(_committed));
        }
        return;
      }
      setState(() {
        _badges = List<MenuBadge>.from(_committed);
        _error = e.status == 403 ? 'Only someone who can edit the menu may change badges.' : e.message;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _badges = List<MenuBadge>.from(_committed);
        _error = '$e';
        _busy = false;
      });
    }
  }

  Future<void> _addBadge() async {
    var label = _add.text.trim();
    if (label.length > widget.labelMax) label = label.substring(0, widget.labelMax);
    final id = menuBadgeSlug(label);
    if (id.isEmpty) return;
    if (_badges.any((b) => b.id == id)) {
      setState(() => _error = '"$label" already exists.');
      return;
    }
    _add.clear();
    setState(() => _badges = [..._badges, MenuBadge(id: id, label: label, kind: _addKind)]);
    await _persist();
  }

  Future<void> _remove(MenuBadge b) async {
    final n = widget.usage(b.id);
    // Ask HERE, with the count, rather than letting the server's refusal be the
    // first the owner hears of it: a dietary claim leaving forty dishes should
    // read as a decision, not as an error message.
    if (b.protected && !b.derived && n > 0) {
      final ok = await _ask(context, 'Remove "${b.label}"?',
          'It is on $n dish${n == 1 ? '' : 'es'}. Removing it removes that claim from ${n == 1 ? 'it' : 'them'} too.');
      if (!ok) return;
      setState(() => _badges = _badges.where((x) => x.id != b.id).toList());
      await _persist(releaseTagged: true);
      return;
    }
    setState(() => _badges = _badges.where((x) => x.id != b.id).toList());
    await _persist();
  }

  Future<void> _rename(MenuBadge b) async {
    final to = await _askText(context, 'Rename badge', 'Label guests see', b.label, widget.labelMax);
    final label = (to ?? '').trim();
    if (label.isEmpty || label == b.label) return;
    // The id never moves, so every dish already tagged keeps its badge.
    setState(() => _badges = [for (final x in _badges) x.id == b.id ? x.copyWith(label: label) : x]);
    await _persist();
  }

  Future<void> _toggle(MenuBadge b, bool on) async {
    setState(() => _badges = [for (final x in _badges) x.id == b.id ? x.copyWith(enabled: on) : x]);
    await _persist();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        width: 520,
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(
          gradient: AppColors.cardGradient,
          borderRadius: AppRadius.cardAll,
          border: Border.all(color: AppColors.borderStrong),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 580),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('GUEST MENU', style: text.labelSmall),
            const SizedBox(height: 6),
            Text('Menu badges', style: text.titleMedium),
            const SizedBox(height: 6),
            Text(
              'Small labels guests see on a dish. Warnings and dietary badges are always shown; highlights are trimmed first when a card is tight. Nothing appears on your menu until you add one.',
              style: text.bodySmall,
            ),
            const SizedBox(height: AppSpacing.lg),
            if (_error != null) ...[
              Text(_error!, style: text.bodySmall!.copyWith(color: AppColors.danger)),
              const SizedBox(height: AppSpacing.sm),
            ],
            Flexible(
              child: _badges.isEmpty
                  ? EmptyState(
                      icon: Icons.sell_outlined,
                      title: 'No badges yet',
                      caption:
                          'Your menu looks exactly as it does today. Start from the set suggested for Indian restaurants, then edit or remove anything you do not want.',
                      action: ForkButton(
                        label: 'Use the starter set (${widget.presets.length})',
                        icon: Icons.auto_awesome,
                        dense: true,
                        onPressed: _busy || widget.presets.isEmpty
                            ? null
                            : () async {
                                setState(() => _badges = List<MenuBadge>.from(widget.presets));
                                await _persist();
                              },
                      ),
                    )
                  : ListView(
                      shrinkWrap: true,
                      children: [
                        for (final kind in kMenuBadgeKinds)
                          if (_badges.any((b) => b.kind == kind)) ...[
                            Padding(
                              padding: const EdgeInsets.only(top: 4, bottom: 6),
                              child: Text(
                                '${kMenuBadgeKindLabel[kind]!.toUpperCase()} — ${kMenuBadgeKindHint[kind]}',
                                style: text.labelSmall,
                              ),
                            ),
                            for (final b in _badges.where((x) => x.kind == kind))
                              Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: ForkCard(
                                  inset: true,
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                  child: Row(children: [
                                    MenuBadgePill(badge: b, dense: false),
                                    const SizedBox(width: AppSpacing.md),
                                    Expanded(
                                      child: Text(
                                        b.derived
                                            ? 'Automatic — on any dish listing "${b.allergen}"'
                                            : widget.usage(b.id) > 0
                                                ? '${widget.usage(b.id)} dish${widget.usage(b.id) == 1 ? '' : 'es'}'
                                                : 'not used yet',
                                        style: text.bodySmall,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    Switch(
                                      value: b.enabled,
                                      onChanged: _busy ? null : (v) => _toggle(b, v),
                                    ),
                                    ForkIconButton(
                                      icon: Icons.edit_outlined,
                                      tooltip: 'Rename',
                                      onPressed: _busy ? null : () => _rename(b),
                                    ),
                                    const SizedBox(width: 4),
                                    ForkIconButton(
                                      icon: Icons.delete_outline,
                                      tooltip: 'Remove',
                                      onPressed: _busy ? null : () => _remove(b),
                                    ),
                                  ]),
                                ),
                              ),
                          ],
                      ],
                    ),
            ),
            const SizedBox(height: AppSpacing.md),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _add,
                  enabled: !_busy,
                  maxLength: widget.labelMax,
                  decoration: const InputDecoration(
                    labelText: 'New badge (e.g. Gluten free)',
                    isDense: true,
                    counterText: '',
                  ),
                  onSubmitted: (_) => _addBadge(),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              DropdownButton<MenuBadgeKind>(
                value: _addKind,
                onChanged: _busy ? null : (v) => setState(() => _addKind = v ?? MenuBadgeKind.promo),
                items: [
                  for (final k in kMenuBadgeKinds)
                    DropdownMenuItem(value: k, child: Text(kMenuBadgeKindLabel[k]!)),
                ],
              ),
              const SizedBox(width: AppSpacing.sm),
              ForkIconButton(icon: Icons.add, tooltip: 'Add badge', onPressed: _busy ? null : _addBadge),
            ]),
            const SizedBox(height: AppSpacing.lg),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              ForkButton(label: 'Done', icon: Icons.check, onPressed: () => Navigator.pop(context, _saved)),
            ]),
          ]),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Bulk tagger
// ---------------------------------------------------------------------------

/// Tag many dishes at once. Pops `true` when anything was saved.
class MenuBadgeTagDialog extends StatefulWidget {
  const MenuBadgeTagDialog({
    super.key,
    required this.rest,
    required this.items,
    required this.catalogue,
    required this.perItemMax,
  });

  final RestClient rest;
  final List<Map<dynamic, dynamic>> items;
  final List<MenuBadge> catalogue;
  final int perItemMax;

  @override
  State<MenuBadgeTagDialog> createState() => _MenuBadgeTagDialogState();
}

class _MenuBadgeTagDialogState extends State<MenuBadgeTagDialog> {
  final Map<String, List<String>> _edits = {};
  final _search = TextEditingController();
  String _query = '';
  bool _busy = false;
  String? _error;

  /// Only hand-taggable badges. A derived one is not a tag — offering it as a
  /// toggle would be offering a switch that does nothing.
  List<MenuBadge> get _taggable => widget.catalogue.where((b) => b.enabled && !b.derived).toList();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  String _id(Map<dynamic, dynamic> it) => '${it['id'] ?? ''}';

  List<String> _tagsOf(Map<dynamic, dynamic> it) {
    final edited = _edits[_id(it)];
    if (edited != null) return edited;
    final raw = it['badges'];
    return raw is List ? raw.map((t) => '$t').toList() : const [];
  }

  List<Map<dynamic, dynamic>> get _visible {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return widget.items;
    return widget.items
        .where((it) => '${it['name'] ?? ''} ${it['category'] ?? ''}'.toLowerCase().contains(q))
        .toList();
  }

  void _toggle(Map<dynamic, dynamic> it, String badgeId) {
    final current = _tagsOf(it);
    final next = current.contains(badgeId)
        ? current.where((b) => b != badgeId).toList()
        : current.length >= widget.perItemMax
            ? current
            : [...current, badgeId];
    setState(() => _edits[_id(it)] = next);
  }

  /// The reason this is a list and not a per-dish dialog: one action, many dishes.
  void _applyToVisible(String badgeId, bool on) {
    setState(() {
      for (final it in _visible) {
        final current = _tagsOf(it);
        if (on && !current.contains(badgeId)) {
          if (current.length >= widget.perItemMax) continue;
          _edits[_id(it)] = [...current, badgeId];
        } else if (!on && current.contains(badgeId)) {
          _edits[_id(it)] = current.where((b) => b != badgeId).toList();
        }
      }
    });
  }

  List<Map<dynamic, dynamic>> get _changed => widget.items.where((it) {
        final next = _edits[_id(it)];
        if (next == null) return false;
        final raw = it['badges'];
        final before = raw is List ? raw.map((t) => '$t').toList() : const <String>[];
        if (next.length != before.length) return true;
        for (var i = 0; i < next.length; i++) {
          if (next[i] != before[i]) return true;
        }
        return false;
      }).toList();

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // Ids and tags only — never whole items. A stale menu snapshot in this
      // app must not be able to overwrite an image, a recipe or a price.
      await widget.rest.post('/menu/badges/tag', {
        'items': [
          for (final it in _changed) {'id': _id(it), 'badges': _tagsOf(it)},
        ],
      });
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is ApiException && e.status == 403
            ? e.sentenceOr('Only someone who can edit the menu may tag dishes.')
            : '$e';
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final taggable = _taggable;
    final visible = _visible;
    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        width: 640,
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(
          gradient: AppColors.cardGradient,
          borderRadius: AppRadius.cardAll,
          border: Border.all(color: AppColors.borderStrong),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 620),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('GUEST MENU', style: text.labelSmall),
            const SizedBox(height: 6),
            Text('Tag dishes with badges', style: text.titleMedium),
            const SizedBox(height: 6),
            Text(
              'Saving writes only the tags — images, recipes, kitchen sections and prices are untouched.',
              style: text.bodySmall,
            ),
            const SizedBox(height: AppSpacing.lg),
            TextField(
              controller: _search,
              decoration: const InputDecoration(labelText: 'Search dishes or categories', isDense: true),
              onChanged: (v) => setState(() => _query = v),
            ),
            const SizedBox(height: AppSpacing.md),
            if (taggable.isNotEmpty && visible.isNotEmpty)
              Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                Text('Apply to all ${visible.length} shown:', style: text.bodySmall),
                for (final b in taggable) ...[
                  InkWell(
                    onTap: _busy ? null : () => _applyToVisible(b.id, true),
                    borderRadius: BorderRadius.circular(999),
                    child: MenuBadgePill(badge: b, dense: false),
                  ),
                  ForkIconButton(
                    icon: Icons.close,
                    tooltip: 'Remove ${b.label} from all shown',
                    onPressed: _busy ? null : () => _applyToVisible(b.id, false),
                  ),
                ],
              ]),
            const SizedBox(height: AppSpacing.md),
            if (_error != null) ...[
              Text(_error!, style: text.bodySmall!.copyWith(color: AppColors.danger)),
              const SizedBox(height: AppSpacing.sm),
            ],
            Flexible(
              child: visible.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text('No dishes match "$_query".', style: text.bodySmall),
                    )
                  : ListView.separated(
                      shrinkWrap: true,
                      itemCount: visible.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (_, i) {
                        final it = visible[i];
                        final tags = _tagsOf(it);
                        final full = tags.length >= widget.perItemMax;
                        return ForkCard(
                          inset: true,
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            SizedBox(
                              width: 170,
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text('${it['name'] ?? ''}',
                                    style: text.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                                Text('${it['category'] ?? ''}', style: text.bodySmall),
                              ]),
                            ),
                            const SizedBox(width: AppSpacing.md),
                            Expanded(
                              child: Wrap(spacing: 5, runSpacing: 5, children: [
                                for (final b in taggable)
                                  InkWell(
                                    onTap: _busy || (full && !tags.contains(b.id)) ? null : () => _toggle(it, b.id),
                                    borderRadius: BorderRadius.circular(999),
                                    child: Opacity(
                                      opacity: full && !tags.contains(b.id) ? 0.4 : 1,
                                      child: MenuBadgePill(badge: b, faded: !tags.contains(b.id)),
                                    ),
                                  ),
                              ]),
                            ),
                          ]),
                        );
                      },
                    ),
            ),
            const SizedBox(height: AppSpacing.lg),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              ForkButton.ghost(label: 'Cancel', dense: true, onPressed: () => Navigator.pop(context, false)),
              const SizedBox(width: AppSpacing.sm),
              ForkButton(
                label: _busy
                    ? 'Saving…'
                    : 'Save${_changed.isEmpty ? '' : ' (${_changed.length} dish${_changed.length == 1 ? '' : 'es'})'}',
                icon: Icons.check,
                onPressed: _busy || _changed.isEmpty ? null : _save,
              ),
            ]),
          ]),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Local dialog helpers (this file cannot reach modules.dart's private ones).
// ---------------------------------------------------------------------------

Future<bool> _ask(BuildContext context, String title, String message) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Continue')),
      ],
    ),
  );
  return ok == true;
}

Future<String?> _askText(BuildContext context, String title, String label, String initial, int maxLength) async {
  final controller = TextEditingController(text: initial);
  final value = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        maxLength: maxLength,
        decoration: InputDecoration(labelText: label, counterText: ''),
        onSubmitted: (v) => Navigator.pop(ctx, v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('Save')),
      ],
    ),
  );
  controller.dispose();
  return value;
}
