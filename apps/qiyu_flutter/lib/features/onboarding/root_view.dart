import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'first_meeting_view.dart';
import 'home_view.dart';
import 'onboarding_view_model.dart';

class RootView extends StatelessWidget {
  const RootView({super.key});

  @override
  Widget build(BuildContext context) {
    final viewModel = context.watch<OnboardingViewModel>();
    if (viewModel.loading) {
      return const Scaffold(
        body: SafeArea(child: Center(child: CircularProgressIndicator())),
      );
    }
    if (viewModel.errorMessage case final message?) {
      return Scaffold(
        body: SafeArea(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  message,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                const SizedBox(height: 12),
                TextButton(
                  key: const Key('retry-root'),
                  onPressed: () => unawaited(viewModel.initialize()),
                  child: const Text('重试'),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return viewModel.completed
        ? const HomeView()
        : const FirstMeetingView();
  }
}
