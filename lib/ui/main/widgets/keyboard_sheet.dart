import 'dart:async';

import 'package:flutter/material.dart';

import '../../../net/keyboard.dart';
import '../../../net/webos_client.dart';
import '../../../theme/theme_manager.dart';
import '../../widgets/app_icon.dart';
import '../remote_controller.dart';

/// The keyboard bottom sheet (spec §8): one pill-shaped text field, one send
/// button, no Enter/Backspace forwarding -- the whole string goes over in a
/// single `insertText` on send, never per keystroke. `isScrollControlled`
/// plus the sheet's own `viewInsets` padding keeps the remote behind it from
/// resizing when the IME opens (spec: "keyboard must not resize the remote
/// behind").
Future<void> showKeyboardSheet(BuildContext context, RemoteController controller) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.88),
    builder: (sheetContext) => KeyboardSheet(controller: controller),
  );
}

class KeyboardSheet extends StatefulWidget {
  const KeyboardSheet({super.key, required this.controller});

  final RemoteController controller;

  @override
  State<KeyboardSheet> createState() => _KeyboardSheetState();
}

class _KeyboardSheetState extends State<KeyboardSheet> {
  final _text = TextEditingController();
  Future<void Function()>? _watch;
  KeyboardFocus _focus = KeyboardFocus.unknown;
  String? _error;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _watch = widget.controller.client.watchKeyboard((focus) {
      if (mounted && focus != _focus) setState(() => _focus = focus);
    });
  }

  @override
  void dispose() {
    // The subscription may still be waiting for the session when the sheet
    // goes; it is cancelled as soon as it exists.
    unawaited(_watch?.then((cancel) => cancel()));
    _text.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _text.text;
    if (text.isEmpty) {
      Navigator.of(context).pop();
      return;
    }
    if (_sending) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    final controller = widget.controller;
    final result = await controller.sendCommandForResult(() => controller.client.sendText(text));
    if (!mounted) return;
    switch (result) {
      case CmdError(:final message):
        setState(() {
          _sending = false;
          _error = keyboardErrorLine(message);
        });
      case Success() || NeedsPairing():
        Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = AppTheme.of(context);
    final note = _error ?? (_focus == KeyboardFocus.none ? keyboardNoFocusHint : null);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (note != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  note,
                  key: const Key('keyboard_note'),
                  style: TextStyle(fontSize: 13, color: theme.primaryText),
                ),
              ),
            Row(
              children: [
                Expanded(
                  child: Container(
                    height: 46,
                    padding: const EdgeInsets.only(left: 16, right: 5),
                    decoration: BoxDecoration(
                      color: theme.circleBtnBg,
                      borderRadius: BorderRadius.circular(23),
                    ),
                    alignment: Alignment.center,
                    child: TextField(
                      controller: _text,
                      autofocus: true,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      style: TextStyle(fontSize: 15, color: theme.primaryText),
                      decoration: InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        hintText: 'Type here…',
                        hintStyle: TextStyle(color: theme.secondaryText),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: _send,
                  child: Semantics(
                    button: true,
                    label: 'Send',
                    child: Container(
                      width: 36,
                      height: 36,
                      decoration: const BoxDecoration(color: Color(0xFF555555), shape: BoxShape.circle),
                      alignment: Alignment.center,
                      child: const AppIcon('ic_send', size: 20, color: Colors.white),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
