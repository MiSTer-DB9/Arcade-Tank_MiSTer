# License and acknowledgements

The Tank core is distributed under GPL-3.0-or-later. The complete GPL
version 3 text is in LICENSE. The core's own files are written for this
project by RetroShrimp; where a file's header offers it under
GPL-2.0-or-later, that file may also be used on those terms on its own.
The combined work is GPL-3.0-or-later because it includes `rtl/video/crt_adjust.sv` (below).

The game name and hardware identifiers identify compatible hardware. No game
ROMs, schematics or Atari / Kee Games manuals are included. The MRA files
name the one ROM the board uses (90-2006, at K10) by CRC.

The MiSTer framework (the `sys` folder) is copied without modification from
Template_MiSTer (commit 3ea1134), with its original notices. Framework
sources include work by Alexey Melnikov and their respective credited
authors.

`rtl/video/crt_adjust.sv` is the CRT Adjust module by Umberto Parisi (rmonic79), from
github.com/rmonic79/MiSTer-CRT-Adjust (commit c682de9), GPL-3.0-or-later.
It is adapted to Tank's 904-pixel line and interlaced frame; the changes are
listed in the file's header.

`rtl/video/tank_rotate.sv` follows the triple-buffering scheme of the framework's
`screen_rotate` module.

MAME's Tank netlist (`nl_tank.cpp`) and its netlist simulator `nltool`
were used as development references and for circuit measurements; no MAME
source is included. Comments that cite `nl_tank.cpp` name its ICs and nets.
