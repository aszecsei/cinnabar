// Package core_math is curves and paths (see docs/core/math.md): keyed curves, the format of a cutscene's channels;
// easing and tweens; cubic Bezier segments, the splines that convert to them, their arc length, and frames along them
// for procedural geometry. It imports only base: and core:, so the host, the game, the cooker and the shared formats
// all import it, always as `import core_math "cinnabar:core/math"`.
//
// Every procedure is contextless and allocates nothing: a table or a run of frames goes into a slice that the caller
// gives. Data holds no procedure: an easing is an Ease, and a tween is a description that a time is applied to, so a
// code reload keeps any of it.
//
// Exactness: the kernels of exact.odin and the keyed curve with i32 times give the same bits as the editor's C#
// evaluator, src/editor/Cinnabar.Editor.Document/CutsceneCurve.cs, which testdata/curve.txt checks. Their arithmetic is
// f64, + - * / only, in a fixed order: do not reorder it. Everything else is plain floating point with no such promise.
package core_math
