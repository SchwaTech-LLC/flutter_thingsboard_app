import 'package:flutter/material.dart';

/// Wordmark adapted from https://new.schwatech.com/az.
class SchwaTechLogo extends StatelessWidget {
  const SchwaTechLogo({super.key, this.compact = false});
  final bool compact;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'SchwaTech logo',
    image: true,
    child: ExcludeSemantics(
      child: SizedBox(
        width: compact ? 150 : 230,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                'SCHWATECH',
                style: TextStyle(
                  fontSize: compact ? 20 : 24,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.8,
                  color:
                      Theme.of(context).brightness == Brightness.dark
                          ? const Color(0xFFF3F5F7)
                          : const Color(0xFF0A0C0F),
                ),
              ),
            ),
            const SizedBox(height: 2),
            const Row(
              children: [
                Expanded(
                  flex: 55,
                  child: ColoredBox(
                    color: Color(0xFFB3005E),
                    child: SizedBox(height: 2),
                  ),
                ),
                Expanded(
                  flex: 45,
                  child: ColoredBox(
                    color: Color(0xFF00707F),
                    child: SizedBox(height: 2),
                  ),
                ),
              ],
            ),
            if (!compact) ...[
              const SizedBox(height: 2),
              const Text(
                'complex simplicity',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 10,
                  letterSpacing: 2,
                  color: Color(0xFF545C66),
                ),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}
