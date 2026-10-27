package core

import "core:path/filepath"
import "core:testing"

@(test)
game_paths_default_to_the_executables_directory :: proc(t: ^testing.T) {
	exe_dir, _ := filepath.join({filepath.dir(#file), "exe"}, context.temp_allocator)
	content, project := game_paths(exe_dir, "", "", context.temp_allocator)
	expected_content, _ := filepath.join({exe_dir, "content"}, context.temp_allocator)
	expected_project, _ := filepath.join({exe_dir, "project.settings"}, context.temp_allocator)
	testing.expect_value(t, content, expected_content)
	testing.expect_value(t, project, expected_project)
}

@(test)
game_paths_keep_the_given_paths_and_make_them_absolute :: proc(t: ^testing.T) {
	content, project := game_paths("ignored", "cache/dev", "samples/game/project.settings", context.temp_allocator)
	testing.expect(t, filepath.is_abs(content), "the content directory is absolute")
	testing.expect(t, filepath.is_abs(project), "the project path is absolute")
	testing.expect(t, filepath.base(project) == "project.settings", "the project path keeps its file")
	testing.expect(t, filepath.base(content) == "dev", "the content directory keeps its name")
}
