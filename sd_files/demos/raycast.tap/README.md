# Raycast

A small retro FPS renderer demonstrating `gfx.tline`. Copy the entire
`raycast.tap` folder to the SD card and refresh the launcher, or launch
`/sd/raycast.tap` from the recovery shell. Requires firmware with `gfx.tline`.

- **@/W** or **Up/Down**: walk forward/backward.
- **Q/E** or **Left/Right**: turn left/right.
- **!/#**: strafe left/right.
- **R**: reset position.
- **Esc**: exit.

The enclosed maze uses grid DDA raycasting and one vertical textured line per
viewport column. Perpendicular camera depth keeps walls straight. Horizontal
textured lines project the floor and ceiling, using automatic texture wrapping.
A column sweep finds visible floor spans below walls and mirrors them above
walls for the ceiling. Span buffers are reused, and graphics, input, and frequently
used math functions are cached in local references.
All textures in `spr/` are original, opaque 32x32 PNGs. Darker wall variants shade
the second face direction. The view fills the 320 × 180 screen and casts one
wall ray per column. Wider canvases show more of the maze to either side while
keeping the same vertical field of view. The FPS and CPU0/CPU1 load overlays
appear in the top-right corner and refresh every half second.
Walking and strafing accelerate smoothly and coast briefly after release.
Movement has a collision radius, wall sliding, and bounded time steps.
Decorative barrels face the camera and are drawn farthest first. Each column
is clipped against nearer walls. Edit the `barrels` positions in `app.lua` to
place them in open cells.
`MAX_DISTANCE` near the top of `app.lua` limits wall traversal and surface
texturing to 12 map cells of perpendicular camera depth. A black rectangle at
that depth closes distant openings behind nearer walls. Lower this value to
reduce work further.
Map strings are decoded into numeric rows once at startup. Floor row
depths and column camera coordinates are also precomputed for the fixed viewport.

Edit the map strings in `app.lua`: `0` is empty, `1` is brick, and `2` is metal.
Keep the boundary enclosed and the starting position in an empty cell.
