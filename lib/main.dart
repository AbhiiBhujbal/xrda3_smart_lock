import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:loader_overlay/loader_overlay.dart';
import 'package:tuya_flutter_ha_sdk/tuya_flutter_ha_sdk.dart';
import 'config/tuya_config.dart';
import 'services/auth_storage.dart';
import 'screens/login_screen.dart';
import 'screens/home_screen.dart';
import 'screens/device_control_screen.dart';
import 'screens/device_pairing_screen.dart';
import 'screens/smart_lock_screen.dart';
import 'screens/camera_screen.dart';
import 'screens/home_management_screen.dart';
import 'screens/room_management_screen.dart';

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

  // Check for auto-login
  bool autoLoggedIn = false;
  if (sdkInitialised) {
    try {
      final isLoggedIn = await TuyaFlutterHaSdk.checkLogin();
      if (isLoggedIn) {
        autoLoggedIn = true;
      } else {
        // Try re-login from stored credentials
        autoLoggedIn = await _tryAutoLogin();
      }
    } catch (_) {
      autoLoggedIn = await _tryAutoLogin();
    }
  }

  runApp(TuyaWorkApp(initiallyLoggedIn: autoLoggedIn));
}

/// Attempt auto-login using saved credentials from FlutterSecureStorage.
Future<bool> _tryAutoLogin() async {
  try {
    if (!await AuthStorage.instance.hasCredentials()) return false;
    final creds = await AuthStorage.instance.getCredentials();
    if (creds.username == null || creds.password == null) return false;

    await TuyaFlutterHaSdk.loginWithUid(
      countryCode: '91',
      uid: creds.username!,
      password: creds.password!,
      createHome: true,
    );
    debugPrint('Auto-login successful');
    return true;
  } catch (e) {
    debugPrint('Auto-login failed: $e');
    return false;
  }
}

class TuyaWorkApp extends StatelessWidget {
  final bool initiallyLoggedIn;
  const TuyaWorkApp({super.key, required this.initiallyLoggedIn});

  @override
  Widget build(BuildContext context) {
    final router = GoRouter(
      initialLocation: initiallyLoggedIn ? '/home' : '/login',
      routes: [
        GoRoute(
          path: '/login',
          name: 'login',
          builder: (_, __) => const LoginScreen(),
        ),
        GoRoute(
          path: '/home',
          name: 'home',
          builder: (_, __) => const HomeScreen(),
        ),
        GoRoute(
          path: '/pairing/:homeId',
          name: 'pairing',
          builder: (_, state) {
            final homeId = int.parse(state.pathParameters['homeId']!);
            final mode = state.uri.queryParameters['mode'];
            return DevicePairingScreen(homeId: homeId, initialMode: mode);
          },
        ),
        GoRoute(
          path: '/device/:devId',
          name: 'device',
          builder: (_, state) {
            final devId = state.pathParameters['devId']!;
            final name = state.uri.queryParameters['name'] ?? 'Device';
            return DeviceControlScreen(devId: devId, deviceName: name);
          },
        ),
        GoRoute(
          path: '/lock/:devId',
          name: 'lock',
          builder: (_, state) {
            final devId = state.pathParameters['devId']!;
            final name = state.uri.queryParameters['name'] ?? 'Smart Lock';
            final homeId = int.tryParse(
                state.uri.queryParameters['homeId'] ?? '');
            return SmartLockScreen(
              devId: devId,
              deviceName: name,
              homeId: homeId,
            );
          },
        ),
        GoRoute(
          path: '/camera/:homeId',
          name: 'camera',
          builder: (_, state) {
            final homeId = int.parse(state.pathParameters['homeId']!);
            return CameraScreen(homeId: homeId);
          },
        ),
        GoRoute(
          path: '/homes',
          name: 'homes',
          builder: (_, __) => const HomeManagementScreen(),
        ),
        GoRoute(
          path: '/rooms/:homeId',
          name: 'rooms',
          builder: (_, state) {
            final homeId = int.parse(state.pathParameters['homeId']!);
            return RoomManagementScreen(homeId: homeId);
          },
        ),
      ],
    );

    return GlobalLoaderOverlay(
      overlayWidgetBuilder: (_) => const Center(
        child: CircularProgressIndicator(),
      ),
      child: MaterialApp.router(
        title: 'Smart Home',
        debugShowCheckedModeBanner: false,
        routerConfig: router,
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
      ),
    );
  }
}
