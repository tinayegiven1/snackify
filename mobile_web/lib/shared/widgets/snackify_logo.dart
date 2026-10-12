import 'package:flutter/material.dart';

class SnackifyLogo extends StatelessWidget {
  const SnackifyLogo({super.key, this.size = 40});

  final double size;

  @override
  Widget build(BuildContext context) {
    // The logo image has square black corners; clip them to match its rounded tile.
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.22),
      child: Image.asset(
        'assets/images/snackify_logo.png',
        width: size,
        height: size,
        semanticLabel: 'Snackify logo',
      ),
    );
  }
}
