# ZelOS Power Monitor

A ComputerCraft program that shows the energy in Advanced Solar Generators and Thermal Expansion Energy Cells on a monitor. It uses the ZelOS GUI style.

## Setup

1. Put a wired modem on the computer and on each solar generator, energy cell and the monitor. Connect them with networking cable.
2. Right click each modem so it turns on and shows the peripheral name in chat, for example `advanced_solar_generator_0`, `cofh_thermalexpansion_energycell_0` and `monitor_0`.
3. Copy `power_monitor.lua` to the computer and run it. To start it on boot, save it as `startup.lua`.

The program finds every peripheral whose name starts with `advanced_solar_generator` or `cofh_thermalexpansion_energycell`, so you can add or remove devices while it runs.

## What it shows

* A total for each group and a card for each device.
* An energy bar with the fill percentage. The bar turns green above 60%, yellow above 25% and red below that.
* A status for each device and each total: `CHARGING`, `DISCHARGING`, `IDLE`, `FULL`, `EMPTY`, `SAMPLING` (first second after start) or `NO DATA`.
* The average energy change per tick over the last 10 seconds, plus stored and maximum energy.

On a 3x3 monitor the program uses text scale 0.5 (57x38 characters) with solar generators on the left and energy cells on the right. When a group has more devices than fit, its pages rotate every 6 seconds. Touch the monitor to go to the next page.

## Settings

The `CONFIG` table at the top of the file holds the settings:

* `monitorName`: set this to a name like `"monitor_0"` if more than one monitor is connected.
* `refreshSeconds`, `rateWindowSeconds`, `pageSeconds`: timing.
* `idleThreshold`: the smallest change per tick that counts as charging or discharging.
* `groups[].unit`: the unit shown for each group (EU for solar, RF for cells).
