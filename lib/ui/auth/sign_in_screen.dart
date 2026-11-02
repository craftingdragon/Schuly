import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import '../../services/auth_service.dart';

/// Sign in to Schuly through an organization identity provider. Pops with true
/// after the provider flow completes.
class SignInScreen extends StatefulWidget {
  const SignInScreen({this.providersLoader, super.key});

  /// Defaults to the providers advertised by the server.
  final Future<List<SignInProvider>> Function()? providersLoader;

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  bool _busy = false;
  bool _loadingProviders = true;
  String? _error;
  List<SignInProvider> _providers = const [];

  @override
  void initState() {
    super.initState();
    _loadProviders();
  }

  Future<void> _loadProviders() async {
    setState(() {
      _loadingProviders = true;
      _providers = const [];
    });
    try {
      final providers = await (widget.providersLoader ?? AuthService.providers)();
      if (mounted) setState(() => _providers = providers);
    } catch (_) {
      if (mounted) setState(() => _providers = const []);
    } finally {
      if (mounted) setState(() => _loadingProviders = false);
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Schuly is not reachable right now. Try again in a moment.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signInWith(SignInProvider provider) => _run(() async {
        await AuthService.signInWithProvider(provider.key);
        if (mounted) Navigator.of(context).pop(true);
      });

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    return FScaffold(
      header: FHeader.nested(
        title: const Text('Schuly'),
        prefixes: [FHeaderAction.back(onPress: () => Navigator.of(context).pop(false))],
      ),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 24),
          children: [
            Text('Sign in to Schuly', style: theme.typography.xl2.copyWith(fontWeight: FontWeight.w600, color: theme.colors.foreground)),
            const SizedBox(height: 6),
            Text('Continue with your school or organization account.', style: theme.typography.sm.copyWith(color: theme.colors.mutedForeground)),
            const SizedBox(height: 24),
            AutofillGroup(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 16,
                children: [
                  if (_error != null) Text(_error!, style: theme.typography.sm.copyWith(color: theme.colors.destructive)),
                  if (_loadingProviders)
                    const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [FCircularProgress(), SizedBox(height: 8), Text('Loading sign-in options...')]))
                  else if (_providers.isEmpty) ...[
                    Text('No sign-in providers are available. Check your connection or contact your administrator.', style: theme.typography.sm.copyWith(color: theme.colors.mutedForeground)),
                    FButton(onPress: _loadProviders, child: const Text('Retry')),
                  ] else
                    for (final provider in _providers)
                      FButton(
                        onPress: _busy ? null : () => _signInWith(provider),
                        prefix: provider.iconUrl == null ? null : Image.network(provider.iconUrl!, width: 18, height: 18, errorBuilder: (_, _, _) => const SizedBox.shrink()),
                        child: _busy ? const SizedBox(width: 16, height: 16, child: FCircularProgress()) : Text('Continue with ${provider.displayName}'),
                      ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
