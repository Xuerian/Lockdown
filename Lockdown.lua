-- Carbine, full rights if you want to use any of it.

-- Addon authors or Carbine, to add a window to the list of pausing windows, call this for normal windows
-- Event_FireGenericEvent("GenericEvent_CombatMode_RegisterPausingWindow", wndHandle)

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
		button_label_modifier = "Modifier"
	}
}
local L = setmetatable({}, {__index = tLocalization.en_us})

-- System key map
-- I don't even know who this is from
-- Three different mods have three different versions
local SystemKeyMap

-- Defaults
local Lockdown = {
	settings = {
		toggle_key = 192, -- backquote
		toggle_modifier = false,
		locktarget_key = 20, -- caps lock
		locktarget_modifier = false,
		targetmouseover_key = 84, -- t
		targetmouseover_modifier = "control",
		free_with_shift = false,
		free_with_ctrl = false,
		free_with_alt = true,
		reticle_show = true,
		reticle_offset_y = -100,
		reticle_offset_x = 0,
		reticle_target = false,
		reticle_target_neutral = true,
		reticle_target_hostile = true,
		reticle_target_friendly = true,
		reticle_target_delay = 0,
	}
}

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
	self.bActiveIntent = true
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
	if eLevel == GameLib.CodeEnumAddonSaveLevel.Account then
		return self.settings
	end
end

function Lockdown:OnRestore(eLevel, tData)
	if eLevel == GameLib.CodeEnumAddonSaveLevel.Account and tData then
		-- Restore settings and initialize defaults
		for k,v in pairs(tData) do
			self.settings[k] = v
		end
		-- Update settings dependant events
		self:KeyOrModifierUpdated()
		self.timerDelayedTarget:Set(self.settings.reticle_target_delay, false)
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
	-- Load reticle
	self.xml = XmlDoc.CreateFromFile("Lockdown.xml")
	self.wndReticle = Apollo.LoadForm("Lockdown.xml", "Lockdown_ReticleForm", "InWorldHudStratum", nil, self)
	self.wndReticle:Show(false)
	self:Reticle_UpdatePosition()
	Apollo.RegisterEventHandler("ResolutionChanged", "Reticle_UpdatePosition", self)

	-- For some reason on reloadui, the mouse locks in the NE screen quadrant
	ApolloTimer.Create(0.7, false, "TimerHandler_InitialLock", self)

	-- Options
	Apollo.RegisterSlashCommand("lockdown", "OnConfigure", self)
	self.wndOptions = Apollo.LoadForm("Lockdown.xml", "Lockdown_OptionsForm", nil, self)
	self.tWnd = children_by_name(self.wndOptions)

	self.xml = nil

	-- Targeting
	-- TODO: Only do this when settings.reticle_target is on
	Apollo.RegisterEventHandler("MouseOverUnitChanged", "EventHandler_MouseOverUnitChanged", self)
	Apollo.RegisterEventHandler("TargetUnitChanged", "EventHandler_TargetUnitChanged", self)
self.timerRelock = ApolloTimer.Create(0.01, false, "TimerHandler_Relock", self)
	self.timerRelock:Stop()
	self.timerDelayedTarget = ApolloTimer.Create(1, false, "TimerHandler_DelayedTarget", self)
	self.timerDelayedTarget:Stop()

	-- Crawl for frames to hook
	self.timerFrameCrawl = ApolloTimer.Create(5.0, false, "TimerHandler_FrameCrawl", self)

	-- Wait for windows to be created or re-created
	self.timerDelayedFrameCatch = ApolloTimer.Create(0.1, true, "TimerHandler_DelayedFrameCatch", self)
	self.timerDelayedFrameCatch:Stop()

	-- Poll frames for visibility.
	-- I'd much rather use hooks or callbacks or events, but I can't hook, I can't find the right callbacks/they don't work, and the events aren't consistant or listed. 
	-- You made me do this, Carbine.
	self.timerColdPulse = ApolloTimer.Create(1.0, true, "TimerHandler_ColdPulse", self)
	self.timerHotPulse = ApolloTimer.Create(0.2, true, "TimerHandler_HotPulse", self)
	
	-- Keybinds
	Apollo.RegisterEventHandler("SystemKeyDown", "EventHandler_SystemKeyDown", self)
	self.timerFreeKeys = ApolloTimer.Create(0.1, true, "TimerHandler_FreeKeys", self)

	-- External windows
	Apollo.RegisterEventHandler("GenericEvent_CombatMode_RegisterPausingWindow", "EventHandler_RegisterPausingWindow", self)

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
	-- Public event voting
	self:AddDelayedWindowEventListener("PublicEventInitiateVote", "PublicEventVoteForm")

	-- Rainbows, unicorns, and kittens
	-- Oh my
	self:KeyOrModifierUpdated()

end

-- Take over MouselockIndicatorPixel to show dirty lock status
function Lockdown:TimerHandler_PixelHook()
	local pixel = Apollo.GetAddon("MouselockIndicatorPixel") or Apollo.GetAddon("MouselockRebind")
	if pixel and pixel.timer and not self.wndPixels then
		pixel.timer:Stop()
		self.timerPixel = ApolloTimer.Create(0.05, true, "TimerHandler_PixelPulse", self)
		self.wndPixels = pixel.wndPixels
	end
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
	if select("#", tDelayedWindows) == 0 then
		self.timerDelayedFrameCatch:Stop()
	end
end

-- API
function Lockdown:EventHandler_RegisterPausingWindow(wndHandle)
	self:RegisterWindow(wndHandle)
end

-- Poll unlocking frames
local bFreeingMouse = false -- User freeing mouse with a modifier key
local tSkipWindows = {}
local bColdSuspend, bHotSuspend = false, false

local function pulse_core(self, t, csi)
	local bWindowUnlock = false
	if not bFreeingMouse then
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
		if csi and CSIsLib.GetActiveCSI() and not tSkipWindows.CSI then
			bWindowUnlock = true
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
				print("Cold suspend")
			end
		elseif bColdSuspend then
			if self.bActiveIntent and not GameLib.IsMouseLockOn() and bColdSuspend and not pulse_core(self, tHotWindows) then
				bColdSuspend = false
				self:SetActionMode(true)
				print("Cold resume")
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
				print("Hot suspend")
			end
		elseif bHotSuspend then
			if self.bActiveIntent and not GameLib.IsMouseLockOn() and bHotSuspend and not pulse_core(self, tColdWindows, true) then
				bHotSuspend = false
				self:SetActionMode(true)
				print("Hot resume")
			end
		end
	end
end

function Lockdown:PollAllWindows()
	return self:TimerHandler_ColdPulse() or self:TimerHandler_HotPulse()
end

function Lockdown:TimerHandler_Relock()
	self:SetActionMode(true)
end

-- Options
local bBindMode, sWhichBind = false, nil
local function OnModifierBtn(btn, optkey)
	local mod = self.settings[optkey]
	if not mod then
		mod = "shift"
	elseif mod == "shift" then
		mod = "control"
	else
		mod = false
	end
end

-- Enter bind mode for a given binding button
local function BindClick(btn, which)
	if not bBindMode then
		bBindMode = true
		sWhichBind = which
		btn:SetText(L.button_label_bind_wait)
	end
end

-- Cycle modifier for a given modifier button
local function ModifierClick(which)
	local mod = Lockdown.settings[which]
	if not mod then
		mod = "shift"
	elseif mod == "shift" then
		mod = "control"
	else
		mod = false
	end
	Lockdown.settings[which] = mod
	Lockdown:KeyOrModifierUpdated()
	Lockdown:UpdateConfigUI()
end

-- UI callbacks
function Lockdown:OnToggleKeyBtn(btn)
	BindClick(btn, "toggle_key")
end

function Lockdown:OnToggleModifierBtn()
	ModifierClick("toggle_modifier")
end

function Lockdown:OnLockTargetKeyBtn(btn)
	BindClick(btn, "locktarget_key")
end

function Lockdown:OnLockTargetModifierBtn()
	ModifierClick("locktarget_modifier")
end

function Lockdown:BtnTargetMouseoverKey(btn)
	BindClick(btn, "targetmouseover_key")
end

function Lockdown:BtnTargetMouseoverMod()
	ModifierClick("targetmouseover_modifier")
end


function Lockdown:OnReticleTargetBtn(btn)
	self.settings.reticle_target = btn:IsChecked()
end

function Lockdown:OnReticleTargetHostileBtn(btn)
	self.settings.reticle_target_hostile = btn:IsChecked()
end

function Lockdown:OnReticleTargetFriendlyBtn(btn)
	self.settings.reticle_target_friendly = btn:IsChecked()
end

function Lockdown:OnReticleTargetNeutralBtn(btn)
	self.settings.reticle_target_neutral = btn:IsChecked()
end

function Lockdown:OnReticleShowBtn(btn)
	self.settings.reticle_show = btn:IsChecked()
end

function Lockdown:OnFreeWithShiftBtn(btn)
	self.settings.free_with_shift = btn:IsChecked()
end

function Lockdown:OnFreeWithCtrlBtn(btn)
	self.settings.free_with_ctrl = btn:IsChecked()
end

function Lockdown:OnFreeWithAltBtn(btn)
	self.settings.free_with_alt = btn:IsChecked()
end

function Lockdown:OnTargetDelaySlider(btn)
	self.settings.reticle_target_delay = btn:GetValue()
	self.timerDelayedTarget:Set(self.settings.reticle_target_delay, false)
end

function Lockdown:On_reticle_offset_x(btn)
	self.settings.reticle_offset_x = btn:GetValue()
	self.tWnd.slider_reticle_offset_x_text:SetText(btn:GetValue())
	self:Reticle_UpdatePosition()
end

function Lockdown:On_reticle_offset_y(btn)
	self.settings.reticle_offset_y = btn:GetValue()
	self.tWnd.slider_reticle_offset_y_text:SetText(btn:GetValue())
	self:Reticle_UpdatePosition()
end

function Lockdown:OnConfigure()
	self:UpdateConfigUI()
	self.wndOptions:Show(true, true)
end

-- Update all text in config window
function Lockdown:UpdateConfigUI()
	local w, s = self.tWnd, self.settings
	w.ToggleKeyBtn:SetText(SystemKeyMap[s.toggle_key])
	w.LockTargetKeyBtn:SetText(SystemKeyMap[s.locktarget_key])
	w.BtnTargetMouseoverKey:SetText(SystemKeyMap[s.targetmouseover_key])
	w.ToggleModifierBtn:SetText(s.toggle_modifier and s.toggle_modifier or L.button_label_modifier)
	w.LockTargetModifierBtn:SetText(s.locktarget_modifier and s.locktarget_modifier or L.button_label_modifier)
	w.BtnTargetMouseoverMod:SetText(s.targetmouseover_modifier and s.targetmouseover_modifier or L.button_label_modifier)
	w.ReticleShowBtn:SetCheck(s.reticle_show)
	w.ReticleTargetBtn:SetCheck(s.reticle_target)
	w.ReticleTargetHostileBtn:SetCheck(s.reticle_target_hostile)
	w.ReticleTargetFriendlyBtn:SetCheck(s.reticle_target_friendly)
	w.ReticleTargetNeutralBtn:SetCheck(s.reticle_target_neutral)
	w.TargetDelaySlider:SetValue(s.reticle_target_delay)
	w.FreeWithShiftBtn:SetCheck(s.free_with_shift)
	w.FreeWithCtrlBtn:SetCheck(s.free_with_ctrl)
	w.FreeWithAltBtn:SetCheck(s.free_with_alt)
	w.slider_reticle_offset_x_text:SetText(s.reticle_offset_x)
	w.slider_reticle_offset_x:SetValue(s.reticle_offset_x)
	w.slider_reticle_offset_y_text:SetText(s.reticle_offset_y)
	w.slider_reticle_offset_y:SetValue(s.reticle_offset_y)
end

function Lockdown:OnCloseButton()
	self.wndOptions:Show(false, true)
end

-- Store key and modifier check function
local toggle_key, toggle_modifier, locktarget_key, locktarget_modifier, targetmousover_key, targetmouseover_modifier
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
	toggle_key, toggle_modifier = Upvalues("toggle_key", "toggle_modifier")
	locktarget_key, locktarget_modifier = Upvalues("locktarget_key", "locktarget_modifier")
	targetmouseover_key, targetmouseover_modifier = Upvalues("targetmouseover_key", "targetmouseover_modifier")
	if self.settings.free_with_alt or self.settings.free_with_ctrl or self.settings.free_with_shift then
		self.timerFreeKeys:Start()
	else
		self.timerFreeKeys:Stop()
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
	if iKey == 27 and self.bActiveIntent then
		if not self:PollAllWindows() then
			if GameLib.GetTargetUnit() then
				GameLib.SetTargetUnit()
				self.timerRelock:Start()
			else
				self:SuspendActionMode()
			end
		end
	
	-- Target mouseover
	elseif iKey == targetmouseover_key and (not targetmouseover_modifier or targetmouseover_modifier()) then
		GameLib.SetTargetUnit(GetMouseOverUnit())

	-- Toggle mode
	elseif iKey == toggle_key and (not toggle_modifier or toggle_modifier()) then
		-- Save currently active windows and resume
		if self.bActiveIntent and not GameLib.IsMouseLockOn() then
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
			self:SetActionMode(not self.bActiveIntent)
		end
	
	-- Lock target
	elseif iKey == locktarget_key and (not locktarget_modifier or locktarget_modifier()) then
		if uLockedTarget then
			uLockedTarget = nil
			GameLib.SetTargetUnit()
			-- TODO: Locked target indicator instead of clearing target
		else
			uLockedTarget = GameLib.GetTargetUnit()
		end
	end
end

-- Watch for modifiers to pause mouselock
function Lockdown:TimerHandler_FreeKeys()
	local old = bFreeingMouse
	bFreeingMouse = ((self.settings.free_with_shift and Apollo.IsShiftKeyDown())
		or (self.settings.free_with_ctrl and Apollo.IsControlKeyDown())
		or (self.settings.free_with_alt and Apollo.IsAltKeyDown()))
	if bFreeingMouse and GameLib.IsMouseLockOn() then
		self:SuspendActionMode()
	end
	if old and not bFreeingMouse and not self:PollAllWindows() then
		self:SetActionMode(true)
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
	self.bActiveIntent = bState
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
	-- Doing it wrong, apparently. 
	-- local nRetW = self.wndReticle:FindChild("Lockdown_ReticleForm"):GetWidth()
	-- local nRetH = self.wndReticle:FindChild("Lockdown_ReticleForm"):GetHeight() 
	local nRetW, nRetH = 32, 32

	local tSize = Apollo.GetDisplaySize()
	local nMidW, nMidH = tSize.nWidth/2 + self.settings.reticle_offset_x, tSize.nHeight/2 + self.settings.reticle_offset_y

	self.wndReticle:SetAnchorOffsets(nMidW - nRetW/2, nMidH - nRetH/2, nMidW + nRetW/2, nMidH + nRetH/2)
	self.wndReticle:FindChild("Lockdown_ReticleSpriteTarget"):SetOpacity(0.3)
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
