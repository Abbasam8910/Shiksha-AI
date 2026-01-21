import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';

/// Widget that renders text with inline LaTeX math expressions.
/// Math expressions should be wrapped in single dollar signs: $...$
/// Example: "The formula is $x^2 + y^2 = r^2$ for a circle."
class MathText extends StatelessWidget {
  final String text;
  final TextStyle? textStyle;
  final TextAlign textAlign;

  const MathText({
    super.key,
    required this.text,
    this.textStyle,
    this.textAlign = TextAlign.start,
  });

  @override
  Widget build(BuildContext context) {
    final defaultStyle =
        textStyle ??
        Theme.of(context).textTheme.bodyMedium ??
        const TextStyle(fontSize: 16);

    // If no math detected, return plain text for performance
    if (!text.contains('\$')) {
      return Text(text, style: defaultStyle, textAlign: textAlign);
    }

    // Parse text into segments (text and math)
    final segments = _parseSegments(text);

    return Text.rich(
      TextSpan(
        children: segments.map((segment) {
          if (segment.isMath) {
            return WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: _buildMathWidget(segment.content, defaultStyle),
            );
          } else {
            return TextSpan(text: segment.content, style: defaultStyle);
          }
        }).toList(),
      ),
      textAlign: textAlign,
    );
  }

  /// Parse text into alternating text and math segments
  List<_TextSegment> _parseSegments(String input) {
    final segments = <_TextSegment>[];
    final regex = RegExp(r'\$([^\$]+)\$');
    int lastEnd = 0;

    for (final match in regex.allMatches(input)) {
      // Add text before this match
      if (match.start > lastEnd) {
        segments.add(
          _TextSegment(
            content: input.substring(lastEnd, match.start),
            isMath: false,
          ),
        );
      }

      // Add the math content (without $ delimiters)
      segments.add(_TextSegment(content: match.group(1) ?? '', isMath: true));

      lastEnd = match.end;
    }

    // Add remaining text after last match
    if (lastEnd < input.length) {
      segments.add(
        _TextSegment(content: input.substring(lastEnd), isMath: false),
      );
    }

    return segments;
  }

  /// Build math widget with error handling
  Widget _buildMathWidget(String latex, TextStyle style) {
    try {
      return Math.tex(
        latex,
        textStyle: style.copyWith(
          fontSize:
              (style.fontSize ?? 16) * 1.1, // Slightly larger for readability
        ),
        onErrorFallback: (error) {
          // If LaTeX parsing fails, show as plain text
          return Text(
            '\$$latex\$',
            style: style.copyWith(
              fontFamily: 'monospace',
              color: Colors.red.shade700,
            ),
          );
        },
      );
    } catch (e) {
      // Fallback for any rendering errors
      return Text('\$$latex\$', style: style);
    }
  }
}

/// Internal class to represent a text segment
class _TextSegment {
  final String content;
  final bool isMath;

  _TextSegment({required this.content, required this.isMath});
}
