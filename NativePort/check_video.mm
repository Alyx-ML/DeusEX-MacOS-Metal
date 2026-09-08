#include "../.porting/SurrealEngine/SurrealEngine/RenderDevice/Metal/MetalRenderDevice.mm"
#include "Engine.h"
#include "GameFolder.h"
#include "Package/PackageManager.h"
#include "Package/Package.h"
#include "Packages/Core/UClass.h"
#include "Packages/Engine/USurrealClient.h"
#include "Packages/Engine/Subsystems/USurrealRenderDevice.h"
#include "Utils/CommandLine.h"
#include "VM/ScriptCall.h"
#include <cassert>
#include <cstdio>

// Offscreen drawable: these checks never create or present a game window.
@interface VideoCheckDrawable : NSObject
@property(nonatomic,strong) id<MTLTexture> texture;
@end
@implementation VideoCheckDrawable
@end

namespace {
struct MetalRenderChecks {
    static void Run() {
        @autoreleasepool {
            auto layer=[CAMetalLayer layer]; layer.device=MTLCreateSystemDefaultDevice(); assert(layer.device);
            MetalRenderDevice renderer(layer);
            auto begin=[&](int width,int height,bool classic) {
                renderer.verticesByFrame[renderer.frameIndex].reset();
                renderer.worldPass=renderer.worldRendering=false;
                renderer.renderRect=GameWindow::FitRenderRect(width,height,classic);
                auto desc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:width height:height mipmapped:NO];
                desc.storageMode=MTLStorageModeShared; desc.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;
                auto drawable=[VideoCheckDrawable new]; drawable.texture=[layer.device newTextureWithDescriptor:desc];
                renderer.drawable=(id<CAMetalDrawable>)drawable;
                desc.pixelFormat=MTLPixelFormatDepth32Float; desc.storageMode=MTLStorageModePrivate; desc.usage=MTLTextureUsageRenderTarget;
                renderer.depth=[layer.device newTextureWithDescriptor:desc];
                renderer.prepareFrameColor();
                renderer.commands=[renderer.queue commandBuffer]; renderer.current=nullptr;
                renderer.beginPass(true,true,vec4(0,0,0,1));
                SceneNode frame{};
                frame.X=frame.FX=renderer.renderRect.width; frame.Y=frame.FY=renderer.renderRect.height;
                frame.FovAngle=90; frame.ObjectToWorld=frame.WorldToView=mat4::identity();
                return frame;
            };
            auto finish=[&]() {
                renderer.Unlock(false);
                std::vector<TextureColor> pixels(size_t(renderer.lastFrameRect.width*renderer.lastFrameRect.height));
                renderer.ReadPixels(pixels.data()); return pixels;
            };
            auto solid=[](UnrealMipmap& mip,TextureInfo& info,uint8_t gray,uint64_t id) {
                mip.Width=mip.Height=1; mip.Data={gray,gray,gray,255};
                info.CacheID=id; info.Format=TextureFormat::BGRA8; info.Mips=&mip; info.NumMips=1;
            };
            UnrealMipmap baseMip,macroMip,fogMip;
            TextureInfo base,macro,fog;
            solid(baseMip,base,100,10001); solid(macroMip,macro,128,10002);
            fogMip.Width=fogMip.Height=1; fogMip.Data.resize(16);
            float fogColor[]={0.2f,0.1f,0.0f,0.5f}; memcpy(fogMip.Data.data(),fogColor,16);
            fog.CacheID=10003; fog.Format=TextureFormat::RGBA32_F; fog.Mips=&fogMip; fog.NumMips=1;
            auto checkRGB=[](TextureColor c,int r,int g,int b) {
                assert(std::abs(int(c.R)-r)<=1 && std::abs(int(c.G)-g)<=1 && std::abs(int(c.B)-b)<=1);
            };
            vec3 points[]={{-10,-10,10},{30,-10,10},{-10,30,10}};
            SurfaceFacet facet{}; facet.Vertices=points; facet.VertexCount=3;
            SurfaceInfo surface; surface.Texture=&base;
            for (bool useMacro : {false,true}) for (bool useFog : {false,true}) {
                auto frame=begin(16,12,false);
                surface.MacroTexture=useMacro ? &macro : nullptr; surface.FogMap=useFog ? &fog : nullptr;
                // Fog must take precedence even with detail textures enabled.
                surface.DetailTexture=&macro; engine->renderdev->DetailTextures=useFog;
                renderer.DrawComplexSurface(&frame,surface,facet);
                auto pixels=finish(); float c=useMacro ? 100*128.0f/255 : 100;
                checkRGB(pixels[6*16+8],std::round(useFog ? 51+c*0.5f : c),std::round(useFog ? 25.5f+c*0.5f : c),std::round(useFog ? c*0.5f : c));
            }
            for (uint32_t flags : {uint32_t(PF_RenderFog),uint32_t(PF_RenderFog|PF_Translucent),uint32_t(PF_RenderFog|PF_Modulated)}) {
                auto frame=begin(16,12,false);
                GouraudVertex vertices[3];
                for (int i=0;i<3;++i) vertices[i]={points[i],vec3(1),{},vec4(.2f,.1f,0,.5f)};
                renderer.DrawGouraudPolygon(&frame,base,vertices,3,flags);
                auto pixels=finish();
                if (flags==PF_RenderFog) checkRGB(pixels[6*16+8],101,76,50);
                else if (flags&PF_Translucent) checkRGB(pixels[6*16+8],100,100,100);
                else checkRGB(pixels[6*16+8],0,0,0);
            }
            // Nonuniform maps expose UV pan/scale and half-texel alignment errors.
            macroMip.Width=macroMip.Height=2; macroMip.Data={0,0,0,255,128,128,128,255,0,0,0,255,0,0,0,255};
            macro.USize=macro.VSize=2; macro.Pan={-1.5f,-.5f}; macro.bRealtimeChanged=true;
            fogMip.Width=fogMip.Height=2; fogMip.Data.resize(64); memset(fogMip.Data.data(),0,64); memcpy(fogMip.Data.data(),fogColor,16);
            fog.USize=fog.VSize=2; fog.bRealtimeChanged=true;
            auto mappedFrame=begin(16,12,false); surface.MacroTexture=&macro; surface.FogMap=&fog;
            renderer.DrawComplexSurface(&mappedFrame,surface,facet);
            checkRGB(finish()[6*16+8],76,51,25);
            puts("PASS: actual Metal surface macro/fog, UV alignment, fog-detail precedence and mesh fog blend exclusions");

            UnrealMipmap mips[3]; TextureInfo mipInfo; mipInfo.CacheID=10004; mipInfo.Format=TextureFormat::BGRA8; mipInfo.Mips=mips; mipInfo.NumMips=3; mipInfo.USize=mipInfo.VSize=4;
            for (int i=0;i<3;++i) {
                mips[i].Width=mips[i].Height=4>>i; mips[i].Data.resize(size_t(mips[i].Width*mips[i].Height)*4);
                for (size_t j=0;j<mips[i].Data.size();j+=4) { mips[i].Data[j+(2-i)]=255; mips[i].Data[j+3]=255; }
            }
            auto uploaded=UploadMetalTexture(layer.device,mipInfo,0,false); assert(uploaded.mipmapLevelCount==3);
            for (int i=0;i<3;++i) {
                std::vector<uint8_t> pixels(mips[i].Data.size());
                [uploaded getBytes:pixels.data() bytesPerRow:size_t(mips[i].Width)*4 fromRegion:MTLRegionMake2D(0,0,mips[i].Width,mips[i].Height) mipmapLevel:i];
                assert(memcmp(pixels.data(),mips[i].Data.data(),pixels.size())==0);
            }
            auto lower=UploadMetalTexture(layer.device,mipInfo,1,false); assert(lower.width==2 && lower.mipmapLevelCount==2);
            auto frame=begin(16,12,false);
            GouraudVertex triangle[3];
            for(int i=0;i<3;++i) triangle[i]={points[i],vec3(1),{i==1 ? 512.0f : 0,i==2 ? 512.0f : 0},{}};
            renderer.DrawGouraudPolygon(&frame,mipInfo,triangle,3,0);
            checkRGB(finish()[6*16+8],0,0,255);
            // UI keeps the base mip even when its UV range is strongly minified.
            frame=begin(16,12,false);
            renderer.DrawTile(&frame,mipInfo,0,0,16,12,0,0,512,512,1,vec4(1),{},0);
            checkRGB(finish()[6*16+8],255,0,0);
            mips[1].Width=3;
            bool rejected=false; try { UploadMetalTexture(layer.device,mipInfo,0,false); } catch(const std::runtime_error&) { rejected=true; } assert(rejected);
            mips[1].Width=2; mips[2].Data.clear(); rejected=false;
            try { UploadMetalTexture(layer.device,mipInfo,0,false); } catch(const std::runtime_error&) { rejected=true; } assert(rejected);
            puts("PASS: authored mip uploads, quality base mip, GPU minification, UI mip exclusion and malformed mip rejection");

            id<MTLBuffer> initial[2]={renderer.verticesByFrame[0].chunks[0],renderer.verticesByFrame[1].chunks[0]};
            for (int iteration=0;iteration<12;++iteration) {
                bool classic=iteration%2; engine->renderScale=iteration%3==0 ? .5f : iteration%3==1 ? .75f : 1.0f;
                frame=begin(16,9,classic); renderer.SetSceneNode(&frame); renderer.BeginWorld();
                if (engine->renderScale<1) {
                    assert(renderer.worldColor.width==std::round(frame.X*engine->renderScale));
                    assert(renderer.worldColor.height==std::round(frame.Y*engine->renderScale));
                } else assert(!renderer.worldPass);
                renderer.DrawTile(&frame,base,0,0,frame.X,frame.Y,0,0,1,1,1,vec4(1),{},0);
                renderer.EndWorld(); assert(!renderer.worldPass);
                TextureInfo empty;
                renderer.DrawTile(&frame,empty,7,5,1,1,0,0,1,1,0,vec4(1),{},PF_NoSmooth);
                auto pixels=finish(); assert(pixels.size()==size_t(frame.X*frame.Y));
                if (classic) {
                    uint8_t full[16*9*4];
                    [renderer.lastFrame getBytes:full bytesPerRow:16*4 fromRegion:MTLRegionMake2D(0,0,16,9) mipmapLevel:0];
                    assert(full[(4*16)*4]==0 && full[(4*16+15)*4]==0);
                }
                checkRGB(pixels[5*frame.X+7],255,255,255);
                checkRGB(pixels[5*frame.X+6],100,100,100); checkRGB(pixels[5*frame.X+8],100,100,100);
                assert(renderer.verticesByFrame[0].chunks[0]==initial[0]); assert(renderer.verticesByFrame[1].chunks[0]==initial[1]);
            }
            engine->renderScale=1;
            FrameVertices arena;
            std::vector<uint8_t> payload(1024*1024,42);
            auto first=arena.reserve(layer.device,payload.size());
            memcpy(first.first.contents,payload.data(),payload.size());
            auto second=arena.reserve(layer.device,payload.size());
            assert(first.first!=second.first && first.second==0 && second.second==0);
            assert(memcmp(first.first.contents,payload.data(),payload.size())==0);
            arena.reset(); auto reused=arena.reserve(layer.device,17);
            assert(reused.first==first.first && reused.second==0);
            auto aligned=arena.reserve(layer.device,1); assert(aligned.second==32);
            puts("PASS: 50/75/100% world scaling, one-pixel native HUD, screenshot dimensions, two-frame buffer reuse and chunk overflow");
            // Compare the actual batched encoder with forced per-draw submission.
            std::vector<TextureColor> reference;
            for (bool immediate : {true,false}) {
                frame=begin(16,16,false); TextureInfo empty;
                for (int i=0;i<64;++i) {
                    renderer.DrawTile(&frame,empty,(i%8)*2,(i/8)*2,2,2,0,0,1,1,1,vec4(float(i)/63,0.25f,0.75f,1),{},0);
                    if (immediate) renderer.flushDraws();
                }
                auto pixels=finish(); assert(renderer.drawCalls==(immediate ? 64 : 1));
                if (immediate) reference=pixels;
                else assert(memcmp(reference.data(),pixels.data(),pixels.size()*sizeof(TextureColor))==0);
            }
            for (bool immediate : {true,false}) {
                frame=begin(16,12,false); TextureInfo empty;
                for (vec4 color : {vec4(.5f,0,0,.5f),vec4(0,0,.5f,.5f)}) {
                    renderer.DrawTile(&frame,empty,0,0,16,12,0,0,1,1,1,color,{},PF_Highlighted);
                    if (immediate) renderer.flushDraws();
                }
                auto pixels=finish(); checkRGB(pixels[6*16+8],64,0,128);
                assert(renderer.drawCalls==(immediate ? 2 : 1));
            }
            frame=begin(16,12,false);
            renderer.DrawTile(&frame,base,0,0,16,12,0,0,1,1,1,vec4(1),{},0);
            renderer.ClearZ(); assert(renderer.drawCalls==1);
            renderer.DrawTile(&frame,base,0,0,8,12,0,0,1,1,1,vec4(1),{},0);
            renderer.SetSceneNode(&frame); assert(renderer.drawCalls==2);
            renderer.DrawTile(&frame,base,0,0,8,12,0,0,1,1,1,vec4(1),{},0);
            renderer.UpdateTextureRect(base,0,0,1,1); assert(renderer.drawCalls==3);
            baseMip.Data={200,200,200,255};
            renderer.DrawTile(&frame,base,8,0,8,12,0,0,1,1,1,vec4(1),{},0);
            auto split=finish(); checkRGB(split[6*16+4],100,100,100); checkRGB(split[6*16+12],200,200,200);
            baseMip.Data={100,100,100,255}; renderer.UpdateTextureRect(base,0,0,1,1);
            frame=begin(16,12,false); TextureInfo empty;
            for (int i=0;i<2000;++i) renderer.DrawTile(&frame,empty,0,0,16,12,0,0,1,1,1,vec4(1),{},0);
            checkRGB(finish()[6*16+8],255,255,255); assert(renderer.drawCalls==2);
            puts("PASS: 64 compatible draws -> 1 with identical pixels, transparent order, state/update boundaries and batch chunk rollover");

            for (float brightness : {.25f,.5f,.75f,1.0f,-1.0f,5.0f,std::numeric_limits<float>::quiet_NaN()}) {
                renderer.Brightness=brightness; engine->renderScale=.5f;
                frame=begin(16,9,true); renderer.SetSceneNode(&frame); renderer.BeginWorld();
                renderer.DrawTile(&frame,base,0,0,frame.X,frame.Y,0,0,1,1,1,vec4(1),{},0);
                renderer.EndWorld();
                renderer.DrawTile(&frame,empty,7,5,1,1,0,0,1,1,0,vec4(1),{},0);
                auto pixels=finish();
                float b=std::isfinite(brightness) ? std::clamp(brightness*2,.05f,2.99f) : 1;
                int expected=std::round(255*std::pow(100.0f/255,1/b));
                checkRGB(pixels[5*frame.X+6],expected,expected,expected); checkRGB(pixels[5*frame.X+7],255,255,255);
                uint8_t full[16*9*4];
                [renderer.lastFrame getBytes:full bytesPerRow:16*4 fromRegion:MTLRegionMake2D(0,0,16,9) mipmapLevel:0];
                assert(full[(4*16)*4]==0 && full[(4*16+15)*4]==0);
            }
            renderer.Brightness=.75f; engine->renderScale=1;
            frame=begin(16,12,false);
            renderer.DrawTile(&frame,empty,0,0,16,12,0,0,1,1,1,vec4(.5f,0,0,.5f),{},PF_Highlighted);
            renderer.DrawTile(&frame,empty,0,0,16,12,0,0,1,1,1,vec4(0,0,.5f,.5f),{},PF_Highlighted);
            checkRGB(finish()[6*16+8],std::round(255*std::pow(64.0f/255,2.0f/3)),0,std::round(255*std::pow(128.0f/255,2.0f/3)));
            renderer.Brightness=.5f;
            puts("PASS: live brightness/gamma, neutral identity, invalid setting handling, native HUD/bars/screenshots and correction after blending");

        }
    }
};
}

static void CheckMetalPixels()
{
    assert(GameWindow::FitRenderRect(1920,1080,true)==Rect(240,0,1440,1080));
    assert(GameWindow::FitRenderRect(3200,2000,true)==Rect(268,1,2664,1998));
    assert(GameWindow::FitRenderRect(900,1600,true)==Rect(0,462,900,675));
    assert(GameWindow::FitRenderRect(1920,1080,false)==Rect(0,0,1920,1080));
    assert(GameWindow::FitRenderRect(0,0,true)==Rect(0,0,1,1));
    @autoreleasepool {
        id<MTLDevice> gpu=MTLCreateSystemDefaultDevice(); assert(gpu);
        NSError* error=nil;
        auto library=[gpu newLibraryWithSource:[NSString stringWithUTF8String:source] options:nil error:&error];
        if (!library) { fprintf(stderr,"%s\n",error.localizedDescription.UTF8String); std::abort(); }
        auto pipelineDesc=[MTLRenderPipelineDescriptor new];
        pipelineDesc.vertexFunction=[library newFunctionWithName:@"mainVS"];
        pipelineDesc.fragmentFunction=[library newFunctionWithName:@"mainPS"];
        pipelineDesc.colorAttachments[0].pixelFormat=MTLPixelFormatRGBA8Unorm;
        auto pipeline=[gpu newRenderPipelineStateWithDescriptor:pipelineDesc error:&error]; assert(pipeline);
        auto texture=[&](int w,int h) {
            auto desc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:w height:h mipmapped:NO];
            desc.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead; desc.storageMode=MTLStorageModeShared;
            return [gpu newTextureWithDescriptor:desc];
        };
        auto target=texture(16,9), base=texture(1,1), detail=texture(1,1);
        uint8_t gray[4]={100,100,100,255}, white[4]={255,255,255,255};
        [base replaceRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0 withBytes:gray bytesPerRow:4];
        [detail replaceRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0 withBytes:white bytesPerRow:4];
        auto sampler=[gpu newSamplerStateWithDescriptor:[MTLSamplerDescriptor new]];
        auto queue=[gpu newCommandQueue];
        for (bool classic : {false,true}) for (bool enabled : {false,true}) for (float distance : {100.0f,1000.0f}) {
            auto command=[queue commandBuffer];
            auto pass=[MTLRenderPassDescriptor renderPassDescriptor];
            pass.colorAttachments[0].texture=target; pass.colorAttachments[0].loadAction=MTLLoadActionClear;
            pass.colorAttachments[0].storeAction=MTLStoreActionStore; pass.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,1);
            auto encoder=[command renderCommandEncoderWithDescriptor:pass];
            Rect rect=GameWindow::FitRenderRect(16,9,classic);
            [encoder setViewport:MTLViewport{rect.x,rect.y,rect.width,rect.height,0,1}];
            [encoder setScissorRect:MTLScissorRect{NSUInteger(rect.x),NSUInteger(rect.y),NSUInteger(rect.width),NSUInteger(rect.height)}];
            Vertex vertices[]={{{-distance,-distance,0,distance},vec4(1),{},{},{}},{{3*distance,-distance,0,distance},vec4(1),{},{},{}},{{-distance,3*distance,0,distance},vec4(1),{},{},{}}};
            DrawFlags flags{0,enabled ? 2u : 0u};
            [encoder setRenderPipelineState:pipeline];
            [encoder setVertexBytes:vertices length:sizeof(vertices) atIndex:0];
            [encoder setFragmentBytes:&flags length:sizeof(flags) atIndex:0];
            [encoder setFragmentTexture:base atIndex:0]; [encoder setFragmentTexture:detail atIndex:1]; [encoder setFragmentTexture:detail atIndex:2]; [encoder setFragmentTexture:detail atIndex:3];
            [encoder setFragmentSamplerState:sampler atIndex:0]; [encoder setFragmentSamplerState:sampler atIndex:1];
            [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            [encoder endEncoding]; [command commit]; [command waitUntilCompleted]; assert(!command.error);
            uint8_t pixels[16*9*4];
            [target getBytes:pixels bytesPerRow:16*4 fromRegion:MTLRegionMake2D(0,0,16,9) mipmapLevel:0];
            int expected=enabled && distance==100 ? 140 : 100;
            assert(std::abs(int(pixels[(4*16+8)*4])-expected)<=1);
            assert(pixels[(4*16)*4]==(classic ? 0 : expected));
            assert(pixels[(4*16+15)*4]==(classic ? 0 : expected));
        }
    }
    puts("PASS: offscreen Metal detail on/off + distance fade, 4:3 bars, widescreen and viewport fitting"); fflush(stdout);
}

int main(int argc, char** argv)
{
    assert(argc == 2);
    CommandLine cmd({argv[0], argv[1]}); commandline = &cmd;
    GameFolderSelection::UpdateList();
    auto* game = new Engine(GameFolderSelection::GetLaunchInfo(0));
    game->LoadEngineSettings();
    auto* transient = game->packages->GetTransientPackage();
    auto make = [&](const char* name, const char* cls) { return transient->NewObject(name, game->packages->FindClass(cls), ObjectFlags::Transient); };
    auto* player = make("video-player", "DeusEx.DeusExPlayer");
    for (const char* cls : {"DeusEx.MenuChoice_WorldTextureDetail", "DeusEx.MenuChoice_ObjectTextureDetail", "DeusEx.MenuChoice_DetailTextures"}) {
        auto* choice = make(cls, cls);
        choice->SetObject("player", player);
        choice->SetObject("btnInfo", make("video-button", "DeusEx.MenuUIInfoButtonWindow"));
        printf("Checking original menu: %s -> %s\n", cls, choice->GetString("configSetting").c_str()); fflush(stdout);
        choice->SetInt("currentValue", 0);
        for (int iteration=0; iteration<4; ++iteration) {
            CallEvent(choice, "CycleNextValue");
            int selected = choice->GetInt("currentValue");
            CallEvent(choice, "SaveSetting");
            CallEvent(choice, "LoadSetting");
            assert(choice->GetInt("currentValue") == selected);
        }
    }
    game->renderdev->SetPropertyFromString("DetailTextures", "False");
    game->renderdev->SaveConfig();
    game->packages->SaveAllIniFiles();
    IniFile persisted((fs::path(argv[1])/"System/SE-DeusEx.ini").string());
    assert(persisted.GetValue("Engine.SurrealRenderDevice", "DetailTextures") == "False");
    game->renderdev->DetailTextures = true;
    game->renderdev->LoadProperties();
    assert(!game->renderdev->DetailTextures);
    auto* tex = UObject::Cast<UTexture>(make("video-texture", "Engine.Texture"));
    TextureInfo info; info.Texture=tex; info.NumMips=3;
    tex->LODSet()=1;
    game->client->TextureDetail="High"; assert(TextureBaseMip(info,*game->client)==0);
    game->client->TextureDetail="Medium"; assert(TextureBaseMip(info,*game->client)==1);
    game->client->TextureDetail="Low"; assert(TextureBaseMip(info,*game->client)==2);
    tex->LODSet()=2; game->client->SkinDetail="Low"; assert(TextureBaseMip(info,*game->client)==1);
    tex->LODSet()=0; assert(TextureBaseMip(info,*game->client)==0);
    info.NumMips=1; tex->LODSet()=1; assert(TextureBaseMip(info,*game->client)==0);
    puts("PASS: original texture menus, saved Detail Textures toggle, world/skin mip quality and UI exclusion"); fflush(stdout);
    CheckMetalPixels();
    MetalRenderChecks::Run();
    fflush(stdout);
    std::_Exit(0);
}
