
#include "Precomp.h"
#include "UEditWindow.h"
#include "Engine.h"
#include "Packages/Extension/Windows/UGC.h"
#include "Packages/Engine/Resources/UFont.h"
#include "Packages/Engine/Resources/USound.h"

UEditWindow::EditState UEditWindow::CaptureEdit()
{
    return {Text(), insertPos(), selectStart(), selectEnd()};
}

void UEditWindow::RestoreEdit(const EditState& state)
{
    Text() = state.text;
    insertPos() = state.cursor;
    selectStart() = state.start;
    selectEnd() = state.end;
    AskParentForReconfigure();
    SetTextChangedFlag(true);
    DispatchTextChanged(true);
}

void UEditWindow::RememberEdit()
{
    redoStates.clear();
    if (maxUndos() <= 0) return;
    if (undoStates.size() >= (size_t)maxUndos()) undoStates.erase(undoStates.begin());
    undoStates.push_back(CaptureEdit());
}

void UEditWindow::ClearUndo() { undoStates.clear(); redoStates.clear(); }

void UEditWindow::Redo()
{
    if (!bEditable() || redoStates.empty()) return;
    undoStates.push_back(CaptureEdit());
    auto state = redoStates.back();
    redoStates.pop_back();
    RestoreEdit(state);
}

void UEditWindow::Undo()
{
    if (!bEditable() || undoStates.empty()) return;
    redoStates.push_back(CaptureEdit());
    auto state = undoStates.back();
    undoStates.pop_back();
    RestoreEdit(state);
}

void UEditWindow::SetMaxUndos(int newMaxUndos)
{
    maxUndos() = std::max(newMaxUndos, 0);
    ClearUndo();
}

void UEditWindow::Copy()
{
	int selStart = 0, selCount = 0;
	GetSelectedArea(selStart, selCount);
	if (selCount > 0)
	{
		engine->window->SetClipboardText(GetText().substr(selStart, selCount));
	}
	else
	{
		engine->window->SetClipboardText(GetText());
	}
}

void UEditWindow::Cut()
{
	Copy();
	int selStart = 0, selCount = 0;
	GetSelectedArea(selStart, selCount);
	if (selCount > 0)
		DeleteChar(false, true);
}

void UEditWindow::Paste()
{
	InsertText(engine->window->GetClipboardText(), true, {});
}

void UEditWindow::DeleteChar(std::optional<bool> bBefore, std::optional<bool> bUndo)
{
    if (!bEditable()) return;
    int start, count;
    GetSelectedArea(start, count);
    if (!count) {
        start = insertPos() - (bBefore.value_or(false) ? 1 : 0);
        if (start < 0 || start >= (int)Text().size()) return;
        count = 1;
    }
    if (bUndo.value_or(false)) RememberEdit();
    Text().erase(start, count);
    SetInsertionPoint(start, false);
    AskParentForReconfigure();
    SetTextChangedFlag(true);
    DispatchTextChanged(true);
}

void UEditWindow::EnableEditing(std::optional<bool> bEdit)
{
	bEditable() = bEdit ? *bEdit : true;
}

void UEditWindow::EnableSingleLineEditing(std::optional<bool> bSingle)
{
	bSingleLine() = bSingle ? *bSingle : true;
}

void UEditWindow::EnableUppercaseOnly(std::optional<bool> bUppercase)
{
	bUppercaseOnly() = bUppercase ? *bUppercase : true;
}

int UEditWindow::GetInsertionPoint()
{
	return insertPos();
}

void UEditWindow::GetSelectedArea(int& startPos, int& Count)
{
	int start = selectStart();
	int end = selectEnd();
	if (end < start)
		std::swap(start, end);
	startPos = start;
	Count = end - start;
}

bool UEditWindow::HasTextChanged()
{
	return textChanged;
}

void UEditWindow::TextModifiedByScript()
{
	ClearUndo();
	// This happens if script code calls UTextWindow::AppendText or UTextWindow::SetText
	insertPos() = (int)Text().size();
	selectStart() = insertPos();
	selectEnd() = insertPos();
}

bool UEditWindow::InsertText(std::optional<std::string> InsertText, std::optional<bool> bUndo, std::optional<bool> bSelect)
{
    if (!bEditable() || !InsertText) return false;
    if (*InsertText == "|n" && bSingleLine()) {
        for (UWindow* cur = this; cur; cur = cur->parentOwner())
            if (cur->EditActivated(this, HasTextChanged())) break;
        return true;
    }
    std::string value = *InsertText;
    if (bSingleLine()) {
        value.erase(std::remove(value.begin(), value.end(), '\r'), value.end());
        value.erase(std::remove(value.begin(), value.end(), '\n'), value.end());
    }
    if (bUppercaseOnly())
        for (char& c : value) c = (char)std::toupper((unsigned char)c);
    int start, count;
    GetSelectedArea(start, count);
    if (!count) start = std::clamp(insertPos(), 0, (int)Text().size());
    if (maxSize() > 0 && Text().size() - count + value.size() > (size_t)maxSize()) return false;
    if (value.empty() && !count) return true;
    if (bUndo.value_or(false)) RememberEdit();
    Text().replace(start, count, value);
    SetInsertionPoint(start + (int)value.size(), false);
    if (bSelect.value_or(false)) SetSelectedArea(start, (int)value.size());
    AskParentForReconfigure();
    SetTextChangedFlag(true);
    DispatchTextChanged(true);
    return true;
}

bool UEditWindow::IsEditingEnabled()
{
	return bEditable();
}

bool UEditWindow::IsSingleLineEditingEnabled()
{
	return bSingleLine();
}

float UEditWindow::TextWidth(int start, int end)
{
    float width = 0;
    for (int i = start; i < end; ++i) width += normalFont() ? normalFont()->GetGlyph(Text()[i]).USize : 1;
    return width;
}

std::vector<UEditWindow::EditLine> UEditWindow::LayoutLines()
{
    if (bSingleLine()) return {{0, (int)Text().size()}};
    std::vector<EditLine> lines;
    int start = 0, lastSpace = -1;
    float width = 0;
    for (int i = 0; i < (int)Text().size(); ++i) {
        if (Text()[i] == '\n') {
            lines.push_back({start, i}); start = i + 1; width = 0; lastSpace = -1;
            continue;
        }
        float advance = TextWidth(i, i + 1);
        if (width + advance > std::max(Width(), 1.0f) && i > start) {
            int end = lastSpace >= start ? lastSpace + 1 : i;
            lines.push_back({start, end}); start = end; i = end - 1;
            width = 0; lastSpace = -1; continue;
        }
        width += advance;
        if (Text()[i] == ' ') lastSpace = i;
    }
    lines.push_back({start, (int)Text().size()});
    return lines;
}

int UEditWindow::CursorLine(const std::vector<EditLine>& lines)
{
    int row = 0;
    while (row + 1 < (int)lines.size() && insertPos() >= lines[row + 1].start) ++row;
    return row;
}

void UEditWindow::MoveInsertionPoint(uint8_t moveInsert, std::optional<bool> bDrag)
{
    auto lines = LayoutLines();
    int row = CursorLine(lines);
    int target = insertPos();
    auto move = (EMoveInsert)moveInsert;
    switch (move) {
    case EMoveInsert::Left: target--; break;
    case EMoveInsert::Right: target++; break;
    case EMoveInsert::WordLeft: target = FindPreviousBreakCharacter(target - 1); break;
    case EMoveInsert::WordRight: target = FindNextBreakCharacter(target + 1); break;
    case EMoveInsert::StartOfLine: target = lines[row].start; break;
    case EMoveInsert::EndOfLine: target = lines[row].end; break;
    case EMoveInsert::Home: target = 0; break;
    case EMoveInsert::End: target = (int)Text().size(); break;
    case EMoveInsert::Up:
    case EMoveInsert::Down:
    case EMoveInsert::PageUp:
    case EMoveInsert::PageDown: {
        if (bSingleLine()) return;
        float x = TextWidth(lines[row].start, target);
        int count = (move == EMoveInsert::PageUp || move == EMoveInsert::PageDown)
            ? std::max(1, (int)(Height() / std::max(1, normalFont() ? normalFont()->GetGlyph('X').VSize : 1))) : 1;
        int next = std::clamp(row + ((move == EMoveInsert::Up || move == EMoveInsert::PageUp) ? -count : count), 0, (int)lines.size() - 1);
        target = lines[next].start;
        float width = 0;
        while (target < lines[next].end) {
            float advance = TextWidth(target, target + 1);
            if (width + advance * 0.5f > x) break;
            width += advance; ++target;
        }
        break;
    }
    }
    SetInsertionPoint(target, bDrag);
}

void UEditWindow::SetInsertionPoint(int NewPos, std::optional<bool> bDrag)
{
	insertPos() = std::clamp(NewPos, 0, (int)Text().size());
	if (!bDrag.has_value() || !bDrag.value())
		selectStart() = insertPos();
	selectEnd() = insertPos();
	blinkDelay() = 0.0f;
}

void UEditWindow::PlayEditSound(UObject* sound, std::optional<float> Volume, std::optional<float> Pitch)
{
	// What is the difference between this function and UWindow::PlaySound?
	PlaySound(sound, Volume, Pitch, {}, {});
}

void UEditWindow::SetEditCursor(std::optional<UObject*> newCursor, std::optional<UObject*> newCursorShadow, std::optional<Color> NewColor)
{
	if (newCursor.has_value())
		editCursor() = UObject::Cast<UTexture>(newCursor.value());
	if (newCursorShadow.has_value())
		editCursorShadow() = UObject::Cast<UTexture>(newCursorShadow.value());
	if (NewColor.has_value())
		editCursorColor() = NewColor.value();
}

void UEditWindow::SetEditSounds(std::optional<UObject*> newTypeSound, std::optional<UObject*> newDeleteSound, std::optional<UObject*> newEnterSound, std::optional<UObject*> newMoveSound)
{
	if (newTypeSound.has_value())
		typeSound() = UObject::Cast<USound>(newTypeSound.value());
	if (newDeleteSound.has_value())
		deleteSound() = UObject::Cast<USound>(newDeleteSound.value());
	if (newEnterSound.has_value())
		enterSound() = UObject::Cast<USound>(newEnterSound.value());
	if (newMoveSound.has_value())
		moveSound() = UObject::Cast<USound>(newMoveSound.value());
}

void UEditWindow::SetInsertionPointBlinkRate(std::optional<float> newBlinkStart, std::optional<float> newBlinkPeriod)
{
	if (newBlinkStart.has_value())
		blinkStart() = newBlinkStart.value();
	if (newBlinkPeriod.has_value())
		blinkPeriod() = newBlinkPeriod.value();
}

void UEditWindow::SetInsertionPointTexture(std::optional<UObject*> NewTexture, std::optional<Color> NewColor)
{
	if (NewTexture.has_value())
		insertTexture() = UObject::Cast<UTexture>(NewTexture.value());
	if (NewColor.has_value())
		insertColor() = NewColor.value();
}

void UEditWindow::SetInsertionPointType(uint8_t newType, std::optional<float> prefWidth, std::optional<float> prefHeight)
{
	insertType() = newType;
	if (prefWidth.has_value())
		insertPrefWidth() = prefWidth.value();
	if (prefHeight.has_value())
		insertPrefHeight() = prefHeight.value();
}

void UEditWindow::SetMaxSize(int newMaxSize)
{
	maxSize() = newMaxSize;
}

void UEditWindow::SetSelectedArea(int startPos, int Count)
{
	selectStart() = std::clamp(startPos, 0, (int)Text().size());
	selectEnd() = std::clamp(startPos + Count, 0, (int)Text().size());
	insertPos() = selectEnd();
}

void UEditWindow::SetSelectedAreaTextColor(std::optional<Color> NewColor)
{
	if (NewColor.has_value())
		selectColor() = NewColor.value();
}

void UEditWindow::SetSelectedAreaTexture(std::optional<UObject*> NewTexture, std::optional<Color> NewColor)
{
	if (NewTexture.has_value())
		selectTexture() = UObject::Cast<UTexture>(NewTexture.value());
	if (NewColor.has_value())
		selectColor() = NewColor.value();
}

void UEditWindow::ClearTextChangedFlag()
{
	textChanged = false;
}

void UEditWindow::SetTextChangedFlag(std::optional<bool> bSet)
{
	textChanged = bSet ? *bSet : true;
}

void UEditWindow::InitWindow()
{
	blinkPeriod() = 0.5f;
	maxUndos() = 32;
	bEditable() = true;
	bSingleLine() = true;
	ULargeTextWindow::InitWindow();
}

void UEditWindow::Tick(float timeElapsed)
{
	ULargeTextWindow::Tick(timeElapsed);

	blinkDelay() -= timeElapsed;
	if (blinkDelay() < -blinkPeriod())
		blinkDelay() = blinkPeriod();
}

void UEditWindow::DrawWindow(UGC* gc)
{
    UWindow::DrawWindow(gc);
    if (!normalFont()) return;
    gc->SetFont(normalFont());
    gc->SetAlignments((uint8_t)EHAlign::Left, (uint8_t)EVAlign::Top);
    gc->bWordWrap() = false;
    auto lines = LayoutLines();
    int cursorRow = CursorLine(lines);
    float lineHeight = std::max(1, normalFont()->GetGlyph('X').VSize);
    int page = std::max(1, (int)(Height() / lineHeight));
    int first = std::max(0, cursorRow - page + 1);
    int selStart = 0, selCount = 0;
    GetSelectedArea(selStart, selCount);
    float cursorX = TextWidth(lines[cursorRow].start, insertPos());
    float scrollX = bSingleLine() ? std::max(0.0f, cursorX - Width() + 2) : 0;
    for (int row = first; row < (int)lines.size() && row < first + page; ++row) {
        auto line = lines[row];
        float y = (row - first) * lineHeight;
        int start = std::max(selStart, line.start), end = std::min(selStart + selCount, line.end);
        if (end > start && selectTexture()) {
            auto tex = selectTexture();
            gc->SetTileColor(selectColor());
            gc->DrawStretchedTexture(TextWidth(line.start, start) - scrollX, y, TextWidth(start, end), lineHeight,
                0, 0, (float)tex->USize(), (float)tex->VSize(), tex);
        }
        gc->SetTextColor(TextColor());
        gc->DrawText(-scrollX, y, Width() + scrollX, lineHeight, Text().substr(line.start, line.end - line.start));
        if (row == cursorRow && IsFocusWindow() && blinkDelay() < 0 && insertTexture()) {
            auto tex = insertTexture();
            gc->SetTileColor(insertColor());
            gc->DrawStretchedTexture(cursorX - scrollX, y, 1, lineHeight, 0, 0, (float)tex->USize(), (float)tex->VSize(), tex);
        }
    }
}

bool UEditWindow::KeyPressed(std::string key)
{
	if (ULargeTextWindow::KeyPressed(key))
		return true;

	if (key.empty() || !IsEditingEnabled())
		return false;

	if (key.front() >= 32)
		InsertText(key, true, false);

	return true;
}

bool UEditWindow::VirtualKeyPressed(EInputKey key, bool bRepeat)
{
	return ULargeTextWindow::VirtualKeyPressed(key, bRepeat);
}

bool UEditWindow::MouseButtonPressed(float pointX, float pointY, EInputKey button, int numClicks)
{
	SetFocusWindow(this);
	ULargeTextWindow::MouseButtonPressed(pointX, pointY, button, numClicks);
	return true;
}

bool UEditWindow::MouseButtonReleased(float pointX, float pointY, EInputKey button, int numClicks)
{
	ULargeTextWindow::MouseButtonReleased(pointX, pointY, button, numClicks);
	return true;
}

void UEditWindow::DispatchTextChanged(bool modified)
{
	for (UWindow* cur = this; cur != nullptr; cur = cur->parentOwner())
	{
		if (cur->TextChanged(this, modified))
			break;
	}
}

int UEditWindow::FindNextBreakCharacter(int search_start)
{
	if (search_start >= int(Text().size()) - 1)
		return (int)Text().size();

	size_t pos = Text().find_first_of(break_characters, search_start);
	if (pos == std::string::npos)
		return (int)Text().size();
	return (int)pos;
}

int UEditWindow::FindPreviousBreakCharacter(int search_start)
{
	if (search_start <= 0)
		return 0;
	size_t pos = Text().find_last_of(break_characters, search_start);
	if (pos == std::string::npos)
		return 0;
	return (int)pos;
}

const std::string UEditWindow::break_characters = " ::;,.-";
