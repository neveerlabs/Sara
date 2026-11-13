import 'package:flutter/services.dart';

class SmartTextInputFormatter extends TextInputFormatter {
  const SmartTextInputFormatter();

  static final _letterPattern = RegExp(r'^\p{L}$', unicode: true);
  static const _simplePairs = <String, String>{
    '(': ')',
    '[': ']',
    '{': '}',
    '<': '>',
    '"': '"',
    "'": "'",
  };
  static const _markdownPairCharacters = {'*', '_', '~', '`'};

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (!newValue.composing.isCollapsed) return newValue;

    final oldSelection = oldValue.selection;
    if (!oldSelection.isValid) return newValue;

    final change = _TextChange.between(oldValue, newValue);
    if (change.removed.isNotEmpty && change.inserted.isEmpty) {
      return _deletePairIfOpeningWasBackspaced(
        oldValue,
        newValue,
        change,
      );
    }

    if (change.inserted.isEmpty || !oldSelection.isValid) return newValue;

    final insertionOffset = change.start;
    if (oldSelection.isCollapsed &&
        insertionOffset == oldSelection.extentOffset &&
        change.inserted.length == 1) {
      final character = change.inserted;
      if (_markdownPairCharacters.contains(character)) {
        final hasAdjacentCloser = oldValue.text.startsWith(
          character,
          insertionOffset,
        );
        if (!hasAdjacentCloser &&
            _isAdjacentToLetter(oldValue.text, insertionOffset)) {
          return newValue;
        }
        return _pairOrExpandMarkdownDelimiter(
          oldValue,
          newValue,
          character,
        );
      }

      if (_isClosingCharacter(character) &&
          insertionOffset < oldValue.text.length &&
          oldValue.text[insertionOffset] == character) {
        return _skipExistingClosingCharacter(
          oldValue,
          insertionOffset,
          character,
        );
      }

      final closing = _simplePairs[character];
      if (closing != null) {
        if (_isAdjacentToLetter(oldValue.text, insertionOffset)) {
          return newValue;
        }
        return _insertClosingPair(
          newValue,
          closing,
        );
      }
    }

    if (!oldSelection.isCollapsed &&
        change.inserted.length == 1 &&
        (_simplePairs.containsKey(change.inserted) ||
            _markdownPairCharacters.contains(change.inserted))) {
      return _wrapSelection(
        oldValue,
        oldSelection,
        change.inserted,
      );
    }
    return newValue;
  }

  TextEditingValue _deletePairIfOpeningWasBackspaced(
    TextEditingValue oldValue,
    TextEditingValue newValue,
    _TextChange change,
  ) {
    if (change.removed.length != 1 ||
        !oldValue.selection.isCollapsed ||
        oldValue.selection.extentOffset != change.start + 1) {
      return newValue;
    }

    final opening = change.removed;
    final closing = _simplePairs[opening] ??
        (_markdownPairCharacters.contains(opening) ? opening : null);
    if (closing == null || change.start >= newValue.text.length) {
      return newValue;
    }
    if (!newValue.text.startsWith(closing, change.start)) return newValue;

    final text = newValue.text.replaceRange(
      change.start,
      change.start + closing.length,
      '',
    );
    return _valueWithSelection(text, change.start);
  }

  TextEditingValue _pairOrExpandMarkdownDelimiter(
    TextEditingValue oldValue,
    TextEditingValue newValue,
    String delimiter,
  ) {
    final caret = newValue.selection.extentOffset;
    final oldCaret = oldValue.selection.extentOffset;
    final oldBefore = oldValue.text.substring(0, oldCaret);
    final oldAfter = oldValue.text.substring(oldCaret);
    final hasOpening = oldBefore.endsWith(delimiter);
    final hasAdjacentClosing = oldAfter.startsWith(delimiter);

    if (hasOpening && hasAdjacentClosing) {
      return _insertAt(
        newValue,
        caret + delimiter.length,
        delimiter,
        caret,
      );
    }

    if (hasAdjacentClosing) {
      return _valueWithSelection(
        oldValue.text,
        oldCaret + delimiter.length,
      );
    }

    if (hasOpening && oldAfter.isNotEmpty) {
      final lastDelimiter = oldValue.text.lastIndexOf(delimiter);
      if (lastDelimiter > oldCaret &&
          oldValue.text.endsWith(delimiter) &&
          !oldAfter.trim().isEmpty) {
        final text = '${newValue.text}$delimiter';
        return _valueWithSelection(text, caret);
      }
    }

    return _insertAt(newValue, caret, delimiter, caret);
  }

  TextEditingValue _insertClosingPair(
    TextEditingValue newValue,
    String closing,
  ) {
    final caret = newValue.selection.extentOffset;
    final text = _insertString(newValue.text, caret, closing);
    return _valueWithSelection(text, caret);
  }

  TextEditingValue _skipExistingClosingCharacter(
    TextEditingValue oldValue,
    int offset,
    String character,
  ) {
    var text = oldValue.text;
    var nextCaret = offset + character.length;
    if (character == ']' &&
        (nextCaret >= text.length || text[nextCaret] != '(')) {
      text = _insertString(text, nextCaret, '()');
      nextCaret++;
    }
    return _valueWithSelection(text, nextCaret);
  }

  TextEditingValue _wrapSelection(
    TextEditingValue oldValue,
    TextSelection selection,
    String opening,
  ) {
    final closing = _simplePairs[opening] ?? opening;
    final start = selection.start;
    final end = selection.end;
    final selected = oldValue.text.substring(start, end);
    final text =
        oldValue.text.replaceRange(start, end, '$opening$selected$closing');
    return _valueWithSelection(text, start + opening.length);
  }

  TextEditingValue _insertAt(
    TextEditingValue value,
    int offset,
    String insertion,
    int caret,
  ) {
    return _valueWithSelection(
      _insertString(value.text, offset, insertion),
      caret,
    );
  }

  String _insertString(String text, int offset, String insertion) =>
      text.replaceRange(offset, offset, insertion);

  bool _isClosingCharacter(String character) =>
      _simplePairs.values.contains(character);

  bool _isAdjacentToLetter(String text, int offset) {
    final before = _runeBefore(text, offset);
    final after = _runeAfter(text, offset);
    return (before != null && _letterPattern.hasMatch(before)) ||
        (after != null && _letterPattern.hasMatch(after));
  }

  String? _runeBefore(String text, int offset) {
    if (offset <= 0 || offset > text.length) return null;
    var start = offset - 1;
    final lastUnit = text.codeUnitAt(start);
    if (_isLowSurrogate(lastUnit) &&
        start > 0 &&
        _isHighSurrogate(text.codeUnitAt(start - 1))) {
      start--;
    }
    return text.substring(start, offset);
  }

  String? _runeAfter(String text, int offset) {
    if (offset < 0 || offset >= text.length) return null;
    var end = offset + 1;
    final firstUnit = text.codeUnitAt(offset);
    if (_isHighSurrogate(firstUnit) &&
        end < text.length &&
        _isLowSurrogate(text.codeUnitAt(end))) {
      end++;
    }
    return text.substring(offset, end);
  }

  bool _isHighSurrogate(int codeUnit) =>
      codeUnit >= 0xD800 && codeUnit <= 0xDBFF;

  bool _isLowSurrogate(int codeUnit) =>
      codeUnit >= 0xDC00 && codeUnit <= 0xDFFF;

  TextEditingValue _valueWithSelection(String text, int offset) {
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: offset),
    );
  }
}

class _TextChange {
  const _TextChange({
    required this.start,
    required this.removed,
    required this.inserted,
  });

  final int start;
  final String removed;
  final String inserted;

  factory _TextChange.between(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final oldText = oldValue.text;
    final newText = newValue.text;
    final selection = oldValue.selection;
    final start = selection.start;
    final oldEnd = selection.end;
    if (selection.isCollapsed) {
      final oldCaret = selection.extentOffset;
      final newCaret = newValue.selection.extentOffset;
      if (newText.length < oldText.length) {
        final deleteStart = newCaret < oldCaret ? newCaret : oldCaret;
        final deleteEnd = deleteStart + oldText.length - newText.length;
        if (deleteStart >= 0 &&
            deleteEnd <= oldText.length &&
            newText == oldText.replaceRange(deleteStart, deleteEnd, '')) {
          return _TextChange(
            start: deleteStart,
            removed: oldText.substring(deleteStart, deleteEnd),
            inserted: '',
          );
        }
      } else if (newText.length > oldText.length) {
        final insertedLength = newText.length - oldText.length;
        if (oldCaret >= 0 &&
            oldCaret <= oldText.length &&
            newText ==
                oldText.replaceRange(
                  oldCaret,
                  oldCaret,
                  newText.substring(oldCaret, oldCaret + insertedLength),
                )) {
          return _TextChange(
            start: oldCaret,
            removed: '',
            inserted: newText.substring(oldCaret, oldCaret + insertedLength),
          );
        }
      }
    }

    final insertedLength = newText.length - (oldText.length - (oldEnd - start));
    if (insertedLength < 0 ||
        newText.length < start + insertedLength ||
        newText.substring(0, start) != oldText.substring(0, start) ||
        newText.substring(start + insertedLength) !=
            oldText.substring(oldEnd)) {
      return _TextChange._fallback(oldText, newText);
    }
    return _TextChange(
      start: start,
      removed: oldText.substring(start, oldEnd),
      inserted: newText.substring(start, start + insertedLength),
    );
  }

  factory _TextChange._fallback(String oldText, String newText) {
    var start = 0;
    while (start < oldText.length &&
        start < newText.length &&
        oldText[start] == newText[start]) {
      start++;
    }
    var oldEnd = oldText.length;
    var newEnd = newText.length;
    while (oldEnd > start &&
        newEnd > start &&
        oldText[oldEnd - 1] == newText[newEnd - 1]) {
      oldEnd--;
      newEnd--;
    }
    return _TextChange(
      start: start,
      removed: oldText.substring(start, oldEnd),
      inserted: newText.substring(start, newEnd),
    );
  }
}
