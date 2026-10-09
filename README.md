# 1v1superheroes

Third-person superhero brawler prototype in **Godot 4.6** (Forward+, Jolt physics).
Open `1v1supers/project.godot` and press Play — the main scene is `prototype.tscn`.

## Controls

| Action | Key |
|---|---|
| Move / run | WASD / Shift |
| Jump (and fly up) | Space |
| Dash (you can't be hit for the first 0.18 s: dodge through a swing) | Ctrl |
| Punch combo (hook, jab, cross, spin kick) | Left mouse |
| Block (hold). Raise it just before a hit to **parry** | V or mouse thumb button |
| Aim (tighter target lock) | Right mouse |
| Interact: pick up item, grab/drop a knocked-out body, use a held usable item | F or E |
| Throw: hold to charge, release to throw (tap to drop) | G or Q |
| Power: fly while wearing the cape (jump first) | R |
| Fly down | C |
| Inventory (drag the item in your hand onto a ring to wear it) | Tab |
| Show hitboxes | \` |
| Multiplayer menu (host / join / invite) | F1 |
| Free the mouse | Esc |

## Multiplayer (Steam or direct)

Two players, each on their own PC. Press **F1** in game.

**Over Steam** (no IP addresses, no port forwarding):

1. One-time setup: install the **GodotSteam GDExtension** for Godot 4 (version
   4.14 or newer; it includes `SteamMultiplayerPeer`). In the editor: *AssetLib*
   tab → search "GodotSteam" → install. Or download it from
   <https://codeberg.org/godotsteam/godotsteam/releases> and unzip it so that
   `1v1supers/addons/godotsteam/` exists. Restart the editor. Without it the
   game runs as before and the Steam buttons stay greyed out. Your friend needs
   it too: commit the folder, or send them an exported build (it includes it).
2. Both players: Steam running and signed in, **two different Steam accounts**,
   Steam friends with each other, the game already started.
3. Host: F1 → *Host game* → *Invite friend* (opens the Steam overlay), or
   *Copy lobby ID* and send it.
4. Friend: accept the invite in Steam, or F1 → *Find games* → *Join selected*,
   or paste the lobby ID → *Join ID*.

The game uses Steam App ID **480** ("Spacewar", Valve's public test app), so
Steam shows you as playing Spacewar. Put your own App ID in
`Scripts/Net/SteamLobby.gd` once the game has a Steam page.

**Direct** (LAN, or two windows on one PC): F1 → *Host* on one, *Join* with the
host's address on the other (default port UDP 24680; over the internet the host
must forward it, which is why Steam is easier). Command line shortcuts (after
`--`): `--host`, `--join=192.168.1.20`, `--name=Ann`. To try two windows from
the editor: *Debug → Customize Run Instances…*, 2 instances, arguments
`-- --host` and `-- --join=127.0.0.1`. Add `--netsim=80,30,5` to a window to
simulate a bad connection (80 ms lag, +0..30 ms jitter, 5% packet loss). The F1
panel shows ping and how smoothly the other fighter replays.

How it works:

- Each PC runs its own fighter with no waiting, so your own moves never lag.
- 60 times a second each PC sends what its player pressed and where the fighter
  ended up. The other PC replays those inputs on a copy of the fighter
  (`NetworkPlayerInput`) about 3 ticks behind, so the copy walks, punches and
  animates by itself, and gets nudged toward the real position. A lost packet's
  tick is replayed with the buttons still held; presses travel as counters, so
  a lost packet never loses a punch.
- Hits: what the attacker saw counts. The victim's PC applies the damage,
  knockback and KO and tells everyone, so each hit lands exactly once.
- Hits taken, respawns, throws, pickups and worn items are sent reliably and
  applied on the same tick they happened on the owner's PC.
- Limits: training dummies, ragdoll flops and items lying around are simulated
  on each PC separately, so they can differ a little. Also: 2 players, no
  reconnect, no cheat protection (play with friends).

## Fighting

- **Block** (hold V): hits from the front only chip 15% of their damage and push
  you back a little, but cost stamina (kicks cost more). Run out of stamina and
  the guard breaks: the hit lands in full and you stagger. Hits from behind
  ignore the guard. You walk slowly with the guard up, and can punch or dodge
  straight out of it.
- **Parry**: raise the guard within 0.15 s of a hit landing and it does nothing;
  the attacker staggers for 0.6 s, open for a counter. The guard must have been
  down for 0.4 s first, so mashing block doesn't parry.
- **Dodge**: the dash can't be hit for its first 0.18 s.

## How the code is organised

Each piece owns one job; nothing else reaches into it.

```
Player (CharacterBody3D)            Scripts/Characters/Player.gd — locomotion + wiring
├─ Input        PlayerInput         WHAT the fighter wants this frame (the only reader of Input)
│                                   LocalPlayerInput = keyboard/mouse, ScriptedPlayerInput = AI/tests/network
├─ state        PlayerState         WHAT it is doing — exactly one at a time:
│                                   Free, Attack, Dash, Turn, Gesture, ThrowCharge, UseItem, Fly,
│                                   Block, Stagger, Dead
├─ Animator     PlayerAnimator      the only thing that touches the AnimationTree
├─ MeleeCombat                      combo data, hitboxes, target finding
├─ Guard                            block / parry / guard break: edits incoming hits
├─ HandHold                         the held item: visual, use, throw
├─ Stamina, Footsteps
├─ Health, Hurtbox3D                hit points / where you can be hit
├─ RagdollController, RagdollGrabber
└─ Inventory (hand), Equipment (worn items)
   NetSync                          online only: sends this fighter / replays the other one

Net (autoload)   Scripts/Net/Net.gd — sessions (Steam lobby or ENet), spawns the
                 other player's copy, routes every network message
SteamLobby       GodotSteam calls (lobby, invite, SteamMultiplayerPeer)
NetCodec         the packet format
NetMenu          the F1 panel
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
death/respawn, grabbing, two-player independence, block/parry/guard break/dodge
(`test_defense`) and the inventory UI. Numbers marked *golden* were measured on
the game before the refactor.

The network tests start a second Godot process and play a real session over
localhost: `test_network` (movement, view, hits both ways, block and parry
across machines, KO/respawn, pickups, throws, worn items, leaving), `test_network_lag` (the same over 70-110 ms lag
with 5% packet loss), `test_steam_flow` (lobby, invite, join and play through a
fake Steam; real Steam needs a Steam client, so test that by hand) and
`test_net_menu`.

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
