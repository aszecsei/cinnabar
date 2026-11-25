// Peaks (see docs/content/daemon-and-operations.md#peaks): each sound's lowest and highest sample in each run of
// PEAK_FRAMES frames, which the cutscene editor draws as the sound's waveform without reading any audio. The file is in
// <cache>/peaks, named by the sound's GUID and a key of its blob, so a sound that cooks again has a new file and a
// reader never sees half of one. The daemon decides which file each sound should have, makes those that are missing
// and removes the others.
package cook

import "core:encoding/endian"
import "core:fmt"
import "core:hash"
import "core:log"
import "core:mem/virtual"
import "core:os"
import "core:strings"

import format "cinnabar:engine/asset/format"

// Change it to make every peak file again.
PEAKS_VERSION :: 1
PEAKS_DIR :: "peaks"
// The frames of a sound that each peak covers: 187.5 peaks a second at 48 kHz.
PEAK_FRAMES :: 256
PEAKS_MAGIC :: "PEAK"
// The header: the magic, the version, the frames of each peak, the sound's frames and the count of peaks.
PEAKS_HEADER_SIZE :: 4 + 4 + 4 + 8 + 4

// peaks_make is a sound's peak file: for each run of PEAK_FRAMES frames, the last of which may be shorter, the lowest
// and the highest sample of any channel, as two i16, after a header. All of it is little endian.
@(private)
peaks_make :: proc(samples: []i16, channels: int, allocator := context.allocator) -> []byte {
	frames := channels > 0 ? len(samples) / channels : 0
	count := (frames + PEAK_FRAMES - 1) / PEAK_FRAMES
	data := make([]byte, PEAKS_HEADER_SIZE + count * 4, allocator)
	copy(data[0:], PEAKS_MAGIC)
	endian.put_u32(data[4:], .Little, PEAKS_VERSION)
	endian.put_u32(data[8:], .Little, PEAK_FRAMES)
	endian.put_u64(data[12:], .Little, u64(frames))
	endian.put_u32(data[20:], .Little, u32(count))
	for peak in 0 ..< count {
		low, high := i16(max(i16)), i16(min(i16))
		for frame in peak * PEAK_FRAMES ..< min((peak + 1) * PEAK_FRAMES, frames) {
			for channel in 0 ..< channels {
				sample := samples[frame * channels + channel]
				low, high = min(low, sample), max(high, sample)
			}
		}
		at := PEAKS_HEADER_SIZE + peak * 4
		endian.put_i16(data[at:], .Little, low)
		endian.put_i16(data[at + 2:], .Little, high)
	}
	return data
}

// peaks_update gives each sound in the index the path of its peak file, makes the files that are missing, from the
// sounds' sources, and removes the files that no sound wants. A sound with no blob has none. The name comes from the
// blob's header in every pass, so a carried sound whose file went, or that an older daemon carried with none, has it
// made again.
peaks_update :: proc(index: ^Index, pass: ^Pass, options: Cook_Options) {
	allocator := virtual.arena_allocator(&index.arena)
	dir := fmt.tprintf("%s/%s", config_dir(options), PEAKS_DIR)
	if err := os.make_directory_all(dir); err != nil && err != .Exist {
		log.warnf("cook: cannot make %s: %v", dir, err)
		return
	}
	positions := make(map[string]int, len(pass.assets), context.temp_allocator)
	for a, i in pass.assets {
		if a.kind != .Audio {
			continue
		}
		buffer: [32]u8
		positions[strings.clone(format.guid_format(a.meta.guid, &buffer), context.temp_allocator)] =
			i
	}
	present := make(map[string]bool, context.temp_allocator)
	if infos, err := os.read_all_directory_by_path(dir, context.temp_allocator); err == nil {
		for info in infos {
			present[info.name] = true
		}
	}
	wanted := make(map[string]bool, context.temp_allocator)
	pending := make([dynamic]Peaks_Job, context.temp_allocator)
	for guid, &entry in index.assets {
		if entry.kind != .Audio {
			continue
		}
		entry.peaks = ""
		blob_key := blob_header_key(fmt.tprintf("%s/%s.blob", config_dir(options), guid))
		if blob_key == 0 {
			continue
		}
		version := u64(PEAKS_VERSION)
		key := hash.fnv64a(([^]byte)(&version)[:size_of(version)])
		key = hash.fnv64a(([^]byte)(&blob_key)[:size_of(blob_key)], key)
		file := fmt.tprintf("%s.%16x.peaks", guid, key)
		wanted[file] = true
		output := strings.clone(fmt.tprintf("%s/%s", dir, file), allocator)
		if present[file] {
			entry.peaks = output
			continue
		}
		i, found := positions[guid]
		if !found {
			continue
		}
		// The jobs run on other threads, so the source is read first.
		asset_source(pass, i)
		append(&pending, Peaks_Job{guid = guid, output = output, source = &pass.assets[i]})
	}
	for name in present {
		if name not_in wanted {
			if err := os.remove(fmt.tprintf("%s/%s", dir, name)); err != nil && err != .Not_Exist {
				log.warnf("cook: cannot delete %s/%s: %v", dir, name, err)
			}
		}
	}
	parallel_for(len(pending), &pending, proc(data: rawptr, i: int) {
		jobs := (^[dynamic]Peaks_Job)(data)
		jobs[i].ok = peaks_write(jobs[i])
	})
	for job in pending {
		if !job.ok {
			continue
		}
		if entry, found := &index.assets[job.guid]; found {
			entry.peaks = job.output
		}
	}
}

@(private = "file")
Peaks_Job :: struct {
	guid:   string,
	output: string,
	source: ^Asset_Source,
	ok:     bool,
}

@(private = "file")
peaks_write :: proc(job: Peaks_Job) -> bool {
	samples, channels, decoded := decode_sound(
		source_of(job.source^),
		audio_setting(job.source^, "channels"),
	)
	defer delete(samples)
	if !decoded {
		log.warnf("cook: cannot make the peaks of %s", job.guid)
		return false
	}
	return write_blob(job.output, peaks_make(samples[:], int(channels), context.temp_allocator))
}
