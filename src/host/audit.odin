package host

import "core:dynlib"
import "core:log"
import win "core:sys/windows"

import "cinnabar:core/layout"

// The pointer audit runs in debug builds only: after on_reload, the new DLL walks its state for values that still
// point into the old DLL's image (see docs/overview/hot-reload.md#rules).
AUDIT_POINTERS :: ODIN_DEBUG

// image_range is the address range of a loaded DLL's image: from its base, which its handle is, to the image's size
// in its PE headers.
image_range :: proc(lib: dynlib.Library) -> layout.Range {
	base := uintptr(lib)
	if base == 0 {
		return {}
	}
	dos := (^win.IMAGE_DOS_HEADER)(base)
	nt := (^win.IMAGE_NT_HEADERS64)(base + uintptr(dos.e_lfanew))
	return {base, base + uintptr(nt.OptionalHeader.SizeOfImage)}
}

// audit_reload asks the new DLL for the values in the state that point into the old one's image, which a code reload
// left behind, and logs each by its field path. The reload goes on: the old image stays loaded, so the values still
// work, but they run the old code.
audit_reload :: proc(old, next: Game_Module, state: rawptr) -> []layout.Finding {
	if next.api.pointer_audit == nil {
		return nil
	}
	findings := next.api.pointer_audit(state, image_range(old.lib), context.temp_allocator)
	for f in findings {
		log.errorf(
			"host: %s points into the old DLL (%#x). Persistent state must not hold its procedures, pointers or strings; see docs/overview/hot-reload.md#rules",
			f.path,
			f.address,
		)
	}
	if len(findings) == 0 {
		log.debug("host: the pointer audit found nothing in the old DLL")
	}
	return findings
}
