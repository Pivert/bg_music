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
bg_music.stereo_music = {}
bg_music.zone_playlists = {} -- Fixed playlists per zone
bg_music.stereo_playlist = {} -- Fixed playlist for stereo
bg_music.current_global_music = nil -- Track global music state
bg_music.music_index = {} -- Track last played songs
bg_music.last_sound_check = 0 -- For sound completion detection
bg_music.stereo_timer = 0 -- Timer for stereo music completion

-- Configuration
local SCAN_INTERVAL = 600 -- 10 minutes in seconds
local DEFAULT_VOLUME = 65
local MIN_VOLUME = 5
local MAX_VOLUME = 99

-- Load music locations from storage
local storage = minetest.get_mod_storage()
local saved_locations = storage:get_string("music_locations")
if saved_locations and saved_locations ~= "" then
	bg_music.music_locations = minetest.deserialize(saved_locations) or {}
end

-- Function to scan for available songs
function bg_music.scan_songs()
	local sounds_path = minetest.get_modpath("bg_music") .. "/sounds"
	local old_count = #bg_music.available_songs
	local new_songs = {}
	
	-- Check if sounds directory exists
	local dir_list = minetest.get_dir_list(sounds_path, false)
	if not dir_list then
		minetest.log("action", "[bg_music] Sounds directory not found, creating it")
		minetest.mkdir(sounds_path)
		bg_music.available_songs = {}
		bg_music.regenerate_playlists()
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
			minetest.log("action", "[bg_music] Found " .. #new_songs .. " songs (was " .. old_count .. ")")
			bg_music.available_songs = new_songs
			
			-- Regenerate playlists when songs change
			bg_music.regenerate_playlists()
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

-- Function to filter songs by regex (Lua patterns)
function bg_music.filter_songs(regex)
	if not regex or regex == "" or regex:match("^%s*$") then
		return bg_music.available_songs
	end
	
	local filtered = {}
	local pattern = regex
	
	-- Try to compile the pattern
	local success, result = pcall(function()
		return string.match("test", pattern)
	end)
	
	if not success then
		minetest.log("warning", "[bg_music] Invalid pattern: " .. regex)
		return bg_music.available_songs
	end
	
	for _, song in ipairs(bg_music.available_songs) do
		if string.match(song, pattern) then
			table.insert(filtered, song)
		end
	end
	
	return filtered
end

-- Function to save music locations
function bg_music.save_locations()
	storage:set_string("music_locations", minetest.serialize(bg_music.music_locations))
end

-- Function to regenerate all playlists
function bg_music.regenerate_playlists()
	-- Clear existing playlists
	bg_music.zone_playlists = {}
	bg_music.stereo_playlist = {}
	
	-- Generate zone playlists
	for _, zone in ipairs(bg_music.music_locations) do
		local filtered_songs = bg_music.filter_songs(zone.filter)
		if #filtered_songs > 0 then
			bg_music.zone_playlists[minetest.pos_to_string(zone.pos)] = bg_music.shuffle_table(filtered_songs)
		end
	end
	
	-- Generate stereo playlist
	if #bg_music.available_songs > 0 then
		bg_music.stereo_playlist = bg_music.shuffle_table(bg_music.available_songs)
	end
	
	-- Reset music indices
	bg_music.music_index = {}
end

-- Function to get next song from playlist (never repeats last)
function bg_music.get_next_song(playlist_key, playlist)
	if not playlist or #playlist == 0 then return nil end
	
	local last_index = bg_music.music_index[playlist_key] or 0
	local next_index = last_index + 1
	
	if next_index > #playlist then
		next_index = 1
	end
	
	bg_music.music_index[playlist_key] = next_index
	return playlist[next_index]
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
	if bg_music.player_music[player_name] and bg_music.player_music[player_name].handle then
		minetest.sound_stop(bg_music.player_music[player_name].handle)
		bg_music.player_music[player_name] = nil
	end
end

-- Function to stop all music globally
function bg_music.stop_all_music()
	local stopped_count = 0
	
	-- Stop zone music for all players
	for player_name, music_data in pairs(bg_music.player_music) do
		if music_data.handle then
			minetest.sound_stop(music_data.handle)
			stopped_count = stopped_count + 1
		end
	end
	bg_music.player_music = {}
	
	-- Stop stereo music for all players
	for player_name, stereo_data in pairs(bg_music.stereo_music) do
		if stereo_data.handle then
			minetest.sound_stop(stereo_data.handle)
			stopped_count = stopped_count + 1
		end
	end
	bg_music.stereo_music = {}
	
	-- Stop global music
	if bg_music.current_global_music and bg_music.current_global_music.handle then
		minetest.log("action", "[bg_music] DEBUG: Stopping global music with handle: " .. tostring(bg_music.current_global_music.handle))
		minetest.sound_stop(bg_music.current_global_music.handle)
		bg_music.current_global_music = nil
		stopped_count = stopped_count + 1
	else
		minetest.log("action", "[bg_music] DEBUG: No global music to stop")
	end
	
	return stopped_count
end

-- Function to check if player is in music zone
function bg_music.check_player_zone(player)
	local player_name = player:get_player_name()
	local player_pos = player:get_pos()
	
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
	
	-- Check if player was already in a zone
	local current_music = bg_music.player_music[player_name]
	
	if closest_zone then
		-- Player is in a music zone
		if not current_music or current_music.zone ~= closest_zone then
			-- Get playlist for this zone
			local zone_key = minetest.pos_to_string(closest_zone.pos)
			local playlist = bg_music.zone_playlists[zone_key]
			
			if playlist and #playlist > 0 then
				local song_name = bg_music.get_next_song(zone_key, playlist)
				if song_name then
					local handle = minetest.sound_play(song_name, {
						to_player = player_name,
						gain = closest_zone.volume / 100,
						loop = true,
					})
					
					bg_music.player_music[player_name] = {
						zone = closest_zone,
						song = song_name,
						handle = handle
					}
					
					minetest.log("action", "[bg_music] Started playing " .. song_name .. " for " .. player_name)
				end
			end
		end
	elseif current_music then
		-- Check if player exited the extended zone
		local zone = current_music.zone
		local distance = bg_music.get_distance(player_pos, zone.pos)
		if distance > (zone.radius_trigger + zone.extra_radius) then
			-- Stop music
			if current_music.handle then
				minetest.sound_stop(current_music.handle)
			end
			bg_music.player_music[player_name] = nil
			minetest.log("action", "[bg_music] Stopped music for " .. player_name)
		end
	end
end

-- Globalstep to check player positions and sound completion
minetest.register_globalstep(function(dtime)
	-- Check if we need to rescan songs
	local current_time = os.time()
	if current_time - bg_music.last_scan_time >= SCAN_INTERVAL then
		bg_music.scan_songs()
	end
	
	-- Check all players
	for _, player in ipairs(minetest.get_connected_players()) do
		bg_music.check_player_zone(player)
	end
	
	-- Check for global music completion (simple approach)
	if bg_music.current_global_music and bg_music.current_global_music.handle then
		-- Use pcall to check if sound is still valid
		local success = pcall(function()
			return minetest.sound_fade(bg_music.current_global_music.handle, 0, 0)
		end)
		if not success then
			-- Sound has finished, reset state
			bg_music.current_global_music = nil
			minetest.log("action", "[bg_music] Global music finished")
		end
	end
end)

-- Register privilege
minetest.register_privilege("setmusic", {
	description = "Can set background music locations",
	give_to_singleplayer = false,
})

-- Register commands
minetest.register_chatcommand("setmusic", {
	params = "<radius_trigger> <extra_radius> [<volume>] [<regex>]",
	description = "Set background music at current position. "..
		"radius_trigger: distance where music starts (meters). "..
		"extra_radius: additional distance where music stops (meters). "..
		"volume: 5-99 (default 65). "..
		"regex: optional song filename filter.",
	privs = {setmusic = true},
	func = function(name, param)
		local parts = {}
		for part in param:gmatch("%S+") do
			table.insert(parts, part)
		end
		
		if #parts < 2 then
			return false, "Usage: /setmusic <radius_trigger> <extra_radius> [<volume>] [<regex>]"
		end
		
		local radius_trigger = tonumber(parts[1])
		local extra_radius = tonumber(parts[2])
		local volume = DEFAULT_VOLUME
		local filter = ""
		
		if not radius_trigger or radius_trigger <= 0 then
			return false, "Radius trigger must be a positive number"
		end
		
		if not extra_radius or extra_radius < 0 then
			return false, "Extra radius must be a non-negative number"
		end
		
		if parts[3] then
			volume = tonumber(parts[3])
			if not volume or volume < MIN_VOLUME or volume > MAX_VOLUME then
				return false, "Volume must be between " .. MIN_VOLUME .. " and " .. MAX_VOLUME
			end
			filter = table.concat(parts, " ", 4)
		else
			filter = table.concat(parts, " ", 3)
		end
		
		local player = minetest.get_player_by_name(name)
		if not player then
			return false, "Player not found"
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
		
		return true, "Background music location set at " .. minetest.pos_to_string(location.pos) .. 
			" with trigger radius " .. radius_trigger .. " and extra radius " .. extra_radius
	end
})

minetest.register_chatcommand("getmusic", {
	description = "List all background music locations with coordinates, radius, volume, and filters",
	func = function(name, param)
		if #bg_music.music_locations == 0 then
			return true, "No background music locations defined"
		end
		
		local result = "Background music locations:\n"
		for i, location in ipairs(bg_music.music_locations) do
			result = result .. string.format("%d. Pos: %s, Trigger: %dm, Extra: %dm, Volume: %d%%",
				i, minetest.pos_to_string(location.pos), location.radius_trigger, location.extra_radius, location.volume)
			if location.filter and location.filter ~= "" then
				result = result .. ", Filter: " .. location.filter
			end
			result = result .. "\n"
		end
		
		return true, result
	end
})

minetest.register_chatcommand("delmusic", {
	params = "<index>",
	description = "Remove background music location by index. Use /getmusic to see indices",
	privs = {setmusic = true},
	func = function(name, param)
		local index = tonumber(param)
		if not index or index < 1 or index > #bg_music.music_locations then
			return false, "Invalid index. Use /getmusic to see valid indices"
		end
		
		local location = bg_music.music_locations[index]
		local pos_str = minetest.pos_to_string(location.pos)
		
		table.remove(bg_music.music_locations, index)
		bg_music.save_locations()
		
		-- Stop music for all players in this zone
		for player_name, music_data in pairs(bg_music.player_music) do
			if music_data.zone == location then
				bg_music.stop_player_music(player_name)
			end
		end
		
		return true, "Removed background music location at " .. pos_str
	end
})

minetest.register_chatcommand("listmusic", {
	params = "[<regex>]",
	description = "List available music files with optional regex filter (triggers rescan)",
	func = function(name, param)
		-- Trigger rescan first
		local old_count = #bg_music.available_songs
		bg_music.scan_songs()
		local new_count = #bg_music.available_songs
		
		local scan_message = ""
		if new_count ~= old_count then
			scan_message = string.format("(Rescanned: %d → %d songs) ", old_count, new_count)
		end
		
		local regex = param and param:match("^%s*(.-)%s*$") or ""
		local filtered_songs = bg_music.filter_songs(regex)
		
		if #filtered_songs == 0 then
			if regex and regex ~= "" then
				return true, scan_message .. "No songs match the pattern: " .. regex
			else
				return true, scan_message .. "No music files found in sounds/ directory"
			end
		end
		
		local result = scan_message .. "Available music files"
		if regex and regex ~= "" then
			result = result .. " (matching: " .. regex .. ")"
		end
		result = result .. ":\n"
		
		for i, song in ipairs(filtered_songs) do
			result = result .. string.format("%d. %s\n", i, song)
		end
		
		return true, result
	end
})

minetest.register_chatcommand("rescanmusic", {
	description = "Manually trigger a rescan of the music folder",
	func = function(name, param)
		local old_count = #bg_music.available_songs
		bg_music.scan_songs()
		local new_count = #bg_music.available_songs
		
		local message = string.format("Music folder rescanned. Found %d songs (was %d)", new_count, old_count)
		minetest.log("action", "[bg_music] " .. message)
		return true, message
	end
})

minetest.register_chatcommand("stopmusic", {
	description = "Stop all background music currently playing",
	func = function(name, param)
		minetest.log("action", "[bg_music] DEBUG: stopmusic command called by " .. name)
		minetest.log("action", "[bg_music] DEBUG: current_global_music = " .. dump(bg_music.current_global_music))
		local stopped_count = bg_music.stop_all_music()
		
		if stopped_count > 0 then
			minetest.log("action", "[bg_music] Stopped " .. stopped_count .. " music instances by " .. name)
			return true, "Stopped " .. stopped_count .. " music instances"
		else
			return true, "No music currently playing"
		end
	end
})

minetest.register_chatcommand("playmusic", {
	params = "[music_id] [all]",
	description = "Play specific music by ID or random music. Use 'all' to play for all players",
	privs = {setmusic = true},
	func = function(name, param)
		local parts = {}
		for part in param:gmatch("%S+") do
			table.insert(parts, part)
		end
		
		local music_id = tonumber(parts[1])
		local play_for_all = parts[2] == "all"
		
		-- Stop any existing global music
		local stopped = bg_music.stop_all_music()
		
		-- Determine song to play
		local song_name
		if music_id then
			if music_id < 1 or music_id > #bg_music.available_songs then
				return false, "Invalid music ID. Use /listmusic to see valid IDs"
			end
			song_name = bg_music.available_songs[music_id]
		else
			-- Play random song
			if #bg_music.available_songs == 0 then
				return false, "No music files available"
			end
			song_name = bg_music.available_songs[math.random(1, #bg_music.available_songs)]
		end
		
		-- Play music
		local player = minetest.get_player_by_name(name)
		if not player then
			return false, "Player not found"
		end
		
		local pos = player:get_pos()
		local handle
		
		if play_for_all then
			-- Play for all players
			handle = minetest.sound_play(song_name, {
				pos = pos,
				gain = 0.7,
				hear_distance = 50,
				loop = false,
			})
		else
			-- Play for single player
			handle = minetest.sound_play(song_name, {
				to_player = name,
				gain = 0.7,
				loop = false,
			})
		end
		
		if handle then
			bg_music.current_global_music = {
				handle = handle,
				type = "playmusic",
				song = song_name,
				pos = pos
			}
			
			local target = play_for_all and "all players" or "you"
			local log_message = "[bg_music] " .. name .. " started playing " .. song_name .. " for " .. target
			minetest.log("action", log_message)
			return true, "Playing " .. song_name .. " for " .. target
		else
			return false, "Failed to play music"
		end
	end
})

-- Clean up when player leaves
minetest.register_on_leaveplayer(function(player)
	local player_name = player:get_player_name()
	bg_music.stop_player_music(player_name)
	bg_music.stereo_music[player_name] = nil
end)

-- Stereo integration - create a simple stereo node
local STEREO_RADIUS = 15

-- Create a simple stereo node with basic textures
minetest.register_node(":bg_music:stereo", {
	description = "Music Stereo",
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
		
		-- Check if stereo is already playing globally
		if bg_music.current_global_music and bg_music.current_global_music.type == "stereo" then
			-- Stop the music
			minetest.chat_send_player(player_name, "DEBUG: Stopping stereo music...")
			if bg_music.current_global_music.handle then
				minetest.sound_stop(bg_music.current_global_music.handle)
				minetest.chat_send_player(player_name, "DEBUG: Sound stopped with handle: " .. tostring(bg_music.current_global_music.handle))
			else
				minetest.chat_send_player(player_name, "DEBUG: No handle found!")
			end
			bg_music.current_global_music = nil
			minetest.chat_send_player(player_name, "Stereo music stopped")
			return itemstack
		end
		
		-- Check if there are any songs available
		if #bg_music.available_songs == 0 then
			minetest.chat_send_player(player_name, "No music files found in sounds/ directory")
			return itemstack
		end
		
		-- Get next song from stereo playlist
		local song_name = bg_music.get_next_song("stereo", bg_music.stereo_playlist)
		if not song_name then
			minetest.chat_send_player(player_name, "No music available")
			return itemstack
		end
		
		-- Stop any existing global music
		bg_music.stop_all_music()
		
		-- Play music to all players within 15m radius
		local handle = minetest.sound_play(song_name, {
			pos = pos,
			gain = 0.7, -- Default volume for stereo
			hear_distance = STEREO_RADIUS,
			loop = false,
		})
		
		if handle then
			bg_music.current_global_music = {
				handle = handle,
				type = "stereo",
				song = song_name,
				pos = pos
			}
			
			minetest.chat_send_player(player_name, "Playing: " .. song_name)
			minetest.log("action", "[bg_music] STEREO: " .. song_name .. " at " .. minetest.pos_to_string(pos))
		end
	end,
})

-- Add crafting recipe for our stereo
minetest.register_craft({
	output = "bg_music:stereo",
	recipe = {
		{"default:steel_ingot", "default:steel_ingot", "default:steel_ingot"},
		{"default:copper_ingot", "default:mese_crystal", "default:copper_ingot"},
		{"default:wood", "default:wood", "default:wood"}
	}
})

-- Initialize on mod load
minetest.register_on_mods_loaded(function()
	-- Initialize random seed
	math.randomseed(os.time() + math.random(1000))
	
	bg_music.scan_songs()
	bg_music.regenerate_playlists()
	minetest.log("action", "[bg_music] Mod loaded with " .. #bg_music.available_songs .. " songs available")
end)