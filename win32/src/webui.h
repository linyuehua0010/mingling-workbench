#pragma once
#include "core.h"
void WebUiInit(HWND hwnd);
void WebUiResize();
void WebUiPublish();
void WebUiClose();
bool WebUiActive();
bool WebUiFallback();
void WebUiPaintLoading(HDC dc, int width, int height);
wstring WebUiState();
void WebUiCommand(const wstring& message);
