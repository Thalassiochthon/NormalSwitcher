using RuSwitcher.Win.Native;

namespace RuSwitcher.Win.Core;

/// <summary>
/// Определяет момент триггера из потока KeyDown/KeyUp. Выделенная клавиша (Pause/Break) — по
/// KeyDown. Двойной тап модификатора (Ctrl/Shift) — как Option-double-tap в macOS: модификатор
/// нажат и отпущен БЕЗ других клавиш между нажатием и отпусканием, дважды в пределах окна.
/// </summary>
public sealed class TriggerDetector
{
    private const long DoubleTapWindowMs = 350;

    private TriggerKind _kind;
    private long _lastTapTime;
    private uint _heldModifier;
    private bool _otherDuringHold;

    public event Action? Triggered;

    public TriggerDetector(TriggerKind kind) => _kind = kind;

    public TriggerKind Kind
    {
        get => _kind;
        set { _kind = value; _heldModifier = 0; _otherDuringHold = false; _lastTapTime = 0; }
    }

    private uint SingleVk => _kind == TriggerKind.PauseBreak ? Win32.VK_PAUSE : 0;

    private bool IsMod(uint vk) => _kind switch
    {
        TriggerKind.CtrlDoubleTap or TriggerKind.CtrlTap => vk is Win32.VK_LCONTROL or Win32.VK_RCONTROL,
        TriggerKind.ShiftDoubleTap or TriggerKind.ShiftTap => vk is Win32.VK_LSHIFT or Win32.VK_RSHIFT,
        TriggerKind.AltDoubleTap or TriggerKind.AltTap => vk is 0xA4 or 0xA5,
        TriggerKind.LeftCtrlDoubleTap => vk == Win32.VK_LCONTROL,
        TriggerKind.RightCtrlDoubleTap => vk == Win32.VK_RCONTROL,
        TriggerKind.LeftShiftDoubleTap => vk == Win32.VK_LSHIFT,
        TriggerKind.RightShiftDoubleTap => vk == Win32.VK_RSHIFT,
        TriggerKind.LeftAltDoubleTap => vk == 0xA4,
        TriggerKind.RightAltDoubleTap => vk == 0xA5,
        _ => false,
    };

    public void OnKeyDown(uint vk)
    {
        if (SingleVk != 0)
        {
            if (vk == SingleVk) Triggered?.Invoke();
            return;
        }
        if (IsMod(vk))
        {
            if (_heldModifier == 0) { _heldModifier = vk; _otherDuringHold = false; }
            else if (_heldModifier != vk) { _otherDuringHold = true; _lastTapTime = 0; }
            // повторные keydown при удержании — флаги не трогаем
        }
        else
        {
            if (_heldModifier != 0) _otherDuringHold = true;  // модификатор + другая клавиша → не тап
            _lastTapTime = 0;                        // набор прерывает последовательность двойного тапа
        }
    }

    public void OnKeyUp(uint vk)
    {
        if (SingleVk != 0 || vk != _heldModifier) return;
        bool wasTap = !_otherDuringHold;
        _heldModifier = 0;
        _otherDuringHold = false;
        if (!wasTap) return;
        if (_kind is TriggerKind.CtrlTap or TriggerKind.ShiftTap or TriggerKind.AltTap)
        {
            Triggered?.Invoke();
            return;
        }

        long now = Environment.TickCount64;
        if (_lastTapTime != 0 && now - _lastTapTime <= DoubleTapWindowMs)
        {
            _lastTapTime = 0;
            Triggered?.Invoke();
        }
        else
        {
            _lastTapTime = now;
        }
    }
}
