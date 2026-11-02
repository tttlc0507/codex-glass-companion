#import <Cocoa/Cocoa.h>

static NSString * const HostID=@"com.openai.codex";
static NSString * const CompanionID=@"local.companion.hover";

static NSArray<NSRunningApplication *> *Running(NSString *bundleID) {
    NSMutableArray *result=[NSMutableArray array];
    for (NSRunningApplication *app in [NSRunningApplication runningApplicationsWithBundleIdentifier:bundleID])
        if (!app.terminated) [result addObject:app];
    return result;
}

@interface CompanionWatch : NSObject
@property(nonatomic, strong) NSURL *companionURL;
@property(nonatomic) BOOL launching;
@property(nonatomic, strong) NSArray *observers;
- (void)start;
- (void)reconcile;
@end

@implementation CompanionWatch
- (BOOL)isInstalledCompanion:(NSRunningApplication *)app {
    return [app.bundleURL.URLByResolvingSymlinksInPath.path isEqualToString:self.companionURL.URLByResolvingSymlinksInPath.path];
}
- (void)start {
    NSNotificationCenter *center=NSWorkspace.sharedWorkspace.notificationCenter;
    __weak CompanionWatch *weakSelf=self;
    NSMutableArray *observers=[NSMutableArray array];
    for (NSNotificationName name in @[NSWorkspaceDidLaunchApplicationNotification,NSWorkspaceDidTerminateApplicationNotification]) {
        id observer=[center addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            NSRunningApplication *app=note.userInfo[NSWorkspaceApplicationKey];
            if ([app.bundleIdentifier isEqualToString:HostID]) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,200*NSEC_PER_MSEC),dispatch_get_main_queue(),^{ [weakSelf reconcile]; });
            }
        }];
        [observers addObject:observer];
    }
    self.observers=observers;
    [self reconcile];
}
- (void)reconcile {
    NSArray *hosts=Running(HostID);
    NSArray *companions=Running(CompanionID);
    if (!hosts.count) {
        for (NSRunningApplication *app in companions)
            if ([self isInstalledCompanion:app]) [app terminate];
        return;
    }
    // A manual Quit stays respected until ChatGPT next launches.
    if (companions.count || self.launching) return;
    if (![NSFileManager.defaultManager fileExistsAtPath:self.companionURL.path]) {
        NSLog(@"Companion is missing at its installed location.");
        return;
    }
    self.launching=YES;
    NSWorkspaceOpenConfiguration *configuration=[NSWorkspaceOpenConfiguration configuration];
    configuration.activates=NO;
    configuration.addsToRecentItems=NO;
    configuration.allowsRunningApplicationSubstitution=NO;
    __weak CompanionWatch *weakSelf=self;
    [NSWorkspace.sharedWorkspace openApplicationAtURL:self.companionURL configuration:configuration completionHandler:^(NSRunningApplication *app,NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            CompanionWatch *strongSelf=weakSelf;
            strongSelf.launching=NO;
            if (error) NSLog(@"Companion launch failed: %@",error.localizedDescription);
            // ChatGPT may have closed while Launch Services was opening the helper.
            if (app && !Running(HostID).count && [strongSelf isInstalledCompanion:app]) [app terminate];
        });
    }];
}
@end

int main(int argc,const char *argv[]) {
    @autoreleasepool {
        NSArray<NSString *> *arguments=NSProcessInfo.processInfo.arguments;
        if (arguments.count<2) return 64;
        NSString *mode=arguments[1];
        if ([mode isEqualToString:@"--status"]) {
            NSMutableArray *companions=[NSMutableArray array];
            for (NSRunningApplication *app in Running(CompanionID))
                [companions addObject:@{@"pid":@(app.processIdentifier),@"path":app.bundleURL.path ?: @""}];
            NSDictionary *result=@{@"chatgpt_running":@(Running(HostID).count>0),@"companions":companions};
            NSData *data=[NSJSONSerialization dataWithJSONObject:result options:0 error:NULL];
            puts([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
            return 0;
        }
        if ([mode isEqualToString:@"--quit-companion"]) {
            for (NSRunningApplication *app in Running(CompanionID)) [app terminate];
            return 0;
        }
        if (![mode isEqualToString:@"--watch"] || arguments.count!=3) return 64;
        NSApplication *app=NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyProhibited];
        CompanionWatch *watch=[[CompanionWatch alloc] init];
        watch.companionURL=[NSURL fileURLWithPath:arguments[2] isDirectory:YES];
        [watch start];
        // Keep the observer owner alive for the entire application run loop.
        __attribute__((objc_precise_lifetime)) CompanionWatch *lifetime=watch;
        [app run];
        (void)lifetime;
    }
    return 0;
}
