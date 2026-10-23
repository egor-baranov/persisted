#import "PersistedSpacesBridge.h"
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <string.h>

// Experimental, process-local lookup only. No code injection, task ports, binary
// patching, security changes, or scripting addition is involved. A missing symbol
// disables the corresponding capability. The caller verifies every mutation.
// API references: Hammerspoon extensions/spaces and yabai v7.1.25 space_manager.c.
static const char *skyLightPath = "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight";
static void *skyLight;
static int (*mainConnection)(void);
static CFArrayRef (*copyDisplays)(int);
static CFArrayRef (*copyMembership)(int, int, CFArrayRef);
static AXError (*getWindowID)(AXUIElementRef, CGWindowID *);
static CGError (*dockNotification)(CFStringRef, int);
static void (*performMove)(id);

// Locate one named local symbol in the already loaded SkyLight image. All table
// offsets and strings are bounded by the image's own __LINKEDIT segment, and the
// result must point into an executable segment. Do not scan instructions or guess
// function addresses when Apple removes/changes this symbol.
static void *findLoadedFunction(const char *symbol) {
    for (uint32_t index = 0; index < _dyld_image_count(); ++index) {
        const char *path = _dyld_get_image_name(index);
        if (!path || strcmp(path, skyLightPath) != 0) continue;
        const struct mach_header_64 *header = (const void *)_dyld_get_image_header(index);
        if (!header || header->magic != MH_MAGIC_64 || header->sizeofcmds > 1024 * 1024) return NULL;
        intptr_t slide = _dyld_get_image_vmaddr_slide(index);
        const uint8_t *cursor = (const uint8_t *)(header + 1);
        const uint8_t *end = cursor + header->sizeofcmds;
        const struct symtab_command *table = NULL;
        const struct segment_command_64 *link = NULL;
        for (uint32_t command = 0; command < header->ncmds; ++command) {
            if (cursor + sizeof(struct load_command) > end) return NULL;
            const struct load_command *load = (const void *)cursor;
            if (load->cmdsize < sizeof(*load) || load->cmdsize > (size_t)(end - cursor)) return NULL;
            if (load->cmd == LC_SYMTAB && load->cmdsize >= sizeof(struct symtab_command)) table = (const void *)load;
            if (load->cmd == LC_SEGMENT_64 && load->cmdsize >= sizeof(struct segment_command_64)) {
                const struct segment_command_64 *segment = (const void *)load;
                if (strncmp(segment->segname, SEG_LINKEDIT, 16) == 0) link = segment;
            }
            cursor += load->cmdsize;
        }
        if (!link || !table || table->nsyms > 10000000) return NULL;
        uint64_t linkEnd = link->fileoff + link->filesize;
        if (linkEnd < link->fileoff || table->symoff < link->fileoff || table->stroff < link->fileoff ||
            (uint64_t)table->symoff + (uint64_t)table->nsyms * sizeof(struct nlist_64) > linkEnd ||
            (uint64_t)table->stroff + table->strsize > linkEnd) return NULL;
        uintptr_t base = (uintptr_t)(link->vmaddr + slide - link->fileoff);
        const struct nlist_64 *symbols = (const void *)(base + table->symoff);
        const char *strings = (const void *)(base + table->stroff);
        for (uint32_t entry = 0; entry < table->nsyms; ++entry) {
            uint32_t offset = symbols[entry].n_un.n_strx;
            if (offset >= table->strsize || (symbols[entry].n_type & N_STAB) ||
                (symbols[entry].n_type & N_TYPE) != N_SECT) continue;
            const char *name = strings + offset;
            size_t remaining = table->strsize - offset;
            if (!memchr(name, 0, remaining) || strcmp(name, symbol) != 0) continue;
            uint64_t address = symbols[entry].n_value;
            cursor = (const uint8_t *)(header + 1);
            for (uint32_t command = 0; command < header->ncmds; ++command) {
                const struct load_command *load = (const void *)cursor;
                if (load->cmd == LC_SEGMENT_64 && load->cmdsize >= sizeof(struct segment_command_64)) {
                    const struct segment_command_64 *segment = (const void *)load;
                    if ((segment->initprot & VM_PROT_EXECUTE) && address >= segment->vmaddr &&
                        address - segment->vmaddr < segment->vmsize) return (void *)(address + slide);
                }
                cursor += load->cmdsize;
            }
            return NULL;
        }
    }
    return NULL;
}

static void loadFunctions(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        skyLight = dlopen(skyLightPath, RTLD_LAZY | RTLD_LOCAL);
        if (!skyLight) return;
        mainConnection = dlsym(skyLight, "SLSMainConnectionID");
        copyDisplays = dlsym(skyLight, "SLSCopyManagedDisplaySpaces");
        copyMembership = dlsym(skyLight, "SLSCopySpacesForWindows");
        getWindowID = dlsym(RTLD_DEFAULT, "_AXUIElementGetWindow");
        dockNotification = dlsym(RTLD_DEFAULT, "CoreDockSendNotification");
        // This private ABI is known on Tahoe. Future macOS releases fail closed.
        if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion == 26) {
            performMove = findLoadedFunction("__ZL54SLSPerformAsynchronousBridgedWindowManagementOperationP47SLSAsynchronousBridgedWindowManagementOperation");
        }
    });
}

CFArrayRef PSDesktopCopyManagedDisplays(void) {
    loadFunctions();
    return mainConnection && copyDisplays ? copyDisplays(mainConnection()) : NULL;
}
CFArrayRef PSDesktopCopyWindowSpaces(CGWindowID window) {
    loadFunctions();
    if (!mainConnection || !copyMembership || window == 0) return NULL;
    NSArray *windows = @[@(window)];
    return copyMembership(mainConnection(), 7, (__bridge CFArrayRef)windows);
}
CGWindowID PSDesktopWindowID(AXUIElementRef element) {
    loadFunctions();
    CGWindowID result = 0;
    return getWindowID && getWindowID(element, &result) == kAXErrorSuccess ? result : 0;
}
bool PSDesktopCanMoveWindows(void) {
    loadFunctions();
    Class operation = NSClassFromString(@"SLSBridgedMoveWindowsToManagedSpaceOperation");
    Method initializer = class_getInstanceMethod(operation, sel_registerName("initWithWindows:spaceID:"));
    if (!performMove || !operation || !initializer || method_getNumberOfArguments(initializer) != 4) return false;
    char result[16] = {0}, windows[16] = {0}, desktop[16] = {0};
    method_getReturnType(initializer, result, sizeof(result));
    method_getArgumentType(initializer, 2, windows, sizeof(windows));
    method_getArgumentType(initializer, 3, desktop, sizeof(desktop));
    return result[0] == '@' && windows[0] == '@' && (desktop[0] == 'Q' || desktop[0] == 'L');
}
bool PSDesktopMoveWindow(CGWindowID window, uint64_t desktop) {
    if (!window || !desktop || !AXIsProcessTrusted() || !PSDesktopCanMoveWindows()) return false;
    @try {
        Class cls = NSClassFromString(@"SLSBridgedMoveWindowsToManagedSpaceOperation");
        id operation = ((id (*)(id, SEL, id, uint64_t))objc_msgSend)([cls alloc], sel_registerName("initWithWindows:spaceID:"), @[@(window)], desktop);
        if (!operation) return false;
        performMove(operation);
#if !__has_feature(objc_arc)
        [operation release];
#endif
        return true;
    } @catch (NSException *exception) {
        return false;
    }
}
bool PSDesktopToggleMissionControl(void) {
    loadFunctions();
    return AXIsProcessTrusted() && dockNotification && dockNotification(CFSTR("com.apple.expose.awake"), 0) == kCGErrorSuccess;
}
