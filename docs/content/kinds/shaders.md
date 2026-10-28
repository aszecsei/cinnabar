# Shaders

Shaders are `.hlsl` files in the content roots. `just shaders` runs `cook shaders --cache build/<target>/content --config dev|release --root game=<content root> --root engine=lib/engine/content --include lib/core/gpu/shaders`, and the daemon cooks them like any other kind.

- **One asset per file.** The cooker compiles each of the file's `vs_main`, `ps_main`, `cs_main`, `as_main` and `ms_main` entry points into one blob. A file with `[shader("...")]` attributes is a ray tracing library and has one library entry (see [GPU](../../gpu/shaders.md#shaders)).
- **Includes are not assets.** `.hlsli` files have no GUID and no `.meta` file. The cooker resolves an include next to the including file first, then in each `--include` directory. The daemon also watches the `--include` directories.
- **The fixed root signature** is attached to every stage, so DXC rejects a shader that does not fit it (see [GPU](../../gpu/interface.md#binding-model)). The runtime never compiles or reflects shaders.
- **Configurations:** development compiles with debug information embedded (`-Zi -Qembed_debug`), so PIX shows the source. Release strips it.
- **Problems:** the cooker parses DXC's messages into problems with their file, line and column. A message in an include belongs to the include's file, and to no asset, as other files' problems do. A shader that fails keeps its old blob, so the running game keeps drawing with the last good version.
- **The cache key** covers the cooker version, the DXC version, the configuration, the source path, the source, the `.meta` file, and the source of every file that it includes, directly or not.
- **One process at a time:** Windows children inherit every inheritable handle, so a DXC started on one thread can hold the pipes of one that another thread started, which then waits forever. The cooker runs its child processes one at a time.
- **Engine shaders** are in the engine's content root, `lib/engine/content/shaders/`, with committed `.meta` files and fixed GUIDs: the editor tools' overlay and pick shaders, and the renderer's.
