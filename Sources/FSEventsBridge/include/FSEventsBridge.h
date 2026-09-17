#import <Foundation/Foundation.h>

/// File-event watcher. The C callback lives here (not Swift) because the
/// Swift compiler's region analysis crashes on the @convention(c) function
/// conversion, and every Swift-side pointer cast tried so far has trapped
/// on at least one real macOS delivery shape.
typedef void (^TLFSEventHandler)(NSArray<NSString *> *paths);

/// Starts watching. Handler runs on a utility queue with the changed paths
/// (may be empty for the initial history-done marker). Returns NULL on failure.
void *TLWatcherStart(NSArray<NSString *> *paths, double latency, TLFSEventHandler handler);

/// Stops a watcher from TLWatcherStart. Safe with NULL.
void TLWatcherStop(void *watcher);
