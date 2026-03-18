import 'package:flutter/material.dart';
import 'package:tuya_flutter_ha_sdk/tuya_flutter_ha_sdk.dart';
import '../main.dart' show sdkInitialised;
import 'home_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  bool _isRegister = true;
  bool _loading = false;
  bool _obscurePassword = true;

  Future<void> _submit() async {
    if (!sdkInitialised) {
      _showSnackBar(
          'SDK not ready. Please check security configuration on Tuya platform.');
      return;
    }

    final username = _usernameController.text.trim();
    final password = _passwordController.text;

    if (username.isEmpty || password.isEmpty) {
      _showSnackBar('Please fill in all fields');
      return;
    }

    if (username.length < 3) {
      _showSnackBar('Username must be at least 3 characters');
      return;
    }

    if (password.length < 6) {
      _showSnackBar('Password must be at least 6 characters');
      return;
    }

    if (_isRegister) {
      if (_confirmPasswordController.text != password) {
        _showSnackBar('Passwords do not match');
        return;
      }
    }

    setState(() => _loading = true);

    try {
      await TuyaFlutterHaSdk.loginWithUid(
        countryCode: '91',
        uid: username,
        password: password,
        createHome: true,
      );

      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const HomeScreen()),
        );
      }
    } catch (e) {
      _showSnackBar(_isRegister
          ? 'Registration failed. Please try again.'
          : 'Sign in failed. Check your credentials.');
    } finally {
      if (mounted) setState(() => _loading = false);
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
                            style:
                                TextStyle(color: cs.onErrorContainer, fontSize: 13),
                          ),
                        ),
                      ],
                    ),
                  ),

                Icon(Icons.home_rounded, size: 80, color: cs.primary),
                const SizedBox(height: 16),
                Text(
                  'Smart Home',
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
                const SizedBox(height: 8),
                Text(
                  _isRegister
                      ? 'Create your account to get started'
                      : 'Welcome back! Sign in to continue',
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
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

                TextField(
                  controller: _usernameController,
                  decoration: const InputDecoration(
                    labelText: 'Username',
                    hintText: 'Choose a username',
                    prefixIcon: Icon(Icons.person_outline),
                    border: OutlineInputBorder(),
                  ),
                  textInputAction: TextInputAction.next,
                ),
                const SizedBox(height: 16),

                TextField(
                  controller: _passwordController,
                  decoration: InputDecoration(
                    labelText: 'Password',
                    hintText: 'Min 6 characters',
                    prefixIcon: const Icon(Icons.lock_outline),
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      icon: Icon(_obscurePassword
                          ? Icons.visibility_off
                          : Icons.visibility),
                      onPressed: () =>
                          setState(() => _obscurePassword = !_obscurePassword),
                    ),
                  ),
                  obscureText: _obscurePassword,
                  textInputAction:
                      _isRegister ? TextInputAction.next : TextInputAction.done,
                  onSubmitted: _isRegister ? null : (_) => _submit(),
                ),

                if (_isRegister) ...[
                  const SizedBox(height: 16),
                  TextField(
                    controller: _confirmPasswordController,
                    decoration: const InputDecoration(
                      labelText: 'Confirm Password',
                      prefixIcon: Icon(Icons.lock_outline),
                      border: OutlineInputBorder(),
                    ),
                    obscureText: _obscurePassword,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _submit(),
                  ),
                ],

                const SizedBox(height: 24),

                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: FilledButton(
                    onPressed: _loading ? null : _submit,
                    child: _loading
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(_isRegister ? 'Create Account' : 'Sign In'),
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
    );
  }
}
