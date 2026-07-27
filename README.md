# Raid Death Count

A lean death-count HUD for **TBC Anniversary** (client 2.5.6).

Who died, how many times, at a glance. Raid Death Count keeps a running tally for everyone in your
raid and shows it in a movable, resizable Details-style list: class icon, name, count, sorted by
deaths. No dependencies, no setup, no configuration to get wrong.

## What it does

- **Counts deaths automatically** while you are in the raid instance. Nothing to start or stop.
- **Shares counts with your raid.** Anyone else running the addon sees the same numbers, and joining
  late, disconnecting, or reloading all sort themselves out on their own.
- **Keeps raids separate.** A different raid, or a new week's lockout of the same one, starts fresh at
  zero. There is no reset to remember.
- **Reports to chat** with one click, so you can post the damage after a wipe.

## The HUD

- Rows sorted by deaths, with a class-coloured bar behind each one.
- Header buttons, right to left: close, lock, **A** / **3** / **5** to report all or the top 3 or 5 to
  chat, and a sync indicator showing how many raiders are running the addon. Hover it for details.
- Scrolls with the mouse wheel when more players die than fit, so you can keep the frame small.
- Unlock it to drag by the title bar and resize from the bottom-right corner. Clicking a row will not
  move it.
- The minimap skull toggles the HUD, and drags around the ring to reposition.

## Installation

1. Download this repository, or grab the latest [release](https://github.com/Jase-Develop/raid-death-count-tbc/releases).
2. Put the `raid-death-count` folder into `World of Warcraft\_anniversary_\Interface\AddOns\`.
3. Restart the client, or `/reload`, then enable **Raid Death Count** in the AddOns list.

## Commands

| Command | Does |
| --- | --- |
| `/rdc` | Show or hide the HUD. |
| `/rdc report` | Post counts to raid chat. Add `top3`, `top5`, or `player <name>` to narrow it. |
| `/rdc lock` | Lock or unlock moving and resizing. |
| `/rdc minimap` | Show or hide the minimap button. |
| `/rdc demo` | Fill the HUD with sample data for a look around. Never touches real counts. |
| `/rdc version` | Print the version. |

Anything else prints the list above.
