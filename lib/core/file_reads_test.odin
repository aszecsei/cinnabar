package core

import "core:os"
import "core:path/filepath"
import "core:sync"
import "core:testing"

import "cinnabar:core/jobs"

// The job system is one for the process, so the tests that start it take turns.
@(private = "file")
jobs_lock: sync.Mutex

@(private = "file")
numbered_file :: proc(t: ^testing.T, name: string, size: int) -> string {
	path, _ := filepath.join({os.get_env("TEMP", context.temp_allocator), name}, context.temp_allocator)
	data := make([]byte, size, context.temp_allocator)
	for &b, i in data {
		b = byte(i)
	}
	testing.expect(t, os.write_entire_file(path, data) == nil, "the test's file is written")
	return path
}

@(test)
a_read_gives_its_range_once_its_job_is_done :: proc(t: ^testing.T) {
	sync.guard(&jobs_lock)
	testing.expect(t, jobs.init(2))
	defer jobs.shutdown()
	path := numbered_file(t, "cinnabar_file_reads_range.bin", 4096)
	defer os.remove(path)

	reads := new(File_Reads, context.temp_allocator)
	read := file_reads_begin(reads, path, 1000, 300)
	testing.expect(t, read != 0, "the read starts")
	file_reads_wait(reads)
	data, state := file_reads_result(reads, read)
	testing.expect_value(t, state, File_Read_State.Done)
	testing.expect_value(t, len(data), 300)
	if len(data) == 300 {
		testing.expect_value(t, data[0], byte(1000 % 256))
		testing.expect_value(t, data[299], byte(1299 % 256))
	}
	testing.expect_value(t, uintptr(raw_data(data)) % FILE_READ_ALIGN, uintptr(0))
	testing.expect_value(t, file_reads_open(reads), 1)

	file_reads_end(reads, read)
	testing.expect_value(t, file_reads_open(reads), 0)
	_, state = file_reads_result(reads, read)
	testing.expect_value(t, state, File_Read_State.Failed)

	// The slot's next read has another ticket, so the old one does not name it.
	next := file_reads_begin(reads, path, 0, 16)
	testing.expect(t, next != 0 && next != read, "a slot's next read has a ticket of its own")
	file_reads_wait(reads)
	_, state = file_reads_result(reads, read)
	testing.expect_value(t, state, File_Read_State.Failed)
	_, state = file_reads_result(reads, next)
	testing.expect_value(t, state, File_Read_State.Done)
	file_reads_end(reads, next)
}

@(test)
a_read_past_the_files_end_or_of_no_file_fails :: proc(t: ^testing.T) {
	sync.guard(&jobs_lock)
	testing.expect(t, jobs.init(2))
	defer jobs.shutdown()
	path := numbered_file(t, "cinnabar_file_reads_end.bin", 100)
	defer os.remove(path)

	reads := new(File_Reads, context.temp_allocator)
	past := file_reads_begin(reads, path, 50, 100)
	missing := file_reads_begin(reads, "no/such/file.bin", 0, 16)
	testing.expect(t, past != 0 && missing != 0, "the reads start")
	file_reads_wait(reads)
	_, state := file_reads_result(reads, past)
	testing.expect_value(t, state, File_Read_State.Failed)
	_, state = file_reads_result(reads, missing)
	testing.expect_value(t, state, File_Read_State.Failed)
	file_reads_end(reads, past)
	file_reads_end(reads, missing)
	testing.expect_value(t, file_reads_open(reads), 0)

	testing.expect_value(t, file_reads_begin(reads, path, 0, 0), File_Read(0))
	testing.expect_value(t, file_reads_begin(reads, path, -1, 16), File_Read(0))
	testing.expect_value(t, file_reads_begin(reads, path, 0, MAX_FILE_READ_SIZE + 1), File_Read(0))
	_, state = file_reads_result(reads, 0)
	testing.expect_value(t, state, File_Read_State.Failed)
}

@(test)
a_read_that_is_ended_early_is_cancelled_and_its_slot_comes_back :: proc(t: ^testing.T) {
	sync.guard(&jobs_lock)
	testing.expect(t, jobs.init(2))
	defer jobs.shutdown()
	path := numbered_file(t, "cinnabar_file_reads_cancel.bin", 4096)
	defer os.remove(path)

	reads := new(File_Reads, context.temp_allocator)
	tickets: [MAX_FILE_READS]File_Read
	for &ticket in tickets {
		ticket = file_reads_begin(reads, path, 0, 64)
		testing.expect(t, ticket != 0, "the table takes its full count of reads")
	}
	testing.expect_value(t, file_reads_begin(reads, path, 0, 64), File_Read(0))

	// Ended at once, whether its job has run or not: either way the read is gone for its owner.
	testing.expect_value(t, file_reads_end_all(reads), MAX_FILE_READS)
	testing.expect_value(t, file_reads_open(reads), 0)
	_, state := file_reads_result(reads, tickets[0])
	testing.expect_value(t, state, File_Read_State.Failed)
	file_reads_wait(reads)
	for slot in reads.slots {
		testing.expect(t, slot.work == nil && slot.buffer == nil, "every slot is free and holds no buffer")
	}
	again := file_reads_begin(reads, path, 0, 64)
	testing.expect(t, again != 0, "a freed slot takes a read again")
	file_reads_wait(reads)
	file_reads_end(reads, again)
}
