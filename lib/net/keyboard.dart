import 'ssap_messages.dart';

const String keyboardPermissionLine = "This TV doesn't let the app type.";
const String keyboardNoFocusHint = 'Select a text field on the TV first';

/// What the TV's `registerRemoteKeyboard` subscription says about text input.
enum KeyboardFocus { unknown, focused, none }

/// The first reply of the subscription is often a bare `subscribed: true`
/// without a widget; that says nothing either way, so it stays unknown
/// rather than triggering the "select a text field" hint.
KeyboardFocus parseKeyboardFocus(Map<String, dynamic>? payload) {
  final widget = payload?['currentWidget'];
  if (widget is! Map) return KeyboardFocus.unknown;
  return widget['focus'] == true ? KeyboardFocus.focused : KeyboardFocus.none;
}

/// The sheet line for a failed `insertText`: a plain sentence for a
/// permission denial, the TV's own text for anything else.
String keyboardErrorLine(String message) =>
    isSsapPermissionError(message) ? keyboardPermissionLine : message;
