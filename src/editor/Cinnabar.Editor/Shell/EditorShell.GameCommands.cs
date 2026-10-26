using Cinnabar.Editor.Commands;
using Cinnabar.Editor.Commands.Ribbon;
using Cinnabar.Editor.Panels;
using GameCommandResult = Cinnabar.Editor.Link.Protocol.GameCommandResult;
using GameCommands = Cinnabar.Editor.Link.Protocol.GameCommands;
using Operation = Cinnabar.Editor.Document.Operation;
using RunGameCommand = Cinnabar.Editor.Link.Protocol.RunGameCommand;

namespace Cinnabar.Editor.Shell;

/// <summary>
/// The game's commands (see docs/editor/shell-and-panels.md#commands): the game describes them with its types, the editor registers
/// them as <c>game.</c> commands on the tabs and in the groups that they name, and running one runs it in the game. A
/// command that edits the scene sends back operations, which the editor applies as one undo entry. The list comes again
/// after a code reload, and replaces the one before.
/// </summary>
public sealed partial class EditorShell
{
    public const string GameCommandPrefix = "game.";

    readonly Dictionary<string, Link.Protocol.GameCommandInfo> _gameCommands = [];
    RibbonLayout? _baseRibbon;

    /// <summary>The game's commands, by the game's IDs.</summary>
    public IReadOnlyDictionary<string, Link.Protocol.GameCommandInfo> GameCommandInfos => _gameCommands;

    void OnGameCommands(GameCommands list)
    {
        foreach (var id in _gameCommands.Keys)
        {
            Commands.Unregister(GameCommandPrefix + id);
        }
        _gameCommands.Clear();
        foreach (var info in list.Commands)
        {
            if (Commands.Find(GameCommandPrefix + info.Id) != null)
            {
                Console.Add(LogLevel.Warning, $"commands: the game describes {info.Id} twice");
                continue;
            }
            _gameCommands[info.Id] = info;
            var id = info.Id;
            Commands.Register(new Command(GameCommandPrefix + id, info.Label, () => RunCommandInGame(id))
            {
                Description = info.Description.Length > 0 ? info.Description : null,
                Icon = info.Icon.Length > 0 ? info.Icon : null,
                // One that edits waits for Edit, as every edit does.
                CanExecuteWhen = () => Host.Linked && (!info.Edits || IsEditing),
            });
        }
        _baseRibbon ??= Ribbon;
        Ribbon = _baseRibbon.WithCommands(_gameCommands.Values.Select(c => (
            c.Tab.Length > 0 ? c.Tab : "Game",
            c.Group.Length > 0 ? c.Group : "Commands",
            GameCommandPrefix + c.Id)));
        RibbonChanged?.Invoke();
        Commands.InvalidateAll();
    }

    /// <summary>Runs a game command in the game, with the selection that the game has.</summary>
    public void RunCommandInGame(string id) => Host.Send(new RunGameCommand(id));

    void OnGameCommandResult(GameCommandResult result)
    {
        if (result.Message.Length > 0)
        {
            Console.Add(LogLevel.Info, result.Message);
        }
        if (result.Operations.Length == 0)
        {
            return;
        }
        Operation[] ops;
        try
        {
            ops = [.. result.Operations.Select(Operation.FromWire)];
        }
        catch (InvalidOperationException e)
        {
            Console.Add(LogLevel.Error, $"commands: {result.Id} sent an operation that the editor cannot read: {e.Message}");
            return;
        }
        var label = _gameCommands.TryGetValue(result.Id, out var info) ? info.Label : result.Id;
        Edit(label, ops);
        // A command that creates entities selects them, as New Entity does.
        if (ops.OfType<Document.CreateEntity>().Select(c => c.Created.Id).ToList() is { Count: > 0 } created)
        {
            SelectScenes(created);
        }
    }
}
