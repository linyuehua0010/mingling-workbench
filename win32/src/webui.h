#pragma once
#include "core.h"
void WebUiInit(HWND hwnd);
void WebUiResize();
void WebUiPublish();
void WebUiClose();
bool WebUiActive();
wstring WebUiState();
void WebUiCommand(const wstring& message);
