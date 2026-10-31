import 'package:flutter/material.dart';

class PlayerPreparationIndicator extends StatelessWidget {
  const PlayerPreparationIndicator({
    super.key,
    required this.label,
    this.detail,
    this.progress,
    this.foregroundColor,
  });

  final String label;
  final String? detail;
  final double? progress;
  final Color? foregroundColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LinearProgressIndicator(
                value: progress,
                borderRadius: BorderRadius.circular(100),
                semanticsLabel: detail == null ? label : '$label / $detail',
              ),
              const SizedBox(height: 12),
              ExcludeSemantics(
                child: Text(
                  label,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: foregroundColor,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
              if (detail case final detail?) ...[
                const SizedBox(height: 4),
                ExcludeSemantics(
                  child: Text(
                    detail,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color:
                          foregroundColor ?? theme.colorScheme.onSurfaceVariant,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
