import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import '../services/auth_controller.dart';
import '../ui/theme/app_colors.dart';
import '../ui/theme/app_spacing.dart';
import '../ui/widgets/fork_button.dart';
import '../ui/widgets/fork_card.dart';

/// Two-phase sign-in. The restaurant name is set up once per device and saved;
/// after that, staff only enter username + password. "Change" clears it.
class LoginScreen extends StatefulWidget {
  final AuthController auth;
  const LoginScreen({super.key, required this.auth});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  static const _restaurantKey = 'restaurant_name';

  final _formKey = GlobalKey<FormState>();
  final _restaurant = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();

  String? _savedRestaurant;
  bool _loadingPrefs = true;

  // Outlet picker state. Populated from GET /auth/outlets once the restaurant
  // step is complete. <=1 outlet => no selector shown (unchanged single-outlet
  // UX). A failed/empty fetch leaves this empty and login falls back to the
  // default outlet.
  List<Map<String, String>> _outlets = const [];
  String? _selectedOutletId;
  bool _loadingOutlets = false;

  static String _outletKeyFor(String restaurant) => 'selected_login_outlet_$restaurant';

  @override
  void initState() {
    super.initState();
    _loadRestaurant();
  }

  Future<void> _loadRestaurant() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final saved = prefs.getString(_restaurantKey);
    setState(() {
      _savedRestaurant = saved;
      _loadingPrefs = false;
    });
    if (saved != null && saved.isNotEmpty) {
      _loadOutlets(saved);
    }
  }

  /// Fetch the restaurant's outlets and preselect the last-used (or default)
  /// one when there is a choice to make. Never blocks sign-in: on failure or
  /// <=1 outlet the selector simply doesn't appear.
  Future<void> _loadOutlets(String restaurant) async {
    if (restaurant.isEmpty) return;
    setState(() => _loadingOutlets = true);
    final outlets = await widget.auth.api.fetchOutlets(restaurant);
    if (!mounted) return;
    String? selected;
    if (outlets.length > 1) {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_outletKeyFor(restaurant));
      final validSaved = saved != null && outlets.any((o) => o['id'] == saved);
      selected = validSaved ? saved : outlets.first['id'];
    }
    if (!mounted) return;
    setState(() {
      _outlets = outlets;
      _selectedOutletId = selected;
      _loadingOutlets = false;
    });
  }

  Future<void> _saveRestaurant() async {
    final name = _restaurant.text.trim();
    if (name.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_restaurantKey, name);
    if (!mounted) return;
    setState(() => _savedRestaurant = name);
    _loadOutlets(name);
  }

  Future<void> _changeRestaurant() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_restaurantKey);
    if (!mounted) return;
    setState(() {
      _savedRestaurant = null;
      _restaurant.clear();
      _outlets = const [];
      _selectedOutletId = null;
      _loadingOutlets = false;
    });
  }

  @override
  void dispose() {
    _restaurant.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    String? outletId;
    if (_outlets.length > 1) {
      outletId = _selectedOutletId ?? _outlets.first['id'];
    } else if (_outlets.length == 1) {
      outletId = _outlets.first['id'];
    }
    if (_outlets.length > 1 && outletId != null && outletId.isNotEmpty) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_outletKeyFor(_savedRestaurant!), outletId);
    }
    await widget.auth.login(_savedRestaurant!, _username.text, _password.text, outletId: outletId);
  }

  Future<void> _forgotPassword() async {
    final messenger = ScaffoldMessenger.of(context);
    final ctrl = TextEditingController(text: _username.text.trim());
    final username = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Forgot password'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Enter your username. Your restaurant admin will be notified to reset your password.',
              style: TextStyle(fontSize: 13)),
          const SizedBox(height: 12),
          TextField(
            controller: ctrl,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Username'),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('Send request')),
        ],
      ),
    );
    if (username == null || username.isEmpty) return;
    await widget.auth.api.forgotPassword(_savedRestaurant!, username);
    messenger.showSnackBar(const SnackBar(
      content: Text('Request sent. Ask your admin to set a new password for you.'),
    ));
  }

  /// Lets a tester repoint the app at a different backend (e.g. a new tunnel
  /// URL) without rebuilding. Persisted on the device; empty = built-in default.
  Future<void> _editServerUrl() async {
    final messenger = ScaffoldMessenger.of(context);
    final ctrl = TextEditingController(text: AppConfig.backendUrl);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Server address'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Where this app connects. Only change this if you were given a new server link.',
              style: TextStyle(fontSize: 13)),
          const SizedBox(height: 12),
          TextField(
            controller: ctrl,
            autofocus: true,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(labelText: 'Server URL', hintText: 'https://…'),
            onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
          ),
          const SizedBox(height: 8),
          Text('Default: ${AppConfig.builtBackendUrl}',
              style: const TextStyle(fontSize: 12, color: AppColors.textTertiary)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, ''), child: const Text('Reset to default')),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('Save')),
        ],
      ),
    );
    if (result == null) return; // cancelled
    var url = result;
    if (url.isNotEmpty && !url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'https://$url'; // pasted a bare host (e.g. a tunnel hostname)
    }
    await AppConfig.setBackendOverride(url.isEmpty ? null : url);
    if (!mounted) return;
    setState(() {});
    messenger.showSnackBar(SnackBar(content: Text('Server set to ${AppConfig.backendUrl}')));
  }

  @override
  Widget build(BuildContext context) {
    // Surface the "session expired" notice once when a 401 forced us back here,
    // so the user understands why they're at login (rather than seeing empty
    // tabs). Consumed immediately so a rebuild can't re-show it.
    final notice = widget.auth.notice;
    if (notice != null) {
      widget.auth.consumeNotice();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(notice),
          backgroundColor: AppColors.danger,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 5),
        ));
      });
    }
    if (_loadingPrefs) {
      return const Scaffold(
        backgroundColor: AppColors.bg,
        body: Center(child: CircularProgressIndicator(color: AppColors.copper)),
      );
    }
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Stack(children: [
        // Soft copper ambience behind the sign-in card.
        Positioned(
          top: -160,
          right: -120,
          child: Container(
            width: 460,
            height: 460,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  AppColors.copperDeep.withValues(alpha: 0.18),
                  Colors.transparent,
                ],
              ),
            ),
          ),
        ),
        Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: ForkCard(
                padding: const EdgeInsets.all(AppSpacing.x3l),
                child: _savedRestaurant == null
                    ? _restaurantStep()
                    : _credentialsStep(widget.auth),
              ),
            ),
          ),
        ),
        Positioned(
          top: 8,
          right: 8,
          child: SafeArea(
            child: IconButton(
              tooltip: 'Server: ${AppConfig.backendUrl}',
              icon: Icon(Icons.settings_outlined,
                  color: AppConfig.hasBackendOverride ? AppColors.copper : AppColors.textTertiary),
              onPressed: _editServerUrl,
            ),
          ),
        ),
      ]),
    );
  }

  /// Copper monogram + letter-spaced wordmark — the brand lockup.
  Widget _brandLockup() {
    return Row(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [AppColors.copperHi, AppColors.copperDeep],
            ),
            boxShadow: [
              BoxShadow(
                color: AppColors.copperShadow.withValues(alpha: 0.6),
                blurRadius: 16,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: const Icon(Icons.restaurant_menu, size: 22, color: AppColors.onCopper),
        ),
        const SizedBox(width: 14),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const [
            Text(
              'RESTAURANT DASH',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                letterSpacing: 2.4,
                color: AppColors.textPrimary,
              ),
            ),
            SizedBox(height: 3),
            Text(
              'Owner workspace',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.4,
                color: AppColors.textSecondary,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _restaurantStep() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _brandLockup(),
        const SizedBox(height: AppSpacing.x3l),
        Text('Set up this device', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 4),
        const Text('Enter your restaurant name to get started.',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 13)),
        const SizedBox(height: 24),
        TextField(
          controller: _restaurant,
          autofocus: true,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(labelText: 'Restaurant name'),
          onSubmitted: (_) => _saveRestaurant(),
        ),
        const SizedBox(height: 8),
        const Text('Saved on this device — staff just sign in after this.',
            style: TextStyle(fontSize: 12, color: AppColors.textTertiary)),
        const SizedBox(height: 24),
        Align(
          alignment: Alignment.centerLeft,
          child: ForkButton(
            label: 'Continue',
            icon: Icons.arrow_forward,
            onPressed: _saveRestaurant,
          ),
        ),
      ],
    );
  }

  Widget _credentialsStep(AuthController auth) {
    return AnimatedBuilder(
      animation: auth,
      builder: (context, _) => Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _brandLockup(),
            const SizedBox(height: AppSpacing.xl),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.inset,
                borderRadius: AppRadius.controlAll,
                border: Border.all(color: AppColors.border),
              ),
              child: Row(
                children: [
                  const Icon(Icons.storefront, size: 16, color: AppColors.copperHi),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(_savedRestaurant!,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          color: AppColors.textPrimary,
                        )),
                  ),
                  TextButton(onPressed: _changeRestaurant, child: const Text('Change')),
                ],
              ),
            ),
            const SizedBox(height: 16),
            if (auth.error != null) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.tint(AppColors.danger),
                  borderRadius: AppRadius.controlAll,
                  border: Border.all(color: AppColors.edge(AppColors.danger)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.error_outline, size: 16, color: AppColors.danger),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(auth.error!,
                          style: const TextStyle(color: AppColors.danger, fontSize: 12.5)),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],
            if (_loadingOutlets) ...[
              Row(
                children: const [
                  SizedBox(
                    height: 16,
                    width: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.copper),
                  ),
                  SizedBox(width: 10),
                  Text('Loading outlets…',
                      style: TextStyle(fontSize: 12.5, color: AppColors.textSecondary)),
                ],
              ),
              const SizedBox(height: 12),
            ] else if (_outlets.length > 1) ...[
              DropdownButtonFormField<String>(
                initialValue: _selectedOutletId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Outlet'),
                dropdownColor: AppColors.surface,
                iconEnabledColor: AppColors.textSecondary,
                style: const TextStyle(color: AppColors.textPrimary, fontSize: 14),
                items: [
                  for (final o in _outlets)
                    DropdownMenuItem<String>(
                      value: o['id'],
                      child: Text(
                        (o['name'] ?? '').isEmpty ? o['id']! : o['name']!,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                validator: (v) => (v == null || v.isEmpty) ? 'Required' : null,
                onChanged: (v) => setState(() => _selectedOutletId = v),
              ),
              const SizedBox(height: 12),
            ],
            TextFormField(
              controller: _username,
              decoration: const InputDecoration(labelText: 'Username'),
              validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _password,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Password'),
              validator: (v) => (v == null || v.isEmpty) ? 'Required' : null,
              onFieldSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: auth.busy ? null : _submit,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: auth.busy
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.onCopper))
                      : const Text('Sign in'),
                ),
              ),
            ),
            const SizedBox(height: 4),
            TextButton(
              onPressed: auth.busy ? null : _forgotPassword,
              child: const Text('Forgot password?'),
            ),
          ],
        ),
      ),
    );
  }
}
