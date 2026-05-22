// DSpellCheck — macOS port (Hunspell, fully self-contained).
//
// Live spell-checking with red squiggle underline, suggestions, multi-language,
// dictionary management. Engine = bundled Hunspell (.aff/.dic), so behavior and
// dictionaries match the Windows original and are reusable on Linux/iOS.
//
// Plugin-only: standard NPP/Scintilla plugin API; no host changes.
//
// NOTE on menus: the macOS host renders plugin menus as a single flat level
// (no nested submenus via FuncItem). "Change Current Language" and "Additional
// Actions" are therefore click-to-open NSMenu popups (same items/names as the
// Windows submenus) — the closest faithful equivalent without host changes.

#include "NppPluginInterfaceMac.h"
#include "Scintilla.h"
#import <Cocoa/Cocoa.h>
#include <hunspell/hunspell.hxx>
#include <iconv.h>

#include <string>
#include <vector>
#include <set>
#include <map>
#include <memory>
#include <algorithm>

// ===========================================================================
// Plugin identity + menu
// ===========================================================================
static const char *PLUGIN_NAME = "DSpellCheck";

enum MenuIdx {
    MI_AutoCheck = 0, MI_FindNext, MI_FindPrev, MI_ChangeLang,
    MI_Sep1, MI_AdditionalActions, MI_Settings, MI_OnlineManual, MI_About,
    NB_FUNC
};
static FuncItem funcItem[NB_FUNC];
NppData nppData;

// ===========================================================================
// Scintilla helpers
// ===========================================================================
static intptr_t npp(uint32_t msg, uintptr_t w = 0, intptr_t l = 0) {
    return nppData._sendMessage(nppData._nppHandle, msg, w, l);
}
static NppHandle curSci() {
    int which = -1;
    npp(NPPM_GETCURRENTSCINTILLA, 0, (intptr_t)&which);
    return (which == 1) ? nppData._scintillaSecondHandle : nppData._scintillaMainHandle;
}
static intptr_t sci(uint32_t msg, uintptr_t w = 0, intptr_t l = 0) {
    return nppData._sendMessage(curSci(), msg, w, l);
}
static std::string sciGetRange(intptr_t a, intptr_t b) {
    if (b <= a) return {};
    std::string buf((size_t)(b - a), '\0');
    Sci_TextRangeFull tr; tr.chrg.cpMin = a; tr.chrg.cpMax = b; tr.lpstrText = buf.data();
    // need +1 for NUL; allocate one extra
    buf.resize((size_t)(b - a) + 1);
    tr.lpstrText = buf.data();
    sci(SCI_GETTEXTRANGEFULL, 0, (intptr_t)&tr);
    buf.resize((size_t)(b - a));
    return buf;
}
static intptr_t sciLen() { return sci(SCI_GETLENGTH); }

static std::string nsToStd(NSString *s) { return s ? std::string(s.UTF8String ?: "") : std::string(); }
static NSString *stdToNs(const std::string &s) { return [NSString stringWithUTF8String:s.c_str()] ?: @""; }

// ===========================================================================
// UTF-8 codepoint iteration
// ===========================================================================
static uint32_t utf8Decode(const std::string &s, size_t i, int &len) {
    unsigned char c = (unsigned char)s[i];
    if (c < 0x80) { len = 1; return c; }
    if ((c >> 5) == 0x6 && i + 1 < s.size()) { len = 2; return ((c & 0x1F) << 6) | (s[i+1] & 0x3F); }
    if ((c >> 4) == 0xE && i + 2 < s.size()) { len = 3; return ((c & 0x0F) << 12) | ((s[i+1] & 0x3F) << 6) | (s[i+2] & 0x3F); }
    if ((c >> 3) == 0x1E && i + 3 < s.size()) { len = 4; return ((c & 0x07) << 18) | ((s[i+1] & 0x3F) << 12) | ((s[i+2] & 0x3F) << 6) | (s[i+3] & 0x3F); }
    len = 1; return c;
}
static bool cpIsLetter(uint32_t cp) {
    if (cp < 0x80) return (cp >= 'A' && cp <= 'Z') || (cp >= 'a' && cp <= 'z');
    static NSCharacterSet *letters = [NSCharacterSet letterCharacterSet];
    if (cp <= 0xFFFF) return [letters characterIsMember:(unichar)cp];
    return [letters longCharacterIsMember:cp];
}
static bool cpIsDigit(uint32_t cp) { return cp >= '0' && cp <= '9'; }
static bool cpIsUpper(uint32_t cp) {
    if (cp < 0x80) return cp >= 'A' && cp <= 'Z';
    static NSCharacterSet *upper = [NSCharacterSet uppercaseLetterCharacterSet];
    if (cp <= 0xFFFF) return [upper characterIsMember:(unichar)cp];
    return [upper longCharacterIsMember:cp];
}
static bool cpIsApostrophe(uint32_t cp) { return cp == '\'' || cp == 0x2019; }

// ===========================================================================
// Settings (subset mirroring Windows DSpellCheck; INI persistence)
// ===========================================================================
struct Settings {
    bool auto_check_text = true;
    int suggestion_count = 5;
    std::string language = "en_US";          // active single language (dict base name)
    std::string multi_languages;             // semicolon list (unused in single mode)
    bool multi_mode = false;
    int underline_color = 0x0000FF;          // red (BGR for Scintilla = 0x0000FF? red = R; BGR 0x0000FF = red)
    int underline_style = INDIC_SQUIGGLE;
    // ignore rules
    bool ignore_containing_digit = true;
    bool ignore_starting_with_capital = false;
    bool ignore_having_a_capital = true;     // internal capital (camelCase/identifiers)
    bool ignore_all_capital = false;
    bool ignore_one_letter = false;
    bool ignore_having_underscore = false;
    int word_minimum_length = 0;
    // file types
    bool check_those = true;                 // true: check only matching; false: check only NOT matching
    std::string file_types = "*.*";
    // suggestions
    bool select_word_on_context_menu_click = true;
    std::string language_name_style = "english"; // original/english/native
    std::string hunspell_user_path;          // dict dir (user)
};
static Settings g_set;

static std::string configDir() {
    char buf[1024] = {0};
    npp(NPPM_GETPLUGINSCONFIGDIR, sizeof(buf), (intptr_t)buf);
    std::string dir = buf[0] ? buf : (nsToStd(NSHomeDirectory()) + "/.nextpad++/plugins/Config");
    return dir;
}
static std::string dictDir() {
    if (!g_set.hunspell_user_path.empty()) return g_set.hunspell_user_path;
    std::string d = configDir() + "/Hunspell";
    [[NSFileManager defaultManager] createDirectoryAtPath:stdToNs(d) withIntermediateDirectories:YES attributes:nil error:nil];
    return d;
}
static std::string iniPath() { return configDir() + "/DSpellCheck.ini"; }

static void loadSettings() {
    @autoreleasepool {
        NSString *c = [NSString stringWithContentsOfFile:stdToNs(iniPath()) encoding:NSUTF8StringEncoding error:nil];
        if (!c) return;
        std::map<std::string, std::string> kv;
        for (NSString *raw in [c componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
            std::string line = nsToStd(raw);
            auto p = line.find('=');
            if (p == std::string::npos || (!line.empty() && (line[0] == ';' || line[0] == '['))) continue;
            kv[line.substr(0, p)] = line.substr(p + 1);
        }
        auto B = [&](const char *k, bool &d){ auto it = kv.find(k); if (it != kv.end()) d = (it->second == "1"); };
        auto I = [&](const char *k, int &d){ auto it = kv.find(k); if (it != kv.end()) { try { d = std::stoi(it->second); } catch (...) {} } };
        auto S = [&](const char *k, std::string &d){ auto it = kv.find(k); if (it != kv.end()) d = it->second; };
        B("auto_check_text", g_set.auto_check_text);
        I("suggestion_count", g_set.suggestion_count);
        S("language", g_set.language);
        S("multi_languages", g_set.multi_languages);
        B("multi_mode", g_set.multi_mode);
        I("underline_color", g_set.underline_color);
        I("underline_style", g_set.underline_style);
        B("ignore_containing_digit", g_set.ignore_containing_digit);
        B("ignore_starting_with_capital", g_set.ignore_starting_with_capital);
        B("ignore_having_a_capital", g_set.ignore_having_a_capital);
        B("ignore_all_capital", g_set.ignore_all_capital);
        B("ignore_one_letter", g_set.ignore_one_letter);
        B("ignore_having_underscore", g_set.ignore_having_underscore);
        I("word_minimum_length", g_set.word_minimum_length);
        B("check_those", g_set.check_those);
        S("file_types", g_set.file_types);
        B("select_word_on_context_menu_click", g_set.select_word_on_context_menu_click);
        S("language_name_style", g_set.language_name_style);
        S("hunspell_user_path", g_set.hunspell_user_path);
    }
}
static void saveSettings() {
    @autoreleasepool {
        std::string o = "; DSpellCheck settings\n[General]\n";
        auto B = [&](const char *k, bool v){ o += std::string(k) + "=" + (v ? "1" : "0") + "\n"; };
        auto I = [&](const char *k, int v){ o += std::string(k) + "=" + std::to_string(v) + "\n"; };
        auto S = [&](const char *k, const std::string &v){ o += std::string(k) + "=" + v + "\n"; };
        B("auto_check_text", g_set.auto_check_text);
        I("suggestion_count", g_set.suggestion_count);
        S("language", g_set.language);
        S("multi_languages", g_set.multi_languages);
        B("multi_mode", g_set.multi_mode);
        I("underline_color", g_set.underline_color);
        I("underline_style", g_set.underline_style);
        B("ignore_containing_digit", g_set.ignore_containing_digit);
        B("ignore_starting_with_capital", g_set.ignore_starting_with_capital);
        B("ignore_having_a_capital", g_set.ignore_having_a_capital);
        B("ignore_all_capital", g_set.ignore_all_capital);
        B("ignore_one_letter", g_set.ignore_one_letter);
        B("ignore_having_underscore", g_set.ignore_having_underscore);
        I("word_minimum_length", g_set.word_minimum_length);
        B("check_those", g_set.check_those);
        S("file_types", g_set.file_types);
        B("select_word_on_context_menu_click", g_set.select_word_on_context_menu_click);
        S("language_name_style", g_set.language_name_style);
        S("hunspell_user_path", g_set.hunspell_user_path);
        [stdToNs(o) writeToFile:stdToNs(iniPath()) atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

// ===========================================================================
// Hunspell engine wrapper (one dictionary loaded; multi-language supported)
// ===========================================================================
class Dictionary {
public:
    std::string name;          // base name e.g. "en_US"
    std::string fullPath;      // base path without extension
    std::unique_ptr<Hunspell> hs;
    std::string encoding;      // dic encoding (e.g. UTF-8, ISO8859-1)
    std::string userDicPath;   // per-language .usr

    bool loaded() const { return hs != nullptr; }

    // convert UTF-8 std::string <-> dic encoding via iconv
    std::string toDic(const std::string &utf8) const { return convert(utf8, "UTF-8", encoding); }
    std::string fromDic(const std::string &enc) const { return convert(enc, encoding, "UTF-8"); }

    static std::string convert(const std::string &in, const std::string &from, const std::string &to) {
        if (from == to) return in;
        iconv_t cd = iconv_open(to.c_str(), from.c_str());
        if (cd == (iconv_t)-1) return in;
        std::vector<char> out((in.size() + 1) * 6 + 16);
        const char *inb = in.data(); size_t inl = in.size();
        char *outb = out.data(); size_t outl = out.size();
        size_t r = iconv(cd, (char **)&inb, &inl, &outb, &outl);
        iconv_close(cd);
        if (r == (size_t)-1) return in;
        return std::string(out.data(), out.size() - outl);
    }

    bool spell(const std::string &utf8word) const {
        if (!hs) return true;
        std::string w = toDic(utf8word);
        if (w.empty()) return true;
        return hs->spell(w);
    }
    std::vector<std::string> suggest(const std::string &utf8word) const {
        std::vector<std::string> out;
        if (!hs) return out;
        for (auto &s : hs->suggest(toDic(utf8word))) out.push_back(fromDic(s));
        return out;
    }
    void add(const std::string &utf8word) {
        if (!hs) return;
        hs->add(toDic(utf8word));
        // persist to per-language user dict (UTF-8 store; reloaded via add_dic on next load)
        FILE *fp = fopen(userDicPath.c_str(), "a");
        if (fp) { fprintf(fp, "%s\n", utf8word.c_str()); fclose(fp); }
    }
};

class Engine {
public:
    // available languages discovered in the dict dir (base name -> full path)
    std::map<std::string, std::string> available;
    std::vector<std::unique_ptr<Dictionary>> active;  // one (single) or many (multi)
    std::set<std::string> ignored;                    // session ignore list (UTF-8 lowercased originals)

    void scan() {
        available.clear();
        @autoreleasepool {
            NSString *dir = stdToNs(dictDir());
            NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];
            for (NSString *f in files) {
                if (![f.pathExtension isEqualToString:@"aff"]) continue;
                NSString *base = f.stringByDeletingPathExtension;
                NSString *dic = [NSString stringWithFormat:@"%@/%@.dic", dir, base];
                if ([[NSFileManager defaultManager] fileExistsAtPath:dic]) {
                    available[nsToStd(base)] = nsToStd([NSString stringWithFormat:@"%@/%@", dir, base]);
                }
            }
        }
    }

    bool working() const { return !active.empty() && active[0]->loaded(); }

    std::unique_ptr<Dictionary> load(const std::string &name) {
        auto it = available.find(name);
        if (it == available.end()) return nullptr;
        auto d = std::make_unique<Dictionary>();
        d->name = name; d->fullPath = it->second;
        std::string aff = it->second + ".aff", dic = it->second + ".dic";
        d->hs = std::make_unique<Hunspell>(aff.c_str(), dic.c_str());
        const char *enc = d->hs->get_dic_encoding();
        d->encoding = enc ? enc : "UTF-8";
        if (strcasecmp(d->encoding.c_str(), "Microsoft-cp1251") == 0) d->encoding = "cp1251";
        d->userDicPath = dictDir() + "/" + name + ".usr";
        // load persisted user words
        if ([[NSFileManager defaultManager] fileExistsAtPath:stdToNs(d->userDicPath)]) {
            @autoreleasepool {
                NSString *c = [NSString stringWithContentsOfFile:stdToNs(d->userDicPath) encoding:NSUTF8StringEncoding error:nil];
                for (NSString *w in [c componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
                    std::string ws = nsToStd(w); if (!ws.empty()) d->hs->add(d->toDic(ws));
                }
            }
        }
        return d;
    }

    void setLanguage(const std::string &name) {
        active.clear();
        auto d = load(name);
        if (d) active.push_back(std::move(d));
    }
    void setMultiLanguages(const std::vector<std::string> &names) {
        active.clear();
        for (auto &n : names) { auto d = load(n); if (d) active.push_back(std::move(d)); }
    }

    bool check(const std::string &utf8word) const {
        std::string low = nsToStd([stdToNs(utf8word) lowercaseString]);
        if (ignored.count(low)) return true;
        if (active.empty()) return true;
        for (auto &d : active) if (d->spell(utf8word)) return true;
        return false;
    }
    // suggestions from the dictionary that yields the most; tracks chosen dict for add
    std::vector<std::string> suggest(const std::string &utf8word, Dictionary **chosen) const {
        std::vector<std::string> best; Dictionary *bestDic = active.empty() ? nullptr : active[0].get();
        for (auto &d : active) {
            auto s = d->suggest(utf8word);
            if (s.size() > best.size()) { best = s; bestDic = d.get(); }
        }
        if (chosen) *chosen = bestDic;
        return best;
    }
    void ignore(const std::string &utf8word) { ignored.insert(nsToStd([stdToNs(utf8word) lowercaseString])); }
    void addToDictionary(const std::string &utf8word) {
        if (!active.empty()) active[0]->add(utf8word);
    }
};
static Engine g_engine;

// ===========================================================================
// Tokenizer + ignore rules
// ===========================================================================
struct Token { intptr_t start, end; std::string text; };  // byte offsets in the source string

static std::vector<Token> tokenize(const std::string &s) {
    std::vector<Token> out;
    size_t i = 0, n = s.size();
    while (i < n) {
        int len; uint32_t cp = utf8Decode(s, i, len);
        if (cpIsLetter(cp) || cpIsDigit(cp)) {
            size_t start = i;
            while (i < n) {
                int l2; uint32_t c2 = utf8Decode(s, i, l2);
                if (cpIsLetter(c2) || cpIsDigit(c2)) { i += l2; continue; }
                if (cpIsApostrophe(c2)) {
                    // apostrophe only counts if followed by a letter (e.g. don't)
                    size_t j = i + l2;
                    if (j < n) { int l3; uint32_t c3 = utf8Decode(s, j, l3); if (cpIsLetter(c3)) { i = j; continue; } }
                }
                break;
            }
            out.push_back({(intptr_t)start, (intptr_t)i, s.substr(start, i - start)});
        } else {
            i += len;
        }
    }
    return out;
}

// trim leading/trailing apostrophes
static std::string trimApostrophes(const std::string &w) {
    std::string r = w;
    while (!r.empty() && (r.front() == '\'' )) r.erase(r.begin());
    while (!r.empty() && (r.back() == '\'')) r.pop_back();
    // unicode right single quote (3 bytes) at ends
    auto stripRq = [](std::string &s, bool front){
        const std::string rq = "\xE2\x80\x99";
        if (front && s.size() >= 3 && s.compare(0,3,rq)==0) s.erase(0,3);
        if (!front && s.size() >= 3 && s.compare(s.size()-3,3,rq)==0) s.erase(s.size()-3);
    };
    stripRq(r, true); stripRq(r, false);
    return r;
}

static bool shouldCheckWord(const std::string &w) {
    if (w.empty()) return false;
    // decode codepoints
    std::vector<uint32_t> cps;
    for (size_t i = 0; i < w.size();) { int l; cps.push_back(utf8Decode(w, i, l)); i += l; }
    if (g_set.word_minimum_length > 0 && (int)cps.size() < g_set.word_minimum_length) return false;
    if (g_set.ignore_one_letter && cps.size() == 1) return false;
    bool anyDigit = false, anyLetter = false, allUpper = true, internalUpper = false, anyUnderscore = false;
    for (size_t k = 0; k < cps.size(); ++k) {
        uint32_t cp = cps[k];
        if (cpIsDigit(cp)) anyDigit = true;
        if (cp == '_') anyUnderscore = true;
        if (cpIsLetter(cp)) { anyLetter = true; if (!cpIsUpper(cp)) allUpper = false; if (k > 0 && cpIsUpper(cp)) internalUpper = true; }
    }
    if (!anyLetter) return false;
    if (g_set.ignore_containing_digit && anyDigit) return false;
    if (g_set.ignore_having_underscore && anyUnderscore) return false;
    if (g_set.ignore_all_capital && allUpper) return false;
    if (g_set.ignore_having_a_capital && internalUpper) return false;
    if (g_set.ignore_starting_with_capital && !cps.empty() && cpIsUpper(cps[0])) return false;
    return true;
}

// ===========================================================================
// Indicator (squiggle) + live checking
// ===========================================================================
static int g_indicator = -1;
static void ensureIndicator() {
    if (g_indicator >= 0) return;
    int id = -1; npp(NPPM_ALLOCATEINDICATOR, 1, (intptr_t)&id);
    g_indicator = (id >= 0) ? id : 18;
}
static void applyIndicatorStyle() {
    ensureIndicator();
    NppHandle h = curSci();
    nppData._sendMessage(h, SCI_INDICSETSTYLE, (uintptr_t)g_indicator, g_set.underline_style);
    nppData._sendMessage(h, SCI_INDICSETFORE, (uintptr_t)g_indicator, g_set.underline_color);
}
static void clearAllUnderlines() {
    ensureIndicator();
    NppHandle h = curSci();
    intptr_t len = nppData._sendMessage(h, SCI_GETLENGTH, 0, 0);
    nppData._sendMessage(h, SCI_SETINDICATORCURRENT, (uintptr_t)g_indicator, 0);
    nppData._sendMessage(h, SCI_INDICATORCLEARRANGE, 0, len);
}

// returns [start,end) byte range of visible document text
static void visibleRange(intptr_t &outStart, intptr_t &outEnd) {
    intptr_t firstVis = sci(SCI_GETFIRSTVISIBLELINE);
    intptr_t onScreen = sci(SCI_LINESONSCREEN);
    intptr_t topLine = sci(SCI_DOCLINEFROMVISIBLE, (uintptr_t)firstVis);
    intptr_t botLine = sci(SCI_DOCLINEFROMVISIBLE, (uintptr_t)(firstVis + onScreen));
    intptr_t len = sciLen();
    intptr_t start = sci(SCI_POSITIONFROMLINE, (uintptr_t)topLine);
    intptr_t end = sci(SCI_GETLINEENDPOSITION, (uintptr_t)botLine);
    if (start < 0) start = 0;
    if (end > len || end < 0) end = len;
    if (end < start) end = start;
    outStart = start; outEnd = end;
}

static void recheckVisible() {
    ensureIndicator();
    applyIndicatorStyle();
    NppHandle h = curSci();
    intptr_t vs, ve; visibleRange(vs, ve);
    // clear underlines across visible range first
    nppData._sendMessage(h, SCI_SETINDICATORCURRENT, (uintptr_t)g_indicator, 0);
    nppData._sendMessage(h, SCI_INDICATORCLEARRANGE, (uintptr_t)vs, ve - vs);
    if (!g_set.auto_check_text || !g_engine.working() || ve <= vs) return;
    std::string text = sciGetRange(vs, ve);
    for (auto &tok : tokenize(text)) {
        std::string w = trimApostrophes(tok.text);
        if (!shouldCheckWord(w)) continue;
        if (g_engine.check(w)) continue;
        nppData._sendMessage(h, SCI_INDICATORFILLRANGE, (uintptr_t)(vs + tok.start), tok.end - tok.start);
    }
}

// ===========================================================================
// Word at a document position (for suggestions / actions)
// ===========================================================================
static bool wordAt(intptr_t pos, intptr_t &outStart, intptr_t &outEnd, std::string &outWord) {
    intptr_t len = sciLen();
    if (pos < 0 || pos > len) return false;
    intptr_t line = sci(SCI_LINEFROMPOSITION, (uintptr_t)pos);
    intptr_t ls = sci(SCI_POSITIONFROMLINE, (uintptr_t)line);
    intptr_t le = sci(SCI_GETLINEENDPOSITION, (uintptr_t)line);
    std::string lineText = sciGetRange(ls, le);
    intptr_t rel = pos - ls;
    for (auto &tok : tokenize(lineText)) {
        if (rel >= tok.start && rel <= tok.end) {
            std::string w = trimApostrophes(tok.text);
            outStart = ls + tok.start; outEnd = ls + tok.end; outWord = w;
            return !w.empty();
        }
    }
    return false;
}

// ===========================================================================
// Language display names
// ===========================================================================
static NSString *languageDisplayName(const std::string &code) {
    if (g_set.language_name_style == "original") return stdToNs(code);
    @autoreleasepool {
        NSString *c = stdToNs(code);
        NSString *norm = [c stringByReplacingOccurrencesOfString:@"_" withString:@"-"];
        NSLocale *en = [NSLocale localeWithLocaleIdentifier:@"en_US"];
        NSString *display = (g_set.language_name_style == "native")
            ? [[NSLocale localeWithLocaleIdentifier:norm] localizedStringForLocaleIdentifier:norm]
            : [en localizedStringForLocaleIdentifier:norm];
        if (display.length > 0) return display;
        return c;
    }
}

// ===========================================================================
// Suggestions popup (right-click equivalent / Show Suggestions at Cursor)
// ===========================================================================
@interface DSCActions : NSObject
+ (instancetype)shared;
- (void)applySuggestion:(NSMenuItem *)item;
- (void)ignoreWord:(NSMenuItem *)item;
- (void)addWord:(NSMenuItem *)item;
- (void)pickLanguage:(NSMenuItem *)item;
@property(nonatomic, assign) intptr_t wStart;
@property(nonatomic, assign) intptr_t wEnd;
@property(nonatomic, copy) NSString *word;
@end

static void replaceRange(intptr_t a, intptr_t b, const std::string &with) {
    NppHandle h = curSci();
    nppData._sendMessage(h, SCI_SETTARGETRANGE, (uintptr_t)a, b);
    nppData._sendMessage(h, SCI_REPLACETARGET, (uintptr_t)with.size(), (intptr_t)with.c_str());
}

@implementation DSCActions
+ (instancetype)shared { static DSCActions *s; static dispatch_once_t o; dispatch_once(&o, ^{ s = [DSCActions new]; }); return s; }
- (void)applySuggestion:(NSMenuItem *)item {
    replaceRange(self.wStart, self.wEnd, nsToStd(item.representedObject));
    recheckVisible();
}
- (void)ignoreWord:(NSMenuItem *)item { g_engine.ignore(nsToStd(self.word)); recheckVisible(); }
- (void)addWord:(NSMenuItem *)item { g_engine.addToDictionary(nsToStd(self.word)); recheckVisible(); }
- (void)pickLanguage:(NSMenuItem *)item {
    g_set.language = nsToStd(item.representedObject);
    g_set.multi_mode = false;
    g_engine.setLanguage(g_set.language);
    saveSettings();
    recheckVisible();
}
@end

static void showSuggestionsForPosition(intptr_t pos) {
    intptr_t ws, we; std::string word;
    if (!wordAt(pos, ws, we, word) || !shouldCheckWord(trimApostrophes(word))) { NSBeep(); return; }
    std::string w = trimApostrophes(word);
    if (g_engine.check(w)) { NSBeep(); return; }  // not misspelled
    if (g_set.select_word_on_context_menu_click) sci(SCI_SETSEL, (uintptr_t)ws, we);
    DSCActions *act = [DSCActions shared];
    act.wStart = ws; act.wEnd = we; act.word = stdToNs(w);
    @autoreleasepool {
        NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Spelling"];
        Dictionary *chosen = nullptr;
        auto sugg = g_engine.suggest(w, &chosen);
        int n = std::min((int)sugg.size(), std::max(1, g_set.suggestion_count));
        if (sugg.empty()) {
            NSMenuItem *mi = [[NSMenuItem alloc] initWithTitle:@"(no suggestions)" action:nil keyEquivalent:@""];
            mi.enabled = NO; [menu addItem:mi];
        } else {
            for (int i = 0; i < n; ++i) {
                NSMenuItem *mi = [[NSMenuItem alloc] initWithTitle:stdToNs(sugg[i]) action:@selector(applySuggestion:) keyEquivalent:@""];
                mi.target = act; mi.representedObject = stdToNs(sugg[i]);
                [menu addItem:mi];
            }
        }
        [menu addItem:[NSMenuItem separatorItem]];
        NSMenuItem *ign = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"Ignore \"%s\"", w.c_str()] action:@selector(ignoreWord:) keyEquivalent:@""];
        ign.target = act; [menu addItem:ign];
        NSMenuItem *add = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"Add \"%s\" to dictionary", w.c_str()] action:@selector(addWord:) keyEquivalent:@""];
        add.target = act; [menu addItem:add];
        // popup at the current mouse location (screen coords when view is nil)
        [menu popUpMenuPositioningItem:nil atLocation:[NSEvent mouseLocation] inView:nil];
    }
}

// ===========================================================================
// Find next / previous misspelling
// ===========================================================================
static void findMistake(bool forward) {
    if (!g_engine.working()) { NSBeep(); return; }
    intptr_t len = sciLen();
    if (len == 0) { NSBeep(); return; }
    intptr_t cur = sci(SCI_GETCURRENTPOS);
    std::string all = sciGetRange(0, len);
    auto toks = tokenize(all);
    // build misspelled token ranges
    std::vector<std::pair<intptr_t,intptr_t>> bad;
    for (auto &t : toks) { std::string w = trimApostrophes(t.text); if (shouldCheckWord(w) && !g_engine.check(w)) bad.push_back({t.start, t.end}); }
    if (bad.empty()) { NSBeep(); return; }
    if (forward) {
        for (auto &b : bad) if (b.first >= cur) { sci(SCI_SETSEL, (uintptr_t)b.first, b.second); sci(SCI_SCROLLCARET); recheckVisible(); return; }
        sci(SCI_SETSEL, (uintptr_t)bad.front().first, bad.front().second); // wrap
    } else {
        for (auto it = bad.rbegin(); it != bad.rend(); ++it) if (it->second < cur) { sci(SCI_SETSEL, (uintptr_t)it->first, it->second); sci(SCI_SCROLLCARET); recheckVisible(); return; }
        sci(SCI_SETSEL, (uintptr_t)bad.back().first, bad.back().second); // wrap
    }
    sci(SCI_SCROLLCARET); recheckVisible();
}

// ===========================================================================
// Additional Actions implementations
// ===========================================================================
static std::vector<std::string> allMisspellings() {
    std::set<std::string> uniq; std::vector<std::string> order;
    intptr_t len = sciLen(); if (len == 0) return order;
    std::string all = sciGetRange(0, len);
    for (auto &t : tokenize(all)) {
        std::string w = trimApostrophes(t.text);
        if (shouldCheckWord(w) && !g_engine.check(w)) { if (uniq.insert(w).second) order.push_back(w); }
    }
    return order;
}
static void copyMisspellings() {
    auto words = allMisspellings();
    std::string out; for (auto &w : words) out += w + "\n";
    NSPasteboard *pb = NSPasteboard.generalPasteboard; [pb clearContents];
    [pb setString:stdToNs(out) forType:NSPasteboardTypeString];
}
static void replaceWithTopSuggestion() {
    intptr_t ws, we; std::string word;
    intptr_t cur = sci(SCI_GETSELECTIONSTART);
    if (!wordAt(cur, ws, we, word)) { NSBeep(); return; }
    std::string w = trimApostrophes(word);
    if (g_engine.check(w)) { NSBeep(); return; }
    Dictionary *c = nullptr; auto s = g_engine.suggest(w, &c);
    if (s.empty()) { NSBeep(); return; }
    replaceRange(ws, we, s[0]); recheckVisible();
}
static void ignoreWordAtCursor() {
    intptr_t ws, we; std::string word;
    if (!wordAt(sci(SCI_GETSELECTIONSTART), ws, we, word)) { NSBeep(); return; }
    g_engine.ignore(trimApostrophes(word)); recheckVisible();
}

// block invoker helper (lets popup items run C++ lambdas)
@interface DSCBlockInvoker : NSObject
+ (instancetype)shared;
- (void)invokeBlock:(NSMenuItem *)item;
@end

// ===========================================================================
// Menu actions
// ===========================================================================
static void doRecheckSoon();
static void showDownloadDialog();

static void cmdAutoCheck() {
    g_set.auto_check_text = !g_set.auto_check_text;
    npp(NPPM_SETMENUITEMCHECK, (uintptr_t)funcItem[MI_AutoCheck]._cmdID, g_set.auto_check_text ? 1 : 0);
    saveSettings();
    if (g_set.auto_check_text) recheckVisible(); else clearAllUnderlines();
}
static void cmdFindNext() { findMistake(true); }
static void cmdFindPrev() { findMistake(false); }

static void cmdChangeLang() {
    @autoreleasepool {
        g_engine.scan();
        NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Language"];
        DSCActions *act = [DSCActions shared];
        if (g_engine.available.empty()) {
            NSMenuItem *mi = [[NSMenuItem alloc] initWithTitle:@"(no dictionaries installed)" action:nil keyEquivalent:@""];
            mi.enabled = NO; [menu addItem:mi];
        } else {
            for (auto &kv : g_engine.available) {
                NSMenuItem *mi = [[NSMenuItem alloc] initWithTitle:languageDisplayName(kv.first) action:@selector(pickLanguage:) keyEquivalent:@""];
                mi.target = act; mi.representedObject = stdToNs(kv.first);
                if (!g_set.multi_mode && kv.first == g_set.language) mi.state = NSControlStateValueOn;
                [menu addItem:mi];
            }
        }
        [menu addItem:[NSMenuItem separatorItem]];
        NSMenuItem *dl = [[NSMenuItem alloc] initWithTitle:@"Download Languages…" action:@selector(invokeBlock:) keyEquivalent:@""];
        dl.target = [DSCBlockInvoker shared];
        dl.representedObject = [^{ showDownloadDialog(); } copy];
        [menu addItem:dl];
        [menu popUpMenuPositioningItem:nil atLocation:[NSEvent mouseLocation] inView:nil];
    }
}

static void cmdAdditionalActions() {
    @autoreleasepool {
        NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Additional Actions"];
        auto add = ^(NSString *title, void(^block)()) {
            NSMenuItem *mi = [[NSMenuItem alloc] initWithTitle:title action:@selector(invokeBlock:) keyEquivalent:@""];
            mi.target = [DSCBlockInvoker shared]; mi.representedObject = [block copy];
            [menu addItem:mi];
        };
        add(@"Copy All Misspelled Words to Clipboard", ^{ copyMisspellings(); });
        add(@"Erase All Misspelled Words", ^{
            auto words = allMisspellings(); (void)words; // erase performed below
            // erase by scanning whole doc back-to-front
            intptr_t len = sciLen(); std::string all = sciGetRange(0, len);
            auto toks = tokenize(all);
            sci(SCI_BEGINUNDOACTION);
            for (auto it = toks.rbegin(); it != toks.rend(); ++it) {
                std::string w = trimApostrophes(it->text);
                if (shouldCheckWord(w) && !g_engine.check(w)) replaceRange(it->start, it->end, "");
            }
            sci(SCI_ENDUNDOACTION); recheckVisible();
        });
        add(@"Bookmark Lines with Misspelling", ^{
            intptr_t len = sciLen(); std::string all = sciGetRange(0, len);
            std::set<intptr_t> lines;
            for (auto &t : tokenize(all)) { std::string w = trimApostrophes(t.text); if (shouldCheckWord(w) && !g_engine.check(w)) lines.insert(sci(SCI_LINEFROMPOSITION,(uintptr_t)t.start)); }
            // Host draws bookmarks on Scintilla marker 20 (kBookmarkMarker); NPPM_GETBOOKMARKID
            // reports 24 but the host actually uses 20, so use 20 to match what's visible.
            for (auto ln : lines) { sci(SCI_MARKERADD, (uintptr_t)ln, 20); }
        });
        add(@"Replace with Topmost Suggestion", ^{ replaceWithTopSuggestion(); });
        add(@"Ignore Word at Cursor", ^{ ignoreWordAtCursor(); });
        add(@"Show Suggestions Menu at Cursor", ^{ showSuggestionsForPosition(sci(SCI_GETCURRENTPOS)); });
        add(@"Reload Hunspell Dictionaries", ^{ g_engine.scan(); if (!g_set.multi_mode) g_engine.setLanguage(g_set.language); recheckVisible(); });
        [menu popUpMenuPositioningItem:nil atLocation:[NSEvent mouseLocation] inView:nil];
    }
}

static void cmdSettings();   // defined in Settings dialog phase
static void cmdOnlineManual() {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"https://github.com/Predelnik/DSpellCheck/wiki"]];
}
static void cmdAbout() {
    @autoreleasepool {
        NSAlert *a = [[NSAlert alloc] init];
        a.messageText = @"DSpellCheck";
        a.informativeText = @"macOS port — live spell-checking with Hunspell.\n\n"
            "Original Windows plugin by Sergey Semushin (Predelnik). GPL v3.\n"
            "Bundled Hunspell engine; dictionaries are LibreOffice/OpenOffice .aff/.dic.";
        [a addButtonWithTitle:@"OK"]; [a runModal];
    }
}

@implementation DSCBlockInvoker
+ (instancetype)shared { static DSCBlockInvoker *s; static dispatch_once_t o; dispatch_once(&o, ^{ s = [DSCBlockInvoker new]; }); return s; }
- (void)invokeBlock:(NSMenuItem *)item { void(^b)() = item.representedObject; if (b) b(); }
@end

// ===========================================================================
// Settings dialog (Simple + Advanced tabs) — matches the Windows layout
// ===========================================================================
static void showDownloadDialog();   // defined in download phase

@interface DSCSettings : NSObject <NSWindowDelegate>
@property(nonatomic, strong) NSWindow *window;
// Simple tab
@property(nonatomic, strong) NSTextField *pathField;
@property(nonatomic, strong) NSPopUpButton *namingStyle;
@property(nonatomic, strong) NSPopUpButton *language;
@property(nonatomic, strong) NSTextField *maxSugg;
@property(nonatomic, strong) NSButton *radioThose, *radioNotThose;
@property(nonatomic, strong) NSTextField *fileTypes;
@property(nonatomic, strong) NSButton *cbComments, *cbStrings, *cbVarNames;
@property(nonatomic, strong) NSButton *cbSelectWord;
// Advanced tab
@property(nonatomic, strong) NSButton *igDigit, *igStartCap, *igHaveCap, *igAllCap, *igOne, *igUnderscore;
@property(nonatomic, strong) NSTextField *minLen;
@end

@implementation DSCSettings

- (instancetype)init { if ((self = [super init])) [self build]; return self; }

- (NSTextField *)lbl:(NSString *)s frame:(NSRect)f to:(NSView *)v {
    NSTextField *t = [NSTextField labelWithString:s]; t.frame = f; [v addSubview:t]; return t;
}

- (void)build {
    NSRect r = NSMakeRect(0, 0, 560, 620);
    _window = [[NSWindow alloc] initWithContentRect:r
        styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
        backing:NSBackingStoreBuffered defer:YES];
    _window.title = @"DSpellCheck Settings";
    _window.releasedWhenClosed = NO; _window.delegate = self;
    NSView *root = _window.contentView;

    NSTabView *tabs = [[NSTabView alloc] initWithFrame:NSMakeRect(12, 56, 536, 552)];
    [root addSubview:tabs];
    NSTabViewItem *simple = [[NSTabViewItem alloc] initWithIdentifier:@"simple"]; simple.label = @"Simple";
    NSTabViewItem *adv = [[NSTabViewItem alloc] initWithIdentifier:@"advanced"]; adv.label = @"Advanced";
    [tabs addTabViewItem:simple]; [tabs addTabViewItem:adv];
    NSView *sv = [[NSView alloc] initWithFrame:NSMakeRect(0,0,520,520)]; simple.view = sv;
    NSView *av = [[NSView alloc] initWithFrame:NSMakeRect(0,0,520,520)]; adv.view = av;

    // ---- Simple tab (top-down; y measured from bottom) ----
    CGFloat W = 520;
    [self lbl:@"Library:" frame:NSMakeRect(12, 484, 70, 20) to:sv];
    NSPopUpButton *lib = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(86, 480, 150, 26)];
    [lib addItemWithTitle:@"Hunspell"]; [sv addSubview:lib];

    NSBox *hbox = [[NSBox alloc] initWithFrame:NSMakeRect(12, 350, W-24, 122)];
    hbox.title = @"Hunspell Settings"; [sv addSubview:hbox];
    [self lbl:@"Hunspell Dictionaries Path" frame:NSMakeRect(10, 78, 220, 18) to:hbox];
    _pathField = [[NSTextField alloc] initWithFrame:NSMakeRect(10, 56, W-24-60, 22)];
    _pathField.stringValue = stdToNs(dictDir()); [hbox addSubview:_pathField];
    NSButton *browse = [NSButton buttonWithTitle:@"…" target:self action:@selector(browse:)];
    browse.frame = NSMakeRect(W-24-46, 55, 36, 24); [hbox addSubview:browse];
    NSButton *download = [NSButton buttonWithTitle:@"Download…" target:self action:@selector(download:)];
    download.frame = NSMakeRect(10, 12, 130, 28); [hbox addSubview:download];
    NSButton *remove = [NSButton buttonWithTitle:@"Remove Dictionaries…" target:self action:@selector(removeDicts:)];
    remove.frame = NSMakeRect(150, 12, 180, 28); [hbox addSubview:remove];
    NSButton *reveal = [NSButton buttonWithTitle:@"Reveal" target:self action:@selector(reveal:)];
    reveal.frame = NSMakeRect(W-24-90, 12, 80, 28); [hbox addSubview:reveal];

    [self lbl:@"Language Naming Style:" frame:NSMakeRect(12, 318, 170, 20) to:sv];
    _namingStyle = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(190, 314, 180, 26)];
    [_namingStyle addItemsWithTitles:@[@"Original", @"English", @"Native"]]; [sv addSubview:_namingStyle];

    [self lbl:@"Language:" frame:NSMakeRect(12, 286, 170, 20) to:sv];
    _language = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(190, 282, 180, 26)]; [sv addSubview:_language];

    [self lbl:@"Max Number of Suggestions:" frame:NSMakeRect(12, 254, 220, 20) to:sv];
    _maxSugg = [[NSTextField alloc] initWithFrame:NSMakeRect(240, 252, 60, 22)]; [sv addSubview:_maxSugg];

    NSBox *fbox = [[NSBox alloc] initWithFrame:NSMakeRect(12, 150, W-24, 92)];
    fbox.title = @"File Types (Separate with semicolon ; )"; [fbox setContentViewMargins:NSMakeSize(6,4)]; [sv addSubview:fbox];
    _radioThose = [NSButton radioButtonWithTitle:@"Check only those:" target:self action:@selector(radioChanged:)];
    _radioThose.frame = NSMakeRect(10, 42, 180, 20); [fbox addSubview:_radioThose];
    _radioNotThose = [NSButton radioButtonWithTitle:@"Check only NOT those:" target:self action:@selector(radioChanged:)];
    _radioNotThose.frame = NSMakeRect(220, 42, 200, 20); [fbox addSubview:_radioNotThose];
    _fileTypes = [[NSTextField alloc] initWithFrame:NSMakeRect(10, 12, W-44, 22)]; [fbox addSubview:_fileTypes];

    NSBox *cbox = [[NSBox alloc] initWithFrame:NSMakeRect(12, 86, W-24, 56)];
    cbox.title = @"In code, check only:"; [sv addSubview:cbox];
    _cbComments = [NSButton checkboxWithTitle:@"Comments" target:nil action:nil]; _cbComments.frame = NSMakeRect(10, 8, 110, 20); [cbox addSubview:_cbComments];
    _cbStrings = [NSButton checkboxWithTitle:@"Strings" target:nil action:nil]; _cbStrings.frame = NSMakeRect(130, 8, 100, 20); [cbox addSubview:_cbStrings];
    _cbVarNames = [NSButton checkboxWithTitle:@"Function/Variable names" target:nil action:nil]; _cbVarNames.frame = NSMakeRect(240, 8, 230, 20); [cbox addSubview:_cbVarNames];

    [self lbl:@"Suggestions Control:" frame:NSMakeRect(12, 54, 160, 20) to:sv];
    NSPopUpButton *sc = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(180, 50, 200, 26)];
    [sc addItemWithTitle:@"Use N++ Context Menu"]; [sv addSubview:sc];
    _cbSelectWord = [NSButton checkboxWithTitle:@"Select the Misspelled Words when Menu is Triggered" target:nil action:nil];
    _cbSelectWord.frame = NSMakeRect(12, 20, W-24, 20); [sv addSubview:_cbSelectWord];

    // ---- Advanced tab ----
    [self lbl:@"Ignore words that…" frame:NSMakeRect(12, 484, 300, 20) to:av];
    _igDigit = [NSButton checkboxWithTitle:@"…contain a digit" target:nil action:nil]; _igDigit.frame = NSMakeRect(20, 456, 300, 20); [av addSubview:_igDigit];
    _igStartCap = [NSButton checkboxWithTitle:@"…start with a capital letter" target:nil action:nil]; _igStartCap.frame = NSMakeRect(20, 432, 300, 20); [av addSubview:_igStartCap];
    _igHaveCap = [NSButton checkboxWithTitle:@"…have a capital letter not at the start (camelCase, ALLCAPS)" target:nil action:nil]; _igHaveCap.frame = NSMakeRect(20, 408, 460, 20); [av addSubview:_igHaveCap];
    _igAllCap = [NSButton checkboxWithTitle:@"…are entirely capitalized" target:nil action:nil]; _igAllCap.frame = NSMakeRect(20, 384, 300, 20); [av addSubview:_igAllCap];
    _igOne = [NSButton checkboxWithTitle:@"…are a single letter" target:nil action:nil]; _igOne.frame = NSMakeRect(20, 360, 300, 20); [av addSubview:_igOne];
    _igUnderscore = [NSButton checkboxWithTitle:@"…contain an underscore" target:nil action:nil]; _igUnderscore.frame = NSMakeRect(20, 336, 300, 20); [av addSubview:_igUnderscore];
    [self lbl:@"Minimum word length to check:" frame:NSMakeRect(20, 300, 230, 20) to:av];
    _minLen = [[NSTextField alloc] initWithFrame:NSMakeRect(252, 298, 60, 22)]; [av addSubview:_minLen];

    // ---- bottom buttons ----
    NSButton *ok = [NSButton buttonWithTitle:@"OK" target:self action:@selector(ok:)]; ok.frame = NSMakeRect(300, 14, 78, 30); ok.keyEquivalent = @"\r"; [root addSubview:ok];
    NSButton *cancel = [NSButton buttonWithTitle:@"Cancel" target:self action:@selector(cancel:)]; cancel.frame = NSMakeRect(386, 14, 78, 30); cancel.keyEquivalent = @"\e"; [root addSubview:cancel];
    NSButton *apply = [NSButton buttonWithTitle:@"Apply" target:self action:@selector(apply:)]; apply.frame = NSMakeRect(472, 14, 78, 30); [root addSubview:apply];

    [self loadFromSettings];
    self.namingStyle.target = self; self.namingStyle.action = @selector(namingChanged:);
}

- (void)loadFromSettings {
    g_engine.scan();
    _pathField.stringValue = stdToNs(dictDir());
    NSString *ns = stdToNs(g_set.language_name_style);
    [_namingStyle selectItemWithTitle:[ns capitalizedString]];
    [self rebuildLanguageList];
    _maxSugg.stringValue = [NSString stringWithFormat:@"%d", g_set.suggestion_count];
    _radioThose.state = g_set.check_those ? NSControlStateValueOn : NSControlStateValueOff;
    _radioNotThose.state = g_set.check_those ? NSControlStateValueOff : NSControlStateValueOn;
    _fileTypes.stringValue = stdToNs(g_set.file_types);
    _cbSelectWord.state = g_set.select_word_on_context_menu_click ? NSControlStateValueOn : NSControlStateValueOff;
    _cbComments.state = NSControlStateValueOn; _cbStrings.state = NSControlStateValueOn; // cosmetic defaults
    _igDigit.state = g_set.ignore_containing_digit ? NSControlStateValueOn : NSControlStateValueOff;
    _igStartCap.state = g_set.ignore_starting_with_capital ? NSControlStateValueOn : NSControlStateValueOff;
    _igHaveCap.state = g_set.ignore_having_a_capital ? NSControlStateValueOn : NSControlStateValueOff;
    _igAllCap.state = g_set.ignore_all_capital ? NSControlStateValueOn : NSControlStateValueOff;
    _igOne.state = g_set.ignore_one_letter ? NSControlStateValueOn : NSControlStateValueOff;
    _igUnderscore.state = g_set.ignore_having_underscore ? NSControlStateValueOn : NSControlStateValueOff;
    _minLen.stringValue = [NSString stringWithFormat:@"%d", g_set.word_minimum_length];
}
- (void)rebuildLanguageList {
    [_language removeAllItems];
    for (auto &kv : g_engine.available) {
        [_language addItemWithTitle:languageDisplayName(kv.first)];
        _language.lastItem.representedObject = stdToNs(kv.first);
        if (kv.first == g_set.language) [_language selectItem:_language.lastItem];
    }
}
- (void)namingChanged:(id)s {
    int idx = (int)_namingStyle.indexOfSelectedItem;
    g_set.language_name_style = (idx==0?"original":(idx==2?"native":"english"));
    [self rebuildLanguageList];
}
- (void)radioChanged:(NSButton *)sender {
    _radioThose.state = (sender==_radioThose) ? NSControlStateValueOn : NSControlStateValueOff;
    _radioNotThose.state = (sender==_radioNotThose) ? NSControlStateValueOn : NSControlStateValueOff;
}
- (void)browse:(id)s {
    NSOpenPanel *op = [NSOpenPanel openPanel]; op.canChooseDirectories = YES; op.canChooseFiles = NO;
    if ([op runModal] == NSModalResponseOK && op.URL) _pathField.stringValue = op.URL.path;
}
- (void)download:(id)s { showDownloadDialog(); }
- (void)removeDicts:(id)s { [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:stdToNs(dictDir())]]; }
- (void)reveal:(id)s { [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:stdToNs(dictDir())]]; }

- (void)applySettings {
    [self.window makeFirstResponder:nil];
    int idx = (int)_namingStyle.indexOfSelectedItem;
    g_set.language_name_style = (idx==0?"original":(idx==2?"native":"english"));
    if (_language.selectedItem.representedObject) g_set.language = nsToStd(_language.selectedItem.representedObject);
    g_set.suggestion_count = std::max(1, _maxSugg.intValue);
    g_set.check_those = (_radioThose.state == NSControlStateValueOn);
    g_set.file_types = nsToStd(_fileTypes.stringValue);
    g_set.select_word_on_context_menu_click = (_cbSelectWord.state == NSControlStateValueOn);
    g_set.ignore_containing_digit = (_igDigit.state == NSControlStateValueOn);
    g_set.ignore_starting_with_capital = (_igStartCap.state == NSControlStateValueOn);
    g_set.ignore_having_a_capital = (_igHaveCap.state == NSControlStateValueOn);
    g_set.ignore_all_capital = (_igAllCap.state == NSControlStateValueOn);
    g_set.ignore_one_letter = (_igOne.state == NSControlStateValueOn);
    g_set.ignore_having_underscore = (_igUnderscore.state == NSControlStateValueOn);
    g_set.word_minimum_length = std::max(0, _minLen.intValue);
    std::string newPath = nsToStd(_pathField.stringValue);
    if (newPath != g_set.hunspell_user_path && newPath != (configDir()+"/Hunspell")) g_set.hunspell_user_path = newPath;
    saveSettings();
    g_engine.scan();
    if (!g_set.multi_mode) g_engine.setLanguage(g_set.language);
    recheckVisible();
}
- (void)apply:(id)s { [self applySettings]; }
- (void)ok:(id)s { [self applySettings]; [NSApp stopModal]; }
- (void)cancel:(id)s { [NSApp stopModal]; }
- (void)windowWillClose:(NSNotification *)n { [NSApp stopModal]; }
- (void)run { [self.window center]; [NSApp runModalForWindow:self.window]; [self.window orderOut:nil]; }
@end

static void cmdSettings() {
    @autoreleasepool {
        static DSCSettings *dlg = nil;
        dlg = [[DSCSettings alloc] init];
        [dlg run];
    }
}

// Download Dictionaries — full dialog (LibreOffice list + install) built next phase.
static void showDownloadDialog() {
    @autoreleasepool {
        NSAlert *a = [[NSAlert alloc] init];
        a.messageText = @"Download Dictionaries";
        a.informativeText = @"Place Hunspell .aff/.dic dictionary pairs in the dictionaries folder, "
            "then use Reload Hunspell Dictionaries.\n\n"
            "Dictionaries: https://github.com/LibreOffice/dictionaries\n\n"
            "(In-app download dialog is being added in a follow-up build.)";
        [a addButtonWithTitle:@"Open LibreOffice Dictionaries"];
        [a addButtonWithTitle:@"Reveal Folder"];
        [a addButtonWithTitle:@"Close"];
        NSModalResponse r = [a runModal];
        if (r == NSAlertFirstButtonReturn)
            [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"https://github.com/LibreOffice/dictionaries"]];
        else if (r == NSAlertSecondButtonReturn)
            [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:stdToNs(dictDir())]];
    }
}

// ===========================================================================
// Debounced recheck on edit/scroll
// ===========================================================================
static void doRecheckSoon() {
    static int64_t token = 0;
    int64_t mine = ++token;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (mine == token) recheckVisible();
    });
}

// ===========================================================================
// Left single-click on a misspelled word → suggestions popup.
//
// App-wide local monitor on leftMouseUp. The click is never consumed (normal
// caret placement / editing is preserved); after the click is processed we read
// the caret position (so no coordinate mapping is needed) and, if it's a plain
// click — not a drag-selection — on a misspelled word, we show the suggestions.
// This avoids fighting the host's right-click context menu entirely.
// ===========================================================================
static id g_clickMonitor = nil;
static void installClickMonitor() {
    if (g_clickMonitor) return;
    g_clickMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseUp
        handler:^NSEvent *(NSEvent *e) {
            if (!g_set.auto_check_text || !g_engine.working()) return e;
            if (e.clickCount != 1) return e;   // ignore double/triple clicks
            // defer until after Scintilla has processed the click and moved the caret
            dispatch_async(dispatch_get_main_queue(), ^{
                if (sci(SCI_GETSELECTIONSTART) != sci(SCI_GETSELECTIONEND)) return; // was a drag-select
                intptr_t pos = sci(SCI_GETCURRENTPOS);
                intptr_t ws, we; std::string word;
                if (!wordAt(pos, ws, we, word)) return;
                std::string w = trimApostrophes(word);
                if (shouldCheckWord(w) && !g_engine.check(w)) showSuggestionsForPosition(pos);
            });
            return e; // never consume left clicks
        }];
}

// ===========================================================================
// Toolbar icon
// ===========================================================================
static void handleToolbarModification() {
    npp(NPPM_ADDTOOLBARICON_FORDARKMODE, (uintptr_t)funcItem[MI_AutoCheck]._cmdID, (intptr_t)"spellcheck.png");
}

// ===========================================================================
// Plugin exports
// ===========================================================================
static void setItem(int idx, const char *name, PFUNCPLUGINCMD fn, bool check = false) {
    strncpy(funcItem[idx]._itemName, name, NPP_MENU_ITEM_SIZE - 1);
    funcItem[idx]._pFunc = fn;
    funcItem[idx]._init2Check = check;
}

extern "C" NPP_EXPORT void setInfo(NppData data) {
    nppData = data;
    memset(funcItem, 0, sizeof(funcItem));
    loadSettings();
    g_engine.scan();
    if (!g_set.multi_mode) g_engine.setLanguage(g_set.language);
    setItem(MI_AutoCheck, "Spell Check Document Automatically", cmdAutoCheck, g_set.auto_check_text);
    setItem(MI_FindNext, "Find Next Misspelling", cmdFindNext);
    setItem(MI_FindPrev, "Find Previous Misspelling", cmdFindPrev);
    setItem(MI_ChangeLang, "Change Current Language…", cmdChangeLang);
    setItem(MI_Sep1, "", nullptr);
    setItem(MI_AdditionalActions, "Additional Actions…", cmdAdditionalActions);
    setItem(MI_Settings, "Settings…", cmdSettings);
    setItem(MI_OnlineManual, "Online Manual", cmdOnlineManual);
    setItem(MI_About, "About", cmdAbout);
}
extern "C" NPP_EXPORT const char *getName() { return PLUGIN_NAME; }
extern "C" NPP_EXPORT FuncItem *getFuncsArray(int *nbF) { *nbF = NB_FUNC; return funcItem; }

extern "C" NPP_EXPORT void beNotified(SCNotification *n) {
    if (!n) return;
    switch (n->nmhdr.code) {
        case NPPN_TBMODIFICATION: handleToolbarModification(); break;
        case NPPN_READY: applyIndicatorStyle(); installClickMonitor(); if (g_set.auto_check_text) recheckVisible(); break;
        case NPPN_BUFFERACTIVATED: if (g_set.auto_check_text) doRecheckSoon(); break;
        case SCN_MODIFIED:
            if ((n->modificationType & (SC_MOD_INSERTTEXT | SC_MOD_DELETETEXT)) && g_set.auto_check_text) doRecheckSoon();
            break;
        case SCN_UPDATEUI:
            if ((n->updated & (SC_UPDATE_V_SCROLL | SC_UPDATE_H_SCROLL)) && g_set.auto_check_text) doRecheckSoon();
            break;
        case NPPN_SHUTDOWN: saveSettings(); break;
        default: break;
    }
}
extern "C" NPP_EXPORT intptr_t messageProc(uint32_t, uintptr_t, intptr_t) { return 1; }
