#include "Precomp.h"
#include "Engine.h"
#include "GameFolder.h"
#include "Package/PackageManager.h"
#include "Package/Package.h"
#include "Packages/Core/UClass.h"
#include "Packages/Engine/UViewport.h"
#include "Packages/Engine/Actors/Info/ULevelInfo.h"
#include "Packages/Extension/UPlayerPawnExt.h"
#include "Packages/Engine/Actors/Pawn/UPlayerPawn.h"
#include "Packages/Extension/Windows/TabGroup/URootWindow.h"
#include "Packages/Extension/Windows/Text/UButtonWindow.h"
#include "Utils/CommandLine.h"
#include "Packages/Extension/Windows/Text/UEditWindow.h"
#include "Packages/Extension/Windows/UListWindow.h"
#include <cassert>
#include <cstdio>

struct InputWindow : UModalWindow
{
    InputWindow(UClass* cls) : UModalWindow("input-check", cls, ObjectFlags::Transient)
    {
        PropertyData.Init(cls);
        bIsVisible() = true;
        bIsSensitive() = true;
    }
    bool consume = false;
    int presses = 0, releases = 0, activations = 0, mousePresses = 0, mouseReleases = 0;
    bool MouseButtonPressed(float, float, EInputKey, int) override { ++mousePresses; return true; }
    bool MouseButtonReleased(float, float, EInputKey, int) override { ++mouseReleases; return true; }
    bool ButtonActivated(UWindow*) override { ++activations; return true; }
    bool repeated = false;
    bool RawKeyPressed(EInputKey, EInputType type, bool repeat) override
    {
        if (type == IST_Press) { ++presses; repeated = repeat; }
        else if (type == IST_Release) ++releases;
        return false;
    }
    bool VirtualKeyPressed(EInputKey, bool) override { return consume; }
    bool KeyPressed(std::string) override { return consume; }
};

int main(int argc, char** argv)
{
    assert(argc == 2);
    CommandLine cmd({argv[0], argv[1]});
    commandline = &cmd;
    GameFolderSelection::UpdateList();
    assert(GameFolderSelection::Games.size() == 1);
    auto* game = new Engine(GameFolderSelection::GetLaunchInfo(0));
    auto* transient = game->packages->GetTransientPackage();
    auto* ext = game->packages->GetPackage("Extension");
    auto* root = UObject::Cast<URootWindow>(transient->NewObject("input-root", ext->GetClass("RootWindow"), ObjectFlags::Transient));
    root->bIsVisible() = true;
    root->bIsSensitive() = true;
    InputWindow menu(ext->GetClass("ModalWindow"));
    InputWindow button(ext->GetClass("ModalWindow"));
    root->lastChild() = &menu;
    menu.parentOwner() = root;
    button.parentOwner() = &menu;
    root->FocusWindow() = &button;
    menu.consume = true;
    assert(root->OnWindowKeyDown(IK_Escape));
    assert(button.presses == 1 && menu.presses == 1);
    assert(root->OnWindowKeyChar("a"));
    assert(root->OnWindowKeyUp(IK_Escape));
    assert(button.releases == 1 && menu.releases == 1);
    button.consume = true;
    root->OnWindowKeyDown(IK_Enter);
    assert(button.presses == 2 && menu.presses == 1);
    button.consume = false;
    button.parentOwner() = nullptr;
    assert(root->GetKeyboardFocus() == &menu);
    assert(root->OnWindowKeyDown(IK_Escape));
    menu.bIsVisible() = false;
    assert(!root->IsModalOpen() && !root->OnWindowKeyDown(IK_Escape));
    menu.bIsVisible() = true;
    button.parentOwner() = &menu;
    auto* pawn = UObject::Cast<UPlayerPawn>(transient->NewObject("input-pawn", game->packages->GetPackage("Engine")->GetClass("PlayerPawn"), ObjectFlags::Transient));
    game->viewport->Actor() = pawn;
    game->dxRootWindow = root;
    game->OnWindowKeyDown(IK_Space);
    assert(!button.repeated);
    game->OnWindowKeyDown(IK_Space);
    assert(button.repeated);
    game->OnWindowKeyUp(IK_Space);
    assert(!game->pressedKeys[IK_Space]);
    pawn->bFire() = 1;
    pawn->aExtra0() = 1.0f;
    game->activeInputButtons["bFire"] = {IK_LeftMouse};
    game->activeInputAxes["aExtra0"][IK_Q] = 1.0f;
    game->OnWindowKeyUp(IK_Q); // Modal consumption must not retain a held lean.
    assert(pawn->aExtra0() == 0 && game->activeInputAxes.empty());
    game->ReleaseInput(IK_LeftMouse);
    assert(pawn->bFire() == 0 && game->activeInputButtons.empty());
    pawn->bFire() = pawn->bDuck() = pawn->bRun() = 1;
    pawn->aExtra0() = pawn->aUp() = 1;
    pawn->Health() = 73;
    game->ResetInput();
    assert(!pawn->bFire() && !pawn->bDuck() && !pawn->bRun());
    assert(pawn->aExtra0() == 0 && pawn->aUp() == 0 && pawn->Health() == 73);
    auto* nativeButton = UObject::Cast<UButtonWindow>(menu.NewChild(ext->GetClass("ButtonWindow"), true));
    assert(nativeButton->bIsSelectable());
    nativeButton->bIsSensitive() = true;
    nativeButton->parentOwner() = &menu;
    assert(nativeButton->VirtualKeyPressed(IK_Enter, false));
    assert(menu.activations == 1);
    assert(nativeButton->VirtualKeyPressed(IK_Enter, true));
    assert(menu.activations == 1);
    assert(nativeButton->AcceleratorKeyPressed("n"));
    assert(menu.activations == 2);
    auto* edit = UObject::Cast<UEditWindow>(transient->NewObject("edit-check", ext->GetClass("EditWindow"), ObjectFlags::Transient));
    edit->bEditable() = true;
    edit->bSingleLine() = true;
    edit->SetMaxUndos(4);
    edit->SetText("abcdef");
    edit->SetSelectedArea(2, 2);
    assert(edit->InsertText("XY", true, false));
    assert(edit->Text() == "abXYef" && edit->GetInsertionPoint() == 4);
    edit->Undo(); assert(edit->Text() == "abcdef");
    edit->Redo(); assert(edit->Text() == "abXYef");
    edit->SetInsertionPoint(0, false);
    edit->DeleteChar(true, true);
    assert(edit->GetInsertionPoint() == 0 && edit->Text() == "abXYef");
    edit->SetMaxSize(6);
    assert(!edit->InsertText("extra", true, false));
    edit->SetSelectedArea(0, 2);
    edit->bUppercaseOnly() = true;
    assert(edit->InsertText("hi", true, false) && edit->Text() == "HIXYef");
    edit->Undo();
    edit->InsertText("z", true, false);
    auto changed = edit->Text();
    edit->Redo(); assert(edit->Text() == changed);
    edit->bSingleLine() = false;
    edit->Width() = 100; edit->Height() = 2;
    edit->SetText("abc\ndefgh\nx");
    edit->SetInsertionPoint(2, false);
    edit->MoveInsertionPoint(1, false); assert(edit->GetInsertionPoint() == 6);
    edit->MoveInsertionPoint(6, false); assert(edit->GetInsertionPoint() == 4);
    edit->MoveInsertionPoint(7, true); assert(edit->GetInsertionPoint() == 9);
    int selectionStart, selectionCount;
    edit->GetSelectedArea(selectionStart, selectionCount); assert(selectionStart == 4 && selectionCount == 5);
    edit->MoveInsertionPoint(0, false); assert(edit->GetInsertionPoint() == 3);
    edit->Width() = 3;
    edit->SetText("abcdefg"); edit->SetInsertionPoint(1, false);
    edit->MoveInsertionPoint(1, false); assert(edit->GetInsertionPoint() == 4);
    edit->MoveInsertionPoint(1, false); assert(edit->GetInsertionPoint() == 7);
    auto* list = UObject::Cast<UListWindow>(transient->NewObject("list-check", ext->GetClass("ListWindow"), ObjectFlags::Transient));
    list->SetNumColumns(3); list->Height() = 30; list->lineSize() = 10;
    list->focusLine() = list->anchorLine() = -1;
    int firstRow = list->AddRow("Bravo;20;", {}), secondRow = list->AddRow("alpha;3;", {});
    assert(list->GetField(firstRow, 0) == "Bravo" && list->GetField(firstRow, 1) == "20");
    assert(list->GetField(firstRow, 2).empty() && list->GetField(firstRow, 3).empty());
    list->SetRow(firstRow, {}, {}, {});
    assert(list->GetFocusRow() == firstRow && list->GetNumSelectedRows() == 1);
    list->SetColumnType(1, 1, {}); list->SetSortColumn(1, false, {}); list->Sort();
    assert(list->IndexToRowId(0) == secondRow && list->GetFocusRow() == firstRow);
    assert(list->VirtualKeyPressed(IK_Up, false));
    assert(list->GetFocusRow() == secondRow && list->GetSelectedRow() == secondRow);
    list->SetSortColumn(0, false, false); list->Sort(); assert(list->IndexToRowId(0) == secondRow);
    for (int i = 0; i < 10; ++i) list->AddRow("more;50;", {});
    assert(list->VirtualKeyPressed(IK_End, false));
    assert(list->RowIdToIndex(list->GetFocusRow()) == 11 && list->firstVisibleRow == 9);
    assert(list->VirtualKeyPressed(IK_PageUp, false));
    assert(list->RowIdToIndex(list->GetFocusRow()) == 8 && list->firstVisibleRow == 8);
    list->DeleteAllRows(); assert(list->GetFocusRow() == 0 && list->firstVisibleRow == 0);
    list->SetDelimiter("|"); int delimited = list->AddRow("a|b|", {});
    assert(list->GetField(delimited, 1) == "b" && list->items[0].cells.size() == 3);
    puts("PASS: multiline/soft-wrap caret navigation, selection, save-list fields, numeric/text sort, original list keyboard script and scrolling");
    auto* secondButton = UObject::Cast<UButtonWindow>(transient->NewObject("second-button", ext->GetClass("ButtonWindow"), ObjectFlags::Transient));
    for (auto* item : {nativeButton, secondButton}) {
        item->bIsSelectable() = true;
        item->bIsSensitive() = true;
        item->bIsVisible() = true;
        item->parentOwner() = &menu;
    }
    root->firstChild() = root->lastChild() = &menu;
    menu.firstChild() = nativeButton; menu.lastChild() = secondButton;
    nativeButton->nextSibling() = secondButton; secondButton->prevSibling() = nativeButton;
    secondButton->Y() = 30;
    root->FocusWindow() = nativeButton;
    nativeButton->TextColors.Normal = {10,20,30,255};
    nativeButton->TextColors.NormalFocus = {90,80,70,255};
    nativeButton->UpdateButtonStyle(); assert(nativeButton->curTextColor().R == 90);
    assert(root->MoveFocusDown() == secondButton);
    nativeButton->UpdateButtonStyle(); assert(nativeButton->curTextColor().R == 10);
    assert(root->MoveFocusDown() == nativeButton);
    secondButton->bIsSensitive() = false;
    assert(root->MoveFocusDown() == nativeButton);
    secondButton->bIsSensitive() = true;
    assert(root->MoveTabGroupNext() == secondButton);
    puts("PASS: edit replacement, undo/redo, backspace boundary, size limit, uppercase, menu traversal");
    game->dxRootWindow = nullptr;
    game->keybindings["Joy7"] = "Button bFire";
    ControllerState controller;
    controller.device = 1;
    game->UpdateController(controller, 0.016f);
    controller.buttons[6] = true;
    controller.moveX = 0.5f;
    game->UpdateController(controller, 0.016f);
    assert(game->activeInputButtons["bFire"].count(IK_Joy7));
    assert(game->activeInputAxes["aStrafe"][IK_JoyX] == 3000);
    game->InputCommand("Button bFire", IK_LeftMouse, 20);
    game->UpdateController({}, 0.016f);
    assert(game->activeInputAxes.empty());
    assert(game->activeInputButtons["bFire"].count(IK_LeftMouse));
    game->ReleaseInput(IK_LeftMouse);
    assert(game->activeInputButtons.empty());
    controller.buttons[6] = false;
    game->UpdateController(controller, 0.016f);
    controller.buttons[6] = true;
    game->UpdateController(controller, 0.016f);
    controller.moveX = 0;
    game->dxRootWindow = root;
    root->FocusWindow() = &button;
    button.parentOwner() = &menu;
    game->UpdateController(controller, 0.016f);
    assert(game->activeInputButtons.empty() && game->activeInputAxes.empty());
    int beforePresses = button.presses;
    controller.buttons[0] = true;
    game->UpdateController(controller, 0.016f);
    assert(button.presses == beforePresses + 1);
    game->UpdateController(controller, 0.5f);
    assert(button.presses == beforePresses + 1); // Confirm never repeats.
    controller.buttons[0] = false;
    game->UpdateController(controller, 0.016f);
    game->viewport->SetViewportRect(0, 0, 800, 600);
    root->grabbedWindow() = &button;
    root->MouseX() = 100; root->MouseY() = 100;
    controller.moveX = 0.5f;
    game->UpdateController(controller, 0.1f);
    assert(root->MouseX() > 100 && root->MouseY() == 100 && game->activeInputAxes.empty());
    controller.moveX = 0; controller.buttons[0] = true;
    game->UpdateController(controller, 0.016f);
    assert(button.mousePresses == 1 && button.presses == beforePresses + 1);
    game->UpdateController(controller, 0.5f); assert(button.mousePresses == 1);
    game->UpdateController({}, 0.016f); assert(button.mouseReleases == 1);
    root->grabbedWindow() = nullptr;
    puts("PASS: controller menu pointer, Cross click, no repeat, disconnect releases click, no gameplay axes");
    game->dxRootWindow = nullptr;
    game->UpdateController(controller, 0.016f);
    assert(game->activeInputButtons.empty()); // Held trigger cannot fire while closing a menu.
    game->OnWindowDeactivated();
    assert(game->activeInputAxes.empty());
    game->OnWindowActivated();
    auto* pauseLevel = UObject::Cast<ULevelInfo>(transient->NewObject("pause-level", game->packages->FindClass("Engine.LevelInfo"), ObjectFlags::Transient));
    game->LevelInfo = pauseLevel;
    pauseLevel->NetMode() = 0;
    game->OnWindowDeactivated(); assert(game->IsPaused());
    game->OnWindowActivated(); assert(!game->IsPaused());
    pauseLevel->Pauser() = "Existing menu pause";
    game->OnWindowDeactivated(); game->OnWindowActivated(); assert(game->IsPaused());
    pauseLevel->Pauser().clear(); game->OnWindowActivated();
    game->viewport->SetViewportRect(0, 0, 3200, 2000);
    game->interfaceScale = 1.0f;
    float virtualHeight = root->GetVirtualHeight();
    game->viewport->SetViewportRect(0, 0, 1600, 1000);
    assert(root->GetVirtualHeight() == virtualHeight);
    game->interfaceScale = 1.25f;
    assert(root->GetVirtualHeight() < virtualHeight);
    game->interfaceScale = 1.0f;
    puts("PASS: controller edges, analog input, disconnect, shared controls, menu isolation, focus pause, independent UI scaling");
    // Exercise the original MenuMain/DeusExRootWindow Escape bytecode as well.
    auto* realRoot = UObject::Cast<URootWindow>(transient->NewObject("original-root", game->deusExPackage->GetClass("DeusExRootWindow"), ObjectFlags::Transient));
    auto* realMenu = UObject::Cast<UWindow>(transient->NewObject("original-menu", game->deusExPackage->GetClass("MenuMain"), ObjectFlags::Transient));
    auto* realPawn = UObject::Cast<UPlayerPawnExt>(transient->NewObject("original-pawn", game->deusExPackage->GetClass("DeusExPlayer"), ObjectFlags::Transient));
    realRoot->bIsVisible() = true;
    realRoot->bIsSensitive() = true;
    realMenu->bIsVisible() = true;
    realMenu->bIsSensitive() = true;
    realRoot->parentPawn() = realPawn;
    realPawn->Player() = game->viewport;
    game->viewport->Actor() = realPawn;
    game->dxRootWindow = realRoot;
    realMenu->SetObject("root", realRoot);
    realMenu->SetObject("player", realPawn);
    realRoot->SetInt("winCount", 1);
    *static_cast<UObject**>(realRoot->GetProperty("winStack")) = realMenu;
    realRoot->firstChild() = realRoot->lastChild() = realMenu;
    realMenu->parentOwner() = realRoot;
    button.parentOwner() = realMenu;
    realRoot->FocusWindow() = &button;
    assert(realRoot->OnWindowKeyDown(IK_Escape));
    assert(realRoot->GetInt("winCount") == 0);
    assert(realRoot->lastChild() == nullptr);
    puts("PASS: original Escape menu script, parent menu routing, consumed events, stale focus, repeats, release cleanup, typed input reset");
    fflush(stdout);
    // Avoid the application's shutdown path, which saves user configuration/logs.
    std::_Exit(0);
}
