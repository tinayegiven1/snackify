import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// The tone of a pill or figure: what the colour says at a glance.
enum Tone { neutral, info, good, warn, bad }

extension ToneColors on Tone {
  Color get text => switch (this) {
    Tone.neutral => SnackifyColors.muted,
    Tone.info => SnackifyColors.brandBlue,
    Tone.good => SnackifyColors.good,
    Tone.warn => SnackifyColors.warn,
    Tone.bad => SnackifyColors.bad,
  };

  Color get fill => switch (this) {
    Tone.neutral => SnackifyColors.field,
    Tone.info => SnackifyColors.infoFill,
    Tone.good => SnackifyColors.goodFill,
    Tone.warn => SnackifyColors.warnFill,
    Tone.bad => SnackifyColors.badFill,
  };
}

/// A rounded label such as "Active", "OUT" or "Low stock".
class Pill extends StatelessWidget {
  const Pill(this.label, {super.key, this.tone = Tone.info});

  final String label;
  final Tone tone;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: tone.fill,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: tone.text.withValues(alpha: 0.18)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: tone.text,
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}

/// How much stock is left, as a tone: none (bad), at or under the reorder level (warn), plenty.
Tone stockTone({required int quantity, required bool isLow}) =>
    quantity <= 0 ? Tone.bad : (isLow ? Tone.warn : Tone.good);

/// A quantity with a dot coloured by [stockTone].
class StockLevel extends StatelessWidget {
  const StockLevel({super.key, required this.quantity, required this.isLow, this.large = false});

  final int quantity;
  final bool isLow;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final tone = stockTone(quantity: quantity, isLow: isLow);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: tone.text, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          '$quantity',
          style: TextStyle(
            color: tone.text,
            fontWeight: FontWeight.w700,
            fontSize: large ? 18 : 14,
          ),
        ),
      ],
    );
  }
}

/// One headline figure: a small capitalised label, a big number and an icon, with a coloured
/// edge on the left. Tapping it can act as a quick filter.
class StatCard extends StatelessWidget {
  const StatCard({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    this.tone = Tone.info,
    this.onTap,
    this.selected = false,
  });

  final String label;
  final String value;
  final IconData icon;
  final Tone tone;
  final VoidCallback? onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final accent = tone == Tone.info ? SnackifyColors.brandBlue : tone.text;
    return Card(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: selected ? BorderSide(color: accent, width: 1.5) : BorderSide.none,
      ),
      child: InkWell(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: accent, width: 4)),
          ),
          padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label.toUpperCase(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: SnackifyColors.muted,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.8,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: SnackifyColors.ink,
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(
                  color: tone.fill,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, size: 20, color: accent),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Lays stat cards out in one row on wide screens and two to a row on phones.
class StatCardRow extends StatelessWidget {
  const StatCardRow({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final perRow = constraints.maxWidth >= 640 ? children.length : 2;
        const gap = 12.0;
        final width = (constraints.maxWidth - gap * (perRow - 1)) / perRow;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [for (final child in children) SizedBox(width: width, child: child)],
        );
      },
    );
  }
}

/// A white rounded panel for filters, forms and tables.
class Panel extends StatelessWidget {
  const Panel({super.key, required this.child, this.padding = const EdgeInsets.all(16)});

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(padding: padding, child: child),
    );
  }
}

/// A page's title, a line saying what it is for, and its main buttons.
class PageHeader extends StatelessWidget {
  const PageHeader({super.key, required this.title, this.subtitle, this.actions = const []});

  final String title;
  final String? subtitle;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final heading = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(title, style: theme.textTheme.headlineSmall),
        if (subtitle != null) ...[
          const SizedBox(height: 4),
          Text(subtitle!, style: theme.textTheme.bodyMedium?.copyWith(color: SnackifyColors.muted)),
        ],
      ],
    );
    if (actions.isEmpty) return heading;
    return Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 16,
      runSpacing: 12,
      children: [
        heading,
        Wrap(spacing: 8, runSpacing: 8, children: actions),
      ],
    );
  }
}

/// A product code in the table's strong blue.
class CodeText extends StatelessWidget {
  const CodeText(this.code, {super.key});

  final String code;

  @override
  Widget build(BuildContext context) {
    return Text(
      code,
      style: const TextStyle(color: SnackifyColors.brandBlue, fontWeight: FontWeight.w700),
    );
  }
}
