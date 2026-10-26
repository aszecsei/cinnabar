// Package profile is the frame profiler: CPU zones on every thread, GPU spans from the backend's timestamps, a ring of
// recent frames and the costs of each stats interval. See docs/core/profiling.md#profiler.
//
// The types and the front-end are shared. The recorder runs in the host: the game zones through Platform_API.profile,
// because the game DLL has its own, unused copy of this package. With -define:PROFILE=false the front-end compiles to
// nothing and the recorder records nothing.
package profile

ENABLED :: #config(PROFILE, true)

// Name is an interned zone name. The host interns by content, so an id keeps its meaning across code reloads and
// soft restarts, and a name never points into the DLL image.
Name :: distinct u16

NO_NAME :: Name(0)

// Category groups names for the summaries and the editor's colors. A name has the category it was first interned with.
Category :: enum u8 {
	Frame,
	// Time the main thread spends waiting for the GPU or the display, which is not CPU work.
	Wait,
	Job,
	System,
	Script,
	Render,
	Gpu,
	Asset,
	Editor,
	User,
}

// Callback is a script zone's detail: which callback of the behaviour class ran.
Callback :: enum u16 {
	None,
	Awake,
	Start,
	Update,
	On_Enable,
	On_Disable,
	On_Destroy,
	On_Reload,
	Event,
	Coroutine,
}

Zone_Flag :: enum u8 {
	// The segment ends where its fiber suspended. The zone continues in a Resumed segment.
	Suspended,
	// The segment starts where its fiber resumed, maybe on another thread.
	Resumed,
	// The whole job of a fiber. It is named after the zone that started the job.
	Job,
	// The zone was still open where its code ended, so the profiler closed it.
	Unbalanced,
}

Zone_Flags :: bit_set[Zone_Flag;u8]

// Zone is one recorded segment of a zone. A zone that its fiber suspends in has a segment for each run between waits,
// with the same fiber, name and depth. Times are time.Tick nanoseconds.
Zone :: struct {
	start, end: u64,
	name:       Name,
	// A Callback for Script zones, the piece of a split render pass, and 0 otherwise.
	detail:     u16,
	// The depth in the fiber's zone stack: 0 for a job's zone and the frame code's outermost zones.
	depth:      u8,
	flags:      Zone_Flags,
	// The fiber's index + 1, or 0 on a thread without fibers.
	fiber:      u8,
	lane:       u8,
}

#assert(size_of(Zone) == 24)

// Gpu_Span is the GPU time of a timed marker, on the CPU's clock.
Gpu_Span :: struct {
	start, end: u64,
	name:       Name,
	detail:     u16,
	queue:      u8,
	depth:      u8,
}

// Procs is the recorder as the game reaches it, in Platform_API.profile. The fields are the same in every build.
Procs :: struct {
	// Interns a name. Cache it where the name is used every frame.
	name:     proc(text: string, category: Category) -> Name,
	begin:    proc(name: Name, detail: u16),
	end:      proc(),
	// The calling fiber's number of open zones.
	depth:    proc() -> int,
	// Closes the calling fiber's zones down to depth, marked Unbalanced.
	close_to: proc(depth: int),
}

// scope opens a zone until the end of the enclosing scope: `profile.scope(&platform.profile, name)`.
@(deferred_in = scope_end)
scope :: #force_inline proc(p: ^Procs, name: Name, detail: u16 = 0) {
	when ENABLED {
		if p.begin != nil {
			p.begin(name, detail)
		}
	}
}

@(private)
scope_end :: #force_inline proc(p: ^Procs, name: Name, detail: u16 = 0) {
	when ENABLED {
		if p.end != nil {
			p.end()
		}
	}
}

// scope_text interns the name on every call, for zones that run a few times per frame.
@(deferred_in = scope_text_end)
scope_text :: #force_inline proc(p: ^Procs, text: string, category := Category.User) {
	when ENABLED {
		if p.begin != nil {
			p.begin(p.name(text, category), 0)
		}
	}
}

@(private)
scope_text_end :: #force_inline proc(p: ^Procs, text: string, category := Category.User) {
	when ENABLED {
		if p.end != nil {
			p.end()
		}
	}
}

// name interns a name, or gives NO_NAME without the profiler.
name :: #force_inline proc(p: ^Procs, text: string, category: Category) -> Name {
	when ENABLED {
		if p.name != nil {
			return p.name(text, category)
		}
	}
	return NO_NAME
}

begin :: #force_inline proc(p: ^Procs, name: Name, detail: u16 = 0) {
	when ENABLED {
		if p.begin != nil {
			p.begin(name, detail)
		}
	}
}

end :: #force_inline proc(p: ^Procs) {
	when ENABLED {
		if p.end != nil {
			p.end()
		}
	}
}

depth :: #force_inline proc(p: ^Procs) -> int {
	when ENABLED {
		if p.depth != nil {
			return p.depth()
		}
	}
	return 0
}

close_to :: #force_inline proc(p: ^Procs, depth: int) {
	when ENABLED {
		if p.close_to != nil {
			p.close_to(depth)
		}
	}
}

// procs is the recorder's Procs, for Platform_API.
procs :: proc() -> Procs {
	return {name = intern, begin = begin_zone, end = end_zone, depth = zone_depth, close_to = close_zones}
}
