# Scenes

Scenes are `.scene` text files (see [Editor](../../editor/document-and-scenes.md#scenes)). `just scenes` runs `cook scenes --cache build/cache --config dev|release --root game=<content root>`. The cooker cannot lay out native components, because their types exist only in the game DLL, so it checks only the file: its syntax, and that the scene IDs and the script GUIDs that it names exist. A missing one is a warning. A scene with an error keeps its old blob. The cache key covers the cooker version, the configuration, the source path, the source and the `.meta` file.
