import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../settings/tool_settings.dart';

/// A scrolling column with the gaps every Configure tab wants.
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
  });

  final TextEditingController controller;
  final String label;
  final String? hint;
  final String? helper;
  final bool isNumber;
  final bool isSecret;
  final int maxLines;

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    obscureText: isSecret,
    maxLines: isSecret ? 1 : maxLines,
    keyboardType: isNumber ? TextInputType.number : null,
    inputFormatters: isNumber ? [FilteringTextInputFormatter.digitsOnly] : null,
    decoration: InputDecoration(labelText: label, hintText: hint, helperText: helper, border: const OutlineInputBorder(), isDense: true),
  );
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
          entry.key: TextEditingController(text: settings.value(entry.key, entry.value)),
      };

  final ToolSettings settings;
  final Map<String, TextEditingController> controllers;

  TextEditingController operator [](String key) => controllers[key]!;

  String text(String key) => controllers[key]!.text.trim();

  /// Throws [FormatException] naming the field, for a clear message.
  int number(String key, {int min = 0, int max = 0x7fffffff, String? label}) {
    final value = int.tryParse(text(key));
    if (value == null || value < min || value > max) {
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

/// Shows an error the way every tool does: a snackbar with the message.
void showError(BuildContext context, Object error) {
  final text = switch (error) {
    FormatException(:final message) => message,
    ArgumentError(:final message) => '$message',
    _ => '$error',
  };
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));
}
