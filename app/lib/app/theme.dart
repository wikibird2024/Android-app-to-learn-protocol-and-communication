import 'package:flutter/material.dart';

const _seedColor = Colors.indigo;

final lightTheme = ThemeData(colorSchemeSeed: _seedColor);

final darkTheme = ThemeData(
  colorSchemeSeed: _seedColor,
  brightness: Brightness.dark,
);

/// Hex, frames and terminals: fixed width so columns line up.
const monospace = TextStyle(fontFamily: 'monospace', fontSize: 13);
