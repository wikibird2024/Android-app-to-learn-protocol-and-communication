import 'package:flutter/material.dart';

const _seedColor = Colors.indigo;

final lightTheme = _theme(Brightness.light);
final darkTheme = _theme(Brightness.dark);

ThemeData _theme(Brightness brightness) {
  final colors = ColorScheme.fromSeed(seedColor: _seedColor, brightness: brightness);
  final isDark = brightness == Brightness.dark;
  return ThemeData(
    colorScheme: colors,
    extensions: [
      StatusColors(
        ok: isDark ? const Color(0xff7bd88f) : const Color(0xff1e8e3e),
        warn: isDark ? const Color(0xffffc857) : const Color(0xffb26a00),
        sent: colors.primary,
        received: colors.tertiary,
        note: colors.outline,
      ),
    ],
  );
}

/// What a color means, the same on every screen: green = connected, sent
/// lines in primary, received in tertiary (like a serial terminal's two
/// colors). Errors use the theme's own `colorScheme.error`.
class StatusColors extends ThemeExtension<StatusColors> {
  const StatusColors({required this.ok, required this.warn, required this.sent, required this.received, required this.note});

  final Color ok;
  final Color warn;
  final Color sent;
  final Color received;
  final Color note;

  static StatusColors of(BuildContext context) => Theme.of(context).extension<StatusColors>()!;

  @override
  StatusColors copyWith({Color? ok, Color? warn, Color? sent, Color? received, Color? note}) => StatusColors(
    ok: ok ?? this.ok,
    warn: warn ?? this.warn,
    sent: sent ?? this.sent,
    received: received ?? this.received,
    note: note ?? this.note,
  );

  @override
  StatusColors lerp(StatusColors? other, double t) => other == null
      ? this
      : StatusColors(
          ok: Color.lerp(ok, other.ok, t)!,
          warn: Color.lerp(warn, other.warn, t)!,
          sent: Color.lerp(sent, other.sent, t)!,
          received: Color.lerp(received, other.received, t)!,
          note: Color.lerp(note, other.note, t)!,
        );
}

/// Hex, frames and terminals: fixed width so columns line up. JetBrains
/// Mono ships in the app, so every phone shows the same glyphs (0 vs O).
const monospace = TextStyle(fontFamily: 'JetBrainsMono', fontFamilyFallback: ['monospace'], fontSize: 13);
