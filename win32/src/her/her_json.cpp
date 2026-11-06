// 冥零工作台 · 小 JSON（astrbot 的配置都是 json，为了不拖进第三方库自己写一个）
#include "her.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>

namespace her {

namespace {

struct Parser {
    const std::wstring& s;
    size_t i = 0;
    bool err = false;

    explicit Parser(const std::wstring& text) : s(text) {}

    void Ws() {
        while (i < s.size()) {
            wchar_t c = s[i];
            if (c == L' ' || c == L'\t' || c == L'\r' || c == L'\n' || c == 0xFEFF)
                i++;
            else
                break;
        }
    }
    bool Eat(wchar_t c) {
        Ws();
        if (i < s.size() && s[i] == c) {
            i++;
            return true;
        }
        return false;
    }
    J Value() {
        Ws();
        if (i >= s.size()) return Fail();
        wchar_t c = s[i];
        if (c == L'{') return Obj();
        if (c == L'[') return Arr();
        if (c == L'"') return Str();
        if (c == L't' && s.compare(i, 4, L"true") == 0) {
            i += 4;
            return J(true);
        }
        if (c == L'f' && s.compare(i, 5, L"false") == 0) {
            i += 5;
            return J(false);
        }
        if (c == L'n' && s.compare(i, 4, L"null") == 0) {
            i += 4;
            return J();
        }
        return Num();
    }
    J Fail() {
        err = true;
        return J();
    }
    J Obj() {
        J o;
        o.t = J::OBJ;
        i++;  // {
        Ws();
        if (i < s.size() && s[i] == L'}') {
            i++;
            return o;
        }
        while (i < s.size()) {
            Ws();
            if (i >= s.size() || s[i] != L'"') return Fail();
            std::wstring k = StrRaw();
            if (err) return J();
            if (!Eat(L':')) return Fail();
            J v = Value();
            if (err) return J();
            bool dup = false;
            for (auto& kv : o.o)
                if (kv.first == k) {
                    kv.second = v;
                    dup = true;
                    break;
                }
            if (!dup) o.o.push_back({k, v});
            if (Eat(L',')) continue;
            if (Eat(L'}')) break;
            return Fail();
        }
        return o;
    }
    J Arr() {
        J a;
        a.t = J::ARR;
        i++;  // [
        Ws();
        if (i < s.size() && s[i] == L']') {
            i++;
            return a;
        }
        while (i < s.size()) {
            J v = Value();
            if (err) return J();
            a.a.push_back(v);
            if (Eat(L',')) continue;
            if (Eat(L']')) break;
            return Fail();
        }
        return a;
    }
    std::wstring StrRaw() {
        std::wstring out;
        i++;  // "
        while (i < s.size()) {
            wchar_t c = s[i++];
            if (c == L'"') return out;
            if (c != L'\\') {
                out.push_back(c);
                continue;
            }
            if (i >= s.size()) break;
            wchar_t e = s[i++];
            switch (e) {
                case L'"': out.push_back(L'"'); break;
                case L'\\': out.push_back(L'\\'); break;
                case L'/': out.push_back(L'/'); break;
                case L'b': out.push_back(L'\b'); break;
                case L'f': out.push_back(L'\f'); break;
                case L'n': out.push_back(L'\n'); break;
                case L'r': out.push_back(L'\r'); break;
                case L't': out.push_back(L'\t'); break;
                case L'u': {
                    unsigned v = 0;
                    for (int k = 0; k < 4 && i < s.size(); k++) {
                        wchar_t h = s[i++];
                        v <<= 4;
                        if (h >= L'0' && h <= L'9') v |= (unsigned)(h - L'0');
                        else if (h >= L'a' && h <= L'f') v |= (unsigned)(h - L'a' + 10);
                        else if (h >= L'A' && h <= L'F') v |= (unsigned)(h - L'A' + 10);
                    }
                    if (v >= 0xD800 && v <= 0xDBFF && i + 5 < s.size() && s[i] == L'\\' && s[i + 1] == L'u') {
                        unsigned lo = 0;
                        size_t save = i;
                        i += 2;
                        for (int k = 0; k < 4 && i < s.size(); k++) {
                            wchar_t h = s[i++];
                            lo <<= 4;
                            if (h >= L'0' && h <= L'9') lo |= (unsigned)(h - L'0');
                            else if (h >= L'a' && h <= L'f') lo |= (unsigned)(h - L'a' + 10);
                            else if (h >= L'A' && h <= L'F') lo |= (unsigned)(h - L'A' + 10);
                        }
                        if (lo >= 0xDC00 && lo <= 0xDFFF) {
                            unsigned cp = 0x10000 + ((v - 0xD800) << 10) + (lo - 0xDC00);
                            out.push_back((wchar_t)(0xD800 + ((cp - 0x10000) >> 10)));
                            out.push_back((wchar_t)(0xDC00 + ((cp - 0x10000) & 0x3FF)));
                        } else {
                            i = save;
                            out.push_back((wchar_t)v);
                        }
                    } else {
                        out.push_back((wchar_t)v);
                    }
                    break;
                }
                default: out.push_back(e); break;
            }
        }
        err = true;
        return out;
    }
    J Str() {
        std::wstring v = StrRaw();
        J j;
        j.t = J::STR;
        j.s = v;
        return j;
    }
    J Num() {
        Ws();
        size_t a = i;
        if (i < s.size() && (s[i] == L'-' || s[i] == L'+')) i++;
        bool any = false;
        while (i < s.size() && ((s[i] >= L'0' && s[i] <= L'9') || s[i] == L'.' || s[i] == L'e' || s[i] == L'E' ||
                                s[i] == L'+' || s[i] == L'-')) {
            any = true;
            i++;
        }
        if (!any) return Fail();
        std::wstring t = s.substr(a, i - a);
        J j;
        j.t = J::NUM;
        j.num = _wtof(t.c_str());
        return j;
    }
};

void DumpStr(const std::wstring& v, std::wstring& out) {
    out.push_back(L'"');
    for (size_t i = 0; i < v.size(); i++) {
        wchar_t c = v[i];
        switch (c) {
            case L'"': out += L"\\\""; break;
            case L'\\': out += L"\\\\"; break;
            case L'\n': out += L"\\n"; break;
            case L'\r': out += L"\\r"; break;
            case L'\t': out += L"\\t"; break;
            case L'\b': out += L"\\b"; break;
            case L'\f': out += L"\\f"; break;
            default:
                if (c < 0x20)
                    out += L"\\u00" + std::wstring(1, (wchar_t)(L'0' + ((c >> 4) & 0xF))) +
                           std::wstring(1, (wchar_t)((c & 0xF) < 10 ? L'0' + (c & 0xF) : L'a' + (c & 0xF) - 10));
                else
                    out.push_back(c);
        }
    }
    out.push_back(L'"');
}

void DumpVal(const J& v, int indent, int level, std::wstring& out) {
    auto nl = [&](int lv) {
        if (indent <= 0) return;
        out.push_back(L'\n');
        for (int k = 0; k < lv * indent; k++) out.push_back(L' ');
    };
    switch (v.t) {
        case J::NUL: out += L"null"; break;
        case J::BOOL: out += v.b ? L"true" : L"false"; break;
        case J::NUM: out += v.NumText(); break;
        case J::STR: DumpStr(v.s, out); break;
        case J::ARR: {
            if (v.a.empty()) {
                out += L"[]";
                break;
            }
            out.push_back(L'[');
            for (size_t i = 0; i < v.a.size(); i++) {
                if (i) out.push_back(L',');
                if (indent > 0) nl(level + 1);
                DumpVal(v.a[i], indent, level + 1, out);
            }
            if (indent > 0) nl(level);
            out.push_back(L']');
            break;
        }
        case J::OBJ: {
            if (v.o.empty()) {
                out += L"{}";
                break;
            }
            out.push_back(L'{');
            for (size_t i = 0; i < v.o.size(); i++) {
                if (i) out.push_back(L',');
                if (indent > 0) nl(level + 1);
                DumpStr(v.o[i].first, out);
                out.push_back(L':');
                if (indent > 0) out.push_back(L' ');
                DumpVal(v.o[i].second, indent, level + 1, out);
            }
            if (indent > 0) nl(level);
            out.push_back(L'}');
            break;
        }
    }
}

}  // namespace

J JObj() {
    J j;
    j.t = J::OBJ;
    return j;
}
J JArr() {
    J j;
    j.t = J::ARR;
    return j;
}
J JStr(const std::wstring& v) { return J(v); }
J JNum(double v) { return J(v); }
J JBool(bool v) { return J(v); }

J J::Parse(const std::wstring& text, bool* ok) {
    Parser p(text);
    J v = p.Value();
    p.Ws();
    bool good = !p.err;
    if (ok) *ok = good;
    if (!good) v = J();
    return v;
}

std::wstring J::NumText() const {
    if (t != NUM) return s;
    double d = num;
    if (d == (double)(long long)d && std::fabs(d) < 1e15) return std::to_wstring((long long)d);
    wchar_t buf[64];
    swprintf(buf, 64, L"%.10g", d);
    return buf;
    return std::wstring();
}

std::wstring J::Dump(int indent) const {
    std::wstring out;
    DumpVal(*this, indent, 0, out);
    return out;
}

const J* J::Get(const std::wstring& key) const {
    if (t != OBJ) return nullptr;
    for (auto& kv : o)
        if (kv.first == key) return &kv.second;
    return nullptr;
}

J* J::GetM(const std::wstring& key) {
    if (t != OBJ) return nullptr;
    for (auto& kv : o)
        if (kv.first == key) return &kv.second;
    return nullptr;
}

bool J::Has(const std::wstring& key) const { return Get(key) != nullptr; }

void J::Set(const std::wstring& key, const J& v) {
    if (t != OBJ) {
        t = OBJ;
        o.clear();
    }
    for (auto& kv : o)
        if (kv.first == key) {
            kv.second = v;
            return;
        }
    o.push_back({key, v});
}

std::wstring J::Str(const std::wstring& key, const std::wstring& def) const {
    const J* v = Get(key);
    if (!v) return def;
    if (v->t == STR) return v->s;
    if (v->t == NUM) return v->NumText();
    if (v->t == BOOL) return v->b ? L"true" : L"false";
    return def;
}

bool J::Bool(const std::wstring& key, bool def) const {
    const J* v = Get(key);
    if (!v) return def;
    if (v->t == BOOL) return v->b;
    if (v->t == NUM) return v->num != 0;
    if (v->t == STR) return v->s == L"true" || v->s == L"1";
    return def;
}

double J::Num(const std::wstring& key, double def) const {
    const J* v = Get(key);
    if (!v) return def;
    if (v->t == NUM) return v->num;
    if (v->t == STR) return _wtof(v->s.c_str());
    if (v->t == BOOL) return v->b ? 1 : 0;
    return def;
}

long long J::Int(const std::wstring& key, long long def) const {
    const J* v = Get(key);
    if (!v) return def;
    if (v->t == NUM) return (long long)v->num;
    if (v->t == STR) return _wtoi64(v->s.c_str());
    return def;
}

const J* J::Path(const std::wstring& dot) const {
    const J* cur = this;
    size_t a = 0;
    while (a <= dot.size()) {
        size_t b = dot.find(L'.', a);
        if (b == std::wstring::npos) b = dot.size();
        std::wstring key = dot.substr(a, b - a);
        if (!cur || cur->t != OBJ) return nullptr;
        cur = cur->Get(key);
        if (!cur) return nullptr;
        if (b == dot.size()) break;
        a = b + 1;
    }
    return cur;
}

bool J::PathSet(const std::wstring& dot, const J& v) {
    if (t != OBJ) return false;
    J* cur = this;
    size_t a = 0;
    while (a <= dot.size()) {
        size_t b = dot.find(L'.', a);
        if (b == std::wstring::npos) b = dot.size();
        std::wstring key = dot.substr(a, b - a);
        if (b == dot.size()) {
            cur->Set(key, v);
            return true;
        }
        J* next = cur->GetM(key);
        if (!next) {
            J o = JObj();
            cur->Set(key, o);
            next = cur->GetM(key);
        }
        if (next->t != OBJ) next->t = J::OBJ;
        cur = next;
        a = b + 1;
    }
    return true;
}

}  // namespace her
