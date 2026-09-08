
#include "Precomp.h"
#include "UGameDirectory.h"
#include "Utils/Logger.h"
#include "Engine.h"
#include "Package/PackageManager.h"

void UDXGameDirectory::GetGameDirectory()
{
	if (GameDirectoryType() == EGameDirectoryTypes::GD_Maps)
	{
		currentDirectory = fs::path(engine->LaunchInfo.gameRootFolder) / "Maps";
		PopulateDirectoryList();
	}
	else
	{
		currentDirectory = engine->packages->GetSaveFolderPath();
		PopulateSaveInfoPointers();
	}
}

int UDXGameDirectory::GetNewSaveFileIndex()
{
	const auto saveFolder = engine->packages->GetSaveFolderPath();

	// Save folders being formatted like Save0001 implies that the number can go up to 9999
	for (int i = 1; i < 10000; i++)
	{
		auto folderPath = saveFolder / GetSaveIndexFolderName(i);
		if (!fs::exists(folderPath) || (fs::exists(folderPath) && !fs::is_directory(folderPath)))
			return i;
	}

	return 0;
}

std::string UDXGameDirectory::GenerateSaveFilename(int saveIndex)
{
	return GetSaveIndexFolderName(saveIndex);
}

std::string UDXGameDirectory::GenerateNewSaveFileName(std::optional<int> newIndex)
{
	return GenerateSaveFilename(newIndex ? *newIndex : GetNewSaveFileIndex());
}

int UDXGameDirectory::GetDirCount()
{
    return (int)DirectoryList().size();
}

std::string UDXGameDirectory::GetDirFilename(int fileIndex)
{
    auto list = DirectoryList();
    return fileIndex >= 0 && (size_t)fileIndex < list.size() ? list[fileIndex] : "";
}

void UDXGameDirectory::SetDirType(EGameDirectoryTypes newDirType)
{
	GameDirectoryType() = newDirType;
}

void UDXGameDirectory::SetDirFilter(const std::string& strFilter)
{
	CurrentFilter() = strFilter;
}

UDXSaveInfo* UDXGameDirectory::GetSaveInfo(int fileIndex)
{
	if (GameDirectoryType() != EGameDirectoryTypes::GD_SaveGames)
		// We're not in the Save folder
		return nullptr;

	auto pkg = engine->packages->GetSaveInfoPackage(GetSaveIndexFolderName(fileIndex));

	if (!pkg)
		return nullptr;

	return Cast<UDXSaveInfo>(pkg->GetUObject("DeusExSaveInfo", "MyDeusExSaveInfo"));
}

UDXSaveInfo* UDXGameDirectory::GetSaveInfoFromDirectoryIndex(int DirectoryIndex)
{
    auto list = LoadedSaveInfoPointers();
    return DirectoryIndex >= 0 && (size_t)DirectoryIndex < list.size() ? list[DirectoryIndex] : nullptr;
}

UDXSaveInfo* UDXGameDirectory::GetTempSaveInfo()
{
	if (!TempSaveInfo()) TempSaveInfo() = Cast<UDXSaveInfo>(engine->packages->GetTransientPackage()->NewObject("TempSaveInfo", engine->deusExPackage->GetClass("DeusExSaveInfo"), ObjectFlags::Transient));
	return TempSaveInfo();
}

void UDXGameDirectory::DeleteSaveInfo(UDXSaveInfo& saveInfo)
{
    // Scripts call this after displaying each row; it releases metadata, never save files.
}

void UDXGameDirectory::PurgeAllSaveInfo()
{
    LoadedSaveInfoPointers().Array->Resize(0);
    TempSaveInfo() = nullptr;
}

int UDXGameDirectory::GetSaveFreeSpace()
{
    auto folder = engine->packages->GetSaveFolderPath();
    return (int)std::min<uintmax_t>(fs::space(folder).available / 1024, 1000ULL * 1024 * 1024);
}

int UDXGameDirectory::GetSaveDirectorySize(int saveIndex)
{
	if (GameDirectoryType() != EGameDirectoryTypes::GD_SaveGames)
		// We're not in the Save folder
		return 0;

    uintmax_t bytes = 0;
    auto folder = currentDirectory / GetSaveIndexFolderName(saveIndex);
    if (!fs::is_directory(folder)) return 0;
    for (const auto& entry : fs::directory_iterator(folder))
        if (entry.is_regular_file()) bytes += entry.file_size();
    return (int)std::min<uintmax_t>((bytes + 1023) / 1024, INT32_MAX);
}

std::string UDXGameDirectory::GetSaveIndexFolderName(int saveIndex)
{
    return PackageManager::SaveSlotFolder(saveIndex);
}

void UDXGameDirectory::PopulateDirectoryList()
{
    auto list = DirectoryList();
    list.Array->Resize(0);
    if (!fs::is_directory(currentDirectory)) return;
    for (const auto& entry : fs::directory_iterator(currentDirectory))
        if (entry.is_regular_file() && NameString(entry.path().extension().string()) == ".dx")
            list.push_back(entry.path().filename().string());
    std::sort(list.begin(), list.end());
}

void UDXGameDirectory::PopulateSaveInfoPointers()
{
    engine->packages->RefreshSaveInfos();
    auto list = LoadedSaveInfoPointers();
    auto dirs = DirectoryList();
    list.Array->Resize(0);
    dirs.Array->Resize(0);
    for (const auto& pair : engine->packages->GetSaveInfoPackages()) {
        if (pair.first == "QuickSave") continue;
        auto* info = Cast<UDXSaveInfo>(pair.second->GetUObject("DeusExSaveInfo", "MyDeusExSaveInfo"));
        if (!info) continue;
        list.push_back(info);
        dirs.push_back(pair.first.ToString());
    }
}
