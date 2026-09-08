# Deus Ex for Apple silicon — preview

Requires an Apple silicon Mac running macOS 27 or later, and your own complete
Deus Ex GOTY 1.112fm installation. This is an unofficial, modified SurrealEngine
build with a native Metal renderer. Game compatibility remains incomplete.

1. Unzip Deus-Ex-Mac-ARM64.zip. Keep the extracted Deus Ex Mac folder together;
   move the whole folder wherever you want to keep the game.
2. Copy your installed GOTY game's contents into “Put game files here”. Put
   System, Maps, Textures, Sounds and Music directly inside that folder.
3. Open Deus Ex.app beside it. The app finds those files automatically.

    Deus Ex Mac/
      Deus Ex.app
      Put game files here/
        System/
        Maps/
        Textures/
        Sounds/
        Music/

The ZIP contains the native app and instructions, with no original game files.
If files are missing, the app opens a folder picker. You can also use that picker
to select an existing installation without copying it.

Use an installed copy from your Steam, GOG or disc installation. Copy the whole
installed folder from a Windows PC or an existing Wine/CrossOver installation
if needed. A setup EXE, installer archive or Steam library folder is not the
installed game folder. Restore the original System/DeusEx.exe if you use a
replacement launcher; it is read to identify the game version, never executed.
Keep this folder available: the app reads its game data directly.

Hold Option while opening the app to choose a different installation. If the
remembered folder is missing, the picker opens again. Cancel exits the app.

Saves, settings and game.log live in:
~/Library/Application Support/Deus Ex Native/

Your source installation is not edited. Existing native saves/settings are
preserved when changing the game folder. Windows saves are not imported
automatically. Start a new game for this preview; save compatibility is still
being developed. Delete neither the source game folder nor your native Save
folder when updating the app. Replace only the app.

This preview has an ad-hoc signature, not a Developer ID signature or Apple
notarization. A downloaded copy may require approval in macOS Privacy & Security.

## Sharing this build

Upload Deus-Ex-Mac-ARM64.zip, Deus-Ex-Mac-Source.tar.gz, SHA256SUMS.txt and this
file together to a GitHub Release. Neither archive contains the original game.
The source archive includes this build's modifications and library sources.
The current development repository also tracks original game files and other
local artifacts: do not publish the whole working tree or its history as a
source release. The generated source archive is the scoped source distribution.

This modified build is based on SurrealEngine by Magnus Norddahl, Lupert Everett
and contributors. Library notices are inside the app's Resources/Licenses.
Sample rate converter designed by Aleksey Vaneev of Voxengo.
SurrealVideo and OpenAL Soft are supplied as replaceable dynamic libraries;
their source and licence notices are included in the accompanying source archive.

## Building the supplied source

Extract Deus-Ex-Mac-Source.tar.gz, then work in its Deus-Ex-Mac directory.
Use Xcode with the macOS 27 SDK, CMake, Ninja and SDL3 (the packaging script
currently expects the Apple silicon Homebrew SDL3 installation).

    cmake -S .porting/SurrealEngine -B .porting/SurrealEngine/build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=27.0 -DENABLE_SDL3=ON
    cmake --build .porting/SurrealEngine/build --target SurrealEngine -j 6
    python3 NativePort/check_install.py "/path/to/your/Deus Ex GOTY"
    python3 NativePort/package_app.py

The packaging step produces dist/Deus Ex Mac/ and the release files.
