import 'package:flutter/material.dart';
import 'package:tuya_flutter_ha_sdk/tuya_flutter_ha_sdk.dart';
import 'config/tuya_config.dart';
import 'screens/login_screen.dart';
import 'screens/home_screen.dart';

/// Global flag so screens can show a banner if SDK didn't init
bool sdkInitialised = false;
String? sdkInitError;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    await TuyaFlutterHaSdk.tuyaSdkInit(
      androidKey: TuyaConfig.androidAppKey,
      androidSecret: TuyaConfig.androidAppSecret,
      iosKey: TuyaConfig.iosAppKey,
      iosSecret: TuyaConfig.iosAppSecret,
    );
    sdkInitialised = true;
    debugPrint('Tuya SDK initialized successfully');
  } catch (e) {
    sdkInitError = e.toString();
    debugPrint('Tuya SDK init failed: $e');
  }

  runApp(const TuyaWorkApp());
}

class TuyaWorkApp extends StatelessWidget {
  const TuyaWorkApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Smart Home',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF00B294),
        useMaterial3: true,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: const Color(0xFF00B294),
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      home: const AuthGate(),
    );
  }
}

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  bool _checking = true;
  bool _loggedIn = false;

  @override
  void initState() {
    super.initState();
    _checkLogin();
  }

  Future<void> _checkLogin() async {
    if (!sdkInitialised) {
      // SDK didn't init — go straight to login screen
      setState(() => _checking = false);
      return;
    }
    try {
      final isLoggedIn = await TuyaFlutterHaSdk.checkLogin();
      setState(() {
        _loggedIn = isLoggedIn;
        _checking = false;
      });
    } catch (e) {
      setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    return _loggedIn ? const HomeScreen() : const LoginScreen();
  }
}
