import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sara_desktop/smart_text_input_formatter.dart';

void main() {
  const formatter = SmartTextInputFormatter();

  test(
      'typing an opening bracket inserts its closer and keeps the caret inside',
      () {
    final result = _type(formatter, _value('hello', 5), '(');

    expect(result.text, 'hello()');
    expect(result.selection, const TextSelection.collapsed(offset: 6));
  });

  test('markdown delimiters expand from italic to bold and fence pairs', () {
    var value = _value('', 0);
    value = _type(formatter, value, '*');
    expect(value.text, '**');
    expect(value.selection, const TextSelection.collapsed(offset: 1));

    value = _type(formatter, value, '*');
    expect(value.text, '****');
    expect(value.selection, const TextSelection.collapsed(offset: 2));

    value = _type(formatter, _value('', 0), '`');
    value = _type(formatter, value, '`');
    value = _type(formatter, value, '`');
    expect(value.text, '``````');
    expect(value.selection, const TextSelection.collapsed(offset: 3));

    value = _type(formatter, _value('', 0), '*');
    value = _type(formatter, value, '*');
    value = _backspace(formatter, value);
    expect(value.text, '**');
    expect(value.selection, const TextSelection.collapsed(offset: 1));
  });

  test('typing a closing bracket skips its generated closer and starts a link',
      () {
    var value = _type(formatter, _value('', 0), '[');
    value = _type(formatter, value, 'x');
    value = _type(formatter, value, ']');

    expect(value.text, '[x]()');
    expect(value.selection, const TextSelection.collapsed(offset: 4));
  });

  test('typing a markdown closer advances instead of duplicating it', () {
    final value = _type(formatter, _value('*x*', 2), '*');

    expect(value.text, '*x*');
    expect(value.selection, const TextSelection.collapsed(offset: 3));
  });

  test('backspace removes the matching closer but forward delete stays normal',
      () {
    var value = _type(formatter, _value('', 0), '(');
    value = _backspace(formatter, value);
    expect(value.text, isEmpty);

    value = _type(formatter, _value('', 0), '[');
    value = _delete(formatter, value);
    expect(value.text, '[');
    expect(value.selection, const TextSelection.collapsed(offset: 1));
  });

  test('selecting text and typing a markdown delimiter wraps the selection',
      () {
    const oldValue = TextEditingValue(
      text: 'hello world',
      selection: TextSelection(baseOffset: 6, extentOffset: 11),
    );
    const typedValue = TextEditingValue(
      text: 'hello *',
      selection: TextSelection.collapsed(offset: 7),
    );

    final result = formatter.formatEditUpdate(oldValue, typedValue);

    expect(result.text, 'hello *world*');
    expect(result.selection, const TextSelection.collapsed(offset: 7));
  });
}

TextEditingValue _value(String text, int offset) => TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: offset),
    );

TextEditingValue _type(
  SmartTextInputFormatter formatter,
  TextEditingValue oldValue,
  String character,
) {
  final offset = oldValue.selection.extentOffset;
  final text = oldValue.text.replaceRange(offset, offset, character);
  final newValue = TextEditingValue(
    text: text,
    selection: TextSelection.collapsed(offset: offset + character.length),
  );
  return formatter.formatEditUpdate(oldValue, newValue);
}

TextEditingValue _backspace(
  SmartTextInputFormatter formatter,
  TextEditingValue oldValue,
) {
  final offset = oldValue.selection.extentOffset;
  final text = oldValue.text.replaceRange(offset - 1, offset, '');
  final newValue = TextEditingValue(
    text: text,
    selection: TextSelection.collapsed(offset: offset - 1),
  );
  return formatter.formatEditUpdate(oldValue, newValue);
}

TextEditingValue _delete(
  SmartTextInputFormatter formatter,
  TextEditingValue oldValue,
) {
  final offset = oldValue.selection.extentOffset;
  final text = oldValue.text.replaceRange(offset, offset + 1, '');
  final newValue = TextEditingValue(
    text: text,
    selection: TextSelection.collapsed(offset: offset),
  );
  return formatter.formatEditUpdate(oldValue, newValue);
}
