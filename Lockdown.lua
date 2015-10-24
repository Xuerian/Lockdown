-- Lockdown contains a significant amount of code providing a expanded targeting system around a user-positioned reticle, since we cannot reposition the mouseover location.
-- It must account for a few complications with the API to do so:
-- Units are not well classified as units the player should care about or should be able to target, by default
-- All units may be targeted with GameLib.SetTargetUnit(unit), but invalid targets are immediately un-targeted. This is the process in that case:
-- GameLib.SetTargetUnit(unit) called (It returns true or false based on if the player can target anything at the current time, not if the player can target [unit])
--  "UnitCreated" and "TargetUnitChanged" are called during this call, and finish before it returns
--  "TargetUnitChanged" is then called after it returns, inside the current frame.

----------------------------------------------------------
-- Localization

local tLocalization = {
	en_us = {
		button_configure = "Lockdown",
		button_label_bind = "Click to change",
		button_label_bind_wait = "Press new key",
		button_label_mod = "No modifier",

		Title_tweaks = "Tweaks",
		Text_mouselockrebind = "Orange settings require included ahk script, read the Lockdown Curse page for details. Orange and yellow settings require a UI reload to take effect.",

		togglelock = "Toggle Lockdown",
		locktarget = "Lock/Unlock current target",
		manualtarget = "Manual target",
		auto_target = "Reticle targeting",
		reticle_show = "Show reticle",
		auto_target_delay = "Reticle target delay",
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
		manualtarget_key = 84, -- T
		manualtarget_mod = "control",
		free_with_shift = false,
		free_with_ctrl = false,
		free_with_alt = true,
		free_also_toggles = false,
		reticle_show = true,
		auto_target = true,
		auto_target_neutral = false,
		auto_target_hostile = true,
		auto_target_friendly = false,
		auto_target_settler = false,
		auto_target_delay = 0,
		auto_target_interval = 100,
		reticle_opacity = 0.3,
		reticle_size = 32,
		reticle_sprite = "giznat",
		reticle_offset_x = 0,
		reticle_offset_y = 0,
		reticle_hue_red = 1,
		reticle_hue_blue = 1,
		reticle_hue_green = 1,
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
	self:RegisterEventHandler("UnitCreated", "PreloadHandler_UnitCreated")
end





----------------------------------------------------------
-- Saved data

function Lockdown:OnSave(eLevel)
	if eLevel == GameLib.CodeEnumAddonSaveLevel.General then
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
	if eLevel == GameLib.CodeEnumAddonSaveLevel.General and tData then
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
function Lockdown:OnLoad()
	----------------------------------------------------------
	-- Load reticle

	self.xmlDoc = XmlDoc.CreateFromFile("Lockdown.xml")
	self.wndReticle = Apollo.LoadForm(self.xmlDoc, "Lockdown_ReticleForm", "InWorldHudStratum", nil, self)
	self.wndReticleSpriteTarget = self.wndReticle:FindChild("Lockdown_ReticleSpriteTarget")

	-- Add reticles
	self:AddReticle("tiny", [[Lockdown\reticles\tiny.png]], 128)
	self:AddReticle("giznat", [[Lockdown\reticles\giznat.png]], 128)
	self:Reticle_Update()
	self.wndReticle:Show(GameLib.IsMouseLockOn())
	self:RegisterEventHandler("ResolutionChanged", "Reticle_Update")


	----------------------------------------------------------
	-- Options

	Apollo.RegisterSlashCommand("lockdown", "OnConfigure", self)


	----------------------------------------------------------
	-- Targeting

	self:RegisterEventHandler("TargetUnitChanged")
	self.timerRelock = ApolloTimer.Create(0.01, false, "TimerHandler_Relock", self)
	self.timerRelock:Stop()
	self.timerDelayedTarget = ApolloTimer.Create(1, false, "TimerHandler_DelayedTarget", self)
	self.timerDelayedTarget:Stop()

	----------------------------------------------------------
	-- Keybinds

	self:RegisterEventHandler("SystemKeyDown")

	self:KeyOrModifierUpdated()

	-- Apparently initial game load and UnitCreated aren't too reliable..
	if not self.HALReady then
		Alfred:Wait(GameLib.GetPlayerUnit, self.InitHAL)
	end
end

-- HAL init runs when player unit is created
function Lockdown:InitHAL()
	local self = self or Lockdown -- Support normal calling
	if self.HALReady then return end -- Only init once
	self.HALReady = true
	-- Get player path
	local nPath = PlayerPathLib.GetPlayerPathType()
	g_isScientist = nPath == 2
	g_isSettler = nPath == 1
	-- Update event registration
	Apollo.RemoveEventHandler("UnitCreated", self)
	Apollo.RegisterEventHandler("UnitCreated", "EventHandler_UnitCreated", self)
	Apollo.RegisterEventHandler("UnitDestroyed", "EventHandler_UnitDestroyed", self)
	Apollo.RegisterEventHandler("UnitGibbed", "EventHandler_UnitDestroyed", self)
	Apollo.RegisterEventHandler("UnitActivationTypeChanged", "RefreshUnit", self)
	Apollo.RegisterEventHandler("ChangeWorld", "EventHandler_WorldChange", self)
	self:RegisterEventHandler("UnitDestroyed")
	self:RegisterEventHandler("ChangeWorld")
	-- Process pre-load units
	for i=1,#preload_units do
		self:EventHandler_UnitCreated(preload_units[i])
		preload_units[i] = nil
	end
	preload_units = nil
	-- Create timer
	self.timerHAL = ApolloTimer.Create(self.settings.auto_target_interval/1000, true, "TimerHandler_HAL", self)
	-- Initial locked timer
	if GameLib.IsMouseLockOn() or self.settings.auto_target then
		self:StartHAL()
	else
		self:StopHAL()
	end
end

function Lockdown:StartHAL()
	if self.HALReady then
		self.timerHAL:Start()
	end
end

function Lockdown:StopHAL()
	if self.HALReady then
		self.timerHAL:Stop()
	end
end

----------------------------------------------------------
-- Units and Advanced Targeting

function Lockdown:PreloadHandler_UnitCreated(unit)
	if unit:IsThePlayer() then
		return self:InitHAL()
	end
	table.insert(preload_units, unit)
end

local markers = {}
local onscreen = {}
Lockdown.markers = markers
Lockdown.onscreen = onscreen

function Lockdown:RefreshUnit(unit)
	-- Catch newly activateable units
	if not markers[unit:GetId()] then
		self:EventHandler_UnitCreated(unit)
	end
	-- Qualify unit
	self:EventHandler_WorldLocationOnScreen(nil, nil, GameLib.GetUnitScreenPosition(unit).bOnScreen, unit)
end

-- Store category of marker
function Lockdown:EventHandler_UnitCreated(unit)
	local id = unit:GetId()
	-- Invalid or existing markers
	if not id or markers[id] or not unit:IsValid() or unit:IsThePlayer() then return nil end
	local utype = unit:GetType()
	-- Filter units
	--  Players (Except Player)
	if utype == "Player" or utype == "NonPlayer" or unit:GetRewardInfo() or unit:GetActivationState()
		-- NPCs that get plates
		-- or ((utype == "NonPlayer" or utype == "Turret") and unit:ShouldShowNamePlate())
		-- Harvestable nodes (Except farming)
		or (utype == "Harvest" and unit:GetHarvestRequiredTradeskillName() ~= "Farmer" and unit:CanBeHarvestedBy(player))
		then
			-- Ok!
	 -- Quest objective units, scannables
	 -- These are filtered in WorldLocationOnScreen, since they can change.
	-- elseif (utype == "Simple" or utype == "NonPlayer") and unit:GetRewardInfo() then
		-- Ok!
	else return end -- Not ok.
	-- Activate marker
	local marker = Apollo.LoadForm(self.xmlDoc, "Lockdown_Marker", "InWorldHudStratum", self)
	marker:Show()
	marker:SetData(unit)
	marker:SetUnit(unit)
	markers[id] = marker

	self:RefreshUnit(unit)
end

local uCurrentTarget, uLastAutoTarget
function Lockdown:EventHandler_UnitDestroyed(unit)
	local id = unit:GetId()
	if markers[id] then
		markers[id]:Destroy()
		markers[id] = nil
		if unit == uLastAutoTarget and GameLib.IsMouseLockOn() and unit == GameLib.GetTargetUnit() then
			uCurrentTarget = nil
			GameLib.SetTargetUnit()
		end
	end
	if onscreen[id] then
		onscreen[id] = nil
	end
end

function Lockdown:EventHandler_ChangeWorld()
	for uid in pairs(onscreen) do
		onscreen[uid] = nil
	end
	for uid in pairs(markers) do
		markers[uid]:Destroy()
		markers[uid] = nil
	end
end

-- Check a marker (Unit) that just entered or left the screen
--  This function could possibly structured better
--  However, this is the way that most made sense at the time
local eRewardQuest, eRewardScientist = Unit.CodeEnumRewardInfoType.Quest, Unit.CodeEnumRewardInfoType.Scientist
function Lockdown:EventHandler_WorldLocationOnScreen(wnd, ctrl, visible, unit)
	if not unit then unit = ctrl:GetUnit() end
	-- Purge invalid or dead units
	if not unit:IsValid() or unit:IsDead() then
		self:EventHandler_UnitDestroyed(unit)
		return
	-- Visible units
	elseif visible then
		-- Basic relevance
		if unit:ShouldShowNamePlate() and self.tTargetDispositions[unit:GetDispositionTo(GameLib.GetPlayerUnit())] then
			onscreen[unit:GetId()] = unit
			return
		end			
		-- Units we want based on activation state
		local tAct = unit:GetActivationState()
		-- Ignore settler "Minfrastructure"
		-- TODO: Options to include/filter these things
		local bActState = tAct and next(tAct) or false
		if bActState then
			-- Hide already activated quest objects
			if tAct.QuestTarget and not (tAct.Interact and tAct.Interact.bCanInteract) then
				onscreen[unit:GetId()] = nil
				return
			end
			-- Hide settler collection or improvements
			if g_isSettler and not opt.auto_target_settler and (tAct.SettlerMinfrastructure or (tAct.Collect and tAct.Collect.bUsePlayerPath)) then
				onscreen[unit:GetId()] = nil
				return
			end
			-- Generic activateable objects
			local t = tAct.Interact
			if t and (t.bCanInteract or t.bIsHighlightable or t.bShowCallout) then
				onscreen[unit:GetId()] = unit
				return
			end
			-- Quest turn-ins
			if tAct.QuestReward and tAct.QuestReward.bIsActive and tAct.QuestReward.bCanInteract then
				onscreen[unit:GetId()] = unit
				return
			end
			-- Quest starting objects
			if tAct.QuestNew and tAct.QuestNew.bCanInteract then
				onscreen[unit:GetId()] = Unit
				return
			end
			-- Scientist scans
			if g_isScientist then
				-- Datacubes
				if (tAct.Datacube and tAct.Datacube.bIsActive)
				-- Raw scannable items (information constructs)
					or (tAct.ScientistRawScannable and tAct.ScientistRawScannable.bIsActive) then
					onscreen[unit:GetId()] = unit
					return
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
					or (t.nCompleted and t.nCompleted < t.nNeeded and (not bActState or not tAct.Interact or tAct.Interact.bCanInteract))
					-- or scientist scans
					 or (t.eType == eRewardScientist and g_isScientist) then
					onscreen[unit:GetId()] = unit
					return
				end
			end
		end
	end
	-- Invisible or otherwise undesirable units
	onscreen[unit:GetId()] = nil
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

-- Scan lists of markers in order of priority based on current state
 -- If reticle center within range of unit center (reticle size vs estimated object size)
 -- If object meets criteria (Node range, ally health)
local pReticle, nReticleRadius
local uDelayedTarget, uLockedTarget
local nLastTargetTick -- Used to mitigate untargetable units
function Lockdown:TimerHandler_HAL()
	local player = GameLib.GetPlayerUnit()
	if not player or uLockedTarget then return end
	-- Grab local references to things we're going to use each iteration
	local NewPoint, PointLength = Vector2.New, pReticle.Length
	local GetUnitScreenPosition = GameLib.GetUnitScreenPosition
	local GetOverheadAnchor = player.GetOverheadAnchor
	local IsDead, IsOccluded = player.IsDead, player.IsOccluded
	uCurrentTarget = GameLib.GetTargetUnit()
	local nBest, uBest = 999
	-- Iterate over onscreen units
	for id, unit in pairs(onscreen) do
		local tPos = GetUnitScreenPosition(unit)
		-- Destroy markers we shouldn't be getting
		if unit == player or IsDead(unit) then
			self:EventHandler_UnitDestroyed(unit)
		-- Verify that unit is still on screen
		elseif tPos and tPos.bOnScreen and not IsOccluded(unit) then
			-- Try to place unit point in middle of unit
			local pOverhead, nUnitRadius = GetOverheadAnchor(unit), 0
			if pOverhead then
				nUnitRadius = (tPos.nY - pOverhead.y)/2
				-- Sanity check radius
				if nUnitRadius < 0 then
					nUnitRadius = 15
				end
			end
			-- Check reticle intersection
			local nDist = PointLength(NewPoint(tPos.nX, tPos.nY - nUnitRadius) - pReticle)
			if nDist < nBest and nDist < (nUnitRadius + nReticleRadius) then
				-- Verify possibly stale units
				if unit == uLastAutoTarget and not uCurrentTarget then
					-- SendVarToRover("Last lockdown target", unit)
					self:EventHandler_WorldLocationOnScreen(nil, nil, true, unit)
					if onscreen[unit:GetId()] then
						nBest, uBest = nDist, unit
					end
				else
					nBest, uBest = nDist, unit
				end
			end
		end
	end
	-- Target best unit
	-- TODO: Re-add delayed targeting
	if uBest and uCurrentTarget ~= uBest then
		uCurrentTarget, uLastAutoTarget = uBest, uBest
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

function ChangeHandlers.auto_target_delay(value)
	Lockdown.timerDelayedTarget:Set(value, false)
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
	self.settings[setting] = mod
	self:KeyOrModifierUpdated()
	btn:SetText(mod and mod or L.button_label_mod)
end

-- Checkboxes
local tCheckboxMap = {}
function Lockdown:OnButtonCheck(btn)
	self.settings[tCheckboxMap[btn:GetName()]] = btn:IsChecked()
end

-- Sliders
local tSliderMap = {}
function Lockdown:OnSlider(slider)
	local setting, value = tSliderMap[slider:GetName()], slider:GetValue()
	self.settings[setting] = value
	if ChangeHandlers[setting] then
		ChangeHandlers[setting](value)
	end
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
	self.wndOptions:Show(true, true)
end

function Lockdown:OnConfigureClose()
	self.wndOptions:Show(false, true)
end

function Lockdown:OnBtn_Unbind()
	if self.bind_mode_active then
		self.bind_mode_active = false
		self.settings[sWhichBind] = ""
		self:KeyOrModifierUpdated()
		self:UpdateConfigUI()
	end
end

function Lockdown:OnBtn_ReloadUI()
	self.settings._is_ahk_reload = true
	RequestReloadUI()
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
		self:RegisterWindow(self.wndOptions)
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
	local mod = Lockdown.settings[whichmod]
	if mod == "shift" then
		mod = Apollo.IsShiftKeyDown
	elseif mod == "control" then
		mod = Apollo.IsControlKeyDown
	else
		mod = false
	end
	return Lockdown.settings[whichkey], mod
end

function Lockdown:KeyOrModifierUpdated()
	locktarget_key, locktarget_mod = Upvalues("locktarget_key", "locktarget_mod")
	manualtarget_key, manualtarget_mod = Upvalues("manualtarget_key", "manualtarget_mod")
	if self.settings.free_with_alt or self.settings.free_with_ctrl or self.settings.free_with_shift then
		self.timerFreeKeys:Start()
	else
		self.timerFreeKeys:Stop()
	end
end

-- Keys

function Lockdown:EventHandler_SystemKeyDown(iKey, ...)
	-- Listen for key to bind
	if self.bind_mode_active and iKey ~= 0xF1 and iKey ~= 0xF2 then
		self.bind_mode_active = false
		self.settings[sWhichBind] = iKey
		self:KeyOrModifierUpdated()
		self:UpdateConfigUI()
		return
	end

	-- Open options on Escape
	-- TODO: don't reset cursor position when a blocking window is still open
	if iKey == 27 and bActiveIntent then
		if not self:PollAllWindows() then
			if GameLib.GetTargetUnit() then
				GameLib.SetTargetUnit()
				self.timerRelock:Start()
			else
				self:SuspendActionMode()
			end
		end
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

function Lockdown:TimerHandler_DelayedTarget()
	if uDelayedTarget then
		GameLib.SetTargetUnit(uDelayedTarget)
	end
end

function Lockdown:EventHandler_TargetUnitChanged()
	if not GameLib.GetTargetUnit() then
		-- Simple method to prevent target spamming on untargetable mobs
		if uLastAutoTarget and (Apollo.GetTickCount() - nLastTargetTick) == 0 then
			onscreen[uLastAutoTarget:GetId()] = nil
		end
		uCurrentTarget = nil
	end
	if uLockedTarget then
		uLockedTarget = nil
		system_print(L.message_target_unlocked)
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
