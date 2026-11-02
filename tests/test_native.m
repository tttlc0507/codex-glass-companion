#define main CompanionUIEntryPoint
#include "../src/CompanionHover.m"
#undef main

static void Require(BOOL passed,NSString *message) {
    if (!passed) { fprintf(stderr,"FAIL: %s\n",message.UTF8String); exit(1); }
}
int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        StatusLight *light=[[StatusLight alloc] initWithFrame:NSMakeRect(0,0,120,40)];
        [light layout];
        NSInteger centerEnergy=0;
        Require(light.diffusionFields.count==4,@"Overlapping light fields cover the capsule");
        for (CALayer *field in light.diffusionFields) {
            CGImageRef mask=(__bridge CGImageRef)field.mask.contents;
            Require(mask!=NULL,@"Diffusion has an alpha mask");
            CFDataRef pixels=CGDataProviderCopyData(CGImageGetDataProvider(mask));
            const UInt8 *values=CFDataGetBytePtr(pixels);
            size_t width=CGImageGetWidth(mask),height=CGImageGetHeight(mask),row=CGImageGetBytesPerRow(mask);
            centerEnergy+=values[(height/2)*row+width/2];
            Require(values[0]==0,@"Each diffuse field preserves transparent corners");
            for (NSInteger y=(NSInteger)height/2-4;y<(NSInteger)height/2+4;y++)
                for (NSInteger x=(NSInteger)width/2-4;x<(NSInteger)width/2+4;x++) {
                    NSInteger v=values[y*row+x];
                    Require(labs(v-values[y*row+x+1])<12 && labs(v-values[(y+1)*row+x])<12,
                        @"The center stays smooth across every direction, without a beam seam");
                }
            CFRelease(pixels);
        }
        Require(centerEnergy>50 && centerEnergy<350,@"Soft, transparent color reaches the middle");
        id cached=light.diffusionFields.firstObject.mask.contents;
        [light layout];
        Require(cached==light.diffusionFields.firstObject.mask.contents,@"Static diffusion masks are cached, not rebuilt during animation");
        Require([light hitTest:NSMakePoint(60,20)]==nil,@"Status light never intercepts a toolbar click or hover");
        Require(!CGPathContainsPoint(light.highlightMask.path,NULL,CGPointMake(1,1),false),@"Highlight follows the capsule corners");
        Require(light.highlightMask.lineWidth<1.5,@"Moving highlight remains a fine optical edge");
        light.status=@"running"; [light applyMotionPreference:NO];
        CABasicAnimation *animation=(id)[light.highlight animationForKey:@"edgeDrift"];
        Require(animation.duration==8,@"Running light drifts slowly");
        for (CALayer *field in light.diffusionFields)
            Require([field animationForKey:@"diffuseDrift"].beginTime==animation.beginTime,@"Inner light and fine edge share the same timing");
        [light applyMotionPreference:YES];
        Require(![light.highlight animationForKey:@"edgeDrift"],@"Reduced motion keeps a static status edge");
        for (CALayer *field in light.diffusionFields)
            Require(![field animationForKey:@"diffuseDrift"],@"Reduced motion also stops the inner diffusion");
        Require(light.lightLayers.opacity==1,@"Reduced motion keeps status visible");
        light.status=@"attention"; [light applyMotionPreference:NO];
        Require([light.highlight animationForKey:@"edgeDrift"].duration==12,@"Confirmation light is calmer");
        light.status=@"completed";
        Require(![light.highlight animationForKey:@"edgeDrift"],@"Completion settles without endless animation");
        light.status=@"idle";
        Require(light.lightLayers.opacity==0,@"Idle returns to the original uncolored material");
        Companion *owner=[Companion new];
        FloatingPanel *popup=[owner panelWithSize:NSMakeSize(360,236) radius:24];
        for (NSView *view in popup.contentView.subviews)
            Require(![view isKindOfClass:StatusLight.class],@"Hover material receives no status light");
        owner.toolbar=[owner panelWithSize:NSMakeSize(120,40) radius:20];
        owner.popover=popup;
        for (NSString *mode in @[@"dark",@"light",@"system"]) {
            [owner applyAppearanceMode:mode];
            NSString *expected=[mode isEqualToString:@"dark"] ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua;
            if ([mode isEqualToString:@"system"])
                Require(!NSApp.appearance && !owner.toolbar.appearance && !popup.appearance,@"Follow-system releases both appearance overrides");
            else {
                Require([NSApp.appearance.name isEqualToString:expected],@"The app selects the requested glass appearance");
                Require([owner.toolbar.appearance.name isEqualToString:expected] && [popup.appearance.name isEqualToString:expected],@"Capsule and popup switch together");
            }
            NSMenu *styles=[[owner menu] itemWithTitle:@"外观"].submenu;
            Require(styles.numberOfItems==3,@"Both glass styles and follow-system remain available");
            NSInteger selected=0;
            for (NSMenuItem *item in styles.itemArray) if (item.state==NSControlStateValueOn) {
                selected++;
                Require([item.representedObject isEqualToString:mode],@"The appearance menu marks the actual selection");
            }
            Require(selected==1,@"Exactly one appearance is selected");
        }
        puts("PASS: capsule edge, pointer passthrough, status transitions, reduced motion, and unchanged popup material.");
    }
    return 0;
}
