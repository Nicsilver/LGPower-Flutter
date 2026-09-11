import 'dart:async';

import 'package:flutter/material.dart';

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
  final theme = AppTheme.of(context);
  final textController = TextEditingController();
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.88),
    builder: (sheetContext) {
      void send() {
        final text = textController.text;
        if (text.isNotEmpty) {
          unawaited(controller.sendCommand(() => controller.client.sendText(text)));
        }
        Navigator.of(sheetContext).pop();
      }

      return Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(sheetContext).viewInsets.bottom),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Row(
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
                    controller: textController,
                    autofocus: true,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => send(),
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
                onTap: send,
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
        ),
      );
    },
  );
}
