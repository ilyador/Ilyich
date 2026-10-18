import 'package:flutter/material.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';

class ImmichTitleText extends StatelessWidget {
  final double fontSize;

  const ImmichTitleText({super.key, this.fontSize = 48});

  @override
  Widget build(BuildContext context) {
    return Text(
      'Ilyich',
      maxLines: 1,
      style: TextStyle(
        fontFamily: 'GoogleSans',
        fontSize: fontSize,
        fontWeight: FontWeight.w600,
        color: context.primaryColor,
        height: 1,
      ),
    );
  }
}
