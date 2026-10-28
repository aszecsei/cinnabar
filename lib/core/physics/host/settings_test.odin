package physics_host

import "core:fmt"
import "core:os"
import "core:testing"

// The user's file names the backend if it names one; the project's otherwise; neither gives "".
@(test)
the_user_file_names_the_backend_first :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "physics_host_test_*", context.temp_allocator)
	testing.expect(t, err == nil)
	defer os.remove_all(dir)
	project := fmt.tprintf("%s/project.settings", dir)
	user := fmt.tprintf("%s/project.user.settings", dir)
	testing.expect_value(t, backend_setting(project, context.temp_allocator), "")
	testing.expect(t, os.write_entire_file(project, "# Physics.\nphysics.backend = jolt\noutput = Sdr\n") == nil)
	testing.expect_value(t, backend_setting(project, context.temp_allocator), "jolt")
	testing.expect(t, os.write_entire_file(user, "physics.backend = none\n") == nil)
	testing.expect_value(t, backend_setting(project, context.temp_allocator), "none")
}
