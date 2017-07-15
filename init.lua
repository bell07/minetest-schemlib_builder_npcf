--local dprint = print
local dprint = function() return end
local modpath = minetest.get_modpath(minetest.get_current_modname())

local BUILD_DISTANCE = 3

schemlib_builder_npcf = {}

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
		local plan = schemlib.plan.new(plan_id, entry.anchor_pos)
		plan.schemlib_builder_npcf_building_filename = entry.filename
		plan:read_from_schem_file(modpath.."/buildings/"..entry.filename)
		plan:apply_flood_with_air() -- is usually prepared in this way
		plan_manager:add(plan_id, plan)
	end
end

--------------------------------------
-- Save active WIP plan's
--------------------------------------
function plan_manager:save()
	self.stored_list = {}
	for plan_id, plan in pairs(self.plan_list) do
		if plan.anchor_pos and plan.schemlib_builder_npcf_building_filename then
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
	return self.plan_list[plan_id]
end

--------------------------------------
-- Set the plan finished
--------------------------------------
function plan_manager:set_finished(plan_id)
	self.plan_list[plan_id] = nil
end

--------------------------------------
-- Add new plan to the list
--------------------------------------
function plan_manager:add(plan_id, plan)
	self.plan_list[plan_id] = plan
end

--------------------------------------
-- set anchor and rename to get active
--------------------------------------
function plan_manager:activate_by_anchor(plan_id, anchor_pos)
	local plan = self.plan_list[plan_id]
	local new_plan_id = minetest.pos_to_string(anchor_pos)

	self.plan_list[plan_id] = nil
	plan.plan_id = plan_id
	plan.anchor_pos = anchor_pos
	self.plan_list[new_plan_id] = plan
	self:save()
end

-- Restore data at init
plan_manager:restore()

--------------------------------------
-- NPC Enhancements
--------------------------------------
local function check_plan(self)
	local mv_obj = npcf.movement.getControl(self)
	-- check if current plan is still valid / get them
	if self.metadata.build_plan_id then
		self.build_plan = plan_manager:get(self.metadata.build_plan_id)
		if self.build_plan then
			self.build_plan_status = self.build_plan:get_status()
			if self.build_plan_status == "finished" then
				-- build is finished
				plan_manager:set_finished(self.metadata.build_plan_id)
				plan_manager:save()
				self.build_plan = nil
				self.build_npc_ai = nil
				self.metadata.build_plan_id = nil
				self.build_plan_status = nil
			end
		else
			self.build_npc_ai = nil
			self.metadata.build_plan_id = nil
			self.build_plan_status = nil
		end
	end


	-- The NPC is not a workaholic
	if self.build_plan == nil then
		if not self.metadata.schemlib_pause then
			self.metadata.schemlib_pause = math.random(100)
			self.metadata.schemlib_pause_counter = 0
			dprint("take a pause:", self.metadata.schemlib_pause)
		end
		self.metadata.schemlib_pause_counter = self.metadata.schemlib_pause_counter + 1
		if self.metadata.schemlib_pause_counter < self.metadata.schemlib_pause then
			-- it is pause time
			return false
		end
	else
		-- reset pause counter if plan exists to allow pause next time
		self.metadata.schemlib_pause = nil
	end

	if self.build_plan == nil then
		-- select existing plan
		local selected_plan = {}
		for plan_id, plan in pairs(plan_manager.plan_list) do
			dprint("plan exists:", plan_id, plan.anchor_pos)
			if plan.status == "build" then -- already active
				local distance = vector.distance(plan.anchor_pos, mv_obj.pos)
				if distance < 100 and (not selected_plan.distance or selected_plan.distance > distance) then
					selected_plan.distance = distance
					selected_plan.plan = plan
					selected_plan.plan_id = plan_id
				end
			elseif plan.status == "new" then
				selected_plan.distance = 100
				selected_plan.plan = plan
				selected_plan.plan_id = plan_id
			end
		end
		self.build_plan = selected_plan.plan
		self.metadata.build_plan_id = selected_plan.plan_id
		if self.build_plan then
			self.build_plan_status = self.build_plan:get_status()
			dprint("Existing plan selected", selected_plan.plan_id)
		end
	end
	if self.build_plan == nil then
		local filepath = modpath.."/buildings/"
		local files = minetest.get_dir_list(filepath, false)
		local filename
		if #files == 0 then
			print("ERROR: no files found")
			return --error
		else
			filename = files[math.random(#files)]
			dprint("File selected for build", filename)
		end

		self.metadata.build_plan_id = filename
		self.build_plan = schemlib.plan.new(filename)
		self.build_plan:read_from_schem_file(filepath..filename)
		self.build_plan.schemlib_builder_npcf_building_filename = filename
		plan_manager:add(self.metadata.build_plan_id , self.build_plan)
		self.build_plan:apply_flood_with_air() -- is usually prepared in this way
		dprint("building loaded. Nodes:", self.build_plan.data.nodecount)
		return false -- small pause, do nothing anymore this step
	else
		-- use existing plan, do the next step
		return true
	end
end


local function plan_ready_to_build(self)
	local mv_obj = npcf.movement.getControl(self)
	-- the anchor_pos missed, plan needs t
	if self.build_plan_status == "new" then
		local anchor_pos, error_pos =  self.build_plan:propose_anchor(vector.round(mv_obj.pos), true)
		if anchor_pos == false then
			dprint("not buildable nearly", minetest.pos_to_string(mv_obj.pos))

			if math.random(4) == 1 then
				local walk_to = vector.add(mv_obj.pos, vector.multiply(vector.direction(error_pos, mv_obj.pos), 10))
				walk_to.y = mv_obj.pos.y
				walk_to = npcf.movement.functions.get_walkable_pos(walk_to, 3)
				if walk_to then
					walk_to.y = walk_to.y + 1
					mv_obj:walk(walk_to, 1, {teleport_on_stuck = true})
					dprint("walk to", minetest.pos_to_string(walk_to))
				end
			end
			return false
		end
		dprint("proposed anchor", minetest.pos_to_string(anchor_pos), "nearly", minetest.pos_to_string(mv_obj.pos))

		-- Prepare building plan to be build
		self.metadata.build_plan_id = plan_manager:activate_by_anchor(self.metadata.build_plan_id, anchor_pos)
		self.build_plan.plan_id = self.metadata.build_plan_id
		self.build_plan:apply_flood_with_air()
		self.build_plan:set_status("build")
		self.build_plan_status = "build"
		dprint("building ready to build at:", self.metadata.build_plan_id)
		return false -- small pause, do nothing anymore this step
	elseif self.build_plan_status == "build" then
		return true
	else
		return false
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
		if not self.my_ai_data then
			self.my_ai_data = {}
		end

		local mv_obj = npcf.movement.getControl(self)
		mv_obj:mine_stop()
		-- check plan
		if check_plan(self) then
			if plan_ready_to_build(self) then
				if not self.build_npc_ai or self.build_npc_ai.plan ~= self.build_plan then
					self.build_npc_ai = schemlib.npc_ai.new(self.build_plan, BUILD_DISTANCE)
				end
				self.target_node = self.build_npc_ai:plan_target_get(mv_obj.pos)
			end
		else
			--no target without plan
			self.target_node = nil
		end

		if self.target_node then
			-- at work
			local targetpos = self.target_node:get_world_pos()
			mv_obj:walk(targetpos, 1, {teleport_on_stuck = true})
			dprint("work at:", minetest.pos_to_string(targetpos), self.target_node.name, "my pos", minetest.pos_to_string(mv_obj.pos))
			if vector.distance(mv_obj.pos, targetpos) <= BUILD_DISTANCE then
				dprint("build:", minetest.pos_to_string(targetpos))
				mv_obj:mine()
				mv_obj:set_walk_parameter({teleport_on_stuck = false})
				self.build_npc_ai:place_node(self.target_node)
				self.target_node = nil
			end
		else
			-- walk around
			if math.random(10) == 1 then
				local walk_to = vector.add(mv_obj.pos,{x=math.random(41)-21, y=0, z=math.random(41)-21})
				walk_to = npcf.movement.functions.get_walkable_pos(walk_to, 3)
				if walk_to then
					walk_to.y = walk_to.y + 1
					mv_obj:walk(walk_to, 1, {teleport_on_stuck = true})
					dprint("walk to", minetest.pos_to_string(walk_to))
				end
			elseif math.random(100) == 1 then
				mv_obj:sit()
			elseif math.random(200) == 1 then
				mv_obj:lay()
			end
		end
	end,
})


