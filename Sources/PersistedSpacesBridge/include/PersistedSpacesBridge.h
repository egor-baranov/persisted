#pragma once
#include <ApplicationServices/ApplicationServices.h>
#include <stdbool.h>
#include <stdint.h>

CFArrayRef _Nullable PSDesktopCopyManagedDisplays(void) CF_RETURNS_RETAINED;
CFArrayRef _Nullable PSDesktopCopyWindowSpaces(CGWindowID window) CF_RETURNS_RETAINED;
CGWindowID PSDesktopWindowID(AXUIElementRef _Nonnull element);
bool PSDesktopCanMoveWindows(void);
/// Submits an asynchronous request. Callers must independently verify membership.
bool PSDesktopMoveWindow(CGWindowID window, uint64_t desktop);
bool PSDesktopToggleMissionControl(void);
