import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Loaded once in main() and passed in with an override.
final sharedPreferencesProvider = Provider<SharedPreferences>(
  (ref) => throw UnimplementedError('override sharedPreferencesProvider'),
);

/// A tool's last-used settings (host, port, baud...) plus named profiles,
/// so a bench setup is one tap away next time. Stored as strings in
/// SharedPreferences under `tool.<toolId>.*`.
class ToolSettings {
  ToolSettings(this._preferences, this.toolId);

  final SharedPreferences _preferences;
  final String toolId;

  String get _lastKey => 'tool.$toolId.last';
  String get _profilesKey => 'tool.$toolId.profiles';

  Map<String, String> get last => _decode(_preferences.getString(_lastKey));

  String value(String key, String fallback) => last[key] ?? fallback;

  Future<void> saveLast(Map<String, String> values) =>
      _preferences.setString(_lastKey, jsonEncode(values));

  Map<String, Map<String, String>> get profiles {
    final raw = _preferences.getString(_profilesKey);
    if (raw == null) return {};
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return {
        for (final entry in json.entries)
          entry.key: _decode(jsonEncode(entry.value)),
      };
    } on Object {
      return {};
    }
  }

  Future<void> saveProfile(String name, Map<String, String> values) {
    final all = profiles..[name] = values;
    return _preferences.setString(_profilesKey, jsonEncode(all));
  }

  Future<void> deleteProfile(String name) {
    final all = profiles..remove(name);
    return _preferences.setString(_profilesKey, jsonEncode(all));
  }

  static Map<String, String> _decode(String? raw) {
    if (raw == null) return {};
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return {};
      return {for (final entry in json.entries) '${entry.key}': '${entry.value}'};
    } on FormatException {
      return {};
    }
  }
}

final toolSettingsProvider = Provider.family<ToolSettings, String>(
  (ref, toolId) => ToolSettings(ref.watch(sharedPreferencesProvider), toolId),
);
