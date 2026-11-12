package asset_format

import "core:testing"

@(test)
a_project_without_agent_types_has_the_default :: proc(t: ^testing.T) {
	agents, problems := nav_agents_parse("game.name = Demo\nnav.agent.Default.radius = 0.25\n", context.temp_allocator)
	testing.expect_value(t, len(problems), 0)
	testing.expect_value(t, len(agents), 1)
	expected := DEFAULT_NAV_AGENT
	expected.radius = 0.25
	testing.expect_value(t, agents[0], expected)
}

@(test)
agent_types_take_their_fields_and_a_later_line_wins :: proc(t: ^testing.T) {
	text := "nav.agents = Human, Large\nnav.agent.Large.radius = 0.8\nnav.agent.Large.height = 3\nnav.agent.Human.step_height = 0.4\n# The user file.\nnav.agent.Large.radius = 1\n"
	agents, problems := nav_agents_parse(text, context.temp_allocator)
	testing.expect_value(t, len(problems), 0)
	testing.expect_value(t, len(agents), 2)
	testing.expect_value(t, agents[0], Nav_Agent{"Human", 0.4, 1.8, 0.4, 45})
	testing.expect_value(t, agents[1], Nav_Agent{"Large", 1, 3, 0.35, 45})
	testing.expect(t, nav_volume_agents(0, 1) && nav_volume_agents(0b10, 1) && !nav_volume_agents(0b10, 0))
}

@(test)
agent_types_report_their_problems_by_line :: proc(t: ^testing.T) {
	text := "nav.agents = Human, Human, Big.One\nnav.agent.Small.radius = 0.2\nnav.agent.Human.slope = 30\nnav.agent.Human.radius = x\n"
	agents, problems := nav_agents_parse(text, context.temp_allocator)
	testing.expect_value(t, len(agents), 1)
	testing.expect_value(t, agents[0], Nav_Agent{"Human", 0.4, 1.8, 0.35, 45})
	testing.expect_value(t, len(problems), 4)
	if len(problems) == 4 {
		testing.expect_value(t, problems[0].line, 1)
		testing.expect_value(t, problems[1], Nav_Settings_Problem{2, `nav.agent.Small.radius: nav.agents does not name "Small"`})
		testing.expect_value(t, problems[2].line, 3)
		testing.expect_value(t, problems[3].line, 4)
	}
}
