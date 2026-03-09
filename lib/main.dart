import 'dart:async';

import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:google_fonts/google_fonts.dart';

import 'app_navigator.dart';
import 'deep_link_service.dart';
import 'app_theme.dart';
import 'notification_service.dart';
import 'user_service.dart';
import 'chats_home.dart';
import 'user_presence_service.dart';

bool _startupServicesInitialized = false;

Future<void> _startDeferredStartupServices() async {
  if (_startupServicesInitialized) return;
  _startupServicesInitialized = true;
  unawaited(NotificationService.initialize());
  unawaited(DeepLinkService.initialize());
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await NotificationService.registerBackgroundHandler();
  await Firebase.initializeApp();
  await AppThemeController.initialize();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  ThemeData _buildTheme({required Color seed, required Brightness brightness}) {
    final isDark = brightness == Brightness.dark;
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: seed,
        brightness: brightness,
      ),
      scaffoldBackgroundColor: isDark
          ? const Color(0xFF0F141B)
          : const Color(0xFFF2F6FC),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
      ),
    );

    final textTheme = GoogleFonts.manropeTextTheme(base.textTheme).copyWith(
      headlineLarge: GoogleFonts.sora(
        fontWeight: FontWeight.w700,
        fontSize: 32,
        color: base.colorScheme.onSurface,
      ),
      headlineMedium: GoogleFonts.sora(
        fontWeight: FontWeight.w700,
        color: base.colorScheme.onSurface,
      ),
      titleLarge: GoogleFonts.sora(
        fontWeight: FontWeight.w700,
        color: base.colorScheme.onSurface,
      ),
      labelLarge: GoogleFonts.manrope(fontWeight: FontWeight.w700),
    );

    return base.copyWith(
      textTheme: textTheme,
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleTextStyle: textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w800,
        ),
      ),
      cardTheme: CardThemeData(
        color: isDark
            ? const Color(0xFF171F2A).withValues(alpha: 0.95)
            : Colors.white.withValues(alpha: 0.98),
        elevation: isDark ? 0 : 1.2,
        shadowColor: Colors.black.withValues(alpha: isDark ? 0.20 : 0.08),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark ? const Color(0xFF1A2431) : Colors.white,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(
            color: isDark
                ? Colors.white.withValues(alpha: 0.05)
                : Colors.black.withValues(alpha: 0.05),
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: base.colorScheme.primary, width: 1.3),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          elevation: 0,
          textStyle: textTheme.labelLarge,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
      chipTheme: base.chipTheme.copyWith(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) {
        return ValueListenableBuilder<ThemeMode>(
          valueListenable: AppThemeController.mode,
          builder: (context, mode, child) {
            return ValueListenableBuilder<Color>(
              valueListenable: AppThemeController.seed,
              builder: (context, seed, child) {
                final resolvedSeed = lightDynamic?.primary ?? seed;
                return MaterialApp(
                  debugShowCheckedModeBanner: false,
                  navigatorKey: AppNavigator.navigatorKey,
                  theme: _buildTheme(
                    seed: resolvedSeed,
                    brightness: Brightness.light,
                  ),
                  darkTheme: _buildTheme(
                    seed: darkDynamic?.primary ?? resolvedSeed,
                    brightness: Brightness.dark,
                  ),
                  themeMode: mode,
                  home: const AppEntry(),
                );
              },
            );
          },
        );
      },
    );
  }
}

class AppEntry extends StatefulWidget {
  const AppEntry({super.key});

  @override
  State<AppEntry> createState() => _AppEntryState();
}

class _AppEntryState extends State<AppEntry> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_startDeferredStartupServices());
    });
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      initialData: FirebaseAuth.instance.currentUser,
      builder: (context, snap) {
        final user = snap.data;
        if (user == null) return const GoogleLoginScreen();
        return const SessionPresence(child: ChatsHome());
      },
    );
  }
}

class GoogleLoginScreen extends StatefulWidget {
  const GoogleLoginScreen({super.key});

  @override
  State<GoogleLoginScreen> createState() => _GoogleLoginScreenState();
}

class _GoogleLoginScreenState extends State<GoogleLoginScreen> {
  bool loading = false;
  String error = '';

  Future<void> signInWithGoogle() async {
    setState(() {
      loading = true;
      error = '';
    });

    try {
      final googleSignIn = GoogleSignIn();

      // مهم: ده يمنع تعليق اختيار الحساب
      try {
        await googleSignIn.disconnect();
      } catch (_) {}

      final googleUser = await googleSignIn.signIn();
      if (googleUser == null) {
        if (mounted) setState(() => loading = false);
        return;
      }

      final googleAuth = await googleUser.authentication;

      final credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );

      await FirebaseAuth.instance.signInWithCredential(credential);

      // خزّن الاسم/الصورة/الإيميل في users/{uid}
      await UserService.upsertMe();

      if (!mounted) return;
      await Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(
          builder: (_) => const SessionPresence(child: ChatsHome()),
        ),
        (route) => false,
      );
    } on FirebaseAuthException catch (e) {
      setState(() => error = e.message ?? 'FirebaseAuth error');
    } catch (e) {
      setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              colors.primaryContainer.withValues(alpha: isDark ? 0.35 : 0.9),
              colors.surface,
              isDark ? const Color(0xFF101822) : const Color(0xFFE9F5FF),
            ],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 430),
                child: Card(
                  elevation: 8,
                  shadowColor: Colors.black26,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 30, 24, 24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Align(
                          child: Container(
                            width: 72,
                            height: 72,
                            decoration: BoxDecoration(
                              color: colors.primary.withValues(alpha: 0.12),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              Icons.chat_rounded,
                              size: 36,
                              color: colors.primary,
                            ),
                          ),
                        ),
                        const SizedBox(height: 18),
                        Text(
                          'Welcome to Noon Chat',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Sign in with Google to start chatting instantly.',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(color: colors.onSurfaceVariant),
                        ),
                        const SizedBox(height: 24),
                        FilledButton.icon(
                          onPressed: loading ? null : signInWithGoogle,
                          icon: const Icon(Icons.login_rounded),
                          label: Text(
                            loading ? 'Signing in...' : 'Continue with Google',
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          style: FilledButton.styleFrom(
                            minimumSize: const Size.fromHeight(54),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                        ),
                        AnimatedSize(
                          duration: const Duration(milliseconds: 220),
                          curve: Curves.easeOut,
                          child: loading
                              ? const Padding(
                                  padding: EdgeInsets.only(top: 14),
                                  child: Center(
                                    child: SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2.4,
                                      ),
                                    ),
                                  ),
                                )
                              : const SizedBox.shrink(),
                        ),
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 220),
                          child: error.isEmpty
                              ? const SizedBox.shrink()
                              : Container(
                                  key: ValueKey(error),
                                  margin: const EdgeInsets.only(top: 14),
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: colors.errorContainer,
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Text(
                                    error,
                                    style: TextStyle(
                                      color: colors.onErrorContainer,
                                      fontSize: 13,
                                    ),
                                  ),
                                ),
                        ),
                        const SizedBox(height: 14),
                        Text(
                          'By continuing, you agree to use your Google account for authentication.',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: colors.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
