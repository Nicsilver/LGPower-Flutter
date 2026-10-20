import 'ssap_messages.dart';

const String keyboardPermissionLine = "This TV doesn't let the app type.";
const String keyboardNoFocusHint = 'Select a text field on the TV first';

/// What the TV's `registerRemoteKeyboard` subscription says about text input.
enum KeyboardFocus { unknown, focused, none }

/// The TV's first reply carries `currentWidget` only while a text field has
/// focus, and later pushes always carry it, so a reply without one means
/// nothing is focused.
KeyboardFocus parseKeyboardFocus(Map<String, dynamic>? payload) {
  if (payload == null) return KeyboardFocus.unknown;
  final widget = payload['currentWidget'];
  if (widget is! Map) return KeyboardFocus.none;
  return widget['focus'] == true ? KeyboardFocus.focused : KeyboardFocus.none;
}

/// The sheet line for a failed `insertText`: a plain sentence for a
/// permission denial, the TV's own text for anything else.
String keyboardErrorLine(String message) =>
    isSsapPermissionError(message) ? keyboardPermissionLine : message;
