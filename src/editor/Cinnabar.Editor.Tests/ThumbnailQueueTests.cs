using Cinnabar.Editor.Content;
using Cinnabar.Editor.Link;
using Cinnabar.Editor.Link.Cook;
using Cinnabar.Editor.Link.Protocol;

namespace Cinnabar.Editor.Tests;

/// <summary>What the content browser asks the host to draw, without a host.</summary>
public sealed class ThumbnailQueueTests
{
    const string A = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const string B = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const string C = "cccccccccccccccccccccccccccccccc";
    const string Done = "dddddddddddddddddddddddddddddddd";
    const string Script = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";

    readonly List<ILinkMessage> _sent = [];
    readonly AssetIndex _index = new();
    readonly DateTime _now = new(2026, 11, 5, 0, 0, 0, DateTimeKind.Utc);
    bool _canBake = true;

    ThumbnailQueue NewQueue()
    {
        _index.Apply(new AssetSnapshot(
        [
            TestAssets.Make(A, AssetKind.Material, "a.material", thumbnail: "t/a.png"),
            TestAssets.Make(B, AssetKind.Mesh, "b.mesh", thumbnail: "t/b.png"),
            TestAssets.Make(C, AssetKind.Prefab, "c.prefab", thumbnail: "t/c.png"),
            TestAssets.Make(Done, AssetKind.Material, "d.material", thumbnail: "t/d.png", thumbnailReady: true),
            TestAssets.Make(Script, AssetKind.Script, "e.luau"),
        ], []));
        return new ThumbnailQueue(_index, _sent.Add, () => _canBake);
    }

    IEnumerable<BakeThumbnail> Bakes => _sent.OfType<BakeThumbnail>();

    static string Guid(BakeThumbnail bake) => Convert.ToHexString(bake.Asset).ToLowerInvariant();

    [Fact]
    public void VisibleTilesBakeFirst()
    {
        var queue = NewQueue();
        _canBake = false;
        queue.Want(A, _now);
        queue.Want(B, _now);
        queue.Want(C, _now);
        Assert.Empty(_sent);

        // What was the last to show is what the user is looking at.
        _canBake = true;
        queue.Pump(_now);
        Assert.Equal(C, Guid(Bakes.Single()));
        Assert.Equal(ThumbnailKind.Prefab, Bakes.Single().Kind);
        var capture = _sent.OfType<CaptureRequest>().Single();
        Assert.Equal(CaptureKind.Thumbnail, capture.Kind);
        Assert.Equal("t/c.png", capture.Path);
        Assert.Equal(capture.Id, Bakes.Single().Id);

        // A tile that leaves is not drawn.
        queue.Unwant(A);
        queue.Apply(new CaptureResult(capture.Id, CaptureKind.Thumbnail, true, "", "t/c.png", 0, 0, 0, 0, 0, OutputMode.Sdr), _now);
        Assert.Equal([C, B], Bakes.Select(Guid));
    }

    [Fact]
    public void OneAtATime()
    {
        var queue = NewQueue();
        queue.Want(A, _now);
        queue.Want(B, _now);
        Assert.Single(Bakes);
        queue.Pump(_now);
        Assert.Single(Bakes);
    }

    [Fact]
    public void WhatIsReadyOrHasNoPictureIsNotAskedFor()
    {
        var queue = NewQueue();
        queue.Want(Done, _now);
        queue.Want(Script, _now);
        Assert.Empty(_sent);
        Assert.Equal(0, queue.Waiting);
    }

    [Fact]
    public void AnAnswerMarksTheIndexWithoutARebuild()
    {
        var queue = NewQueue();
        var changes = 0;
        var pictures = new List<string>();
        _index.Changed += () => changes++;
        _index.ThumbnailChanged += pictures.Add;
        queue.Want(A, _now);
        var id = Bakes.Single().Id;

        queue.Apply(new CaptureResult(id, CaptureKind.Thumbnail, true, "", "t/a.png", 0, 0, 0, 0, 0, OutputMode.Sdr), _now);

        Assert.True(_index.Find(A)!.ThumbnailReady);
        Assert.Equal([A], pictures);
        Assert.Equal(0, changes);
    }

    [Fact]
    public void ThumbnailChangedDoesNotRaiseChanged()
    {
        NewQueue();
        var changes = 0;
        _index.Changed += () => changes++;
        // A path that is no longer the asset's says nothing: the asset cooked again while the picture was drawn.
        _index.MarkThumbnailReady(A, "t/old.png");
        Assert.False(_index.Find(A)!.ThumbnailReady);
        _index.MarkThumbnailReady(A, "t/a.png");
        Assert.True(_index.Find(A)!.ThumbnailReady);
        Assert.Equal(0, changes);
    }

    [Fact]
    public void PlayPauses()
    {
        var queue = NewQueue();
        _canBake = false;
        queue.Want(A, _now);
        Assert.Empty(_sent);
        _canBake = true;
        queue.Restart(_now);
        Assert.Single(Bakes);
    }

    [Fact]
    public void AFailureIsNotRetriedUntilThePathChanges()
    {
        var queue = NewQueue();
        queue.Want(A, _now);
        queue.Apply(new ThumbnailFailed(Bakes.Single().Id, "it draws nothing"), _now);
        Assert.Equal("it draws nothing", queue.FailureOf(_index.Find(A)!));
        Assert.Equal(["t/a.png: it draws nothing"], queue.Failures);

        queue.Pump(_now);
        queue.Restart(_now);
        Assert.Single(Bakes);

        // The asset changes, so its file's name does, and it gets another chance.
        _index.Apply(new AssetDelta([TestAssets.Make(A, AssetKind.Material, "a.material", thumbnail: "t/a2.png")], [], [], []));
        queue.Pump(_now);
        Assert.Equal(2, Bakes.Count());
        Assert.Null(queue.FailureOf(_index.Find(A)!));

        // Regenerate forgets one by hand.
        queue.Apply(new ThumbnailFailed(Bakes.Last().Id, "again"), _now);
        Assert.Equal(2, Bakes.Count());
        queue.Forget(_index.Find(A)!, _now);
        Assert.Equal(3, Bakes.Count());
    }

    [Fact]
    public void AFilesPictureIsThatOfWhatItMakes()
    {
        const string Stage = "11111111111111111111111111111111";
        const string Prefab = "22222222222222222222222222222222";
        const string Mesh = "33333333333333333333333333333333";
        const string Lone = "44444444444444444444444444444444";
        var index = new AssetIndex();
        index.Apply(new AssetSnapshot(
        [
            TestAssets.Make(Stage, AssetKind.Model, "s.usda"),
            TestAssets.Make(Mesh, AssetKind.Mesh, "s.usda", parent: Stage, subasset: "mesh", thumbnail: "t/m.png"),
            TestAssets.Make(Prefab, AssetKind.Prefab, "s.usda", parent: Stage, subasset: "prefab", thumbnail: "t/p.png"),
            TestAssets.Make(Lone, AssetKind.Script, "l.luau"),
        ], []));

        // Its prefab, before its meshes, and an asset with its own picture has that one.
        Assert.Equal(Prefab, index.PictureOf(index.Find(Stage)!)!.Guid);
        Assert.Equal(Mesh, index.PictureOf(index.Find(Mesh)!)!.Guid);
        Assert.Null(index.PictureOf(index.Find(Lone)!));
    }

    [Fact]
    public void ThePictureOfAStaleTileIsTheIndexs()
    {
        var queue = NewQueue();
        var stale = _index.Find(A)!;
        _index.MarkThumbnailReady(A, "t/a.png");
        Assert.False(stale.ThumbnailReady);
        Assert.True(_index.PictureOf(stale)!.ThumbnailReady);
        Assert.Empty(queue.Failures);
    }

    [Fact]
    public void ALostLinkRequeues()
    {
        var queue = NewQueue();
        queue.Want(A, _now);
        Assert.Single(Bakes);

        queue.Restart(_now);

        Assert.Equal(2, Bakes.Count());
        Assert.Equal(A, Guid(Bakes.Last()));
    }

    [Fact]
    public void ALostAnswerIsGivenUpOn()
    {
        var queue = NewQueue();
        queue.Want(A, _now);
        queue.Pump(_now + ThumbnailQueue.Timeout - TimeSpan.FromSeconds(1));
        Assert.Single(Bakes);
        queue.Pump(_now + ThumbnailQueue.Timeout);
        Assert.Equal(2, Bakes.Count());
    }

    [Fact]
    public void AnAnswerToAnotherRequestIsIgnored()
    {
        var queue = NewQueue();
        queue.Want(A, _now);
        var id = Bakes.Single().Id;
        queue.Apply(new CaptureResult(id + 5, CaptureKind.Thumbnail, true, "", "t/a.png", 0, 0, 0, 0, 0, OutputMode.Sdr), _now);
        Assert.False(_index.Find(A)!.ThumbnailReady);
    }
}
