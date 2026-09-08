#import <AppKit/AppKit.h>
#include <filesystem>
#include <stdexcept>
#include <functional>
#include <exception>
#include <unistd.h>
#include <fcntl.h>

#include "game_install.h"

std::string PrepareMacGameBundle() {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        [NSApp activateIgnoringOtherApps:YES];
        NSURL* support=[NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
        fs::path game=fs::path(support.path.fileSystemRepresentation)/"Deus Ex Native";
        NSString* remembered=[NSUserDefaults.standardUserDefaults stringForKey:@"DeusExInstallation"];
        fs::path assets=DefaultDeusExInstall(NSBundle.mainBundle.bundlePath.fileSystemRepresentation,
            remembered ? remembered.fileSystemRepresentation : "");
        bool choose=assets.empty() || ([NSEvent modifierFlags] & NSEventModifierFlagOption);
        if (!choose) {
            try { assets=ValidateDeusExInstall(assets); }
            catch (...) { choose=true; }
        }
        while (true) {
            if (choose) {
                NSOpenPanel* panel=[NSOpenPanel openPanel];
                panel.title=@"Choose your Deus Ex GOTY installation";
                panel.message=@"Copy your installed game’s System, Maps, Textures, Sounds and Music folders into ‘Put game files here’ beside Deus Ex.app, then select that folder. You can also select an existing GOTY installation.";
                panel.prompt=@"Use This Game";
                panel.canChooseFiles=NO;
                panel.canChooseDirectories=YES;
                panel.allowsMultipleSelection=NO;
                if (!assets.empty()) panel.directoryURL=[NSURL fileURLWithPath:[NSString stringWithUTF8String:assets.c_str()]];
                if ([panel runModal] != NSModalResponseOK) return {};
                assets=panel.URL.path.fileSystemRepresentation;
            }
            try {
                assets=ValidateDeusExInstall(assets);
                PrepareDeusExInstall(assets,game);
                [NSUserDefaults.standardUserDefaults setObject:[NSString stringWithUTF8String:assets.c_str()] forKey:@"DeusExInstallation"];
                fs::current_path(game);
                int log=open((game/"game.log").c_str(),O_WRONLY|O_CREAT|O_TRUNC,0600);
                if (log<0) throw std::runtime_error("Cannot open game log");
                dup2(log,STDOUT_FILENO); dup2(log,STDERR_FILENO); close(log);
                return game.string();
            } catch (const std::exception& error) {
                NSAlert* alert=[NSAlert new];
                alert.messageText=@"Deus Ex could not use this folder";
                alert.informativeText=[NSString stringWithUTF8String:error.what()];
                [alert addButtonWithTitle:@"Choose Another Folder"];
                [alert addButtonWithTitle:@"Quit"];
                if ([alert runModal] != NSAlertFirstButtonReturn) return {};
                choose=true;
            }
        }
    }
}

int RunMacGame(const std::function<int()>& runGame)
{
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        __block int result = 1;
        __block std::exception_ptr failure;
        // Enter from a run-loop timer so nested event pumping can still service the main dispatch queue.
        [NSTimer scheduledTimerWithTimeInterval:0 repeats:NO block:^(NSTimer* timer) {
            try { result = runGame(); }
            catch (...) { failure = std::current_exception(); }
            [NSApp stop:nil];
            [NSApp postEvent:[NSEvent otherEventWithType:NSEventTypeApplicationDefined
                location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0 context:nil
                subtype:0 data1:0 data2:0] atStart:NO];
        }];
        [NSApp run];
        if (failure) std::rethrow_exception(failure);
        return result;
    }
}
