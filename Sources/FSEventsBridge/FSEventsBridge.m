#import "FSEventsBridge.h"
#import <CoreServices/CoreServices.h>

static void TLCallback(ConstFSEventStreamRef stream,
                       void *info,
                       size_t n,
                       void *eventPaths,
                       const FSEventStreamEventFlags *flags,
                       const FSEventStreamEventId *ids) {
    (void)stream; (void)n; (void)flags; (void)ids;
    TLFSEventHandler handler = (__bridge TLFSEventHandler)info;
    if (!handler) return;
    // Deliberately NOT parsing eventPaths: its shape has killed this app
    // twice (bridge trap, then a wild pointer into CFGetTypeID). The
    // consumer re-checks every source with microsecond short-circuits
    // (file signatures + byte offsets), so "something changed" is the
    // complete signal — contents would add nothing but risk.
    (void)eventPaths;
    handler(@[]);
}

void *TLWatcherStart(NSArray<NSString *> *paths, double latency, TLFSEventHandler handler) {
    if (!handler || paths.count == 0) return NULL;
    FSEventStreamContext ctx;
    memset(&ctx, 0, sizeof(ctx));
    ctx.info = (__bridge void *)handler;
    ctx.retain = (CFAllocatorRetainCallBack)_Block_copy;
    ctx.release = (CFAllocatorReleaseCallBack)_Block_release;
    FSEventStreamRef s = FSEventStreamCreate(NULL, TLCallback, &ctx,
                                             (__bridge CFArrayRef)paths,
                                             kFSEventStreamEventIdSinceNow,
                                             (CFAbsoluteTime)latency,
                                             kFSEventStreamCreateFlagFileEvents);
    if (!s) return NULL;
    FSEventStreamSetDispatchQueue(s, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    FSEventStreamStart(s);
    return (void *)s;
}

void TLWatcherStop(void *watcher) {
    if (!watcher) return;
    FSEventStreamRef s = (FSEventStreamRef)watcher;
    FSEventStreamStop(s);
    FSEventStreamInvalidate(s);
    FSEventStreamRelease(s);
}
