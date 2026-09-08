#include "Precomp.h"
#include "Engine.h"
#include "Packages/Engine/USurrealClient.h"
#include "Packages/Engine/Subsystems/USurrealRenderDevice.h"
#include <deque>
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
struct Vertex { vec4 position,color; vec2 uv,lm; vec4 detail; };
struct DrawFlags { uint32_t poly, textures; };
static_assert(sizeof(Vertex)==64);

int TextureBaseMip(const TextureInfo& info, const USurrealClient& client)
{
    if (!info.Texture || info.NumMips <= 1) return 0;
    const auto lod = info.Texture->LODSet();
    const NameString quality = lod == 1 ? client.TextureDetail : lod == 2 ? client.SkinDetail : "High";
    const int level = quality == "Low" ? (lod == 2 ? 1 : 2) : quality == "Medium" ? 1 : 0;
    return std::min(level, info.NumMips - 1);
}
const char* source=R"(
#include <metal_stdlib>
using namespace metal;
struct V { float4 position,color; float2 uv,lm; float4 detail; };
struct DrawFlags { uint poly, textures; };
struct Out { float4 position [[position]]; float4 color; float2 uv,lm,detail; };
vertex Out mainVS(uint i [[vertex_id]],const device V* v [[buffer(0)]]) {
    return {v[i].position,v[i].color,v[i].uv,v[i].lm,v[i].detail.xy};
}
fragment float4 mainPS(Out v [[stage_in]],texture2d<float> tex [[texture(0)]],texture2d<float> light [[texture(1)]],texture2d<float> detail [[texture(2)]],sampler s [[sampler(0)]],constant DrawFlags& flags [[buffer(0)]]) {
    float4 c=tex.sample(s,v.uv);
    if ((flags.poly&2) && c.a<0.5) discard_fragment();
    c*=v.color;
    if (flags.textures&1) c.rgb*=light.sample(s,v.lm).rgb*2.0;
    if (flags.textures&2) {
        float fade=clamp(2.0f-(1.0f/v.position.w)/380.0f,0.0f,1.0f);
        float3 detailColor=(detail.sample(s,v.detail).rgb-0.5f)*0.8f+1.0f;
        c.rgb=mix(c.rgb,c.rgb*detailColor,fade);
    }
    return c;
})";
class MetalRenderDevice final : public RenderDevice {
    id<MTLDevice> device;
    id<MTLCommandQueue> queue;
    id<MTLLibrary> library;
    CAMetalLayer* layer;
    id<CAMetalDrawable> drawable;
    id<MTLCommandBuffer> commands, lastSubmitted;
    std::deque<id<MTLCommandBuffer>> inFlight;
    id<MTLRenderCommandEncoder> encoder;
    id<MTLTexture> depth,white,lastFrame;
    id<MTLSamplerState> sampler,nearest;
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
        auto uploader=GLTextureUploader::GetUploader(info->Format);
        if (!uploader || (uploader->GetInternalformat()!=GL_RGBA8 && uploader->GetInternalformat()!=GL_RGBA32F))
            throw std::runtime_error("Metal: unsupported texture format "+std::to_string(uint32_t(info->Format)));
        auto& mip=info->Mips[baseMip];
        if (mip.Width<=0 || mip.Height<=0 || mip.Width>16384 || mip.Height>16384) throw std::runtime_error("Metal: invalid texture dimensions");
        const size_t pixelSize=info->Format==TextureFormat::RGBA32_F ? 16 : 4;
        const size_t inputSize=info->Format==TextureFormat::P8 ? 1 : info->Format==TextureFormat::RGB8 ? 3 : pixelSize;
        if (mip.Data.size()<size_t(mip.Width)*mip.Height*inputSize || (info->Format==TextureFormat::P8 && !info->Palette)) throw std::runtime_error("Metal: truncated texture");
        std::vector<uint8_t> pixels(size_t(mip.Width)*mip.Height*pixelSize);
        uploader->UploadRect(pixels.data(),&mip,0,0,mip.Width,mip.Height,info->Palette,masked);
        const auto format=info->Format==TextureFormat::BGRA8 ? MTLPixelFormatBGRA8Unorm : info->Format==TextureFormat::RGBA32_F ? MTLPixelFormatRGBA32Float : MTLPixelFormatRGBA8Unorm;
        auto desc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:mip.Width height:mip.Height mipmapped:NO];
        desc.storageMode=MTLStorageModeShared;
        id<MTLTexture> result=[device newTextureWithDescriptor:desc];
        if (!result) throw std::runtime_error("Metal: texture allocation failed");
        [result replaceRegion:MTLRegionMake2D(0,0,mip.Width,mip.Height) mipmapLevel:0 withBytes:pixels.data() bytesPerRow:size_t(mip.Width)*pixelSize];
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
        pass.colorAttachments[0].texture=drawable.texture;
        pass.colorAttachments[0].loadAction=clearColor ? MTLLoadActionClear : MTLLoadActionLoad;
        pass.colorAttachments[0].storeAction=MTLStoreActionStore;
        pass.colorAttachments[0].clearColor=MTLClearColorMake(color.x,color.y,color.z,color.w);
        pass.depthAttachment.texture=depth;
        pass.depthAttachment.loadAction=clearDepth ? MTLLoadActionClear : MTLLoadActionLoad;
        pass.depthAttachment.storeAction=MTLStoreActionStore; pass.depthAttachment.clearDepth=1;
        encoder=[commands renderCommandEncoderWithDescriptor:pass];
        [encoder setCullMode:MTLCullModeNone];
        if (current) SetSceneNode(current);
    }
    void draw(const std::vector<Vertex>& vertices,TextureInfo* tex,TextureInfo* lm,uint32_t flags,MTLPrimitiveType primitive=MTLPrimitiveTypeTriangle,TextureInfo* detail=nullptr) {
        if (!encoder || vertices.empty()) return;
        if (flags&PF_Translucent) flags&=~PF_Masked;
        id<MTLRenderPipelineState> state=pipeline(flags);
        if (!state) throw std::runtime_error("Metal: missing cached pipeline "+std::to_string(flags));
        const bool writes=!(flags&(PF_Translucent|PF_Modulated)) || (flags&PF_Occlude);
        [encoder setDepthStencilState:depths.at(writes)];
        auto buffer=[device newBufferWithBytes:vertices.data() length:vertices.size()*sizeof(Vertex) options:MTLResourceStorageModeShared];
        if (!buffer) throw std::runtime_error("Metal: vertex allocation failed");
        [encoder setVertexBuffer:buffer offset:0 atIndex:0];
        [encoder setFragmentTexture:texture(tex,flags&PF_Masked) atIndex:0];
        [encoder setFragmentTexture:texture(lm) atIndex:1];
        [encoder setFragmentTexture:texture(detail) atIndex:2];
        DrawFlags drawFlags{flags, (lm ? 1u : 0u) | (detail ? 2u : 0u)};
        [encoder setFragmentBytes:&drawFlags length:sizeof(drawFlags) atIndex:0];
        [encoder setFragmentSamplerState:(flags&PF_NoSmooth) ? nearest : sampler atIndex:0];
        [encoder setRenderPipelineState:state];
        [encoder drawPrimitives:primitive vertexStart:0 vertexCount:vertices.size()];
    }
    static std::vector<Vertex> fan(const std::vector<Vertex>& points) {
        std::vector<Vertex> result;
        for (size_t i=2;i<points.size();++i) { result.push_back(points[0]);result.push_back(points[i-1]);result.push_back(points[i]); }
        return result;
    }
    vec4 screen(float x,float y,float z) const {
        if (!current) throw std::runtime_error("Metal: no scene node");
        return {2*x/current->FX-1,1-2*y/current->FY,std::clamp(z/32768.0f,0.0f,1.0f),1};
    }
public:
    explicit MetalRenderDevice(Widget* viewport) {
        Viewport=viewport;
        auto handle=static_cast<CocoaNativeHandle*>(viewport->GetNativeHandle());
        layer=(__bridge CAMetalLayer*)handle->metalLayer;
        if (!layer) throw std::runtime_error("Metal: no native layer");
        device=layer.device ?: MTLCreateSystemDefaultDevice(); layer.device=device;
        layer.pixelFormat=MTLPixelFormatBGRA8Unorm; layer.framebufferOnly=NO;
        queue=[device newCommandQueue];
        NSError* error=nil; library=[device newLibraryWithSource:[NSString stringWithUTF8String:source] options:nil error:&error];
        if (!library) throw std::runtime_error(error.localizedDescription.UTF8String);
        auto sd=[MTLSamplerDescriptor new]; sd.sAddressMode=sd.tAddressMode=MTLSamplerAddressModeRepeat;
        sd.minFilter=sd.magFilter=MTLSamplerMinMagFilterLinear; sampler=[device newSamplerStateWithDescriptor:sd];
        sd.minFilter=sd.magFilter=MTLSamplerMinMagFilterNearest; nearest=[device newSamplerStateWithDescriptor:sd];
        for (bool write:{false,true}) { auto d=[MTLDepthStencilDescriptor new]; d.depthCompareFunction=MTLCompareFunctionLessEqual; d.depthWriteEnabled=write; depths[write]=[device newDepthStencilStateWithDescriptor:d]; }
        white=[device newTextureWithDescriptor:[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:1 height:1 mipmapped:NO]];
        uint32_t pixel=0xffffffff; [white replaceRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0 withBytes:&pixel bytesPerRow:4];
        fprintf(stderr,"Native ARM64 Metal backend: %s\n",device.name.UTF8String);
    }
    void Flush(bool) override { textures.clear(); }
    void Lock(vec4 scale,vec4 fog,vec4 clear,uint8_t* hits,int* hitSize) override {
        if (hits && hitSize) *hitSize=0;
        flashScale=scale;flashFog=fog;
        if (inFlight.size() >= 2) {
            auto oldest = inFlight.front();
            [oldest waitUntilCompleted];
            if (oldest.error) throw std::runtime_error(oldest.error.localizedDescription.UTF8String);
            inFlight.pop_front();
        }
        renderRect=engine->window->GetRenderRect();
        layer.drawableSize=CGSizeMake(std::max(1, (int)std::round(engine->window->GetNativePixelWidth()*engine->renderScale)),
            std::max(1, (int)std::round(engine->window->GetNativePixelHeight()*engine->renderScale)));
        drawable=[layer nextDrawable]; if (!drawable) return;
        auto t=drawable.texture;
        if (!depth || depth.width!=t.width || depth.height!=t.height) {
            auto desc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:t.width height:t.height mipmapped:NO];
            desc.storageMode=MTLStorageModePrivate; desc.usage=MTLTextureUsageRenderTarget; depth=[device newTextureWithDescriptor:desc];
        }
        commands=[queue commandBuffer]; current=nullptr; beginPass(true,true,engine->classicAspectRatio ? vec4(0,0,0,1) : clear);
    }
    void Unlock(bool blit) override {
        if (!commands) return;
        [encoder endEncoding]; encoder=nil;
        lastFrame=drawable.texture; lastFrameRect=renderRect;
        if (blit) [commands presentDrawable:drawable];
        [commands commit];
        inFlight.push_back(commands);
        lastSubmitted = commands;
        if (!frameReported) { fprintf(stderr,"Metal frame submitted: %lux%lu; display sync; at most two GPU frames in flight\n",(unsigned long)lastFrame.width,(unsigned long)lastFrame.height);frameReported=true; }
        commands=nil;drawable=nil;current=nullptr;
    }
    void SetSceneNode(SceneNode* frame) override {
        current=frame;
        float rz=std::tan(radians(frame->FovAngle)*0.5f),aspect=frame->FY/frame->FX;
        transform=mat4::scale(1,-1,1)*mat4::frustum(-rz,rz,-aspect*rz,aspect*rz,1,32768,handedness::left,clipzrange::zero_positive_w)*frame->WorldToView*frame->ObjectToWorld;
        if (encoder) {
            [encoder setViewport:MTLViewport{renderRect.x+frame->XB,renderRect.y+frame->YB,double(frame->X),double(frame->Y),0,1}];
            [encoder setScissorRect:MTLScissorRect{NSUInteger(renderRect.x),NSUInteger(renderRect.y),NSUInteger(renderRect.width),NSUInteger(renderRect.height)}];
        }
    }
    void DrawComplexSurface(SceneNode* frame,SurfaceInfo& surface,SurfaceFacet& facet) override {
        if (facet.VertexCount<3) return;
        if (current!=frame) SetSceneNode(frame);
        std::vector<Vertex> points;
        for (uint32_t i=0;i<facet.VertexCount;++i) {
            auto p=facet.Vertices[i]; auto relative=p-facet.MapCoords.Origin;
            vec2 uv{dot(facet.MapCoords.XAxis,relative),dot(facet.MapCoords.YAxis,relative)},base{},light{};
            vec4 detail{};
            if (surface.Texture) base={(uv.x-surface.Texture->Pan.x)*GetUMult(*surface.Texture),(uv.y-surface.Texture->Pan.y)*GetVMult(*surface.Texture)};
            if (surface.LightMap) light={(uv.x-surface.LightMap->Pan.x+0.5f*surface.LightMap->UScale)*GetUMult(*surface.LightMap),(uv.y-surface.LightMap->Pan.y+0.5f*surface.LightMap->VScale)*GetVMult(*surface.LightMap)};
            if (surface.DetailTexture) detail={(uv.x-surface.DetailTexture->Pan.x)*GetUMult(*surface.DetailTexture),(uv.y-surface.DetailTexture->Pan.y)*GetVMult(*surface.DetailTexture),0,0};
            points.push_back({transform*vec4(p,1),vec4(1),base,light,detail});
        }
        draw(fan(points),surface.Texture,surface.LightMap,surface.PolyFlags,MTLPrimitiveTypeTriangle,
            engine->renderdev->DetailTextures ? surface.DetailTexture : nullptr);
    }
    void DrawGouraudPolygon(SceneNode* frame,TextureInfo& info,const GouraudVertex* p,int count,uint32_t flags) override {
        if (count<3) return; if (current!=frame) SetSceneNode(frame);
        std::vector<Vertex> points;
        for(int i=0;i<count;++i) points.push_back({transform*vec4(p[i].Point,1),(flags&PF_Modulated) ? vec4(1) : vec4(p[i].Light,1),{p[i].UV.x*GetUMult(info),p[i].UV.y*GetVMult(info)},vec2(0)});
        draw(fan(points),&info,nullptr,flags);
    }
    void DrawTile(SceneNode* frame,TextureInfo& info,float x,float y,float w,float h,float u,float v,float ul,float vl,float z,vec4 color,vec4,uint32_t flags) override {
        if (current!=frame) SetSceneNode(frame);
        if (flags&PF_Modulated) color=vec4(1);
        u*=GetUMult(info);ul*=GetUMult(info);v*=GetVMult(info);vl*=GetVMult(info);
        std::vector<Vertex> p={{screen(x,y,z),color,{u,v},{}},{screen(x+w,y,z),color,{u+ul,v},{}},{screen(x+w,y+h,z),color,{u+ul,v+vl},{}},{screen(x,y+h,z),color,{u,v+vl},{}}};
        draw(fan(p),&info,nullptr,flags);
    }
    void Draw3DLine(SceneNode* frame,vec4 color,uint32_t,vec3 a,vec3 b) override {
        if(current!=frame) SetSceneNode(frame);draw({{transform*vec4(a,1),color,{},{}},{transform*vec4(b,1),color,{},{}}},nullptr,nullptr,PF_Highlighted,MTLPrimitiveTypeLine);
    }
    void Draw2DLine(SceneNode* frame,vec4 color,uint32_t,vec3 a,vec3 b) override {
        if(current!=frame) SetSceneNode(frame);draw({{screen(a.x,a.y,a.z),color,{},{}},{screen(b.x,b.y,b.z),color,{},{}}},nullptr,nullptr,PF_Highlighted,MTLPrimitiveTypeLine);
    }
    void Draw2DPoint(SceneNode* frame,vec4 color,uint32_t,float x1,float y1,float x2,float y2,float z) override {
        TextureInfo empty;DrawTile(frame,empty,x1,y1,x2-x1,y2-y1,0,0,1,1,z,color,{},PF_Highlighted);
    }
    void ClearZ() override { if(encoder) { [encoder endEncoding];beginPass(false,true); } }
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
    void UpdateTextureRect(TextureInfo& info,int,int,int,int) override { textures.erase({info.CacheID,false});textures.erase({info.CacheID,true}); }
};
}
std::unique_ptr<RenderDevice> CreateMetalRenderDevice(Widget* viewport) { return std::make_unique<MetalRenderDevice>(viewport); }
