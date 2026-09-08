
#include "Precomp.h"
#include "Utils/Exception.h"
#include "Utils/Logger.h"
#include "Utils/CommandLine.h"
#include "GameApp.h"
#include "GameFolder.h"
#include "Engine.h"
#include "UI/WidgetResourceData.h"
#include "UI/ErrorWindow/ErrorWindow.h"
#include "UI/Launcher/LauncherWindow.h"
#include "Utils/File.h"
#include <stdexcept>
#include <iostream>

int GameApp::main(Array<std::string> args)
{
	InitWidgetResources("dark");

	try
	{
		CommandLine cmd(args);
		commandline = &cmd;

		if (ErrorWindow::CheckCrashReporter())
			return 0;

		if (commandline->HasArg("-h", "--help"))
		{
			std::cout << "SurrealEngine [--url=<mapname>] [--engineversion=X] [Path to game folder]\n";
			return 0;
		}

		int selectedGameIndex;
        if (commandline->HasArg("--direct", "--direct")) {
            Logger::Get()->SetCallback([](const LogMessageLine& line) { fprintf(stderr,"%s: %s\n",line.Source.c_str(),line.Text.c_str()); });
            GameFolderSelection::UpdateList();
            if (GameFolderSelection::Games.size()!=1) throw std::runtime_error("--direct requires exactly one game folder");
            selectedGameIndex=0;
        } else selectedGameIndex = LauncherWindow::ExecModal();
		if (selectedGameIndex >= 0)
		{
			GameLaunchInfo info = GameFolderSelection::GetLaunchInfo(selectedGameIndex);
			Engine engine(info);
			engine.Run();
		}
	}
	catch (const std::exception& e)
	{
		fprintf(stderr,"Native game error: %s\n",e.what());
        ErrorWindow::ExecModal(e.what(), Logger::Get()->GetLog());
	}

	DeinitWidgetResources();
	return 0;
}
