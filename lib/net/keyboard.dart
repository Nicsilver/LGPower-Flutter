import 'ssap_messages.dart';

const String keyboardPermissionLine = "This TV doesn't allow typing from this app";
const String keyboardSearchOnlyLine =
    'Newer LG TVs (webOS 25 and 26) block typing from apps. Send searches the web on the TV instead.';
const String keyboardLinkLine = "This TV won't open links from this app";
const String keyboardNoFocusHint = 'Select a text field on the TV first';

/// What the TV's `registerRemoteKeyboard` subscription says about text input.
enum KeyboardFocus { unknown, focused, none }

/// Only an explicit `focus:false` counts as "no field focused". The research
/// behind the subscription comes from the open-source IME, where
/// `currentWidget` and each of its keys are left out when not valid; LG's
/// production keyboard is closed, and a false hint on a TV that types fine
/// is worse than no hint.
KeyboardFocus parseKeyboardFocus(Map<String, dynamic>? payload) {
  final widget = payload?['currentWidget'];
  if (widget is! Map) return KeyboardFocus.unknown;
  return switch (widget['focus']) {
    true => KeyboardFocus.focused,
    false => KeyboardFocus.none,
    _ => KeyboardFocus.unknown,
  };
}

/// The sheet line for a failed `insertText`: a plain sentence for a
/// permission denial, the TV's own text for anything else.
String keyboardErrorLine(String message) =>
    isSsapPermissionError(message) ? keyboardPermissionLine : message;
