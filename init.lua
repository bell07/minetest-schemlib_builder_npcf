local dprint = print
local modpath = minetest.get_modpath(minetest.get_current_modname())

local BUILD_DISTANCE = 3

local function check_plan(self)
	local control = npcf.control_framework.getControl(self)
	-- check if current plan is still valid / get them
	if self.build_plan_id then
		self.build_plan = schemlib.plan.get(self.build_plan_id)
		if self.build_plan then
			if not self.build_plan.data then
				--TODO (maybe): load the data
			elseif self.build_plan.data.nodecount == 0 then
				-- build is finished
				self.build_plan:delete_plan()
				self.build_plan = nil
				self.build_plan_id = nil
			end
		end
	end
	-- The NPC is not a workaholic
	if self.build_plan == nil then
		if not self.schemlib_pause then
			self.schemlib_pause = math.random(100)
			dprint("take a pause:", self.schemlib_pause) 
		end
		if not self.schemlib_builder_timer then
			self.schemlib_builder_timer = 0
		elseif self.schemlib_builder_timer < self.schemlib_pause then
			return false
		end
		self.schemlib_pause = nil
	end
	if self.build_plan == nil then
		local all_plan = schemlib.plan.get_all()
		if all_plan ~= nil then
			-- select existing plan
			local selected_plan = {}
			for plan_id, plan in pairs(all_plan) do
				if plan.anchor_pos then
					if vector.distance(plan.anchor_pos, control.pos) < 100 then
						selected_plan.plan = plan
						selected_plan.plan_id = plan_id
					end
				else
			--TODO: a logic to select plans without anchor_pos ??
					self.build_plan = selected_plan.plan
					self.build_plan_id = selected_plan.plan_id
				end
			end

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

		self.build_plan_id = filename
		self.build_plan = schemlib.plan.new(filename)
		self.build_plan:read_from_schem_file(filepath..filename)
		dprint("building loaded. Nodes:", self.build_plan.data.nodecount)

		 --take a short pause if created new building
		self.schemlib_builder_timer = 0
		return false
	else
		-- use existing plan, do the next step
		return true
	end
end


local function plan_ready_to_build(self)
	local control = npcf.control_framework.getControl(self)
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
	if self.build_plan.anchor_pos == nil then
		self.build_plan.anchor_pos = vector.round(control.pos)
		self.build_plan.anchor_pos.y = self.build_plan.anchor_pos.y - 1. --1.5 is NPC high
		-- rename to saveble
		self.build_plan_id = self.build_plan.anchor_pos.x.."-"..self.build_plan.anchor_pos.y.."-"..self.build_plan.anchor_pos.z
		self.build_plan:change_plan_id(self.build_plan_id)
		self.build_plan:apply_flood_with_air(3, 0, 3)
		-- TODO: self.build_plan:save() to file
		dprint("building ready to build at:", self.build_plan_id)
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

		local control = npcf.control_framework.getControl(self)
		control:mine_stop()
		-- check plan
		if check_plan(self) then
			if plan_ready_to_build(self) then
				self.target_node = schemlib.npc_ai.plan_target_get({
						plan = self.build_plan, 
						npcpos = control.pos,
						savedata = self.my_ai_data})
			end
		end

		if self.target_node then
			-- at work
			control:walk(self.target_node.world_pos, 1)
			dprint("work at:", minetest.pos_to_string(self.target_node.world_pos), self.target_node.name, "my pos", minetest.pos_to_string(control.pos))
			if vector.distance(control.pos, self.target_node.world_pos) <= BUILD_DISTANCE then
				dprint("build:", minetest.pos_to_string(self.target_node.world_pos))
				control:mine()
				schemlib.npc_ai.place_node(self.target_node, self.build_plan)
				self.build_plan:del_node(self.target_node.plan_pos)
				self.target_node = nil
			end
		else
			-- walk around
			if math.random(100) == 1 then
				local walk_to = vector.add(control.pos,{x=math.random(40)-20, y=0, z=math.random(40)-20})
				control:walk(walk_to, 1)
				dprint("walk to", minetest.pos_to_string(walk_to))
			end
		end
	end
})


