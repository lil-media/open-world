#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <AppKit/AppKit.h>

// Simple C API for Metal rendering from Zig
typedef struct {
    void* device;
    void* queue;
    void* layer;
} MetalContext;

MetalContext* metal_create_context(void* sdl_metal_view) {
    MetalContext* ctx = malloc(sizeof(MetalContext));

    // Get default device
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
        free(ctx);
        return NULL;
    }

    // Create command queue
    id<MTLCommandQueue> queue = [device newCommandQueue];
    if (!queue) {
        free(ctx);
        return NULL;
    }

    // Get the CAMetalLayer from SDL's metal view
    // SDL returns an NSView, we need to get its layer
    NSView* view = (__bridge NSView*)sdl_metal_view;
    CAMetalLayer* layer = (CAMetalLayer*)[view layer];
    if (!layer) {
        free(ctx);
        return NULL;
    }
    layer.device = device;
    layer.pixelFormat = MTLPixelFormatBGRA8Unorm;

    ctx->device = (__bridge_retained void*)device;
    ctx->queue = (__bridge_retained void*)queue;
    ctx->layer = (__bridge_retained void*)layer;

    return ctx;
}

void metal_destroy_context(MetalContext* ctx) {
    if (ctx) {
        if (ctx->device) CFRelease(ctx->device);
        if (ctx->queue) CFRelease(ctx->queue);
        if (ctx->layer) CFRelease(ctx->layer);
        free(ctx);
    }
}

bool metal_render_frame(MetalContext* ctx, float r, float g, float b) {
    if (!ctx) return false;

    CAMetalLayer* layer = (__bridge CAMetalLayer*)ctx->layer;
    id<MTLCommandQueue> queue = (__bridge id<MTLCommandQueue>)ctx->queue;

    // Get next drawable
    id<CAMetalDrawable> drawable = [layer nextDrawable];
    if (!drawable) return false;

    // Create command buffer
    id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
    if (!commandBuffer) return false;

    // Create render pass descriptor
    MTLRenderPassDescriptor* passDescriptor = [MTLRenderPassDescriptor renderPassDescriptor];
    passDescriptor.colorAttachments[0].texture = drawable.texture;
    passDescriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
    passDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
    passDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(r, g, b, 1.0);

    // Create render encoder (just clear for now)
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:passDescriptor];
    [encoder endEncoding];

    // Present and commit
    [commandBuffer presentDrawable:drawable];
    [commandBuffer commit];

    return true;
}

const char* metal_get_device_name(MetalContext* ctx) {
    if (!ctx) return "Unknown";
    id<MTLDevice> device = (__bridge id<MTLDevice>)ctx->device;
    return [[device name] UTF8String];
}
