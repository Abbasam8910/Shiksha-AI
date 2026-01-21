/// Utility to convert ASCII math/chemistry notation to Unicode subscripts/superscripts.
/// This ensures formulas display correctly even if the model outputs x^2 instead of x².
class MathFormatter {
  // Superscript mappings (for exponents like x^2)
  static const Map<String, String> _superscripts = {
    '0': '⁰',
    '1': '¹',
    '2': '²',
    '3': '³',
    '4': '⁴',
    '5': '⁵',
    '6': '⁶',
    '7': '⁷',
    '8': '⁸',
    '9': '⁹',
    '+': '⁺',
    '-': '⁻',
    'n': 'ⁿ',
    'i': 'ⁱ',
  };

  // Subscript mappings (for chemistry like H_2O)
  static const Map<String, String> _subscripts = {
    '0': '₀',
    '1': '₁',
    '2': '₂',
    '3': '₃',
    '4': '₄',
    '5': '₅',
    '6': '₆',
    '7': '₇',
    '8': '₈',
    '9': '₉',
    '+': '₊',
    '-': '₋',
  };

  // Reverse map: Unicode subscript → ASCII digit
  static const Map<String, String> _subscriptsReverse = {
    '₀': '0',
    '₁': '1',
    '₂': '2',
    '₃': '3',
    '₄': '4',
    '₅': '5',
    '₆': '6',
    '₇': '7',
    '₈': '8',
    '₉': '9',
  };

  /// Converts ASCII notation to Unicode subscripts/superscripts.
  /// Examples:
  ///   - "x^2" → "x²"
  ///   - "H_2O" → "H₂O"
  ///   - "C_6H_12O_6" → "C₆H₁₂O₆"
  static String format(String text) {
    String result = text;

    // 0. DEFENSIVE: First normalize any mixed Unicode subscripts back to ASCII
    // This prevents double-encoding corruption
    _subscriptsReverse.forEach((unicode, ascii) {
      result = result.replaceAll(unicode, ascii);
    });

    // 1. Handle LaTeX \text{X}_n or \text{X}_{n} format
    result = result.replaceAllMapped(
      RegExp(r'\\text\{([A-Za-z]+)\}_?\{?(\d+)\}?'),
      (match) {
        final element = match.group(1)!;
        final subscript = match.group(2)!;
        return '$element$subscript'; // Convert to plain ASCII first
      },
    );

    // 2. Clean standalone \text{...} → just the text inside
    result = result.replaceAllMapped(
      RegExp(r'\\text\{([^}]*)\}'),
      (match) => match.group(1)!,
    );

    // 3. Remove $...$ delimiters (LaTeX math mode)
    result = result.replaceAllMapped(
      RegExp(r'\$([^$]+)\$'),
      (match) => format(match.group(1)!), // Recursively format content
    );

    // 4. Replace common LaTeX commands with symbols
    final latexSymbols = {
      r'\times': '×',
      r'\div': '÷',
      r'\pm': '±',
      r'\sqrt': '√',
      r'\pi': 'π',
      r'\alpha': 'α',
      r'\beta': 'β',
      r'\gamma': 'γ',
      r'\delta': 'δ',
      r'\theta': 'θ',
      r'\lambda': 'λ',
      r'\mu': 'μ',
      r'\sigma': 'σ',
      r'\omega': 'ω',
      r'\infty': '∞',
      r'\neq': '≠',
      r'\leq': '≤',
      r'\geq': '≥',
      r'\approx': '≈',
      r'\rightarrow': '→',
      r'\leftarrow': '←',
    };
    latexSymbols.forEach((latex, symbol) {
      result = result.replaceAll(latex, symbol);
    });

    // 5. Handle \frac{a}{b} → a/b
    result = result.replaceAllMapped(
      RegExp(r'\\frac\{([^}]+)\}\{([^}]+)\}'),
      (match) => '${match.group(1)}/${match.group(2)}',
    );

    // 6. Convert superscripts: x^2, x^{10}, etc.
    result = result.replaceAllMapped(RegExp(r'\^(\{?)(\d+)(\}?)'), (match) {
      final digits = match.group(2)!;
      return digits.split('').map((c) => _superscripts[c] ?? c).join();
    });

    // 7. Convert subscripts: H_2, C_{12}, etc.
    // Match: Letter followed by _ and digits (with optional braces)
    result = result.replaceAllMapped(RegExp(r'([A-Za-z])_(\{?)(\d+)(\}?)'), (
      match,
    ) {
      final element = match.group(1)!;
      final subscript = match.group(3)!;
      return element +
          subscript.split('').map((c) => _subscripts[c] ?? c).join();
    });

    // 8. FINAL PASS: Convert any remaining plain digit sequences after capital letters
    // This catches cases like "C6H12O6" → "C₆H₁₂O₆"
    result = result.replaceAllMapped(RegExp(r'([A-Z])(\d+)'), (match) {
      final element = match.group(1)!;
      final number = match.group(2)!;
      // Only convert single or double digit numbers in chemical context
      if (number.length <= 2) {
        return element +
            number.split('').map((c) => _subscripts[c] ?? c).join();
      }
      return match.group(0)!; // Keep as-is if longer
    });

    return result;
  }
}
