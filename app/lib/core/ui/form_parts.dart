import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../settings/tool_settings.dart';

/// A scrolling column with the gaps every Setup tab wants.
class FormColumn extends StatelessWidget {
  const FormColumn({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(12),
    children: [
      for (final child in children) Padding(padding: const EdgeInsets.only(bottom: 10), child: child),
    ],
  );
}

class LabeledField extends StatelessWidget {
  const LabeledField({
    super.key,
    required this.controller,
    required this.label,
    this.hint,
    this.isNumber = false,
    this.isSecret = false,
    this.maxLines = 1,
    this.helper,
    this.presets,
  });

  final TextEditingController controller;
  final String label;
  final String? hint;
  final String? helper;
  final bool isNumber;
  final bool isSecret;
  final int maxLines;

  /// Common values (value → what uses it) offered in a ▾ menu; typing any
  /// other value still works.
  final Map<String, String>? presets;

  @override
  Widget build(BuildContext context) {
    final controller = this.controller;
    final presets = this.presets;
    final menu = presets == null
        ? null
        : PopupMenuButton<String>(
            icon: const Icon(Icons.arrow_drop_down),
            tooltip: 'Common values',
            onSelected: (value) => controller.text = value,
            itemBuilder: (context) => [
              for (final MapEntry(key: value, value: use) in presets.entries)
                PopupMenuItem(value: value, child: Text(use.isEmpty ? value : '$value  ·  $use')),
            ],
          );
    Widget field(String? error) => TextField(
      controller: controller,
      obscureText: isSecret,
      maxLines: isSecret ? 1 : maxLines,
      keyboardType: isNumber ? TextInputType.number : null,
      inputFormatters: isNumber ? [FilteringTextInputFormatter.digitsOnly] : null,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        helperText: helper,
        errorText: error,
        errorMaxLines: 2,
        border: const OutlineInputBorder(),
        isDense: true,
        suffixIcon: menu,
      ),
    );
    if (controller is! SettingField) return field(null);
    return ValueListenableBuilder(valueListenable: controller.error, builder: (context, error, _) => field(error));
  }
}

/// A settings text field that can show why its value was refused, right
/// under the field (not only in a snackbar that disappears).
class SettingField extends TextEditingController {
  SettingField({super.text}) {
    addListener(() {
      if (text != _checkedText) error.value = null; // the user is fixing it
    });
  }

  final error = ValueNotifier<String?>(null);
  String? _checkedText;

  void refuse(String message) {
    _checkedText = text;
    error.value = message;
  }

  @override
  void dispose() {
    error.dispose();
    super.dispose();
  }
}

/// Choice from a short fixed list (QoS, parity, function code).
class ChoiceField<T> extends StatelessWidget {
  const ChoiceField({super.key, required this.label, required this.value, required this.options, required this.onChanged});

  final String label;
  final T value;
  final Map<T, String> options;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) => DropdownButtonFormField<T>(
    initialValue: value,
    isExpanded: true,
    decoration: InputDecoration(labelText: label, border: const OutlineInputBorder(), isDense: true),
    items: [for (final entry in options.entries) DropdownMenuItem(value: entry.key, child: Text(entry.value))],
    onChanged: (selected) {
      if (selected != null) onChanged(selected);
    },
  );
}

/// Text controllers that remember their last value per tool, and named
/// profiles ("bench PLC", "home broker") of all of them.
class SettingsControllers {
  SettingsControllers(this.settings, Map<String, String> defaults)
    : controllers = {
        for (final entry in defaults.entries)
          entry.key: SettingField(text: settings.value(entry.key, entry.value)),
      };

  final ToolSettings settings;
  final Map<String, SettingField> controllers;

  SettingField operator [](String key) => controllers[key]!;

  String text(String key) => controllers[key]!.text.trim();

  /// Throws [FormatException] naming the field, for a clear message.
  int number(String key, {int min = 0, int max = 0x7fffffff, String? label}) {
    final value = int.tryParse(text(key));
    if (value == null || value < min || value > max) {
      controllers[key]!.refuse('a number $min..$max');
      throw FormatException('${label ?? key}: a number $min..$max');
    }
    return value;
  }

  Map<String, String> get values => {for (final entry in controllers.entries) entry.key: entry.value.text};

  Future<void> remember() => settings.saveLast(values);

  void load(Map<String, String> values) {
    for (final entry in values.entries) {
      controllers[entry.key]?.text = entry.value;
    }
  }

  void dispose() {
    for (final controller in controllers.values) {
      controller.dispose();
    }
  }
}

/// Row with "Profiles" menu: load, save as, delete.
class ProfileBar extends StatefulWidget {
  const ProfileBar({super.key, required this.controllers, this.onLoaded});

  final SettingsControllers controllers;
  final VoidCallback? onLoaded;

  @override
  State<ProfileBar> createState() => _ProfileBarState();
}

class _ProfileBarState extends State<ProfileBar> {
  @override
  Widget build(BuildContext context) {
    final settings = widget.controllers.settings;
    final profiles = settings.profiles;
    return Wrap(
      spacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        const Icon(Icons.bookmarks_outlined, size: 18),
        for (final name in profiles.keys)
          InputChip(
            label: Text(name),
            onPressed: () {
              widget.controllers.load(profiles[name]!);
              widget.onLoaded?.call();
            },
            onDeleted: () async {
              await settings.deleteProfile(name);
              setState(() {});
            },
          ),
        ActionChip(
          avatar: const Icon(Icons.add, size: 16),
          label: const Text('Save profile'),
          onPressed: () async {
            final name = await _askName(context);
            if (name == null || name.isEmpty) return;
            await settings.saveProfile(name, widget.controllers.values);
            setState(() {});
          },
        ),
      ],
    );
  }

  Future<String?> _askName(BuildContext context) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Profile name'),
        content: TextField(controller: controller, autofocus: true, decoration: const InputDecoration(hintText: 'bench PLC')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('Save')),
        ],
      ),
    ).whenComplete(controller.dispose);
  }
}

/// An error in words a bench user can act on: what failed and what to
/// check. Connection errors from the OS get a hint; the rest keep their
/// message.
String friendlyError(Object error) => switch (error) {
  FormatException(:final message) => message,
  ArgumentError(:final message) => '$message',
  SocketException(:final message, :final osError) => _socketHint('$message ${osError?.message ?? ''}', error),
  TimeoutException() => 'No reply in time. Check the address, that the phone and the device share a network, and that the device is powered.',
  TlsException() => 'TLS failed: plain port vs TLS port mixed up (MQTT 1883 vs 8883), or the server certificate is not trusted.',
  _ => '$error',
};

String _socketHint(String text, SocketException error) {
  final lower = text.toLowerCase();
  if (lower.contains('refused')) {
    return 'Connection refused: the host answered, but nothing listens on port ${error.port ?? '?'}. Is the server / broker running?';
  }
  if (lower.contains('host lookup') || lower.contains('no address')) {
    return 'Host name not found. Check the spelling, or use the IP address (mDNS finder).';
  }
  if (lower.contains('timed out') || lower.contains('unreachable')) {
    return 'No answer from the host. Is the phone on the same Wi-Fi as the device?';
  }
  return 'Network error: $text';
}

/// Shows an error the way every tool does: a snackbar that stays until it
/// is read (8 s or closed), with a hint from [friendlyError].
void showError(BuildContext context, Object error) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(friendlyError(error)),
      behavior: SnackBarBehavior.floating,
      showCloseIcon: true,
      duration: const Duration(seconds: 8),
    ));
}
