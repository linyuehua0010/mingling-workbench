// From the repository root (MinGW g++ on PATH):
// g++ -std=c++17 -O2 -flto -DUNICODE -D_UNICODE win32/tests/resource-root.cpp
//     win32/src/her/her_config.cpp -static -o win32/build/resource-root-test.exe
// LTO discards unrelated configuration functions and their dependencies.
#include "../src/her/her.h"
#include <cstdio>
#include <set>

static wstring exe, workspace, base;
static std::set<wstring> directories;
wstring ExeDir() { return exe; }
wstring WorkspaceDir() { return workspace; }
wstring BaseDir() { return base; }
wstring JoinPath(const wstring& a, const wstring& b) { return a + L"\\" + b; }
bool DirExists(const wstring& path) { return directories.count(path) != 0; }

int main() {
    workspace = L"F:\\robot";
    base = L"F:\\legacy";
    struct Case {
        const char* name;
        const wchar_t* exe;
        std::set<wstring> dirs;
        const wchar_t* expected;
    };
    const Case cases[] = {
        {"installed resources beside exe", L"C:\\Apps\\MinglingWorkbench",
         {L"C:\\Apps\\MinglingWorkbench\\tools", L"F:\\robot\\tools"}, L"C:\\Apps\\MinglingWorkbench"},
        {"development bin", L"F:\\source\\bin", {L"F:\\source\\tools"}, L"F:\\source"},
        {"development build", L"F:\\source\\win32\\build", {L"F:\\source\\tools"}, L"F:\\source"},
        {"old snapshot uses configured workspace", L"C:\\Apps\\MinglingWorkbench-snapshot",
         {L"F:\\robot\\tools"}, L"F:\\robot"},
        {"legacy robot root", L"C:\\Apps\\MinglingWorkbench", {L"F:\\legacy\\tools"}, L"F:\\legacy"},
        {"missing resources reports installation path", L"C:\\Apps\\MinglingWorkbench", {}, L"C:\\Apps\\MinglingWorkbench"},
        {"unrelated parent tools ignored", L"C:\\Apps\\MinglingWorkbench",
         {L"C:\\Apps\\tools"}, L"C:\\Apps\\MinglingWorkbench"},
    };
    for (const auto& c : cases) {
        exe = c.exe;
        directories = c.dirs;
        if (her::Root() != c.expected) {
            std::printf("FAIL: %s\n", c.name);
            return 1;
        }
        std::printf("PASS: %s\n", c.name);
    }
}
