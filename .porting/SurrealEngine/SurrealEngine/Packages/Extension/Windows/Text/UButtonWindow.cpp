
#include "Precomp.h"
#include "UButtonWindow.h"
#include "Packages/Extension/Windows/UGC.h"
#include "Packages/Engine/Resources/USound.h"
#include "Packages/Engine/Resources/UFont.h"
#include "Packages/Engine/Resources/Textures/UTexture.h"

void UButtonWindow::UpdateButtonStyle()
{
    bool pressed = bButtonPressed(), focus = IsFocusWindow();
    auto choose = [&](const auto& styles) {
        if (!bIsSensitive()) return pressed ? styles.PressedInsensitive : styles.NormalInsensitive;
        if (focus) return pressed ? styles.PressedFocus : styles.NormalFocus;
        return pressed ? styles.Pressed : styles.Normal;
    };
    curTexture() = choose(ButtonTextures);
    if (!curTexture()) curTexture() = ButtonTextures.Normal;
    curTileColor() = choose(ButtonColors);
    curTextColor() = choose(TextColors);
}

void UButtonWindow::DrawWindow(UGC* gc)
{
	UpdateButtonStyle();
	gc->SetTileColor(curTileColor());
	if (curTexture())
	{
		gc->DrawStretchedTexture(
			0.0f, 0.0f, Width(), Height(),
			0.0f, 0.0f, (float)curTexture()->USize(), (float)curTexture()->VSize(),
			curTexture());
	}

	if (normalFont())
	{
		gc->SetFont(normalFont());
		float xMargin = hMargin();
		float yMargin = vMargin();
		float w = Width() - 2.0f * xMargin;
		float h = Height() - 2.0f * yMargin;
		if (w > 0.0f && h > 0.0f)
		{
			gc->SetTextColor(curTextColor());
			gc->SetAlignments(HAlign(), VAlign());
			gc->DrawText(xMargin, yMargin, w, h, Text());
		}
		// DrawDebugBox(gc);
	}

	// Note: we are intentionally not calling UTextWindow::DrawWindow
	UWindow::DrawWindow(gc);
}

bool UButtonWindow::VirtualKeyPressed(EInputKey key, bool repeat)
{
    if (repeat && !bAutoRepeat() && (key == IK_Enter || key == IK_Space)) return true;
    return UTextWindow::VirtualKeyPressed(key, repeat);
}

void UButtonWindow::ActivateButton(EInputKey key)
{
	for (UWindow* cur = this; cur; cur = cur->parentOwner())
	{
		if (cur->ButtonActivated(this))
			break;
	}
}

void UButtonWindow::EnableAutoRepeat(std::optional<bool> bEnable, std::optional<float> newInitialDelay, std::optional<float> newRepeatRate)
{
	if (bEnable)
		bAutoRepeat() = *bEnable;
	if (newInitialDelay)
		initialDelay() = *newInitialDelay;
	if (newRepeatRate)
		repeatRate() = *newRepeatRate;

	repeatTime() = 0.0f; // To do: this field is probably used to figure out when its time to repeat
}

void UButtonWindow::EnableRightMouseClick(std::optional<bool> bEnable)
{
	bEnableRightMouseClick() = !bEnable || *bEnable;
}

void UButtonWindow::PressButton(std::optional<uint8_t> Key)
{
	// How does this differ from activate? It animates first maybe? use activateTimer() for that?
	ActivateButton(Key ? (EInputKey)(*Key) : IK_LeftMouse);
}

void UButtonWindow::SetActivateDelay(std::optional<float> newDelay)
{
	if (newDelay)
		activateDelay() = *newDelay;
}

void UButtonWindow::SetButtonColors(std::optional<Color> Normal, std::optional<Color> pressed, std::optional<Color> normalFocus, std::optional<Color> pressedFocus, std::optional<Color> normalInsensitive, std::optional<Color> pressedInsensitive)
{
	if (Normal)
		ButtonColors.Normal = *Normal;
	if (pressed)
		ButtonColors.Pressed = *pressed;
	if (normalFocus)
		ButtonColors.NormalFocus = *normalFocus;
	if (pressedFocus)
		ButtonColors.PressedFocus = *pressedFocus;
	if (normalInsensitive)
		ButtonColors.NormalInsensitive = *normalInsensitive;
	if (pressedInsensitive)
		ButtonColors.PressedInsensitive = *pressedInsensitive;
}

void UButtonWindow::SetButtonSounds(std::optional<UObject*> newPressSound, std::optional<UObject*> newClickSound)
{
	if (newPressSound)
		pressSound() = UObject::Cast<USound>(*newPressSound);
	if (newClickSound)
		clickSound() = UObject::Cast<USound>(*newClickSound);
}

void UButtonWindow::SetButtonTextures(std::optional<UObject*> Normal, std::optional<UObject*> pressed, std::optional<UObject*> normalFocus, std::optional<UObject*> pressedFocus, std::optional<UObject*> normalInsensitive, std::optional<UObject*> pressedInsensitive)
{
	if (Normal)
		ButtonTextures.Normal = UObject::Cast<UTexture>(*Normal);
	if (pressed)
		ButtonTextures.Pressed = UObject::Cast<UTexture>(*pressed);
	if (normalFocus)
		ButtonTextures.NormalFocus = UObject::Cast<UTexture>(*normalFocus);
	if (pressedFocus)
		ButtonTextures.PressedFocus = UObject::Cast<UTexture>(*pressedFocus);
	if (normalInsensitive)
		ButtonTextures.NormalInsensitive = UObject::Cast<UTexture>(*normalInsensitive);
	if (pressedInsensitive)
		ButtonTextures.PressedInsensitive = UObject::Cast<UTexture>(*pressedInsensitive);
}

void UButtonWindow::SetTextColors(std::optional<Color> Normal, std::optional<Color> pressed, std::optional<Color> normalFocus, std::optional<Color> pressedFocus, std::optional<Color> normalInsensitive, std::optional<Color> pressedInsensitive)
{
	if (Normal)
		TextColors.Normal = *Normal;
	if (pressed)
		TextColors.Pressed = *pressed;
	if (normalFocus)
		TextColors.NormalFocus = *normalFocus;
	if (pressedFocus)
		TextColors.PressedFocus = *pressedFocus;
	if (normalInsensitive)
		TextColors.NormalInsensitive = *normalInsensitive;
	if (pressedInsensitive)
		TextColors.PressedInsensitive = *pressedInsensitive;
}

void UButtonWindow::MouseMoved(float newX, float newY)
{
	if (bMousePressed())
	{
		bButtonPressed() = newX >= 0.0f && newX < Width() && newY >= 0.0f && newY < Height();
	}
	else
	{
		UTextWindow::MouseMoved(newX, newY);
	}
}

bool UButtonWindow::MouseButtonPressed(float pointX, float pointY, EInputKey button, int numClicks)
{
	SetFocusWindow(this);

	if (UTextWindow::MouseButtonPressed(pointX, pointY, button, numClicks))
		return true;

	bMousePressed() = true;
	bButtonPressed() = true;
	GrabMouse();
	return true;
}

bool UButtonWindow::MouseButtonReleased(float pointX, float pointY, EInputKey button, int numClicks)
{
	if (bMousePressed())
	{
		UngrabMouse();
		bMousePressed() = false;
		bButtonPressed() = false;
		if (pointX >= 0.0f && pointX < Width() && pointY >= 0.0f && pointY < Height())
			ActivateButton(button);
		return true;
	}

	return UTextWindow::MouseButtonReleased(pointX, pointY, button, numClicks);
}
