import 'package:flutter/material.dart';

class AppTheme {
  static ThemeData get light => ThemeData(
        useMaterial3: true,
        colorScheme: _lightScheme,
        scaffoldBackgroundColor: _lightScheme.surface,
        fontFamily: 'ABCDiatype',
        appBarTheme: const AppBarTheme(centerTitle: false),
        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: _lightScheme.surface,
          indicatorColor: _lightScheme.primaryContainer,
        ),
      );

  static ThemeData get dark => ThemeData(
        useMaterial3: true,
        colorScheme: _darkScheme,
        scaffoldBackgroundColor: _darkScheme.surface,
        fontFamily: 'ABCDiatype',
        appBarTheme: const AppBarTheme(centerTitle: false),
        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: _darkScheme.surface,
          indicatorColor: _darkScheme.primaryContainer,
        ),
      );

  static final _lightScheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF14382C),
    brightness: Brightness.light,
  ).copyWith(
    primary: const Color(0xFF14382C),
    onPrimary: const Color(0xFFFFFFFF),
    primaryContainer: const Color(0xFFDCEBE4),
    onPrimaryContainer: const Color(0xFF0C211A),
    secondary: const Color(0xFF6E5133),
    onSecondary: const Color(0xFFFFFFFF),
    secondaryContainer: const Color(0xFFF3E3D0),
    onSecondaryContainer: const Color(0xFF2D1C0D),
    tertiary: const Color(0xFF375A7F),
    onTertiary: const Color(0xFFFFFFFF),
    tertiaryContainer: const Color(0xFFDCE8F7),
    onTertiaryContainer: const Color(0xFF0E2238),
    error: const Color(0xFFB3261E),
    onError: const Color(0xFFFFFFFF),
    surface: const Color(0xFFF4F1EA),
    onSurface: const Color(0xFF171713),
    surfaceContainerHighest: const Color(0xFFE4DED2),
    onSurfaceVariant: const Color(0xFF4A473F),
    outline: const Color(0xFF7A7468),
    shadow: const Color(0xFF000000),
    inverseSurface: const Color(0xFF302F2A),
    onInverseSurface: const Color(0xFFF5F0E8),
    inversePrimary: const Color(0xFFA7D2BE),
  );

  static final _darkScheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFFA7D2BE),
    brightness: Brightness.dark,
  ).copyWith(
    primary: const Color(0xFFA7D2BE),
    onPrimary: const Color(0xFF083125),
    primaryContainer: const Color(0xFF214C3D),
    onPrimaryContainer: const Color(0xFFDCEBE4),
    secondary: const Color(0xFFE4C9A9),
    onSecondary: const Color(0xFF3E2712),
    secondaryContainer: const Color(0xFF584023),
    onSecondaryContainer: const Color(0xFFF3E3D0),
    tertiary: const Color(0xFFB7D3F2),
    onTertiary: const Color(0xFF18324D),
    tertiaryContainer: const Color(0xFF284563),
    onTertiaryContainer: const Color(0xFFDCE8F7),
    error: const Color(0xFFFFB4AB),
    onError: const Color(0xFF690005),
    surface: const Color(0xFF11130F),
    onSurface: const Color(0xFFE7E2D9),
    surfaceContainerHighest: const Color(0xFF4A473F),
    onSurfaceVariant: const Color(0xFFCFC7B8),
    outline: const Color(0xFF999184),
    shadow: const Color(0xFF000000),
    inverseSurface: const Color(0xFFE7E2D9),
    onInverseSurface: const Color(0xFF302F2A),
    inversePrimary: const Color(0xFF14382C),
  );
}
