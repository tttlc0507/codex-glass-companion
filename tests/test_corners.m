#define main CompanionUIEntryPoint
#include "../src/CompanionHover.m"
#undef main

static void Require(BOOL passed,NSString *message) {
    if (!passed) { fprintf(stderr,"FAIL: %s\n",message.UTF8String); exit(1); }
}

int main(int argc,const char *argv[]) {
    @autoreleasepool {
        if (argc>1) {
            NSBitmapImageRep *image=[NSBitmapImageRep imageRepWithData:[NSData dataWithContentsOfFile:@(argv[1])]];
            Require(image!=nil,@"Screenshot can be decoded");
            NSInteger width=image.pixelsWide,height=image.pixelsHigh;
            printf("screenshot %ldx%ld alpha=%d\n",(long)width,(long)height,image.hasAlpha);
            for (NSInteger i=0;i<4;i++) {
                NSInteger x=(i&1)?width-1:0,y=(i&2)?height-1:0;
                NSColor *color=[[image colorAtX:x y:y] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
                printf("corner %ld rgba %.4f %.4f %.4f %.4f\n",(long)i,color.redComponent,color.greenComponent,color.blueComponent,color.alphaComponent);
            }
            return 0;
        }
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        RoundedMaterialView *view=[[RoundedMaterialView alloc] initWithFrame:NSMakeRect(0,0,360,236)];
        view.clipRadius=24;
        Require(view.maskImage!=nil,@"Material compositor has its own alpha mask");
        NSBitmapImageRep *materialMask=[NSBitmapImageRep imageRepWithData:view.maskImage.TIFFRepresentation];
        Require(materialMask.hasAlpha,@"Material mask preserves a transparent alpha channel");
        for (NSInteger i=0;i<4;i++) {
            NSInteger x=(i&1)?materialMask.pixelsWide-2:1;
            NSInteger y=(i&2)?materialMask.pixelsHigh-2:1;
            Require([materialMask colorAtX:x y:y].alphaComponent<0.01,@"All four native material corners are transparent");
        }
        Require([materialMask colorAtX:materialMask.pixelsWide/2 y:materialMask.pixelsHigh/2].alphaComponent>0.99,@"Material mask keeps the center opaque");
        NSEdgeInsets caps=view.maskImage.capInsets;
        Require(caps.top==24 && caps.bottom==24 && caps.left==24 && caps.right==24,@"Mask retains all four corner radii when stretched");
        for (NSNumber *height in @[@236,@124,@180,@486,@236]) {
            [view setFrameSize:NSMakeSize(360,height.doubleValue)];
            CGPathRef path=view.contentClip.path;
            CGRect bounds=CGPathGetBoundingBox(path);
            Require(bounds.size.width==360 && bounds.size.height==height.doubleValue,@"Content clip updates immediately after resizing");
            CGFloat width=360,h=height.doubleValue;
            for (NSInteger i=0;i<4;i++) {
                CGPoint outside=CGPointMake((i&1)?width-1:1,(i&2)?h-1:1);
                CGPoint inside=CGPointMake((i&1)?width-24:24,(i&2)?h-24:24);
                Require(!CGPathContainsPoint(path,NULL,outside,false),@"Each outer corner is transparent");
                Require(CGPathContainsPoint(path,NULL,inside,false),@"Material inside the rounded corner remains visible");
            }
        }
        puts("PASS: material alpha mask, four corner caps, and clip geometry at five resize transitions.");
    }
    return 0;
}
