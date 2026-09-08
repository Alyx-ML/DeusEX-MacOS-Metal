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
            [encoder setFragmentTexture:base atIndex:0]; [encoder setFragmentTexture:detail atIndex:1]; [encoder setFragmentTexture:detail atIndex:2];
            [encoder setFragmentSamplerState:sampler atIndex:0];
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
    std::_Exit(0);
}
