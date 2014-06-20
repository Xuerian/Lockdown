-- Addon authors or Carbine, to add a window to the list of pausing windows, call this for normal windows
-- Event_FireGenericEvent("CombatMode_RegisterPausingWindow", wndHandle)

-- Lockdown automatically detects immediately created escapable windows, but redundant registration is not harmful.

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
	"SupplySachelForm"
}

-- Add windows to ignore here
local tIgnoreWindows = {
	StoryPanelInformational = true,
	StoryPanelBubble = true,
	StoryPanelBubbleCenter = true,
	ProcsIcon1 = true,
	ProcsIcon2 = true,
	ProcsIcon3 = true,
	LootNotificationForm = true,
	ClairvoyanceNotification = true,
}

-- Add windows to be checked at a high rate here
local tHotList = {
	SpaceStashInventoryForm = true,
	ProgressLogForm = true,
	QuestWindow = true,
	ZoneMapFrame = true,
}

-- Localization
local tLocalization = {
	en_us = {
		button_configure = "Lockdown",
		button_label_bind = "Click to change",
		button_label_bind_wait = "Press new key",
		button_label_mod = "Modifier"
	}
}
local L = setmetatable({}, {__index = tLocalization.en_us})

-- System key map
-- I don't even know who this is from
-- Three different mods have three different versions
local SystemKeyMap

-- Defaults
local Lockdown = {
	defaults = {
		togglelock_key = 192, -- `
		togglelock_mod = false,
		locktarget_key = 20, -- Caps Lock
		locktarget_mod = false,
		targetmouseover_key = 84, -- T
		targetmouseover_mod = "control",
		free_with_shift = false,
		free_with_ctrl = false,
		free_with_alt = true,
		reticle_show = true,
		reticle_target = true,
		reticle_target_neutral = true,
		reticle_target_hostile = true,
		reticle_target_friendly = true,
		reticle_target_delay = 0,
		reticle_opacity = 0.3,
		reticle_size = 32,
		reticle_sprite = "giznat",
	},
	settings = {},
	reticles = {}
}

for k,v in pairs(Lockdown.defaults) do
	Lockdown.settings[k] = v
end

-- Helpers
local function print(...)
	local out = {}
	for i=1,select('#', ...) do
		table.insert(out, tostring(select(i, ...)))
	end
	Print(table.concat(out, ", "))
end

-- Wipe a table for reuse
local function wipe(t)
	for k,v in pairs(t) do
		t[k] = nil
	end
end

-- Startup
function Lockdown:Init()
	Apollo.RegisterAddon(self, true, L.button_configure)
end

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

function Lockdown:OnSave(eLevel)
	if eLevel == GameLib.CodeEnumAddonSaveLevel.General then
		local s = self.settings
	end
end

function Lockdown:OnRestore(eLevel, tData)
	if eLevel == GameLib.CodeEnumAddonSaveLevel.General and tData then
		local s = self.settings
		-- Restore settings
		for k,v in pairs(s) do
			s[k] = tData[k]
		end
		-- Update settings dependant events
		self:KeyOrModifierUpdated()
		self.timerDelayedTarget:Set(s.reticle_target_delay / 1000, false)
	end
end

local function children_by_name(wnd, t)
	local t = t or {}
	for _,child in ipairs(wnd:GetChildren()) do
		t[child:GetName()] = child
		children_by_name(child, t)
	end
	return t
end

function Lockdown:OnLoad()
	----------------------------------------------------------
	-- Load reticle
	self.wndReticle = Apollo.LoadForm("Lockdown.xml", "Lockdown_ReticleForm", "InWorldHudStratum", nil, self)
	self.wndReticleSpriteTarget = self.wndReticle:FindChild("Lockdown_ReticleSpriteTarget")

	-- Add reticles
	self:AddReticle("tiny", [[Lockdown\reticles\tiny.png]], 32)
	self:AddReticle("giznat", [[Lockdown\reticles\giznat.png]], 32)
	self.wndReticle:Show(false)
	self:Reticle_UpdatePosition()
	Apollo.RegisterEventHandler("ResolutionChanged", "Reticle_UpdatePosition", self)

	-- For some reason on reloadui, the mouse locks in the NE screen quadrant
	ApolloTimer.Create(0.7, false, "TimerHandler_InitialLock", self)

	----------------------------------------------------------
	-- Options
	Apollo.RegisterSlashCommand("lockdown", "OnConfigure", self)

	----------------------------------------------------------
	-- Targeting
	-- TODO: Only do this when settings.reticle_target is on
	Apollo.RegisterEventHandler("MouseOverUnitChanged", "EventHandler_MouseOverUnitChanged", self)
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

	-- External windows
	Apollo.RegisterEventHandler("CombatMode_RegisterPausingWindow", "EventHandler_RegisterPausingWindow", self)

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
	self.timerToggleModifier = ApolloTimer.Create(0.1, true, "TimerHandler_ToggleModifier", self)

	-- Rainbows, unicorns, and kittens
	-- Oh my
	self:KeyOrModifierUpdated()


	self:SetActionMode(true)
end

-- Disover frames we should pause for
local tColdWindows, tHotWindows, tWindows = {}, {}, {}
function Lockdown:RegisterWindow(wnd)
	if wnd then
		local sName = wnd:GetName()
		if not tIgnoreWindows[sName] then
			-- Add to window index
			if not tWindows[sName] then
				tWindows[sName] = tHotList[sName] and "hot" or "cold"
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

-- API
function Lockdown:EventHandler_RegisterPausingWindow(wndHandle)
	self:RegisterWindow(wndHandle)
end

-- Poll unlocking frames
local bToggleModifier = false -- User toggling mouse with a modifier key
local tSkipWindows = {}
local bColdSuspend, bHotSuspend = false, false
local bActiveIntent = true

local function pulse_core(self, t, csi)
	local bWindowUnlock = false
	if not bToggleModifier then
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
	end

	return bWindowUnlock
end

function Lockdown:TimerHandler_ColdPulse()
	if not bHotSuspend then
		if pulse_core(self, tColdWindows, true) then
			if not bColdSuspend then
				bColdSuspend = true
				self:SuspendActionMode()
			end
		elseif bColdSuspend then
			if bActiveIntent and not GameLib.IsMouseLockOn() and bColdSuspend and not pulse_core(self, tHotWindows) then
				bColdSuspend = false
				self:SetActionMode(true)
			end
		end
	end
end

function Lockdown:TimerHandler_HotPulse()
	if not bColdSuspend then
		if pulse_core(self, tHotWindows) then
			if not bHotSuspend then
				bHotSuspend = true
				self:SuspendActionMode()
			end
		elseif bHotSuspend then
			if bActiveIntent and not GameLib.IsMouseLockOn() and bHotSuspend and not pulse_core(self, tColdWindows, true) then
				bHotSuspend = false
				self:SetActionMode(true)
			end
		end
	end
end

function Lockdown:PollAllWindows()
	self:TimerHandler_ColdPulse()
	self:TimerHandler_HotPulse()
	return bColdSuspend or bHotSuspend
end

function Lockdown:TimerHandler_Relock()
	self:SetActionMode(true)
end

-- Specific setting change handlers
-- CAN'T TAKE THE CHANGE, MAN
local ChangeHandlers = {}

function ChangeHandlers.reticle_target_delay(value)
	Lockdown.timerDelayedTarget:Set(value, false)
end

function ChangeHandlers.reticle_opacity(value)
	Lockdown.wndReticle:Show(true)
	Lockdown.wndReticleSpriteTarget:SetOpacity(value)
end

-- Per category widget handlers
-- Binding keys
local tBindKeyMap = {}
function Lockdown:OnBindKey(btn)
	local setting = tBindKeyMap[btn:GetName()]
	if not bBindMode then
		bBindMode = true
		btn:SetText(L.button_label_bind_wait)
		btn:SetCheck(true)
		sWhichBind = setting
	elseif sWhichBind == setting then
		bBindMode = false
		btn:SetText(SystemKeyMap[self.settings[setting]])
		btn:SetCheck(false)
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
		text:SetText(self.settings[setting])
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
			for name, elem in pairs(self.w) do
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
					else
						print("Element not bound", name)
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

		-- Default tab
		self:OnTab_General()
	end

	-- Update checkboxes
	for name, setting in pairs(tCheckboxMap) do
		w[name]:SetCheck(s[setting])
	end
	-- Update key bind buttons
	bBindMode = false
	for name, setting in pairs(tBindKeyMap) do
		w[name]:SetText(SystemKeyMap[s[setting]])
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
end

-- Store key and modifier check function
local togglelock_key, togglelock_mod, locktarget_key, locktarget_mod, targetmousover_key, targetmouseover_mod
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
	targetmouseover_key, targetmouseover_mod = Upvalues("targetmouseover_key", "targetmouseover_mod")
	if self.settings.free_with_alt or self.settings.free_with_ctrl or self.settings.free_with_shift then
		self.timerToggleModifier:Start()
	else
		self.timerToggleModifier:Stop()
	end
end

-- Keys
local uLockedTarget
function Lockdown:EventHandler_SystemKeyDown(iKey, ...)
	-- Listen for key to bind
	if bBindMode then
		bBindMode = false
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
	
	-- Static hotkeys, F7 and F8
	elseif iKey == 118 then
		self:SetActionMode(true)
	elseif iKey == 119 then
		self:SetActionMode(false)

	-- Target mouseover
	elseif iKey == targetmouseover_key and (not targetmouseover_mod or targetmouseover_mod()) then
		GameLib.SetTargetUnit(GetMouseOverUnit())

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
			GameLib.SetTargetUnit()
			-- TODO: Locked target indicator instead of clearing target
		else
			uLockedTarget = GameLib.GetTargetUnit()
		end
	end
end

-- Watch for modifiers to toggle mouselock
function Lockdown:TimerHandler_ToggleModifier()
	local old = bToggleModifier
	bToggleModifier = ((self.settings.free_with_shift and Apollo.IsShiftKeyDown())
		or (self.settings.free_with_ctrl and Apollo.IsControlKeyDown())
		or (self.settings.free_with_alt and Apollo.IsAltKeyDown()))
	if not old and bToggleModifier then
		if GameLib.IsMouseLockOn() then
			self:SuspendActionMode()
		else
			self:ForceActionMode()
		end
	end
	if old and not bToggleModifier then
		if self:PollAllWindows() then
			self:SuspendActionMode()
		else
			self:SetActionMode(bActiveIntent)
		end
	end
end


-- Targeting
local uLastMouseover
function Lockdown:EventHandler_MouseOverUnitChanged(unit)
	local opt = self.settings
	if unit and opt.reticle_target and GameLib.IsMouseLockOn() and (not uLockedTarget or uLockedTarget:IsDead()) then
		local disposition = unit:GetDispositionTo(GameLib.GetPlayerUnit())
		if ((opt.reticle_target_friendly and disposition == 2)
			or (opt.reticle_target_neutral and disposition == 1)
			or (opt.reticle_target_hostile and disposition == 0)) then
			if opt.reticle_target_delay ~= 0 then
				if unit ~= GameLib.GetTargetUnit() then
					uLastMouseover = unit
					self.timerDelayedTarget:Start()
				else
					self.timerDelayedTarget:Stop()
				end
			else
				GameLib.SetTargetUnit(unit)
			end
		end
	end
end

function Lockdown:TimerHandler_DelayedTarget()
	GameLib.SetTargetUnit(uLastMouseover)
end

function Lockdown:EventHandler_TargetUnitChanged()
	uLockedTarget = nil
end

-- Action mode toggle
function Lockdown:SetActionMode(bState)
	bActiveIntent = bState
	if GameLib.IsMouseLockOn() ~= bState then
		GameLib.SetMouseLock(bState)
	end
	if not bState then
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
	end
	-- TODO: Indicate inactive-but-enabled status
end

-- Suspend without disabling
function Lockdown:SuspendActionMode()
	if GameLib.IsMouseLockOn() then
		GameLib.SetMouseLock(false)
		self.wndReticle:Show(false)
	end
	-- TODO: Indicate active-but-suspended status
end

-- Adjust reticle
function Lockdown:Reticle_UpdatePosition()
	local s = self.settings
	local n = self.reticles[s.reticle_sprite] / 2
	self.wndReticleSpriteTarget:SetAnchorOffsets(-n, -n, n, n)
	self.wndReticleSpriteTarget:SetOpacity(s.reticle_opacity)
	self.wndReticleSpriteTarget:SetSprite("reticles:"..s.reticle_sprite)
end

function Lockdown:AddReticle(name, path, size)
	local tSpriteXML = {
		__XmlNode = "Sprites", {
			__XmlNode = "Sprite", Name = name, Cycle = 1, {
				__XmlNode = "Frame", Texture = path,
				x0 = 0, x2 = 0, x3 = 0, x4 = 0, x5 = size,
				y0 = 0, y2 = 0, y3 = 0, y4 = 0, y5 = size,
				HotSpotX = 0, HotSpotY = 0, Duration = 1.0,
				StartColor = "white", EndColor = "white"
			}
		}
	}
	Apollo.LoadSprites(XmlDoc.CreateFromTable(tSpriteXML), "reticles")
	self.reticles[name] = size
end

Lockdown:Init()

-- I don't want this at the top.
SystemKeyMap = {
	[8] = "Backspace",
	[9] = "Tab",
	[13] = "Enter",
	[16] = "Shift",
	[17] = "Ctrl",
	[19] = "Pause Break",
	[20] = "Caps Lock",
	[27] = "Esc",
	[32] = "Space",
	[33] = "Page Up",
	[34] = "Page Down",
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
	[65] = "A",
	[66] = "B",
	[67] = "C",
	[68] = "D",
	[69] = "E",
	[70] = "F",
	[71] = "G",
	[72] = "H",
	[73] = "I",
	[74] = "J",
	[75] = "K",
	[76] = "L",
	[77] = "M",
	[78] = "N",
	[79] = "O",
	[80] = "P",
	[81] = "Q",
	[82] = "R",
	[83] = "S",
	[84] = "T",
	[85] = "U",
	[86] = "V",
	[87] = "W",
	[88] = "X",
	[89] = "Y",
	[90] = "Z",
	[96] = "Num 0",
	[97] = "Num 1",
	[98] = "Num 2",
	[99] = "Num 3",
	[100] = "Num 4",
	[101] = "Num 5",
	[102] = "Num 6",
	[103] = "Num 7",
	[104] = "Num 8",
	[105] = "Num 9",
	[106] = "Num *",
	[107] = "Num +",
	[109] = "Num -",
	[110] = "Num .",
	[111] = "Num /",
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
	[222] = "'"
}
