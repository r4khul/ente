import "dart:async";
import "dart:math";

import "package:ente_components/ente_components.dart";
import "package:ente_components/hugeicons.dart";
import "package:ente_strings/ente_strings.dart";
import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_svg/flutter_svg.dart";
import "package:photos/services/account/user_service.dart";
import "package:rive/rive.dart" as rive;

enum _ReferralSource {
  friend("Friend or family", HugeIcons.strokeRoundedUserMultiple),
  socialMedia("Social media or forums", HugeIcons.strokeRoundedBubbleChat),
  media("Blog, video or podcast", HugeIcons.strokeRoundedPlayCircle),
  search("Search or AI assistant", HugeIcons.strokeRoundedSearch01),
  appStore("App store", HugeIcons.strokeRoundedStore01);

  const _ReferralSource(this.value, this.icon);

  final String value;
  final List<List<dynamic>> icon;

  String label(StringsLocalizations strings) {
    return switch (this) {
      friend => strings.hearUsWhereFriend,
      socialMedia => strings.hearUsWhereSocialMedia,
      media => strings.hearUsWhereMedia,
      search => strings.hearUsWhereSearch,
      appStore => strings.hearUsWhereAppStore,
    };
  }
}

class ReferralSourcePage extends StatefulWidget {
  const ReferralSourcePage({super.key});

  static Route<void> route() {
    return MaterialPageRoute(
      settings: const RouteSettings(name: _routeName),
      builder: (_) => const ReferralSourcePage(),
    );
  }

  static bool isRoute(Route<dynamic> route) {
    return route.settings.name == _routeName;
  }

  static const _routeName = "referral_source";

  @override
  State<ReferralSourcePage> createState() => _ReferralSourcePageState();
}

class _ReferralSourcePageState extends State<ReferralSourcePage> {
  static const double _logoWidth = 50;
  static const _maxOtherLength = 100;
  static const double _menuBorderWidth = 1;
  static const double _menuSlotSize = 36;
  static const double _menuTextInset =
      _menuBorderWidth + Spacing.md + _menuSlotSize + Spacing.md;
  static const Size _duckyArtboard = Size(620, 522);
  static const double _duckyHeadTop = 60;
  static const double _duckyHeadBottom = 294;
  static const double _duckyHugBottom = 412;
  static const double _duckyMaxHeight = 172;
  static const double _duckyMinHeight = 56;

  final _otherController = TextEditingController();
  final _otherFocusNode = FocusNode();
  final _questionKey = GlobalKey();
  rive.FileLoader? _duckyLoader;
  _ReferralSource? _selected;
  double? _questionHeight;
  bool _measurementScheduled = false;

  @override
  void initState() {
    super.initState();
    _duckyLoader = _loadDucky();
  }

  rive.FileLoader? _loadDucky() {
    try {
      return rive.FileLoader.fromAsset(
        "assets/ducky_hug.riv",
        riveFactory: rive.Factory.flutter,
      );
    } catch (_) {
      return null;
    }
  }

  @override
  void dispose() {
    _duckyLoader?.dispose();
    _otherFocusNode.dispose();
    _otherController.dispose();
    super.dispose();
  }

  void _measureQuestion() {
    if (_measurementScheduled) return;
    _measurementScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measurementScheduled = false;
      if (!mounted) return;
      final height = _questionKey.currentContext?.size?.height;
      if (height != null && height != _questionHeight) {
        setState(() => _questionHeight = height);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.componentColors;
    final isKeyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    final skipLabelHeight =
        MediaQuery.textScalerOf(context).scale(TextStyles.body.fontSize!) *
        TextStyles.body.height!;
    return Scaffold(
      backgroundColor: colors.backgroundBase,
      appBar: AppBar(
        backgroundColor: colors.backgroundBase,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        automaticallyImplyLeading: false,
        toolbarHeight: max(kMinInteractiveDimension, skipLabelHeight),
        centerTitle: true,
        title: SvgPicture.asset(
          "packages/ente_components/assets/ente_wordmark.svg",
          width: _logoWidth,
          colorFilter: ColorFilter.mode(colors.textBase, BlendMode.srcIn),
        ),
        actions: [_buildSkipAction(context)],
      ),
      body: SafeArea(
        top: false,
        bottom: false,
        child: _buildQuestion(context, isKeyboardOpen),
      ),
    );
  }

  Widget _buildQuestion(BuildContext context, bool isKeyboardOpen) {
    final colors = context.componentColors;
    final strings = context.strings;
    return LayoutBuilder(
      builder: (context, constraints) {
        _measureQuestion();
        final questionHeight = _questionHeight;
        final duckyLoader = _duckyLoader;
        final duckyHeight =
            duckyLoader == null || questionHeight == null || isKeyboardOpen
            ? 0.0
            : min(
                _duckyMaxHeight,
                constraints.maxHeight -
                    questionHeight -
                    Spacing.lg -
                    Spacing.md,
              );
        final showDucky = duckyHeight >= _duckyMinHeight;
        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    Spacing.lg,
                    Spacing.lg,
                    Spacing.lg,
                    showDucky
                        ? Spacing.md
                        : Spacing.xxl + MediaQuery.paddingOf(context).bottom,
                  ),
                  child: Column(
                    key: _questionKey,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        strings.hearUsWhereTitle,
                        textAlign: TextAlign.center,
                        style: TextStyles.display2.copyWith(
                          color: colors.textBase,
                        ),
                      ),
                      const SizedBox(height: Spacing.xxl),
                      MenuGroupComponent(
                        showDividers: true,
                        items: [
                          for (final source in _ReferralSource.values)
                            _buildSource(source, strings),
                          _buildOtherSource(context),
                        ],
                      ),
                    ],
                  ),
                ),
                if (duckyLoader != null && showDucky)
                  _buildDucky(duckyLoader, duckyHeight, constraints.maxWidth),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildSkipAction(BuildContext context) {
    final color = context.componentColors.primary;
    final toolbarWidth =
        MediaQuery.sizeOf(context).width -
        MediaQuery.paddingOf(context).horizontal;
    return Semantics(
      button: true,
      child: GestureDetector(
        key: const ValueKey("referralSourceSkipButton"),
        behavior: HitTestBehavior.opaque,
        onTap: _close,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: kMinInteractiveDimension,
            maxWidth:
                toolbarWidth -
                _logoWidth -
                2 * NavigationToolbar.kMiddleSpacing,
          ),
          child: Padding(
            padding: const EdgeInsets.only(left: 12, right: 18),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    context.strings.skip,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyles.body.copyWith(color: color),
                  ),
                ),
                const SizedBox(width: Spacing.xs),
                HugeIcon(
                  icon: HugeIcons.strokeRoundedArrowRight01,
                  size: IconSizes.small,
                  strokeWidth: 2,
                  color: color,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSource(_ReferralSource source, StringsLocalizations strings) {
    final colors = context.componentColors;
    final isSelected = _selected == source;
    return MenuComponent(
      title: source.label(strings),
      leading: HugeIcon(icon: source.icon, size: IconSizes.small),
      trailing: HugeIcon(
        icon: isSelected
            ? HugeIcons.strokeRoundedTick02
            : HugeIcons.strokeRoundedArrowRight01,
        size: IconSizes.small,
        color: isSelected ? colors.primary : colors.textLighter,
      ),
      onTap: () => _select(source),
    );
  }

  Widget _buildOtherSource(BuildContext context) {
    final colors = context.componentColors;
    final strings = context.strings;
    return ListenableBuilder(
      listenable: Listenable.merge([_otherController, _otherFocusNode]),
      builder: (context, _) {
        final hasText = _otherController.text.trim().isNotEmpty;
        return Stack(
          children: [
            ExcludeSemantics(
              child: MenuComponent(
                title: "",
                leading: const HugeIcon(
                  icon: HugeIcons.strokeRoundedPencilEdit01,
                  size: IconSizes.small,
                ),
                trailing: hasText
                    ? IconButtonComponent(
                        variant: IconButtonComponentVariant.unfilled,
                        size: _menuSlotSize,
                        iconSize: IconSizes.small,
                        shouldSurfaceExecutionStates: false,
                        tooltip: strings.done,
                        icon: HugeIcon(
                          icon: HugeIcons.strokeRoundedArrowRight02,
                          color: colors.primary,
                        ),
                        onTap: () => _submit(_otherController.text),
                      )
                    : const SizedBox.shrink(),
                onTap: _otherFocusNode.requestFocus,
              ),
            ),
            Positioned.fill(
              left: _menuTextInset,
              right: _menuTextInset,
              child: Center(
                child: TextField(
                  key: const ValueKey("referralSourceOtherField"),
                  controller: _otherController,
                  focusNode: _otherFocusNode,
                  textCapitalization: TextCapitalization.sentences,
                  textInputAction: TextInputAction.done,
                  inputFormatters: [
                    LengthLimitingTextInputFormatter(_maxOtherLength),
                  ],
                  scrollPadding: const EdgeInsets.only(bottom: 120),
                  cursorColor: colors.primary,
                  style: TextStyles.body.copyWith(color: colors.textBase),
                  decoration: InputDecoration(
                    hintText: strings.hearUsWhereOther,
                    hintStyle: TextStyles.body.copyWith(
                      color: _otherFocusNode.hasFocus
                          ? colors.textLighter
                          : colors.textBase,
                    ),
                    border: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    isDense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                  onTapOutside: (_) => _otherFocusNode.unfocus(),
                  onSubmitted: _submit,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildDucky(
    rive.FileLoader loader,
    double visibleHeight,
    double maxWidth,
  ) {
    const maxScale = _duckyMaxHeight / _duckyHugBottom;
    const headHeight = _duckyHeadBottom - _duckyHeadTop;
    final scale = min(maxScale, visibleHeight / headHeight);
    final visibleUnits = visibleHeight / scale;
    final top = visibleUnits >= _duckyHeadBottom
        ? 0.0
        : _duckyHeadBottom - visibleUnits;
    final width = _duckyArtboard.width * scale;
    final boxWidth = min(width, maxWidth);
    return ExcludeSemantics(
      child: ClipRect(
        child: SizedBox(
          width: boxWidth,
          height: visibleHeight,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: (boxWidth - width) / 2,
                top: -top * scale,
                width: width,
                height: _duckyArtboard.height * scale,
                child: rive.RiveWidgetBuilder(
                  fileLoader: loader,
                  builder: (context, state) {
                    if (state is rive.RiveLoaded) {
                      return rive.RiveWidget(
                        controller: state.controller,
                        fit: rive.Fit.contain,
                      );
                    }
                    return const SizedBox.shrink();
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  bool get _isOpen => ModalRoute.of(context)?.isCurrent ?? false;

  void _select(_ReferralSource source) {
    if (!_isOpen) {
      return;
    }
    setState(() => _selected = source);
    _submit(source.value);
  }

  void _submit(String source) {
    final trimmed = source.trim();
    if (trimmed.isEmpty || !_isOpen) {
      return;
    }
    unawaited(UserService.instance.submitReferralSource(trimmed));
    Navigator.of(context).pop();
  }

  void _close() {
    if (_isOpen) {
      Navigator.of(context).pop();
    }
  }
}
