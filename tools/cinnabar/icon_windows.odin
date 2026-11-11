package cinnabar

import win "core:sys/windows"

foreign import kernel32 "system:Kernel32.lib"

@(default_calling_convention = "system")
foreign kernel32 {
	BeginUpdateResourceW :: proc(pFileName: win.LPCWSTR, bDeleteExistingResources: win.BOOL) -> win.HANDLE ---
	UpdateResourceW :: proc(hUpdate: win.HANDLE, lpType: rawptr, lpName: rawptr, wLanguage: win.WORD, lpData: rawptr, cb: win.DWORD) -> win.BOOL ---
	EndUpdateResourceW :: proc(hUpdate: win.HANDLE, fDiscard: win.BOOL) -> win.BOOL ---
}

// write_icon_resources replaces an executable's icon resources, in the neutral language.
write_icon_resources :: proc(exe: string, r: Icon_Resources) -> bool {
	update := BeginUpdateResourceW(win.utf8_to_wstring(exe, context.temp_allocator), false)
	if update == nil {
		return false
	}
	ok := true
	for image, i in r.images {
		ok = ok && bool(UpdateResourceW(update, rawptr(win.RT_ICON), rawptr(uintptr(i + 1)), 0, raw_data(image), win.DWORD(len(image))))
	}
	ok = ok && bool(UpdateResourceW(update, rawptr(win.RT_GROUP_ICON), rawptr(uintptr(ICON_GROUP_ID)), 0, raw_data(r.group), win.DWORD(len(r.group))))
	return bool(EndUpdateResourceW(update, !ok)) && ok
}
