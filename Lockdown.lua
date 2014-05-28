-- Carbine, full rights if you want to use any of it.

-- Addon authors or Carbine, to add a window to the list of pausing windows, call this for normal windows
-- Event_FireGenericEvent("GenericEvent_CombatMode_RegisterPausingWindow", wndHandle)

-- Lockdown automatically detects immediately created escapable windows, but redundant registration is not harmful.

-- Add windows that don't close on escape here
local tAdditionalWindows = {
	"RoverForm",
	"GeminiConsoleWindow",
	"KeybindForm"
}

-- Add windows to ignore here
local tIgnoreWindows = {
	StoryPanelInformational = true
}

-- Localization
local tLocalization = {
	en_us = {
		button_configure = "Lockdown",
		button_label_bind = "Click to bind toggle key",
		button_label_bind_wait = "Press key..",
		button_label_modifier = "Modifier"
	}
}
local L = setmetatable({}, {__index = tLocalization.en_us})

-- Addon init and variables
local Lockdown = {}

local tDefaults = {
	key = 192, -- backquote
	modifier = false
}

Lockdown.settings = {}
for k,v in pairs(tDefaults) do
	Lockdown.settings[k] = v
end

-- Helpers
local function print(...)
	local out = {}
	for i=1,select('#', ...) do
		table.insert(out, ("%s [%s]"):format(tostring(select(i, ...)), type(select(i, ...))))
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
	-- self.bIntentPaused = false
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
		self:UpdateHotkeyMagicalRainbowUnicorns()
	end
end

function Lockdown:OnLoad()
	-- Load reticle
	self.xml = XmlDoc.CreateFromFile("Lockdown.xml")
	self.wndReticle = Apollo.LoadForm("Lockdown.xml", "Lockdown_ReticleForm", "InWorldHudStratum", nil, self)
	self.wndReticle:Show(false)
	self:Reticle_UpdatePosition()
	Apollo.RegisterEventHandler("ResolutionChanged", "Reticle_UpdatePosition", self)

	-- Options
	Apollo.RegisterSlashCommand("lockdown", "OnConfigure", self)
	self.wndOptions = Apollo.LoadForm("Lockdown.xml", "Lockdown_OptionsForm", nil, self)
	self.wndOptionsButtonKey = self.wndOptions:FindChild("BindKey")
	self.wndOptionsButtonModifier = self.wndOptions:FindChild("Modifier")

	-- Targeting
	Apollo.RegisterEventHandler("MouseOverUnitChanged", "EventHandler_MouseOverUnitChanged", self)

	-- Crawl for frames to hook
	Apollo.CreateTimer("Lockdown_FrameCrawl", 5.0, false)
	Apollo.RegisterTimerHandler("Lockdown_FrameCrawl", "TimerHandler_FrameCrawl", self)

	-- Poll frames for visibility.
	-- I'd much rather use hooks or callbacks or events, but I can't hook, I can't find the right callbacks/they don't work, and the events aren't consistant or listed. 
	-- You made me do this, Carbine.
	Apollo.CreateTimer("Lockdown_FramePollPulse", 0.5, true)
	Apollo.RegisterTimerHandler("Lockdown_FramePollPulse", "TimerHandler_FramePollPulse", self)

	-- Keybinds
	Apollo.RegisterEventHandler("SystemKeyDown", "EventHandler_SystemKeyDown", self)

	-- External windows
	Apollo.RegisterEventHandler("GenericEvent_CombatMode_RegisterPausingWindow", "EventHandler_RegisterPausingWindow", self)

	-- Carbine, plz.
	self:AddWindowEventListener("AbilityWindowHasBeenToggled", "AbilitiesBuilderForm")
	self:AddWindowEventListener("GenericEvent_InitializeFriends", "SocialPanelForm")

	-- Rainbows, unicorns, and kittens
	-- Oh my
	self:UpdateHotkeyMagicalRainbowUnicorns()
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
			tPauseWindows[wnd] = wnd:GetName()
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
local tSkipWindows = {}
function Lockdown:TimerHandler_FramePollPulse()
	bWindowUnlock = false
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
	-- Update state 
	if bWindowUnlock then
		self:SuspendActionMode()

	elseif self.bActiveIntent and not GameLib.IsMouseLockOn() then
		self:SetActionMode(true)
	end
end

-- Options
local bBindMode = false
function Lockdown:OnConfigure()
	self.wndOptionsButtonKey:SetText(L.button_label_bind)
	self.wndOptions:Show(true, true)
end

function Lockdown:ButtonHandler_Bind()
	bBindMode = true
	self.wndOptionsButtonKey:SetText(L.button_label_bind_wait)
end

function Lockdown:ButtonHandler_Modifier()
	local mod = self.settings.modifier
	if not mod then
		mod = "shift"
	elseif mod == "shift" then
		mod = "control"
	else
		mod = false
	end
	self.settings.modifier = mod
	self:UpdateHotkeyMagicalRainbowUnicorns()
end

function Lockdown:ButtonHandler_Close()
	self.wndOptions:Show(false, true)
end

-- Store key and modifier check value||method each time they change
local cKey, mModifier
function Lockdown:UpdateHotkeyMagicalRainbowUnicorns()
	cKey = self.settings.key
	local mod = self.settings.modifier
	if mod == "shift" then
		mModifier = Apollo.IsShiftKeyDown
	elseif mod == "control" then
		mModifier = Apollo.IsControlKeyDown
	else
		mModifier = false
	end
	self.wndOptionsButtonModifier:SetText(mod and mod or L.button_label_modifier)
end

-- Keys
function Lockdown:EventHandler_SystemKeyDown(iKey, ...)
	-- Listen for key to bind
	if bBindMode then
		bBindMode = false
		self.settings.key = iKey
		self.wndOptionsButtonKey:SetText(L.button_label_bind)
		self:UpdateHotkeyMagicalRainbowUnicorns()
		return
	end

	-- Open options on Escape
	if iKey == 27 and self.bActiveIntent then
		if GameLib.GetTargetUnit() then
			GameLib.SetTargetUnit()
			self:SetActionMode(true)
		else
			self:SuspendActionMode()
		end
	
	-- Static hotkeys, F7 and F8
	elseif iKey == 118 then
		self:SetActionMode(true)
	elseif iKey == 119 then
		self:SetActionMode(false)

	-- Toggle mode
	elseif iKey == cKey and (not mModifier or mModifier()) then
		-- Save currently active windows and resume
		if self.bActiveIntent and not GameLib.IsMouseLockOn() then
			wipe(tSkipWindows)
			for wnd in pairs(tPauseWindows) do
				if wnd:IsShown() then
					tSkipWindows[wnd] = true
				end
			end
			self:SetActionMode(true)
		else
			-- Toggle
			self:SetActionMode(not self.bActiveIntent)
		end
	end
end

-- Targeting
function Lockdown:EventHandler_MouseOverUnitChanged(unit)
	if unit and GameLib.IsMouseLockOn() then
		GameLib.SetTargetUnit(unit)
	end
end

-- Action mode toggle
function Lockdown:SetActionMode(bState)
	self.bActiveIntent = bState
	-- self.bIntentPaused = false
	if GameLib.IsMouseLockOn() ~= bState then
		GameLib.SetMouseLock(bState)
	end
	self.wndReticle:Show(bState)
	-- TODO: Sounds
end

-- Suspend without disabling
function Lockdown:SuspendActionMode()
	-- self.bIntentPaused = true
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
