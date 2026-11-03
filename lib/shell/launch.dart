import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'strings.dart';

/// Native startup and recovery, available before the web view is ready.
class LaunchScreen extends StatelessWidget {
  const LaunchScreen({
    super.key,
    required this.t,
    required this.progress,
    required this.slow,
    required this.error,
    this.errorTitle,
    this.onRetry,
    this.onSaves,
    this.onOpenBrowser,
  });
  final Strings t;
  final int progress;
  final bool slow;
  final String? error;
  final String? errorTitle;
  final VoidCallback? onRetry;
  final VoidCallback? onSaves;
  final VoidCallback? onOpenBrowser;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context), scheme = theme.colorScheme;
    final failed = error != null;
    final status = SizedBox(
      width: 280,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 88),
        child: failed
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Symbols.cloud_off_rounded,
                        size: 20,
                        color: scheme.error,
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          errorTitle ?? t['offline'],
                          style: theme.textTheme.titleSmall,
                        ),
                      ),
                    ],
                  ),
                  if (error != (errorTitle ?? t['offline'])) ...[
                    const SizedBox(height: 4),
                    Text(
                      error!,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  LinearProgressIndicator(
                    value: progress > 0 ? progress / 100 : null,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    progress > 0
                        ? t.format('loading', {'percent': progress})
                        : t['connecting'],
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  if (slow)
                    Text(
                      t['slow'],
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
      ),
    );
    final brand = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Image.asset(
          'assets/brand/android-chrome-512x512.png',
          width: 96,
          height: 96,
        ),
        const SizedBox(height: 16),
        Text('haneoka', style: theme.textTheme.headlineSmall),
        const SizedBox(height: 32),
        status,
      ],
    );
    final actions = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (failed || slow) ...[
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Symbols.refresh_rounded),
              label: Text(t['retry']),
            ),
          ),
          const SizedBox(height: 12),
          if (onOpenBrowser != null) ...[
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: onOpenBrowser,
                icon: const Icon(Symbols.open_in_browser_rounded),
                label: Text(t['openBrowser']),
              ),
            ),
            const SizedBox(height: 12),
          ],
        ],
        if (onSaves != null)
          SizedBox(
            width: double.infinity,
            child: FilledButton.tonalIcon(
              onPressed: onSaves,
              icon: const Icon(Symbols.sports_esports_rounded),
              label: Text(t['readSave']),
            ),
          ),
      ],
    );
    return ColoredBox(
      color: theme.scaffoldBackgroundColor,
      child: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide =
                constraints.maxWidth >= 600 && constraints.maxHeight < 600;
            return SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: wide ? 960 : 480),
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: wide
                          ? Row(
                              children: [
                                Expanded(child: brand),
                                const SizedBox(width: 32),
                                Expanded(child: actions),
                              ],
                            )
                          : Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                brand,
                                const SizedBox(height: 24),
                                actions,
                              ],
                            ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
