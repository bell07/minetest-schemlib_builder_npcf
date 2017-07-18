--local dprint = print
local dprint = function() return end
local modpath = minetest.get_modpath(minetest.get_current_modname())
local filepath = modpath.."/buildings/"

local BUILD_DISTANCE = 3

schemlib_builder_npcf = {
	max_pause_duration = 10,  -- pause between jobs in processing steps (second
	architect_rarity = 2,    -- create own random building plan if nothing found
	walk_around_rarity = 3,  -- Rarity for direction change in walk around without job
	walk_around_duration = 10, -- Rarity for direction change in walk around without job
	plan_max_distance = 100,  -- Maximal distance to the next plan
	check_anchor_rarity = 10, -- Rarity of check for anchor call --10
	--buildings = {}          -- list with buildings {name=, filename=}
}

local func = {} -- different functions
local building_checktable = {}

local tmp_next_plan
--------------------------------------
-- Plan manager singleton
--------------------------------------
local plan_manager = {
	plan_list = {}
}
schemlib_builder_npcf.plan_manager = plan_manager

--------------------------------------
-- Restore active WIP plan's
--------------------------------------
function plan_manager:restore()
	self.stored_list = schemlib.save_restore.restore_data("/schemlib_builder_npcf.store")
	for plan_id, entry in pairs(self.stored_list) do
		local filename = building_checktable[entry.filename]
		if filename then
			func.get_plan_from_file(entry.filename, modpath.."/buildings/"..entry.filename, plan_id, entry.anchor_pos)
		end
	end
end

--------------------------------------
-- Save active WIP plan's
--------------------------------------
function plan_manager:save()
	self.stored_list = {}
	for plan_id, plan in pairs(self.plan_list) do
		if plan.schemlib_builder_npcf_building_filename then
			local entry = {
				anchor_pos = plan.anchor_pos,
				filename   = plan.schemlib_builder_npcf_building_filename
			}
			self.stored_list[plan_id] = entry
		end
	end
	schemlib.save_restore.save_data("/schemlib_builder_npcf.store", self.stored_list)
end

--------------------------------------
-- Get known plan
--------------------------------------
function plan_manager:get(plan_id)
	local plan = self.plan_list[plan_id]
	if plan and plan:get_status() == "finished" then
		dprint(self.npc_id, "plan finished, remove from npc plan manager")
		self:set_finished(plan)
		return nil
	else
		return plan
	end
end

--------------------------------------
-- Set the plan finished
--------------------------------------
function plan_manager:set_finished(plan)
	self.plan_list[plan.plan_id] = nil
	plan_manager:save()
end

--------------------------------------
-- Add new plan to the list
--------------------------------------
function plan_manager:add(plan)
	self.plan_list[plan.plan_id] = plan
end

--------------------------------------
-- set anchor and rename to get active
--------------------------------------
function plan_manager:activate_by_anchor(anchor_pos)
	local plan = tmp_next_plan
	tmp_next_plan = nil
	local new_plan_id = minetest.pos_to_string(anchor_pos)
	plan.plan_id = new_plan_id
	plan.anchor_pos = anchor_pos
	plan:set_status("build")
	self.plan_list[new_plan_id] = plan
	self:save()
	return plan
end

--------------------------------------
-- Functions
--------------------------------------
-- Get buildings list
--------------------------------------
function func.get_buildings_list()
	local list = {}
	local building_files = minetest.get_dir_list(modpath.."/buildings/", false)
	for _, file in ipairs(building_files) do
		table.insert(list, {name=file, filename=modpath.."/buildings/"..file})
		building_checktable[file] = true
	end
	return list
end

--------------------------------------
-- Load plan from file and configure them
--------------------------------------
function func.get_plan_from_file(name, filename, plan_id, anchor_pos)
	plan_id = plan_id or name
	local plan = schemlib.plan.new(plan_id, anchor_pos)
	plan.schemlib_builder_npcf_building_filename = name
	plan:read_from_schem_file(filename)
	plan:apply_flood_with_air()
	if anchor_pos then
		plan:set_status("build")
		plan_manager:add(plan)
	end
	return plan
end

--------------------------------------
-- NPC Enhancements
--------------------------------------
-- Get exsisting plan prefering the already assigned
function func.get_existing_plan(self)
	local mv_obj = npcf.movement.getControl(self)
	if self.metadata.build_plan_id and (not tmp_next_plan or self.build_plan ~= tmp_next_plan) then
		-- check if current plan is still valid / get them
		dprint(self.npc_id,"check existing plan", self.metadata.build_plan_id )
		self.build_plan = plan_manager:get(self.metadata.build_plan_id)
	end

	-- The NPC is not a workaholic
	if self.build_plan == nil and schemlib_builder_npcf.max_pause_duration > 0 then
		dprint(self.npc_id,"check for pause")
		if not self.metadata.schemlib_pause then
			self.metadata.schemlib_pause = math.random(schemlib_builder_npcf.max_pause_duration)
			self.metadata.schemlib_pause_counter = 0
			dprint(self.npc_id,"take a pause:", self.metadata.schemlib_pause)
		end
		self.metadata.schemlib_pause_counter = self.metadata.schemlib_pause_counter + 1
		if self.metadata.schemlib_pause_counter < self.metadata.schemlib_pause then
			-- it is pause time
			return
		end
	else
		-- reset pause counter if plan exists to allow pause next time
		self.metadata.schemlib_pause = nil
	end

	if not self.build_plan or self.build_plan == tmp_next_plan then
		-- no plan assigned, check for neighboar plans / select existing plan
		dprint(self.npc_id,"select existing plan")
		local selected_plan = {}
		for plan_id, _ in pairs(plan_manager.plan_list) do
			local plan = plan_manager:get(plan_id)
			if plan then
				local distance = vector.distance(plan.anchor_pos, mv_obj.pos)
				dprint(self.npc_id,"plan exists:", plan_id, plan.anchor_pos, distance)
				if distance < schemlib_builder_npcf.plan_max_distance and (not selected_plan.distance or selected_plan.distance > distance) then
					selected_plan.distance = distance
					selected_plan.plan = plan
				end
			end
		end
		self.build_plan = selected_plan.plan or self.build_plan
		if self.build_plan then
			self.metadata.build_plan_id = self.build_plan.plan_id
			dprint(self.npc_id,"Existing plan selected", selected_plan.plan_id)
		end
	end
end


function func.create_new_plan(self)
	local mv_obj = npcf.movement.getControl(self)
	if not tmp_next_plan then
		-- no plan in list - and no plan temporary loaded - load them (maybe)
		local building = schemlib_builder_npcf.buildings[math.random(#schemlib_builder_npcf.buildings)]
		dprint(self.npc_id,"File selected for build", building.filename)
		tmp_next_plan = func.get_plan_from_file(building.name, building.filename)
		dprint(self.npc_id,"building loaded. Nodes:", tmp_next_plan.data.nodecount)
		return
	end

	if math.random(schemlib_builder_npcf.check_anchor_rarity) == 1 then
		-- dummy plan exists, search for anchor, but do not penetrate the map by propose_anchor()
		local chk_pos = vector.round(mv_obj.pos)
		local anchor_pos, error_pos
		-- check for possible overlaps with other plans
		for plan_id, _ in pairs(plan_manager.plan_list) do
			local plan = plan_manager:get(plan_id)
			if tmp_next_plan:check_overlap(plan:get_world_minp(), plan:get_world_maxp(), chk_pos) then
				error_pos = plan:get_world_pos(plan:get_random_plan_pos())
				break
			end
		end
		if not error_pos then
			-- take the anchor proposal
			anchor_pos, error_pos =  tmp_next_plan:propose_anchor(chk_pos, true)
		end
		if not anchor_pos then
			dprint(self.npc_id,"not buildable nearly", minetest.pos_to_string(chk_pos))
			if error_pos then
				-- walk away from error position
				self.prefered_direction = vector.direction(error_pos, mv_obj.pos)
			end
			return
		end
		dprint(self.npc_id,"proposed anchor", minetest.pos_to_string(anchor_pos), "nearly", minetest.pos_to_string(mv_obj.pos))

		-- Prepare building plan to be build
		self.build_plan = plan_manager:activate_by_anchor(anchor_pos)
		self.metadata.build_plan_id = self.build_plan.plan_id
		dprint(self.npc_id,"building ready to build at:", self.metadata.build_plan_id)
	end
end



npcf:register_npc("schemlib_builder_npcf:builder" ,{
	description = "Larry Schemlib (NPC)",
	textures = {"npcf_builder_skin.png"},
	stepheight = 1.1,
	inventory_image = "npcf_builder_inv.png",
	on_step = function(self)
		if self.timer < 1 then
			return
		end
		self.timer = 0
		local mv_obj = npcf.movement.getControl(self)
		mv_obj:mine_stop()

		-- check plan
		func.get_existing_plan(self)
		if self.build_plan then
			dprint(self.npc_id,"plan ready for  build, get the next node")
			if not self.build_npc_ai or self.build_npc_ai.plan ~= self.build_plan then
				self.build_npc_ai = schemlib.npc_ai.new(self.build_plan, BUILD_DISTANCE)
			end
			self.target_node = self.build_npc_ai:plan_target_get(mv_obj.pos)
		end
		if not self.build_plan and schemlib_builder_npcf.architect_rarity > 0 and
				math.random(schemlib_builder_npcf.architect_rarity) == 1 then
			func.create_new_plan(self)
			self.target_node = nil
		end

		if not self.build_plan then
			dprint(self.npc_id,"plan not ready for build, or NPC does a pause")
			self.target_node = nil
		end

		dprint(self.npc_id,"target selected", tostring(self.target_node))
		if self.target_node then
			-- at work
			local targetpos = self.target_node:get_world_pos()
			mv_obj:walk(targetpos, 1, {teleport_on_stuck = true})
			dprint(self.npc_id,"work at:", minetest.pos_to_string(targetpos), self.target_node.name, "my pos", minetest.pos_to_string(mv_obj.pos))
			if vector.distance(mv_obj.pos, targetpos) <= BUILD_DISTANCE then
				dprint(self.npc_id,"build:", minetest.pos_to_string(targetpos))
				mv_obj:mine()
				mv_obj:set_walk_parameter({teleport_on_stuck = false})
				self.build_npc_ai:place_node(self.target_node)
				self.target_node = nil
			end
		else
			-- walk around

			-- check the timer
			if self.metadata.walk_around_timer then
				self.metadata.walk_around_counter = self.metadata.walk_around_counter + 1
				if self.metadata.walk_around_counter > self.metadata.walk_around_timer then
					self.walk_around_timer = nil
				end
			end

			if schemlib_builder_npcf.walk_around_rarity > 0 and
					(math.random(schemlib_builder_npcf.walk_around_rarity) == 1 and not self.walk_around_timer) then
				-- set the timer
				self.metadata.walk_around_timer = math.random(schemlib_builder_npcf.walk_around_duration)
				self.metadata.walk_around_counter = 0

				self.metadata.walk_around_counter = self.metadata.walk_around_counter + 1
				if self.metadata.walk_around_counter > self.metadata.walk_around_timer then
					self.walk_around_timer = nil
				end

				local walk_to = vector.add(mv_obj.pos,{x=math.random(41)-21, y=0, z=math.random(41)-21})

				-- create prefered direction to nearest player
				if math.random(10) == 1 then
					local nearest_pos, nearest_distance
					for _, player in ipairs(minetest.get_connected_players()) do
						local playerpos  = player:getpos()
						local distance = vector.distance(mv_obj.pos, playerpos)
						if distance < schemlib_builder_npcf.plan_max_distance and
								(not nearest_pos or (nearest_distance > distance)) then
							nearest_pos = playerpos
							nearest_distance = distance
						end
					end
					if nearest_pos then
						self.prefered_direction = vector.direction(mv_obj.pos, nearest_pos)
					end
				end

				-- create prefered direction to nearest other builder npc
				if math.random(10) == 1 then
					local nearest_pos, nearest_distance
					for _, npc in pairs(npcf.npcs) do
						if npc.name == "schemlib_builder_npcf:builder" and npc.pos then
							local distance = vector.distance(mv_obj.pos, npc.pos)
							if distance < schemlib_builder_npcf.plan_max_distance and
									(not nearest_pos or (nearest_distance > distance)) then
								nearest_pos = npc.pos
								nearest_distance = distance
							end
						end
					end
					if nearest_pos then
						self.prefered_direction = vector.direction(mv_obj.pos, nearest_pos)
					end
				end

				-- prefer the streight way
				if not self.prefered_direction then
					local yaw = mv_obj.yaw + math.pi * 0.5
					self.prefered_direction = {x=math.cos(yaw), y=0, z=math.sin(yaw)}
				end
				walk_to = vector.add(walk_to, vector.multiply(self.prefered_direction, 10))

				-- prefer the high of the ground under the last building is built, to go down
				if self.anchor_y then
					walk_to.y = self.anchor_y
				end

				walk_to = npcf.movement.functions.get_walkable_pos(walk_to, 3)
				if walk_to then
					walk_to.y = walk_to.y + 1
					mv_obj:walk(walk_to, 1, {teleport_on_stuck = true})
					self.anchor_y = nil -- used once
					dprint(self.npc_id,"walk to", minetest.pos_to_string(walk_to))
				end
			elseif math.random(200) == 1 then
				mv_obj:sit()
			elseif math.random(400) == 1 then
				mv_obj:lay()
			end
		end
	end,
})

-- Restore data at init
schemlib_builder_npcf.buildings = func.get_buildings_list() -- at init!
plan_manager:restore()

