#include "Precomp.h"
#include "Engine.h"
#include "Packages/Engine/USurrealClient.h"
#include "Packages/Engine/Subsystems/USurrealRenderDevice.h"
#include <array>
#include "RenderDevice/RenderDevice.h"
#include "RenderDevice/OpenGL/GLTextureUploader.h"
#include "Packages/Engine/Resources/Level/UModel.h"
#include <surrealwidgets/core/widget.h>
#include <surrealwidgets/window/cocoanativehandle.h>
#import "../../../SurrealWidgets/src/window/cocoa/AppKitWrapper.h"
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include <map>
#include <vector>
#include <stdexcept>

namespace {
struct Vertex { vec4 position,color; vec2 uv,lm; vec4 detail,macro,fog; };
struct DrawFlags { uint32_t poly, textures; };
static_assert(sizeof(Vertex)==96);

int TextureBaseMip(const TextureInfo& info, const USurrealClient& client)
{
    if (!info.Texture || info.NumMips <= 1) return 0;
    const auto lod = info.Texture->LODSet();
    const NameString quality = lod == 1 ? client.TextureDetail : lod == 2 ? client.SkinDetail : "High";
    const int level = quality == "Low" ? (lod == 2 ? 1 : 2) : quality == "Medium" ? 1 : 0;
    return std::min(level, info.NumMips - 1);
}
// Each slot is reused only after its command buffer has finished reading it.
struct FrameVertices {
    id<MTLCommandBuffer> submitted;
    std::vector<id<MTLBuffer>> chunks;
    size_t chunk=0, offset=0;
    void reset() {
        [submitted waitUntilCompleted];
        if (submitted.error) throw std::runtime_error(submitted.error.localizedDescription.UTF8String);
        submitted=nil; chunk=offset=0;
    }
    std::pair<id<MTLBuffer>,size_t> reserve(id<MTLDevice> device,size_t bytes) {
        if (!bytes || bytes>device.maxBufferLength-15) throw std::runtime_error("Metal: invalid vertex buffer size");
        if (chunk<chunks.size() && bytes>chunks[chunk].length-offset) { ++chunk; offset=0; }
        if (chunk==chunks.size()) chunks.push_back(nil);
        if (!chunks[chunk] || chunks[chunk].length<bytes) {
            chunks[chunk]=[device newBufferWithLength:std::max((bytes+15)&~size_t(15),size_t(1024*1024)) options:MTLResourceStorageModeShared];
            if (!chunks[chunk]) throw std::runtime_error("Metal: vertex allocation failed");
        }
        size_t start=offset;
        offset=(start+bytes+15)&~size_t(15);
        return {chunks[chunk],start};
    }
};

id<MTLTexture> UploadMetalTexture(id<MTLDevice> device,const TextureInfo& info,int baseMip,bool masked)
{
    if (!info.Mips || baseMip<0 || baseMip>=info.NumMips) throw std::runtime_error("Metal: invalid mip level");
    auto uploader=GLTextureUploader::GetUploader(info.Format);
    if (!uploader || (uploader->GetInternalformat()!=GL_RGBA8 && uploader->GetInternalformat()!=GL_RGBA32F))
        throw std::runtime_error("Metal: unsupported texture format "+std::to_string(uint32_t(info.Format)));
    auto& base=info.Mips[baseMip];
    if (base.Width<=0 || base.Height<=0 || base.Width>16384 || base.Height>16384) throw std::runtime_error("Metal: invalid texture dimensions");
    int levels=1;
    for (int size=std::max(base.Width,base.Height); size>1 && levels<info.NumMips-baseMip; size/=2) ++levels;
    const size_t pixelSize=info.Format==TextureFormat::RGBA32_F ? 16 : 4;
    const size_t inputSize=info.Format==TextureFormat::P8 ? 1 : info.Format==TextureFormat::RGB8 ? 3 : pixelSize;
    const auto format=info.Format==TextureFormat::BGRA8 ? MTLPixelFormatBGRA8Unorm : info.Format==TextureFormat::RGBA32_F ? MTLPixelFormatRGBA32Float : MTLPixelFormatRGBA8Unorm;
    auto desc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:base.Width height:base.Height mipmapped:levels>1];
    desc.mipmapLevelCount=levels; desc.storageMode=MTLStorageModeShared; desc.usage=MTLTextureUsageShaderRead;
    id<MTLTexture> result=[device newTextureWithDescriptor:desc];
    if (!result) throw std::runtime_error("Metal: texture allocation failed");
    std::vector<uint8_t> pixels(size_t(base.Width)*base.Height*pixelSize);
    for (int level=0; level<levels; ++level) {
        auto& mip=info.Mips[baseMip+level];
        if (mip.Width!=std::max(base.Width>>level,1) || mip.Height!=std::max(base.Height>>level,1))
            throw std::runtime_error("Metal: inconsistent mip dimensions");
        if (mip.Data.size()<size_t(mip.Width)*mip.Height*inputSize || (info.Format==TextureFormat::P8 && !info.Palette))
            throw std::runtime_error("Metal: truncated texture");
        uploader->UploadRect(pixels.data(),&mip,0,0,mip.Width,mip.Height,info.Palette,masked);
        [result replaceRegion:MTLRegionMake2D(0,0,mip.Width,mip.Height) mipmapLevel:level withBytes:pixels.data() bytesPerRow:size_t(mip.Width)*pixelSize];
    }
    return result;
}

float MetalGammaExponent(float brightness)
{
    return 1.0f/std::clamp(std::isfinite(brightness) ? brightness*2.0f : 1.0f,0.05f,2.99f);
}

const char* source=R"(
#include <metal_stdlib>
using namespace metal;
struct V { float4 position,color; float2 uv,lm; float4 detail,macro,fog; };
struct DrawFlags { uint poly, textures; };
struct Out { float4 position [[position]]; float4 color; float2 uv,lm,detail,macro; float4 fog; };
vertex Out mainVS(uint i [[vertex_id]],const device V* v [[buffer(0)]]) {
    return {v[i].position,v[i].color,v[i].uv,v[i].lm,v[i].detail.xy,v[i].macro.xy,v[i].fog};
}
fragment float4 mainPS(Out v [[stage_in]],texture2d<float> tex [[texture(0)]],texture2d<float> light [[texture(1)]],texture2d<float> detail [[texture(2)]],texture2d<float> macro [[texture(3)]],sampler s [[sampler(0)]],sampler lightSampler [[sampler(1)]],constant DrawFlags& flags [[buffer(0)]]) {
    float4 c=tex.sample(s,v.uv);
    c*=v.color;
    if (flags.textures&4) c*=macro.sample(s,v.macro);
    if ((flags.poly&2) && c.a<0.5) discard_fragment();
    if (flags.textures&1) c.rgb*=clamp(light.sample(lightSampler,v.lm).rgb,0.0f,1.0f)*2.0;
    if (flags.textures&2) {
        float fade=clamp(2.0f-(1.0f/v.position.w)/380.0f,0.0f,1.0f);
        float3 detailColor=(detail.sample(s,v.detail).rgb-0.5f)*0.8f+1.0f;
        c.rgb=mix(c.rgb,c.rgb*detailColor,fade);
    }
    if (flags.textures&8) {
        float4 fog=detail.sample(lightSampler,v.detail);
        c.rgb=fog.rgb+c.rgb*(1.0f-fog.a);
    } else if (flags.textures&16) c.rgb=v.fog.rgb+c.rgb*(1.0f-v.fog.a);
    return c;
}
struct CompositeOut { float4 position [[position]]; float2 uv; };
vertex CompositeOut compositeVS(uint i [[vertex_id]]) {
    float2 uv=float2((i<<1)&2,i&2);
    return {float4(uv.x*2-1,1-uv.y*2,0,1),uv};
}
fragment float4 compositePS(CompositeOut v [[stage_in]],texture2d<float> world [[texture(0)]]) {
    constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear);
    return world.sample(s,v.uv);
}
fragment float4 gammaPS(CompositeOut v [[stage_in]],texture2d<float> frame [[texture(0)]],constant float& exponent [[buffer(0)]]) {
    float4 c=frame.read(uint2(v.position.xy));
    return float4(pow(clamp(c.rgb,0.0f,1.0f),float3(exponent)),c.a);
})";
class MetalRenderDevice final : public RenderDevice {
    friend struct MetalRenderChecks;
    id<MTLDevice> device;
    id<MTLCommandQueue> queue;
    id<MTLLibrary> library;
    CAMetalLayer* layer;
    id<CAMetalDrawable> drawable;
    id<MTLCommandBuffer> commands, lastSubmitted;
    std::array<FrameVertices,2> verticesByFrame;
    size_t frameIndex=0;
    id<MTLRenderCommandEncoder> encoder;
    id<MTLTexture> depth,white,lastFrame,worldColor,worldDepth;
    id<MTLRenderPipelineState> compositePipeline,gammaPipeline;
    id<MTLTexture> frameColor;
    float gammaExponent=1.0f;
    struct DrawBatch {
        id<MTLBuffer> buffer;
        size_t offset=0,count=0;
        uint32_t poly=0,textures=0;
        MTLPrimitiveType primitive=MTLPrimitiveTypeTriangle;
        std::array<id<MTLTexture>,4> images;
        id<MTLSamplerState> sampler;
    } batch;
    size_t drawCalls=0;
    bool worldPass=false,worldRendering=false;
    id<MTLSamplerState> sampler,nearest,linear,lightSampler;
    std::map<uint32_t,id<MTLRenderPipelineState>> pipelines;
    std::map<bool,id<MTLDepthStencilState>> depths;
    struct CachedTexture { int mip; id<MTLTexture> texture; };
    std::map<std::pair<uint64_t,bool>,CachedTexture> textures;
    Rect renderRect, lastFrameRect;
    mat4 transform=mat4::identity();
    SceneNode* current=nullptr;
    vec4 flashScale{},flashFog{};
    bool frameReported=false;

    id<MTLTexture> texture(TextureInfo* info,bool masked=false) {
        if (!info || !info->NumMips || !info->Mips) return white;
        const int baseMip=TextureBaseMip(*info,*engine->client);
        const auto key=std::make_pair(info->CacheID,masked);
        auto found=textures.find(key);
        if (found!=textures.end() && found->second.mip==baseMip && !info->bRealtimeChanged) return found->second.texture;
        auto result=UploadMetalTexture(device,*info,baseMip,masked);
        textures[key]={baseMip,result};
        return result;
    }
    id<MTLRenderPipelineState> pipeline(uint32_t flags) {
        const uint32_t key=flags&(PF_Invisible|PF_Translucent|PF_Modulated|PF_Highlighted);
        auto found=pipelines.find(key); if (found!=pipelines.end()) return found->second;
        auto desc=[MTLRenderPipelineDescriptor new];
        desc.vertexFunction=[library newFunctionWithName:@"mainVS"];
        desc.fragmentFunction=[library newFunctionWithName:@"mainPS"];
        desc.depthAttachmentPixelFormat=MTLPixelFormatDepth32Float;
        auto c=desc.colorAttachments[0]; c.pixelFormat=MTLPixelFormatBGRA8Unorm;
        c.writeMask=(flags&PF_Invisible) ? MTLColorWriteMaskNone : MTLColorWriteMaskAll;
        c.blendingEnabled=bool(key&(PF_Translucent|PF_Modulated|PF_Highlighted));
        c.sourceRGBBlendFactor=MTLBlendFactorOne; c.destinationRGBBlendFactor=MTLBlendFactorZero;
        if (flags&PF_Translucent) c.destinationRGBBlendFactor=MTLBlendFactorOneMinusSourceColor;
        else if (flags&PF_Modulated) { c.sourceRGBBlendFactor=MTLBlendFactorDestinationColor; c.destinationRGBBlendFactor=MTLBlendFactorSourceColor; }
        else if (flags&PF_Highlighted) c.destinationRGBBlendFactor=MTLBlendFactorOneMinusSourceAlpha;
        c.sourceAlphaBlendFactor=c.sourceRGBBlendFactor; c.destinationAlphaBlendFactor=c.destinationRGBBlendFactor;
        NSError* error=nil; auto result=[device newRenderPipelineStateWithDescriptor:desc error:&error];
        if (!result) throw std::runtime_error(error.localizedDescription.UTF8String);
        pipelines[key]=result; return result;
    }
    void beginPass(bool clearColor,bool clearDepth,vec4 color={}) {
        auto pass=[MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture=worldPass ? worldColor : gammaExponent!=1.0f ? frameColor : drawable.texture;
        pass.colorAttachments[0].loadAction=clearColor ? MTLLoadActionClear : MTLLoadActionLoad;
        pass.colorAttachments[0].storeAction=MTLStoreActionStore;
        pass.colorAttachments[0].clearColor=MTLClearColorMake(color.x,color.y,color.z,color.w);
        pass.depthAttachment.texture=worldPass ? worldDepth : depth;
        pass.depthAttachment.loadAction=clearDepth ? MTLLoadActionClear : MTLLoadActionLoad;
        pass.depthAttachment.storeAction=MTLStoreActionStore; pass.depthAttachment.clearDepth=1;
        encoder=[commands renderCommandEncoderWithDescriptor:pass];
        [encoder setCullMode:MTLCullModeNone];
        if (current) SetSceneNode(current);
    }
    void flushDraws() {
        if (!batch.count) return;
        const bool writes=!(batch.poly&(PF_Translucent|PF_Modulated)) || (batch.poly&PF_Occlude);
        [encoder setDepthStencilState:depths.at(writes)];
        [encoder setVertexBuffer:batch.buffer offset:batch.offset atIndex:0];
        for (size_t i=0;i<batch.images.size();++i) [encoder setFragmentTexture:batch.images[i] atIndex:i];
        DrawFlags flags{batch.poly,batch.textures};
        [encoder setFragmentBytes:&flags length:sizeof(flags) atIndex:0];
        [encoder setFragmentSamplerState:batch.sampler atIndex:0];
        [encoder setFragmentSamplerState:lightSampler atIndex:1];
        [encoder setRenderPipelineState:pipeline(batch.poly)];
        [encoder drawPrimitives:batch.primitive vertexStart:0 vertexCount:batch.count];
        ++drawCalls; batch={};
    }
    Vertex* reserveDraw(size_t count,TextureInfo* tex,TextureInfo* lm,uint32_t flags,MTLPrimitiveType primitive=MTLPrimitiveTypeTriangle,TextureInfo* detail=nullptr,TextureInfo* macro=nullptr,bool fogMap=false,bool meshFog=false,bool smoothWorld=true) {
        if (!encoder || !count) return nullptr;
        if (count>device.maxBufferLength/sizeof(Vertex)) throw std::runtime_error("Metal: too many vertices");
        if (flags&PF_Translucent) flags&=~PF_Masked;
        std::array<id<MTLTexture>,4> images={texture(tex,flags&PF_Masked),texture(lm),texture(detail),texture(macro)};
        const uint32_t textureFlags=(lm ? 1u : 0u) | (detail ? (fogMap ? 8u : 2u) : 0u) | (macro ? 4u : 0u) | (meshFog ? 16u : 0u);
        id<MTLSamplerState> selected=(flags&PF_NoSmooth) ? nearest : smoothWorld ? sampler : linear;
        auto [buffer,offset]=verticesByFrame[frameIndex].reserve(device,count*sizeof(Vertex));
        // Only adjacent draws merge; never sort transparent geometry or cross a state boundary.
        if (batch.count && (batch.poly!=flags || batch.textures!=textureFlags || batch.primitive!=primitive || batch.images!=images || batch.sampler!=selected || batch.buffer!=buffer || batch.offset+batch.count*sizeof(Vertex)!=offset)) flushDraws();
        if (!batch.count) batch={buffer,offset,0,flags,textureFlags,primitive,images,selected};
        batch.count+=count;
        return reinterpret_cast<Vertex*>(static_cast<uint8_t*>(buffer.contents)+offset);
    }
    void prepareFrameColor() {
        gammaExponent=MetalGammaExponent(Brightness);
        drawCalls=0;
        if (gammaExponent!=1.0f && (!frameColor || frameColor.width!=drawable.texture.width || frameColor.height!=drawable.texture.height)) {
            auto desc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:layer.pixelFormat width:drawable.texture.width height:drawable.texture.height mipmapped:NO];
            desc.storageMode=MTLStorageModePrivate; desc.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;
            frameColor=[device newTextureWithDescriptor:desc];
            if (!frameColor) throw std::runtime_error("Metal: gamma target allocation failed");
        }
    }
    void applyGamma() {
        if (gammaExponent==1.0f) return;
        auto pass=[MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture=drawable.texture;
        pass.colorAttachments[0].loadAction=MTLLoadActionDontCare;
        pass.colorAttachments[0].storeAction=MTLStoreActionStore;
        auto output=[commands renderCommandEncoderWithDescriptor:pass];
        [output setRenderPipelineState:gammaPipeline];
        [output setFragmentTexture:frameColor atIndex:0];
        [output setFragmentBytes:&gammaExponent length:sizeof(gammaExponent) atIndex:0];
        [output drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [output endEncoding];
    }
    vec4 screen(float x,float y,float z) const {
        if (!current) throw std::runtime_error("Metal: no scene node");
        return {2*x/current->FX-1,1-2*y/current->FY,std::clamp(z/32768.0f,0.0f,1.0f),1};
    }
    explicit MetalRenderDevice(CAMetalLayer* nativeLayer) {
        layer=nativeLayer;
        if (!layer) throw std::runtime_error("Metal: no native layer");
        device=layer.device ?: MTLCreateSystemDefaultDevice(); layer.device=device;
        layer.pixelFormat=MTLPixelFormatBGRA8Unorm; layer.framebufferOnly=NO;
        queue=[device newCommandQueue];
        NSError* error=nil; library=[device newLibraryWithSource:[NSString stringWithUTF8String:source] options:nil error:&error];
        if (!library) throw std::runtime_error(error.localizedDescription.UTF8String);
        auto sd=[MTLSamplerDescriptor new]; sd.sAddressMode=sd.tAddressMode=MTLSamplerAddressModeRepeat;
        sd.minFilter=sd.magFilter=MTLSamplerMinMagFilterLinear; linear=[device newSamplerStateWithDescriptor:sd];
        sd.mipFilter=MTLSamplerMipFilterLinear; sd.maxAnisotropy=8; sampler=[device newSamplerStateWithDescriptor:sd];
        sd.mipFilter=MTLSamplerMipFilterNotMipmapped; sd.maxAnisotropy=1;
        sd.minFilter=sd.magFilter=MTLSamplerMinMagFilterNearest; nearest=[device newSamplerStateWithDescriptor:sd];
        sd.minFilter=sd.magFilter=MTLSamplerMinMagFilterLinear;
        sd.sAddressMode=sd.tAddressMode=MTLSamplerAddressModeClampToEdge;
        lightSampler=[device newSamplerStateWithDescriptor:sd];
        auto composite=[MTLRenderPipelineDescriptor new];
        composite.vertexFunction=[library newFunctionWithName:@"compositeVS"];
        composite.fragmentFunction=[library newFunctionWithName:@"compositePS"];
        composite.colorAttachments[0].pixelFormat=layer.pixelFormat;
        composite.depthAttachmentPixelFormat=MTLPixelFormatDepth32Float;
        compositePipeline=[device newRenderPipelineStateWithDescriptor:composite error:&error];
        if (!compositePipeline) throw std::runtime_error(error.localizedDescription.UTF8String);
        composite.fragmentFunction=[library newFunctionWithName:@"gammaPS"];
        composite.depthAttachmentPixelFormat=MTLPixelFormatInvalid;
        gammaPipeline=[device newRenderPipelineStateWithDescriptor:composite error:&error];
        if (!gammaPipeline) throw std::runtime_error(error.localizedDescription.UTF8String);
        for (bool write:{false,true}) { auto d=[MTLDepthStencilDescriptor new]; d.depthCompareFunction=MTLCompareFunctionLessEqual; d.depthWriteEnabled=write; depths[write]=[device newDepthStencilStateWithDescriptor:d]; }
        white=[device newTextureWithDescriptor:[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:1 height:1 mipmapped:NO]];
        uint32_t pixel=0xffffffff; [white replaceRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0 withBytes:&pixel bytesPerRow:4];
        fprintf(stderr,"Native ARM64 Metal backend: %s\n",device.name.UTF8String);
    }
public:
    explicit MetalRenderDevice(Widget* viewport) : MetalRenderDevice((__bridge CAMetalLayer*)static_cast<CocoaNativeHandle*>(viewport->GetNativeHandle())->metalLayer) {
        Viewport=viewport;
    }
    void Flush(bool) override { flushDraws(); textures.clear(); }
    void Lock(vec4 scale,vec4 fog,vec4 clear,uint8_t* hits,int* hitSize) override {
        if (hits && hitSize) *hitSize=0;
        flashScale=scale;flashFog=fog;
        verticesByFrame[frameIndex].reset();
        worldPass=worldRendering=false;
        renderRect=engine->window->GetRenderRect();
        layer.drawableSize=CGSizeMake(std::max(1,engine->window->GetNativePixelWidth()),std::max(1,engine->window->GetNativePixelHeight()));
        drawable=[layer nextDrawable]; if (!drawable) return;
        auto t=drawable.texture;
        if (!depth || depth.width!=t.width || depth.height!=t.height) {
            auto desc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:t.width height:t.height mipmapped:NO];
            desc.storageMode=MTLStorageModePrivate; desc.usage=MTLTextureUsageRenderTarget; depth=[device newTextureWithDescriptor:desc];
        }
        prepareFrameColor();
        commands=[queue commandBuffer]; current=nullptr; beginPass(true,true,engine->classicAspectRatio ? vec4(0,0,0,1) : clear);
    }
    void Unlock(bool blit) override {
        if (!commands) return;
        flushDraws();
        [encoder endEncoding]; encoder=nil;
        applyGamma();
        lastFrame=drawable.texture; lastFrameRect=renderRect;
        if (blit) [commands presentDrawable:drawable];
        [commands commit];
        verticesByFrame[frameIndex].submitted=commands;
        frameIndex=(frameIndex+1)%verticesByFrame.size();
        lastSubmitted = commands;
        if (!frameReported) { fprintf(stderr,"Metal frame submitted: %lux%lu; display sync; at most two GPU frames in flight\n",(unsigned long)lastFrame.width,(unsigned long)lastFrame.height);frameReported=true; }
        commands=nil;drawable=nil;current=nullptr;
    }
    void BeginWorld() override {
        worldRendering=true;
        if (!encoder || engine->renderScale>=1.0f) return;
        flushDraws();
        [encoder endEncoding]; encoder=nil;
        int width=std::max(1,int(std::round(renderRect.width*engine->renderScale)));
        int height=std::max(1,int(std::round(renderRect.height*engine->renderScale)));
        if (!worldColor || worldColor.width!=width || worldColor.height!=height) {
            auto desc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:layer.pixelFormat width:width height:height mipmapped:NO];
            desc.storageMode=MTLStorageModePrivate; desc.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;
            worldColor=[device newTextureWithDescriptor:desc];
            desc.pixelFormat=MTLPixelFormatDepth32Float; desc.usage=MTLTextureUsageRenderTarget;
            worldDepth=[device newTextureWithDescriptor:desc];
            if (!worldColor || !worldDepth) throw std::runtime_error("Metal: world target allocation failed");
        }
        worldPass=true; beginPass(true,true,vec4(0,0,0,1));
    }
    void EndWorld() override {
        worldRendering=false;
        if (!worldPass) return;
        flushDraws();
        [encoder endEncoding]; worldPass=false;
        beginPass(false,true);
        [encoder setViewport:MTLViewport{renderRect.x,renderRect.y,renderRect.width,renderRect.height,0,1}];
        [encoder setScissorRect:MTLScissorRect{NSUInteger(renderRect.x),NSUInteger(renderRect.y),NSUInteger(renderRect.width),NSUInteger(renderRect.height)}];
        [encoder setRenderPipelineState:compositePipeline];
        [encoder setDepthStencilState:depths.at(false)];
        [encoder setFragmentTexture:worldColor atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        if (current) SetSceneNode(current);
    }
    void SetSceneNode(SceneNode* frame) override {
        flushDraws();
        current=frame;
        float rz=std::tan(radians(frame->FovAngle)*0.5f),aspect=frame->FY/frame->FX;
        transform=mat4::scale(1,-1,1)*mat4::frustum(-rz,rz,-aspect*rz,aspect*rz,1,32768,handedness::left,clipzrange::zero_positive_w)*frame->WorldToView*frame->ObjectToWorld;
        if (encoder) {
            const double sx=worldPass ? double(worldColor.width)/renderRect.width : 1.0;
            const double sy=worldPass ? double(worldColor.height)/renderRect.height : 1.0;
            const double x=worldPass ? 0 : renderRect.x, y=worldPass ? 0 : renderRect.y;
            [encoder setViewport:MTLViewport{x+frame->XB*sx,y+frame->YB*sy,frame->X*sx,frame->Y*sy,0,1}];
            [encoder setScissorRect:MTLScissorRect{NSUInteger(x),NSUInteger(y),NSUInteger(worldPass ? worldColor.width : renderRect.width),NSUInteger(worldPass ? worldColor.height : renderRect.height)}];
        }
    }
    void DrawComplexSurface(SceneNode* frame,SurfaceInfo& surface,SurfaceFacet& facet) override {
        if (facet.VertexCount<3) return;
        if (current!=frame) SetSceneNode(frame);
        const bool fog=surface.FogMap && surface.FogMap->NumMips>0 && surface.FogMap->Mips && !surface.FogMap->Mips[0].Data.empty();
        TextureInfo* extra=fog ? surface.FogMap : !surface.FogMap && engine->renderdev->DetailTextures ? surface.DetailTexture : nullptr;
        Vertex* out=reserveDraw(size_t(facet.VertexCount-2)*3,surface.Texture,surface.LightMap,surface.PolyFlags,MTLPrimitiveTypeTriangle,extra,surface.MacroTexture,fog);
        if (!out) return;
        auto vertex=[&](uint32_t i) {
            auto p=facet.Vertices[i]; auto relative=p-facet.MapCoords.Origin;
            vec2 uv{dot(facet.MapCoords.XAxis,relative),dot(facet.MapCoords.YAxis,relative)},base{},light{};
            vec4 detail{},macro{};
            if (surface.Texture) base={(uv.x-surface.Texture->Pan.x)*GetUMult(*surface.Texture),(uv.y-surface.Texture->Pan.y)*GetVMult(*surface.Texture)};
            if (surface.LightMap) light={(uv.x-surface.LightMap->Pan.x+0.5f*surface.LightMap->UScale)*GetUMult(*surface.LightMap),(uv.y-surface.LightMap->Pan.y+0.5f*surface.LightMap->VScale)*GetVMult(*surface.LightMap)};
            if (extra) detail={(uv.x-extra->Pan.x+(fog ? 0.5f*extra->UScale : 0))*GetUMult(*extra),(uv.y-extra->Pan.y+(fog ? 0.5f*extra->VScale : 0))*GetVMult(*extra),0,0};
            if (surface.MacroTexture) macro={(uv.x-surface.MacroTexture->Pan.x)*GetUMult(*surface.MacroTexture),(uv.y-surface.MacroTexture->Pan.y)*GetVMult(*surface.MacroTexture),0,0};
            return Vertex{transform*vec4(p,1),vec4(1),base,light,detail,macro,{}};
        };
        Vertex first=vertex(0),previous=vertex(1);
        for (uint32_t i=2;i<facet.VertexCount;++i) {
            Vertex next=vertex(i); *out++=first; *out++=previous; *out++=next; previous=next;
        }
    }
    void DrawGouraudPolygon(SceneNode* frame,TextureInfo& info,const GouraudVertex* p,int count,uint32_t flags) override {
        if (count<3) return; if (current!=frame) SetSceneNode(frame);
        const bool fog=(flags&(PF_RenderFog|PF_Translucent|PF_Modulated))==PF_RenderFog;
        Vertex* out=reserveDraw(size_t(count-2)*3,&info,nullptr,flags,MTLPrimitiveTypeTriangle,nullptr,nullptr,false,fog);
        if (!out) return;
        auto vertex=[&](int i) { return Vertex{transform*vec4(p[i].Point,1),(flags&PF_Modulated) ? vec4(1) : vec4(p[i].Light,1),{p[i].UV.x*GetUMult(info),p[i].UV.y*GetVMult(info)},{},{},{},p[i].Fog}; };
        Vertex first=vertex(0),previous=vertex(1);
        for(int i=2;i<count;++i) {
            Vertex next=vertex(i); *out++=first; *out++=previous; *out++=next; previous=next;
        }
    }
    void DrawTile(SceneNode* frame,TextureInfo& info,float x,float y,float w,float h,float u,float v,float ul,float vl,float z,vec4 color,vec4,uint32_t flags) override {
        if (current!=frame) SetSceneNode(frame);
        if (flags&PF_Modulated) color=vec4(1);
        u*=GetUMult(info);ul*=GetUMult(info);v*=GetVMult(info);vl*=GetVMult(info);
        Vertex* out=reserveDraw(6,&info,nullptr,flags,MTLPrimitiveTypeTriangle,nullptr,nullptr,false,false,worldRendering);
        if (!out) return;
        out[0]={screen(x,y,z),color,{u,v},{}};
        out[1]={screen(x+w,y,z),color,{u+ul,v},{}};
        out[2]={screen(x+w,y+h,z),color,{u+ul,v+vl},{}};
        out[3]=out[0]; out[4]=out[2];
        out[5]={screen(x,y+h,z),color,{u,v+vl},{}};
    }
    void Draw3DLine(SceneNode* frame,vec4 color,uint32_t,vec3 a,vec3 b) override {
        if(current!=frame) SetSceneNode(frame);
        if (auto* out=reserveDraw(2,nullptr,nullptr,PF_Highlighted,MTLPrimitiveTypeLine)) {
            out[0]={transform*vec4(a,1),color,{},{}}; out[1]={transform*vec4(b,1),color,{},{}};
        }
    }
    void Draw2DLine(SceneNode* frame,vec4 color,uint32_t,vec3 a,vec3 b) override {
        if(current!=frame) SetSceneNode(frame);
        if (auto* out=reserveDraw(2,nullptr,nullptr,PF_Highlighted,MTLPrimitiveTypeLine)) {
            out[0]={screen(a.x,a.y,a.z),color,{},{}}; out[1]={screen(b.x,b.y,b.z),color,{},{}};
        }
    }
    void Draw2DPoint(SceneNode* frame,vec4 color,uint32_t,float x1,float y1,float x2,float y2,float z) override {
        TextureInfo empty;DrawTile(frame,empty,x1,y1,x2-x1,y2-y1,0,0,1,1,z,color,{},PF_Highlighted);
    }
    void ClearZ() override { if(encoder) { flushDraws(); [encoder endEncoding];beginPass(false,true); } }
    void PushHit(const uint8_t*,int) override { }
    void PopHit(int,bool) override { }
    void ReadPixels(TextureColor* pixels) override {
        if (!lastFrame || !pixels) return;
        [lastSubmitted waitUntilCompleted];
        if (lastSubmitted.error) throw std::runtime_error(lastSubmitted.error.localizedDescription.UTF8String);
        [lastFrame getBytes:pixels bytesPerRow:NSUInteger(lastFrameRect.width)*4 fromRegion:MTLRegionMake2D(lastFrameRect.x,lastFrameRect.y,lastFrameRect.width,lastFrameRect.height) mipmapLevel:0];
        for(size_t i=0;i<size_t(lastFrameRect.width)*size_t(lastFrameRect.height);++i) std::swap(pixels[i].R,pixels[i].B);
    }
    void EndFlash() override {
        if(!current || (flashScale==vec4(0.5f,0.5f,0.5f,0) && flashFog==vec4(0))) return;
        TextureInfo empty;vec4 color{flashFog.x,flashFog.y,flashFog.z,1-std::min(flashScale.x*2,1.0f)};
        DrawTile(current,empty,0,0,current->FX,current->FY,0,0,1,1,0,color,{},PF_Highlighted);
    }
    void PrecacheTexture(TextureInfo& info,uint32_t flags) override { texture(&info,flags&PF_Masked); }
    bool SupportsTextureFormat(TextureFormat f) override { auto u=GLTextureUploader::GetUploader(f);return u && (u->GetInternalformat()==GL_RGBA8 || u->GetInternalformat()==GL_RGBA32F); }
    void UpdateTextureRect(TextureInfo& info,int,int,int,int) override { flushDraws(); textures.erase({info.CacheID,false});textures.erase({info.CacheID,true}); }
};
}
std::unique_ptr<RenderDevice> CreateMetalRenderDevice(Widget* viewport) { return std::make_unique<MetalRenderDevice>(viewport); }
