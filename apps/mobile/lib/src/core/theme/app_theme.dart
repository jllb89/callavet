import 'package:flutter/material.dart';

class AppTheme {
  static ThemeData get light => ThemeData(
        useMaterial3: true,
        colorScheme: _lightScheme,
        scaffoldBackgroundColor: _lightScheme.background,
      fontFamily: 'ABCDiatype',
      appBarTheme: const AppBarTheme(centerTitle: true),
      );

  static ThemeData get dark => ThemeData(
        useMaterial3: true,
        colorScheme: _darkScheme,
        scaffoldBackgroundColor: _darkScheme.background,
      fontFamily: 'ABCDiatype',
      appBarTheme: const AppBarTheme(centerTitle: true),
      );

  static const _lightScheme = ColorScheme(
    brightness: Brightness.light,
    primary: Color(0xFF0D0D0D),
    onPrimary: Color(0xFFFFFFFF),
    secondary: Color(0xFF1F1F1F),
    onSecondary: Color(0xFFFFFFFF),
    error: Color(0xFFB3261E),
    onError: Color(0xFFFFFFFF),
    background: Color(0xFFF7F7F7),
    onBackground: Color(0xFF0E0E0E),
    surface: Color(0xFFFFFFFF),
    onSurface: Color(0xFF0E0E0E),
  );

  static const _darkScheme = ColorScheme(
    brightness: Brightness.dark,
    primary: Color(0xFFFFFFFF),
    onPrimary: Color(0xFF0D0D0D),
    secondary: Color(0xFFE5E5E5),
    onSecondary: Color(0xFF0D0D0D),
    error: Color(0xFFFFB4AB),
    onError: Color(0xFF690005),
    background: Color(0xFF0B0B0B),
    onBackground: Color(0xFFF4F4F4),
    surface: Color(0xFF111111),
    onSurface: Color(0xFFF4F4F4),
  );
}
