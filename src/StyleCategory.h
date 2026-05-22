#pragma once
// Lexer/style → spell-check category. Verbatim port of DSpellCheck's
// ScintillaUtils::get_style_category (covers ~60 Lexilla lexers).
enum class StyleCategory { text, comment, string, identifier, unknown };
StyleCategory get_style_category(int lexer, int style, bool check_default_udl_style);
