using Cinnabar.Editor.Panels;

namespace Cinnabar.Editor.Tests;

public sealed class RebuildGateTests
{
    [Fact]
    public void ARebuildAskedForDuringOneRunsAfterItAndNotInsideIt()
    {
        var log = new List<string>();
        RebuildGate? gate = null;
        var asked = false;
        gate = new RebuildGate(() =>
        {
            log.Add("begin");
            if (!asked)
            {
                // As a box that commits when the rows are cleared does.
                asked = true;
                gate!.Run();
            }
            log.Add("end");
        });

        gate.Run();

        Assert.Equal(["begin", "end", "begin", "end"], log);
    }

    [Fact]
    public void ABuildThatAlwaysAsksForAnotherStillEnds()
    {
        var passes = 0;
        RebuildGate? gate = null;
        gate = new RebuildGate(() =>
        {
            passes++;
            gate!.Run();
        });

        gate.Run();

        Assert.InRange(passes, 2, 8);
        // The gate is open again afterwards.
        var before = passes;
        gate.Run();
        Assert.True(passes > before);
    }

    [Fact]
    public void ABuildThatThrowsLeavesTheGateOpen()
    {
        var fail = true;
        var built = 0;
        var gate = new RebuildGate(() =>
        {
            if (fail)
            {
                throw new InvalidOperationException("a row");
            }
            built++;
        });

        Assert.Throws<InvalidOperationException>(gate.Run);
        fail = false;
        gate.Run();

        Assert.Equal(1, built);
    }
}
