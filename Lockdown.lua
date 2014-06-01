-- Carbine, full rights if you want to use any of it.

-- Addon authors or Carbine, to add a window to the list of pausing windows, call this for normal windows
-- Event_FireGenericEvent("GenericEvent_CombatMode_RegisterPausingWindow", wndHandle)

-- Lockdown automatically detects immediately created escapable windows, but redundant registration is not harmful.

-- Add windows that don't close on escape here
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
	"ResurrectDialog"
}

-- Add windows to ignore here
local tIgnoreWindows = {
	StoryPanelInformational = true,
	StoryPanelBubble = true,
	StoryPanelBubbleCenter = true,
	ProcsIcon1 = true,
	ProcsIcon2 = true,
	ProcsIcon3 = true,
}

-- Localization
local tLocalization = {
	en_us = {
		button_configure = "Lockdown",
		button_label_bind = "Click to bind",
		button_label_bind_wait = "Press key..",
		button_label_modifier = "Modifier"
	}
}
local L = setmetatable({}, {__index = tLocalization.en_us})

-- Addon init and variables
local Lockdown = {}

local tDefaults = {
	toggle_key = 192, -- backquote
	toggle_modifier = false,
	locktarget_key = 20, -- caps lock
	locktarget_modifier = false,
	free_with_shift = false,
	free_with_ctrl = false,
	free_with_alt = false,
	reticle_show = true,
	reticle_target = true,
	reticle_target_delay = 0,
}

Lockdown.settings = {}
for k,v in pairs(tDefaults) do
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

-- Print without debug
local function chatprint(text)
	ChatSystemLib.PostOnChannel(2, text)
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
	local sHandler = "EventHandler_"..sEvent
	Apollo.RegisterEventHandler(sEvent, sHandler, self)
	self[sHandler] = function(self_)
		local wnd = Apollo.FindWindowByName(sName)
		if wnd then
			self_:RegisterWindow(wnd)
		end
	end
end

function Lockdown:OnSave(eLevel)
	if eLevel == GameLib.CodeEnumAddonSaveLevel.Account then
		return self.settings
	end
end

function Lockdown:OnRestore(eLevel, tData)
	if eLevel == GameLib.CodeEnumAddonSaveLevel.Account and tData then
		self.settings = tData
		for k,v in pairs(tDefaults) do
			if self.settings[k] == nil then
				self.settings[k] = v
			end
		end
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

	-- Poll frames for visibility.
	-- I'd much rather use hooks or callbacks or events, but I can't hook, I can't find the right callbacks/they don't work, and the events aren't consistant or listed. 
	-- You made me do this, Carbine.
	self.timerFramePollPulse = ApolloTimer.Create(0.5, true, "TimerHandler_FramePollPulse", self)
	
	-- Keybinds
	Apollo.RegisterEventHandler("SystemKeyDown", "EventHandler_SystemKeyDown", self)
	self.timerFreeKeys = ApolloTimer.Create(0.05, true, "TimerHandler_FreeKeys", self)

	-- External windows
	Apollo.RegisterEventHandler("GenericEvent_CombatMode_RegisterPausingWindow", "EventHandler_RegisterPausingWindow", self)

	-- Carbine, plz.
	self:AddWindowEventListener("AbilityWindowHasBeenToggled", "AbilitiesBuilderForm")
	self:AddWindowEventListener("GenericEvent_InitializeFriends", "SocialPanelForm")

	-- Rainbows, unicorns, and kittens
	-- Oh my
	self:KeyOrModifierUpdated()
end

function Lockdown:TimerHandler_InitialLock()
	if self.bActiveIntent then
		GameLib:SetMouseLock(false)
		GameLib:SetMouseLock(true)
	end
end

-- Disover frames we should pause for
local tPauseWindows = {}
function Lockdown:RegisterWindow(wnd)
	if wnd then
		local sName = wnd:GetName()
		if not tIgnoreWindows[sName] then
			-- Remove any old handles
			for k,v in pairs(tPauseWindows) do
				if v == sName then
					tPauseWindows[sName] = nil
				end
			end
			-- Add new handle
			tPauseWindows[wnd] = sName
			-- print(sName)
			return true
		end
	end
	return false
end

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
	self:SetActionMode(true)
end

function Lockdown:EventHandler_RegisterPausingWindow(wndHandle)
	Lockdown:RegisterWindow(wndHandle)
end

-- Poll unlocking frames
local bWindowUnlock = false
local bFreeingMouse = false -- User freeing mouse with a modifier key
local tSkipWindows = {}
function Lockdown:TimerHandler_FramePollPulse()
	bWindowUnlock = false
	if not bFreeingMouse then
		-- Poll windows
		for wnd in pairs(tPauseWindows) do
			-- Unlock if visible and not currently skipped
			if wnd:IsShown() then
				if not tSkipWindows[wnd] then
					bWindowUnlock = true
				end
			-- Expire hidden from skiplist
			elseif tSkipWindows[wnd] then
				tSkipWindows[wnd] = nil
			end
		end

		-- CSI(?) dialogs
		if CSIsLib.GetActiveCSI() and not tSkipWindows.CSI then
			bWindowUnlock = true
		end

		-- Update state 
		if bWindowUnlock then
			self:SuspendActionMode()

		elseif self.bActiveIntent and not GameLib.IsMouseLockOn() then
			self:SetActionMode(true)
		end
	end

	return bWindowUnlock
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
local function ModifierClick(btn, which)
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

function Lockdown:OnToggleModifierBtn(btn)
	ModifierClick(btn, "toggle_modifier")
end

function Lockdown:OnLockTargetKeyBtn(btn)
	BindClick(btn, "locktarget_key")
end

function Lockdown:OnLockTargetModifierBtn(btn)
	ModifierClick(btn, "locktarget_modifier")
end

function Lockdown:OnReticleTargetBtn(btn)
	self.settings.reticle_target = btn:IsChecked()
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

function Lockdown:OnConfigure()
	self:UpdateConfigUI()
	self.wndOptions:Show(true, true)
end

-- Update all text in config window
function Lockdown:UpdateConfigUI()
	self.tWnd.ToggleKeyBtn:SetText(L.button_label_bind)
	self.tWnd.LockTargetKeyBtn:SetText(L.button_label_bind)
	self.tWnd.ToggleModifierBtn:SetText(self.settings.toggle_modifier and self.settings.toggle_modifier or L.button_label_modifier)
	self.tWnd.LockTargetModifierBtn:SetText(self.settings.locktarget_modifier and self.settings.locktarget_modifier or L.button_label_modifier)
	self.tWnd.ReticleShowBtn:SetCheck(self.settings.reticle_show)
	self.tWnd.ReticleTargetBtn:SetCheck(self.settings.reticle_target)
	self.tWnd.TargetDelaySlider:SetValue(self.settings.reticle_target_delay)
	self.tWnd.FreeWithShiftBtn:SetCheck(self.settings.free_with_shift)
	self.tWnd.FreeWithCtrlBtn:SetCheck(self.settings.free_with_ctrl)
	self.tWnd.FreeWithAltBtn:SetCheck(self.settings.free_with_alt)	
end

function Lockdown:OnCloseButton()
	self.wndOptions:Show(false, true)
end

-- Store key and modifier check function
local toggle_key, toggle_modifier, locktarget_key, locktarget_modifier
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
		if not self:TimerHandler_FramePollPulse() then
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

	-- Toggle mode
	elseif iKey == toggle_key and (not toggle_modifier or toggle_modifier()) then
		-- Save currently active windows and resume
		if self.bActiveIntent and not GameLib.IsMouseLockOn() then
			wipe(tSkipWindows)
			for wnd in pairs(tPauseWindows) do
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

function Lockdown:TimerHandler_FreeKeys()
	local old = bFreeingMouse
	bFreeingMouse = ((self.settings.free_with_shift and Apollo.IsShiftKeyDown())
		or (self.settings.free_with_ctrl and Apollo.IsControlKeyDown())
		or (self.settings.free_with_alt and Apollo.IsAltKeyDown()))
	if bFreeingMouse and GameLib.IsMouseLockOn() then
		self:SuspendActionMode()
	end
	if old and not bFreeingMouse then
		self:TimerHandler_FramePollPulse()
	end
end


-- Targeting
local uLastMouseover
function Lockdown:EventHandler_MouseOverUnitChanged(unit)
	if unit and self.settings.reticle_target and GameLib.IsMouseLockOn() then
		if unit ~= GameLib.GetTargetUnit() then
			if not uLockedTarget or uLockedTarget:IsDead() then
				if self.settings.reticle_target_delay ~= 0 then
					uLastMouseover = unit
					self.timerDelayedTarget:Start()
				else
					GameLib.SetTargetUnit(unit)
				end
			end
		elseif self.settings.reticle_target_delay ~= 0 then
			self.timerDelayedTarget:Stop()
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
	local nMidW, nMidH = tSize.nWidth/2, tSize.nHeight/2

	self.wndReticle:SetAnchorOffsets(nMidW - nRetW/2, nMidH - nRetH/2, nMidW + nRetW/2, nMidH + nRetH/2)
	self.wndReticle:FindChild("Lockdown_ReticleSpriteTarget"):SetOpacity(0.3)
end

Lockdown:Init()
