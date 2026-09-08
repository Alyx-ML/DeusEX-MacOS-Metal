#include "Precomp.h"
#include "Engine.h"
#include "Package/PackageManager.h"
#include "Packages/Extension/Windows/TabGroup/URootWindow.h"
#include "Packages/Extension/Windows/Text/UEditWindow.h"
#include <surrealwidgets/window/cocoanativehandle.h>
#import "../SurrealWidgets/src/window/cocoa/AppKitWrapper.h"
#import <GameController/GameController.h>
#import <notify.h>

static UEditWindow* FocusedEdit()
{
    return engine && engine->dxRootWindow ? UObject::TryCast<UEditWindow>(engine->dxRootWindow->GetKeyboardFocus()) : nullptr;
}

@interface DeusExMacActions : NSObject <NSMenuItemValidation>
@end
@implementation DeusExMacActions
- (void)quit:(id)sender { if (engine) engine->OnWindowClose(); }
- (void)edit:(NSMenuItem*)sender
{
    auto* edit = FocusedEdit();
    if (!edit) return;
    switch (sender.tag) {
        case 0: edit->Undo(); break;
        case 1: edit->Redo(); break;
        case 2: edit->Cut(); break;
        case 3: edit->Copy(); break;
        case 4: edit->Paste(); break;
        case 5: edit->SetSelectedArea(0, (int)edit->Text().size()); break;
    }
}
- (void)setting:(NSMenuItem*)sender
{
    double value = [sender.representedObject doubleValue];
    if (sender.tag == 0) {
        engine->renderScale = (float)value;
        [NSUserDefaults.standardUserDefaults setDouble:value forKey:@"RenderScale"];
    } else if (sender.tag == 1) {
        engine->interfaceScale = (float)value;
        [NSUserDefaults.standardUserDefaults setDouble:value forKey:@"InterfaceScale"];
        if (engine->dxRootWindow) engine->dxRootWindow->AskParentForReconfigure();
    } else {
        engine->controllerEnabled = !engine->controllerEnabled;
        engine->UpdateController({}, 0);
        [NSUserDefaults.standardUserDefaults setBool:engine->controllerEnabled forKey:@"ControllerEnabled"];
    }
}
- (BOOL)validateMenuItem:(NSMenuItem*)item
{
    if (item.action == @selector(edit:)) return FocusedEdit() != nullptr;
    if (item.action == @selector(setting:)) {
        if (item.tag == 2) item.state = engine->controllerEnabled ? NSControlStateValueOn : NSControlStateValueOff;
        else {
            float current = item.tag == 0 ? engine->renderScale : engine->interfaceScale;
            item.state = std::abs(current - [item.representedObject floatValue]) < 0.01f ? NSControlStateValueOn : NSControlStateValueOff;
        }
    }
    return YES;
}
@end

void Engine::InitializeMacIntegration()
{
    [NSUserDefaults.standardUserDefaults registerDefaults:@{@"RenderScale": @1.0, @"InterfaceScale": @1.0, @"ControllerEnabled": @YES}];
    auto setting = [](NSString* key, float low, float high) {
        float value = [NSUserDefaults.standardUserDefaults floatForKey:key];
        return std::isfinite(value) ? std::clamp(value, low, high) : 1.0f;
    };
    renderScale = setting(@"RenderScale", 0.5f, 1.0f);
    interfaceScale = setting(@"InterfaceScale", 0.75f, 1.25f);
    controllerEnabled = [NSUserDefaults.standardUserDefaults boolForKey:@"ControllerEnabled"];
    const char* commands[16] = {"Jump", "Duck", "ParseRightClick", "ShowInventoryWindow", "PrevWeapon", "NextWeapon", "Fire", "ToggleScope", "ToggleWalk", "ReloadWeapon", "ShowInventoryWindow", "ShowMainMenu", "", "", "PrevWeapon", "NextWeapon"};
    for (int i=0; i<16; ++i) {
        auto& binding = keybindings[keynames[IK_Joy1+i]];
        if (binding.empty() || (i >= 12 && binding == "ActivateBelt " + std::to_string(i - 11))) binding = commands[i];
    }
    static DeusExMacActions* actions = [DeusExMacActions new];
    NSMenu* bar = [NSMenu new];
    auto menu = [&](NSString* title) {
        NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
        item.submenu = [[NSMenu alloc] initWithTitle:title];
        [bar addItem:item]; return item.submenu;
    };
    NSMenu* app = menu(@"Deus Ex");
    [app addItemWithTitle:@"Hide Deus Ex" action:@selector(hide:) keyEquivalent:@"h"];
    [app addItem:[NSMenuItem separatorItem]];
    auto quit = [app addItemWithTitle:@"Quit Deus Ex" action:@selector(quit:) keyEquivalent:@"q"]; quit.target = actions;
    NSMenu* edit = menu(@"Edit");
    NSArray* titles = @[@"Undo", @"Redo", @"Cut", @"Copy", @"Paste", @"Select All"];
    NSArray* keys = @[@"z", @"z", @"x", @"c", @"v", @"a"];
    for (int i=0; i<6; ++i) {
        auto item = [edit addItemWithTitle:titles[i] action:@selector(edit:) keyEquivalent:keys[i]];
        item.tag = i; item.target = actions;
        item.keyEquivalentModifierMask = NSEventModifierFlagCommand | (i == 1 ? NSEventModifierFlagShift : 0);
    }
    NSMenu* view = menu(@"View");
    for (int type=0; type<2; ++type) {
        auto title = type == 0 ? @"Rendering Resolution" : @"Interface Size";
        auto parent = [view addItemWithTitle:title action:nil keyEquivalent:@""];
        parent.submenu = [[NSMenu alloc] initWithTitle:title];
        NSArray* values = type == 0 ? @[@50, @75, @100] : @[@75, @100, @125];
        for (NSNumber* percent in values) {
            auto item = [parent.submenu addItemWithTitle:[NSString stringWithFormat:@"%@%%", percent] action:@selector(setting:) keyEquivalent:@""];
            item.target = actions; item.tag = type; item.representedObject = @([percent doubleValue] / 100.0);
        }
    }
    auto controller = [view addItemWithTitle:@"Enable Controller" action:@selector(setting:) keyEquivalent:@""];
    controller.target = actions; controller.tag = 2;
    NSMenu* windows = menu(@"Window");
    auto* handle = static_cast<CocoaNativeHandle*>(window->GetNativeHandle());
    auto full = [windows addItemWithTitle:@"Enter Full Screen" action:@selector(toggleFullScreen:) keyEquivalent:@"f"];
    full.target = handle->nsWindow; full.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagControl;
    [NSApp setMainMenu:bar]; [NSApp setWindowsMenu:windows];
    fprintf(stderr, "macOS integration initialized: render=%.2f UI=%.2f controller=%d bundle=%s GameModeOptIn=%d\n", renderScale, interfaceScale, controllerEnabled, NSBundle.mainBundle.bundleIdentifier.UTF8String, [NSBundle.mainBundle.infoDictionary[@"LSSupportsGameMode"] boolValue]);
}

void Engine::PollMacController(float elapsed)
{
    @autoreleasepool {
        static int gameModeToken = -1, fullscreenToken = -1;
        static CFTimeInterval lastStatusTime = 0;
        static std::string lastStatus;
        if (gameModeToken == -1) {
            notify_register_check("com.apple.system.game_mode_status_changed", &gameModeToken);
            notify_register_check("com.apple.system.fullscreen_gaming_session_changed", &fullscreenToken);
        }
        if (CACurrentMediaTime() - lastStatusTime > 1.0) {
            lastStatusTime = CACurrentMediaTime();
            uint64_t gameMode = 0, fullscreenSession = 0;
            notify_get_state(gameModeToken, &gameMode); notify_get_state(fullscreenToken, &fullscreenSession);
            NSWindow* nsWindow = static_cast<CocoaNativeHandle*>(window->GetNativeHandle())->nsWindow;
            std::string status = "active=" + std::to_string(NSApp.active) + " key=" + std::to_string(nsWindow.keyWindow)
                + " fullscreen=" + std::to_string(bool(nsWindow.styleMask & NSWindowStyleMaskFullScreen))
                + " appRunning=" + std::to_string(NSApp.running) + " gameMode=" + std::to_string(gameMode)
                + " fullscreenGameSession=" + std::to_string(fullscreenSession);
            if (status != lastStatus) { fprintf(stderr, "macOS gaming status: %s\n", status.c_str()); lastStatus = status; }
        }
        ControllerState sample;
        GCController* controller = GCController.current ?: GCController.controllers.firstObject;
        if (controllerEnabled && controller) {
            auto state = [controller.input capture];
            sample.device = (uintptr_t)(__bridge void*)controller;
            NSArray* names = @[GCInputButtonA, GCInputButtonB, GCInputButtonX, GCInputButtonY,
                GCInputLeftShoulder, GCInputRightShoulder, GCInputRightTrigger, GCInputLeftTrigger,
                GCInputLeftThumbstickButton, GCInputRightThumbstickButton, GCInputButtonOptions, GCInputButtonMenu];
            for (int i=0; i<12; ++i) sample.buttons[i] = state.buttons[names[i]].pressedInput.pressed;
            auto dpad = state.dpads[GCInputDirectionPad];
            sample.buttons[12] = dpad.up.pressed; sample.buttons[13] = dpad.down.pressed;
            sample.buttons[14] = dpad.left.pressed; sample.buttons[15] = dpad.right.pressed;
            auto left = state.dpads[GCInputLeftThumbstick], right = state.dpads[GCInputRightThumbstick];
            sample.moveX = left.xAxis.value; sample.moveY = left.yAxis.value;
            sample.lookX = right.xAxis.value; sample.lookY = right.yAxis.value;
        }
        static uintptr_t lastDevice = 0;
        static unsigned lastButtons = 0;
        unsigned buttons = 0;
        for (int i = 0; i < 16; ++i) if (sample.buttons[i]) buttons |= 1u << i;
        if (buttons != lastButtons) {
            fprintf(stderr, "Controller buttons: %04x menu=%d\n", buttons, dxRootWindow && dxRootWindow->IsModalOpen());
            lastButtons = buttons;
        }
        if (sample.device != lastDevice) {
            fprintf(stderr, "Controller: %s\n", sample.device ? (controller.vendorName.UTF8String ?: "connected") : "disconnected");
            lastDevice = sample.device;
        }
        UpdateController(sample, elapsed);
    }
}
