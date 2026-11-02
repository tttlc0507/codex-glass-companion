#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>


static NSString *ArgumentValue(NSString *prefix) {
    for (NSString *argument in NSProcessInfo.processInfo.arguments)
        if ([argument hasPrefix:prefix]) return [argument substringFromIndex:prefix.length];
    return nil;
}
static NSString *PythonExecutable(void) {
    NSString *override=NSProcessInfo.processInfo.environment[@"COMPANION_PYTHON"];
    if (override.length && [NSFileManager.defaultManager isExecutableFileAtPath:override]) return override;
    for (NSString *path in @[@"/opt/homebrew/bin/python3",@"/usr/local/bin/python3",@"/usr/bin/python3"])
        if ([NSFileManager.defaultManager isExecutableFileAtPath:path]) return path;
    return @"/usr/bin/python3";
}
static NSDictionary *DemoSnapshot(void) {
    NSString *state=ArgumentValue(@"--state=") ?: @"running";
    if (![@[@"running",@"attention",@"completed",@"idle"] containsObject:state]) state=@"running";
    NSString *label=@{@"running":@"任务进行中",@"attention":@"等待你确认",@"completed":@"任务已完成",@"idle":@"当前没有进行中的任务"}[state];
    NSTimeInterval now=NSDate.date.timeIntervalSince1970;
    NSDictionary *task=@{@"id":@"demo-task",@"title":@"打磨桌面小工具",@"status":label,
                         @"detail":@"调整玻璃材质与交互细节",@"completed":@2,@"total":@3};
    BOOL active=[state isEqualToString:@"running"] || [state isEqualToString:@"attention"];
    return @{@"windows":@[@{@"label":@"5 小时",@"remaining":@73,@"resets_at":@(now+10800)},
                           @{@"label":@"本周",@"remaining":@90,@"resets_at":@(now+259200)}],
             @"quota_timestamp":@(now),@"quota_source":@"demo",@"tasks":active?@[task]:@[],
             @"recent":[state isEqualToString:@"completed"]?@[task]:@[],
             @"indicator":@{@"state":state,@"label":label}};
}

@class Companion, Surface;
static NSColor *Ink(void) { return NSColor.labelColor; }
static NSColor *Muted(void) { return NSColor.secondaryLabelColor; }
static NSTextField *Text(NSRect frame, NSString *value, CGFloat size, NSFontWeight weight, NSColor *color) {
    NSTextField *label = [NSTextField labelWithString:value ?: @""];
    label.frame = frame;
    label.font = [NSFont systemFontOfSize:size weight:weight];
    label.textColor = color;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    label.maximumNumberOfLines = 1;
    return label;
}

static NSImage *RoundedMaterialMask(CGFloat radius) {
    CGFloat side=2*radius+1;
    NSImage *image=[NSImage imageWithSize:NSMakeSize(side,side) flipped:NO drawingHandler:^BOOL(NSRect rect) {
        [NSColor.whiteColor setFill];
        [[NSBezierPath bezierPathWithRoundedRect:rect xRadius:radius yRadius:radius] fill];
        return YES;
    }];
    image.capInsets=NSEdgeInsetsMake(radius,radius,radius,radius);
    image.resizingMode=NSImageResizingModeStretch;
    return image;
}

@interface RoundedMaterialView : NSVisualEffectView
@property(nonatomic) CGFloat clipRadius;
@property(nonatomic, strong) CAShapeLayer *contentClip;
- (void)updateRoundedClip;
@end
@implementation RoundedMaterialView
- (instancetype)initWithFrame:(NSRect)frame {
    self=[super initWithFrame:frame];
    if (self) {
        self.wantsLayer=YES;
        self.clipsToBounds=YES;
        self.layer.opaque=NO;
        self.layer.backgroundColor=NSColor.clearColor.CGColor;
        self.layer.masksToBounds=YES;
        self.contentClip=[CAShapeLayer layer];
        self.layer.mask=self.contentClip;
    }
    return self;
}
- (void)setClipRadius:(CGFloat)radius {
    _clipRadius=radius;
    // The material is composited behind the window: a CALayer corner alone
    // cannot clip it. AppKit's material mask also gives the window its shape.
    self.maskImage=RoundedMaterialMask(radius);
    [self updateRoundedClip];
}
- (void)updateRoundedClip {
    if (!self.contentClip) return;
    NSRect bounds=self.bounds;
    CGFloat radius=MIN(self.clipRadius,MIN(bounds.size.width,bounds.size.height)/2);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.layer.cornerRadius=radius;
    self.contentClip.frame=bounds;
    self.contentClip.contentsScale=self.window.backingScaleFactor ?: NSScreen.mainScreen.backingScaleFactor;
    CGPathRef path=CGPathCreateWithRoundedRect(CGRectMake(0,0,bounds.size.width,bounds.size.height),radius,radius,NULL);
    self.contentClip.path=path;
    CGPathRelease(path);
    [CATransaction commit];
    [self.window invalidateShadow];
}
- (void)setFrameSize:(NSSize)size {
    [super setFrameSize:size];
    [self updateRoundedClip];
}
- (void)layout {
    [super layout];
    [self updateRoundedClip];
}
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [self updateRoundedClip];
}
- (void)viewDidChangeBackingProperties {
    [super viewDidChangeBackingProperties];
    [self updateRoundedClip];
}
@end

// Light is scattered from samples around the glass boundary. The smooth fields
// overlap everywhere; there is no angular origin, beam, or seam in the middle.
static NSArray *CreateDiffusionMasks(NSSize size, CGFloat scale) {
    if (size.width<=0 || size.height<=0) return @[];
    scale=MAX(1,scale);
    size_t width=MAX(1,ceil(size.width*scale)),height=MAX(1,ceil(size.height*scale));
    CGContextRef contexts[4]={0};
    unsigned char *alpha[4]; size_t stride[4];
    for (NSInteger k=0;k<4;k++) {
        contexts[k]=CGBitmapContextCreate(NULL,width,height,8,0,NULL,(CGBitmapInfo)kCGImageAlphaOnly);
        if (!contexts[k]) {
            for (NSInteger j=0;j<k;j++) CGContextRelease(contexts[j]);
            return @[];
        }
        alpha[k]=CGBitmapContextGetData(contexts[k]);
        stride[k]=CGBitmapContextGetBytesPerRow(contexts[k]);
    }
    CGFloat radius=size.height/2,halfSegment=MAX(0,(size.width-size.height)/2);
    CGFloat straight=halfSegment*2,arc=M_PI*radius,perimeter=straight*2+arc*2;
    enum { count=64 };
    const CGFloat sigma=12;
    struct { CGPoint point; CGFloat weight[4]; } sources[count];
    for (NSInteger j=0;j<count;j++) {
        CGFloat distance=(j+0.5)*perimeter/count;
        CGPoint point;
        if (distance<straight) point=CGPointMake(radius+distance,size.height);
        else if ((distance-=straight)<arc) {
            CGFloat angle=M_PI_2-distance/radius;
            point=CGPointMake(size.width-radius+radius*cos(angle),radius+radius*sin(angle));
        } else if ((distance-=arc)<straight) point=CGPointMake(size.width-radius-distance,0);
        else {
            distance-=straight;
            CGFloat angle=-M_PI_2-distance/radius;
            point=CGPointMake(radius+radius*cos(angle),radius+radius*sin(angle));
        }
        sources[j].point=point;
        CGFloat phase=2*M_PI*(j+0.5)/count;
        for (NSInteger k=0;k<4;k++) sources[j].weight[k]=pow(MAX(0,cos(phase-k*M_PI_2)),2);
    }
    CGFloat normalization=perimeter/(count*sqrt(2*M_PI)*sigma);
    for (size_t y=0;y<height;y++) for (size_t x=0;x<width;x++) {
        CGFloat px=(x+0.5)/scale,py=(y+0.5)/scale;
        CGFloat depth=radius-hypot(MAX(fabs(px-size.width/2)-halfSegment,0),py-size.height/2);
        CGFloat energy[4]={0};
        if (depth>=0) for (NSInteger j=0;j<count;j++) {
            CGFloat dx=px-sources[j].point.x,dy=py-sources[j].point.y;
            CGFloat scattered=exp(-(dx*dx+dy*dy)/(2*sigma*sigma));
            for (NSInteger k=0;k<4;k++) energy[k]+=scattered*sources[j].weight[k];
        }
        for (NSInteger k=0;k<4;k++) alpha[k][y*stride[k]+x]=(unsigned char)lrint(255*MIN(1,energy[k]*normalization));
    }
    NSMutableArray *images=[NSMutableArray array];
    for (NSInteger k=0;k<4;k++) {
        CGImageRef image=CGBitmapContextCreateImage(contexts[k]);
        if (image) [images addObject:CFBridgingRelease(image)];
        CGContextRelease(contexts[k]);
    }
    return images;
}

@interface StatusLight : NSView
@property(nonatomic, copy) NSString *status;
@property(nonatomic, strong) CALayer *lightLayers;
@property(nonatomic, strong) CAShapeLayer *quietRim;
@property(nonatomic, strong) CAShapeLayer *softRim;
@property(nonatomic, strong) CALayer *highlightClip;
@property(nonatomic, strong) CAShapeLayer *highlightMask;
@property(nonatomic, strong) CAGradientLayer *highlight;
@property(nonatomic, strong) NSArray<CALayer *> *diffusionFields;
@property(nonatomic) NSSize diffusionSize;
@property(nonatomic) CGFloat diffusionScale;
- (void)applyMotionPreference:(BOOL)reduce;
@end

@implementation StatusLight
- (instancetype)initWithFrame:(NSRect)frame {
    self=[super initWithFrame:frame];
    if (self) {
        self.wantsLayer=YES;
        self.layer.opaque=NO;
        self.lightLayers=[CALayer layer];
        self.lightLayers.opacity=0;
        [self.layer addSublayer:self.lightLayers];
        NSMutableArray *fields=[NSMutableArray array];
        for (NSInteger k=0;k<4;k++) {
            CALayer *field=[CALayer layer];
            field.mask=[CALayer layer]; field.opacity=0.12;
            [self.lightLayers addSublayer:field]; [fields addObject:field];
        }
        self.diffusionFields=fields;
        self.quietRim=[CAShapeLayer layer];
        self.quietRim.fillColor=NSColor.clearColor.CGColor;
        self.quietRim.lineWidth=1.0;
        self.softRim=[CAShapeLayer layer];
        self.softRim.fillColor=NSColor.clearColor.CGColor;
        self.softRim.lineWidth=3.4;
        [self.lightLayers addSublayer:self.softRim];
        [self.lightLayers addSublayer:self.quietRim];
        self.highlightClip=[CALayer layer];
        self.highlightMask=[CAShapeLayer layer];
        self.highlightMask.fillColor=NSColor.clearColor.CGColor;
        self.highlightMask.strokeColor=NSColor.whiteColor.CGColor;
        self.highlightMask.lineWidth=1.35;
        self.highlightClip.mask=self.highlightMask;
        self.highlight=[CAGradientLayer layer];
        self.highlight.type=kCAGradientLayerConic;
        self.highlight.startPoint=CGPointMake(0.5,0.5);
        self.highlight.endPoint=CGPointMake(0.5,0);
        self.highlight.locations=@[@0,@0.48,@0.70,@0.81,@0.88,@0.95,@1];
        [self.highlightClip addSublayer:self.highlight];
        [self.lightLayers addSublayer:self.highlightClip];
        [self setAccessibilityElement:NO];
        [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(motionOptionsChanged:)
            name:NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification object:nil];
        self.status=@"idle";
    }
    return self;
}
- (void)dealloc { [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self]; }
- (BOOL)isOpaque { return NO; }
- (NSView *)hitTest:(NSPoint)point { return nil; }
- (void)layout {
    [super layout];
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    CGRect bounds=NSRectToCGRect(self.bounds);
    self.lightLayers.frame=bounds;
    self.quietRim.frame=bounds; self.softRim.frame=bounds;
    self.highlightClip.frame=bounds; self.highlightMask.frame=bounds;
    CGRect edge=CGRectInset(bounds,1.0,1.0);
    CGFloat radius=edge.size.height/2;
    CGPathRef path=CGPathCreateWithRoundedRect(edge,radius,radius,NULL);
    self.quietRim.path=path; self.softRim.path=path; self.highlightMask.path=path;
    CGPathRelease(path);
    CGFloat side=hypot(bounds.size.width,bounds.size.height)+4;
    self.highlight.bounds=CGRectMake(0,0,side,side);
    self.highlight.position=CGPointMake(CGRectGetMidX(bounds),CGRectGetMidY(bounds));
    CGFloat scale=self.window.backingScaleFactor ?: NSScreen.mainScreen.backingScaleFactor;
    if (!NSEqualSizes(self.diffusionSize,self.bounds.size) || self.diffusionScale!=scale) {
        NSArray *masks=CreateDiffusionMasks(self.bounds.size,scale);
        for (NSInteger k=0;k<self.diffusionFields.count;k++) {
            CALayer *field=self.diffusionFields[k];
            field.frame=bounds; field.mask.frame=bounds;
            field.mask.contents=k<masks.count ? masks[k] : nil;
            field.mask.contentsScale=scale;
        }
        self.diffusionSize=self.bounds.size; self.diffusionScale=scale;
    }
    for (CALayer *layer in @[self.quietRim,self.softRim,self.highlightMask,self.highlight]) layer.contentsScale=scale;
    [CATransaction commit];
}
- (void)setStatus:(NSString *)status {
    if ([_status isEqualToString:status]) return;
    _status=[status copy];
    [self updateColor];
    [self motionOptionsChanged:nil];
}
- (void)updateColor {
    [self.effectiveAppearance performAsCurrentDrawingAppearance:^{
        // Fixed signal hues: red FF3B30, yellow FFCC00, green 34C759.
        NSColor *red=[NSColor colorWithSRGBRed:1 green:59/255.0 blue:48/255.0 alpha:1];
        NSColor *yellow=[NSColor colorWithSRGBRed:1 green:204/255.0 blue:0 alpha:1];
        NSColor *green=[NSColor colorWithSRGBRed:52/255.0 green:199/255.0 blue:89/255.0 alpha:1];
        NSColor *color=[self.status isEqualToString:@"attention"] ? yellow :
                       ([self.status isEqualToString:@"completed"] ? green : red);
        BOOL reduce=NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;
        [CATransaction begin];
        [CATransaction setAnimationDuration:reduce ? 0 : 0.45];
        self.lightLayers.opacity=[self.status isEqualToString:@"idle"] ? 0 : 1;
        self.quietRim.strokeColor=[color colorWithAlphaComponent:0.14].CGColor;
        self.softRim.strokeColor=[color colorWithAlphaComponent:0.065].CGColor;
        NSMutableArray *colors=[NSMutableArray array];
        for (NSNumber *alpha in @[@0.02,@0.02,@0.12,@0.32,@0.54,@0.14,@0.02])
            [colors addObject:(id)[color colorWithAlphaComponent:alpha.doubleValue].CGColor];
        self.highlight.colors=colors;
        for (CALayer *field in self.diffusionFields) field.backgroundColor=color.CGColor;
        [CATransaction commit];
    }];
}
- (void)applyMotionPreference:(BOOL)reduce {
    BOOL flowing=[self.status isEqualToString:@"running"] || [self.status isEqualToString:@"attention"];
    if (reduce || !flowing) {
        [self.highlight removeAnimationForKey:@"edgeDrift"];
        for (CALayer *field in self.diffusionFields) [field removeAnimationForKey:@"diffuseDrift"];
        return;
    }
    CFTimeInterval duration=[self.status isEqualToString:@"attention"] ? 12 : 8;
    CABasicAnimation *existing=(CABasicAnimation *)[self.highlight animationForKey:@"edgeDrift"];
    if (existing && existing.duration==duration) return;
    CABasicAnimation *orbit=[CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
    orbit.fromValue=@0; orbit.toValue=@(2*M_PI);
    orbit.duration=duration; orbit.repeatCount=HUGE_VALF;
    orbit.beginTime=CACurrentMediaTime();
    orbit.timingFunction=[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
    [self.highlight addAnimation:orbit forKey:@"edgeDrift"];
    for (NSInteger k=0;k<self.diffusionFields.count;k++) {
        CAKeyframeAnimation *drift=[CAKeyframeAnimation animationWithKeyPath:@"opacity"];
        NSMutableArray *values=[NSMutableArray array],*times=[NSMutableArray array];
        for (NSInteger step=0;step<=16;step++) {
            double progress=step/16.0;
            [values addObject:@(0.05+0.15*pow(0.5+0.5*cos(2*M_PI*progress-k*M_PI_2),1.25))];
            [times addObject:@(progress)];
        }
        drift.values=values; drift.keyTimes=times;
        drift.duration=duration; drift.repeatCount=HUGE_VALF; drift.beginTime=orbit.beginTime;
        drift.calculationMode=kCAAnimationLinear;
        [self.diffusionFields[k] addAnimation:drift forKey:@"diffuseDrift"];
    }
}
- (void)motionOptionsChanged:(NSNotification *)note {
    [self applyMotionPreference:NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion];
}
- (void)viewDidChangeEffectiveAppearance { [super viewDidChangeEffectiveAppearance]; [self updateColor]; }
- (void)viewDidChangeBackingProperties { [super viewDidChangeBackingProperties]; self.needsLayout=YES; }
@end

@interface FloatingPanel : NSPanel
@property(nonatomic, strong) Surface *surface;
@end
@implementation FloatingPanel
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

@interface Surface : NSView
@property(nonatomic, weak) Companion *owner;
@property(nonatomic) BOOL toolbar;
@end

@interface HoverButton : NSButton
@property(nonatomic, weak) Companion *owner;
@property(nonatomic) NSInteger module;
@property(nonatomic) BOOL hovering;
@property(nonatomic, strong) NSTrackingArea *hoverTracking;
@end

@interface OpticalSymbolCell : NSButtonCell
@property(nonatomic) CGFloat opticalOffsetUp;
@property(nonatomic) CGFloat opticalOffsetRight;
@end
@implementation OpticalSymbolCell
- (NSRect)imageRectForBounds:(NSRect)bounds {
    NSRect rect=[super imageRectForBounds:bounds];
    CGFloat vertical=self.controlView.isFlipped ? -self.opticalOffsetUp : self.opticalOffsetUp;
    return NSOffsetRect(rect,self.opticalOffsetRight,vertical);
}
@end

@interface Meter : NSView
@property(nonatomic) double fraction;
@end
@implementation Meter
- (void)drawRect:(NSRect)rect {
    [[NSColor.labelColor colorWithAlphaComponent:0.10] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:3 yRadius:3] fill];
    if (self.fraction > 0) {
        [[Ink() colorWithAlphaComponent:0.78] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(0,0,self.bounds.size.width*self.fraction,self.bounds.size.height) xRadius:3 yRadius:3] fill];
    }
}
@end

@interface TaskCard : NSView
@property(nonatomic, copy) NSString *threadID;
@end
@implementation TaskCard
- (BOOL)isFlipped { return YES; }
- (void)mouseDown:(NSEvent *)event {
    if (self.threadID.length) {
        NSURL *url = [NSURL URLWithString:[@"codex://threads/" stringByAppendingString:self.threadID]];
        [[NSWorkspace sharedWorkspace] openURL:url];
    }
}
@end

@interface Companion : NSObject <NSApplicationDelegate>
@property(nonatomic, strong) FloatingPanel *toolbar;
@property(nonatomic, strong) FloatingPanel *popover;
@property(nonatomic, strong) NSStatusItem *statusItem;
@property(nonatomic, strong) NSTask *bridge;
@property(nonatomic, strong) NSPipe *bridgeInput;
@property(nonatomic, strong) NSPipe *bridgeOutput;
@property(nonatomic, strong) NSMutableData *incoming;
@property(nonatomic, strong) NSDictionary *snapshot;
@property(nonatomic, strong) NSTimer *closeTimer;
@property(nonatomic, strong) NSArray<HoverButton *> *buttons;
@property(nonatomic, strong) StatusLight *statusLight;
@property(nonatomic) BOOL demoMode;
@property(nonatomic, copy) NSString *appearanceMode;
@property(nonatomic) NSInteger module;
@property(nonatomic) BOOL terminating;
- (void)entered:(NSInteger)module;
- (void)leave;
- (void)cancelClose;
- (void)showMenu:(NSEvent *)event view:(NSView *)view;
- (void)savePosition;
- (void)updateIndicator;
- (void)applyAppearanceMode:(NSString *)mode;
@end

@implementation Surface
- (BOOL)isFlipped { return YES; }
- (BOOL)allowsVibrancy { return YES; }
- (void)updateTrackingAreas {
    for (NSTrackingArea *area in self.trackingAreas.copy) [self removeTrackingArea:area];
    [super updateTrackingAreas];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:self.bounds options:NSTrackingMouseEnteredAndExited|NSTrackingActiveAlways|NSTrackingInVisibleRect owner:self userInfo:nil]];
}
- (void)mouseEntered:(NSEvent *)event { [self.owner cancelClose]; }
- (void)mouseExited:(NSEvent *)event { [self.owner leave]; }
- (void)mouseDown:(NSEvent *)event {
    if (self.toolbar) {
        [self.window performWindowDragWithEvent:event];
        [self.owner savePosition];
    }
}
- (void)rightMouseDown:(NSEvent *)event { [self.owner showMenu:event view:self]; }
- (void)drawRect:(NSRect)rect {
    if (!self.toolbar) return;
    // Paint feedback before the light and buttons. The same animated color
    // field then passes through the hovered area, instead of a gray patch
    // covering that field above it.
    BOOL illuminated=self.owner.statusLight && ![self.owner.statusLight.status isEqualToString:@"idle"];
    for (HoverButton *button in self.owner.buttons) if (button.hovering) {
        NSRect bounds=NSInsetRect(button.frame,2,2);
        NSBezierPath *shape=[NSBezierPath bezierPathWithRoundedRect:bounds xRadius:14 yRadius:14];
        if (illuminated) {
            [[NSColor.whiteColor colorWithAlphaComponent:0.09] setFill];
            [shape fill];
            [[NSColor.whiteColor colorWithAlphaComponent:0.17] setStroke];
            shape.lineWidth=0.5;
            [shape stroke];
        } else {
            [NSColor.quaternaryLabelColor setFill];
            [shape fill];
        }
    }
    [NSColor.separatorColor setStroke];
    NSBezierPath *lines = [NSBezierPath bezierPath];
    lines.lineWidth = 0.5;
    for (NSInteger x=40; x<=80; x+=40) {
        [lines moveToPoint:NSMakePoint(x,11)];
        [lines lineToPoint:NSMakePoint(x,29)];
    }
    [lines stroke];
}
@end

@implementation HoverButton
- (void)updateTrackingAreas {
    if (self.hoverTracking) [self removeTrackingArea:self.hoverTracking];
    [super updateTrackingAreas];
    self.hoverTracking = [[NSTrackingArea alloc] initWithRect:self.bounds options:NSTrackingMouseEnteredAndExited|NSTrackingActiveAlways|NSTrackingInVisibleRect owner:self userInfo:nil];
    [self addTrackingArea:self.hoverTracking];
}
- (void)mouseEntered:(NSEvent *)event {
    self.hovering = YES;
    self.owner.toolbar.surface.needsDisplay = YES;
    [self.owner entered:self.module];
}
- (void)mouseExited:(NSEvent *)event {
    self.hovering = NO;
    self.owner.toolbar.surface.needsDisplay = YES;
    [self.owner leave];
}
- (void)mouseDown:(NSEvent *)event {
    NSPoint start = event.locationInWindow;
    while (YES) {
        NSEvent *next = [self.window nextEventMatchingMask:NSEventMaskLeftMouseDragged|NSEventMaskLeftMouseUp];
        if (next.type == NSEventTypeLeftMouseUp) {
            if (NSPointInRect([self convertPoint:next.locationInWindow fromView:nil],self.bounds))
                [self sendAction:self.action to:self.target];
            break;
        }
        if (hypot(next.locationInWindow.x-start.x,next.locationInWindow.y-start.y)>3) {
            [self.owner cancelClose];
            [self.owner.popover orderOut:nil];
            self.owner.module = 0;
            [self.window performWindowDragWithEvent:event];
            [self.owner savePosition];
            break;
        }
    }
}
- (void)rightMouseDown:(NSEvent *)event { [self.owner showMenu:event view:self]; }
@end

@implementation Companion
- (FloatingPanel *)panelWithSize:(NSSize)size radius:(CGFloat)radius {
    FloatingPanel *panel = [[FloatingPanel alloc] initWithContentRect:NSMakeRect(0,0,size.width,size.height)
        styleMask:NSWindowStyleMaskBorderless|NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:NO];
    panel.opaque = NO;
    panel.backgroundColor = NSColor.clearColor;
    panel.hasShadow = YES;
    panel.hidesOnDeactivate = NO;
    panel.level = NSFloatingWindowLevel;
    panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces|NSWindowCollectionBehaviorFullScreenAuxiliary;
    panel.animationBehavior = NSWindowAnimationBehaviorNone;
    panel.releasedWhenClosed = NO;
    Surface *view = [[Surface alloc] initWithFrame:NSMakeRect(0,0,size.width,size.height)];
    view.owner = self;
    panel.surface = view;
    RoundedMaterialView *frost=[[RoundedMaterialView alloc] initWithFrame:view.frame];
    frost.material=NSVisualEffectMaterialPopover;
    frost.blendingMode=NSVisualEffectBlendingModeBehindWindow;
    frost.state=NSVisualEffectStateActive;
    frost.clipRadius=radius;
    panel.contentView=frost;
#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 260000
    if (@available(macOS 26.0,*)) {
        NSGlassEffectView *glass=[[NSGlassEffectView alloc] initWithFrame:view.frame];
        glass.cornerRadius=radius;
        glass.clipsToBounds=YES;
        // The window's frosted material provides the legible backing; clear glass
        // supplies the native optical edge without covering that backing again.
        glass.style=NSGlassEffectViewStyleClear;
        glass.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
        // Content belongs inside the material so AppKit can adapt its legibility.
        glass.contentView=view;
        [frost addSubview:glass];
    } else
#endif
    {
        view.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
        [frost addSubview:view];
    }
    return panel;
}
- (void)applicationDidFinishLaunching:(NSNotification *)note {
    if ([NSRunningApplication runningApplicationsWithBundleIdentifier:NSBundle.mainBundle.bundleIdentifier].count>1) {
        [NSApp terminate:nil];
        return;
    }
    self.incoming = [NSMutableData data];
    [self applyAppearanceMode:[NSUserDefaults.standardUserDefaults stringForKey:@"companionAppearance"] ?: @"system"];
    self.demoMode=[NSProcessInfo.processInfo.arguments containsObject:@"--demo"] ||
        [NSBundle.mainBundle.bundleIdentifier hasSuffix:@".demo"];
    NSString *appearance=ArgumentValue(@"--appearance=");
    if (appearance) [self applyAppearanceMode:appearance];
    if (self.demoMode) self.snapshot=DemoSnapshot();
    self.toolbar = [self panelWithSize:NSMakeSize(120,40) radius:20];
    self.toolbar.title = @"悬浮助手";
    self.toolbar.surface.toolbar = YES;
    NSArray *symbols = @[@"square.and.pencil", @"waveform", @"chevron.down"];
    NSArray *labels = @[@"开始任务", @"悬停查看 5 小时和本周剩余用量", @"悬停查看进行中的任务"];
    NSMutableArray *buttons = [NSMutableArray array];
    for (NSInteger i=0;i<3;i++) {
        HoverButton *button = [[HoverButton alloc] initWithFrame:NSMakeRect(i*40+2,4,36,32)];
        OpticalSymbolCell *cell=[OpticalSymbolCell new];
        if (i==0) { cell.opticalOffsetUp=1.0; cell.opticalOffsetRight=0.20; }
        button.cell=cell;
        button.owner = self;
        button.module = i+1;
        button.bordered = NO;
        button.title = @"";
        button.buttonType = NSButtonTypeMomentaryChange;
        button.imagePosition = NSImageOnly;
        NSImage *image = [NSImage imageWithSystemSymbolName:symbols[i] accessibilityDescription:labels[i]];
        NSFontWeight weight=i==2 ? NSFontWeightLight : NSFontWeightRegular;
        button.image = [image imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:14 weight:weight]];
        button.contentTintColor = NSColor.labelColor;
        button.target = self;
        button.action = @selector(moduleClicked:);
        [button setAccessibilityLabel:labels[i]];
        [self.toolbar.surface addSubview:button];
        [buttons addObject:button];
    }
    self.buttons = buttons;
    self.statusLight=[[StatusLight alloc] initWithFrame:self.toolbar.contentView.bounds];
    self.statusLight.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
    [self.toolbar.surface addSubview:self.statusLight positioned:NSWindowBelow relativeTo:self.buttons.firstObject];
    [self updateIndicator];
    NSScreen *screen = NSScreen.mainScreen;
    NSRect visible = screen.visibleFrame;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSPoint point = NSMakePoint(NSMaxX(visible)-160,NSMinY(visible)+60);
    if ([defaults boolForKey:@"toolbarCompact"]) point=NSMakePoint([defaults doubleForKey:@"toolbarX"],[defaults doubleForKey:@"toolbarY"]);
    BOOL onScreen=NO;
    for (NSScreen *candidate in NSScreen.screens)
        if (NSContainsRect(candidate.visibleFrame,NSMakeRect(point.x,point.y,120,40))) onScreen=YES;
    if (!onScreen) point=NSMakePoint(NSMaxX(visible)-160,NSMinY(visible)+60);
    [self.toolbar setFrameOrigin:point];
    [self.toolbar orderFrontRegardless];
    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.image = [NSImage imageWithSystemSymbolName:@"capsule" accessibilityDescription:@"悬浮助手"];
    self.statusItem.menu = [self menu];
    [self startBridge];
    NSString *panel=ArgumentValue(@"--panel=");
    if (self.demoMode && panel) {
        [self entered:[panel isEqualToString:@"tasks"] ? 3 : 2];
        [self.toolbar orderOut:nil];
    }
}
- (NSMenu *)menu {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"悬浮助手"];
    NSArray *items = @[@[@"显示／隐藏悬浮条",NSStringFromSelector(@selector(toggle:)),@"capsule"],
                      @[@"放回屏幕右下角",NSStringFromSelector(@selector(reposition:)),@"arrow.down.right"],
                      @[@"刷新剩余用量",NSStringFromSelector(@selector(refresh:)),@"arrow.clockwise"]];
    for (NSArray *entry in items) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:entry[0] action:NSSelectorFromString(entry[1]) keyEquivalent:@""];
        item.target = self;
        item.image=[NSImage imageWithSystemSymbolName:entry[2] accessibilityDescription:nil];
        [menu addItem:item];
    }
    NSMenuItem *appearance=[[NSMenuItem alloc] initWithTitle:@"外观" action:NULL keyEquivalent:@""];
    appearance.image=[NSImage imageWithSystemSymbolName:@"circle.lefthalf.filled" accessibilityDescription:nil];
    NSMenu *styles=[[NSMenu alloc] initWithTitle:@"外观"];
    for (NSArray *entry in @[@[@"跟随系统",@"system"],@[@"浅色玻璃",@"light"],@[@"深色玻璃",@"dark"]]) {
        NSMenuItem *style=[[NSMenuItem alloc] initWithTitle:entry[0] action:@selector(chooseAppearance:) keyEquivalent:@""];
        style.target=self; style.representedObject=entry[1];
        style.state=[self.appearanceMode isEqualToString:entry[1]] ? NSControlStateValueOn : NSControlStateValueOff;
        [styles addItem:style];
    }
    appearance.submenu=styles;
    [menu addItem:appearance];
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"退出悬浮助手" action:@selector(quit:) keyEquivalent:@"q"];
    quit.target = self;
    quit.image=[NSImage imageWithSystemSymbolName:@"power" accessibilityDescription:nil];
    [menu addItem:quit];
    return menu;
}
- (void)applyAppearanceMode:(NSString *)mode {
    if (![@[@"system",@"light",@"dark"] containsObject:mode]) mode=@"system";
    self.appearanceMode=mode;
    NSAppearance *appearance=nil;
    if ([mode isEqualToString:@"light"]) appearance=[NSAppearance appearanceNamed:NSAppearanceNameAqua];
    else if ([mode isEqualToString:@"dark"]) appearance=[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    NSApp.appearance=appearance;
    self.toolbar.appearance=appearance;
    self.popover.appearance=appearance;
    self.toolbar.surface.needsDisplay=YES;
    [self.statusLight updateColor];
    if (self.module) [self renderPopover];
}
- (void)chooseAppearance:(NSMenuItem *)sender {
    NSString *mode=sender.representedObject;
    if (![@[@"system",@"light",@"dark"] containsObject:mode]) return;
    [NSUserDefaults.standardUserDefaults setObject:mode forKey:@"companionAppearance"];
    [self applyAppearanceMode:mode];
    // The menu action has finished tracking before the status menu is replaced.
    dispatch_async(dispatch_get_main_queue(), ^{ self.statusItem.menu=[self menu]; });
}
- (void)showMenu:(NSEvent *)event view:(NSView *)view {
    [self.popover orderOut:nil];
    self.module=0;
    [NSMenu popUpContextMenu:[self menu] withEvent:event forView:view];
}
- (void)toggle:(id)sender {
    if (self.toolbar.isVisible) { [self.toolbar orderOut:nil]; [self.popover orderOut:nil]; self.module=0; }
    else [self.toolbar orderFrontRegardless];
}
- (void)reposition:(id)sender {
    NSRect frame=NSScreen.mainScreen.visibleFrame;
    [self.toolbar setFrameOrigin:NSMakePoint(NSMaxX(frame)-160,NSMinY(frame)+60)];
    [self.toolbar orderFrontRegardless];
    [self.popover orderOut:nil];
    self.module=0;
    [self savePosition];
}
- (void)savePosition {
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"toolbarCompact"];
    [NSUserDefaults.standardUserDefaults setDouble:self.toolbar.frame.origin.x forKey:@"toolbarX"];
    [NSUserDefaults.standardUserDefaults setDouble:self.toolbar.frame.origin.y forKey:@"toolbarY"];
}
- (void)refresh:(id)sender {
    if (self.bridge.running) {
        @try { [self.bridgeInput.fileHandleForWriting writeData:[@"refresh\n" dataUsingEncoding:NSUTF8StringEncoding]]; } @catch(NSException *exception) {}
    } else [self startBridge];
}
- (void)quit:(id)sender { [NSApp terminate:nil]; }
- (void)moduleClicked:(HoverButton *)sender {
    if (self.demoMode && sender.module==1) return;
    if (sender.module==1) {
        [self.popover orderOut:nil]; self.module=0;
        [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"codex://threads/new"]];
    } else [self entered:sender.module];
}
- (void)entered:(NSInteger)module {
    [self cancelClose];
    if (module==1) { [self.popover orderOut:nil]; self.module=0; return; }
    if (module==self.module && self.popover.isVisible) return;
    self.module=module;
    [self renderPopover];
}
- (void)cancelClose { [self.closeTimer invalidate]; self.closeTimer=nil; }
- (void)leave {
    if (self.demoMode) return;
    [self cancelClose];
    __weak Companion *weakSelf=self;
    self.closeTimer=[NSTimer scheduledTimerWithTimeInterval:0.22 repeats:NO block:^(NSTimer *timer) {
        Companion *strongSelf=weakSelf;
        NSPoint point=NSEvent.mouseLocation;
        if (!NSPointInRect(point,strongSelf.toolbar.frame) && !NSPointInRect(point,strongSelf.popover.frame)) {
            [strongSelf.popover orderOut:nil]; strongSelf.module=0;
        }
    }];
}
- (void)updateIndicator {
    NSString *state=self.snapshot[@"indicator"][@"state"] ?: @"idle";
    NSString *label=self.snapshot[@"indicator"][@"label"] ?: @"正在读取任务状态";
    if (![@[@"running",@"attention",@"completed"] containsObject:state]) state=@"idle";
    self.statusLight.status=state;
    self.toolbar.surface.needsDisplay=YES;
    [self.buttons.lastObject setAccessibilityValue:label];
    self.buttons.lastObject.toolTip=label;
}
- (NSString *)dateLabel:(NSNumber *)timestamp weekly:(BOOL)weekly {
    if (![timestamp isKindOfClass:NSNumber.class]) return @"重置时间暂不可用";
    NSDateFormatter *formatter=[NSDateFormatter new];
    formatter.timeZone=NSTimeZone.localTimeZone;
    formatter.locale=[NSLocale localeWithLocaleIdentifier:@"zh_CN"];
    formatter.dateFormat=weekly ? @"M月d日 HH:mm" : @"HH:mm";
    return [[formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:timestamp.doubleValue]] stringByAppendingString:@" 重置"];
}
- (void)renderPopover {
    if (!self.module) return;
    BOOL usage=self.module==2;
    NSArray *tasks=self.snapshot[@"tasks"] ?: @[];
    NSArray *recent=self.snapshot[@"recent"] ?: @[];
    CGFloat height=usage ? 236 : (tasks.count ? 78+tasks.count*102 : (recent.count ? 180 : 124));
    if (!self.popover) self.popover=[self panelWithSize:NSMakeSize(360,height) radius:24];
    else {
        [self.popover setContentSize:NSMakeSize(360,height)];
        for (NSView *child in self.popover.surface.subviews.copy) [child removeFromSuperview];
    }
    self.popover.title=usage ? @"剩余用量" : @"任务进度";
    self.popover.level=NSFloatingWindowLevel+1;
    NSView *view=self.popover.surface;
    [view addSubview:Text(NSMakeRect(22,18,230,24),usage?@"剩余用量":@"进行中的任务",15,NSFontWeightMedium,Ink())];
    if (usage) {
        NSArray *windows=self.snapshot[@"windows"] ?: @[@{@"label":@"5 小时"},@{@"label":@"本周"}];
        for (NSInteger i=0;i<2;i++) {
            NSDictionary *window=i<windows.count ? windows[i] : @{};
            CGFloat y=54+i*74;
            [view addSubview:Text(NSMakeRect(22,y,130,23),window[@"label"] ?: (i?@"本周":@"5 小时"),14,NSFontWeightRegular,Ink())];
            id remaining=window[@"remaining"];
            BOOL known=[remaining isKindOfClass:NSNumber.class];
            NSString *value=known ? [NSString stringWithFormat:@"%.0f%% 剩余",[remaining doubleValue]] : (self.snapshot?@"暂不可用":@"读取中…");
            NSTextField *amount=Text(NSMakeRect(158,y,180,23),value,14,NSFontWeightMedium,Ink());
            amount.alignment=NSTextAlignmentRight;
            [view addSubview:amount];
            Meter *meter=[[Meter alloc] initWithFrame:NSMakeRect(22,y+31,316,6)];
            meter.fraction=known ? [remaining doubleValue]/100.0 : 0;
            [meter setAccessibilityElement:YES];
            [meter setAccessibilityLabel:[NSString stringWithFormat:@"%@，%@",window[@"label"] ?: @"用量",value]];
            [view addSubview:meter];
            [view addSubview:Text(NSMakeRect(22,y+45,316,20),[self dateLabel:window[@"resets_at"] weekly:i==1],12,NSFontWeightRegular,Muted())];
        }
        NSNumber *updated=self.snapshot[@"quota_timestamp"];
        NSString *footer=@"正在读取账户用量…";
        if ([updated isKindOfClass:NSNumber.class]) {
            NSDateFormatter *formatter=[NSDateFormatter new]; formatter.dateFormat=@"HH:mm";
            formatter.timeZone=NSTimeZone.localTimeZone;
            NSString *time=[formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:updated.doubleValue]];
            BOOL stale=[NSDate.date timeIntervalSince1970]-updated.doubleValue>120;
            footer=[NSString stringWithFormat:@"%@ %@",stale?@"最近记录":@"更新于",time];
            if ([self.snapshot[@"quota_error"] boolValue]) footer=[footer stringByAppendingString:@" · 刷新暂不可用"];
        } else if (self.snapshot) footer=@"用量暂不可用，稍后自动重试";
        [view addSubview:Text(NSMakeRect(22,208,316,18),footer,11,NSFontWeightRegular,Muted())];
    } else if (tasks.count) {
        CGFloat y=54;
        for (NSDictionary *task in tasks) {
            TaskCard *card=[[TaskCard alloc] initWithFrame:NSMakeRect(12,y,336,92)];
            card.threadID=self.demoMode ? nil : task[@"id"];
            card.wantsLayer=YES;
            card.layer.backgroundColor=[NSColor colorWithRed:0.62 green:0.45 blue:0.72 alpha:0.08].CGColor;
            card.layer.cornerRadius=12;
            [card addSubview:Text(NSMakeRect(16,10,300,23),task[@"title"],15,NSFontWeightMedium,Ink())];
            [card addSubview:Text(NSMakeRect(16,36,300,21),task[@"status"],14,NSFontWeightRegular,Muted())];
            NSString *detail=[task[@"detail"] stringByReplacingOccurrencesOfString:@"\n" withString:@" "] ?: @"";
            detail=[detail stringByReplacingOccurrencesOfString:@"**" withString:@""];
            if (task[@"total"]) detail=[NSString stringWithFormat:@"%@/%@ 步 · %@",task[@"completed"],task[@"total"],detail];
            [card addSubview:Text(NSMakeRect(16,62,300,18),detail,12,NSFontWeightRegular,Muted())];
            [view addSubview:card]; y+=102;
        }
        [view addSubview:Text(NSMakeRect(22,height-27,316,18),@"移开后收起 · 点击任务可打开会话",11,NSFontWeightRegular,Muted())];
    } else {
        NSString *taskError=[self.snapshot[@"task_error"] isKindOfClass:NSString.class] ? self.snapshot[@"task_error"] : nil;
        [view addSubview:Text(NSMakeRect(22,58,316,24),taskError ?: (self.snapshot?@"当前没有进行中的任务":@"正在读取任务…"),14,NSFontWeightRegular,Muted())];
        if (recent.count) {
            NSDictionary *task=recent.firstObject;
            [view addSubview:Text(NSMakeRect(22,101,316,20),@"最近任务",12,NSFontWeightRegular,Muted())];
            TaskCard *card=[[TaskCard alloc] initWithFrame:NSMakeRect(22,127,316,35)]; card.threadID=self.demoMode ? nil : task[@"id"];
            [card addSubview:Text(NSMakeRect(0,0,245,23),task[@"title"],14,NSFontWeightRegular,Ink())];
            NSTextField *status=Text(NSMakeRect(245,0,71,23),task[@"status"],12,NSFontWeightRegular,Muted());
            status.alignment=NSTextAlignmentRight; [card addSubview:status]; [view addSubview:card];
        }
    }
    NSRect toolbar=self.toolbar.frame;
    NSScreen *screen=self.toolbar.screen ?: NSScreen.mainScreen;
    NSRect visible=screen.visibleFrame;
    CGFloat x=MIN(MAX(NSMidX(toolbar)-180,NSMinX(visible)+8),NSMaxX(visible)-368);
    CGFloat y=NSMaxY(toolbar)+12;
    if (y+height>NSMaxY(visible)-8) y=NSMinY(toolbar)-height-12;
    y=MAX(NSMinY(visible)+8,y);
    [self.popover setFrameOrigin:NSMakePoint(x,y)];
    [self.popover orderFrontRegardless];
}
- (void)startBridge {
    if (self.demoMode || self.bridge.running || self.terminating) return;
    NSString *script=[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"companion_backend.py"];
    self.bridge=[NSTask new]; self.bridge.executableURL=[NSURL fileURLWithPath:PythonExecutable()];
    NSMutableDictionary *environment=[NSProcessInfo.processInfo.environment mutableCopy];
    NSURL *host=[NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:@"com.openai.codex"];
    if (host) environment[@"COMPANION_HOST_APP"]=host.path;
    environment[@"COMPANION_APP_VERSION"]=[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"dev";
    self.bridge.environment=environment;
    self.bridge.arguments=@[@"-u",script];
    self.bridge.currentDirectoryURL=[NSURL fileURLWithPath:NSBundle.mainBundle.resourcePath];
    self.bridgeInput=[NSPipe pipe]; self.bridgeOutput=[NSPipe pipe];
    self.bridge.standardInput=self.bridgeInput; self.bridge.standardOutput=self.bridgeOutput;
    self.bridge.standardError=[NSFileHandle fileHandleWithNullDevice];
    __weak Companion *weakSelf=self;
    self.bridgeOutput.fileHandleForReading.readabilityHandler=^(NSFileHandle *handle) {
        NSData *data=handle.availableData;
        if (!data.length) { handle.readabilityHandler=nil; return; }
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf receive:data]; });
    };
    self.bridge.terminationHandler=^(NSTask *task) {
        dispatch_async(dispatch_get_main_queue(), ^{
            Companion *strongSelf=weakSelf;
            if (!strongSelf || strongSelf.terminating) return;
            NSMutableDictionary *unavailable=[strongSelf.snapshot mutableCopy] ?: [NSMutableDictionary dictionary];
            unavailable[@"quota_error"]=@YES; unavailable[@"task_error"]=@"任务连接暂时中断";
            unavailable[@"indicator"]=@{@"state":@"idle",@"label":@"任务连接暂时中断"};
            unavailable[@"tasks"]=@[]; strongSelf.snapshot=unavailable;
            [strongSelf updateIndicator];
            if (strongSelf.module) [strongSelf renderPopover];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC),dispatch_get_main_queue(),^{ [weakSelf startBridge]; });
        });
    };
    NSError *error=nil;
    if (![self.bridge launchAndReturnError:&error]) {
        self.snapshot=@{@"quota_error":@YES,@"task_error":@"无法启动本机数据连接"};
        [self updateIndicator];
    }
}
- (void)receive:(NSData *)data {
    [self.incoming appendData:data];
    NSData *newline=[@"\n" dataUsingEncoding:NSUTF8StringEncoding];
    while (YES) {
        NSRange range=[self.incoming rangeOfData:newline options:0 range:NSMakeRange(0,self.incoming.length)];
        if (range.location==NSNotFound) break;
        NSData *line=[self.incoming subdataWithRange:NSMakeRange(0,range.location)];
        [self.incoming replaceBytesInRange:NSMakeRange(0,range.location+1) withBytes:NULL length:0];
        NSDictionary *packet=[NSJSONSerialization JSONObjectWithData:line options:0 error:NULL];
        if ([packet isKindOfClass:NSDictionary.class] && ![packet isEqualToDictionary:self.snapshot]) {
            self.snapshot=packet;
            [self updateIndicator];
            if (self.module) [self renderPopover];
        }
    }
}
- (void)applicationWillTerminate:(NSNotification *)note {
    self.terminating=YES;
    self.bridge.terminationHandler=nil;
    self.bridgeOutput.fileHandleForReading.readabilityHandler=nil;
    [self.bridgeInput.fileHandleForWriting closeFile];
    if (self.bridge.running) [self.bridge terminate];
}
@end

int main(int argc,const char *argv[]) {
    @autoreleasepool {
        NSApplication *app=NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        Companion *delegate=[Companion new]; app.delegate=delegate;
        [app run];
    }
    return 0;
}
