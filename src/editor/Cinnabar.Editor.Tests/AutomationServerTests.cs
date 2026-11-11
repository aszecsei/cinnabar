using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using Cinnabar.Editor.Model;

namespace Cinnabar.Editor.Tests;

/// <summary>The automation socket without an editor: requests go to the handler one at a time and answers come back in order.</summary>
public sealed class AutomationServerTests
{
    static async Task<(TcpClient Client, StreamReader Reader, StreamWriter Writer)> Connect(int port)
    {
        var client = new TcpClient();
        await client.ConnectAsync(IPAddress.Loopback, port, TestContext.Current.CancellationToken);
        var stream = client.GetStream();
        return (client, new StreamReader(stream, Encoding.UTF8), new StreamWriter(stream, new UTF8Encoding(false)) { AutoFlush = true, NewLine = "\n" });
    }

    static async Task<JsonElement> Ask(StreamReader reader, StreamWriter writer, string line)
    {
        await writer.WriteLineAsync(line.AsMemory(), TestContext.Current.CancellationToken);
        var answer = await reader.ReadLineAsync(TestContext.Current.CancellationToken);
        Assert.NotNull(answer);
        return JsonDocument.Parse(answer).RootElement;
    }

    [Fact]
    public async Task RequestsAreAnsweredInOrderWithTheirIds()
    {
        List<AutomationRequest> seen = [];
        await using var server = new AutomationServer((request, _) =>
        {
            seen.Add(request);
            return Task.FromResult(request.Command switch
            {
                "status" => new AutomationResponse(request.Id, true, Status: new AutomationStatus(true, "Running", "Edit", "E:/door.scene", "mygame", 42)),
                "screenshot" => new AutomationResponse(request.Id, true, ["E:/captures/a.png", "E:/captures/a.json"]),
                "timing" => new AutomationResponse(request.Id, true, Timing: new AutomationTiming(5, 4.5,
                    [new PassTiming("fog inject", "compute", 1, 0.2, 0.1, 0.3, 5)], [new AutomationViewportSize(0, 1920, 1080, true)])),
                _ => new AutomationResponse(request.Id, false, Error: $"unknown command {request.Command}"),
            });
        });
        server.Start();
        Assert.True(server.Port > 0);
        var (client, reader, writer) = await Connect(server.Port);
        using (client)
        {
            var status = await Ask(reader, writer, """{"id":1,"command":"status"}""");
            Assert.Equal(1, status.GetProperty("id").GetInt64());
            Assert.True(status.GetProperty("ok").GetBoolean());
            Assert.Equal("mygame", status.GetProperty("status").GetProperty("game").GetString());
            Assert.False(status.TryGetProperty("error", out _));

            var shot = await Ask(reader, writer, """{"id":2,"command":"screenshot","views":["depth","normals"],"path":"E:/captures/a"}""");
            Assert.Equal(["E:/captures/a.png", "E:/captures/a.json"], shot.GetProperty("files").EnumerateArray().Select(f => f.GetString()));
            Assert.Equal(["depth", "normals"], seen[1].Views!);
            Assert.Equal("E:/captures/a", seen[1].Path);

            var timing = await Ask(reader, writer, """{"id":5,"command":"timing","samples":5,"skip":2,"passes":["fog inject"]}""");
            var pass = timing.GetProperty("timing").GetProperty("passes")[0];
            Assert.Equal("fog inject", pass.GetProperty("name").GetString());
            Assert.Equal(0.2, pass.GetProperty("medianMs").GetDouble());
            Assert.True(timing.GetProperty("timing").GetProperty("viewports")[0].GetProperty("fixed").GetBoolean());
            Assert.Equal((5, 2), (seen[2].Samples, seen[2].Skip));
            Assert.Equal(["fog inject"], seen[2].Passes!);

            var unknown = await Ask(reader, writer, """{"id":3,"command":"dance"}""");
            Assert.False(unknown.GetProperty("ok").GetBoolean());
            Assert.Contains("dance", unknown.GetProperty("error").GetString());

            var malformed = await Ask(reader, writer, "{not json");
            Assert.Equal(0, malformed.GetProperty("id").GetInt64());
            Assert.False(malformed.GetProperty("ok").GetBoolean());

            var empty = await Ask(reader, writer, """{"id":4}""");
            Assert.Equal(4, empty.GetProperty("id").GetInt64());
            Assert.Contains("command", empty.GetProperty("error").GetString());
        }
        Assert.Equal(4, seen.Count);
    }

    [Fact]
    public async Task AHandlerThatThrowsAnswersWithTheError()
    {
        await using var server = new AutomationServer((_, _) => throw new InvalidOperationException("no host"));
        server.Start();
        var (client, reader, writer) = await Connect(server.Port);
        using (client)
        {
            var answer = await Ask(reader, writer, """{"id":7,"command":"gif"}""");
            Assert.Equal(7, answer.GetProperty("id").GetInt64());
            Assert.Equal("no host", answer.GetProperty("error").GetString());
        }
    }

    [Fact]
    public async Task TheUiCommandAnswersWithItsFile()
    {
        using var dir = new TempDirectory("ui-command");
        using var shell = TestShell.Open(dir, null, null);
        var request = new AutomationRequest(1, "ui", Path: dir.Combine("chrome"), Window: "contentBrowser");

        var none = await shell.HandleAutomation(request, TestContext.Current.CancellationToken);
        Assert.False(none.Ok);
        Assert.Contains("no window", none.Error);

        (string? Window, string Path)? asked = null;
        shell.UiCapture = (window, path) =>
        {
            asked = (window, path);
            return null;
        };
        var drawn = await shell.HandleAutomation(request, TestContext.Current.CancellationToken);
        Assert.True(drawn.Ok);
        Assert.Equal([dir.Combine("chrome.png")], drawn.Files!);
        Assert.Equal(("contentBrowser", dir.Combine("chrome.png")), asked);

        shell.UiCapture = (_, _) => "the window is gone";
        var failed = await shell.HandleAutomation(request, TestContext.Current.CancellationToken);
        Assert.False(failed.Ok);
        Assert.Equal("the window is gone", failed.Error);
    }

    [Fact]
    public void TheInfoFileRoundTripsAndAMissingOneIsNull()
    {
        var directory = Path.Combine(Path.GetTempPath(), $"cinnabar-automation-tests-{Guid.NewGuid():N}");
        var path = Path.Combine(directory, "editor", "automation.json");
        try
        {
            Assert.Null(AutomationServer.ReadInfo(path));
            var info = new AutomationInfo(51234, 777, new DateTime(2026, 10, 27, 8, 0, 0, DateTimeKind.Utc));
            AutomationServer.WriteInfo(path, info);
            Assert.Equal(info, AutomationServer.ReadInfo(path));
            Assert.False(File.Exists(path + ".tmp"));
            File.WriteAllText(path, "nonsense");
            Assert.Null(AutomationServer.ReadInfo(path));
            AutomationServer.DeleteInfo(path);
            Assert.False(File.Exists(path));
            AutomationServer.DeleteInfo(path);
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }
}
