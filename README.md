# Raid Death Count

A lean death-count HUD for **TBC Anniversary** (client 2.5.6).

Raid Death Count tracks and syncs per-player **death counts** in your raid and shows them in a
movable, resizable Details-style HUD (class icon, name, count), sorted by deaths descending. It is
**dependency-free**: it runs stand-alone on the stock WoW API, with no external libraries.

## How it works

- **Death detection** polls `UnitIsDeadOrGhost` for each group member, so it catches far-away
  deaths a combat-log-only approach would miss. Feign Death is ignored, and a first-sight baseline
  means players already dead when you join are not miscounted. Deaths are only counted while you are
  physically inside the raid instance (not out in the world or a dungeon).
- **Sync** shares counts over addon comms (RAID/PARTY). Counts are monotonic within a raid and
  merged by MAX, so late joins, disconnects, and duplicate messages all self-heal.
- **Raid scoping** keeps each raid's counts separate (by lockout / instance), so an old raid's
  totals never bleed into a new one, and a fresh lockout of the same instance auto-resets to zero.
- **Counts are saved per character**, so an alt does not inherit a raid it was never in. HUD position
  and size are shared account-wide. If that alt does walk into the raid with other addon users, sync
  fills its counts back in: the counts belong to the raid, the storage belongs to the character.

## The HUD

- Details-style rows (rank, class icon, name, count) with a class-coloured bar, sorted by deaths.
- Header controls (right to left): close, a pin/lock toggle for move + resize, report buttons
  **A** / **3** / **5** (report all / top 3 / top 5 to chat), and a sync indicator showing how many
  addons are in sync (hover it to see who).
- Movable and resizable (drag the frame, or the bottom-right grip) when unlocked.
- A minimap button (skull) toggles the HUD; drag it around the ring to reposition.

## Installation

1. Clone or download this repository.
2. Put the `raid-death-count` folder into your `World of Warcraft\_anniversary_\Interface\AddOns\`
   directory.
3. Restart the client, or `/reload`, and enable **Raid Death Count** in the AddOns list.

## Usage

- `/rdc` (or `/rdc toggle`) - toggle the HUD.
- `/rdc report [player <name> | top3 | top5 | all]` - report counts to raid/party (default: all).
- `/rdc lock` - toggle the HUD move + resize lock.
- `/rdc minimap` - show/hide the minimap button.
- `/rdc demo` - toggle sample data for a UI preview (local only, never touches real counts).
- `/rdc version` - print the addon version.
- `/rdc <anything else>` - print the command help.

Counts reset automatically per raid: a new lockout or a different raid starts every client at zero,
so there is no manual reset to run.

## Status

Working build (v0.3), tested in a live raid on a single client. The core, sync, and HUD are in place;
cross-client sync verification is ongoing.
