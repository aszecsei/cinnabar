package cook

import "core:sync"
import "core:time"

import cook_link "cinnabar:engine/asset/cook_link"
import format "cinnabar:engine/asset/format"

// The daemon's progress: a pass that is done within PROGRESS_DELAY reports nothing, and one that takes longer reports
// at most once each PROGRESS_INTERVAL, and at the end of each step.
PROGRESS_DELAY :: 250 * time.Millisecond
PROGRESS_INTERVAL :: 100 * time.Millisecond

// Progress is how a pass reports how far it has got with each of its steps: the assets of a kind, or a stage's meshes
// and textures. report is called on any of the pass's threads, one call at a time, and a step's counts never go back.
// A pass without report reports nothing. Reporting only counts, so the blobs and problems are those of a pass without.
Progress :: struct {
	report:   proc(data: rawptr, progress: cook_link.Cook_Progress),
	data:     rawptr,
	delay:    time.Duration,
	interval: time.Duration,
	// What the pass keeps: when it started, its step and the jobs of it that are done, and what it reported last.
	start:    time.Tick,
	kind:     format.Asset_Kind,
	name:     string,
	total:    int,
	done:     int,
	mutex:    sync.Mutex,
	reported: time.Tick,
	sent:     int,
}

// step_begin starts a step of total jobs, on the thread that cooks the pass, before its jobs run. name is a stage's.
step_begin :: proc(pass: ^Pass, kind: format.Asset_Kind, name: string, total: int) {
	p := &pass.progress
	p.kind, p.name, p.total = kind, name, total
	p.done, p.sent = 0, 0
}

// step_advance counts a job of the step as done, on any thread, and reports when it is time to.
step_advance :: proc(pass: ^Pass) {
	p := &pass.progress
	if p.report == nil {
		return
	}
	done := sync.atomic_add(&p.done, 1) + 1
	now := time.tick_now()
	if time.tick_diff(p.start, now) < p.delay {
		return
	}
	sync.mutex_lock(&p.mutex)
	defer sync.mutex_unlock(&p.mutex)
	// Another thread may have reported a later count while this one waited.
	if done <= p.sent || done < p.total && time.tick_diff(p.reported, now) < p.interval {
		return
	}
	p.reported, p.sent = now, done
	p.report(p.data, cook_link.Cook_Progress{kind = link_kind(p.kind), name = p.name, done = u32(done), total = u32(p.total)})
}
