
#include "Precomp.h"
#include "UListWindow.h"
#include "Engine.h"
#include "Packages/Engine/Resources/UFont.h"
#include "Packages/Engine/Resources/USound.h"
#include "Packages/Extension/Windows/UGC.h"

void UListWindow::InitWindow()
{
	focusLine() = -1;
	anchorLine() = -1;
	lastIndex() = -1;
	bMultiSelect() = true;
	focusThickness() = 1.0f;
	UWindow::InitWindow();
}

int UListWindow::AddRow(const std::string& rowStr, std::optional<int> clientData)
{
	int id = nextRowId++;
	Item item;
	item.id = id;
	if (clientData.has_value())
		item.clientInt = clientData.value();
	items.push_back(std::move(item));
	ModifyRow(id, rowStr);
	return id;
}

void UListWindow::AddSortColumn(int colIndex, std::optional<bool> bReverse, std::optional<bool> bCaseSensitive)
{
	if (colIndex < 0 || (size_t)colIndex >= columns.size()) return;
	RemoveSortColumn(colIndex);
	sortColumns.push_back({colIndex, bReverse.value_or(false), bCaseSensitive.value_or(false)});
	if (bAutoSort()) Sort();
}

void UListWindow::DeleteAllRows()
{
	items.clear();
	nextRowId = 1;
	focusLine() = anchorLine() = -1;
	firstVisibleRow = 0;
}

void UListWindow::DeleteRow(int rowId)
{
	int index = RowIdToIndex(rowId);
	if (index < 0) return;
	int focused = GetFocusRow();
	items.erase(items.begin() + index);
	focusLine() = RowIdToIndex(focused);
	anchorLine() = focusLine();
	ShowFocusRow();
}

void UListWindow::EnableAutoExpandColumns(std::optional<bool> bAutoExpand)
{
	bAutoExpandColumns() = bAutoExpand.has_value() ? bAutoExpand.value() : true;
	// To do: actually expand the columns
	LogUnimplemented("ListWindow.EnableAutoExpandColumns");
}

void UListWindow::EnableAutoSort(std::optional<bool> bNewAutoSort)
{
	bAutoSort() = bNewAutoSort.has_value() ? bNewAutoSort.value() : true;
	if (bAutoSort()) Sort();
}

void UListWindow::EnableHotKeys(std::optional<bool> bEnable)
{
	bHotKeys() = bEnable.has_value() ? bEnable.value() : true;
}

void UListWindow::EnableMultiSelect(std::optional<bool> bEnableMultiSelect)
{
	bMultiSelect() = bEnableMultiSelect.has_value() ? bEnableMultiSelect.value() : true;
}

uint8_t UListWindow::GetColumnAlignment(int colIndex)
{
	if (colIndex < 0 || (size_t)colIndex >= columns.size())
		return 0;
	return (uint8_t)columns[colIndex].align;
}

void UListWindow::GetColumnColor(int colIndex, Color& colColor)
{
	if (colIndex < 0 || (size_t)colIndex >= columns.size())
		colColor = { 255, 255, 255, 255 };
	else
		colColor = columns[colIndex].color;
}

UObject* UListWindow::GetColumnFont(int colIndex)
{
	if (colIndex < 0 || (size_t)colIndex >= columns.size())
		return nullptr;
	return columns[colIndex].font;
}

std::string UListWindow::GetColumnTitle(int colIndex)
{
	if (colIndex < 0 || (size_t)colIndex >= columns.size())
		return {};
	return columns[colIndex].title;
}

uint8_t UListWindow::GetColumnType(int colIndex)
{
	if (colIndex < 0 || (size_t)colIndex >= columns.size())
		return 0;
	return columns[colIndex].type;
}

float UListWindow::GetColumnWidth(int colIndex)
{
	if (colIndex < 0 || (size_t)colIndex >= columns.size())
		return 0;
	return columns[colIndex].width;
}

std::string UListWindow::GetField(int rowId, int colIndex)
{
	int rowIndex = RowIdToIndex(rowId);
	if (rowIndex == -1)
		return {};
	if (colIndex < 0 || (size_t)colIndex >= items[rowIndex].cells.size())
		return {};
	return items[rowIndex].cells[colIndex];
}

void UListWindow::GetFieldMargins(float& marginWidth, float& marginHeight)
{
	// UNUSED from scripts.
	LogUnimplemented("ListWindow.GetFieldMargins");
}

float UListWindow::GetFieldValue(int rowId, int colIndex)
{
	return (float)std::atof(GetField(rowId, colIndex).c_str());
}

int UListWindow::GetFocusRow()
{
	if (focusLine() < 0 || (size_t)focusLine() >= items.size())
		return 0;
	return items[focusLine()].id;
}

int UListWindow::GetNumColumns()
{
	return (int)columns.size();
}

int UListWindow::GetNumRows()
{
	return (int)items.size();
}

int UListWindow::GetNumSelectedRows()
{
	int count = 0;
	for (auto& item : items)
	{
		if (item.selected)
			count++;
	}
	return count;
}

int UListWindow::GetPageSize()
{
	return std::max(1, (int)(Height() / std::max(lineSize(), 1.0f)));
}

int UListWindow::GetRowClientInt(int rowId)
{
	int rowIndex = RowIdToIndex(rowId);
	if (rowIndex == -1)
		return 0;
	return items[rowIndex].clientInt;
}

UObject* UListWindow::GetRowClientObject(int rowId)
{
	int rowIndex = RowIdToIndex(rowId);
	if (rowIndex == -1)
		return 0;
	return items[rowIndex].clientObj;
}

int UListWindow::GetSelectedRow()
{
	for (auto& item : items)
	{
		if (item.selected)
		{
			return item.id;
		}
	}
	return 0;
}

void UListWindow::HideColumn(int colIndex, std::optional<bool> bHide)
{
	if (colIndex < 0 || (size_t)colIndex >= columns.size())
		return;
	columns[colIndex].hidden = bHide.has_value() ? bHide.value() : true;
}

int UListWindow::IndexToRowId(int index)
{
	if (index < 0 || (size_t)index >= items.size())
		return -1;
	return items[index].id;
}

bool UListWindow::IsAutoExpandColumnsEnabled()
{
	return bAutoExpandColumns();
}

bool UListWindow::IsAutoSortEnabled()
{
	return bAutoSort();
}

bool UListWindow::IsColumnHidden(int colIndex)
{
	if (colIndex < 0 || (size_t)colIndex >= columns.size())
		return false;
	return columns[colIndex].hidden;
}

bool UListWindow::IsMultiSelectEnabled()
{
	return bMultiSelect();
}

bool UListWindow::IsRowSelected(int rowId)
{
	int rowIndex = RowIdToIndex(rowId);
	if (rowIndex == -1)
		return false;
	return items[rowIndex].selected;
}

void UListWindow::ModifyRow(int rowId, const std::string& rowStr)
{
	int rowIndex = RowIdToIndex(rowId);
	if (rowIndex == -1)
		return;

	auto& item = items[rowIndex];
	item.cells.clear();
	const std::string delimiter = Delimiter().empty() ? ";" : Delimiter();
	size_t start = 0, pos;
	while ((pos = rowStr.find(delimiter, start)) != std::string::npos)
	{
		item.cells.push_back(rowStr.substr(start, pos - start));
		start = pos + delimiter.size();
	}
	item.cells.push_back(rowStr.substr(start));
	if (bAutoSort()) Sort();
}

void UListWindow::MoveRow(uint8_t Move, std::optional<bool> bSelect, std::optional<bool> bClearRows, std::optional<bool> bDrag)
{
	if (items.empty() || Move > 5) return;
	int index = focusLine();
	if (index < 0) index = 0;
	else if (Move == 0) --index;
	else if (Move == 1) ++index;
	else if (Move == 2) index -= GetPageSize();
	else if (Move == 3) index += GetPageSize();
	if (Move == 4) index = 0;
	if (Move == 5) index = (int)items.size() - 1;
	SetRow(IndexToRowId(std::clamp(index, 0, (int)items.size() - 1)), bSelect, bClearRows, bDrag);
}

void UListWindow::PlayListSound(UObject* listSound, std::optional<float> Volume, std::optional<float> Pitch)
{
	// UNUSED from scripts.
	LogUnimplemented("ListWindow.PlayListSound");
}

void UListWindow::RemoveSortColumn(int colIndex)
{
	sortColumns.erase(std::remove_if(sortColumns.begin(), sortColumns.end(), [=](const SortColumn& col) { return col.index == colIndex; }), sortColumns.end());
}

void UListWindow::ResetSortColumns(std::optional<bool> bSort)
{
	sortColumns.clear();
	if (bSort.value_or(true)) Sort();
}

void UListWindow::ResizeColumns(std::optional<bool> bExpandOnly)
{
	// UNUSED from scripts.
	LogUnimplemented("ListWindow.ResizeColumns");
}

int UListWindow::RowIdToIndex(int rowId)
{
	int index = 0;
	for (auto& item : items)
	{
		if (item.id == rowId)
		{
			return index;
		}
		index++;
	}
	return -1;
}

void UListWindow::SelectAllRows(std::optional<bool> bSelect)
{
	bool selected = bSelect.has_value() ? bSelect.value() : true;
	for (auto& item : items)
	{
		item.selected = selected;
	}
}

void UListWindow::SelectRow(int rowId, std::optional<bool> bSelect)
{
	bool selected = bSelect.has_value() ? bSelect.value() : true;
	int rowIndex = RowIdToIndex(rowId);
	if (rowIndex != -1)
		items[rowIndex].selected = selected;
}

void UListWindow::SelectToRow(int rowId, std::optional<bool> bClearRows, std::optional<bool> bInvert, std::optional<bool> bSpanRows)
{
	// UNUSED from scripts.
	LogUnimplemented("ListWindow.SelectToRow");
}

void UListWindow::SetColumnAlignment(int colIndex, uint8_t newAlign)
{
	if (colIndex < 0 || (size_t)colIndex >= columns.size())
		return;
	columns[colIndex].align = (EHAlign)newAlign;
}

void UListWindow::SetColumnColor(int colIndex, const Color& NewColor)
{
	if (colIndex < 0 || (size_t)colIndex >= columns.size())
		return;
	columns[colIndex].color = NewColor;
}

void UListWindow::SetColumnFont(int colIndex, UObject* NewFont)
{
	if (colIndex < 0 || (size_t)colIndex >= columns.size())
		return;
	columns[colIndex].font = UObject::Cast<UFont>(NewFont);
}

void UListWindow::SetColumnTitle(int colIndex, const std::string& Title)
{
	if (colIndex < 0 || (size_t)colIndex >= columns.size())
		return;
	columns[colIndex].title = Title;
}

void UListWindow::SetColumnType(int colIndex, uint8_t newType, std::optional<std::string> newFmt)
{
	if (colIndex < 0 || (size_t)colIndex >= columns.size())
		return;
	columns[colIndex].type = newType;
	columns[colIndex].format = newFmt;
}

void UListWindow::SetColumnWidth(int colIndex, float newWidth)
{
	if (colIndex < 0 || (size_t)colIndex >= columns.size())
		return;
	columns[colIndex].width = newWidth;
}

void UListWindow::SetDelimiter(const std::string& newDelimiter)
{
	Delimiter() = newDelimiter;
}

void UListWindow::SetField(int rowId, int colIndex, const std::string& fieldStr)
{
	if (colIndex < 0 || (size_t)colIndex >= columns.size())
		return;
	int rowIndex = RowIdToIndex(rowId);
	if (rowIndex == -1)
		return;
	if (items[rowIndex].cells.size() <= (size_t)colIndex)
		items[rowIndex].cells.resize(colIndex + 1);
	items[rowIndex].cells[colIndex] = fieldStr;
}

void UListWindow::SetFieldMargins(float newMarginWidth, float newMarginHeight)
{
	// UNUSED from scripts.
	LogUnimplemented("ListWindow.SetFieldMargins");
}

void UListWindow::SetFieldValue(int rowId, int colIndex, float NewValue)
{
	SetField(rowId, colIndex, std::to_string(NewValue));
}

void UListWindow::SetFocusColor(const Color& NewColor)
{
	focusColor() = NewColor;
}

void UListWindow::SetFocusRow(int rowId, std::optional<bool> bMoveTo, std::optional<bool> bAnchor)
{
	focusLine() = RowIdToIndex(rowId);
	if (bAnchor.value_or(true)) anchorLine() = focusLine();
	if (bMoveTo.value_or(true)) ShowFocusRow();
}

void UListWindow::SetFocusTexture(UObject* NewTexture)
{
	focusTexture() = UObject::Cast<UTexture>(NewTexture);
}

void UListWindow::SetFocusThickness(float newThickness)
{
	focusThickness() = newThickness;
}

void UListWindow::SetHighlightColor(const Color& NewColor)
{
	highlightColor() = NewColor;
}

void UListWindow::SetHighlightTextColor(const Color& NewColor)
{
	highlightTextColor = NewColor;
}

void UListWindow::SetHighlightTexture(UObject* NewTexture)
{
	highlightTexture() = UObject::Cast<UTexture>(NewTexture);
}

void UListWindow::SetHotKeyColumn(int colIndex)
{
	hotKeyCol() = colIndex;
}

void UListWindow::SetListSounds(std::optional<UObject*> newActivateSound, std::optional<UObject*> newMoveSound)
{
	if (newActivateSound.has_value())
		ActivateSound() = UObject::Cast<USound>(newActivateSound.value());
	if (newMoveSound.has_value())
		moveSound() = UObject::Cast<USound>(newMoveSound.value());
}

void UListWindow::SetNumColumns(int newCols)
{
	columns.resize(std::max(0, newCols));
}

void UListWindow::SetRow(int rowId, std::optional<bool> bSelect, std::optional<bool> bClearRows, std::optional<bool> bDrag)
{
	int index = RowIdToIndex(rowId);
	if (index < 0) return;
	if (bClearRows.value_or(true) || !bMultiSelect()) SelectAllRows(false);
	if (bSelect.value_or(true))
	{
		int anchor = bDrag.value_or(false) && bMultiSelect() && anchorLine() >= 0 ? anchorLine() : index;
		for (int i = std::min(anchor, index); i <= std::max(anchor, index); ++i) items[i].selected = true;
	}
	SetFocusRow(rowId, true, !bDrag.value_or(false));
	DispatchListSelectionChanged();
}

void UListWindow::SetRowClientInt(int rowId, int clientInt)
{
	int rowIndex = RowIdToIndex(rowId);
	if (rowIndex == -1)
		return;
	items[rowIndex].clientInt = clientInt;
}

void UListWindow::SetRowClientObject(int rowId, UObject* clientObj)
{
	int rowIndex = RowIdToIndex(rowId);
	if (rowIndex == -1)
		return;
	items[rowIndex].clientObj = clientObj;
}

void UListWindow::SetSortColumn(int colIndex, std::optional<bool> bReverse, std::optional<bool> bCaseSensitive)
{
	sortColumns.clear();
	AddSortColumn(colIndex, bReverse, bCaseSensitive);
}

void UListWindow::ShowFocusRow()
{
	int page = GetPageSize();
	if (focusLine() >= 0) {
		if (focusLine() < firstVisibleRow) firstVisibleRow = focusLine();
		if (focusLine() >= firstVisibleRow + page) firstVisibleRow = focusLine() - page + 1;
	}
	firstVisibleRow = std::clamp(firstVisibleRow, 0, std::max(0, (int)items.size() - page));
}

void UListWindow::Sort()
{
	int focused = GetFocusRow(), anchor = IndexToRowId(anchorLine());
	std::stable_sort(items.begin(), items.end(), [&](const Item& a, const Item& b) {
		for (auto col : sortColumns) {
			if ((size_t)col.index >= columns.size()) continue;
			std::string av = (size_t)col.index < a.cells.size() ? a.cells[col.index] : "";
			std::string bv = (size_t)col.index < b.cells.size() ? b.cells[col.index] : "";
			int order;
			if (columns[col.index].type != 0) {
				double an = std::strtod(av.c_str(), nullptr), bn = std::strtod(bv.c_str(), nullptr);
				order = an < bn ? -1 : an > bn ? 1 : 0;
			} else {
				if (!col.caseSensitive) {
					for (char& c : av) c = (char)std::tolower((unsigned char)c);
					for (char& c : bv) c = (char)std::tolower((unsigned char)c);
				}
				order = av.compare(bv);
			}
			if (order) return col.reverse ? order > 0 : order < 0;
		}
		return false;
	});
	focusLine() = RowIdToIndex(focused);
	anchorLine() = RowIdToIndex(anchor);
	ShowFocusRow();
}

void UListWindow::ToggleRowSelection(int rowId)
{
	int rowIndex = RowIdToIndex(rowId);
	if (rowIndex == -1)
		return;
	items[rowIndex].selected = !items[rowIndex].selected;
	DispatchListSelectionChanged();
}

void UListWindow::DrawWindow(UGC* gc)
{
	UFont* font = normalFont();
	if (!font)
		return;

	float w = Width();
	float h = Height();
	float lineHeight = (float)font->GetGlyph('X').VSize + 2;
	lineSize() = lineHeight;

	float y = 0.0f;
	ShowFocusRow();
	for (int lineIndex = firstVisibleRow; lineIndex < (int)items.size() && y < h; ++lineIndex)
	{
		auto& item = items[lineIndex];
		if (lineIndex == focusLine())
		{
			gc->SetTextColor(highlightTextColor);
			gc->SetTileColor(focusColor());
			if (focusTexture())
				gc->DrawTexture(0.0f, y, w, lineHeight, 0.0f, 0.0f, focusTexture());
		}

		if (item.selected)
		{
			float t = focusThickness();
			gc->SetTextColor(highlightTextColor);
			gc->SetTileColor(highlightColor());
			if (highlightTexture())
				gc->DrawTexture(t, y + t, std::max(w - 2.0f * t, 0.0f), std::max(lineHeight - t * 2.0f, 0.0f), 0.0f, 0.0f, highlightTexture());
		}
		else
		{
			gc->SetTextColor(TextColor());
			gc->SetTileColor(tileColor());
		}

		float x = 0.0f;
		size_t colIndex = 0;
		for (auto& col : columns)
		{
			if (col.hidden) { ++colIndex; continue; }
			if (item.cells.size() > colIndex)
			{
				UFont* colFont = col.font ? col.font : font;
				gc->SetFont(colFont);
				gc->SetAlignments((uint8_t)col.align, (uint8_t)EVAlign::Center);

				//if (!item.selected)
				//	gc->SetTextColor(col.color);

				gc->DrawText(x, y, col.width, lineHeight, item.cells[colIndex]);
			}
			x += col.width;
			colIndex++;
		}
		y += lineHeight;
	}
}

bool UListWindow::MouseButtonPressed(float pointX, float pointY, EInputKey button, int numClicks)
{
	SetFocusWindow(this);

	if (UWindow::MouseButtonPressed(pointX, pointY, button, numClicks))
		return true;

	if (lineSize() <= 0.0f)
		return true;

	int index = firstVisibleRow + (int)std::floor(pointY / lineSize());
	int rowId = IndexToRowId(index);
	if (rowId > 0)
	{
		SetRow(rowId, true, true, false);

	}

	return true;
}

bool UListWindow::MouseButtonReleased(float pointX, float pointY, EInputKey button, int numClicks)
{
	return UWindow::MouseButtonReleased(pointX, pointY, button, numClicks);
}

void UListWindow::DispatchListSelectionChanged()
{
	int numSelections = GetNumSelectedRows();
	int focusRowId = GetFocusRow();
	for (UWindow* cur = this; cur; cur = cur->parentOwner())
	{
		if (cur->ListSelectionChanged(this, numSelections, focusRowId))
			break;
	}
}
