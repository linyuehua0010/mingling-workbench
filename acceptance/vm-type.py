import ctypes
import sys
import time

if len(sys.argv) < 3:
    raise SystemExit("usage: vm-type.py <text-file> <vm-hwnd> [--paste]")
text = open(sys.argv[1], encoding="utf-8").read().rstrip("\r\n")
vm = int(sys.argv[2])
paste_only = len(sys.argv) > 3 and sys.argv[3] == "--paste"
u = ctypes.windll.user32
k = ctypes.windll.kernel32
for _hwnd in (20648192, 134534):
    u.ShowWindow(_hwnd, 0)
k.GlobalAlloc.argtypes = [ctypes.c_uint, ctypes.c_size_t]
k.GlobalAlloc.restype = ctypes.c_void_p
k.GlobalLock.argtypes = [ctypes.c_void_p]
k.GlobalLock.restype = ctypes.c_void_p
k.GlobalUnlock.argtypes = [ctypes.c_void_p]
u.SetClipboardData.argtypes = [ctypes.c_uint, ctypes.c_void_p]
u.SetClipboardData.restype = ctypes.c_void_p

u.OpenClipboard(0)
u.EmptyClipboard()
size = (len(text) + 1) * 2
h = k.GlobalAlloc(0x42, size)
p = k.GlobalLock(h)
ctypes.memmove(p, ctypes.create_unicode_buffer(text), size)
k.GlobalUnlock(h)
u.SetClipboardData(13, h)
u.CloseClipboard()

u.ShowWindow(vm, 9)
u.SwitchToThisWindow(vm, True)
time.sleep(0.8)
x, y = (250, 200) if paste_only else (1100, 400)
u.SetCursorPos(x, y)
u.mouse_event(2, 0, 0, 0, 0)
u.mouse_event(4, 0, 0, 0, 0)
time.sleep(0.5)
u.keybd_event(0x11, 0, 0, 0)
u.keybd_event(0x47, 0, 0, 0)
u.keybd_event(0x47, 0, 2, 0)
u.keybd_event(0x11, 0, 2, 0)
time.sleep(0.8)
if not paste_only:
    u.keybd_event(0x5B, 0, 0, 0)
    u.keybd_event(0x52, 0, 0, 0)
    u.keybd_event(0x52, 0, 2, 0)
    u.keybd_event(0x5B, 0, 2, 0)
    time.sleep(1.2)
u.keybd_event(0x11, 0, 0, 0)
u.keybd_event(0x56, 0, 0, 0)
u.keybd_event(0x56, 0, 2, 0)
u.keybd_event(0x11, 0, 2, 0)
time.sleep(0.5)
u.keybd_event(0x0D, 0, 0, 0)
u.keybd_event(0x0D, 0, 2, 0)
time.sleep(0.3)
u.keybd_event(0x0D, 0, 0, 0)
u.keybd_event(0x0D, 0, 2, 0)
time.sleep(1.0)
print("sent")
