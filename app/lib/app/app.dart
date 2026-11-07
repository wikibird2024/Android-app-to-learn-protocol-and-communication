import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'router.dart';
import 'theme.dart';

class ProtocolLabApp extends ConsumerWidget {
  const ProtocolLabApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp.router(
      title: 'Protocol Lab',
      theme: lightTheme,
      darkTheme: darkTheme,
      routerConfig: ref.watch(routerProvider),
    );
  }
}
