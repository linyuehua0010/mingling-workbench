// g++ -std=c++17 -O2 -flto -DUNICODE -D_UNICODE -municode
//     win32/tests/process-launch.cpp win32/src/her/her_probe.cpp -static
//     -o win32/build/process-launch-test.exe
#include "../src/her/her.h"
#include <cstdio>

std::wstring her::Base() { return L"C:\\"; }

int wmain(int argc, wchar_t** argv) {
    const wstring expected = L"F:\\冥零 工作区\\bots\\ollama-models";
    if (argc == 3 && wstring(argv[1]) == L"--child") {
        wchar_t value[1024] = {};
        DWORD length = GetEnvironmentVariableW(L"MINGLING_LAUNCH_TEST", value, 1024);
        FILE* file = _wfopen(argv[2], L"wb");
        if (!file) return 2;
        fwrite(value, sizeof(wchar_t), length, file);
        fclose(file);
        return 0;
    }
    wchar_t temp[MAX_PATH], path[MAX_PATH], self[MAX_PATH];
    GetTempPathW(MAX_PATH, temp);
    GetTempFileNameW(temp, L"mlg", 0, path);
    GetModuleFileNameW(nullptr, self, MAX_PATH);
    EnvList env = {{L"MINGLING_LAUNCH_TEST", expected}};
    DWORD pid = her::LaunchExe(self, L"--child \"" + wstring(path) + L"\"", temp, env, true);
    if (!pid) { DeleteFileW(path); std::puts("FAIL: process did not start"); return 1; }
    HANDLE process = OpenProcess(SYNCHRONIZE, FALSE, pid);
    if (process) { WaitForSingleObject(process, 5000); CloseHandle(process); }
    FILE* file = _wfopen(path, L"rb");
    wchar_t value[1024] = {};
    size_t length = file ? fread(value, sizeof(wchar_t), 1023, file) : 0;
    if (file) fclose(file);
    DeleteFileW(path);
    if (wstring(value, length) != expected) {
        std::puts("FAIL: Unicode environment was not preserved"); return 1;
    }
    std::puts("PASS: child process receives Unicode environment including Chinese path");
    return 0;
}
