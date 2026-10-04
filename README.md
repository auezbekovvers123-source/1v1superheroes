# 1v1superheroes

Third-person superhero brawler prototype in **Godot 4.6** (Forward+, Jolt physics).
Open `1v1supers/project.godot` and press Play — the main scene is `prototype.tscn`.

## Controls

| Action | Key |
|---|---|
| Move / run | WASD / Shift |
| Jump (and fly up) | Space |
| Dash | Ctrl |
| Punch combo (hook, jab, cross, spin kick) | Left mouse |
| Aim (tighter target lock) | Right mouse |
| Interact: pick up item, grab/drop a knocked-out body, use a held usable item | F or E |
| Throw: hold to charge, release to throw (tap to drop) | G or Q |
| Power: fly while wearing the cape (jump first) | R |
| Fly down | C |
| Inventory (drag the item in your hand onto a ring to wear it) | Tab |
| Show hitboxes | \` |
| Free the mouse | Esc |

## How the code is organised

Each piece owns one job; nothing else reaches into it.

```
Player (CharacterBody3D)            Scripts/Characters/Player.gd — locomotion + wiring
├─ Input        PlayerInput         WHAT the fighter wants this frame (the only reader of Input)
│                                   LocalPlayerInput = keyboard/mouse, ScriptedPlayerInput = AI/tests/network
├─ state        PlayerState         WHAT it is doing — exactly one at a time:
│                                   Free, Attack, Dash, Turn, Gesture, ThrowCharge, UseItem, Fly, Dead
├─ Animator     PlayerAnimator      the only thing that touches the AnimationTree
├─ MeleeCombat                      combo data, hitboxes, target finding
├─ HandHold                         the held item: visual, use, throw
├─ Stamina, Footsteps
├─ Health, Hurtbox3D                hit points / where you can be hit
├─ RagdollController, RagdollGrabber
└─ Inventory (hand), Equipment (worn items)
```

- **Adding a state**: subclass `PlayerState`, answer its queries (`allows_jump`,
  `allows_sprint`, `update_facing`, …), register it in `Player._ready`.
  States decide which actions may interrupt them; a target state refuses entry
  through `can_enter`.
- **Hits** travel as a `HitInfo` (damage, knockback, hitstop, attacker, kind).
  `Health` only keeps score; the body that was hit applies knockback
  (`HitReaction`), and `RagdollController` alone starts the death ragdoll.
- **A second fighter / AI**: instance `Scenes/Characters/player.tscn` and call
  `set_input(ScriptedPlayerInput.new())` (or your own `PlayerInput` subclass).
  Only the fighter with a local human input gets the camera and the mouse, and
  the HUD/inventory follow the `local_player` group.

## Tests

Headless gameplay tests drive the player through `ScriptedPlayerInput` and check
speeds, jump heights, dash distance, combo damage/timing, throws, flight,
death/respawn, grabbing, two-player independence and the inventory UI. Numbers
marked *golden* were measured on the game before the refactor.

```sh
cd 1v1supers
GODOT=/path/to/godot tests/run_tests.sh               # all tests
godot --headless --path . -s tests/test_combat.gd     # one test
```

## Tools and addons

- `addons/CityBuilderCG` (editor) — bakes a city to `Scenes/Levels/generated_city.tscn`;
  `Scripts/City/CityGenerator.gd` builds one at runtime (`CityTest` node in the levels).
- `addons/better_godot_mcp`, `addons/godot_mcp` — editor bridges for AI tooling. Exclude
  `addons/` and `tests/` from export presets.
