package cinnabar

import "core:encoding/endian"
import "core:log"
import "core:os"

// An icon file holds images and a directory of them. An executable holds each image as an RT_ICON resource and the
// directory as an RT_GROUP_ICON resource, whose entries name the images' resources by ID in place of their offsets.
// The window takes group 1 (see lib/core/window_windows.odin), and Explorer takes the first group.
ICON_GROUP_ID :: 1
// The sizes of an ICONDIR, an ICONDIRENTRY and a GRPICONDIRENTRY.
ICON_HEADER :: 6
ICON_ENTRY :: 16
GROUP_ENTRY :: 14

// Icon_Resources are an icon file's resources: the group's bytes, and each image's, whose resource ID is its index + 1.
Icon_Resources :: struct {
	group:  []byte,
	images: [][]byte,
}

// icon_resources reads an icon file into the resources that an executable holds, or fails on a file that is not one.
icon_resources :: proc(ico: []byte, allocator := context.allocator) -> (r: Icon_Resources, ok: bool) {
	if len(ico) < ICON_HEADER {
		return
	}
	reserved, _ := endian.get_u16(ico[0:], .Little)
	kind, _ := endian.get_u16(ico[2:], .Little)
	count, _ := endian.get_u16(ico[4:], .Little)
	if reserved != 0 || kind != 1 || count == 0 || len(ico) < ICON_HEADER + int(count) * ICON_ENTRY {
		return
	}
	r.group = make([]byte, ICON_HEADER + int(count) * GROUP_ENTRY, allocator)
	copy(r.group, ico[:ICON_HEADER])
	r.images = make([][]byte, count, allocator)
	for i in 0 ..< int(count) {
		entry := ico[ICON_HEADER + i * ICON_ENTRY:][:ICON_ENTRY]
		size, _ := endian.get_u32(entry[8:], .Little)
		offset, _ := endian.get_u32(entry[12:], .Little)
		if int(offset) + int(size) > len(ico) || size == 0 {
			return {}, false
		}
		r.images[i] = ico[offset:][:size]
		// Width, height, colors, reserved, planes, bit count and size are the same; the offset becomes the image's ID.
		group_entry := r.group[ICON_HEADER + i * GROUP_ENTRY:][:GROUP_ENTRY]
		copy(group_entry, entry[:12])
		endian.put_u16(group_entry[12:], .Little, u16(i + 1))
	}
	return r, true
}

// set_icon writes an icon file into an executable as its icon.
set_icon :: proc(exe, icon_path: string) -> bool {
	ico, err := os.read_entire_file(icon_path, context.temp_allocator)
	if err != nil {
		log.errorf("cinnabar: the icon %s: %v", icon_path, err)
		return false
	}
	resources, ok := icon_resources(ico, context.temp_allocator)
	if !ok {
		log.errorf("cinnabar: %s is not an icon file (.ico)", icon_path)
		return false
	}
	if !write_icon_resources(exe, resources) {
		log.errorf("cinnabar: cannot write the icon into %s", exe)
		return false
	}
	return true
}
