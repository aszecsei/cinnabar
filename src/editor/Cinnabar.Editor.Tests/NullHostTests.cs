using Cinnabar.Editor.Link.Protocol;

namespace Cinnabar.Editor.Tests;

/// <summary>
/// The editor link against build/dev/null-host.exe, which renders with the null GPU backend, so that the tests of
/// <see cref="HostTests"/> run on a machine without a GPU. The null backend runs no shaders, and its shared mode shares
/// nothing, so what needs either stays in <see cref="HostLinkTests"/>.
/// </summary>
public sealed class NullHostTests() : HostTests("null-host.exe", "just build and just null-host", () => [])
{
    // A pick in a scene view that draws waits for the pick shader to write its ticket, which no shader does here, so the
    // game picks again in each frame and never answers. The pick's passes still pass the null backend's validation, which
    // logs an error and drops the frame for one that breaks a rule, and the frames go on.
    [Fact]
    public async Task APickInAViewThatDrawsRecordsValidPassesAndTheFramesGoOn()
    {
        await using var editor = await Connect();
        editor.Link.Send(new Hello(LinkMessages.ProtocolVersion, "test"));
        await editor.Next<EntitySnapshot>();
        var target = await Show(editor);
        await Load(editor, Scene(Box(1, "Box", z: 1, scale: 1)));
        editor.Link.Send(new EditorCamera(0, [Origin, 0, -Meter], [0, 0, 0, 1], (float)(60 * Math.PI / 180), 0.05f, CameraProjection.Perspective, 0, 0));

        editor.Link.Send(new PickRequest(7, 0, target.Width / 2, target.Height / 2, 1, 1));
        await editor.Next<HostStats>();
        for (var i = 0; i < 3; i++)
        {
            Assert.True((await editor.Next<HostStats>()).Frames > 0, "the frames stopped after a pick");
        }
        Assert.DoesNotContain(editor.Skipped, m => m is Log { Level: LogLevel.Error });
    }
}
