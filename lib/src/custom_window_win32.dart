import 'package:ffi/ffi.dart';
import 'package:flutter/widgets.dart';
import 'package:win32/win32.dart';

import 'custom_window.dart';
import 'win32_extra.dart';
import 'package:flutter/src/widgets/_window_win32.dart' hide HWND;

import 'dart:ffi' hide Size;

import 'win32_util.dart';
import 'widgets.dart' show WindowTrafficLightInactiveConfigration;

// Windows 11 is build 22000+. The only version-specific tweak: on Windows 10
// the client rect must keep a 1px non-client strip at the top, otherwise a
// white line shows there; on Windows 11 the top can reach the window edge.
// Everything else (frame inset for native shadow/resize, WM_NCACTIVATE, the
// DwmExtendFrameIntoClientArea shadow margin) is identical on both, matching
// what production libraries like window_manager do.
final bool _isWindows11 = () {
  final osvi = calloc<OSVERSIONINFO>()
    ..ref.dwOSVersionInfoSize = sizeOf<OSVERSIONINFO>();
  try {
    RtlGetVersion(osvi);
    return osvi.ref.dwBuildNumber >= 22000;
  } finally {
    calloc.free(osvi);
  }
}();

class SubclassState {
  bool needRearmMouseTracker = false;
}

final _subclassState = <int, SubclassState>{};

int _subclassProc(
  Pointer hwnd,
  int msg,
  int wparam,
  int lparam,
  int idSubclass,
  int refData,
) {
  final state = _subclassState.putIfAbsent(hwnd.address, () => SubclassState());
  if (msg == WM_DESTROY) {
    _subclassState.remove(hwnd.address);
  }
  if (msg == WM_MOUSELEAVE) {
    HWND parentWindow = GetAncestor(HWND(hwnd), GA_ROOT);
    if (parentWindow.isNotNull) {
      final cursorPos = malloc<POINT>();
      GetCursorPos(cursorPos);
      final cursorPosLparam = makeLParam(cursorPos.ref.x, cursorPos.ref.y);
      free(cursorPos);
      final parentHitTest = SendMessage(
        parentWindow,
        WM_NCHITTEST,
        WPARAM(0),
        LPARAM(cursorPosLparam),
      ).value;
      if (parentHitTest == HTMAXBUTTON || parentHitTest == HTCAPTION) {
        state.needRearmMouseTracker = true;
        return 0;
      }
    }
  } else if (msg == WM_NCHITTEST) {
    // NCHITTEST needs to cooperate with parent (top level) window.
    HWND parentWindow = GetAncestor(HWND(hwnd), GA_ROOT);
    if (parentWindow.isNotNull) {
      final parentResult = SendMessage(
        parentWindow,
        msg,
        WPARAM(wparam),
        LPARAM(lparam),
      ).value;
      if (parentResult == HTCLIENT) {
        return HTCLIENT;
      } else {
        return HTTRANSPARENT;
      }
    } else {
      return HTCLIENT;
    }
  } else if (msg == WM_MOUSEMOVE) {
    if (state.needRearmMouseTracker) {
      final trackMouseEvent = malloc<TRACKMOUSEEVENT>();
      trackMouseEvent.ref.cbSize = sizeOf<TRACKMOUSEEVENT>();
      trackMouseEvent.ref.hwndTrack = HWND(hwnd);
      trackMouseEvent.ref.dwFlags = TME_LEAVE;
      TrackMouseEvent(trackMouseEvent);
      malloc.free(trackMouseEvent);
      state.needRearmMouseTracker = false;
    }
  }
  return DefSubclassProc(HWND(hwnd), msg, WPARAM(wparam), LPARAM(lparam));
}

class CustomWindowWin32 extends CustomWindow {
  CustomWindowWin32(this.controller, {required this.onClose}) {
    controller.addWindowsMessageHandler(handleWindowsMessage);
    _makeWindowUndecorated(_hwnd);
    _flutterView = _findFlutterView();
    SetWindowSubclass(
      _flutterView,
      Pointer.fromFunction<SUBCLASSPROC>(_subclassProc, 0),
      0,
      0,
    );
  }

  final VoidCallback onClose;

  late final HWND _flutterView;

  HWND _findFlutterView() {
    final className = "FlutterView".toNativeUtf16();
    final child = FindWindowEx(_hwnd, null, PCWSTR(className), null);
    free(className);
    if (child.value.isNull) {
      throw Exception('Could not find FlutterView child window');
    }
    return child.value;
  }

  final WindowControllerWin32 controller;

  HWND get _hwnd => HWND(controller.windowHandle);

  static final int Function(Pointer<Void>) _getDpiForWindow =
      DynamicLibrary.process().lookupFunction<
        Uint32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('FlutterDesktopGetDpiForHWND');

  static void _makeWindowUndecorated(HWND hwnd) {
    SetWindowLongPtr(
      hwnd,
      GWL_STYLE,
      WS_THICKFRAME |
          WS_CAPTION |
          WS_SYSMENU |
          WS_MAXIMIZEBOX |
          WS_MINIMIZEBOX |
          WS_OVERLAPPED,
    );
    SetWindowPos(
      hwnd,
      null,
      0,
      0,
      0,
      0,
      SWP_FRAMECHANGED |
          SWP_NOMOVE |
          SWP_NOSIZE |
          SWP_NOZORDER |
          SWP_NOACTIVATE,
    );

    // Restore the native drop shadow. A 1px top margin is enough to re-enable
    // it and stays hidden behind opaque content. A negative ("sheet of
    // glass") margin must NOT be used: it bleeds the glass into the client
    // and causes artifacts. Works on both Windows 10 and 11.
    final margins = malloc<MARGINS>();
    margins.ref.cxLeftWidth = 0;
    margins.ref.cxRightWidth = 0;
    margins.ref.cyTopHeight = 1;
    margins.ref.cyBottomHeight = 0;
    DwmExtendFrameIntoClientArea(hwnd, margins);
    malloc.free(margins);
  }

  final _dragExcludeRects = <BuildContext, Rect>{};
  final _maximizeButtonRects = <BuildContext, Rect>{};

  @override
  void setDragExcludeRectForElement(BuildContext element, Rect? rect) {
    if (rect == null) {
      _dragExcludeRects.remove(element);
    } else {
      _dragExcludeRects[element] = rect;
    }
  }

  @override
  void setDraggableRectForElement(BuildContext element, Rect? rect) {}

  @override
  void setMaximizeButtonFrame(BuildContext element, Rect? rect) {
    if (rect == null) {
      _maximizeButtonRects.remove(element);
    } else {
      _maximizeButtonRects[element] = rect;
    }
  }

  @override
  Size getTrafficLightSize() {
    return Size.zero;
  }

  @override
  void setTrafficLightConfiguration(
    Offset offset,
    Brightness? brightness,
    WindowTrafficLightInactiveConfigration? inactiveConfigration,
  ) {}

  @override
  void requestClose() {
    PostMessage(_hwnd, WM_CLOSE, WPARAM(0), LPARAM(0));
  }

  bool _trackingMouseLeave = false;

  int? handleWindowsMessage(
    HWND windowHandle,
    int message,
    int wParam,
    int lParam,
  ) {
    switch (message) {
      case WM_DESTROY:
        onClose();
        break;
      case WM_ERASEBKGND:
        return 0;
      case WM_SIZE:
        // This would cause Flutter relayout with a very small size.
        if (wParam == SIZE_MINIMIZED) return 0;
        break;
      case WM_NCACTIVATE:
        // Don't let the default handling draw the (legacy) caption over the
        // client area when activation changes. Returning 1 keeps the window
        // looking active without painting a title bar.
        return 1;
      case WM_NCCALCSIZE:
        // Keep a real (but invisible) non-client frame: inset the client by
        // the system frame metrics on left/right/bottom so DWM keeps drawing
        // the native shadow and handles resizing. The title bar is removed by
        // pulling the client to the top edge (Windows 11) or leaving a 1px
        // strip (Windows 10, otherwise a white line shows there). When
        // maximized, inset the top too so the offscreen frame doesn't clip
        // content.
        if (wParam != 1) return 0;
        final dpi = _getDpiForWindow(windowHandle.cast());
        final padding = GetSystemMetricsForDpi(SM_CXPADDEDBORDER, dpi).value;
        final borderLR =
            GetSystemMetricsForDpi(SM_CXFRAME, dpi).value + padding;
        final borderTB =
            GetSystemMetricsForDpi(SM_CYFRAME, dpi).value + padding;
        final rect = Pointer<NCCALCSIZE_PARAMS>.fromAddress(lParam).ref.rgrc[0];
        rect.left += borderLR;
        rect.right -= borderLR;
        rect.bottom -= borderTB;
        if (IsZoomed(_hwnd)) {
          rect.top += borderTB;
        } else {
          rect.top += _isWindows11 ? 0 : 1;
        }
        return 0;
      case WM_NCHITTEST:
        final (xPos, yPos) = splitLParam(lParam);
        final (xClient, yClient) = screenToClient(_hwnd, xPos, yPos);

        double scale = _getDpiForWindow(windowHandle.cast()) / 96.0;
        double x = xClient / scale;
        double y = yClient / scale;

        final rect = malloc<RECT>();
        GetClientRect(_hwnd, rect);
        final width = (rect.ref.right - rect.ref.left) / scale;
        final height = (rect.ref.bottom - rect.ref.top) / scale;
        malloc.free(rect);

        // Sides and bottom keep a real non-client frame (see WM_NCCALCSIZE),
        // so the system resizes them natively; only the top edge lives in the
        // client and needs an in-client grip. No resize when maximized.
        const edgeSize = 1;
        const topEdgeSize = 3;

        if (_maximizeButtonRects.values.any((r) => r.contains(Offset(x, y)))) {
          return HTMAXBUTTON;
        }

        if (!IsZoomed(_hwnd)) {
          if (y < topEdgeSize) {
            if (x < topEdgeSize) {
              return HTTOPLEFT;
            } else if (x > width - topEdgeSize) {
              return HTTOPRIGHT;
            } else {
              return HTTOP;
            }
          } else if (y > height - edgeSize) {
            if (x < edgeSize) {
              return HTBOTTOMLEFT;
            } else if (x > width - edgeSize) {
              return HTBOTTOMRIGHT;
            } else {
              return HTBOTTOM;
            }
          } else if (x < edgeSize) {
            return HTLEFT;
          } else if (x > width - edgeSize) {
            return HTRIGHT;
          }
        }

        for (final excludeRect in _dragExcludeRects.values) {
          if (excludeRect.contains(Offset(x, y))) {
            return HTCLIENT;
          }
        }
        return HTCLIENT;
      case WM_NCMOUSEMOVE:
        if (wParam == HTMAXBUTTON || wParam == HTCAPTION) {
          final (x, y) = splitLParam(lParam);
          final (flutterX, flutterY) = screenToClient(_flutterView, x, y);

          SendMessage(
            _flutterView,
            WM_MOUSEMOVE,
            WPARAM(0),
            LPARAM(makeLParam(flutterX, flutterY)),
          );

          if (!_trackingMouseLeave) {
            final trackMouseEvent = malloc<TRACKMOUSEEVENT>();
            trackMouseEvent.ref.cbSize = sizeOf<TRACKMOUSEEVENT>();
            trackMouseEvent.ref.hwndTrack = _hwnd;
            trackMouseEvent.ref.dwFlags = TME_LEAVE | TME_NONCLIENT;
            TrackMouseEvent(trackMouseEvent);
            malloc.free(trackMouseEvent);
            _trackingMouseLeave = true;
          }
          return 0;
        }
      case WM_NCLBUTTONDOWN:
        if (wParam == HTMAXBUTTON) {
          final (x, y) = splitLParam(lParam);
          final (flutterX, flutterY) = screenToClient(_flutterView, x, y);
          SendMessage(
            _flutterView,
            WM_LBUTTONDOWN,
            WPARAM(0),
            LPARAM(makeLParam(flutterX, flutterY)),
          );
          return 0;
        }
        return null;
      case WM_NCLBUTTONUP:
        if (wParam == HTMAXBUTTON) {
          final (x, y) = splitLParam(lParam);
          final (flutterX, flutterY) = screenToClient(_flutterView, x, y);
          SendMessage(
            _flutterView,
            WM_LBUTTONUP,
            WPARAM(0),
            LPARAM(makeLParam(flutterX, flutterY)),
          );
          return 0;
        }
        return null;
      case WM_NCMOUSELEAVE:
        _trackingMouseLeave = false;
        final cursorPos = malloc<POINT>();
        GetCursorPos(cursorPos);
        final cursorPosLparam = makeLParam(cursorPos.ref.x, cursorPos.ref.y);
        free(cursorPos);
        final flutterHitTest = SendMessage(
          _flutterView,
          WM_NCHITTEST,
          WPARAM(0),
          LPARAM(cursorPosLparam),
        ).value;
        if (flutterHitTest != HTCLIENT) {
          SendMessage(_flutterView, WM_MOUSELEAVE, WPARAM(0), LPARAM(0));
        }
        return 0;
    }
    return null;
  }

  @override
  bool windowNeedsCustomBorder() {
    return false;
  }

  @override
  bool windowNeedsMoveDragDetector() {
    return true;
  }

  @override
  void setCustomBorderShadowWidth(
    double top,
    double left,
    double bottom,
    double right,
  ) {}

  @override
  void startWindowMoveDrag(Offset globalPosition) {
    ReleaseCapture();
    SendMessage(_hwnd, WM_NCLBUTTONDOWN, WPARAM(HTCAPTION), LPARAM(0));
  }

  @override
  void startWindowResizeDrag(Offset globalPosition, WindowEdge edge) {}

  @override
  bool titlebarNeedsDoubleClickDetector() {
    return true;
  }
}
