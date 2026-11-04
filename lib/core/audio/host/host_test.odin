package audio_host

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

// The user's file names the backend if it names one; the project's otherwise; neither gives "".
@(test)
the_user_file_names_the_backend_first :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "audio_host_test_*", context.temp_allocator)
	testing.expect(t, err == nil)
	defer os.remove_all(dir)
	project := fmt.tprintf("%s/project.settings", dir)
	user := fmt.tprintf("%s/project.user.settings", dir)
	testing.expect_value(t, backend_setting(project, context.temp_allocator), "")
	testing.expect(t, os.write_entire_file(project, "# Audio.\naudio.backend = mixer\noutput = Sdr\n") == nil)
	testing.expect_value(t, backend_setting(project, context.temp_allocator), "mixer")
	testing.expect(t, os.write_entire_file(user, "audio.backend = none\n") == nil)
	testing.expect_value(t, backend_setting(project, context.temp_allocator), "none")
}

// A read takes any range, and reads what is there.
@(test)
file_reads_a_range :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "audio_host_test_*", context.temp_allocator)
	testing.expect(t, err == nil)
	defer os.remove_all(dir)
	path := fmt.tprintf("%s/range.blob", dir)
	testing.expect(t, os.write_entire_file(path, "0123456789") == nil)

	file := file_open(strings.clone_to_cstring(path, context.temp_allocator))
	testing.expect(t, file != nil)
	defer file_close(file)
	buffer: [4]u8
	testing.expect_value(t, file_read_at(file, 3, &buffer[0], 4), 4)
	testing.expect_value(t, string(buffer[:]), "3456")
	testing.expect_value(t, file_read_at(file, 8, &buffer[0], 4), 2)
	testing.expect_value(t, string(buffer[:2]), "89")
	testing.expect_value(t, file_read_at(file, 100, &buffer[0], 4), 0)
	testing.expect(t, file_open("no such file") == nil)
}

// The cooker writes a blob by renaming a new file over it (write_blob in tools/cook/assets.odin). Windows refuses that
// while the blob is open, even with FILE_SHARE_DELETE, which is why a stream closes its file after each read. If this
// ever starts to succeed, a stream could hold its file open and keep playing the old contents.
@(test)
a_file_that_is_open_cannot_be_replaced :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "audio_host_test_*", context.temp_allocator)
	testing.expect(t, err == nil)
	defer os.remove_all(dir)
	path := fmt.tprintf("%s/sound.blob", dir)
	temporary := fmt.tprintf("%s.tmp", path)
	testing.expect(t, os.write_entire_file(path, "old contents") == nil)
	testing.expect(t, os.write_entire_file(temporary, "new contents") == nil)

	file := file_open(strings.clone_to_cstring(path, context.temp_allocator))
	testing.expect(t, file != nil)
	testing.expect(t, os.rename(temporary, path) != nil)
	file_close(file)
	testing.expect_value(t, os.rename(temporary, path), nil)
}

// A reader that closes its file between reads sees a replacement in the modification time.
@(test)
file_modified_changes_with_a_replacement :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "audio_host_test_*", context.temp_allocator)
	testing.expect(t, err == nil)
	defer os.remove_all(dir)
	path := fmt.tprintf("%s/sound.blob", dir)
	name := strings.clone_to_cstring(path, context.temp_allocator)
	temporary := fmt.tprintf("%s.tmp", path)
	testing.expect(t, os.write_entire_file(path, "old contents") == nil)

	file := file_open(name)
	before := file_modified(file)
	testing.expect(t, before != 0)
	file_close(file)

	time.sleep(20 * time.Millisecond)
	testing.expect(t, os.write_entire_file(temporary, "new contents") == nil)
	testing.expect_value(t, os.rename(temporary, path), nil)

	file = file_open(name)
	defer file_close(file)
	testing.expect(t, file_modified(file) != before)
}
