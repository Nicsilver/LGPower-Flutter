import 'package:flutter/widgets.dart';

/// Compact (360dp-wide phones) vs sw400dp dimension set (port spec §2),
/// picked once per build from `shortestSide`. Values are copied verbatim
/// from `values/dimens.xml` and `values-sw400dp/dimens.xml`.
class MainDims {
  const MainDims._({
    required this.mainPadH,
    required this.pillWidth,
    required this.dpadSize,
    required this.okSize,
    required this.pillGap,
    required this.pillMirror,
    required this.dpadTopGap,
    required this.dpadBottomGap,
  });

  final double mainPadH;
  final double pillWidth;
  final double dpadSize;
  final double okSize;
  final double pillGap;
  final double pillMirror;
  final double dpadTopGap;
  final double dpadBottomGap;

  static const compact = MainDims._(
    mainPadH: 20,
    pillWidth: 48,
    dpadSize: 200,
    okSize: 84,
    pillGap: 8,
    pillMirror: 56,
    dpadTopGap: 22,
    dpadBottomGap: 96,
  );

  static const sw400 = MainDims._(
    mainPadH: 24,
    pillWidth: 54,
    dpadSize: 230,
    okSize: 96,
    pillGap: 10,
    pillMirror: 64,
    dpadTopGap: 37,
    dpadBottomGap: 126,
  );

  static MainDims of(BuildContext context) {
    final shortestSide = MediaQuery.of(context).size.shortestSide;
    return shortestSide >= 400 ? sw400 : compact;
  }
}
