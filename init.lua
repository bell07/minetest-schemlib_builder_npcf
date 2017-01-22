local dprint = print
local modpath = minetest.get_modpath(minetest.get_current_modname())

local BUILD_DISTANCE = 3

local function check_plan(self)
	local mv_obj = npcf.movement.getControl(self)
	-- check if current plan is still valid / get them
	if self.metadata.build_plan_id then
		self.build_plan = schemlib.plan.get(self.metadata.build_plan_id)
		if self.build_plan then
			if not self.build_plan.data then
				--TODO (maybe): load the data
			elseif self.build_plan.data.nodecount == 0 then
				-- build is finished
				self.build_plan:delete_plan()
				self.build_plan = nil
				self.metadata.build_plan_id = nil
			end
		else
			self.metadata.build_plan_id = nil
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
		local all_plan = schemlib.plan.get_all()
		if all_plan ~= nil then
			-- select existing plan
			local selected_plan = {}
			for plan_id, plan in pairs(all_plan) do
				print("plan exists:", plan_id, plan.anchor_pos)
				if plan.anchor_pos then
					if vector.distance(plan.anchor_pos, mv_obj.pos) < 100 then
						selected_plan.plan = plan
						selected_plan.plan_id = plan_id
					end
				else
			--TODO: if not assigned to anchor, all NPC can use them
					selected_plan.plan = plan
					selected_plan.plan_id = plan_id
				end
			end
			self.build_plan = selected_plan.plan
			self.metadata.build_plan_id = selected_plan.plan_id

			if self.build_plan then
				dprint("Existing plan selected", selected_plan.plan_id)
			end
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
		dprint("building loaded. Nodes:", self.build_plan.data.nodecount)
		return false -- small pause, do nothing anymore this step
	else
		-- use existing plan, do the next step
		return true
	end
end


local function plan_ready_to_build(self)
	local mv_obj = npcf.movement.getControl(self)
	-- TODO: check if anchor_pos is set
	-- If not, try a random nearly position can be used
	-- schemlib.world:propose_y(wpos)
	-- in schemlib.world:plan_is_placeble(wpos)
	-- including check if an other plan in this area
	-- including check for is_ground_content ~= false in this area (nil is like true)
	-- Check node count is zero. Delete plan in this case

	-- TODO: if buildable: set anchor and save the building (will be added to the schemlib.plan.plan_list)
	-- Now the plan is ready to build
	
	-- the anchor_pos missed, plan needs t
	if not self.build_plan.anchor_pos then
		local anchor_pos, error_pos =  self.build_plan:propose_anchor(vector.round(mv_obj.pos), true)
		if anchor_pos == false then
			dprint("not buildable nearly", minetest.pos_to_string(mv_obj.pos))
			--TODO: walk away
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
		-- rename to saveble
		self.build_plan.anchor_pos = anchor_pos
		self.metadata.build_plan_id = self.build_plan.anchor_pos.x.."-"..self.build_plan.anchor_pos.y.."-"..self.build_plan.anchor_pos.z
		self.build_plan:change_plan_id(self.metadata.build_plan_id)
		self.build_plan:apply_flood_with_air()
		-- TODO: self.build_plan:save() to file
		dprint("building ready to build at:", self.metadata.build_plan_id)
		return false -- small pause, do nothing anymore this step
	end

	-- is buildable, anchor exists
	if self.build_plan.anchor_pos then
		return true
	end

	return false --currently not
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
				self.target_node = schemlib.npc_ai.plan_target_get({
						plan = self.build_plan, 
						npcpos = mv_obj.pos,
						savedata = self.my_ai_data})
			end
		else
			--no target without plan
			self.target_node = nil
		end

		if self.target_node then
			-- at work
			mv_obj:walk(self.target_node.world_pos, 1, {teleport_on_stuck = true})
			dprint("work at:", minetest.pos_to_string(self.target_node.world_pos), self.target_node.name, "my pos", minetest.pos_to_string(mv_obj.pos))
			if vector.distance(mv_obj.pos, self.target_node.world_pos) <= BUILD_DISTANCE then
				dprint("build:", minetest.pos_to_string(self.target_node.world_pos))
				mv_obj:mine()
				mv_obj:set_walk_parameter({teleport_on_stuck = false})
				schemlib.npc_ai.place_node(self.target_node, self.build_plan)
				self.build_plan:del_node(self.target_node.plan_pos)
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


