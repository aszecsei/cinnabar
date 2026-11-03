using System.Runtime.InteropServices;
using Cinnabar.Editor.Link.Protocol;

namespace Cinnabar.Editor.Viewport;

/// <summary>What a pad reports, before the game's dead zones: the bits of XInput's wButtons, sticks from -1 to 1, and triggers from 0 to 1.</summary>
readonly record struct GamepadReading(ushort Buttons, float LeftX, float LeftY, float RightX, float RightY, float LeftTrigger, float RightTrigger);

/// <summary>Turns the pads into the game's input events: what changed since the game last heard, as core's window does for a game of its own (see docs/core/input.md#gamepads).</summary>
sealed class GamepadPoller(Func<int, GamepadReading?> read)
{
    const int Slots = 4;
    // XInput can take milliseconds on a slot that has no pad, so a call reads at most one of those.
    const long EmptySlotIntervalMs = 250;

    readonly bool[] _connected = new bool[Slots];
    readonly bool[] _told = new bool[Slots];
    readonly GamepadReading?[] _last = new GamepadReading?[Slots];
    long? _lastEmptyRead;
    int _nextEmptySlot;

    /// <summary>The events for what changed, at a time in milliseconds.</summary>
    public InputEvent[] Poll(long nowMs)
    {
        var events = new List<InputEvent>();
        for (var slot = 0; slot < Slots; slot++)
        {
            if (_connected[slot])
            {
                Update(slot, events);
            }
        }
        if (_lastEmptyRead is not { } last || nowMs - last >= EmptySlotIntervalMs)
        {
            for (var i = 0; i < Slots; i++)
            {
                var slot = (_nextEmptySlot + i) % Slots;
                if (!_connected[slot])
                {
                    Update(slot, events);
                    _nextEmptySlot = (slot + 1) % Slots;
                    _lastEmptyRead = nowMs;
                    break;
                }
            }
        }
        return [.. events];
    }

    /// <summary>The game forgot the pads, because it lost the input: the next poll tells it about each of them again.</summary>
    public void Forget() => Array.Clear(_told);

    void Update(int slot, List<InputEvent> events)
    {
        var reading = read(slot);
        _connected[slot] = reading != null;
        if (reading == _last[slot] && (_told[slot] || reading == null))
        {
            return;
        }
        _last[slot] = reading;
        _told[slot] = true;
        events.Add(GameInput.Pad(slot, reading));
    }

    /// <summary>A slot's pad, or null when it has none.</summary>
    public static GamepadReading? ReadXInput(int slot)
    {
        if (XInputGetState((uint)slot, out var state) != 0)
        {
            return null;
        }
        return new GamepadReading(
            state.Buttons,
            Stick(state.LeftX), Stick(state.LeftY), Stick(state.RightX), Stick(state.RightY),
            state.LeftTrigger / 255f, state.RightTrigger / 255f);
    }

    static float Stick(short value) => Math.Max(value / 32767f, -1);

    [StructLayout(LayoutKind.Sequential)]
    struct XInputState
    {
        public uint PacketNumber;
        public ushort Buttons;
        public byte LeftTrigger;
        public byte RightTrigger;
        public short LeftX;
        public short LeftY;
        public short RightX;
        public short RightY;
    }

    [DllImport("xinput1_4.dll")]
    static extern uint XInputGetState(uint userIndex, out XInputState state);
}
