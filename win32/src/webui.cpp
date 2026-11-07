// 本地内存资源的 HTML 界面；只有这个源能调到 C++ 这边。
#include "webui.h"
#include "../vendor/webview2/WebView2.h"
#include "webui_uuid.h"
#include <shlwapi.h>
#include <functional>

template<class Interface, class... Args> class Callback final : public Interface {
    ULONG refs = 1;
    std::function<HRESULT(Args...)> fn;
public:
    explicit Callback(std::function<HRESULT(Args...)> f) : fn(std::move(f)) {}
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID id, void** out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        if (IsEqualIID(id, IID_IUnknown) || IsEqualIID(id, __uuidof(Interface))) {
            *out = static_cast<Interface*>(this); AddRef(); return S_OK;
        }
        return E_NOINTERFACE;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return ++refs; }
    ULONG STDMETHODCALLTYPE Release() override { ULONG n = --refs; if (!n) delete this; return n; }
    HRESULT STDMETHODCALLTYPE Invoke(Args... args) override { return fn(args...); }
};
template<class I, class... A, class F> static auto Handler(F fn) {
    return new Callback<I, A...>(fn);
}
static HWND host;
static HMODULE loader;
static ICoreWebView2Environment* environment;
static ICoreWebView2Controller* controller;
static ICoreWebView2* view;
static bool closing = false;
static const wchar_t* origin = L"https://mingling.local/";
static void Fail(HRESULT hr) {
    wchar_t code[32]; swprintf(code, 32, L"0x%08lX", (unsigned long)hr);
    wstring msg = L"内嵌界面没能启动（" + wstring(code) + L"）。\n请安装 Microsoft Edge WebView2 Runtime，并确认 WebView2Loader.dll 与工作台在同一目录。";
    MessageBoxW(host, msg.c_str(), L"冥零 · 界面启动失败", MB_OK | MB_ICONERROR);
}
bool WebUiActive() { return view != nullptr; }
void WebUiResize() {
    if (controller) { RECT rc; GetClientRect(host, &rc); controller->put_Bounds(rc); }
}
void WebUiPublish() {
    if (view && !closing) view->PostWebMessageAsJson(WebUiState().c_str());
}
void WebUiClose() {
    closing = true;
    if (controller) { controller->Close(); controller->Release(); controller = nullptr; }
    if (view) { view->Release(); view = nullptr; }
    if (environment) { environment->Release(); environment = nullptr; }
    // Keep the loader mapped until process exit: asynchronous COM callbacks may still unwind.
}
void WebUiInit(HWND hwnd) {
    host = hwnd;
    loader = LoadLibraryExW(JoinPath(ExeDir(), L"WebView2Loader.dll").c_str(), nullptr, LOAD_WITH_ALTERED_SEARCH_PATH);
    if (!loader) { Fail(HRESULT_FROM_WIN32(GetLastError())); return; }
    using Create = HRESULT(STDAPICALLTYPE*)(PCWSTR, PCWSTR, ICoreWebView2EnvironmentOptions*, ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler*);
    auto create = reinterpret_cast<Create>(GetProcAddress(loader, "CreateCoreWebView2EnvironmentWithOptions"));
    if (!create) { Fail(E_NOINTERFACE); return; }
    auto envHandler = Handler<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler, HRESULT, ICoreWebView2Environment*>(
        [](HRESULT hr, ICoreWebView2Environment* env) -> HRESULT {
            if (closing) return S_OK;
            if (FAILED(hr) || !env) { Fail(hr); return S_OK; }
            environment = env; env->AddRef();
            auto ctlHandler = Handler<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler, HRESULT, ICoreWebView2Controller*>(
                [](HRESULT result, ICoreWebView2Controller* ctl) -> HRESULT {
                    if (closing) return S_OK;
                    if (FAILED(result) || !ctl) { Fail(result); return S_OK; }
                    controller = ctl; ctl->AddRef(); ctl->get_CoreWebView2(&view);
                    ICoreWebView2Settings* settings = nullptr;
                    if (SUCCEEDED(view->get_Settings(&settings))) {
                        settings->put_AreDefaultContextMenusEnabled(FALSE);
                        settings->put_AreDevToolsEnabled(FALSE);
                        settings->put_AreDefaultScriptDialogsEnabled(FALSE);
                        settings->put_IsStatusBarEnabled(FALSE);
                        settings->Release();
                    }
                    EventRegistrationToken token{};
                    auto resource = Handler<ICoreWebView2WebResourceRequestedEventHandler, ICoreWebView2*, ICoreWebView2WebResourceRequestedEventArgs*>(
                        [](ICoreWebView2*, ICoreWebView2WebResourceRequestedEventArgs* args) -> HRESULT {
                            ICoreWebView2WebResourceRequest* request = nullptr;
                            args->get_Request(&request); LPWSTR uri = nullptr; request->get_Uri(&uri); request->Release();
                            wstring url = uri ? uri : L""; CoTaskMemFree(uri);
                            int id = url == origin ? 200 : url == wstring(origin) + L"hero.png" ? 201 : url == wstring(origin) + L"avatar.png" ? 202 : 0;
                            HRSRC res = id ? FindResourceW(GetModuleHandleW(nullptr), MAKEINTRESOURCEW(id), RT_RCDATA) : nullptr;
                            IStream* stream = nullptr;
                            if (res) stream = SHCreateMemStream((const BYTE*)LockResource(LoadResource(GetModuleHandleW(nullptr), res)), SizeofResource(GetModuleHandleW(nullptr), res));
                            ICoreWebView2WebResourceResponse* response = nullptr;
                            environment->CreateWebResourceResponse(stream, res ? 200 : 404, res ? L"OK" : L"Not Found",
                                id == 200 ? L"Content-Type: text/html; charset=utf-8\r\nCache-Control: no-store" : L"Content-Type: image/png\r\nCache-Control: no-store", &response);
                            if (response) { args->put_Response(response); response->Release(); }
                            if (stream) stream->Release();
                            return S_OK;
                        });
                    view->AddWebResourceRequestedFilter(L"*", COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL);
                    view->add_WebResourceRequested(resource, &token); resource->Release();
                    auto navigation = Handler<ICoreWebView2NavigationStartingEventHandler, ICoreWebView2*, ICoreWebView2NavigationStartingEventArgs*>(
                        [](ICoreWebView2*, ICoreWebView2NavigationStartingEventArgs* args) -> HRESULT {
                            LPWSTR uri = nullptr; args->get_Uri(&uri);
                            if (!uri || wstring(uri) != origin) args->put_Cancel(TRUE);
                            CoTaskMemFree(uri); return S_OK;
                        });
                    view->add_NavigationStarting(navigation, &token); navigation->Release();
                    auto popup = Handler<ICoreWebView2NewWindowRequestedEventHandler, ICoreWebView2*, ICoreWebView2NewWindowRequestedEventArgs*>(
                        [](ICoreWebView2*, ICoreWebView2NewWindowRequestedEventArgs* args) -> HRESULT { args->put_Handled(TRUE); return S_OK; });
                    view->add_NewWindowRequested(popup, &token); popup->Release();
                    auto message = Handler<ICoreWebView2WebMessageReceivedEventHandler, ICoreWebView2*, ICoreWebView2WebMessageReceivedEventArgs*>(
                        [](ICoreWebView2*, ICoreWebView2WebMessageReceivedEventArgs* args) -> HRESULT {
                            LPWSTR source = nullptr; args->get_Source(&source);
                            bool trusted = source && wstring(source) == origin; CoTaskMemFree(source);
                            if (!trusted) return S_OK;
                            LPWSTR json = nullptr; args->get_WebMessageAsJson(&json);
                            if (json) { WebUiCommand(json); CoTaskMemFree(json); WebUiPublish(); }
                            return S_OK;
                        });
                    view->add_WebMessageReceived(message, &token); message->Release();
                    WebUiResize(); controller->put_IsVisible(TRUE);
                    view->Navigate(origin);
                    return S_OK;
                });
            HRESULT result = env->CreateCoreWebView2Controller(host, ctlHandler); ctlHandler->Release();
            if (FAILED(result)) Fail(result);
            return S_OK;
        });
    HRESULT hr = create(nullptr, JoinPath(StateDir(), L"webview2").c_str(), nullptr, envHandler);
    envHandler->Release();
    if (FAILED(hr)) Fail(hr);
}
