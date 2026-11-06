// 冥零工作台 · 只读 sqlite
// Windows 10/11 自带 winsqlite3.dll（System32 里就有），接口跟 sqlite3 一样。
// 这样不用往 exe 里塞 1.2MB 的 amalgamation，也不怕没有 sqlite3.dll。
#include "her.h"

#include <cstring>

namespace her {

namespace {

typedef int (*FnOpen)(const char*, void**, int, const char*);
typedef int (*FnPrepare)(void*, const char*, int, void**, const char**);
typedef int (*FnStep)(void*);
typedef long long (*FnColInt64)(void*, int);
typedef const unsigned char* (*FnColText)(void*, int);
typedef int (*FnColCount)(void*);
typedef int (*FnFinalize)(void*);
typedef int (*FnClose)(void*);
typedef const char* (*FnErrmsg)(void*);

struct Api {
    HMODULE dll = nullptr;
    FnOpen open_v2 = nullptr;
    FnPrepare prepare_v2 = nullptr;
    FnStep step = nullptr;
    FnColInt64 col_int64 = nullptr;
    FnColText col_text = nullptr;
    FnColCount col_count = nullptr;
    FnFinalize finalize = nullptr;
    FnClose close_v2 = nullptr;
    FnErrmsg errmsg = nullptr;
    bool Load() {
        if (dll) return open_v2 != nullptr;
        const wchar_t* names[] = {L"winsqlite3.dll", L"sqlite3.dll", L"libsqlite3-0.dll"};
        for (auto* n : names) {
            dll = LoadLibraryW(n);
            if (dll) break;
        }
        if (!dll) return false;
        open_v2 = (FnOpen)GetProcAddress(dll, "sqlite3_open_v2");
        prepare_v2 = (FnPrepare)GetProcAddress(dll, "sqlite3_prepare_v2");
        step = (FnStep)GetProcAddress(dll, "sqlite3_step");
        col_int64 = (FnColInt64)GetProcAddress(dll, "sqlite3_column_int64");
        col_text = (FnColText)GetProcAddress(dll, "sqlite3_column_text");
        col_count = (FnColCount)GetProcAddress(dll, "sqlite3_column_count");
        finalize = (FnFinalize)GetProcAddress(dll, "sqlite3_finalize");
        close_v2 = (FnClose)GetProcAddress(dll, "sqlite3_close_v2");
        errmsg = (FnErrmsg)GetProcAddress(dll, "sqlite3_errmsg");
        return open_v2 && prepare_v2 && step && finalize;
    }
};

Api& A() {
    static Api a;
    static bool tried = false;
    if (!tried) {
        a.Load();
        tried = true;
    }
    return a;
}

const int SQLITE_OK = 0;
const int SQLITE_ROW = 100;
const int SQLITE_OPEN_READONLY = 0x00000001;
const int SQLITE_OPEN_URI = 0x00000040;

}  // namespace

bool Sqlite::OpenRead(const std::wstring& path, std::wstring* err) {
    Close();
    Api& a = A();
    if (!a.open_v2) {
        if (err) *err = L"系统里没有 sqlite3 组件";
        return false;
    }
    std::string utf8 = WToUtf8(path);
    void* db = nullptr;
    int rc = a.open_v2(utf8.c_str(), &db, SQLITE_OPEN_READONLY, nullptr);
    if (rc != SQLITE_OK) {
        if (err) *err = L"打不开 " + path;
        if (db) a.close_v2(db);
        return false;
    }
    this->db = db;
    return true;
}

void Sqlite::Close() {
    if (db && A().close_v2) A().close_v2(db);
    db = nullptr;
}

bool Sqlite::QueryLongs(const std::wstring& sql, std::vector<long long>& out, std::wstring* err) {
    out.clear();
    if (!db) return false;
    Api& a = A();
    std::string s = WToUtf8(sql);
    void* stmt = nullptr;
    if (a.prepare_v2(db, s.c_str(), -1, &stmt, nullptr) != SQLITE_OK) {
        if (err) *err = a.errmsg ? Utf8ToW(a.errmsg(db)) : L"sql 语法不对";
        return false;
    }
    while (a.step(stmt) == SQLITE_ROW) out.push_back(a.col_int64(stmt, 0));
    a.finalize(stmt);
    return true;
}

bool Sqlite::QueryTexts(const std::wstring& sql, std::vector<std::vector<std::wstring>>& rows,
                        std::wstring* err) {
    rows.clear();
    if (!db) return false;
    Api& a = A();
    std::string s = WToUtf8(sql);
    void* stmt = nullptr;
    if (a.prepare_v2(db, s.c_str(), -1, &stmt, nullptr) != SQLITE_OK) {
        if (err) *err = a.errmsg ? Utf8ToW(a.errmsg(db)) : L"sql 语法不对";
        return false;
    }
    int cols = a.col_count ? (int)a.col_count(stmt) : 1;
    int rc = 0;
    while ((rc = a.step(stmt)) == SQLITE_ROW) {
        std::vector<std::wstring> row;
        for (int c = 0; c < cols; c++) {
            const unsigned char* t = a.col_text(stmt, c);
            row.push_back(t ? Utf8ToW(std::string((const char*)t)) : std::wstring());
        }
        rows.push_back(row);
    }
    a.finalize(stmt);
    return true;
}

}  // namespace her
