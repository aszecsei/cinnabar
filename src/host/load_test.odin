package host

import "core:testing"

@(test)
each_host_loads_a_copy_of_its_own :: proc(t: ^testing.T) {
	testing.expect_value(t, copy_path("build/dev/standard.dll", 4120, 0), "build/dev/standard_4120_0.dll")
	testing.expect_value(t, copy_path("build/dev/game.dll", 7, 3), "build/dev/game_7_3.dll")

	testing.expect(t, is_copy_of("standard_4120_0.dll", "standard.dll"))
	testing.expect(t, is_copy_of("mygame_12.dll", "mygame.dll"), "a copy named as hosts before named them")
	testing.expect(t, !is_copy_of("standard.dll", "standard.dll"))
	testing.expect(t, !is_copy_of("standard_.dll", "standard.dll"))
	testing.expect(t, !is_copy_of("standard_tools_1.dll", "standard.dll"))
	testing.expect(t, !is_copy_of("mygame_1_2.pdb", "mygame.dll"))
	testing.expect(t, !is_copy_of("game_1_2.dll", "mygame.dll"))
}
