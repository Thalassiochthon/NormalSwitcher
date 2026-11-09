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
    private bool _modDown;
    private bool _otherDuringHold;

    public event Action? Triggered;

    public TriggerDetector(TriggerKind kind) => _kind = kind;

    public TriggerKind Kind
    {
        get => _kind;
        set { _kind = value; _modDown = false; _otherDuringHold = false; _lastTapTime = 0; }
    }

    private uint SingleVk => _kind == TriggerKind.PauseBreak ? Win32.VK_PAUSE : 0;

    private bool IsMod(uint vk) => _kind switch
    {
        TriggerKind.CtrlDoubleTap => vk == Win32.VK_LCONTROL || vk == Win32.VK_RCONTROL,
        TriggerKind.ShiftDoubleTap => vk == Win32.VK_LSHIFT || vk == Win32.VK_RSHIFT,
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
            if (!_modDown) { _modDown = true; _otherDuringHold = false; }  // первое нажатие удержания
            // повторные keydown при удержании — флаги не трогаем
        }
        else
        {
            if (_modDown) _otherDuringHold = true;  // модификатор + другая клавиша → не тап
            _lastTapTime = 0;                        // набор прерывает последовательность двойного тапа
        }
    }

    public void OnKeyUp(uint vk)
    {
        if (SingleVk != 0 || !IsMod(vk)) return;
        bool wasTap = _modDown && !_otherDuringHold;
        _modDown = false;
        _otherDuringHold = false;
        if (!wasTap) return;

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
