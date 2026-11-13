# Utility

The decision module of the `utility` technique, in `lib/engine/ai/utility`. When an agent thinks, the module scores each option of the agent's decision, and runs the best one. Read [Agents](agents.md) and [Content: Decisions: Utility](../content/kinds/decisions.md#utility) first. The second document gives the text, the options, the considerations and the curves.

**In this document:** [Design](#design) · [Registering](#registering) · [A think](#a-think) · [Scoring](#scoring) · [Choosing](#choosing) · [Targets](#targets) · [Actions](#actions) · [Time](#time) · [Scores for debugging](#scores-for-debugging) · [Determinism](#determinism) · [Reload and restart](#reload-and-restart) · [Limits](#limits)

## Design

1. **Scores, not rules.** Each option scores how much it makes sense now, from 0 up to its weight, and the best one runs. A designer shapes how much each input matters with a curve, not with code. An option can therefore win in a situation that no one planned for.
2. **The state is in the agent.** The running option, each option's cooldown and the last scores are at offsets in the agent's module state, which the cooker sizes. The module holds no state of its own, so a code reload keeps every agent where it was ([Agents: Reload and restart](agents.md#reload-and-restart)).
3. **Every value comes from the blackboard or the world.** Inputs read the agent's keys, the places of entities, and the ticks at which keys changed. The module calls no script.
4. **Randomness is the agent's own.** A weighted pick draws from the agent's generator, which is seeded by its slot, so a run replays the same ([Determinism](#determinism)).

## Registering

`utility.register(&g.ai)` registers the module for the `utility` technique. `register_world` calls it after `ai.register`, which clears the modules, so a code reload registers the module again.

The module has a `check`, which `ai` calls before an agent starts with a decision ([Agents: Thinking](agents.md#thinking)). It runs `format.utility_check`, so `think` reads only data whose indices, ranges, offsets and keys were checked. If the check refuses the data, the agent waits, and `ai` gives a warning once.

## A think

1. **The running option ends** when the agent's action is no longer its action reference, running: the action succeeded or failed, or something else replaced it. Its cooldown starts.
2. **Every option is scored** ([Scoring](#scoring)). The running option's score is multiplied by `1 + momentum`.
3. **If no option scores above 0**, the module stops the running action, and the agent runs no option.
4. **If the running option's score is still the highest**, it goes on running. If it has a target and its best target changed, the module writes the new target into the key.
5. **Otherwise the module picks an option** ([Choosing](#choosing)). If it is not the running option, the old option's cooldown starts. The module then writes the new option's target, asks for its `set` writes, and asks to start its action, which stops the old one.

## Scoring

An option scores 0 when it is cooling down or its `when` does not hold. Otherwise its score is its weight times the product of its considerations' scores, each made up for the count of considerations by the compensation factor ([Content: Decisions: Options](../content/kinds/decisions.md#options)).

A consideration reads its input, normalizes it over its range, and maps it through its curve:
- **A float, int or bool key**: the key's value, a bool being 0 or 1.
- **`distance(a, b)`**: the meters between the places, from the entities' `Transform`s as they are at the think. An entity that is none, dead or without a `Transform` is infinitely far, so a range from near to far gives it 1, and a range from far to near gives it 0.
- **`since(key)`**: the seconds since the key's value last changed. `ai` notes the tick at which each write changes a key's bytes. A write of the same value is not a change, so a perception row that writes the same entity in each tick does not reset the time. Every key counts as changed when the agent starts.

The module keeps each option's score, before momentum, and the input and score of each of its considerations in the module state, for debuggers ([Scores for debugging](#scores-for-debugging)).

## Choosing

- **`pick = best`** takes the highest score. Of equal scores it takes the first option in the text.
- **`pick = weighted`** takes the options whose score is above 0 and at least the highest times `1 - within`, and draws one, each in proportion to its score. It draws from the agent's generator (`Think_Context.random`) only when more than one option is in the band.

**Momentum** keeps two close scores from making the agent switch back and forth. The running option gains its bonus in every think in which it runs. Another option cuts in only when its score is above the running option's score with the bonus. A running option that is still the highest is never drawn against, so a weighted pick does not replace it at random.

## Targets

An option with `target` is scored once for each entity in the agent's perception memory that it perceives now, by sight or by hearing ([Perception: Memory](perception.md#memory)), and that has the option's `target_tag`, if it names one. While an entity is scored, the module reads a copy of the agent's values in which the target key holds that entity. The guard, the arguments that the considerations read and the distances therefore see each candidate. The best entity, the first of equal ones in the memory's order, gives the option's score. When the option wins, the module writes the entity into the key, and the action reads the key when it starts.

- **With a memory and no candidate**, the option scores 0: there is nothing to act on.
- **Without a memory**, as for an agent without a `Perceiver` or one that has perceived nothing yet, the option is scored once, with the key as it is. A script or another system can then fill the key.

## Actions

An agent runs one action at a time ([Agents: Actions](agents.md#actions)). Each option has its own action reference, so the module knows which option the agent's action belongs to. A start applies after the tick, so the option sees its action running from the next think.

When the action ends, the next think scores the options again, without the ended option's bonus. An option whose action ended can run again at once, unless it has a cooldown. An action that fails at once, such as one that no native action or script defines, therefore runs again at each think. Give such an option a cooldown, or a guard.

## Time

Cooldowns count world ticks (`world.clock.tick`), and a time from a key is read when the option ends. `since` inputs are in seconds at the clock's tick rate. An option sees time pass only when the agent thinks.

## Scores for debugging

`ai.scores(s, entity)` gives what the agent's module scored in its last think, as `ai.Option_Score`s: each option's decision node ID, its action's name, its score before momentum, its best target or none, and the ID, normalized input and score of each of its considerations. A module gives these through `Module.scores`. The utility's reads its module state, so the scores cost nothing until something reads them. Scripts read the same through `Agent.scores(entity)` ([Agents: Scripts](agents.md#scripts)), and the decision editor's live view is to read them too.

## Determinism

The module writes only the agent's module state and the outputs of its `Think_Context`. It reads the blackboard as it was at the think. The weighted pick draws from the agent's own generator, which `ai` seeds from `ai.set_seed`'s seed and the agent's slot when the agent starts, never from an `Entity` value. A choice therefore gives the same result on one job or many, and a run with the same seed replays the same picks ([Agents: Determinism](agents.md#determinism)). The tests compare the module state and the values of 60 agents, with weighted picks, momentum, cooldowns and targets, on one job and on eight workers.

## Reload and restart

- **A code reload** keeps the running option, the cooldowns, the last scores, the generator and the running action. The action is neither started again nor stopped.
- **A recooked decision or blackboard** starts the agent again from its blackboard's defaults, with no option running.
- **A soft restart** starts every agent again.

## Limits

- **Writes apply after the tick.** The target and the `set` writes of the option that starts apply with its start, so the action reads them. A think reads the values that they replace until the next think.
- **Inputs are keys, distances and times.** An input that is a value of the target entity itself, such as its health, needs a key that a script or a system fills.
- **One target key per option.** An option chooses among the entities that the agent perceives now, not among the entities that it remembers.
- **No hysteresis per target.** Momentum keeps the running option, not its target: a running option follows the best target at each think.
