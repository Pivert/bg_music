# bg_music - Ambient Background Music for Luanti

A Luanti server mod that provides ambient background music based on player location. Music starts playing when players enter defined zones and stops when they leave.

## Features

- **Zone-based music**: Define spherical zones where music plays
- **Automatic scanning**: Scans for new music files every 10 minutes
- **Regex filtering**: Filter songs by filename patterns
- **Volume control**: Set custom volume levels for each zone
- **Player-specific**: Each player hears music independently
- **Persistent storage**: Music locations are saved between server restarts

## Installation

1. Copy the `bg_music` folder to your Luanti server's `mods/` directory
2. Place your `.ogg` music files in `mods/bg_music/sounds/`
3. Enable the mod in your world configuration
4. Grant the `setmusic` privilege to trusted players

## Commands

### /setmusic
**Usage:** `/setmusic <radius_trigger> <extra_radius> [<volume>] [<regex>]`

Sets a background music zone at your current position.

- **radius_trigger**: Distance in meters from the center where music starts playing
- **extra_radius**: Additional distance beyond trigger radius where music stops
- **volume**: Optional volume level (5-99, default: 65)
- **regex**: Optional regex pattern to filter songs (e.g., "calm.*forest")

**Example:**
```
/setmusic 20 10 75 calm
```
This creates a zone with 20m trigger radius, 10m extra radius, 75% volume, playing only songs with "calm" in the filename.

### /getmusic
**Usage:** `/getmusic`

Lists all defined background music locations with their settings.

### /delmusic
**Usage:** `/delmusic <index>`

Removes a background music location by its index (shown by `/getmusic`).

**Example:**
```
/delmusic 3
```
Removes the 3rd music location.

### /listmusic
**Usage:** `/listmusic [<regex>]`

Lists available music files with optional regex filtering. Useful for testing regex patterns before using them in zones.

**Examples:**
```
/listmusic forest
```
Lists all songs with "forest" in the filename.

```
/listmusic "test1|test2"
```
Lists songs containing either "test1" OR "test2" (use quotes for patterns with special characters).

### /rescanmusic
**Usage:** `/rescanmusic`

Manually triggers a rescan of the music folder. Useful after adding new music files without waiting for the automatic 10-minute scan.

**Example:**
```
/rescanmusic
```
Rescans the sounds/ directory and reports how many songs were found.

## Privileges

- **setmusic**: Required to use `/set_bgmusic` and `/rm_bgmusic` commands

## How It Works

1. **Music Zones**: Each zone is defined by a center position, trigger radius, and extra radius
2. **Entering Zone**: When a player enters the trigger radius, a new random song starts playing
3. **Exiting Zone**: When a player exits the trigger radius + extra radius, music stops
4. **Song Selection**: A new random song is selected every time a player enters a zone
5. **Volume**: Each zone can have its own volume level

## Music Stereo Node

The mod provides its own stereo node (`bg_music:stereo`) that can be crafted and placed:
- **Right-click**: Start playing a random song within 15m radius
- **Second right-click**: Stop the music
- **Continuous random**: Each song completion triggers a new random song
- **Volume**: Fixed at 70% for stereo playback
- **Crafting**: Made with steel, copper, mese crystal, and wood

**Note**: This is a separate stereo node from homedecor's stereo, designed specifically for music playback.

## File Structure

```
bg_music/
├── init.lua          # Main mod code
├── mod.conf          # Mod configuration
├── README.md         # This file
└── sounds/           # Place your .ogg music files here
    ├── song1.ogg
    ├── song2.ogg
    └── ...
```

## Music Files

- Format: OGG Vorbis (.ogg)
- Location: `mods/bg_music/sounds/`
- Naming: Use descriptive filenames for easy filtering with regex
- Scanning: Files are automatically detected every 10 minutes
- Manual Scan: Use `/rescanmusic` to trigger immediate rescan

## Regex Patterns (Lua Patterns)

This mod uses Lua's pattern matching, which is slightly different from traditional regex:

- `.` - any character
- `%a` - letters, `%d` - digits, `%w` - alphanumeric
- `+` - one or more, `*` - zero or more, `?` - zero or one
- `|` - OR operator (use quotes: `"pattern1|pattern2"`)
- `^` - start of string, `$` - end of string
- `[abc]` - character set, `[^abc]` - negated set

**Always use quotes** around patterns containing special characters like `|`, `*`, `+`, etc.

## Examples

### Creating a Forest Ambiance
```
# Stand in the forest area
/setmusic 25 15 70 forest
```

### Creating a Cave Ambiance
```
# Stand in the cave
/setmusic 15 10 60 cave
```

### Creating a Town Theme
```
# Stand in the town center
/setmusic 30 20 75 "town|village"
```

### Using OR in Regex Patterns
When using patterns with special characters like `|`, always use quotes:

```
# Match songs with "forest" OR "nature" in the name
/setmusic 25 15 70 "forest|nature"

# Match songs starting with "day" OR "night"
/setmusic 20 10 65 "^day|^night"

# Match multiple specific songs
/setmusic 15 5 80 "calm_forest|peaceful_meadow|gentle_stream"
```

**Important:** Always use quotes around patterns containing special characters like `|`, `*`, `+`, etc.

## Troubleshooting

### No Music Playing
- Check that .ogg files are in the `sounds/` directory
- Verify the zone settings with `/get_bgmusic`
- Ensure the player has entered the trigger radius
- Check server logs for scanning messages

### Invalid Regex Pattern
- The mod will log a warning for invalid regex patterns
- When in doubt, omit the regex parameter to use all songs

### Permission Denied
- Ensure the player has the `setmusic` privilege
- Use `/grant <player> setmusic` to grant the privilege

## License

This mod is released under the GNU General Public License v3.0 or later.
See the LICENSE file for details.

## Author

Pivert <fun@pivert.org>

## Version History

- 1.0.0: Initial release with zone-based music system