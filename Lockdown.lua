-- Addon authors or Carbine, to add a window to the list of pausing windows, call this for normal windows
-- Event_FireGenericEvent("CombatMode_RegisterPausingWindow", wndHandle[, bCheckOften])

-- Lockdown automatically detects immediately created escapable windows, but redundant registration is not harmful.


----------------------------------------------------------
-- Window lists

-- Add windows that don't close on escape here
-- Many Carbine windows must be caught via event handlers
-- since they get recreated and handles go stale. 
local tAdditionalWindows = {
	"RoverForm",
	"GeminiConsoleWindow",
	"KeybindForm",
	"DuelRequest",
	-- Necessary?
	"RoleConfirm",
	"JoinGame",
	"VoteKick",
	"VoteSurrender",
	"AddonError",
	"ResurrectDialog",
	"ExitInstanceDialog",
	"GuildDesignerForm",
	"SupplySachelForm",
	"ViragsSocialMainForm",
}

-- Add windows to ignore here
local tIgnoreWindows = {
	-- Floating text panes
	StoryPanelInformational = true,
	StoryPanelBubble = true,
	StoryPanelBubbleCenter = true,
	-- ProcsHUD
	ProcsIcon1 = true,
	ProcsIcon2 = true,
	ProcsIcon3 = true,
	-- ?
	LootNotificationForm = true,
	-- Clairvoyance mod, whose windows are all escapable for no good reason
	ClairvoyanceNotification = true,
	DisorientWindow = true,
	WeaponIndicator = true,
	-- Killing blow mod
	KillingBlowAlert = true,
	-- ZInterrupt
	InterruptProgress = true,
}

-- Add windows to be checked at a high rate here
local tHotList = {
	SpaceStashInventoryForm = true,
	InventoryBag = true,
	ProgressLogForm = true,
	QuestWindow = true,
	ZoneMapFrame = true,
	QuestWindow_Metal = true,
	QuestWindow_Holo = true,
}


----------------------------------------------------------
-- Localization

local tLocalization = {
	en_us = {
		button_configure = "Lockdown",
		button_label_bind = "Click to change",
		button_label_bind_wait = "Press new key",
		button_label_mod = "Modifier",

		Title_tweaks = "Tweaks",
		mouselockrebind = "Orange settings require included ahk script, read the Lockdown Curse page for details. Orange and yellow settings require a UI reload to take effect.",

		togglelock = "Toggle Lockdown",
		locktarget = "Lock/Unlock current target",
		manualtarget = "Manual target",
		Widget_free_with = "Free cursor while holding..",
		free_also_toggles = "Free cursor acts as toggle (Unfinished)",
		lock_on_load = "Lock on startup",
		ahk_cursor_center = "Center cursor on lock",
		ahk_update_interval = "AHK update interval [ms]",
		auto_target = "Reticle targeting",
		auto_target_delay = "Reticle target delay",
		reticle_show = "Show reticle",
		reticle_opacity = "Reticle opacity",
		reticle_size = "Reticle size",
		reticle_offset_y = "Vert offset (not targeting)",
		reticle_offset_x = "Horiz offset (not targeting)",
		reticle_hue_red = "Reticle hue (Red)",
		reticle_hue_green = "Reticle hue (Green)",
		reticle_hue_blue = "Reticle hue (Blue)",
	}
}
local L = setmetatable({}, {__index = tLocalization.en_us})

-- System key map
-- I don't even know who this is from
-- Three different mods have three different versions
local SystemKeyMap
local bActiveIntent


----------------------------------------------------------
-- Settings

-- Defaults
local Lockdown = {
	defaults = {
		lock_on_load = true,
		togglelock_key = 192, -- `
		togglelock_mod = false,
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
		auto_target_neutral = true,
		auto_target_hostile = true,
		auto_target_friendly = true,
		auto_target_delay = 0,
		reticle_opacity = 0.3,
		reticle_size = 32,
		reticle_sprite = "giznat",
		reticle_offset_x = 0,
		reticle_offset_y = 0,
		reticle_hue_red = 1,
		reticle_hue_blue = 1,
		reticle_hue_green = 1,

		ahk_lmb_key = 189, -- -
		ahk_rmb_key = 187, -- =
		ahk_mmb_key = "",
		ahk_cursor_center = true,
		ahk_update_interval = 100,
	},
	settings = {},
	reticles = {}
}

setmetatable(Lockdown.settings, {__index = Lockdown.defaults})


----------------------------------------------------------
-- TinyAsync, because WildStar

local TinyAsync = { timers = {}, i = 0 }
function TinyAsync:Wait(fCondition, fAction, nfDelay)
	local i = self.i
	local timer = ApolloTimer.Create(nfDelay or 0.1, true, "Timer_"..i, self)
	self.timers[i] = timer
	-- Apparently ApolloTimer doesn't like numerical function keys
	self["Timer_"..i] = function()
		if fCondition() then
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

TinyAsync:Wait(function() return ChatAddon and ChatAddon.tWindow end, function()
	function print(...)
		local out = {}
		for i=1,select('#', ...) do
			table.insert(out, tostring(select(i, ...)))
		end
		Print(table.concat(out, " "))
	end
	-- Process and clear buffer
	for i,v in ipairs(print_buffer) do
		print(unpack(v))
	end
	print_buffer = nil
end, 1)


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
-- Because Carbine does it

function Lockdown:Init()
	Apollo.RegisterAddon(self, true, L.button_configure)
	Apollo.RegisterEventHandler("UnitCreated", "PreloadHandler_UnitCreated", self)
end


----------------------------------------------------------
-- Easy event handlers

-- Register a window update for a given event
function Lockdown:AddWindowEventListener(sEvent, sName)
	local sHandler = "AutoEventHandler_"..sEvent
	Apollo.RegisterEventHandler(sEvent, sHandler, self)
	self[sHandler] = function(self_)
		local wnd = Apollo.FindWindowByName(sName)
		if wnd then
			self_:RegisterWindow(wnd)
		end
	end
end

-- Register a delayed window update for a given event
local tDelayedWindows = {}
function Lockdown:AddDelayedWindowEventListener(sEvent, sName)
	local sHandler = "AutoEventHandler_"..sEvent
	Apollo.RegisterEventHandler(sEvent, sHandler, self)
	self[sHandler] = function(self_)
		tDelayedWindows[sName] = true
		Lockdown.timerDelayedFrameCatch:Start()
	end
end


----------------------------------------------------------
-- Saved data

function Lockdown:OnSave(eLevel)
	if eLevel == GameLib.CodeEnumAddonSaveLevel.General then
		local s = self.settings
		s.ahk_lmb = SystemKeyMap[s.ahk_lmb_key] or ""
		s.ahk_rmb = SystemKeyMap[s.ahk_rmb_key] or ""
		s.ahk_mmb = SystemKeyMap[s.ahk_mmb_key] or ""
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
		self.timerDelayedTarget:Set(s.auto_target_delay / 1000, false)
		-- Show settings window after reload
		if tData._is_ahk_reload then
			self:OnConfigure()
		end
		self:SetActionMode(s.lock_on_load)
	end
end

local preload_units, is_scientist, player = {}
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
	Apollo.RegisterEventHandler("ResolutionChanged", "Reticle_Update", self)


	----------------------------------------------------------
	-- Options
	Apollo.RegisterSlashCommand("lockdown", "OnConfigure", self)


	----------------------------------------------------------
	-- Targeting

	Apollo.RegisterEventHandler("TargetUnitChanged", "EventHandler_TargetUnitChanged", self)
	self.timerRelock = ApolloTimer.Create(0.01, false, "TimerHandler_Relock", self)
	self.timerRelock:Stop()
	self.timerDelayedTarget = ApolloTimer.Create(1, false, "TimerHandler_DelayedTarget", self)
	self.timerDelayedTarget:Stop()


	----------------------------------------------------------
	-- Automatic [un]locking

	-- Crawl for frames to hook
	self.timerFrameCrawl = ApolloTimer.Create(5.0, false, "TimerHandler_FrameCrawl", self)

	-- Wait for windows to be created or re-created
	self.timerDelayedFrameCatch = ApolloTimer.Create(0.1, false, "TimerHandler_DelayedFrameCatch", self)
	self.timerDelayedFrameCatch:Stop()

	-- Poll frames for visibility.
	-- I'd much rather use hooks or callbacks or events, but I can't hook, I can't find the right callbacks/they don't work, and the events aren't consistant or listed. 
	-- You made me do this, Carbine.
	self.timerColdPulse = ApolloTimer.Create(0.5, true, "TimerHandler_ColdPulse", self)
	self.timerHotPulse = ApolloTimer.Create(0.2, true, "TimerHandler_HotPulse", self)


	----------------------------------------------------------
	-- Windows and their relevant events

	Apollo.RegisterEventHandler("CombatMode_RegisterPausingWindow", "RegisterWindow", self)

	-- These windows are created or re-created and must be caught with event handlers
	-- Abilities builder
	self:AddWindowEventListener("AbilityWindowHasBeenToggled", "AbilitiesBuilderForm")
	-- Social panel
	self:AddWindowEventListener("GenericEvent_InitializeFriends", "SocialPanelForm")
	-- Lore window
	self:AddWindowEventListener("HudAlert_ToggleLoreWindow", "LoreWindowForm")
	self:AddWindowEventListener("InterfaceMenu_ToggleLoreWindow", "LoreWindowForm")
	-- Guild windows
	self:AddDelayedWindowEventListener("GuildBankerOpen", "GuildBankForm")
	self:AddDelayedWindowEventListener("Guild_ToggleInfo", "GuildInfoForm")
	self:AddDelayedWindowEventListener("Guild_TogglePerks", "GuildPerksForm")
	self:AddDelayedWindowEventListener("Guild_ToggleRoster", "GuildRosterForm")
	-- Crafting grid
	self:AddDelayedWindowEventListener("GenericEvent_StartCraftingGrid", "CraftingGridForm")
	-- Runecrafting
	self:AddDelayedWindowEventListener("GenericEvent_CraftingResume_OpenEngraving", "RunecraftingForm")
	-- Tradeskill trainer
	self:AddDelayedWindowEventListener("InvokeTradeskillTrainerWindow", "TradeskillTrainerForm")
	-- Settler building
	self:AddDelayedWindowEventListener("InvokeSettlerBuild", "BuildMapForm")
	-- Commodity marketplace
	self:AddDelayedWindowEventListener("ToggleMarketplaceWindow", "MarketplaceCommodityForm")
	-- Auctionhouse
	self:AddDelayedWindowEventListener("ToggleAuctionWindow", "MarketplaceAuctionForm")
	-- CREDD
	self:AddDelayedWindowEventListener("ToggleCREDDExchangeWindow", "MarketplaceCREDDForm")
	-- Instance settings
	self:AddDelayedWindowEventListener("ShowInstanceGameModeDialog", "InstanceSettingsForm")
	self:AddDelayedWindowEventListener("ShowInstanceRestrictedDialog", "InstanceSettingsRestrictedForm")
	-- Public events
	self:AddDelayedWindowEventListener("PublicEventInitiateVote", "PublicEventVoteForm")
	self:AddDelayedWindowEventListener("PublicEventStart", "PublicEventStatsForm")
	self:AddDelayedWindowEventListener("GenericEvent_OpenEventStatsZombie", "PublicEventStatsForm")
	-- Match Tracker / PVP Score
	self:AddDelayedWindowEventListener("Datachron_LoadPvPContent", "MatchTracker")
	-- Bank
	self:AddDelayedWindowEventListener("ShowBank", "BankViewerForm")
	self:AddDelayedWindowEventListener("ToggleBank", "BankViewerForm")
	

	----------------------------------------------------------
	-- Keybinds

	Apollo.RegisterEventHandler("SystemKeyDown", "EventHandler_SystemKeyDown", self)
	self.timerFreeKeys = ApolloTimer.Create(0.1, true, "TimerHandler_FreeKeys", self)

	-- Rainbows, unicorns, and kittens
	-- Oh my
	self:KeyOrModifierUpdated()


	----------------------------------------------------------
	-- Defer advanced targeting startup
	if self.settings.auto_target then
		self.timerHAL = ApolloTimer.Create(0.05, true, "TimerHandler_HAL", self)
		self.timerHAL:Stop()

		TinyAsync:Wait(function()
			player = GameLib.GetPlayerUnit()
			return player and player:IsValid()
		end,
		function()
			-- Get player path
			is_scientist = PlayerPathLib.GetPlayerPathType() == 2
			-- Update event registration
			Apollo.RemoveEventHandler("UnitCreated", self)
			Apollo.RegisterEventHandler("UnitCreated", "EventHandler_UnitCreated", self)
			Apollo.RegisterEventHandler("UnitDestroyed", "EventHandler_UnitDestroyed", self)
			Apollo.RegisterEventHandler("UnitGibbed", "EventHandler_UnitDestroyed", self)
			-- Process pre-load units
			for i,v in ipairs(preload_units) do
				self:EventHandler_UnitCreated(v)
			end
			preload_units = nil
			self.HALReady = true
			-- Initial locked timer
			if GameLib.IsMouseLockOn() then
				self:StartHAL()
			end
		end)
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
	table.insert(preload_units, unit)
end

local markers = {}
local onscreen = {}

-- Store category of marker
function Lockdown:EventHandler_UnitCreated(unit)
	local id = unit:GetId()
	-- Invalid or existing markers
	if not id or markers[id] or not unit:IsValid() or unit:IsThePlayer() then return nil end
	local utype = unit:GetType()
	-- Filter units
	--  Players (Except Player)
	if utype == "Player" or utype == "NonPlayer" or unit:GetRewardInfo()
		-- NPCs that get plates
		-- or ((utype == "NonPlayer" or utype == "Turret") and unit:ShouldShowNamePlate())
		-- Harvestable nodes (Except farming)
		or (utype == "Harvest" and unit:GetHarvestRequiredTradeskillName() ~= "Farmer" and unit:CanBeHarvestedBy(GameLib.GetPlayerUnit()))
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

	if GameLib.GetUnitScreenPosition(unit).bOnScreen then
		self:EventHandler_WorldLocationOnScreen(nil, marker, true)
	end
end

function Lockdown:EventHandler_UnitDestroyed(unit)
	local id = unit:GetId()
	if markers[id] then
		markers[id]:Destroy()
		markers[id] = nil
	end
	if onscreen[id] then
		onscreen[id] = nil
	end
	if GameLib.IsMouseLockOn() and unit == GameLib.GetTargetUnit() then
		uCurrentTarget, uLastTarget = nil, nil
		GameLib.SetTargetUnit()
	end
end

local function IsUnitInteresting(unit)
	local reward = unit:GetRewardInfo()
	if reward and reward[1] then
		for k,v in pairs(reward) do
			if (v.strType == "Quest" and v.nCompleted and v.nCompleted < v.nNeeded)
				 or (v.strType == "Scientist" and is_scientist) then
				return true
			end
		end
	end
	return false
end

function Lockdown:EventHandler_WorldLocationOnScreen(wnd, ctrl, visible)
	local unit = ctrl:GetData()
	if unit:IsValid() and not unit:IsDead() then
		if visible and ((unit:ShouldShowNamePlate() and self.tTargetDispositions[unit:GetDispositionTo(player)]) or IsUnitInteresting(unit)) then
			onscreen[unit:GetId()] = unit
		else
			onscreen[unit:GetId()] = nil
		end
	else
		self:EventHandler_UnitDestroyed(unit)
	end
end

-- Scan lists of markers in order of priority based on current state
 -- If reticle center within range of unit center (reticle size vs estimated object size)
 -- If object meets criteria (Node range, ally health)
local pReticle, nReticleRadius
local nLastTargetTime, uLastTarget, uDelayedTarget, uCurrentTarget = 0
function Lockdown:TimerHandler_HAL()
	if not player then return end
	local nTargetTimeDelta = os.clock() - nLastTargetTime
	if nTargetTimeDelta < 0.2 then return end -- Throttle target flickering
	-- Grab local references to things we're going to use each iteration
	local NewPoint, PointLength = Vector2.New, pReticle.Length
	local GetUnitScreenPosition = GameLib.GetUnitScreenPosition
	local GetOverheadAnchor, GetType = player.GetOverheadAnchor, player.GetType
	uCurrentTarget = GameLib.GetTargetUnit()
	-- Iterate over onscreen units
	for id, unit in pairs(onscreen) do
		local tPos = GetUnitScreenPosition(unit)
		-- Destroy player markers we shouldn't be getting
		if unit == player or unit:IsDead() then
			self:EventHandler_UnitDestroyed(unit)
		-- Verify that unit is still on screen
		elseif tPos and tPos.bOnScreen and not unit:IsOccluded() then
			-- Try to place unit point in middle of unit
			local pOverhead, nUnitRadius = GetOverheadAnchor(unit), 0
			if pOverhead then
				nUnitRadius = (tPos.nY - pOverhead.y)/2
			end
			local pUnit = NewPoint(tPos.nX, tPos.nY - nUnitRadius)
			-- Check reticle intersection
			-- TODO: Re-add delayed targeting
			if PointLength(pUnit - pReticle) < (nUnitRadius + nReticleRadius) then
				if not uCurrentTarget or (uCurrentTarget ~= unit and (uLastTarget ~= unit or nTargetTimeDelta > 15)) then
					GameLib.SetTargetUnit(unit)
					uLastTarget, nLastTargetTime = uCurrentTarget, os.clock()
				end
				return
			end
		end
	end
end


----------------------------------------------------------
-- Frame discovery, handling, and polling

-- Disover frames we should pause for
local tColdWindows, tHotWindows, tWindows = {}, {}, {}
function Lockdown:RegisterWindow(wnd, hot)
	if wnd then
		local sName = wnd:GetName()
		if not tIgnoreWindows[sName] then
			-- Add to window index
			if not tWindows[sName] then
				tWindows[sName] = (tHotList[sName] or hot) and "hot" or "cold"
				end

			-- Add or update handle
			if tWindows[sName] == "hot" then
				tHotWindows[sName] = wnd
			else
				tColdWindows[sName] = wnd
			end
			return true
		end
	end
	return false
end

-- Discover simple unlocking frames
function Lockdown:TimerHandler_FrameCrawl()
	for _,strata in ipairs(Apollo.GetStrata()) do
		for _,wnd in ipairs(Apollo.GetWindowsInStratum(strata)) do
			if wnd:IsStyleOn("Escapable") and not wnd:IsStyleOn("CloseOnExternalClick") then
				Lockdown:RegisterWindow(wnd)
			end
		end
	end
	-- Existing frames that aren't found above
	for _,sName in ipairs(tAdditionalWindows) do
		local wnd = Apollo.FindWindowByName(sName)
		if wnd then
			Lockdown:RegisterWindow(wnd)
		end
	end
end

-- Wait for certain frames to be created or recreated after a event
function Lockdown:TimerHandler_DelayedFrameCatch()
	for sName in pairs(tDelayedWindows) do
		local wnd = Apollo.FindWindowByName(sName)
		if wnd then
			self:RegisterWindow(wnd)
			tDelayedWindows[sName] = nil
		end
	end
end

-- Poll unlocking frames
local free_key_held = false -- User toggling mouse with a modifier key
local tSkipWindows = {}
local bColdSuspend, bHotSuspend = false, false

function Lockdown:PulseCore(t, other_suspend, csi)
	local bWindowUnlock = false
	if not free_key_held then
		local tSkipWindows = tSkipWindows
		-- Poll windows
		for _, wnd in pairs(t) do
			-- Unlock if visible and not currently skipped
			if wnd:IsShown() and wnd:IsValid() then
				if not tSkipWindows[wnd] then
					bWindowUnlock = true
				end
			-- Expire hidden from skiplist
			elseif tSkipWindows[wnd] then
				tSkipWindows[wnd] = nil
			end
		end

		-- CSI(?) dialogs
		-- TODO: Skip inconsequential CSI dialogs (QTEs)
		if csi then
			if CSIsLib.GetActiveCSI() then
				if not tSkipWindows.CSI then
					bWindowUnlock = true
				end
			else
				tSkipWindows.CSI = false
			end
		end

		-- Update lock
		local lock = GameLib.IsMouseLockOn()
		if not (bWindowUnlock or other_suspend or lock) and bActiveIntent then
			self:SetActionMode(true)
		elseif (bWindowUnlock or other_suspend) and lock then
			self:SuspendActionMode()
		end
	end

	return bWindowUnlock
end

function Lockdown:TimerHandler_ColdPulse()
	bColdSuspend = self:PulseCore(tColdWindows, bHotSuspend, true)
end

function Lockdown:TimerHandler_HotPulse()
	bHotSuspend = self:PulseCore(tHotWindows, bColdSuspend)
end

function Lockdown:PollAllWindows()
	self:TimerHandler_HotPulse()
	self:TimerHandler_ColdPulse()
	return bColdSuspend or bHotSuspend
end

function Lockdown:TimerHandler_Relock()
	self:SetActionMode(true)
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

		-- Localize strings
		w.Text_mouselockrebind:SetText(L.mouselockrebind)

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
					if self.settings[setting] ~= nil then
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
		w[name]:SetText(s[setting] and s[setting] or L.button_label_mod)
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
local togglelock_key, togglelock_mod, locktarget_key, locktarget_mod, manualtarget_key, manualtarget_mod
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
	togglelock_key, togglelock_mod = Upvalues("togglelock_key", "togglelock_mod")
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
	
	-- Use vkeys to avoid overlapping player input
	elseif iKey == 0xF1 then
		self:SetActionMode(true, true)
	elseif iKey == 0xF2 and not free_key_held then
		self:SetActionMode(false, true)

	-- Manual target
	elseif iKey == manualtarget_key and (not manualtarget_mod or manualtarget_mod()) then
		if uCurrentTarget then
			GameLib.SetTargetUnit(uCurrentTarget)
		end

	-- Toggle mode
	elseif iKey == togglelock_key and (not togglelock_mod or togglelock_mod()) then
		-- Save currently active windows and resume
		if bActiveIntent and not GameLib.IsMouseLockOn() then
			wipe(tSkipWindows)

			for _,wnd in pairs(tColdWindows) do
				if wnd:IsShown() then
					tSkipWindows[wnd] = true
				end
			end
			for _,wnd in pairs(tHotWindows) do
				if wnd:IsShown() then
					tSkipWindows[wnd] = true
				end
			end

			if CSIsLib.GetActiveCSI() then
				tSkipWindows.CSI = true
			end
			self:SetActionMode(true)
		else
			-- Toggle
			self:SetActionMode(not bActiveIntent)
		end
	
	-- Lock target
	elseif iKey == locktarget_key and (not locktarget_mod or locktarget_mod()) then
		if uLockedTarget then
			uLockedTarget = nil
			-- TODO: Locked target indicator instead of clearing target
		else
			uLockedTarget = GameLib.GetTargetUnit()
		end
	end
end

-- Watch for modifiers to toggle mouselock
function Lockdown:TimerHandler_FreeKeys()
	local old = free_key_held
	free_key_held = ((self.settings.free_with_shift and Apollo.IsShiftKeyDown())
		or (self.settings.free_with_ctrl and Apollo.IsControlKeyDown())
		or (self.settings.free_with_alt and Apollo.IsAltKeyDown()))

	-- If status has changed
	-- This now clashes with the entirely external MouselockRebind. It doesn't know if we need a relock or not and so doesn't really work with free_also_toggles
	if old ~= free_key_held then
		-- If we are now holding the key
		if free_key_held then
			-- If the mouse is already locked, suspend lock
			if GameLib.IsMouseLockOn() then
				self:SuspendActionMode()
			-- If the mouse isn't locked but we want to toggle, force it
			elseif self.settings.free_also_toggles then
				self:ForceActionMode()
			end
		-- If we let go of the key and lock doesn't match intent
		elseif GameLib.IsMouseLockOn() ~= bActiveIntent then
			-- If we want to be locked and aren't paused otherwise
			if bActiveIntent and not (self:PulseCore(tHotWindows) or self:PulseCore(tColdWindows, true)) then
				self:SetActionMode(true)
			-- If we were locked and don't intend to be locked, unlock
			elseif not bActiveIntent then
				self:SetActionMode(false)
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
		uLastTarget = nil
	end
	uLockedTarget = nil
end


----------------------------------------------------------
-- Mode setters

-- Action mode toggle
function Lockdown:SetActionMode(bState)
	bActiveIntent = bState
	if GameLib.IsMouseLockOn() ~= bState then
		GameLib.SetMouseLock(bState)
	end
	if bState then
		self:StartHAL()
	else
		self:StopHAL()
		bHotSuspend = false
		bColdSuspend = false
	end
	self.wndReticle:Show(bState and self.settings.reticle_show)
	-- TODO: Sounds
end

-- Force without enabling
function Lockdown:ForceActionMode()
	if not GameLib.IsMouseLockOn() then
		GameLib.SetMouseLock(true)
		self.wndReticle:Show(true)
		self:StartHAL()
	end
	-- TODO: Indicate inactive-but-enabled status
end

-- Suspend without disabling
function Lockdown:SuspendActionMode()
	if GameLib.IsMouseLockOn() then
		GameLib.SetMouseLock(false)
		self.wndReticle:Show(false)
		self:StopHAL()
	end
	-- TODO: Indicate active-but-suspended status
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
