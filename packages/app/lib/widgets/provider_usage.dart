import 'dart:math' as math;

import 'package:agent_protocol/agent_protocol.dart';
import 'package:fluent_ui/fluent_ui.dart';

import '../core/theme.dart';

ProviderUsageTone deriveProviderUsageTone(double? usedPct) {
  if (usedPct == null || !usedPct.isFinite) {
    return ProviderUsageTone.defaultTone;
  }
  if (usedPct > 90) return ProviderUsageTone.danger;
  if (usedPct >= 70) return ProviderUsageTone.warning;
  return ProviderUsageTone.defaultTone;
}

double? resolveProviderUsageWindowPct(ProviderUsageWindow window) =>
    window.usedPct ??
    (window.remainingPct == null ? null : 100 - window.remainingPct!);

double? resolveProviderUsageBalancePct(ProviderUsageBalance balance) {
  final limit = balance.limit;
  if (limit == null || limit <= 0 || !limit.isFinite) return null;
  final used =
      balance.used ??
      (balance.remaining == null ? null : limit - balance.remaining!);
  if (used == null || !used.isFinite) return null;
  return used / limit * 100;
}

double clampProviderUsagePct(double value) => math.max(0, math.min(100, value));

String formatProviderUsagePct(double value) =>
    '${clampProviderUsagePct(value).round()}%';

ProviderUsageTone resolveProviderUsageTone(
  ProviderUsageTone? providerTone,
  double? usedPct,
) => providerTone ?? deriveProviderUsageTone(usedPct);

Color providerUsageToneColor(BuildContext context, ProviderUsageTone tone) =>
    switch (tone) {
      ProviderUsageTone.defaultTone => context.statusColors.neutral,
      ProviderUsageTone.ok => context.statusColors.success,
      ProviderUsageTone.warning => context.statusColors.warning,
      ProviderUsageTone.danger => context.statusColors.danger,
    };

class ProviderUsageCard extends StatelessWidget {
  const ProviderUsageCard({super.key, required this.usage});

  final ProviderUsage usage;

  @override
  Widget build(BuildContext context) {
    final status = switch (usage.status) {
      ProviderUsageStatus.available => null,
      ProviderUsageStatus.unavailable => 'Unavailable',
      ProviderUsageStatus.error => 'Error',
    };
    return Card(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  usage.displayName,
                  style: context.textStyles.titleSmall,
                ),
              ),
              if (usage.planLabel case final plan?)
                InfoBadge(source: Text(plan)),
              if (status case final status?) ...[
                const SizedBox(width: 8),
                Text(
                  status,
                  style: context.textStyles.bodySmall?.copyWith(
                    color: usage.status == ProviderUsageStatus.error
                        ? context.statusColors.danger
                        : context.statusColors.neutral,
                  ),
                ),
              ],
            ],
          ),
          if (usage.error case final error?) ...[
            const SizedBox(height: 12),
            Text(
              error,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: context.textStyles.bodySmall?.copyWith(
                color: context.statusColors.danger,
              ),
            ),
          ],
          if (usage.windows.isNotEmpty || usage.balances.isNotEmpty) ...[
            const SizedBox(height: 16),
            for (final window in usage.windows) ...[
              ProviderUsageWindowBar(window: window),
              const SizedBox(height: 12),
            ],
            for (final balance in usage.balances) ...[
              ProviderUsageBalanceBar(balance: balance),
              const SizedBox(height: 12),
            ],
          ],
          for (final detail in usage.details)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      detail.label,
                      style: context.textStyles.bodySmall?.copyWith(
                        color: context.statusColors.neutral,
                      ),
                    ),
                  ),
                  Text(detail.value, style: context.textStyles.bodySmall),
                ],
              ),
            ),
          if (_footerText(usage) case final footer?) ...[
            const SizedBox(height: 8),
            Text(
              footer,
              style: context.textStyles.bodySmall?.copyWith(
                color: context.statusColors.neutral,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class ProviderUsageWindowBar extends StatelessWidget {
  const ProviderUsageWindowBar({super.key, required this.window});

  final ProviderUsageWindow window;

  @override
  Widget build(BuildContext context) {
    final usedPct = resolveProviderUsageWindowPct(window);
    final tone = resolveProviderUsageTone(window.tone, usedPct);
    final atRisk = window.runsOutAt != null && window.shortfallPct != null;
    final trailing = atRisk
        ? 'runs out ${formatProviderUsageReset(window.runsOutAt)?.replaceFirst('resets ', '') ?? ''}'
              .trim()
        : formatProviderUsageReset(window.resetsAt);
    return ProviderUsageBar(
      label: window.label,
      value: usedPct == null ? '—' : formatProviderUsagePct(usedPct),
      trailing: trailing,
      trailingDanger: atRisk,
      usedPct: usedPct,
      tone: tone,
    );
  }
}

class ProviderUsageBalanceBar extends StatelessWidget {
  const ProviderUsageBalanceBar({super.key, required this.balance});

  final ProviderUsageBalance balance;

  @override
  Widget build(BuildContext context) {
    final usedPct = resolveProviderUsageBalancePct(balance);
    final used =
        balance.used ??
        (balance.limit != null && balance.remaining != null
            ? balance.limit! - balance.remaining!
            : null);
    final amount = switch ((balance.limit, used, balance.remaining)) {
      (final limit?, final used?, _) =>
        '${formatProviderUsageAmount(used, balance.unit)} / '
            '${formatProviderUsageAmount(limit, balance.unit)}',
      (_, _, final remaining?) =>
        '${formatProviderUsageAmount(remaining, balance.unit)} left',
      (_, final used?, _) => formatProviderUsageAmount(used, balance.unit),
      _ => '—',
    };
    return ProviderUsageBar(
      label: balance.label,
      value: amount,
      trailing: formatProviderUsageReset(balance.resetsAt),
      usedPct: usedPct,
      tone: balance.tone ?? ProviderUsageTone.defaultTone,
      showTrack: usedPct != null,
    );
  }
}

class ProviderUsageBar extends StatelessWidget {
  const ProviderUsageBar({
    super.key,
    required this.label,
    required this.value,
    required this.usedPct,
    required this.tone,
    this.trailing,
    this.trailingDanger = false,
    this.showTrack = true,
  });

  final String label;
  final String value;
  final String? trailing;
  final bool trailingDanger;
  final double? usedPct;
  final ProviderUsageTone tone;
  final bool showTrack;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.textStyles.bodySmall?.copyWith(
                color: context.statusColors.neutral,
              ),
            ),
          ),
          Text(
            trailing == null ? value : '$value · $trailing',
            key: ValueKey('provider-usage-value-$label'),
            style: context.textStyles.bodySmall?.copyWith(
              fontWeight: FontWeight.w600,
              color: trailingDanger ? context.statusColors.danger : null,
            ),
          ),
        ],
      ),
      if (showTrack) ...[
        const SizedBox(height: 3),
        LayoutBuilder(
          builder: (context, constraints) => Container(
            key: ValueKey('provider-usage-track-$label'),
            height: 4,
            decoration: BoxDecoration(
              color: FluentTheme.of(
                context,
              ).resources.cardBackgroundFillColorSecondary,
              borderRadius: BorderRadius.circular(2),
            ),
            alignment: Alignment.centerLeft,
            child: Container(
              key: ValueKey('provider-usage-fill-$label'),
              width:
                  constraints.maxWidth *
                  clampProviderUsagePct(usedPct ?? 0) /
                  100,
              decoration: BoxDecoration(
                color: providerUsageToneColor(context, tone),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
      ],
    ],
  );
}

String formatProviderUsageAmount(double value, ProviderUsageBalanceUnit unit) =>
    switch (unit) {
      ProviderUsageBalanceUnit.usd => '\$${value.toStringAsFixed(2)}',
      ProviderUsageBalanceUnit.tokens => _compactCount(value),
      _ => value.round().toString(),
    };

String _compactCount(double value) {
  if (value.abs() >= 1000000) {
    return '${(value / 1000000).toStringAsFixed(1)}M';
  }
  if (value.abs() >= 1000) {
    return '${(value / 1000).toStringAsFixed(1)}K';
  }
  return value.round().toString();
}

String? formatProviderUsageReset(String? iso, {DateTime? now}) {
  if (iso == null) return null;
  final timestamp = DateTime.tryParse(iso);
  if (timestamp == null) return null;
  final diff = timestamp.difference((now ?? DateTime.now()).toUtc());
  if (diff <= Duration.zero) return 'resetting now';
  final days = diff.inDays;
  if (days > 0) return 'resets ${days}d';
  final hours = diff.inHours;
  if (hours > 0) return 'resets ${hours}h';
  return 'resets ${diff.inMinutes}m';
}

String? _footerText(ProviderUsage usage) {
  final parts = <String>[
    if (usage.sourceLabel?.isNotEmpty == true) usage.sourceLabel!,
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}
