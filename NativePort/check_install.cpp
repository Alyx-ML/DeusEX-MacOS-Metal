#include "game_install.h"
#include "Engine.h"
#include "Package/PackageManager.h"
#include "Utils/CommandLine.h"
#include <cassert>
#include <fstream>
#include <iostream>

int main(int argc, char** argv)
{
    assert(argc == 3);
    const auto assets = ValidateDeusExInstall(argv[1]);
    const fs::path temp = fs::canonical(argv[2]), game = temp/"Native settings";
    const auto portable = temp/"Portable package";
    fs::create_directories(portable/"Put game files here");
    assert(DefaultDeusExInstall(portable/"Deus Ex.app", assets) == portable/"Put game files here");
    assert(DefaultDeusExInstall(temp/"No adjacent folder/Deus Ex.app", assets) == assets);
    for (const char* folder : {"System", "Maps", "Music", "Sounds", "Textures"})
        fs::create_directory_symlink(assets/folder, portable/"Put game files here"/folder);
    PrepareDeusExInstall(DefaultDeusExInstall(portable/"Deus Ex.app", {}), temp/"Portable settings");
    const auto relocated = temp/"Moved portable package";
    fs::rename(portable, relocated);
    PrepareDeusExInstall(DefaultDeusExInstall(relocated/"Deus Ex.app", assets), temp/"Portable settings");
    assert(fs::read_symlink(temp/"Portable settings/Maps") == relocated/"Put game files here/Maps");
    assert(ValidateDeusExInstall(assets/"System") == assets);
    PrepareDeusExInstall(assets, game);
    assert(FindUE1GameInPath(game.string()).first == KnownUE1Games::DEUS_EX_1112fm);
    assert(!fs::is_symlink(game/"System/SE-DeusEx.ini"));
    assert(!fs::is_symlink(game/"Save"));
    assert(fs::equivalent(game/"Maps", assets/"Maps"));
    IniFile ini((game/"System/SE-DeusEx.ini").string());
    assert(ini.GetValue("Core.System", "SavePath") == "../Save");
    assert(ini.GetValues("Core.System", "Paths").size() == 5);
    ini.SetValue("Engine.SurrealClient", "WindowedViewportX", "987");
    ini.SaveTo((game/"System/SE-DeusEx.ini").string());
    std::ofstream(game/"Save/keep.txt") << "preserved";
    auto moved = temp/"Moved game ü with spaces";
    fs::create_directories(moved);
    for (const char* folder : {"System", "Maps", "Music", "Sounds", "Textures"})
        fs::create_directory_symlink(assets/folder, moved/folder);
    fs::create_symlink(assets/"System/DeusEx.u", game/"System/obsolete.u");
    PrepareDeusExInstall(moved, game);
    assert(!fs::is_symlink(game/"System/obsolete.u"));
    assert(fs::read_symlink(game/"Maps") == moved/"Maps");
    assert(fs::file_size(game/"Save/keep.txt") == 9);
    IniFile kept((game/"System/SE-DeusEx.ini").string());
    assert(kept.GetValue("Engine.SurrealClient", "WindowedViewportX") == "987");
    fs::remove(moved/"Maps");
    bool rejected = false;
    try { PrepareDeusExInstall(moved, game); } catch (const std::exception&) { rejected = true; }
    assert(rejected && fs::file_size(game/"Save/keep.txt") == 9);
    // Incomplete data must fail before creating a settings directory.
    fs::create_directories(temp/"Empty");
    rejected = false;
    try { PrepareDeusExInstall(temp/"Empty", temp/"Unwanted"); } catch (const std::exception&) { rejected = true; }
    assert(rejected && !fs::exists(temp/"Unwanted"));
    // A stock install has no SE-* settings; exercise first launch with real packages.
    const auto stock = temp/"Stock", fresh = temp/"Fresh";
    fs::create_directories(stock/"System");
    for (const auto& entry : fs::directory_iterator(assets/"System"))
        if (entry.is_regular_file() && entry.path().filename().string().rfind("SE-", 0) != 0)
            fs::create_symlink(entry.path(), stock/"System"/entry.path().filename());
    for (const char* folder : {"Maps", "Music", "Sounds", "Textures"})
        fs::create_directory_symlink(assets/folder, stock/folder);
    PrepareDeusExInstall(stock, fresh);
    IniFile first((fresh/"System/SE-DeusEx.ini").string());
    assert(first.GetValue("Engine.SurrealClient", "WindowedViewportX") == "1280");
    CommandLine cmd({argv[0], fresh.string()}); commandline = &cmd;
    GameFolderSelection::UpdateList();
    auto* runtime = new Engine(GameFolderSelection::GetLaunchInfo(0));
    assert(runtime->packages->FindClass("DeusEx.DeusExPlayer"));
    assert(runtime->packages->FindClass("DeusEx.DeusExRootWindow"));
    assert(runtime->packages->LoadMap("01_NYC_UNATCOIsland"));
    assert(runtime->packages->GetSaveFolderPath() == fresh/"Save");
    std::cout << "PASS: fresh stock configuration and engine loading of game classes/map\n";
    std::cout << "PASS: install/root-System validation, local settings, folder change, missing data and save preservation\n" << std::flush;
    std::_Exit(0); // No engine shutdown writes outside the isolated test.
}
