#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <OpenGL/OpenGL.h>
#import <OpenGL/gl.h>
#import <OpenGL/glext.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <CoreVideo/CoreVideo.h>
#import <math.h>
#import <mach-o/dyld.h>

@interface NSView (AquariumContext)
- (NSOpenGLContext *)openGLContext;
@end

static Class aquariumClass;
static IMP originalDraw;
static IMP originalFrame;
static IMP originalWallpaper;
static char framePendingKey;
static IMP originalRender, originalReshape, originalLoadBackground, originalFlush;
static _Thread_local BOOL rendering;
static _Thread_local GLint logicalWidth, logicalHeight;
static _Thread_local double renderScale = 1;
static _Thread_local unsigned char *activeScene;
static NSURL *wallpaper(NSWorkspace *, SEL, NSScreen *);

// Preserve the original ripple geometry, but rasterize its light map at a
// useful resolution instead of stretching 128 pixels over the whole desktop.
static _Thread_local GLsizei lightMapSize;
static GLsizei lightResolution(void) {
    int limit=MIN(1024,MIN(lround(logicalWidth*renderScale),lround(logicalHeight*renderScale)));
    int size=128; while(size*2<=limit)size*=2;
    return size;
}

// Scale full-window drawing and the separate legacy ripple-light capture.
static void nativeViewport(GLint x, GLint y, GLsizei width, GLsizei height) {
    if (rendering && width == logicalWidth && height == logicalHeight) {
        x = lround(x*renderScale); y = lround(y*renderScale);
        width = lround(width*renderScale); height = lround(height*renderScale);
    }
    if(rendering && width==128 && height==128 && x==0 && y==0) {
        lightMapSize=lightResolution();width=height=lightMapSize;
    }
    glViewport(x,y,width,height);
}
__attribute__((used)) static struct { const void *replacement, *original; }
viewportInterpose __attribute__((section("__DATA,__interpose"))) = {nativeViewport,glViewport};

static void sharpLightCapture(GLenum target,GLint level,GLenum format,GLint x,GLint y,GLsizei width,GLsizei height,GLint border) {
    if(rendering && target==GL_TEXTURE_2D && width==128 && height==128 && lightMapSize) {
        width=height=lightMapSize;
        static GLsizei loggedSize;
        if(loggedSize!=width){NSLog(@"AquariumCompatibility: ripple-light map %dx%d",width,height);loggedSize=width;}
    }
    glCopyTexImage2D(target,level,format,x,y,width,height,border);
}
__attribute__((used)) static struct {const void *replacement,*original;}
lightCaptureInterpose __attribute__((section("__DATA,__interpose"))) = {sharpLightCapture,glCopyTexImage2D};

// The verified v1.9 fish material draw returns to executable offset 0x7b98.
// Allow its entire mesh across the waterline; restore clipping for bubbles.
static void wholeFishDraw(GLenum mode,GLsizei count,GLenum type,const GLvoid *indices) {
    uintptr_t caller=(uintptr_t)__builtin_return_address(0);
    uintptr_t base=(uintptr_t)_dyld_get_image_header(0);
    BOOL fish=rendering && caller-base==0x7b98;
    GLboolean clipped=fish ? glIsEnabled(GL_SCISSOR_TEST) : GL_FALSE;
    if(clipped) glDisable(GL_SCISSOR_TEST);
    glDrawElements(mode,count,type,indices);
    if(clipped) glEnable(GL_SCISSOR_TEST);
    static BOOL logged;
    if(fish&&!logged){NSLog(@"AquariumCompatibility: complete fish meshes at waterline");logged=YES;}
}
__attribute__((used)) static struct {const void *replacement,*original;}
wholeFishInterpose __attribute__((section("__DATA,__interpose"))) = {wholeFishDraw,glDrawElements};

// The old additive light receiver is a giant 3D quad. Its projected edges
// cross the desktop diagonally. Composite that map per pixel instead.
static _Thread_local BOOL suppressLightReceiver;
static _Thread_local GLfloat receiverColor[4];
static void seamlessBegin(GLenum mode) {
    uintptr_t caller=(uintptr_t)__builtin_return_address(0);
    if(rendering && caller-(uintptr_t)_dyld_get_image_header(0)==0x1505d) {
        glGetFloatv(GL_CURRENT_COLOR,receiverColor);
        glColor4f(0,0,0,0);suppressLightReceiver=YES;
    }
    glBegin(mode);
}
static void seamlessEnd(void) {
    glEnd();
    if(suppressLightReceiver){glColor4fv(receiverColor);suppressLightReceiver=NO;}
}
__attribute__((used)) static struct {const void *replacement,*original;}
receiverBeginInterpose __attribute__((section("__DATA,__interpose"))) = {seamlessBegin,glBegin},
receiverEndInterpose __attribute__((section("__DATA,__interpose"))) = {seamlessEnd,glEnd};

static unsigned char *sceneData(id scene) {
    SEL selector = NSSelectorFromString(@"ssMain");
    return ((void *(*)(id,SEL))objc_msgSend)(scene,selector);
}

// Continuous background refraction avoids the original 12-by-12 mesh.
// Cache a program per GL context; the old app has separate preview/desktop views.
static GLuint rippleProgram(void) {
    static NSMutableDictionary *programs;
    if (!programs) programs=[NSMutableDictionary dictionary];
    NSValue *key=[NSValue valueWithPointer:CGLGetCurrentContext()];
    NSNumber *cached=programs[key];
    if (cached) return cached.unsignedIntValue;
    const GLchar *vertex="#version 120\nvarying vec2 uv; void main(){gl_Position=gl_Vertex;uv=gl_MultiTexCoord0.xy;}";
    const GLchar *fragment=
        "#version 120\n"
        "uniform sampler2D photo,lightMap; uniform float t,level,lighting; varying vec2 uv;"
        "void main(){vec2 p=uv;float d=level-uv.y;"
        "float wet=step(0.0,d);float fade=smoothstep(0.0,0.035,d);"
        "float a=sin(uv.y*67.0+uv.x*18.0+t*1.3);"
        "float b=sin(uv.x*91.0-uv.y*35.0-t*1.7);"
        "p+=wet*fade*vec2(0.0014*a+0.0005*b,0.0007*b);"
        "vec3 c=texture2D(photo,clamp(p,vec2(0.001),vec2(0.999))).rgb;"
        "c*=mix(vec3(1.0),vec3(0.95,0.985,1.0),wet);"
        "c*=1.0+wet*fade*lighting*0.025*a*b;"
        "float caustic=texture2D(lightMap,uv).r;"
        "c+=wet*fade*lighting*0.18*caustic;"
        "gl_FragColor=vec4(c,1.0);}";
    GLuint shaders[2]={glCreateShader(GL_VERTEX_SHADER),glCreateShader(GL_FRAGMENT_SHADER)};
    const GLchar *texts[2]={vertex,fragment};
    GLuint program=glCreateProgram(); BOOL okay=YES;
    for(int i=0;i<2;i++) {
        glShaderSource(shaders[i],1,&texts[i],NULL);glCompileShader(shaders[i]);
        GLint status;glGetShaderiv(shaders[i],GL_COMPILE_STATUS,&status);
        if(!status){char log[2048]={0};glGetShaderInfoLog(shaders[i],sizeof(log),NULL,log);NSLog(@"AquariumCompatibility: ripple shader %s",log);okay=NO;}
        glAttachShader(program,shaders[i]);
    }
    glLinkProgram(program);GLint linked;glGetProgramiv(program,GL_LINK_STATUS,&linked);
    for(int i=0;i<2;i++)glDeleteShader(shaders[i]);
    if(!okay||!linked){glDeleteProgram(program);program=0;}
    programs[key]=@(program);
    NSLog(@"AquariumCompatibility: continuous ripples program=%u",program);
    return program;
}

static void smoothBackground(id scene,unsigned char *data,float level) {
    GLuint texture=*(GLuint *)(data+0xc8);
    if(!texture || !glIsTexture(texture)) return;
    GLuint program=rippleProgram(); if(!program)return;
    GLint oldProgram,oldActive;glGetIntegerv(GL_CURRENT_PROGRAM,&oldProgram);glGetIntegerv(GL_ACTIVE_TEXTURE,&oldActive);
    glPushAttrib(GL_ALL_ATTRIB_BITS);
    glActiveTexture(GL_TEXTURE0);
    GLint oldTexture;glGetIntegerv(GL_TEXTURE_BINDING_2D,&oldTexture);
    glDisable(GL_SCISSOR_TEST);glDisable(GL_DEPTH_TEST);glDepthMask(GL_FALSE);
    glDisable(GL_BLEND);glDisable(GL_LIGHTING);glDisable(GL_CULL_FACE);glDisable(GL_ALPHA_TEST);
    glBindTexture(GL_TEXTURE_2D,texture);glUseProgram(program);
    glActiveTexture(GL_TEXTURE1);
    GLint oldLightTexture;glGetIntegerv(GL_TEXTURE_BINDING_2D,&oldLightTexture);
    glBindTexture(GL_TEXTURE_2D,*(GLuint *)(data+0xcc));
    glActiveTexture(GL_TEXTURE0);
    glUniform1i(glGetUniformLocation(program,"lightMap"),1);
    Ivar ivar=class_getInstanceVariable([scene class],"mySettings");
    unsigned char *settings=(unsigned char *)(__bridge void *)scene+ivar_getOffset(ivar);
    static double start;double now=CFAbsoluteTimeGetCurrent();if(!start)start=now;
    glUniform1i(glGetUniformLocation(program,"photo"),0);
    glUniform1f(glGetUniformLocation(program,"t"),(float)fmod(now-start,3600));
    glUniform1f(glGetUniformLocation(program,"level"),level);
    glUniform1f(glGetUniformLocation(program,"lighting"),settings[0]?1:0);
    glBegin(GL_QUADS);
    glTexCoord2f(0,0);glVertex2f(-1,-1);glTexCoord2f(1,0);glVertex2f(1,-1);
    glTexCoord2f(1,1);glVertex2f(1,1);glTexCoord2f(0,1);glVertex2f(-1,1);
    glEnd();
    glUseProgram(oldProgram);glBindTexture(GL_TEXTURE_2D,oldTexture);
    glActiveTexture(GL_TEXTURE1);glBindTexture(GL_TEXTURE_2D,oldLightTexture);
    glActiveTexture(GL_TEXTURE0);
    glPopAttrib();glActiveTexture(oldActive);
}

static void reshape(id self, SEL selector) {
    ((void(*)(id,SEL))originalReshape)(self,selector);
    if (!rendering) return;
    unsigned char *data = sceneData(self);
    if (!data) return;
    activeScene=data;
    float level = *(float *)(data+0xd0);
    if (!isfinite(level) || level<0 || level>1) return;
    GLint width = lround(logicalWidth*renderScale), height = lround(logicalHeight*renderScale);
    smoothBackground(self,data,level);
    glEnable(GL_SCISSOR_TEST);
    glScissor(0,0,width,(GLsizei)floor(height*level));
}

static void render(id self, SEL selector, NSOpenGLContext *context, NSView *view) {
    rendering = YES;
    activeScene=sceneData(self);
    logicalWidth = lround(view.bounds.size.width); logicalHeight = lround(view.bounds.size.height);
    renderScale = view.window.backingScaleFactor ?: 1;
    glDisable(GL_SCISSOR_TEST);
    ((void(*)(id,SEL,id,id))originalRender)(self,selector,context,view);
    glDisable(GL_SCISSOR_TEST);
    activeScene=NULL; rendering = NO;
}

static void loadBackground(id self, SEL selector, id view) {
    ((void(*)(id,SEL,id))originalLoadBackground)(self,selector,view);
    unsigned char *data = sceneData(self);
    if (!data) return;
    Ivar settingsIvar=class_getInstanceVariable([self class],"mySettings");
    unsigned char *settings=(unsigned char *)(__bridge void *)self+ivar_getOffset(settingsIvar);
    int mode=*(int *)(settings+0x34);
    NSURL *url=nil;
    if (mode==1) url=wallpaper([NSWorkspace sharedWorkspace],@selector(desktopImageURLForScreen:),[view window].screen);
    else if (mode==2) {
        NSString *folder=[NSString stringWithUTF8String:(char *)(settings+0x38)];
        NSArray<NSURL *> *contents=[[NSFileManager defaultManager] contentsOfDirectoryAtURL:[NSURL fileURLWithPath:folder] includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
        NSMutableArray<NSURL *> *images=[NSMutableArray array];
        for (NSURL *candidate in contents)
            if ([@[@"jpg",@"jpeg",@"png",@"gif",@"heic"] containsObject:candidate.pathExtension.lowercaseString]) [images addObject:candidate];
        if (images.count==1) url=images.firstObject;
    }
    if (!url) return; // Preserve the old engine's chosen image for multi-image folders.
    NSImage *image = [[NSImage alloc] initWithContentsOfURL:url];
    CGImageRef cg = [image CGImageForProposedRect:NULL context:nil hints:nil];
    if (!cg) return;
    GLint maxSize=0; glGetIntegerv(GL_MAX_TEXTURE_SIZE,&maxSize);
    double ratio = fmin(1.0, fmin(4096,maxSize)/(double)MAX(CGImageGetWidth(cg),CGImageGetHeight(cg)));
    size_t width=lround(CGImageGetWidth(cg)*ratio),height=lround(CGImageGetHeight(cg)*ratio);
    NSMutableData *pixels=[NSMutableData dataWithLength:width*height*4];
    CGColorSpaceRef colors=CGColorSpaceCreateDeviceRGB();
    CGContextRef bitmap=CGBitmapContextCreate(pixels.mutableBytes,width,height,8,width*4,colors,kCGImageAlphaPremultipliedLast|kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(colors);
    if (!bitmap) return;
    CGContextSetInterpolationQuality(bitmap,kCGInterpolationHigh);
    CGContextTranslateCTM(bitmap,0,height);
    CGContextScaleCTM(bitmap,1,-1);
    CGContextDrawImage(bitmap,CGRectMake(0,0,width,height),cg);
    CGContextRelease(bitmap);
    GLuint texture=*(GLuint *)(data+0xc8);
    glBindTexture(GL_TEXTURE_2D,texture);
    glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA,(GLsizei)width,(GLsizei)height,0,GL_RGBA,GL_UNSIGNED_BYTE,pixels.bytes);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_S,GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_T,GL_CLAMP_TO_EDGE);
    NSLog(@"AquariumCompatibility: full-resolution backdrop %zu x %zu",width,height);
}

static void flush(NSOpenGLContext *self, SEL selector) {
    ((void(*)(id,SEL))originalFlush)(self,selector);
    if (!rendering) return;
    static double last; static int count;
    double now=CFAbsoluteTimeGetCurrent();
    if (!last) last=now;
    ++count;
    if (now-last>=5) {
        GLint viewport[4]={0}; glGetIntegerv(GL_VIEWPORT,viewport);
        NSLog(@"AquariumCompatibility: fps=%.1f viewport=%dx%d scale=%.1f",count/(now-last),viewport[2],viewport[3],renderScale);
        if(activeScene) NSLog(@"AquariumCompatibility: fill=%.3f target=%.3f",*(float *)(activeScene+0xd0),*(float *)(activeScene+0xd4));
        count=0; last=now;
    }
}

static CVReturn frame(NSView *self, SEL selector, const CVTimeStamp *timestamp) {
    if ([NSThread isMainThread])
        return ((CVReturn(*)(id,SEL,const CVTimeStamp *))originalFrame)(self,selector,timestamp);
    @synchronized(self) {
        if (objc_getAssociatedObject(self,&framePendingKey)) return kCVReturnSuccess;
        objc_setAssociatedObject(self,&framePendingKey,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    CVTimeStamp copy = timestamp ? *timestamp : (CVTimeStamp){0};
    dispatch_async(dispatch_get_main_queue(), ^{
        ((CVReturn(*)(id,SEL,const CVTimeStamp *))originalFrame)(self,selector,&copy);
        @synchronized(self) { objc_setAssociatedObject(self,&framePendingKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
    });
    return kCVReturnSuccess;
}

static NSURL *wallpaper(NSWorkspace *self, SEL selector, NSScreen *screen) {
    NSURL *url = ((id(*)(id,SEL,id))originalWallpaper)(self,selector,screen);
    if (url && [@[@"jpg",@"jpeg",@"png",@"gif"] containsObject:url.pathExtension.lowercaseString]
        && [[NSFileManager defaultManager] isReadableFileAtPath:url.path]) return url;
    if (url) {
        NSImage *image = [[NSImage alloc] initWithContentsOfURL:url];
        NSBitmapImageRep *rep = image ? [NSBitmapImageRep imageRepWithData:image.TIFFRepresentation] : nil;
        NSData *jpeg = [rep representationUsingType:NSBitmapImageFileTypeJPEG properties:@{NSImageCompressionFactor:@0.95}];
        if (jpeg) {
            NSURL *cache = [[[NSFileManager defaultManager] URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask] firstObject];
            [[NSFileManager defaultManager] createDirectoryAtURL:cache withIntermediateDirectories:YES attributes:nil error:nil];
            NSURL *out = [cache URLByAppendingPathComponent:[NSString stringWithFormat:@"aquarium-wallpaper-%@.jpg",screen.deviceDescription[@"NSScreenNumber"] ?: @0]];
            if ([jpeg writeToURL:out atomically:YES]) return out;
        }
    }
    return [[NSBundle mainBundle] URLForResource:@"AquariumBackground" withExtension:@"jpg"] ?: url;
}
static void repairSurface(NSView *view) {
    if (!view.window) return;
    NSOpenGLContext *context = [view openGLContext];
    if (!context) return;
    CGLContextObj cgl = context.CGLContextObj;
    CGLLockContext(cgl);
    [view setWantsBestResolutionOpenGLSurface:YES];
    if (context.view != view) [context setView:view];
    [context update];
    CGLUnlockContext(cgl);
}

static void moved(NSView *self, SEL selector) {
    struct objc_super parent = { self, class_getSuperclass(aquariumClass) };
    ((void(*)(struct objc_super *,SEL))objc_msgSendSuper)(&parent,selector);
    repairSurface(self);
    dispatch_async(dispatch_get_main_queue(), ^{ repairSurface(self); });
    NSLog(@"AquariumCompatibility: view moved to %@",self.window);
}

static void layerChanged(NSView *self, SEL selector, CALayer *layer) {
    struct objc_super parent = { self, class_getSuperclass(aquariumClass) };
    ((void(*)(struct objc_super *,SEL,id))objc_msgSendSuper)(&parent,selector,layer);
    NSOpenGLContext *context = [self openGLContext];
    if (context) {
        CGLLockContext(context.CGLContextObj);
        [context update];
        CGLUnlockContext(context.CGLContextObj);
    }
}

static void draw(NSView *self, SEL selector) {
    ((void(*)(id,SEL))originalDraw)(self,selector);
    static int frames;
    if (++frames == 120) {
        NSOpenGLContext *ctx = [self openGLContext];
        CGLLockContext(ctx.CGLContextObj);
        [ctx makeCurrentContext];
        NSLog(@"AquariumCompatibility: rendered frame, view=%@ renderer=%s error=%x",ctx.view,glGetString(GL_RENDERER),glGetError());
        CGLUnlockContext(ctx.CGLContextObj);
    }
}

__attribute__((constructor)) static void installCompatibility(void) {
    @autoreleasepool {
        aquariumClass = NSClassFromString(@"MyOpenGLView");
        if (!aquariumClass) { NSLog(@"AquariumCompatibility: class missing"); return; }
        class_addMethod(aquariumClass,@selector(viewDidMoveToWindow),(IMP)moved,"v@:");
        class_addMethod(aquariumClass,@selector(setLayer:),(IMP)layerChanged,"v@:@");
        Method method = class_getInstanceMethod(aquariumClass,NSSelectorFromString(@"drawView"));
        originalDraw = method_setImplementation(method,(IMP)draw);
        Method callback = class_getInstanceMethod(aquariumClass,NSSelectorFromString(@"getFrameForTime:"));
        originalFrame = method_setImplementation(callback,(IMP)frame);
        Method background = class_getInstanceMethod([NSWorkspace class],@selector(desktopImageURLForScreen:));
        originalWallpaper = method_setImplementation(background,(IMP)wallpaper);
        Class scene=NSClassFromString(@"Scene");
        originalRender=method_setImplementation(class_getInstanceMethod(scene,NSSelectorFromString(@"render:glView:")),(IMP)render);
        originalReshape=method_setImplementation(class_getInstanceMethod(scene,NSSelectorFromString(@"glReshape")),(IMP)reshape);
        originalLoadBackground=method_setImplementation(class_getInstanceMethod(scene,NSSelectorFromString(@"loadBGImage:")),(IMP)loadBackground);
        originalFlush=method_setImplementation(class_getInstanceMethod([NSOpenGLContext class],@selector(flushBuffer)),(IMP)flush);
        NSLog(@"AquariumCompatibility: installed surface lifecycle repair");
    }
}
