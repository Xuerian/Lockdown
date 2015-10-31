-- Lockdown contains a significant amount of code providing a expanded targeting system around a user-positioned reticle, since we cannot reposition the mouseover location.
-- It must account for a few complications with the API to do so:
-- Units are not well classified as units the player should care about or should be able to target, by default
-- All units may be targeted with GameLib.SetTargetUnit(unit), but invalid targets are immediately un-targeted. This is the process in that case:
-- GameLib.SetTargetUnit(unit) called (It returns true or false based on if the player can target anything at the current time, not if the player can target [unit])
--  "UnitCreated" and "TargetUnitChanged" are called during this call, and finish before it returns
--  "TargetUnitChanged" is then called after it returns, inside the current frame.

local tUnitWhitelist = {
	["Charge Target"] = true -- Challenge swing things
}

local tUnitBlacklist = {

}

----------------------------------------------------------
-- Localization

local tLocalization = {
	en_us = {
		button_configure = "Lockdown",
		button_label_bind = "Click to change",
		button_label_bind_wait = "Press new key",
		button_label_mod = "No modifier",

		Title_tweaks = "Tweaks",
		Text_mouselockrebind = "Lockdown has been slimmed down quite a bit since Reloaded. Some options are missing or incomplete.",

		togglelock = "Toggle Lockdown",
		locktarget = "Lock/Unlock current target",
		manualtarget = "Manual target",
		auto_target = "Reticle targeting",
		reticle_show = "Show reticle",
		-- auto_target_delay = "Reticle target delay",
		reticle_range_limit = "Maximum targeting range",
		reticle_clear_distant_target = "Clear targets that move too far from the reticle",
		reticle_clear_distant_range = "Clear target distance",
		-- update_frame_rate = "Update every 4*n frames",
		reticle_opacity = "Reticle opacity",
		reticle_size = "Reticle size",
		reticle_offset_y = "Vertical offset",
		reticle_offset_x = "Horizontal offset",
		reticle_hue_red = "Reticle hue (Red)",
		reticle_hue_green = "Reticle hue (Green)",
		reticle_hue_blue = "Reticle hue (Blue)",

		message_target_locked = "Target locked: %s",
		message_target_unlocked = "Target unlocked",
	}
}
local L = setmetatable({}, {__index = tLocalization.en_us})

-- System key map
-- I don't even know who this is from
-- Three different mods have three different versions
local SystemKeyMap


----------------------------------------------------------
-- Local references

local pairs, ipairs, table, string, math = pairs, ipairs, table, string, math
local GameLib, Apollo = GameLib, Apollo


----------------------------------------------------------
-- Settings

-- Defaults
Lockdown = {
	defaults = {
		locktarget_key = 20, -- Caps Lock
		locktarget_mod = false,
		reticle_show = true,
		reticle_range_limit = 50,
		reticle_clear_distant_target = true,
		reticle_clear_distant_range = 150,
		auto_target = true,
		auto_target_neutral = false,
		auto_target_hostile = true,
		auto_target_friendly = false,
		auto_target_settler = false,
		auto_target_harvest = true,
		reticle_opacity = 0.1,
		reticle_size = 128,
		reticle_sprite = "giznat",
		reticle_offset_x = 0,
		reticle_offset_y = -70,
		reticle_hue_red = 1,
		reticle_hue_blue = 1,
		reticle_hue_green = 1,

		-- Deprecated
		manualtarget_key = 72, -- H
		manualtarget_mod = "control",
		free_with_shift = false,
		free_with_ctrl = false,
		free_with_alt = true,
		auto_target_delay = 0,
		auto_target_interval = 100,
		update_frame_rate = 4,
	},
	settings = {},
	reticles = {}
}
local Lockdown = Lockdown

-- Since OnRestore can trigger late (or not trigger), preset these
Lockdown.tTargetDispositions = {
	[Unit.CodeEnumDisposition.Friendly] = Lockdown.defaults.auto_target_friendly,
	[Unit.CodeEnumDisposition.Neutral] = Lockdown.defaults.auto_target_neutral,
	[Unit.CodeEnumDisposition.Hostile] = Lockdown.defaults.auto_target_hostile
}

local opt = Lockdown.settings

setmetatable(Lockdown.settings, {__index = Lockdown.defaults})


----------------------------------------------------------
-- Wait until a condition is met (Or simply wait for a delay) to call a given function

local Alfred = { timers = {}, i = 0 }
function Alfred:Wait(fCondition, fAction, nfDelay)
	local i = self.i
	local timer = ApolloTimer.Create(nfDelay or 0.1, true, "Timer_"..i, self)
	self.timers[i] = timer
	-- Apparently ApolloTimer doesn't like numerical function keys
	self["Timer_"..i] = function()
		if not fCondition or fCondition() then
			timer:Stop()
			fAction()
			-- Release
			self.timers[i] = nil
			self["Timer_"..i] = nil
		end
	end
	self.i = i + 1
	return i
end


----------------------------------------------------------
-- I want my print(), and I want my print() whenitwillactuallywork!

local print_buffer = {}
local function print(...)
	table.insert(print_buffer, {...})
end

Alfred:Wait(nil, function()
	function print(...)
		local out = {}
		for i=1,select('#', ...) do
			local v = select(i, ...)
			table.insert(out,  v == nil and "[nil]" or tostring(v))
		end
		Print(table.concat(out, " "))
	end
	-- Process and clear buffer
	for i,v in ipairs(print_buffer) do
		print(unpack(v))
	end
	print_buffer = nil
end, 3)

local function system_print(...)
	if ChatSystemLib then
		ChatSystemLib.PostOnChannel(2, table.concat({...}, ", "))
	else
		print(...)
	end
end

----------------------------------------------------------
-- Helpers

-- Wipe a table for reuse
local function wipe(t)
	for k,v in pairs(t) do
		t[k] = nil
	end
end

-- Load all form elements into a table by name
local function children_by_name(wnd, t)
	local t = t or {}
	for _,child in ipairs(wnd:GetChildren()) do
		t[child:GetName()] = child
		children_by_name(child, t)
	end
	return t
end


----------------------------------------------------------
-- Module stuff

function Lockdown:RegisterEventHandler(event, handler)
	handler = handler or "EventHandler_"..event
	assert(self[handler], "Requested event handler does not exist")
	Apollo.RegisterEventHandler(event, handler, self)
end

function Lockdown:Init()
	Apollo.RegisterAddon(self, true, L.button_configure)
	-- We have to register for this right away, since we get units before
	-- the addon finishes loading, much less the player unit existing.
	self:RegisterEventHandler("UnitCreated", "Handler_ProcessUnit")
end

----------------------------------------------------------
-- Saved data

function Lockdown:OnSave(eLevel)
	if eLevel == GameLib.CodeEnumAddonSaveLevel.Account then
		local s = self.settings
		-- Don't save defaults
		for k,v in pairs(s) do
			if v == self.defaults[k] then
				s[k] = nil
			end
		end
		return s
	end
end

function Lockdown:OnRestore(eLevel, tData)
	if eLevel == GameLib.CodeEnumAddonSaveLevel.Account and tData then
		local s = self.settings
		-- Restore settings
		for k,v in pairs(self.defaults) do
			if tData[k] ~= nil then
				s[k] = tData[k]
			end
		end
		-- Build settings dependent data
		self.tTargetDispositions = {
			[Unit.CodeEnumDisposition.Friendly] = s.auto_target_friendly,
			[Unit.CodeEnumDisposition.Neutral] = s.auto_target_neutral,
			[Unit.CodeEnumDisposition.Hostile] = s.auto_target_hostile
		}
		-- Update settings dependant events
		self:KeyOrModifierUpdated()
	end
end

local preload_units, g_isScientist, g_isSettler = {}
local LOCK_STATE = false
local PLAYER = nil
local FRAME = 0
local PAUSED = false
function Lockdown:OnLoad()
	----------------------------------------------------------
	-- Load reticle

	self.wndReticle = Apollo.LoadForm("Lockdown.xml", "Lockdown_ReticleForm", "InWorldHudStratum", nil, self)
	self.wndReticleSpriteTarget = self.wndReticle:FindChild("Lockdown_ReticleSpriteTarget")

	-- Add reticles
	self:AddReticle("tiny", [[Lockdown\reticles\tiny.png]], 128)
	self:AddReticle("giznat", [[Lockdown\reticles\giznat.png]], 256)
	self:Reticle_Update()
	self:RegisterEventHandler("ResolutionChanged", "Reticle_Update")

	----------------------------------------------------------------------
	-- TICK TOCK TICK TOCK

	self:RegisterEventHandler("VarChange_FrameCount")
	self:RegisterEventHandler("NextFrame")

	----------------------------------------------------------
	-- Options

	Apollo.RegisterSlashCommand("lockdown", "OnConfigure", self)
	Apollo.RegisterSlashCommand("ldt", "LockdownTest", self)

	----------------------------------------------------------
	-- Targeting

	self.xmlMarker = XmlDoc.CreateFromFile("Lockdown_Marker.xml")
	self:RegisterEventHandler("UnitActivationTypeChanged", "Handler_ProcessUnit")
	self:RegisterEventHandler("UnitMiniMapMarkerChanged", "Handler_ProcessUnit")
	self:RegisterEventHandler("UnitGibbed", "Handler_ProcessUnit")
	self:RegisterEventHandler("UnitDestroyed")
	self:RegisterEventHandler("ChangeWorld")
	self:RegisterEventHandler("TargetUnitChanged")
	self.timerEscResume = ApolloTimer.Create(1, false, "TimerHandler_EscResume", self)
	self.timerEscResume:Stop()

	----------------------------------------------------------
	-- Keybinds

	self:RegisterEventHandler("SystemKeyDown")
	-- self.timerFreeKeys = ApolloTimer.Create(0.1, true, "TimerHandler_FreeKeys", self)

	self:KeyOrModifierUpdated()
end

----------------------------------------------------------
-- Units and Advanced Targeting

-- true if desired, false if not, nil if needs removed
-- TODO: Better filtering of units we really don't care about to cut down on OnScreen calls
local function IsDesiredUnit(unit)
	if not unit:IsValid() or unit:IsThePlayer() then return nil end
	local unitType = unit:GetType()
	local player = GameLib.GetPlayerUnit()
	-- PC Units are not removed on death and respawn without a unit creation event
	if unitType == "Player" then
		if unit:GetDispositionTo(player) == Unit.CodeEnumDisposition.Friendly then
			-- TODO: Friendly player filtering
		elseif player:IsPvpFlagged() and unit:IsPvpFlagged() then
			return true
		end
		return false
	end
	-- Lists
	local name = unit:GetName()
	if tUnitBlacklist[name] then
		return nil
	elseif tUnitWhitelist[name] then
		return true
	
	-- Harvest nodes
	elseif unitType == "Harvest"
	and unit:GetHarvestRequiredTradeskillName() ~= "Farmer"
	and unit:CanBeHarvestedBy(player) then
		return true
	
	-- Visible plates
	elseif unit:ShouldShowNamePlate() and unit:GetDispositionTo(player) ~= Unit.CodeEnumDisposition.Friendly then
		if unit:IsDead() then
			return false
		end
		return true
	end

	-- Activation states
	local tAct = unit:GetActivationState()
	local bActState = tAct and next(tAct) or false
	if bActState then
		-- Hide already activated quest objects
		if tAct.QuestTarget and not (tAct.Interact and tAct.Interact.bCanInteract) then
			if unitType == "Simple" then return else return false end
			-- return false
		
		-- Hide settler collection or improvements
		-- elseif g_isSettler and not opt.auto_target_settler and (tAct.SettlerMinfrastructure or (tAct.Collect and tAct.Collect.bUsePlayerPath)) then
		-- 	onscreen[unit:GetId()] = nil
		-- 	return
		
		-- Generic activateable objects
		elseif tAct.Interact and (tAct.Interact.bCanInteract or tAct.Interact.bIsHighlightable or tAct.Interact.bShowCallout) then
			return true
		
		-- Quest turn-ins
		elseif tAct.QuestReward and tAct.QuestReward.bIsActive and tAct.QuestReward.bCanInteract then
			return true
		
		-- Quest starting objects
		elseif tAct.QuestNew and tAct.QuestNew.bCanInteract then
			return true
		
		-- Scientist scans
		elseif g_isScientist then
			-- Datacubes
			if (tAct.Datacube and tAct.Datacube.bIsActive)
			-- Raw scannable items (information constructs)
			or (tAct.ScientistRawScannable and tAct.ScientistRawScannable.bIsActive) then
				return true
			end
		end
	end
	-- Units we want based on quest or path status
	local tRewards = unit:GetRewardInfo()
	if tRewards then
		for i=1,#tRewards do
			local t = tRewards[i] --t.eType == eRewardQuest and 
			-- Quest items we need and haven't interacted with
			if (t.peoObjective and t.peoObjective:GetStatus() == 1)
			or (t.nCompleted
			 and t.nCompleted < t.nNeeded
			 and (not bActState
			  or not tAct.Interact
			  or tAct.Interact.bCanInteract))
			-- or scientist scans
			or (g_isScientist and t.eType == Unit.CodeEnumRewardInfoType.Scientist) then
				return true
			end
		end
	end
	-- Discard simple units until their activation state changes
	if unitType == "Simple" then return else return false end
end

local markers = {} -- Frames anchored to units for onscreen event
local onscreen = {} -- Currently onscreen units
local inrange = {} -- Currently in range units
local buffered = {} -- Units that were created while player was invalid
local suspended = {} -- Units that are not currently, but may be targetable
Lockdown.tTrackingData = {
	markers = markers,
	onscreen = onscreen,
	inrange = inrange,
	buffered = buffered,
	suspended = suspended
}

local function DestroyMarker(uid)
	if markers[uid] then
		markers[uid]:Destroy()
		markers[uid] = nil
		onscreen[uid] = nil
		inrange[uid] = nil
		suspended[uid] = nil
	end
end



function Lockdown:Handler_ProcessUnit(unit, bOnScreen)
	if not unit then return end
	local uid = unit:GetId()
	if not uid or not unit:IsValid() or unit:IsThePlayer() then return end
	-- Player is invalid/invalidated at certain times, buffer those units
	-- since we need to get their standing to the player
	if not PLAYER then
		table.insert(buffered, unit)
		return
	end
	-- Evaluate
	local desired = IsDesiredUnit(unit)
	if desired ~= nil then
		local marker = markers[uid]
		-- New marker
		if not markers[uid] then
			markers[uid] = Apollo.LoadForm(self.xmlMarker, "Lockdown_Marker", "InWorldHudStratum", self)
			markers[uid]:SetData(unit)
			markers[uid]:SetUnit(unit)
		end
		-- Start tracking
		if bOnScreen == nil then
			bOnScreen = GameLib.GetUnitScreenPosition(unit).bOnScreen
		end
		if desired and bOnScreen then
			if not onscreen[uid] then
				onscreen[uid] = unit
			end
		-- Stop tracking
		elseif onscreen[uid] then
			onscreen[uid] = nil
			inrange[uid] = nil
		end
	-- Destroy marker
	else
		DestroyMarker(uid)
	end
end

local uCurrentTarget, uLastAutoTarget
local plsNoOverflow = false
function Lockdown:EventHandler_UnitDestroyed(unit)
	if plsNoOverflow then return nil end
	plsNoOverflow = true
	local uid = unit:GetId()
	if markers[uid] then
		-- Clear target if targeted by Lockdown
		if unit == uLastAutoTarget and GameLib.IsMouseLockOn() and unit == GameLib.GetTargetUnit() then
			uCurrentTarget = nil
			GameLib.SetTargetUnit()
		end
	end
	DestroyMarker(uid)
	plsNoOverflow = false
end

-- Clear all units on world change
function Lockdown:EventHandler_ChangeWorld()
	PLAYER = nil
	for uid in pairs(markers) do
		DestroyMarker(uid)
	end
end

function Lockdown:EventHandler_WorldLocationOnScreen(wnd, ctrl, visible)
	self:Handler_ProcessUnit(ctrl:GetUnit(), visible)
end

local function count(t)
	local n = 0
	for k,v in pairs(t) do
		n = n + 1
	end
	return n
end
function Lockdown:LockdownTest()
	local target = GameLib.GetTargetUnit()
	local tid = target and target:GetId() or nil
	local t = {
		num_onscreen = count(onscreen), -- Number of onscreen markers
		num_markers = count(markers), -- Total number of markers
		list_onscreen = {}, -- Onscreen markers
		list_offscreen = {}, -- Offscreen markers
	}
	for uid,unit in pairs(onscreen) do
		table.insert(t.list_onscreen, unit:GetName())
	end
	for uid,marker in pairs(markers) do
		if not onscreen[uid] then
			table.insert(t.list_offscreen, marker:GetUnit():GetName())
		end
	end
	if tid then
		t.osdata = osdata[tid]
		t.target = target
		t.screen = GameLib.GetUnitScreenPosition(target)
		t.marker = markers[tid]
		t.onscreen = onscreen[tid]
		t.is_marker_unit = t.marker:GetUnit() == target
	end
	SendVarToRover("Lockdown Debug Table", t)
end

--[[local fn = Lockdown.EventHandler_WorldLocationOnScreen
function Lockdown:EventHandler_WorldLocationOnScreen(wnd, ctrl, visible, unit)
	if not unit then unit = ctrl:GetData() end
	local id = unit:GetId()
	local initial = onscreen[id]
	fn(self, wnd, ctrl, visible, unit)
	if initial ~= onscreen[id] then
		print("WorldLocationOnScreen", onscreen[id] and "||||" or "----", unit:GetName())
	end
end]]

local pReticle, nReticleRadius
-- Returns bIntersects, nDistIntersection, nDistPoints
local function UnitInReticle(unit)
	local tPos = GameLib.GetUnitScreenPosition(unit)
	if not tPos or not tPos.bOnScreen then
		return false, 0, 0
	end
	-- Try to place unit point in middle of units
	local nUnitRadius, pOverhead = 0
	if unit:GetType() ~= "Simple" then
		pOverhead = unit:GetOverheadAnchor()
		-- Sanity check radius
		if pOverhead then
			nUnitRadius = math.max(15, (tPos.nY - pOverhead.y) / 2)
		end
	end
	local nDistPoints = pReticle.Length(Vector2.New(tPos.nX, tPos.nY - nUnitRadius) - pReticle)
	return nDistPoints < (nReticleRadius + nUnitRadius), nDistPoints - nReticleRadius - nUnitRadius, nDistPoints
end

-- Find in range unit closest to center of reticle
local uDelayedTarget, uLockedTarget
local nLastTargetTick -- Used to mitigate untargetable units
local nLastTargetFrame
function Lockdown:UpdateReticleTarget()
	if not PLAYER or uLockedTarget then return end
	uCurrentTarget = GameLib.GetTargetUnit()
	-- Clear targets too far away from reticle
	if uCurrentTarget and not uLockedTarget and self.settings.reticle_clear_distant_target and uCurrentTarget == uLastAutoTarget then
		local bInReticle, nDistIntersection = UnitInReticle(uCurrentTarget)
		if not bInReticle and nDistIntersection > self.settings.reticle_clear_distant_range then
			GameLib.SetTargetUnit()
		end
	end
	local nBest, uBest = 999
	for id, unit in pairs(inrange) do
		if not unit:IsOccluded() then
			-- Check reticle intersection
			local bInReticle, _, nDistPoints = UnitInReticle(unit)
			if bInReticle and nDistPoints < nBest then
				-- Verify possibly stale units
				if unit == uLastAutoTarget and not uCurrentTarget then
					-- SendVarToRover("Last lockdown target", unit)
					self:Handler_ProcessUnit(unit, true)
					if onscreen[id] then
						nBest, uBest = nDistPoints, unit
					end
				else
					nBest, uBest = nDistPoints, unit
				end
			end
		end
	end
	-- Target best unit
	-- TODO: Re-add delayed targeting
	if uBest and uCurrentTarget ~= uBest then
		uCurrentTarget, uLastAutoTarget = uBest, uBest
		-- Save tick to detect failed target attempts
		nLastTargetTick = Apollo.GetTickCount()
		if self.settings.auto_target then
			GameLib.SetTargetUnit(uBest)
		end
	end
end


----------------------------------------------------------
-- Configuration

-- Specific setting change handlers
-- CAN'T TAKE THE CHANGE, MAN
local ChangeHandlers = {}

function Lockdown:ChangeSetting(setting, value)
	self.settings[setting] = value
	if ChangeHandlers[setting] then
		ChangeHandlers[setting](value)
	end
end


local function ReticleChanged()
	Lockdown.wndReticle:Show(true)
	Lockdown:Reticle_Update()
end

ChangeHandlers.reticle_opacity = ReticleChanged
ChangeHandlers.reticle_size = ReticleChanged
ChangeHandlers.reticle_offset_x = ReticleChanged
ChangeHandlers.reticle_offset_y = ReticleChanged
ChangeHandlers.reticle_hue_red = ReticleChanged
ChangeHandlers.reticle_hue_green = ReticleChanged
ChangeHandlers.reticle_hue_blue = ReticleChanged
ChangeHandlers.reticle_sprite = ReticleChanged

local function AutoTargetDisposition(sDisposition)
	return function(value)
		Lockdown.tTargetDispositions[Unit.CodeEnumDisposition[sDisposition]] = value
	end
end

ChangeHandlers.auto_target_friendly = AutoTargetDisposition("Friendly")
ChangeHandlers.auto_target_neutral = AutoTargetDisposition("Neutral")
ChangeHandlers.auto_target_hostile = AutoTargetDisposition("Hostile")

-- Per category widget handlers
-- Binding keys
local tBindKeyMap = {}
local sWhichBind
local function BindKeySetText(btn, setting)
	local s = Lockdown.settings
	if s[setting] and s[setting] ~= "" then
		btn:SetText(SystemKeyMap[s[setting]] or "????")
	else
		btn:SetText()
	end
end
function Lockdown:OnBindKey(btn)
	local setting = tBindKeyMap[btn:GetName()]
	if not self.bind_mode_active then
		self.bind_mode_active = true
		btn:SetText(L.button_label_bind_wait)
		btn:SetCheck(true)
		sWhichBind = setting
		self.w.Btn_Unbind:Show(true)
	elseif sWhichBind == setting then
		self.bind_mode_active = false
		BindKeySetText(btn, setting)
		btn:SetCheck(false)
		self.w.Btn_Unbind:Show(false)
	end
end
-- Binding modifiers
local tBindModMap = {}
function Lockdown:OnBindMod(btn)
	local setting = tBindModMap[btn:GetName()]
	local mod = self.settings[setting]
	if not mod then
		mod = "shift"
	elseif mod == "shift" then
		mod = "control"
	else
		mod = false
	end
	self:ChangeSetting(setting, mod)
	self:KeyOrModifierUpdated()
	btn:SetText(mod and mod or L.button_label_mod)
end

-- Checkboxes
local tCheckboxMap = {}
function Lockdown:OnButtonCheck(btn)
	self:ChangeSetting(tCheckboxMap[btn:GetName()], btn:IsChecked())
end

-- Sliders
local tSliderMap = {}
function Lockdown:OnSlider(slider)
	local setting, value = tSliderMap[slider:GetName()], slider:GetValue()
	self:ChangeSetting(setting, value)
	self:UpdateWidget_Slider(slider, setting)
end

function Lockdown:UpdateWidget_Slider(slider, setting)
	local text = self.w["Text_"..setting]
	if text then
		text:SetText(math.floor(self.settings[setting]*100)/100)
	end
end

-- General handlers
function Lockdown:OnConfigure()
	self:UpdateConfigUI()
	self.wndOptions:Invoke()
end

function Lockdown:OnConfigureClose()
	self.wndOptions:Close()
end

function Lockdown:OnBtn_Unbind()
	if self.bind_mode_active then
		self.bind_mode_active = false
		self:ChangeSetting(sWhichBind, "")
		self:KeyOrModifierUpdated()
		self:UpdateConfigUI()
	end
end


function Lockdown:OnTab_General()
	self.w.Content_General:Show(true)
	self.w.Content_Reticle:Show(false)
	self.w.Tab_General:SetCheck(true)
	self.w.Tab_Reticle:SetCheck(false)
end

function Lockdown:OnTab_Reticle()
	self.w.Content_General:Show(false)
	self.w.Content_Reticle:Show(true)
	self.w.Tab_General:SetCheck(false)
	self.w.Tab_Reticle:SetCheck(true)
end

-- Update all text in config window
local bSettingsInit = false
function Lockdown:UpdateConfigUI()
	local s, w = self.settings, self.w
	if not bSettingsInit then
		bSettingsInit = true
		-- Load settings window
		self.wndOptions = Apollo.LoadForm("Lockdown.xml", "Lockdown_OptionsForm", nil, self)
		-- Reference all children by name
		self.w = children_by_name(self.wndOptions)
		w = self.w

		-- Options children cache
		--[=[ 	w = setmetatable({}, {__index = function(t, k)
				local child = self.wndOptions:FindChild(k)
				if child then
					rawset(t, k, child)
				end
				return child
			end})
			self.xml = nil--]=]

		-- Map elements matching Prefix_{setting} to settings
		--  in given element_map table
		-- Add desired events to those elements
		local match, format = string.match, string.format
		local function SetUpElements(element_prefix, element_map, event_map, setting_suffix)
			-- Search for elements matching prefix
			local pattern = "^"..element_prefix.."_(.+)$"
			for name, elem in pairs(w) do
				local found = match(name, pattern)
				if found then
					-- Confirm existing setting
					local setting = setting_suffix and format("%s_%s", found, setting_suffix) or found
					if self.defaults[setting] ~= nil then
						-- Map
						element_map[name] = setting
						-- Add event handlers
						for event, handler in pairs(event_map) do
							elem:AddEventHandler(event, handler, self)
						end
						-- Localization
						if L[setting] then
							if element_prefix == "Check" then
								elem:SetText(L[setting])
							elseif element_prefix == "Slider" then
								w["Widget_"..setting]:SetText(L[setting])
							end
						 elseif element_prefix == "Key" and L[found] then
							w["Widget_"..found]:SetText(L[found])
						end
					else
						print("Element not bound", name, setting)
					end
				end
			end
		end

		-- Checkboxes
		SetUpElements("Check", tCheckboxMap, { ButtonCheck = "OnButtonCheck", ButtonUncheck = "OnButtonCheck" })

		-- Binding keys
		SetUpElements("Key", tBindKeyMap, { ButtonSignal = "OnBindKey" }, "key")

		-- Binding modifiers
		SetUpElements("Mod", tBindModMap, { ButtonSignal = "OnBindMod" }, "mod")

		-- Sliders
		SetUpElements("Slider", tSliderMap, { SliderBarChanged = "OnSlider" })

		-- Blunt localization
		for k,v in pairs(w) do
			if L[k] then
				v:SetText(L[k])
			end
		end

		-- Default tab
		self:OnTab_General()
	end

	-- Update checkboxes
	for name, setting in pairs(tCheckboxMap) do
		w[name]:SetCheck(s[setting])
	end
	-- Update key bind buttons
	self.bind_mode_active = false
	for name, setting in pairs(tBindKeyMap) do
		BindKeySetText(w[name], setting)
		w[name]:SetCheck(false)
	end
	-- Update key modifier buttons
	for name, setting in pairs(tBindModMap) do
		w[name]:SetText(s[setting] or L.button_label_mod)
	end
	-- Update sliders
	for name, setting in pairs(tSliderMap) do
		w[name]:SetValue(s[setting])
		self:UpdateWidget_Slider(w[name], setting)
	end

	self.w.Btn_Unbind:Show(false)
end


----------------------------------------------------------
-- Keybind handling

-- Store key and modifier check function
local locktarget_key, locktarget_mod, manualtarget_key, manualtarget_mod
local function Upvalues(whichkey, whichmod)
	local mod = opt[whichmod]
	if mod == "shift" then
		mod = Apollo.IsShiftKeyDown
	elseif mod == "control" then
		mod = Apollo.IsControlKeyDown
	else
		mod = false
	end
	return opt[whichkey], mod
end

function Lockdown:KeyOrModifierUpdated()
	locktarget_key, locktarget_mod = Upvalues("locktarget_key", "locktarget_mod")
	manualtarget_key, manualtarget_mod = Upvalues("manualtarget_key", "manualtarget_mod")
end

-- Keys

function Lockdown:EventHandler_SystemKeyDown(iKey, ...)
	-- Listen for key to bind
	if self.bind_mode_active and iKey ~= 0xF1 and iKey ~= 0xF2 then
		self.bind_mode_active = false
		self:ChangeSetting(sWhichBind, iKey)
		self:KeyOrModifierUpdated()
		self:UpdateConfigUI()
		return
	end

	-- Manual target
	if iKey == manualtarget_key and (not manualtarget_mod or manualtarget_mod()) then
		if uCurrentTarget then
			GameLib.SetTargetUnit(uCurrentTarget)
		end

	-- Open options on Escape
	-- TODO: Pause locking for a short time after pressing escape
	elseif iKey == 27 and LOCK_STATE then
		PAUSED = true
		self.timerEscResume:Start()

	-- Lock target
	elseif iKey == locktarget_key and (not locktarget_mod or locktarget_mod()) then
		if uLockedTarget then
			uLockedTarget = nil
			system_print(L.message_target_unlocked)
		-- TODO: Locked target indicator instead of clearing target
		else
			uLockedTarget = GameLib.GetTargetUnit()
			if uLockedTarget and uLockedTarget:IsValid() then
				system_print((L.message_target_locked):format(uLockedTarget:GetName()))
			end
		end
	end
end

function Lockdown:TimerHandler_EscResume()
	PAUSED = false
end

function Lockdown:TimerHandler_DelayedTarget()
end

function Lockdown:EventHandler_TargetUnitChanged()
	if not GameLib.GetTargetUnit() then
		-- Simple method to prevent target spamming on untargetable mobs
		-- if uLastAutoTarget and nLastTargetFrame == FRAME then
		if uLastAutoTarget and nLastTargetTick == Apollo.GetTickCount() then
			local uid = uLastAutoTarget:GetId()
			if uid then
				onscreen[uid] = nil
				inrange[uid] = nil
				suspended[uid] = os.time() + 5
			end
		end
		uCurrentTarget = nil
	end
	if uLockedTarget then
		uLockedTarget = nil
		system_print(L.message_target_unlocked)
	end
end

local iSlow = 0
-- Apparently fired every four frames
function Lockdown:EventHandler_VarChange_FrameCount(_, nFrame)
	-- Track state and manage reticle
	local bState = GameLib.IsMouseLockOn()
	if bState ~= LOCK_STATE then
		LOCK_STATE = bState
		self.wndReticle:Show(bState and self.settings.reticle_show)
	end

	-- Evaluate inrange units for a new target
	if bState and not PAUSED then
		self:UpdateReticleTarget()
	end

	-- Low rate updates
	iSlow = iSlow + 1
	-- if iSlow >= nSlowUpdateRate then
	if iSlow >= 4 then
		iSlow = 0
		if PLAYER then
			-- Update marker distances
			if LOCK_STATE then
				local origin = PLAYER:GetPosition()
				local limit = self.settings.reticle_range_limit
				for uid, unit in pairs(onscreen) do
					local p = onscreen[uid]:GetPosition()
					if p then
						if Vector3.New(p.x - origin.x, p.y - origin.y, p.z - origin.z):Length() < limit then
							if not inrange[uid] then
								inrange[uid] = unit
							end
						elseif inrange[uid] then
							inrange[uid] = nil
						end
					end
				end
			end
			-- Update suspension list
			if next(suspended) then
				local now = os.time()
				for uid, expires in pairs(suspended) do
					if expires < now then
						suspended[uid] = nil
						self:Handler_ProcessUnit(GameLib.GetUnitById(uid))
					end
				end
			end
		else
			-- Player is invalid on initial addon load
			-- A UnitCreated event is not fired on initial load
			-- It is also invalidated on changing worlds, but does get
			-- a UnitCreated there. So we'll just timer it instead.
			local player = GameLib.GetPlayerUnit()
			if player and player:IsValid() then
				PLAYER = player
				-- Process buffer
				for i=#buffered,1,-1 do
					self:Handler_ProcessUnit(buffered[i])
					buffered[i] = nil
				end
				-- Update player information
				local nPath = PlayerPathLib.GetPlayerPathType()
				g_isScientist = nPath == 2
				g_isSettler = nPath == 1
			end
		end
	end
end


----------------------------------------------------------
-- Reticles

-- Adjust reticle
function Lockdown:Reticle_Update()
	local s = self.settings
	-- local n = self.reticles[s.reticle_sprite] / 2
	local n = s.reticle_size / 2
	local rox, roy = s.reticle_offset_x, s.reticle_offset_y
	self.wndReticleSpriteTarget:SetAnchorOffsets(-n + rox, -n + roy, n + rox, n + roy)
	self.wndReticleSpriteTarget:SetOpacity(s.reticle_opacity)
	self.wndReticleSpriteTarget:SetSprite("reticles:"..s.reticle_sprite)
	self.wndReticleSpriteTarget:SetBGColor(CColor.new(s.reticle_hue_red, s.reticle_hue_green, s.reticle_hue_blue))

	local size = Apollo.GetDisplaySize()
	local ret_x, ret_y = size.nWidth/2 + rox, size.nHeight/2 + roy
	pReticle = Vector2.New(ret_x, ret_y)
	nReticleRadius = n
end

function Lockdown:AddReticle(name, path, size)
	local tSpriteXML = {
		__XmlNode = "Sprites", {
			__XmlNode = "Sprite", Name = name, Cycle = 1, {
				__XmlNode = "Frame", Texture = path,
				x0 = 0, x2 = 0, x3 = 0, x4 = 0, x5 = size,
				y0 = 0, y2 = 0, y3 = 0, y4 = 0, y5 = size,
				HotSpotX = 0, HotSpotY = 0, Duration = 1.0,
				StartColor = "white", EndColor = "white", Stretchy = 1
			}
		}
	}
	Apollo.LoadSprites(XmlDoc.CreateFromTable(tSpriteXML), "reticles")
	self.reticles[name] = size
end

-- I don't want this at the top.
SystemKeyMap = {
	[8] = "Backspace",
	[9] = "Tab",
	[13] = "Enter",
	[16] = "Shift",
	[17] = "Ctrl",
	[19] = "Pause",
	[20] = "CapsLock",
	[27] = "Esc",
	[32] = "Space",
	[33] = "PgUp",
	[34] = "PgDn",
	[35] = "End",
	[36] = "Home",
	[37] = "Left",
	[38] = "Up",
	[39] = "Right",
	[40] = "Down",
	[45] = "Insert",
	[46] = "Delete",
	[48] = "0",
	[49] = "1",
	[50] = "2",
	[51] = "3",
	[52] = "4",
	[53] = "5",
	[54] = "6",
	[55] = "7",
	[56] = "8",
	[57] = "9",
	[65] = "a",
	[66] = "b",
	[67] = "c",
	[68] = "d",
	[69] = "e",
	[70] = "f",
	[71] = "g",
	[72] = "h",
	[73] = "i",
	[74] = "j",
	[75] = "k",
	[76] = "l",
	[77] = "m",
	[78] = "n",
	[79] = "o",
	[80] = "p",
	[81] = "q",
	[82] = "r",
	[83] = "s",
	[84] = "t",
	[85] = "u",
	[86] = "v",
	[87] = "w",
	[88] = "x",
	[89] = "y",
	[90] = "z",
	[96] = "Numpad0",
	[97] = "Numpad1",
	[98] = "Numpad2",
	[99] = "Numpad3",
	[100] = "Numpad4",
	[101] = "Numpad5",
	[102] = "Numpad6",
	[103] = "Numpad7",
	[104] = "Numpad8",
	[105] = "Numpad9",
	[106] = "NumpadMult",
	[107] = "NumpadAdd",
	[109] = "NumpadSub",
	[110] = "NumpadDot",
	[111] = "NumpadDiv",
	[112] = "F1",
	[113] = "F2",
	[114] = "F3",
	[115] = "F4",
	[116] = "F5",
	[117] = "F6",
	[118] = "F7",
	[119] = "F8",
	[120] = "F9",
	[121] = "F10",
	[122] = "F11",
	[123] = "F12",
	[144] = "Num Lock",
	[145] = "Scroll Lock",
	[186] = ";",
	[187] = "=",
	[188] = ",",
	[189] = "-",
	[190] = ".",
	[191] = "/",
	[192] = "`",
	[219] = "[",
	[220] = [[\]],
	[221] = "]",
	[222] = "'",
}

Lockdown:Init()
