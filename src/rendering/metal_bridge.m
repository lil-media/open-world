#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <string.h>
#import <stdint.h>

// Simple C API for Metal rendering from Zig
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
    size_t vertex_stride;
    size_t index_count;
    size_t uniform_size;
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
    ctx->vertex_stride = 0;
    ctx->index_count = 0;
    ctx->uniform_size = 0;

    return ctx;
}

void metal_destroy_context(MetalContext* ctx) {
    if (ctx) {
        if (ctx->uniform_buffer) CFRelease(ctx->uniform_buffer);
        if (ctx->index_buffer) CFRelease(ctx->index_buffer);
        if (ctx->vertex_buffer) CFRelease(ctx->vertex_buffer);
        if (ctx->pipeline) CFRelease(ctx->pipeline);
        if (ctx->library) CFRelease(ctx->library);
        if (ctx->depth_state) CFRelease(ctx->depth_state);
        if (ctx->texture) CFRelease(ctx->texture);
        if (ctx->sampler) CFRelease(ctx->sampler);
        if (ctx->device) CFRelease(ctx->device);
        if (ctx->queue) CFRelease(ctx->queue);
        if (ctx->layer) CFRelease(ctx->layer);
        free(ctx);
    }
}

static void metal_release_and_assign(void** target, void* new_value) {
    if (*target) {
        CFRelease(*target);
    }
    *target = new_value;
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
        NSLog(@"Failed to find shader entry points.");
        return false;
    }

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

    if (clear_color) {
        passDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(clear_color[0], clear_color[1], clear_color[2], clear_color[3]);
    } else {
        passDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0.1, 0.1, 0.1, 1.0);
    }

    MTLTextureDescriptor* depthDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:drawable.texture.width height:drawable.texture.height mipmapped:NO];
    depthDesc.storageMode = MTLStorageModePrivate;
    depthDesc.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> depthTexture = [device newTextureWithDescriptor:depthDesc];
    if (depthTexture) {
        passDescriptor.depthAttachment.texture = depthTexture;
        passDescriptor.depthAttachment.loadAction = MTLLoadActionClear;
        passDescriptor.depthAttachment.storeAction = MTLStoreActionDontCare;
        passDescriptor.depthAttachment.clearDepth = 1.0;
    }

    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:passDescriptor];
    if (!encoder) return false;

    id<MTLRenderPipelineState> pipeline = ctx->pipeline ? (__bridge id<MTLRenderPipelineState>)ctx->pipeline : nil;
    id<MTLBuffer> vertexBuffer = ctx->vertex_buffer ? (__bridge id<MTLBuffer>)ctx->vertex_buffer : nil;
    id<MTLBuffer> indexBuffer = ctx->index_buffer ? (__bridge id<MTLBuffer>)ctx->index_buffer : nil;
    id<MTLBuffer> uniformBuffer = ctx->uniform_buffer ? (__bridge id<MTLBuffer>)ctx->uniform_buffer : nil;

    if (pipeline && vertexBuffer && indexBuffer && ctx->index_count > 0) {
        [encoder setRenderPipelineState:pipeline];
        if (ctx->depth_state) {
            id<MTLDepthStencilState> depthState = (__bridge id<MTLDepthStencilState>)ctx->depth_state;
            [encoder setDepthStencilState:depthState];
        }
        [encoder setFrontFacingWinding:MTLWindingCounterClockwise];
        [encoder setCullMode:MTLCullModeBack];
        [encoder setVertexBuffer:vertexBuffer offset:0 atIndex:0];
        if (uniformBuffer) {
            [encoder setVertexBuffer:uniformBuffer offset:0 atIndex:1];
            [encoder setFragmentBuffer:uniformBuffer offset:0 atIndex:0];
        }
        if (ctx->texture) {
            id<MTLTexture> texture = (__bridge id<MTLTexture>)ctx->texture;
            [encoder setFragmentTexture:texture atIndex:0];
        }
        if (ctx->sampler) {
            id<MTLSamplerState> sampler = (__bridge id<MTLSamplerState>)ctx->sampler;
            [encoder setFragmentSamplerState:sampler atIndex:0];
        }
        [encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                            indexCount:(NSUInteger)ctx->index_count
                             indexType:MTLIndexTypeUInt32
                           indexBuffer:indexBuffer
                     indexBufferOffset:0];
    }

    [encoder endEncoding];
    [commandBuffer presentDrawable:drawable];
    [commandBuffer commit];

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
