import 'dart:convert';
import 'dart:io';

import 'markdown_memory_repository.dart';

final class OnboardingStateException implements Exception {
  const OnboardingStateException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() => message;
}

final class OnboardingState {
  const OnboardingState({required this.completed, this.completedAt});

  factory OnboardingState.fromJson(Map<String, Object?> json) =>
      OnboardingState(
        completed: json['completed'] == true,
        completedAt: json['completedAt'] as String?,
      );

  final bool completed;
  final String? completedAt;

  Map<String, Object?> toJson() => {
    'schemaVersion': 1,
    'completed': completed,
    if (completedAt != null) 'completedAt': completedAt,
  };
}

abstract interface class OnboardingRepository {
  Future<OnboardingState> load();

  Future<OnboardingState> markCompleted(DateTime at);
}

final class JsonOnboardingRepository implements OnboardingRepository {
  const JsonOnboardingRepository({
    required this.filePath,
    this.writer = const IoAtomicTextWriter(),
  });

  final String filePath;
  final AtomicTextWriter writer;

  @override
  Future<OnboardingState> load() async {
    final file = File(filePath);
    if (!await file.exists()) {
      return const OnboardingState(completed: false);
    }
    try {
      final json =
          jsonDecode(await file.readAsString()) as Map<String, Object?>;
      return OnboardingState.fromJson(json);
    } on Object {
      return const OnboardingState(completed: false);
    }
  }

  @override
  Future<OnboardingState> markCompleted(DateTime at) async {
    final state = OnboardingState(
      completed: true,
      completedAt: at.toUtc().toIso8601String(),
    );
    try {
      await writer.replace(
        filePath,
        '${const JsonEncoder.withIndent('  ').convert(state.toJson())}\n',
      );
    } on Object catch (error) {
      throw OnboardingStateException('首次见面状态无法保存。', error);
    }
    return state;
  }
}
