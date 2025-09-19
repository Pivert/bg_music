-- bg_music mod for Luanti
-- Copyright (C) 2024 Pivert <fun@pivert.org>
-- This program is free software: you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation, either version 3 of the License, or
-- (at your option) any later version.

-- Global table for the mod
bg_music = {}
bg_music.music_locations = {}
bg_music.available_songs = {}
bg_music.player_music = {}
bg_music.last_scan_time = 0
bg_music.active_music = {} -- Unified tracking for ALL music types
bg_music.playlists = {} -- Track playlists per player and filter to avoid repeats
bg_music.player_volumes = {} -- Track personal volume per player (not persistent)

-- Music preference constants
local MUSIC_PREF_ENABLED = "enabled"
local MUSIC_PREF_DISABLED = "disabled"
local DEFAULT_MUSIC_VOLUME = 90 -- Default personal volume percentage

-- Get translator function (using .tr format like working example)
local modname = core.get_current_modname()
local S = core.get_translator(modname)

-- Debug function to test translations
local function debug_translate(key, ...)
	local result = S(key, ...)
	core.log("action", "[bg_music] Translation debug - Key: '" .. key .. "' -> Result: '" .. result .. "'")
	return result
end

-- Safe translation function with fallback
local function safe_translate(key, ...)
	local result = S(key, ...)
	-- If translation returns the same key (no translation found), log it
	if result == key and select('#', ...) > 0 then
		-- Try without parameters first
		local fallback = S(key)
		if fallback ~= key then
			return fallback
		end
	end
	return result
end

-- Configuration
local SCAN_INTERVAL = 600 -- 10 minutes in seconds
local DEFAULT_VOLUME = 65
local MIN_VOLUME = 5
local MAX_VOLUME = 99

-- Load music locations from storage
local storage = core.get_mod_storage()
local saved_locations = storage:get_string("music_locations")
if saved_locations and saved_locations ~= "" then
        bg_music.music_locations = core.deserialize(saved_locations) or {}
end

-- Function to scan for available songs
function bg_music.scan_songs()
        local sounds_path = core.get_modpath("bg_music") .. "/sounds"
        local old_count = #bg_music.available_songs
        local new_songs = {}

        -- Check if sounds directory exists
        local dir_list = core.get_dir_list(sounds_path, false)
        if not dir_list then
                core.log("action", "[bg_music] Sounds directory not found, creating it")
                core.mkdir(sounds_path)
                bg_music.available_songs = {}
                return
        end

        -- Find all .ogg files
        for _, filename in ipairs(dir_list) do
                if filename:match("%.ogg$") then
                        local song_name = filename:gsub("%.ogg$", "")
                        table.insert(new_songs, song_name)
                end
        end

        -- Sort songs for consistent ordering
        table.sort(new_songs)

        -- Check if songs changed
        local changed = false
        if #new_songs ~= old_count then
                changed = true
        else
                for i, song in ipairs(new_songs) do
                        if song ~= bg_music.available_songs[i] then
                                changed = true
                                break
                        end
                end
        end

        if changed then
                core.log("action", "[bg_music] Found " .. #new_songs .. " songs (was " .. old_count .. ")")
                bg_music.available_songs = new_songs
        end

        bg_music.last_scan_time = os.time()
end

-- Function to shuffle a table (Fisher-Yates algorithm)
function bg_music.shuffle_table(t)
	local shuffled = {}
	for i, v in ipairs(t) do shuffled[i] = v end

	-- Ensure random seed is properly initialized
	math.randomseed(os.time() + math.random(1000))

	for i = #shuffled, 2, -1 do
		local j = math.random(i)
		shuffled[i], shuffled[j] = shuffled[j], shuffled[i]
	end

	return shuffled
end

-- Function to get next song from playlist with no repeats until all played
function bg_music.get_next_song_from_playlist(player_name, filter)
	local key = player_name .. "_" .. (filter or "all")
	local playlist_key = "playlist_" .. key
	local index_key = "index_" .. key
	
	-- Get filtered songs
	local filtered_songs = bg_music.filter_songs(filter)
	if #filtered_songs == 0 then
		return nil
	end
	
	-- Initialize or reset playlist if empty or all songs played
	if not bg_music.playlists[playlist_key] or 
	   #bg_music.playlists[playlist_key] == 0 or
	   (bg_music.playlists[index_key] or 0) >= #bg_music.playlists[playlist_key] then
		
		bg_music.playlists[playlist_key] = bg_music.shuffle_table(filtered_songs)
		bg_music.playlists[index_key] = 1
	end
	
	-- Get next song
	local index = bg_music.playlists[index_key]
	local song = bg_music.playlists[playlist_key][index]
	bg_music.playlists[index_key] = index + 1
	
	return song
end

-- Function to filter songs with enhanced pattern matching
function bg_music.filter_songs(filter_string)
	if not filter_string or filter_string == "" or filter_string:match("^%s*$") then
		return bg_music.available_songs
	end

	-- Log the filter being applied
	core.log("action", "[bg_music] Applying filter: " .. filter_string)

	local filtered = {}
	
	-- Handle OR conditions by splitting on |
	local or_patterns = {}
	for pattern in filter_string:gmatch("[^|]+") do
		pattern = pattern:gsub("^%s*(.-)%s*$", "%1") -- trim whitespace
		if pattern ~= "" then
			table.insert(or_patterns, pattern)
		end
	end

	if #or_patterns == 0 then
		return bg_music.available_songs
	end

	for _, song in ipairs(bg_music.available_songs) do
		local include = false
		
		-- Check each OR pattern
		for _, pattern in ipairs(or_patterns) do
			local negate = false
			local check_pattern = pattern
			
			-- Check for negation
			if check_pattern:sub(1, 1) == "!" then
				negate = true
				check_pattern = check_pattern:sub(2)
			end
			
			-- Handle anchors and wildcards properly
			local anchored_start = check_pattern:sub(1, 1) == "^"
			local anchored_end = check_pattern:sub(-1) == "$"
			
			-- Remove anchors for processing
			if anchored_start then
				check_pattern = check_pattern:sub(2)
			end
			if anchored_end then
				check_pattern = check_pattern:sub(1, -2)
			end
			
			-- Convert wildcard * to Lua pattern
			check_pattern = check_pattern:gsub("%*", ".*")
			
			-- Add anchors if needed
			if anchored_start and anchored_end then
				check_pattern = "^" .. check_pattern .. "$"
			elseif anchored_start then
				check_pattern = "^" .. check_pattern
			elseif anchored_end then
				check_pattern = check_pattern .. "$"
			else
				-- Implicit wildcards at start and end for non-anchored patterns
				check_pattern = ".*" .. check_pattern .. ".*"
			end
			
			-- Perform case-insensitive match
			local matches = song:lower():match(check_pattern:lower()) ~= nil
			
			if negate then
				if matches then
					-- Song matches a negation, exclude it
					include = false
					break
				end
			else
				if matches then
					include = true
				end
			end
		end
		
		-- Include if it matches any positive filter and no negation
		if include then
			table.insert(filtered, song)
		end
	end

	core.log("action", "[bg_music] Filter '" .. filter_string .. "' matched " .. #filtered .. " songs")
	return filtered
end

-- Function to save music locations
function bg_music.save_locations()
        storage:set_string("music_locations", core.serialize(bg_music.music_locations))
end

-- Function to check if music is disabled for a player
function bg_music.is_music_disabled(player_name)
	local player = core.get_player_by_name(player_name)
	if not player then
		return true -- If player doesn't exist, treat as disabled
	end
	
	-- Check player attribute using MetaDataRef
	local meta = player:get_meta()
	local pref = meta:get_string("bg_music_preference")
	
	-- If no preference is set, use the world default
	if pref == "" then
		local default_enabled = core.settings:get_bool("bg_music.default_enabled", true)
		return not default_enabled
	end
	
	return pref == MUSIC_PREF_DISABLED
end

-- Function to set music preference for a player
function bg_music.set_music_preference(player_name, enabled)
	local player = core.get_player_by_name(player_name)
	if not player then
		return false
	end
	
	local pref = enabled and MUSIC_PREF_ENABLED or MUSIC_PREF_DISABLED
	-- Use MetaDataRef instead of deprecated set_attribute
	local meta = player:get_meta()
	meta:set_string("bg_music_preference", pref)
	
	local status = enabled and "enabled" or "disabled"
	core.log("action", "[bg_music] Music " .. status .. " for player " .. player_name)
	
	-- Send translated message to player
	local S_player = core.get_translator("bg_music")
	if enabled then
		local msg = S_player("Music enabled. You will now hear background music.")
		core.chat_send_player(player_name, msg)
	else
		local msg = S_player("Music disabled. You will no longer hear automatic background music.")
		core.chat_send_player(player_name, msg)
	end
	
	return true
end

-- Function to check if music should play for a player (respects preferences and explicit playback)
function bg_music.can_play_music_for_player(player_name, is_explicit)
	-- If this is explicit playback (player initiated), always allow
	if is_explicit then
		return true
	end
	
	-- Otherwise, check if music is disabled for this player
	return not bg_music.is_music_disabled(player_name)
end

-- Function to set personal volume for a player (not persistent)
function bg_music.set_player_volume(player_name, volume)
	if volume < 0 or volume > 100 then
		return false, safe_translate("Volume must be between 0 and 100")
	end
	
	bg_music.player_volumes[player_name] = volume
	core.log("action", "[bg_music] Set volume to " .. volume .. "% for player " .. player_name)
	return true
end

-- Function to get personal volume for a player
function bg_music.get_player_volume(player_name)
	local volume = bg_music.player_volumes[player_name]
	if not volume then
		return DEFAULT_MUSIC_VOLUME
	end
	return volume
end

-- Function to calculate effective volume (personal volume applied to base volume)
function bg_music.get_effective_volume(player_name, base_volume)
	local personal_volume = bg_music.get_player_volume(player_name)
	return (base_volume or 1.0) * (personal_volume / 100.0)
end

-- Function to calculate distance between positions
function bg_music.get_distance(pos1, pos2)
        local dx = pos1.x - pos2.x
        local dy = pos1.y - pos2.y
        local dz = pos1.z - pos2.z
        return math.sqrt(dx*dx + dy*dy + dz*dz)
end

-- Function to stop all music for a player
function bg_music.stop_player_music(player_name)
	if bg_music.active_music[player_name] and bg_music.active_music[player_name].handle then
		core.sound_stop(bg_music.active_music[player_name].handle)
		bg_music.active_music[player_name] = nil
	end
end

-- Function to check if player is in music zone
function bg_music.check_player_zone(player)
	local player_name = player:get_player_name()
	local player_pos = player:get_pos()

	-- Check if music is disabled for this player (except for explicit playback)
	if not bg_music.can_play_music_for_player(player_name, false) then
		-- Stop any existing zone music for this player
		local current_music = bg_music.active_music[player_name]
		if current_music and current_music.type == "zone" and current_music.handle then
			core.sound_stop(current_music.handle)
			bg_music.active_music[player_name] = nil
		end
		return
	end

	-- Find closest music zone
	local closest_zone = nil
	local closest_distance = math.huge

	for _, zone in ipairs(bg_music.music_locations) do
		local distance = bg_music.get_distance(player_pos, zone.pos)
		if distance <= zone.radius_trigger then
			-- Player is inside trigger zone
			if distance < closest_distance then
				closest_distance = distance
				closest_zone = zone
			end
		end
	end

	-- Check if player has active music
	local current_music = bg_music.active_music[player_name]

	if closest_zone then
		-- Player is in a music zone
		if not current_music or current_music.zone ~= closest_zone then
			-- Stop existing music first
			if current_music and current_music.handle then
				core.sound_stop(current_music.handle)
			end

			-- Start new music with playlist system (no repeats until all played)
			local song_name = bg_music.get_next_song_from_playlist(player_name, closest_zone.filter)
			if song_name then
				-- Apply personal volume to zone volume
				local effective_gain = bg_music.get_effective_volume(player_name, closest_zone.volume / 100)
				
				local handle = core.sound_play(song_name, {
					to_player = player_name,
					gain = effective_gain,
					loop = false, -- Changed to false to allow playlist progression
				})

				bg_music.active_music[player_name] = {
					type = "zone",
					zone = closest_zone,
					song = song_name,
					handle = handle
				}

				core.log("action", "[bg_music] Started playing " .. song_name .. " for " .. player_name .. " (effective volume: " .. math.floor(effective_gain * 100) .. "%)")
			end
		end
	elseif current_music and current_music.type == "zone" then
		-- Check if player exited the extended zone
		local zone = current_music.zone
		local distance = bg_music.get_distance(player_pos, zone.pos)
		if distance > (zone.radius_trigger + zone.extra_radius) then
			-- Stop music
			if current_music.handle then
				core.sound_stop(current_music.handle)
			end
			bg_music.active_music[player_name] = nil
			core.log("action", "[bg_music] Stopped music for " .. player_name)
		end
	end
end

-- Globalstep to check player positions
core.register_globalstep(function(dtime)
        -- Check if we need to rescan songs
        local current_time = os.time()
        if current_time - bg_music.last_scan_time >= SCAN_INTERVAL then
                bg_music.scan_songs()
        end

        -- Check all players
        for _, player in ipairs(core.get_connected_players()) do
                bg_music.check_player_zone(player)
        end
end)

-- Register privilege
core.register_privilege("setmusic", {
        description = "Can set background music locations",
        give_to_singleplayer = false,
})

-- Register commands
core.register_chatcommand("setmusic", {
	params = "<radius_trigger> <extra_radius> [<volume>] [<filter>]",
	description = S("Set background music at current position. radius_trigger: distance where music starts (meters). extra_radius: additional distance where music stops (meters). volume: 5-99 (default 65). filter: optional song filter (supports wildcards, | for OR, ! for NOT)."),
	privs = {setmusic = true},
	func = function(name, param)
		local parts = {}
		for part in param:gmatch("%S+") do
			table.insert(parts, part)
		end

		if #parts < 2 then
			return false, S("Usage: @1 <radius_trigger> <extra_radius> [<volume>] [<filter>]", "/setmusic")
		end

		local radius_trigger = tonumber(parts[1])
		local extra_radius = tonumber(parts[2])
		local volume = DEFAULT_VOLUME
		local filter = ""

		if not radius_trigger or radius_trigger <= 0 then
			return false, S("Radius trigger must be a positive number")
		end

		if not extra_radius or extra_radius < 0 then
			return false, S("Extra radius must be a non-negative number")
		end

		if parts[3] then
			volume = tonumber(parts[3])
			if not volume or volume < MIN_VOLUME or volume > MAX_VOLUME then
				return false, S("Volume must be between @1 and @2", MIN_VOLUME, MAX_VOLUME)
			end
			filter = table.concat(parts, " ", 4)
		else
			filter = table.concat(parts, " ", 3)
		end

		-- Log the filter being set
		core.log("action", "[bg_music] Setting music location with filter: " .. filter)

		local player = core.get_player_by_name(name)
		if not player then
			return false, S("Player not found")
		end

		local pos = player:get_pos()

		-- Create new music location
		local location = {
			pos = {x = math.floor(pos.x + 0.5), y = math.floor(pos.y + 0.5), z = math.floor(pos.z + 0.5)},
			radius_trigger = radius_trigger,
			extra_radius = extra_radius,
			volume = volume,
			filter = filter
		}

		table.insert(bg_music.music_locations, location)
		bg_music.save_locations()

		if filter ~= "" then
			return true, S("Background music location set at @1 with trigger radius @2 and extra radius @3 (filter: @4)", core.pos_to_string(location.pos), radius_trigger, extra_radius, filter)
		else
			return true, S("Background music location set at @1 with trigger radius @2 and extra radius @3", core.pos_to_string(location.pos), radius_trigger, extra_radius)
		end
	end
})

core.register_chatcommand("getmusic", {
        description = S("List all background music locations with coordinates, radius, volume, and filters"),
        func = function(name, param)
		if #bg_music.music_locations == 0 then
			return true, S("No background music locations defined")
		end

		local result = S("Background music locations:") .. "\n"
                for i, location in ipairs(bg_music.music_locations) do
                        result = result .. string.format("%d. Pos: %s, Trigger: %dm, Extra: %dm, Volume: %d%%",
                                i, core.pos_to_string(location.pos), location.radius_trigger, location.extra_radius, location.volume)
                        if location.filter and location.filter ~= "" then
                                result = result .. ", Filter: " .. location.filter
                        end
                        result = result .. "\n"
                end

                return true, result
        end
})

core.register_chatcommand("delmusic", {
        params = "<index>",
        description = S("Remove background music location by index. Use /getmusic to see indices"),
        privs = {setmusic = true},
        func = function(name, param)
                local index = tonumber(param)
		if not index or index < 1 or index > #bg_music.music_locations then
			return false, S("Invalid index. Use @1 to see valid indices", "/getmusic")
		end

                local location = bg_music.music_locations[index]
                local pos_str = core.pos_to_string(location.pos)

                table.remove(bg_music.music_locations, index)
                bg_music.save_locations()

                -- Stop music for all players in this zone
                for player_name, music_data in pairs(bg_music.player_music) do
                        if music_data.zone == location then
                                bg_music.stop_player_music(player_name)
                        end
                end

		return true, S("Removed background music location at @1", pos_str)
        end
})

core.register_chatcommand("listmusic", {
	params = "[<filter>]",
	description = S("List available music files with optional filter (supports wildcards, | for OR, ! for NOT)"),
	func = function(name, param)
		-- Trigger rescan first
		local old_count = #bg_music.available_songs
		bg_music.scan_songs()
		local new_count = #bg_music.available_songs

		local scan_message = ""
		if new_count ~= old_count then
			scan_message = S("(Rescanned: @1 → @2 songs)", old_count, new_count)
		end

		local filter = param and param:match("^%s*(.-)%s*$") or ""
		-- Log the filter being used
		core.log("action", "[bg_music] listmusic command called with filter: " .. filter)
		local filtered_songs = bg_music.filter_songs(filter)

		if #filtered_songs == 0 then
			if filter and filter ~= "" then
				return true, scan_message .. S("No songs match the filter: @1", filter)
			else
				return true, scan_message .. S("No music files found in sounds/ directory")
			end
		end

		local result = scan_message
		if filter and filter ~= "" then
			result = result .. S("Available music files (filter: @1):", filter)
		else
			result = result .. S("Available music files")
		end
		result = result .. ":\n"

		for i, song in ipairs(filtered_songs) do
			result = result .. string.format("%d. %s\n", i, song)
		end

		return true, result
	end
})

core.register_chatcommand("rescanmusic", {
        description = S("Manually trigger a rescan of the music folder"),
        func = function(name, param)
                local old_count = #bg_music.available_songs
                bg_music.scan_songs()
                local new_count = #bg_music.available_songs

		local message = S("Music folder rescanned. Found @1 songs (was @2)", new_count, old_count)
		core.log("action", "[bg_music] " .. message)
		return true, message
        end
})

-- Clean up when player leaves
core.register_on_leaveplayer(function(player)
	local player_name = player:get_player_name()
	if bg_music.active_music[player_name] then
		if bg_music.active_music[player_name].handle then
			core.sound_stop(bg_music.active_music[player_name].handle)
		end
		bg_music.active_music[player_name] = nil
	end
	
	-- Clean up personal volume setting
	bg_music.player_volumes[player_name] = nil
end)

-- Stereo integration - create a simple stereo node
local STEREO_RADIUS = 15

-- Create a simple stereo node with basic textures
core.register_node(":bg_music:stereo", {
        description = S("Music Stereo"),
        tiles = {
                "default_steel_block.png",
                "default_steel_block.png",
                "default_steel_block.png^default_copper_block.png",
                "default_steel_block.png^default_copper_block.png",
                "default_steel_block.png^default_copper_block.png",
                "default_steel_block.png^default_copper_block.png"
        },
        inventory_image = "default_steel_block.png^default_copper_block.png",
        wield_image = "default_steel_block.png^default_copper_block.png",
        paramtype = "light",
        paramtype2 = "facedir",
        groups = {cracky = 2, oddly_breakable_by_hand = 2},

        on_rightclick = function(pos, node, clicker, itemstack, pointed_thing)
                if not clicker or not clicker:is_player() then
                        return itemstack
                end

                local player_name = clicker:get_player_name()

                -- Check if music is disabled for this player (except for explicit playback)
		if not bg_music.can_play_music_for_player(player_name, true) then
			core.chat_send_player(player_name, S("Music is disabled for you. Use @1 to enable it.", "/enablemusic"))
			return itemstack
		end

                -- Check if player has active music
                if bg_music.active_music[player_name] then
                        -- Stop the music
                        if bg_music.active_music[player_name].handle then
                                core.sound_stop(bg_music.active_music[player_name].handle)
                        end
                        bg_music.active_music[player_name] = nil
		core.chat_send_player(player_name, S("Stereo music stopped"))
                        return itemstack
                end

                -- Check if there are any songs available
		if #bg_music.available_songs == 0 then
			core.chat_send_player(player_name, S("No music files found in sounds/ directory"))
			return itemstack
		end

                -- Pick next song from playlist (no repeats until all played)
                local song_name = bg_music.get_next_song_from_playlist(player_name, nil)

                -- Stop any existing music for this player
                if bg_music.active_music[player_name] then
                        if bg_music.active_music[player_name].handle then
                                core.sound_stop(bg_music.active_music[player_name].handle)
                        end
                        bg_music.active_music[player_name] = nil
                end

                -- Apply personal volume to stereo (default 70%)
                local effective_gain = bg_music.get_effective_volume(player_name, 0.7)

                -- Play music to this player within 15m radius
                local handle = core.sound_play(song_name, {
                        pos = pos,
                        gain = effective_gain,
                        hear_distance = STEREO_RADIUS,
                        loop = false,
                })

                if handle then
                        bg_music.active_music[player_name] = {
                                handle = handle,
                                type = "stereo",
                                song = song_name,
                                pos = pos
                        }

		core.chat_send_player(player_name, S("Playing: @1", song_name))
                        core.log("action", "[bg_music] Stereo at " .. core.pos_to_string(pos) .. " playing " .. song_name .. " for " .. player_name .. " (effective volume: " .. math.floor(effective_gain * 100) .. "%)")
                end

                return itemstack
        end
})

-- Add crafting recipe for our stereo
core.register_craft({
	output = "bg_music:stereo",
	recipe = {
		{"default:steel_ingot", "default:steel_ingot", "default:steel_ingot"},
		{"default:copper_ingot", "default:mese_crystal", "default:copper_ingot"},
		{"default:wood", "default:wood", "default:wood"}
	}
})

-- Global music commands
core.register_chatcommand("playmusic", {
	params = "[<number_or_name>] [all]",
	description = S("Play a song by number (from /listmusic) or name. Use 'all' to play globally"),
	func = function(name, param)
		local parts = {}
		for part in param:gmatch("%S+") do
			table.insert(parts, part)
		end
		
		local song_input = parts[1]
		local play_global = parts[2] == "all"
		
		-- If playing globally, check if any players have disabled music
		if play_global then
			local affected_players = 0
			for _, player in ipairs(core.get_connected_players()) do
				local player_name = player:get_player_name()
				-- Only count players who haven't disabled music
				if bg_music.can_play_music_for_player(player_name, false) then
					affected_players = affected_players + 1
				end
			end
			
			if affected_players == 0 then
				return false, S("No players available to hear the music (all have disabled music)")
			end
		else
			-- For individual playback, check if the requesting player has disabled music
			-- But since this is explicit playback, we allow it even if music is disabled
			if not bg_music.can_play_music_for_player(name, true) then
				return false, S("You have disabled music. Use @1 first.", "/enablemusic")
			end
		end
		
		-- Stop ALL existing music first
		local stopped = 0
		for player_name, music_data in pairs(bg_music.active_music) do
			-- For global playback, only stop music for players who haven't disabled music
			-- For individual playback, only stop the requester's music
			local should_stop = false
			if play_global then
				should_stop = bg_music.can_play_music_for_player(player_name, false)
			else
				should_stop = (player_name == name)
			end
			
			if should_stop and music_data.handle then
				core.sound_stop(music_data.handle)
				stopped = stopped + 1
			end
		end
		
		-- Clear active music entries appropriately
		if play_global then
			-- Only clear entries for players who haven't disabled music
			local new_active_music = {}
			for player_name, music_data in pairs(bg_music.active_music) do
				if not bg_music.can_play_music_for_player(player_name, false) then
					new_active_music[player_name] = music_data
				end
			end
			bg_music.active_music = new_active_music
		else
			-- Clear only the requester's entry
			bg_music.active_music[name] = nil
		end
		
		-- If no song specified, play random music (equivalent to /playmusic *)
		if not song_input or song_input == "" then
			if stopped > 0 then
				-- If we stopped music, play a new random song
				song_input = "*"
			else
				-- No music was playing, just play random
				song_input = "*"
			end
		end
		
		-- Determine song to play
		local song_name = nil
		
		-- Check if input is a number
		local song_number = tonumber(song_input)
		if song_number then
			-- Use song by number
			if song_number >= 1 and song_number <= #bg_music.available_songs then
				song_name = bg_music.available_songs[song_number]
			else
				return false, S("Invalid song number. Use 1-@1", #bg_music.available_songs)
			end
		elseif song_input == "*" then
			-- Wildcard - use playlist system for random selection
			song_name = bg_music.get_next_song_from_playlist(name, nil)
			if not song_name then
				return false, S("No music available")
			end
		else
			-- Check if input is a song name (case-insensitive)
			for _, available in ipairs(bg_music.available_songs) do
				if available:lower() == song_input:lower() then
					song_name = available
					break
				end
			end
			if not song_name then
				return false, S("Song not found: @1. Use @2 to see available songs", song_input, "/listmusic")
			end
		end
		
		-- Play music
		local player = core.get_player_by_name(name)
			if not player and not play_global then
				return false, S("Player not found")
			end
		
		local handle
		if play_global then
			handle = core.sound_play(song_name, {
				gain = 0.7,
				loop = false,
			})
		else
			-- Apply personal volume to individual playback (default 70%)
			local effective_gain = bg_music.get_effective_volume(name, 0.7)
			handle = core.sound_play(song_name, {
				to_player = name,
				gain = effective_gain,
				loop = false,
			})
		end
		
		if handle then
			bg_music.active_music[name] = {
				handle = handle,
				type = "global",
				song = song_name,
				is_global = play_global
			}
			return true, S("Playing: @1", song_name)
		else
			return false, S("Failed to play music")
		end
	end
})

core.register_chatcommand("stopmusic", {
	description = S("Stop all background music currently playing"),
	func = function(name, param)
		local stopped = 0
		
		-- Count and stop ALL music regardless of source
		for player_name, music_data in pairs(bg_music.active_music) do
			if music_data.handle then
				core.sound_stop(music_data.handle)
				stopped = stopped + 1
			end
		end
		bg_music.active_music = {}
		
		if stopped > 0 then
			core.log("action", "[bg_music] Stopped " .. stopped .. " music instances by " .. name)
			return true, S("Stopped @1 music instances", stopped)
		else
			return true, S("No music currently playing")
		end
	end
})

-- Music preference commands
core.register_chatcommand("disablemusic", {
	description = S("Disable all background music for yourself"),
	func = function(name, param)
		if bg_music.set_music_preference(name, false) then
			-- Stop any currently playing music for this player
			local current_music = bg_music.active_music[name]
			if current_music and current_music.handle then
				core.sound_stop(current_music.handle)
				bg_music.active_music[name] = nil
			end
			
			-- Message is now sent in set_music_preference function
			return true, safe_translate("Music disabled. You will no longer hear automatic background music.")
		else
			return false, safe_translate("Failed to disable music.")
		end
	end
})

core.register_chatcommand("enablemusic", {
	description = S("Enable background music for yourself"),
	func = function(name, param)
		if bg_music.set_music_preference(name, true) then
			-- Message is now sent in set_music_preference function
			return true, safe_translate("Music enabled. You will now hear background music.")
		else
			return false, safe_translate("Failed to enable music.")
		end
	end
})

core.register_chatcommand("testlang", {
	description = "Test language detection and translation",
	func = function(name, param)
		local player = core.get_player_by_name(name)
		if not player then
			return false, "Player not found"
		end
		
		local S_player = core.get_translator("bg_music")
		local player_lang = player:get_meta():get_string("language")
		local system_lang = core.settings:get("language") or "not_set"
		local client_info = core.get_player_information(name)
		local client_lang = client_info and client_info.lang_code or "not_available"
		
		-- Test different strings
		local test1 = S_player("Music is enabled for you. Use @1 to disable it.", "/disablemusic")
		local test2 = S_player("Music disabled. You will no longer hear automatic background music.")
		local test3 = S_player("Available music files")
		local test4 = S_player("Set your personal music volume (0-100%)")
		
		local result = "Language test results:\n"
		result = result .. "System language: " .. system_lang .. "\n"
		result = result .. "Player meta language: '" .. player_lang .. "'\n"
		result = result .. "Client language code: '" .. client_lang .. "'\n"
		result = result .. "Test 1 (parametrized): " .. test1 .. "\n"
		result = result .. "Test 2 (simple): " .. test2 .. "\n"
		result = result .. "Test 3 (menu): " .. test3 .. "\n"
		result = result .. "Test 4 (command): " .. test4 .. "\n"
		result = result .. "\nInterpretation:\n"
		if test1:find("�%(T") or test2:find("�%(T") then
			result = result .. "❌ TRANSLATION FILES NOT LOADED - Client showing raw translation codes\n"
		else
			result = result .. "✅ TRANSLATION SYSTEM WORKING - Text should be translated\n"
		end
		result = result .. "If you see English text above, check client language settings\n"
		
		return true, result
	end
})

-- Initialize on mod load
core.register_on_mods_loaded(function()
	-- Initialize random seed
	math.randomseed(os.time() + math.random(1000))

	bg_music.scan_songs()
	core.log("action", "[bg_music] Mod loaded with " .. #bg_music.available_songs .. " songs available")
	
	-- Test translation with language detection
	local system_lang = core.settings:get("language") or "not_set"
	local test_translator = core.get_translator("bg_music")
	local test_result = test_translator("Music is enabled for you. Use @1 to disable it.", "/disablemusic")
	core.log("action", "[bg_music] System language: " .. system_lang)
	core.log("action", "[bg_music] Translation test: " .. test_result)
	
	-- Test direct translation without parameters
	local simple_test = test_translator("Music enabled. You will now hear background music.")
	core.log("action", "[bg_music] Simple translation test: " .. simple_test)
	
	-- Test if translation files are being loaded by checking a known string
	local test_known_string = test_translator("Available music files")
	core.log("action", "[bg_music] Known string test: " .. test_known_string)
	
	-- Log available translation files
	core.log("action", "[bg_music] Translation files check:")
	local locale_files = core.get_dir_list(core.get_modpath("bg_music") .. "/locale/po", false) or {}
	for _, lang in ipairs({"fr", "de", "es", "it", "pt_BR"}) do
		local found = false
		for _, file in ipairs(locale_files) do
			if file == lang .. ".po" then
				found = true
				break
			end
		end
		core.log("action", "[bg_music]   " .. lang .. ".po: " .. (found and "FOUND" or "NOT FOUND"))
	end
	
	-- Test translation with different approaches
	core.log("action", "[bg_music] Translation method tests:")
	
	-- Method 1: Direct S() call
	local method1 = S("Available music files")
	core.log("action", "[bg_music]   Method 1 (S()): " .. method1)
	
	-- Method 2: get_translator in function
	local S_func = core.get_translator("bg_music")
	local method2 = S_func("Available music files")
	core.log("action", "[bg_music]   Method 2 (get_translator in function): " .. method2)
	
	-- Method 3: Test with parameter
	local method3 = S_func("Volume set to @1%", 75)
	core.log("action", "[bg_music]   Method 3 (with parameter): " .. method3)
end)

-- Notify players of their music preference on join
core.register_on_joinplayer(function(player)
	local player_name = player:get_player_name()
	local is_disabled = bg_music.is_music_disabled(player_name)
	
	-- Debug: log player language info
	local player_lang = player:get_meta():get_string("language")
	local system_lang = core.settings:get("language") or "not_set"
	local client_lang = player:get_meta():get_string("client_language") or "not_set"
	
	-- Also try other possible language detection methods
	local env_lang = os.getenv("LANG") or os.getenv("LANGUAGE") or "not_set"
	local locale_lang = os.setlocale(nil, "ctype") or "not_set"
	
	core.log("action", "[bg_music] Player " .. player_name .. " joined:")
	core.log("action", "[bg_music]   Player meta language: '" .. player_lang .. "'")
	core.log("action", "[bg_music]   System language: '" .. system_lang .. "'")
	core.log("action", "[bg_music]   Client language: '" .. client_lang .. "'")
	core.log("action", "[bg_music]   Environment LANG: '" .. env_lang .. "'")
	core.log("action", "[bg_music]   Locale: '" .. locale_lang .. "'")
	
	-- Test if we can detect client language through other means
	local client_info = core.get_player_information(player_name)
	if client_info then
		core.log("action", "[bg_music]   Client info available: yes")
		core.log("action", "[bg_music]   Client version: " .. (client_info.version_string or "unknown"))
		core.log("action", "[bg_music]   Client lang code: " .. (client_info.lang_code or "unknown"))
	else
		core.log("action", "[bg_music]   Client info available: no")
	end
	
	-- Test different translation approaches for multiple languages
	core.log("action", "[bg_music] Testing translations for system language: " .. system_lang)
	
	-- Test 1: French
	if system_lang == "fr" then
		core.log("action", "[bg_music] Testing French translations:")
		local test1 = S("Music is enabled for you. Use @1 to disable it.", "/disablemusic")
		core.log("action", "[bg_music]   FR test: " .. test1)
		
	-- Test 2: German  
	elseif system_lang == "de" then
		core.log("action", "[bg_music] Testing German translations:")
		local test1 = S("Music is enabled for you. Use @1 to disable it.", "/disablemusic")
		core.log("action", "[bg_music]   DE test: " .. test1)
		local test2 = S("Available music files")
		core.log("action", "[bg_music]   DE simple test: " .. test2)
		local test3 = S("Music disabled. You will no longer hear automatic background music.")
		core.log("action", "[bg_music]   DE disabled test: " .. test3)
		
	-- Test 3: Italian
	elseif system_lang == "it" then
		core.log("action", "[bg_music] Testing Italian translations:")
		local test1 = S("Music is enabled for you. Use @1 to disable it.", "/disablemusic")
		core.log("action", "[bg_music]   IT test: " .. test1)
		
	-- Test 4: Spanish
	elseif system_lang == "es" then
		core.log("action", "[bg_music] Testing Spanish translations:")
		local test1 = S("Music is enabled for you. Use @1 to disable it.", "/disablemusic")
		core.log("action", "[bg_music]   ES test: " .. test1)
		
	-- Test 5: Portuguese
	elseif system_lang == "pt_BR" then
		core.log("action", "[bg_music] Testing Portuguese translations:")
		local test1 = S("Music is enabled for you. Use @1 to disable it.", "/disablemusic")
		core.log("action", "[bg_music]   PT_BR test: " .. test1)
	end
	core.log("action", "[bg_music]   Available songs: " .. #bg_music.available_songs)
	
	-- Use direct translation with fallback
	local S_player = core.get_translator("bg_music")
	if is_disabled then
		local msg = debug_translate("Music is currently disabled for you. Use @1 to enable it.", "/enablemusic")
		core.chat_send_player(player_name, msg)
	else
		local msg = debug_translate("Music is enabled for you. Use @1 to disable it.", "/disablemusic")
		core.chat_send_player(player_name, msg)
	end
end)
