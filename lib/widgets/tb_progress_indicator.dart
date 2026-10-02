import 'package:flutter/material.dart';

class TbProgressIndicator extends StatelessWidget {
  const TbProgressIndicator({
    super.key,
    this.size = 36,
    this.valueColor,
    this.semanticsLabel,
    this.semanticsValue,
  });
  final double size;
  final Animation<Color?>? valueColor;
  final String? semanticsLabel;
  final String? semanticsValue;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: size,
    height: size,
    child: CircularProgressIndicator(
      strokeWidth: 3,
      valueColor: valueColor,
      semanticsLabel: semanticsLabel,
      semanticsValue: semanticsValue,
    ),
  );
}
