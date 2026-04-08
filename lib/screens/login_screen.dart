import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:loader_overlay/loader_overlay.dart';
import 'package:tuya_flutter_ha_sdk/tuya_flutter_ha_sdk.dart';
import '../main.dart' show sdkInitialised;
import '../services/auth_storage.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  bool _isRegister = true;
  bool _obscurePassword = true;

  String? _validateUsername(String? value) {
    if (value == null || value.trim().isEmpty) return 'Username is required';
    if (value.trim().length < 3) return 'Must be at least 3 characters';
    return null;
  }

  String? _validatePassword(String? value) {
    if (value == null || value.isEmpty) return 'Password is required';
    if (value.length < 6) return 'Must be at least 6 characters';
    return null;
  }

  String? _validateConfirmPassword(String? value) {
    if (!_isRegister) return null;
    if (value != _passwordController.text) return 'Passwords do not match';
    return null;
  }

  Future<void> _submit() async {
    if (!sdkInitialised) {
      _showSnackBar(
          'SDK not ready. Check security configuration on Tuya platform.');
      return;
    }

    if (!_formKey.currentState!.validate()) return;

    final username = _usernameController.text.trim();
    final password = _passwordController.text;

    context.loaderOverlay.show();

    try {
      await TuyaFlutterHaSdk.loginWithUid(
        countryCode: '91',
        uid: username,
        password: password,
        createHome: true,
      );

      // Save credentials for auto-login
      await AuthStorage.instance.saveCredentials(
        username: username,
        password: password,
      );

      if (mounted) {
        context.loaderOverlay.hide();
        context.go('/home');
      }
    } catch (e) {
      if (mounted) {
        context.loaderOverlay.hide();
        _showSnackBar(_isRegister
            ? 'Registration failed. Please try again.'
            : 'Sign in failed. Check your credentials.');
      }
    }
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // SDK warning banner
                  if (!sdkInitialised)
                    Container(
                      width: double.infinity,
                      margin: const EdgeInsets.only(bottom: 24),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: cs.errorContainer,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.warning_amber_rounded,
                              color: cs.onErrorContainer),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'SDK not initialized. Re-download security AAR from Tuya platform.',
                              style: TextStyle(
                                  color: cs.onErrorContainer, fontSize: 13),
                            ),
                          ),
                        ],
                      ),
                    ),

                  Icon(Icons.home_rounded, size: 80, color: cs.primary),
                  const SizedBox(height: 16),
                  Text(
                    'Smart Home',
                    style: Theme.of(context)
                        .textTheme
                        .headlineMedium
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _isRegister
                        ? 'Create your account to get started'
                        : 'Welcome back! Sign in to continue',
                    style: Theme.of(context)
                        .textTheme
                        .bodyLarge
                        ?.copyWith(color: cs.onSurfaceVariant),
                  ),
                  const SizedBox(height: 32),

                  SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(value: true, label: Text('Register')),
                      ButtonSegment(value: false, label: Text('Sign In')),
                    ],
                    selected: {_isRegister},
                    onSelectionChanged: (s) =>
                        setState(() => _isRegister = s.first),
                  ),
                  const SizedBox(height: 24),

                  TextFormField(
                    controller: _usernameController,
                    validator: _validateUsername,
                    decoration: const InputDecoration(
                      labelText: 'Username',
                      hintText: 'Choose a username',
                      prefixIcon: Icon(Icons.person_outline),
                      border: OutlineInputBorder(),
                    ),
                    textInputAction: TextInputAction.next,
                  ),
                  const SizedBox(height: 16),

                  TextFormField(
                    controller: _passwordController,
                    validator: _validatePassword,
                    decoration: InputDecoration(
                      labelText: 'Password',
                      hintText: 'Min 6 characters',
                      prefixIcon: const Icon(Icons.lock_outline),
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: Icon(_obscurePassword
                            ? Icons.visibility_off
                            : Icons.visibility),
                        onPressed: () => setState(
                            () => _obscurePassword = !_obscurePassword),
                      ),
                    ),
                    obscureText: _obscurePassword,
                    textInputAction: _isRegister
                        ? TextInputAction.next
                        : TextInputAction.done,
                    onFieldSubmitted:
                        _isRegister ? null : (_) => _submit(),
                  ),

                  if (_isRegister) ...[
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _confirmPasswordController,
                      validator: _validateConfirmPassword,
                      decoration: const InputDecoration(
                        labelText: 'Confirm Password',
                        prefixIcon: Icon(Icons.lock_outline),
                        border: OutlineInputBorder(),
                      ),
                      obscureText: _obscurePassword,
                      textInputAction: TextInputAction.done,
                      onFieldSubmitted: (_) => _submit(),
                    ),
                  ],

                  const SizedBox(height: 24),

                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: FilledButton(
                      onPressed: _submit,
                      child:
                          Text(_isRegister ? 'Create Account' : 'Sign In'),
                    ),
                  ),

                  const SizedBox(height: 16),
                  TextButton(
                    onPressed: () =>
                        setState(() => _isRegister = !_isRegister),
                    child: Text(_isRegister
                        ? 'Already have an account? Sign In'
                        : "Don't have an account? Register"),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
