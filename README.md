# BotTakeover

SourceMod plugin for Counter-Strike: Source that lets a dead player take control of a living bot
of his team, like in CS:GO.

Pure SourcePawn, no gamedata of its own: it only uses SourceMod's `CS_RespawnPlayer`, whose
gamedata ships with SourceMod for `linux` and `linux64`, so it runs on 64-bit CS:S servers.

## How it works

A dead player spectates a living bot of his team (first person or chase camera) and presses **E**,
or types `!takeover`. A hint tells him when he can.

- **The player takes the bot's place**: same position, view angles and speed, same health, armor,
  helmet, defuse kit and night vision. The bot's own weapon entities move to him, so clips,
  silencers and burst modes stay as they were; reserve ammo and grenade counts are copied, and the
  bot's active weapon stays drawn. The C4 moves with the other weapons.
- **The bot leaves silently** for the rest of the round: the plugin blocks its `player_death` and
  `player_hurt` events (no kill feed line, nothing for the stats plugins), keeps its suicide out
  of the game log (HLstatsX), gives back the frag and death the suicide cost, and removes the
  body. It respawns normally next round.
- **The player respawns before the bot dies**, so the team is never seen wiped out.

A takeover is refused:

- during the freeze time or after the round end;
- when the player already used his `sm_takeover_per_round` takeovers this round;
- when the bot was hurt less than `sm_takeover_damage_delay` seconds ago;
- when the bot is planting, defusing or on a ladder;
- when a standing player would not fit where the bot is (crouched under something).

The plugin is meant for round-based modes. On a respawn mode (deathmatch) it has no use.

## Installation

Extract the release archive matching your SourceMod version (`-sm1.12` or `-sm1.13`) into `cstrike/`:

- `addons/sourcemod/plugins/BotTakeover.smx`
- `addons/sourcemod/translations/BotTakeover.phrases.txt`

The config `cfg/sourcemod/plugin.BotTakeover.cfg` is created on first load.

## Player commands

| Command | Description |
| - | - |
| `sm_takeover` | Take control of the bot you are spectating (same as pressing E) |

## Cvars

| Cvar | Default | Description |
| - | - | - |
| `sm_takeover_enable` | `1` | Let dead players take control of a living bot of their team |
| `sm_takeover_per_round` | `1` | Takeovers per player and per round, `0` = no limit |
| `sm_takeover_damage_delay` | `2.0` | Seconds after a bot was last hurt before it can be taken over |
| `sm_takeover_use_key` | `1` | Take over the spectated bot with the use key (E) |
| `sm_takeover_hint` | `1` | Show a hint when a dead player spectates a bot he can take over |
| `sm_takeover_announce` | `1` | Tell the player's team who took control of which bot |

## License

GPL-3.0, see [LICENSE](LICENSE).
