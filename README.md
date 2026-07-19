# Raid Death Count

A lean death-count HUD for **TBC Anniversary** (client 2.5.6).

Raid Death Count tracks and syncs per-player **death counts** in your raid and shows them in a
movable, resizable Details-style HUD (class icon, name, count), sorted by deaths descending. It is
**dependency-free**: it runs stand-alone on the stock WoW API, with no external libraries.

## How it works

- **Death detection** polls `UnitIsDeadOrGhost` for each group member, so it catches far-away
  deaths a combat-log-only approach would miss. Feign Death is ignored, and a first-sight baseline
  means players already dead when you join are not miscounted.
- **Sync** shares counts over addon comms (RAID/PARTY). Counts are monotonic within a raid and
  merged by MAX, so late joins, disconnects, and duplicate messages all self-heal.
- **Raid scoping** keeps each raid's counts separate (by lockout / instance), so an old raid's
  totals never bleed into a new one.

## Installation

1. Clone or download this repository.
2. Put the `raid-death-count` folder into your `World of Warcraft\_anniversary_\Interface\AddOns\`
   directory.
3. Restart the client, or `/reload`, and enable **Raid Death Count** in the AddOns list.

## Usage

- `/rdc` (or `/rdc toggle`) - toggle the HUD.
- `/rdc report [player <name> | top3 | top5 | all]` - report counts to raid/party (default: all).
- `/rdc lock` - toggle the HUD move + resize lock.
- `/rdc reset` - clear the current raid's counts.
- `/rdc <anything else>` - print the command help.

## Status

Early build. The core, sync, and HUD are in place; in-game testing across multiple clients is
ongoing.
