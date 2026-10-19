# ZelOS Power Monitor

A ComputerCraft program that shows the energy in Advanced Solar Generators and Thermal Expansion Energy Cells on a monitor. It uses the ZelOS GUI style.

## Setup

1. Put a wired modem on the computer and on each solar generator, energy cell and the monitor. Connect them with networking cable.
2. Right click each modem so it turns on and shows the peripheral name in chat, for example `advanced_solar_generator_0`, `cofh_thermalexpansion_energycell_0` and `monitor_0`.
3. Copy `power_monitor.lua` to the computer and run it. To start it on boot, save it as `startup.lua`.

The program finds every peripheral whose name starts with `advanced_solar_generator` or `cofh_thermalexpansion_energycell`, so you can add or remove devices while it runs.

## What it shows

The monitor has three tabs along the top. Touch a tab to switch.

* **OVERVIEW**: one card per group with a status label, a large energy bar, stored energy, net rate per tick, and the time until full or empty. Below them, a device status card counts how many devices are charging, discharging, idle, empty or not reporting, and names the lowest one.
* **SOLAR** and **CELLS**: the group card, then a card for each device with its percentage, energy bar, status, rate and stored energy. If there are more devices than fit, use the PREV and NEXT buttons. Pages also turn on their own every 8 seconds.

After 2 minutes without a touch the monitor goes back to the overview.

Statuses: `CHARGING`, `DISCHARGING`, `IDLE`, `FULL`, `EMPTY`, `SAMPLING` (first second after start) and `NO DATA`. An empty solar generator buffer shows `IDLE`, because solar generators pass their power straight through.

The program uses text scale 0.5 and needs a monitor at least 3x3 blocks large.

## Settings

The `CONFIG` table at the top of the file holds the settings:

* `monitorName`: set this to a name like `"monitor_0"` if more than one monitor is connected.
* `refreshSeconds`, `rateWindowSeconds`, `pageSeconds`, `returnToOverviewSeconds`: timing. Set a value to 0 to turn that feature off.
* `ignoreDirectSides`: when true, devices touching the computer directly (named `right`, `left` and so on) are skipped, so a device that is also on the wired network is not counted twice.
* `idleThreshold`: the smallest change per tick that counts as charging or discharging.
* `groups[].unit` and `groups[].colorName`: the unit and tab color for each group.
