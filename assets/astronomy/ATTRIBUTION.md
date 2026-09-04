# TROOP photographic lunar sky

The lunar sky uses observational imagery, not generated images. Full-sphere textures have no terrain horizon and remain fixed at optical infinity.

## Milky Way panorama

- Asset: `eso_milky_way.jpg` (4000 × 2000 publication JPEG, downloaded without content changes).
- **Credit: ESO/S. Brunier**.
- Source: [The Milky Way panorama, ESO eso0932a](https://www.eso.org/public/images/eso0932a/).
- Direct asset: https://cdn.eso.org/images/publicationjpg/eso0932a.jpg
- License: [Creative Commons Attribution 4.0 International](https://creativecommons.org/licenses/by/4.0/), under [ESO image use conditions](https://www.eso.org/public/outreach/copyright/). This is the publicly distributed 18-megapixel-derived publication image, not the separately restricted 800-megapixel original.
- Presentation adaptations: spherical mapping, exposure control, celestial overlay. No endorsement by ESO is implied. The full credit appears in the game while the Moon is active.

## Earth

- Asset: `nasa_blue_marble.png` (2048 × 1024).
- **Credit: NASA/Goddard Space Flight Center Scientific Visualization Studio. The Blue Marble Next Generation data is courtesy of Reto Stockli (NASA/GSFC) and NASA's Earth Observatory.**
- Source: [Blue Marble — A Seamless Image Mosaic of the Earth](https://svs.gsfc.nasa.gov/2915/).
- Direct asset: https://svs.gsfc.nasa.gov/vis/a000000/a002900/a002915/bluemarble-2048.png
- NASA-produced imagery, used under [NASA image use guidance](https://www.nasa.gov/nasa-brand-center/images-and-media/).
- Presentation adaptations: spherical mapping, sunlight terminator and atmospheric limb. The texture is a historic satellite composite, not live weather.

## Real constellation figure guide

- Asset: `nasa_constellation_figures.png` (4096 × 2048), losslessly converted from NASA's galactic-coordinate TIFF for engine compatibility. No coordinates or linework were changed.
- **Credit: NASA/Goddard Space Flight Center Scientific Visualization Studio. Constellation figures based on those developed for the IAU by Alan MacRobert of Sky and Telescope magazine (Roger Sinnott and Rick Fienberg).**
- Source: [Deep Star Maps 2020](https://svs.gsfc.nasa.gov/4851/).
- Direct source: https://svs.gsfc.nasa.gov/vis/a000000/a004800/a004851/constellation_figures_4k_gal.tif
- This source uses IAU constellation figures; these familiar line figures, unlike official constellation boundaries, are not an official IAU definition.

## Astronomy and simulation limits

- Planet positions use [NASA/JPL's approximate planetary positions, Table 1](https://ssd.jpl.nasa.gov/planets/approx_pos.html), at the reproducible simulation epoch 2026-09-03 12:00 UTC. The code solves Kepler's equation and transforms J2000 ecliptic to equatorial then Galactic coordinates. All seven other planets are represented; the local horizon may hide some, and Uranus/Neptune need observation exposure.
- Observer translation is approximated by the Earth–Moon barycenter. Lunar parallax, light-time, aberration and full SPICE lunar orientation/libration are not simulated. This is not a navigational ephemeris.
- The gameplay solar clock rotates the celestial frame to the simulated Sun. Earth stays above the chosen near-side colony, and Earth's rendered illuminated limb follows the same Sun direction as terrain/panels. This compresses lunar time and does not reproduce a particular real-world observing site.
- Sun angular diameter: 0.533 degrees. Earth angular diameter: 1.90 degrees. Planets are unresolved point sources with a minimum screen-readable footprint, enlarged in observation mode.
- The Milky Way, external galaxies and nebulae come from the real long-exposure panorama. Photograph/observation exposure reveals faint structure and is not a claim that these colours or all objects are simultaneously visible to unaided eyes in sunlit lunar terrain.
