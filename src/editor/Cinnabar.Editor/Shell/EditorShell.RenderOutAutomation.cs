using System.Globalization;
using Cinnabar.Editor.Link.Protocol;
using Cinnabar.Editor.Model;

namespace Cinnabar.Editor.Shell;

/// <summary>
/// <c>render-out</c> for automation and editorctl (see docs/editor/capture.md#automation): it opens the cutscene's tab,
/// renders it out with the request's settings over the tab's defaults, and answers once the run, and its video, ended.
/// The automation server runs one request at a time, so other requests wait for it.
/// </summary>
public sealed partial class EditorShell
{
    async Task<AutomationResponse> RenderOutResponse(AutomationRequest request)
    {
        AutomationResponse Refuse(string error) => new(request.Id, false, Error: error);
        if (string.IsNullOrWhiteSpace(request.Cutscene))
        {
            return Refuse("render-out takes a cutscene, by its path or its GUID");
        }
        if (string.IsNullOrWhiteSpace(request.Path))
        {
            return Refuse("render-out takes a folder for the frames");
        }
        var asset = Assets.Find(request.Cutscene.Trim().ToLowerInvariant()) ?? Assets.FindByPath(request.Cutscene);
        if (asset == null || OpenCutscene(asset) is not { } editor)
        {
            return Refuse($"no cutscene {request.Cutscene} in the project");
        }
        var settings = editor.DefaultRenderOut(ProjectDirectory, request.Video == true) with
        {
            Folder = Path.GetFullPath(request.Path),
            Audio = request.Audio ?? true,
        };
        if (RenderOutRangeOf(editor, request.Range) is not { } span)
        {
            return Refuse($"render-out's range is whole, inout, shot:<name> or <from>-<to> in ticks, and the cutscene has no {request.Range}");
        }
        settings = settings with { RangeStart = span.Start, RangeEnd = span.End };
        if (request.Size is { } size)
        {
            if (!TryParseFixedSize(size, out var pixels, out var reason) || pixels is not { } fixedSize)
            {
                return Refuse(reason != "" ? reason : "render-out's size is <width>x<height>");
            }
            settings = settings with { Width = (uint)fixedSize.Width, Height = (uint)fixedSize.Height };
        }
        if (request.Format is { } format)
        {
            if (!Enum.TryParse<RenderOutFormat>(format, ignoreCase: true, out var parsed))
            {
                return Refuse($"render-out's format is png or exr, not {format}");
            }
            settings = settings with { Format = parsed };
        }
        settings = settings with
        {
            Rate = request.Rate ?? settings.Rate,
            Pattern = request.Pattern ?? settings.Pattern,
            Warmup = request.Warmup ?? settings.Warmup,
            CameraBinding = request.Camera ?? 0,
        };
        if ((settings.Refusal ?? RenderOutRefusal(editor)) is { } refusal)
        {
            return Refuse(refusal);
        }
        var result = await RenderOutAsync(editor, settings);
        return new AutomationResponse(request.Id, result.Outcome == RenderOutOutcome.Done, Files: [.. result.Files],
            Error: result.Outcome == RenderOutOutcome.Done ? null : result.Reason ?? result.Outcome.ToString(),
            RenderOut: new AutomationRenderOut(result.Outcome.ToString(), result.Reason, result.Frames, result.Folder, result.Audio, result.Video));
    }

    // The ticks of a range by its name: the whole range, the in and out points, a shot by its name, or two times in ticks.
    static (int Start, int End)? RenderOutRangeOf(CutsceneEditor editor, string? range)
    {
        switch (range?.Trim().ToLowerInvariant())
        {
            case null or "" or "whole":
                return editor.RenderOutSpan(RenderOutRange.Whole);
            case "inout":
                return editor.RenderOutSpan(RenderOutRange.InOut);
        }
        var text = range!.Trim();
        if (text.StartsWith("shot:", StringComparison.OrdinalIgnoreCase))
        {
            var name = text[5..];
            return editor.ShotRows.FirstOrDefault(r => string.Equals(r.Name, name, StringComparison.OrdinalIgnoreCase)) is { } shot
                ? (shot.Start, shot.Start + shot.Length)
                : null;
        }
        var parts = text.Split('-');
        return parts.Length == 2
            && int.TryParse(parts[0], NumberStyles.None, CultureInfo.InvariantCulture, out var from)
            && int.TryParse(parts[1], NumberStyles.None, CultureInfo.InvariantCulture, out var to) && to > from
            ? (from, to)
            : null;
    }
}
