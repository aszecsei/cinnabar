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
        Assert.Equal(3, seen.Count);
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
