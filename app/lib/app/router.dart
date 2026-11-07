import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../tools/tool_catalog.dart';
import 'home_screen.dart';

/// Home lists the tools; each tool is its own page, and leaving it disposes
/// it, which closes its connection.
final routerProvider = Provider<GoRouter>((ref) {
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => const HomeScreen(),
        routes: [
          GoRoute(
            path: 'tool/:id',
            builder: (context, state) {
              final tool = toolById(state.pathParameters['id']!);
              return tool == null
                  ? const Scaffold(body: Center(child: Text('Unknown tool')))
                  : tool.builder(context);
            },
          ),
        ],
      ),
    ],
  );
  ref.onDispose(router.dispose);
  return router;
});
