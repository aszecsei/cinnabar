package core

import "base:runtime"
import "core:mem"
import "core:strings"
import "core:sync"

import "cinnabar:core/jobs"

// The most reads that are open at once. file_reads_begin refuses one more.
MAX_FILE_READS :: 256

// The largest range that one read takes.
MAX_FILE_READ_SIZE :: 256 << 20

// File_Reads is the host's table of the game's reads of file ranges that go on across frames (see
// docs/core/platform.md#file-reads). The host owns each read's buffer, so a game that restarts or reloads leaves
// nothing that a job still writes to.
File_Reads :: struct {
	mutex:   sync.Mutex,
	slots:   [MAX_FILE_READS]File_Read_Slot,
	// The jobs that have not finished. The host waits for it before it frees the table.
	running: jobs.Counter,
}

// File_Read_Slot is one read. change_file_read is the only writer of work.
File_Read_Slot :: struct {
	owner:      ^File_Reads,
	// Makes an old ticket of this slot differ from the newest one.
	generation: u32,
	work:       File_Read_Work,
	path:       string,
	offset:     i64,
	buffer:     []byte,
}

// File_Read_Work is where a read is. nil is a free slot.
File_Read_Work :: union {
	// A job is reading.
	File_Read_Running,
	// The owner ended the read while its job was reading. The job frees the slot when it finishes.
	File_Read_Abandoned,
	// The job finished, and the owner has not ended the read.
	File_Read_Finished,
}

File_Read_Running :: struct {}

File_Read_Abandoned :: struct {}

File_Read_Finished :: struct {
	// Whether the whole range was read.
	whole: bool,
}

@(private = "file")
File_Read_Event :: union {
	// begin took the slot.
	File_Read_Began,
	// The job read `count` bytes.
	File_Read_Ran,
	// The owner ended the read.
	File_Read_Ended,
}

@(private = "file")
File_Read_Began :: struct {
	path:   string,
	offset: i64,
	buffer: []byte,
}

@(private = "file")
File_Read_Ran :: struct {
	count: int,
}

@(private = "file")
File_Read_Ended :: struct {}

// change_file_read moves a read from one state to the next. Call it with the table's mutex held.
@(private = "file")
change_file_read :: proc(slot: ^File_Read_Slot, event: File_Read_Event) {
	release :: proc(slot: ^File_Read_Slot) {
		delete(slot.path, runtime.heap_allocator())
		mem.free_bytes(slot.buffer, runtime.heap_allocator())
		slot.path, slot.buffer, slot.offset = "", nil, 0
		slot.generation += 1
		slot.work = nil
	}
	switch e in event {
	case File_Read_Began:
		assert(slot.work == nil, "core: a file read began in a slot that is in use")
		slot.path, slot.offset, slot.buffer = e.path, e.offset, e.buffer
		slot.work = File_Read_Running{}
	case File_Read_Ran:
		switch _ in slot.work {
		case File_Read_Running:
			slot.work = File_Read_Finished{whole = e.count == len(slot.buffer)}
		case File_Read_Abandoned:
			release(slot)
		case File_Read_Finished:
			panic("core: a file read ran twice")
		case:
			panic("core: a file read ran in a free slot")
		}
	case File_Read_Ended:
		switch _ in slot.work {
		case File_Read_Running:
			slot.work = File_Read_Abandoned{}
		case File_Read_Finished:
			release(slot)
		case File_Read_Abandoned:
		case:
		}
	}
}

@(private = "file")
file_read_ticket :: proc(index: int, generation: u32) -> File_Read {
	return File_Read(u64(generation) << 32 | u64(index + 1))
}

// The slot that a ticket names, or nil if the ticket is 0 or its read has ended. Call it with the mutex held.
@(private = "file")
file_read_slot :: proc(reads: ^File_Reads, read: File_Read) -> ^File_Read_Slot {
	index := int(u64(read) & 0xFFFF_FFFF) - 1
	if index < 0 || index >= MAX_FILE_READS {
		return nil
	}
	slot := &reads.slots[index]
	if slot.generation != u32(u64(read) >> 32) || slot.work == nil {
		return nil
	}
	if _, abandoned := slot.work.(File_Read_Abandoned); abandoned {
		return nil
	}
	return slot
}

// file_reads_begin starts a read of `size` bytes of a file from `offset`, on a background job, and returns its ticket,
// or 0 if the table is full or the size is not one that a read takes. The read fails if the file has fewer bytes.
file_reads_begin :: proc(reads: ^File_Reads, path: string, offset: i64, size: int) -> File_Read {
	if size <= 0 || size > MAX_FILE_READ_SIZE || offset < 0 {
		return 0
	}
	sync.lock(&reads.mutex)
	index := -1
	for &slot, i in reads.slots {
		if slot.work == nil {
			index = i
			break
		}
	}
	if index < 0 {
		sync.unlock(&reads.mutex)
		return 0
	}
	slot := &reads.slots[index]
	buffer, err := mem.alloc_bytes_non_zeroed(size, FILE_READ_ALIGN, runtime.heap_allocator())
	if err != nil {
		sync.unlock(&reads.mutex)
		return 0
	}
	slot.owner = reads
	change_file_read(slot, File_Read_Began{strings.clone(path, runtime.heap_allocator()), offset, buffer})
	ticket := file_read_ticket(index, slot.generation)
	sync.unlock(&reads.mutex)

	jobs.run_background({{procedure = run_file_read, data = slot}}, &reads.running)
	return ticket
}

// The alignment of a read's buffer, which is that of a blob.
FILE_READ_ALIGN :: 16

@(private = "file")
run_file_read :: proc(data: rawptr) {
	slot := (^File_Read_Slot)(data)
	// Only this job reads the path and the buffer until it reports, so the file is read without the lock.
	count := file_read_range(slot.path, slot.offset, slot.buffer)
	sync.guard(&slot.owner.mutex)
	change_file_read(slot, File_Read_Ran{count})
}

// file_reads_result is a read's bytes once it is done. They stay valid until file_reads_end. A ticket that is 0, or
// whose read has ended, has failed.
file_reads_result :: proc(reads: ^File_Reads, read: File_Read) -> ([]byte, File_Read_State) {
	sync.guard(&reads.mutex)
	slot := file_read_slot(reads, read)
	if slot == nil {
		return nil, .Failed
	}
	switch work in slot.work {
	case File_Read_Running:
		return nil, .Pending
	case File_Read_Finished:
		if work.whole {
			return slot.buffer, .Done
		}
	case File_Read_Abandoned:
	}
	return nil, .Failed
}

// file_reads_end frees a read, whether it is done or not. A read that is still going on is cancelled: its job frees it.
file_reads_end :: proc(reads: ^File_Reads, read: File_Read) {
	sync.guard(&reads.mutex)
	if slot := file_read_slot(reads, read); slot != nil {
		change_file_read(slot, File_Read_Ended{})
	}
}

// file_reads_end_all ends every read that is open, as a soft restart does for the reads that a game left. It returns
// how many there were.
file_reads_end_all :: proc(reads: ^File_Reads) -> (count: int) {
	sync.guard(&reads.mutex)
	for &slot in reads.slots {
		#partial switch _ in slot.work {
		case File_Read_Running, File_Read_Finished:
			change_file_read(&slot, File_Read_Ended{})
			count += 1
		}
	}
	return
}

// file_reads_open is how many reads are open.
file_reads_open :: proc(reads: ^File_Reads) -> (count: int) {
	sync.guard(&reads.mutex)
	for slot in reads.slots {
		#partial switch _ in slot.work {
		case File_Read_Running, File_Read_Finished:
			count += 1
		}
	}
	return
}

// file_reads_wait waits until no read's job is running. Call it from the main fiber, before the job system stops.
file_reads_wait :: proc(reads: ^File_Reads) {
	jobs.wait(&reads.running)
}
