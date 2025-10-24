#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <string.h>
#import <stdint.h>
#import <CoreGraphics/CoreGraphics.h>
#include <stdlib.h>

// Simple C API for Metal rendering from Zig
typedef enum {
    RenderModeNormal = 0,
    RenderModeWireframe = 1,
} RenderMode;

typedef struct {
    void* device;
    void* queue;
    void* layer;
    void* library;
    void* pipeline;
    void* vertex_buffer;
    void* index_buffer;
    void* uniform_buffer;
    void* depth_state;
    void* texture;
    void* sampler;
    void* line_buffer;
    void* ui_pipeline;
    void* ui_vertex_buffer;
    size_t vertex_stride;
    size_t index_count;
    size_t uniform_size;
    size_t line_vertex_count;
    size_t ui_vertex_count;
    size_t ui_vertex_stride;
    RenderMode render_mode;
    char* capture_path;
    size_t capture_path_len;
    bool capture_pending;
} MetalContext;

MetalContext* metal_create_context(void* sdl_metal_view) {
    MetalContext* ctx = malloc(sizeof(MetalContext));
    if (!ctx) {
        return NULL;
    }

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
    ctx->library = NULL;
    ctx->pipeline = NULL;
    ctx->vertex_buffer = NULL;
    ctx->index_buffer = NULL;
    ctx->uniform_buffer = NULL;
    ctx->depth_state = NULL;
    ctx->texture = NULL;
    ctx->sampler = NULL;
    ctx->line_buffer = NULL;
    ctx->ui_pipeline = NULL;
    ctx->ui_vertex_buffer = NULL;
    ctx->vertex_stride = 0;
    ctx->index_count = 0;
    ctx->uniform_size = 0;
    ctx->line_vertex_count = 0;
    ctx->ui_vertex_count = 0;
    ctx->ui_vertex_stride = 0;
    ctx->render_mode = RenderModeNormal;
    ctx->capture_path = NULL;
    ctx->capture_path_len = 0;
    ctx->capture_pending = false;

    return ctx;
}

void metal_destroy_context(MetalContext* ctx) {
    if (ctx) {
        if (ctx->uniform_buffer) CFRelease(ctx->uniform_buffer);
        if (ctx->index_buffer) CFRelease(ctx->index_buffer);
        if (ctx->vertex_buffer) CFRelease(ctx->vertex_buffer);
        if (ctx->line_buffer) CFRelease(ctx->line_buffer);
        if (ctx->ui_vertex_buffer) CFRelease(ctx->ui_vertex_buffer);
        if (ctx->pipeline) CFRelease(ctx->pipeline);
        if (ctx->ui_pipeline) CFRelease(ctx->ui_pipeline);
        if (ctx->library) CFRelease(ctx->library);
        if (ctx->depth_state) CFRelease(ctx->depth_state);
        if (ctx->texture) CFRelease(ctx->texture);
        if (ctx->sampler) CFRelease(ctx->sampler);
        if (ctx->device) CFRelease(ctx->device);
        if (ctx->queue) CFRelease(ctx->queue);
        if (ctx->layer) CFRelease(ctx->layer);
        if (ctx->capture_path) free(ctx->capture_path);
        free(ctx);
    }
}

static void metal_release_and_assign(void** target, void* new_value) {
    if (*target) {
        CFRelease(*target);
    }
    *target = new_value;
}

static bool metal_save_texture_png(id<MTLTexture> texture, NSString* path) {
    if (!texture || !path) return false;

    @autoreleasepool {
        const NSUInteger width = texture.width;
        const NSUInteger height = texture.height;
        const NSUInteger bytesPerRow = width * 4;
        const size_t dataSize = bytesPerRow * height;
        uint8_t* data = malloc(dataSize);
        if (!data) {
            return false;
        }

        MTLRegion region = MTLRegionMake2D(0, 0, width, height);
        [texture getBytes:data bytesPerRow:bytesPerRow fromRegion:region mipmapLevel:0];

        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
        if (!colorSpace) {
            free(data);
            return false;
        }

        CGContextRef context = CGBitmapContextCreate(
            data,
            width,
            height,
            8,
            bytesPerRow,
            colorSpace,
            kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);

        CGColorSpaceRelease(colorSpace);

        if (!context) {
            free(data);
            return false;
        }

        CGImageRef image = CGBitmapContextCreateImage(context);
        CGContextRelease(context);
        free(data);

        if (!image) {
            return false;
        }

        NSBitmapImageRep* rep = [[NSBitmapImageRep alloc] initWithCGImage:image];
        CGImageRelease(image);
        if (!rep) {
            return false;
        }

        NSData* pngData = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        if (!pngData) {
            return false;
        }

        return [pngData writeToFile:path atomically:YES];
    }
}

bool metal_create_pipeline(MetalContext* ctx, const char* source, size_t source_length, const char* vertex_name, size_t vertex_length, const char* fragment_name, size_t fragment_length, size_t vertex_stride) {
    if (!ctx || !source || source_length == 0 || !vertex_name || vertex_length == 0 || !fragment_name || fragment_length == 0) {
        return false;
    }

    id<MTLDevice> device = (__bridge id<MTLDevice>)ctx->device;
    if (!device) return false;

    NSString* sourceString = [[NSString alloc] initWithBytes:source length:source_length encoding:NSUTF8StringEncoding];
    if (!sourceString) return false;

    NSError* error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:sourceString options:nil error:&error];
    if (!library) {
        NSLog(@"Metal shader compilation failed: %@", error);
        return false;
    }

    NSString* vertexString = [[NSString alloc] initWithBytes:vertex_name length:vertex_length encoding:NSUTF8StringEncoding];
    NSString* fragmentString = [[NSString alloc] initWithBytes:fragment_name length:fragment_length encoding:NSUTF8StringEncoding];
    if (!vertexString || !fragmentString) {
        return false;
    }

    id<MTLFunction> vertexFunction = [library newFunctionWithName:vertexString];
    id<MTLFunction> fragmentFunction = [library newFunctionWithName:fragmentString];
    if (!vertexFunction || !fragmentFunction) {
        NSLog(@"Failed to find shader entry points. vertex=%p, fragment=%p", vertexFunction, fragmentFunction);
        return false;
    }
    // Shaders loaded successfully

    MTLRenderPipelineDescriptor* descriptor = [[MTLRenderPipelineDescriptor alloc] init];
    descriptor.vertexFunction = vertexFunction;
    descriptor.fragmentFunction = fragmentFunction;
    descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    descriptor.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;

    MTLVertexDescriptor* vertexDescriptor = [[MTLVertexDescriptor alloc] init];
    vertexDescriptor.attributes[0].format = MTLVertexFormatFloat3;
    vertexDescriptor.attributes[0].offset = 0;
    vertexDescriptor.attributes[0].bufferIndex = 0;

    vertexDescriptor.attributes[1].format = MTLVertexFormatFloat3;
    vertexDescriptor.attributes[1].offset = sizeof(float) * 3;
    vertexDescriptor.attributes[1].bufferIndex = 0;

    vertexDescriptor.attributes[2].format = MTLVertexFormatFloat2;
    vertexDescriptor.attributes[2].offset = sizeof(float) * 6;
    vertexDescriptor.attributes[2].bufferIndex = 0;

    vertexDescriptor.attributes[3].format = MTLVertexFormatFloat4;
    vertexDescriptor.attributes[3].offset = sizeof(float) * 8;
    vertexDescriptor.attributes[3].bufferIndex = 0;

    vertexDescriptor.layouts[0].stride = vertex_stride;
    vertexDescriptor.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;
    descriptor.vertexDescriptor = vertexDescriptor;
    descriptor.inputPrimitiveTopology = MTLPrimitiveTopologyClassTriangle;
    descriptor.colorAttachments[0].blendingEnabled = YES;
    descriptor.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
    descriptor.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
    descriptor.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
    descriptor.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    descriptor.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
    descriptor.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;

    NSError* pipelineError = nil;
    id<MTLRenderPipelineState> pipeline = [device newRenderPipelineStateWithDescriptor:descriptor error:&pipelineError];
    if (!pipeline) {
        NSLog(@"Failed to create pipeline state: %@", pipelineError);
        return false;
    }

    MTLDepthStencilDescriptor* depthDescriptor = [[MTLDepthStencilDescriptor alloc] init];
    depthDescriptor.depthCompareFunction = MTLCompareFunctionLess;
    depthDescriptor.depthWriteEnabled = YES;
    id<MTLDepthStencilState> depthState = [device newDepthStencilStateWithDescriptor:depthDescriptor];
    if (!depthState) {
        NSLog(@"Failed to create depth stencil state");
        return false;
    }

    metal_release_and_assign(&ctx->library, (__bridge_retained void*)library);
    metal_release_and_assign(&ctx->pipeline, (__bridge_retained void*)pipeline);
    metal_release_and_assign(&ctx->depth_state, (__bridge_retained void*)depthState);
    ctx->vertex_stride = vertex_stride;

    return true;
}

bool metal_create_ui_pipeline(MetalContext* ctx, const char* vertex_name, size_t vertex_length, const char* fragment_name, size_t fragment_length, size_t vertex_stride) {
    if (!ctx || !ctx->library || !vertex_name || vertex_length == 0 || !fragment_name || fragment_length == 0) {
        return false;
    }

    id<MTLDevice> device = (__bridge id<MTLDevice>)ctx->device;
    if (!device) return false;

    id<MTLLibrary> library = (__bridge id<MTLLibrary>)ctx->library;

    NSString* vertexString = [[NSString alloc] initWithBytes:vertex_name length:vertex_length encoding:NSUTF8StringEncoding];
    NSString* fragmentString = [[NSString alloc] initWithBytes:fragment_name length:fragment_length encoding:NSUTF8StringEncoding];
    if (!vertexString || !fragmentString) return false;

    id<MTLFunction> vertexFunction = [library newFunctionWithName:vertexString];
    id<MTLFunction> fragmentFunction = [library newFunctionWithName:fragmentString];
    if (!vertexFunction || !fragmentFunction) {
        NSLog(@"Failed to find UI shader functions");
        return false;
    }

    CAMetalLayer* layer = (__bridge CAMetalLayer*)ctx->layer;
    MTLPixelFormat pixelFormat = layer ? layer.pixelFormat : MTLPixelFormatBGRA8Unorm;
    if (pixelFormat == MTLPixelFormatInvalid) {
        pixelFormat = MTLPixelFormatBGRA8Unorm;
    }

    MTLRenderPipelineDescriptor* descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.vertexFunction = vertexFunction;
    descriptor.fragmentFunction = fragmentFunction;
    descriptor.colorAttachments[0].pixelFormat = pixelFormat;
    descriptor.depthAttachmentPixelFormat = MTLPixelFormatInvalid;

    MTLVertexDescriptor* vertexDescriptor = [MTLVertexDescriptor vertexDescriptor];
    vertexDescriptor.attributes[0].format = MTLVertexFormatFloat2;
    vertexDescriptor.attributes[0].offset = 0;
    vertexDescriptor.attributes[0].bufferIndex = 0;
    vertexDescriptor.attributes[1].format = MTLVertexFormatFloat4;
    vertexDescriptor.attributes[1].offset = sizeof(float) * 2;
    vertexDescriptor.attributes[1].bufferIndex = 0;
    vertexDescriptor.layouts[0].stride = vertex_stride;
    vertexDescriptor.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;

    descriptor.vertexDescriptor = vertexDescriptor;

    NSError* error = nil;
    id<MTLRenderPipelineState> pipelineState = [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
    if (!pipelineState) {
        NSLog(@"Failed to create UI pipeline state: %@", error);
        return false;
    }

    metal_release_and_assign(&ctx->ui_pipeline, (__bridge_retained void*)pipelineState);
    ctx->ui_vertex_stride = vertex_stride;
    return true;
}

bool metal_set_mesh(MetalContext* ctx, const void* vertices, size_t vertex_count, size_t vertex_stride, const uint32_t* indices, size_t index_count) {
    if (!ctx || !vertices || vertex_count == 0 || !indices || index_count == 0) {
        return false;
    }

    id<MTLDevice> device = (__bridge id<MTLDevice>)ctx->device;
    if (!device) return false;

    NSUInteger vertex_length = (NSUInteger)(vertex_count * vertex_stride);
    id<MTLBuffer> vertexBuffer = [device newBufferWithBytes:vertices length:vertex_length options:MTLResourceStorageModeShared];
    if (!vertexBuffer) return false;

    NSUInteger index_length = (NSUInteger)(index_count * sizeof(uint32_t));
    id<MTLBuffer> indexBuffer = [device newBufferWithBytes:indices length:index_length options:MTLResourceStorageModeShared];
    if (!indexBuffer) return false;

    metal_release_and_assign(&ctx->vertex_buffer, (__bridge_retained void*)vertexBuffer);
    metal_release_and_assign(&ctx->index_buffer, (__bridge_retained void*)indexBuffer);
    ctx->vertex_stride = vertex_stride;
    ctx->index_count = index_count;

    return true;
}

bool metal_set_uniforms(MetalContext* ctx, const void* uniforms, size_t size) {
    if (!ctx || !uniforms || size == 0) {
        return false;
    }

    id<MTLDevice> device = (__bridge id<MTLDevice>)ctx->device;
    if (!device) return false;

    id<MTLBuffer> uniformBuffer = ctx->uniform_buffer ? (__bridge id<MTLBuffer>)ctx->uniform_buffer : nil;
    if (!uniformBuffer || ctx->uniform_size < size) {
        uniformBuffer = [device newBufferWithLength:size options:MTLResourceStorageModeShared];
        if (!uniformBuffer) return false;
        metal_release_and_assign(&ctx->uniform_buffer, (__bridge_retained void*)uniformBuffer);
        ctx->uniform_size = size;
    }

    memcpy([uniformBuffer contents], uniforms, size);

    return true;
}

bool metal_draw(MetalContext* ctx, const float* clear_color) {
    if (!ctx) return false;

    CAMetalLayer* layer = (__bridge CAMetalLayer*)ctx->layer;
    id<MTLCommandQueue> queue = (__bridge id<MTLCommandQueue>)ctx->queue;
    id<MTLDevice> device = (__bridge id<MTLDevice>)ctx->device;
    if (!layer || !queue) return false;

    id<CAMetalDrawable> drawable = [layer nextDrawable];
    if (!drawable) return false;

    id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
    if (!commandBuffer) return false;

    id<MTLRenderPipelineState> geoPipeline = ctx->pipeline ? (__bridge id<MTLRenderPipelineState>)ctx->pipeline : nil;
    id<MTLRenderPipelineState> uiPipeline = ctx->ui_pipeline ? (__bridge id<MTLRenderPipelineState>)ctx->ui_pipeline : nil;
    id<MTLBuffer> vertexBuffer = ctx->vertex_buffer ? (__bridge id<MTLBuffer>)ctx->vertex_buffer : nil;
    id<MTLBuffer> indexBuffer = ctx->index_buffer ? (__bridge id<MTLBuffer>)ctx->index_buffer : nil;
    id<MTLBuffer> uniformBuffer = ctx->uniform_buffer ? (__bridge id<MTLBuffer>)ctx->uniform_buffer : nil;
    id<MTLBuffer> lineBuffer = ctx->line_buffer ? (__bridge id<MTLBuffer>)ctx->line_buffer : nil;
    id<MTLBuffer> uiBuffer = ctx->ui_vertex_buffer ? (__bridge id<MTLBuffer>)ctx->ui_vertex_buffer : nil;
    id<MTLDepthStencilState> depthState = ctx->depth_state ? (__bridge id<MTLDepthStencilState>)ctx->depth_state : nil;

    const bool has_geometry = geoPipeline && vertexBuffer && indexBuffer && ctx->index_count > 0;
    const bool has_ui = uiPipeline && uiBuffer && ctx->ui_vertex_count > 0;

    MTLViewport viewport = {
        .originX = 0,
        .originY = 0,
        .width = (double)drawable.texture.width,
        .height = (double)drawable.texture.height,
        .znear = 0.0,
        .zfar = 1.0,
    };

    bool surface_cleared = false;

    if (has_geometry) {
        MTLRenderPassDescriptor* geoPass = [MTLRenderPassDescriptor renderPassDescriptor];
        geoPass.colorAttachments[0].texture = drawable.texture;
        geoPass.colorAttachments[0].loadAction = MTLLoadActionClear;
        geoPass.colorAttachments[0].storeAction = MTLStoreActionStore;
        if (clear_color) {
            geoPass.colorAttachments[0].clearColor = MTLClearColorMake(clear_color[0], clear_color[1], clear_color[2], clear_color[3]);
        } else {
            geoPass.colorAttachments[0].clearColor = MTLClearColorMake(0.1, 0.1, 0.1, 1.0);
        }

        if (depthState) {
            MTLTextureDescriptor* depthDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:drawable.texture.width height:drawable.texture.height mipmapped:NO];
            depthDesc.storageMode = MTLStorageModePrivate;
            depthDesc.usage = MTLTextureUsageRenderTarget;
            id<MTLTexture> depthTexture = [device newTextureWithDescriptor:depthDesc];
            if (depthTexture) {
                geoPass.depthAttachment.texture = depthTexture;
                geoPass.depthAttachment.loadAction = MTLLoadActionClear;
                geoPass.depthAttachment.storeAction = MTLStoreActionDontCare;
                geoPass.depthAttachment.clearDepth = 1.0;
            }
        }

        id<MTLRenderCommandEncoder> geoEncoder = [commandBuffer renderCommandEncoderWithDescriptor:geoPass];
        if (!geoEncoder) {
            return false;
        }

        [geoEncoder setViewport:viewport];
        [geoEncoder setRenderPipelineState:geoPipeline];
        if (depthState) {
            [geoEncoder setDepthStencilState:depthState];
        }
        [geoEncoder setFrontFacingWinding:MTLWindingCounterClockwise];
        [geoEncoder setCullMode:MTLCullModeNone];
        [geoEncoder setTriangleFillMode:ctx->render_mode == RenderModeWireframe ? MTLTriangleFillModeLines : MTLTriangleFillModeFill];
        [geoEncoder setVertexBuffer:vertexBuffer offset:0 atIndex:0];
        if (uniformBuffer) {
            [geoEncoder setVertexBuffer:uniformBuffer offset:0 atIndex:1];
            [geoEncoder setFragmentBuffer:uniformBuffer offset:0 atIndex:0];
        }
        if (ctx->texture) {
            id<MTLTexture> texture = (__bridge id<MTLTexture>)ctx->texture;
            [geoEncoder setFragmentTexture:texture atIndex:0];
        }
        if (ctx->sampler) {
            id<MTLSamplerState> sampler = (__bridge id<MTLSamplerState>)ctx->sampler;
            [geoEncoder setFragmentSamplerState:sampler atIndex:0];
        }
        [geoEncoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                              indexCount:(NSUInteger)ctx->index_count
                               indexType:MTLIndexTypeUInt32
                             indexBuffer:indexBuffer
                       indexBufferOffset:0];

        if (lineBuffer && ctx->line_vertex_count > 0) {
            [geoEncoder setVertexBuffer:lineBuffer offset:0 atIndex:0];
            if (uniformBuffer) {
                [geoEncoder setVertexBuffer:uniformBuffer offset:0 atIndex:1];
                [geoEncoder setFragmentBuffer:uniformBuffer offset:0 atIndex:0];
            }
            [geoEncoder drawPrimitives:MTLPrimitiveTypeLine vertexStart:0 vertexCount:(NSUInteger)ctx->line_vertex_count];
        }
        [geoEncoder endEncoding];
        surface_cleared = true;
    }

    if (has_ui) {
        MTLRenderPassDescriptor* uiPass = [MTLRenderPassDescriptor renderPassDescriptor];
        uiPass.colorAttachments[0].texture = drawable.texture;
        if (surface_cleared) {
            uiPass.colorAttachments[0].loadAction = MTLLoadActionLoad;
        } else {
            uiPass.colorAttachments[0].loadAction = MTLLoadActionClear;
            if (clear_color) {
                uiPass.colorAttachments[0].clearColor = MTLClearColorMake(clear_color[0], clear_color[1], clear_color[2], clear_color[3]);
            } else {
                uiPass.colorAttachments[0].clearColor = MTLClearColorMake(0.1, 0.1, 0.1, 1.0);
            }
            surface_cleared = true;
        }
        uiPass.colorAttachments[0].storeAction = MTLStoreActionStore;

        id<MTLRenderCommandEncoder> uiEncoder = [commandBuffer renderCommandEncoderWithDescriptor:uiPass];
        if (!uiEncoder) {
            return false;
        }

        [uiEncoder setViewport:viewport];
        [uiEncoder setRenderPipelineState:uiPipeline];
        [uiEncoder setFrontFacingWinding:MTLWindingCounterClockwise];
        [uiEncoder setCullMode:MTLCullModeNone];
        [uiEncoder setTriangleFillMode:MTLTriangleFillModeFill];
        [uiEncoder setVertexBuffer:nil offset:0 atIndex:1];
        [uiEncoder setFragmentBuffer:nil offset:0 atIndex:0];
        [uiEncoder setFragmentTexture:nil atIndex:0];
        [uiEncoder setFragmentSamplerState:nil atIndex:0];
        [uiEncoder setVertexBuffer:uiBuffer offset:0 atIndex:0];
        [uiEncoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:(NSUInteger)ctx->ui_vertex_count];
        [uiEncoder endEncoding];
    } else if (!surface_cleared) {
        MTLRenderPassDescriptor* clearPass = [MTLRenderPassDescriptor renderPassDescriptor];
        clearPass.colorAttachments[0].texture = drawable.texture;
        clearPass.colorAttachments[0].loadAction = MTLLoadActionClear;
        clearPass.colorAttachments[0].storeAction = MTLStoreActionStore;
        if (clear_color) {
            clearPass.colorAttachments[0].clearColor = MTLClearColorMake(clear_color[0], clear_color[1], clear_color[2], clear_color[3]);
        } else {
            clearPass.colorAttachments[0].clearColor = MTLClearColorMake(0.1, 0.1, 0.1, 1.0);
        }
        id<MTLRenderCommandEncoder> clearEncoder = [commandBuffer renderCommandEncoderWithDescriptor:clearPass];
        if (clearEncoder) {
            [clearEncoder setViewport:viewport];
            [clearEncoder endEncoding];
        }
    }

    [commandBuffer presentDrawable:drawable];
    [commandBuffer commit];

    if (ctx->capture_pending && ctx->capture_path && ctx->capture_path_len > 0) {
        [commandBuffer waitUntilCompleted];
        NSString* pathString = [[NSString alloc] initWithBytes:ctx->capture_path length:ctx->capture_path_len encoding:NSUTF8StringEncoding];
        if (!pathString) {
            NSLog(@"Failed to decode screenshot path");
        } else {
            id<MTLTexture> captureTexture = drawable.texture;
            if (!metal_save_texture_png(captureTexture, pathString)) {
                NSLog(@"Failed to save screenshot to %@", pathString);
            }
        }
        free(ctx->capture_path);
        ctx->capture_path = NULL;
        ctx->capture_path_len = 0;
        ctx->capture_pending = false;
    }

    return true;
}




bool metal_request_capture(MetalContext* ctx, const char* path, size_t path_length) {
    if (!ctx || !path || path_length == 0) return false;

    char* copy = malloc(path_length);
    if (!copy) return false;

    memcpy(copy, path, path_length);

    if (ctx->capture_path) {
        free(ctx->capture_path);
    }

    ctx->capture_path = copy;
    ctx->capture_path_len = path_length;
    ctx->capture_pending = true;

    if (ctx->layer) {
        CAMetalLayer* layer = (__bridge CAMetalLayer*)ctx->layer;
        layer.framebufferOnly = NO;
    }

    return true;
}


bool metal_render_frame(MetalContext* ctx, float r, float g, float b) {
    float clear[4] = { r, g, b, 1.0f };
    return metal_draw(ctx, clear);
}

const char* metal_get_device_name(MetalContext* ctx) {
    if (!ctx) return "Unknown";
    id<MTLDevice> device = (__bridge id<MTLDevice>)ctx->device;
    return [[device name] UTF8String];
}

void metal_set_performance_hud(MetalContext* ctx, bool enabled) {
    if (!ctx || !ctx->layer) return;

    CAMetalLayer* layer = (__bridge CAMetalLayer*)ctx->layer;

    // The Metal HUD is controlled by CAMetalLayer's displaySyncEnabled and developer HUD settings
    // We need to access the MTLDevice to enable the HUD
    id<MTLDevice> device = (__bridge id<MTLDevice>)ctx->device;

    if (enabled) {
        // Enable developer HUD by setting environment variable (must be done before device creation)
        // Since we can't change this at runtime, we enable statistics collection
        NSLog(@"Metal Performance HUD requested. Note: For full HUD, set MTL_HUD_ENABLED=1 before launch");

        // We can at least enable frame capture and statistics
        layer.framebufferOnly = NO; // Allow reading back for profiling
    } else {
        layer.framebufferOnly = YES; // Optimize for rendering only
    }
}

void metal_set_render_mode(MetalContext* ctx, int mode) {
    if (!ctx) return;
    ctx->render_mode = (RenderMode)mode;
}

bool metal_set_line_mesh(MetalContext* ctx, const void* vertices, size_t vertex_count, size_t vertex_stride) {
    if (!ctx || !vertices || vertex_count == 0) {
        // Clear line buffer if no vertices
        if (ctx->line_buffer) {
            CFRelease(ctx->line_buffer);
            ctx->line_buffer = NULL;
        }
        ctx->line_vertex_count = 0;
        return true;
    }

    id<MTLDevice> device = (__bridge id<MTLDevice>)ctx->device;
    if (!device) return false;

    NSUInteger vertex_length = (NSUInteger)(vertex_count * vertex_stride);
    id<MTLBuffer> lineBuffer = [device newBufferWithBytes:vertices length:vertex_length options:MTLResourceStorageModeShared];
    if (!lineBuffer) return false;

    metal_release_and_assign(&ctx->line_buffer, (__bridge_retained void*)lineBuffer);
    ctx->line_vertex_count = vertex_count;

    return true;
}

bool metal_set_ui_mesh(MetalContext* ctx, const void* vertices, size_t vertex_count, size_t vertex_stride) {
    if (!ctx) return false;
    if (!vertices || vertex_count == 0) {
        if (ctx->ui_vertex_buffer) {
            CFRelease(ctx->ui_vertex_buffer);
            ctx->ui_vertex_buffer = NULL;
        }
        ctx->ui_vertex_count = 0;
        ctx->ui_vertex_stride = 0;
        return true;
    }

    id<MTLDevice> device = (__bridge id<MTLDevice>)ctx->device;
    if (!device) return false;

    NSUInteger length = (NSUInteger)(vertex_count * vertex_stride);
    id<MTLBuffer> buffer = [device newBufferWithBytes:vertices length:length options:MTLResourceStorageModeShared];
    if (!buffer) return false;

    metal_release_and_assign(&ctx->ui_vertex_buffer, (__bridge_retained void*)buffer);
    ctx->ui_vertex_stride = vertex_stride;
    ctx->ui_vertex_count = vertex_count;
    return true;
}

bool metal_set_texture(MetalContext* ctx, const uint8_t* data, size_t width, size_t height, size_t bytes_per_row) {
    if (!ctx || !data || width == 0 || height == 0 || bytes_per_row == 0) {
        return false;
    }

    id<MTLDevice> device = (__bridge id<MTLDevice>)ctx->device;
    if (!device) return false;

    MTLTextureDescriptor* descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:(NSUInteger)width height:(NSUInteger)height mipmapped:NO];
    descriptor.storageMode = MTLStorageModeShared;
    descriptor.usage = MTLTextureUsageShaderRead;

    id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
    if (!texture) {
        NSLog(@"Failed to create texture");
        return false;
    }

    MTLRegion region = MTLRegionMake2D(0, 0, (NSUInteger)width, (NSUInteger)height);
    [texture replaceRegion:region mipmapLevel:0 withBytes:data bytesPerRow:(NSUInteger)bytes_per_row];

    MTLSamplerDescriptor* samplerDescriptor = [[MTLSamplerDescriptor alloc] init];
    samplerDescriptor.minFilter = MTLSamplerMinMagFilterLinear;
    samplerDescriptor.magFilter = MTLSamplerMinMagFilterLinear;
    samplerDescriptor.mipFilter = MTLSamplerMipFilterNotMipmapped;
    samplerDescriptor.sAddressMode = MTLSamplerAddressModeRepeat;
    samplerDescriptor.tAddressMode = MTLSamplerAddressModeRepeat;
    id<MTLSamplerState> sampler = [device newSamplerStateWithDescriptor:samplerDescriptor];
    if (!sampler) {
        NSLog(@"Failed to create sampler state");
        return false;
    }

    metal_release_and_assign(&ctx->texture, (__bridge_retained void*)texture);
    metal_release_and_assign(&ctx->sampler, (__bridge_retained void*)sampler);

    return true;
}
