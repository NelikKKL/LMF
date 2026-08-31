import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'screens/home_screen.dart';

void main() {
  runApp(const LmfApp());
}

class LmfApp extends StatelessWidget {
  const LmfApp({super.key});

  static const _fallbackSeed = Color(0xFF9AA6FF);

  @override
  Widget build(BuildContext context) {
    return DynamicColorBuilder(
      builder: (ColorScheme? lightDynamic, ColorScheme? darkDynamic) {
        final lightScheme = (lightDynamic ?? ColorScheme.fromSeed(
          seedColor: _fallbackSeed,
          brightness: Brightness.light,
        )).harmonized();

        final darkScheme = (darkDynamic ?? ColorScheme.fromSeed(
          seedColor: _fallbackSeed,
          brightness: Brightness.dark,
        )).harmonized().copyWith(
              surface: const Color(0xFF121212),
            );

        return MaterialApp(
          title: 'LMF',
          debugShowCheckedModeBanner: false,
          themeMode: ThemeMode.system,
          theme: ThemeData(
            colorScheme: lightScheme,
            useMaterial3: true,
            scaffoldBackgroundColor: lightScheme.surface,
          ),
          darkTheme: ThemeData(
            colorScheme: darkScheme,
            useMaterial3: true,
            scaffoldBackgroundColor: const Color(0xFF121212),
            cardColor: const Color(0xFF1C1C1C),
            appBarTheme: const AppBarTheme(
              backgroundColor: Color(0xFF121212),
              surfaceTintColor: Colors.transparent,
            ),
          ),
          home: const HomeScreen(),
        );
      },
    );
  }
}
