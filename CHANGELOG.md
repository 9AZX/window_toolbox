## 0.0.8

* Win32: pass the dragged `WindowEdge` to delegates via `windowWillResizeToSizeWithEdge`.
* Win32: clamp delegate-modified sizes in `WM_SIZING` to the window min / max
  tracking size to prevent the window from drifting when the system re-applies
  size constraints anchored at top-left.
* Win32: add `dpiScale` getter on `WindowControllerWin32`.

## 0.0.1

* TODO: Describe initial release.
