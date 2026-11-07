# Microsoft WebView2 SDK

Pinned SDK: **1.0.2903.40**, x64 Loader.

Source: [official Microsoft NuGet package](https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/1.0.2903.40/microsoft.web.webview2.1.0.2903.40.nupkg).

Files are copied unchanged from `build/native/include/WebView2.h` and `build/native/x64/WebView2Loader.dll`. `LICENSE.txt` and `NOTICE.txt` are from the same package.

Loader SHA-256: `462B36FD1BE6CA9F7563466A89E57C41EF4A4DEF3E0A84FA885D203AEA4A3AAF`.

The loader locates the Microsoft Edge WebView2 Runtime installed on the user's machine. The Runtime itself is not included here. See [Microsoft's Win32 guide](https://learn.microsoft.com/en-us/microsoft-edge/webview2/get-started/win32).
