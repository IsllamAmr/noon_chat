import 'package:flutter/material.dart';

class ChatSearchBar extends StatefulWidget {
  final TextEditingController? controller;
  final FocusNode? focusNode;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onFilterTap;
  final String hintText;
  final bool autofocus;

  const ChatSearchBar({
    super.key,
    this.controller,
    this.focusNode,
    this.onChanged,
    this.onFilterTap,
    this.hintText = 'Search chats',
    this.autofocus = false,
  });

  @override
  State<ChatSearchBar> createState() => _ChatSearchBarState();
}

class _ChatSearchBarState extends State<ChatSearchBar> {
  late FocusNode _focusNode;
  late bool _ownsFocusNode;
  bool _isFocused = false;

  static const _height = 47.0;
  static const _radius = 15.0;
  static const _brandIndigo = Color(0xFF6366F1);
  static const _backgroundDark = Color(0xFF0F172A);
  static const _defaultBorderDark = Color(0xFF1E293B);
  static const _hintDark = Color(0xFF6B7280);
  static const _iconDark = Color(0xFF94A3B8);
  static const _textDark = Color(0xFFF8FAFC);

  @override
  void initState() {
    super.initState();
    _ownsFocusNode = widget.focusNode == null;
    _focusNode = widget.focusNode ?? FocusNode();
    _isFocused = _focusNode.hasFocus;
    _focusNode.addListener(_onFocusChanged);
  }

  @override
  void didUpdateWidget(covariant ChatSearchBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode == widget.focusNode) return;

    _focusNode.removeListener(_onFocusChanged);
    if (_ownsFocusNode) {
      _focusNode.dispose();
    }

    _ownsFocusNode = widget.focusNode == null;
    _focusNode = widget.focusNode ?? FocusNode();
    _isFocused = _focusNode.hasFocus;
    _focusNode.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChanged);
    if (_ownsFocusNode) {
      _focusNode.dispose();
    }
    super.dispose();
  }

  void _onFocusChanged() {
    final next = _focusNode.hasFocus;
    if (next == _isFocused || !mounted) return;
    setState(() => _isFocused = next);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final background = isDark
        ? _backgroundDark
        : scheme.surfaceContainerHighest;
    final borderColor = _isFocused
        ? _brandIndigo
        : (isDark ? _defaultBorderDark : scheme.outlineVariant);
    final iconColor = isDark ? _iconDark : scheme.onSurfaceVariant;
    final hintColor = isDark ? _hintDark : scheme.onSurfaceVariant;
    final textColor = isDark ? _textDark : scheme.onSurface;

    return Material(
      color: Colors.transparent,
      child: SizedBox(
        height: _height,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOut,
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(_radius),
            border: Border.all(color: borderColor, width: 1),
          ),
          child: Row(
            children: [
              const SizedBox(width: 12),
              Icon(Icons.search_rounded, color: iconColor, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: widget.controller,
                  focusNode: _focusNode,
                  autofocus: widget.autofocus,
                  onChanged: widget.onChanged,
                  textInputAction: TextInputAction.search,
                  style: TextStyle(
                    color: textColor,
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                  ),
                  cursorColor: _brandIndigo,
                  decoration: InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    hintText: widget.hintText,
                    hintStyle: TextStyle(
                      color: hintColor,
                      fontSize: 14.5,
                      fontWeight: FontWeight.w500,
                    ),
                    contentPadding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                ),
              ),
              _SearchFilterIconButton(
                onTap: widget.onFilterTap,
                iconColor: iconColor,
              ),
              const SizedBox(width: 4),
            ],
          ),
        ),
      ),
    );
  }
}

class _SearchFilterIconButton extends StatelessWidget {
  final VoidCallback? onTap;
  final Color iconColor;

  const _SearchFilterIconButton({required this.onTap, required this.iconColor});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Filter',
      child: Material(
        type: MaterialType.transparency,
        shape: const CircleBorder(),
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Icon(Icons.tune_rounded, color: iconColor, size: 20),
          ),
        ),
      ),
    );
  }
}
