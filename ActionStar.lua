-- Carbine, full rights if you want to use any of it.

-- Addon authors or Carbine, to add a window to the list of pausing windows, call
-- Event_FireGenericEvent("GenericEvent_CombatMode_RegisterPausingWindow", wndHandle)
-- ActionStar automatically detects immediately detected escapable windows, but redundant registration is not harmful.

-- Add windows that don't close on escape here
local tHardcodedForms = {
	"RoverForm",
	"GeminiConsoleWindow",
	"KeybindForm"
}

local ActionStar = {}

-- Debug
local function print(...)
	local out = {...}
	for i,v in ipairs(out) do
		out[i] = tostring(v)
	end
	Print(table.concat(out, ", "))
end

-- Startup
function ActionStar:Init()
	self.bActiveIntent = true
	-- self.bIntentPaused = false
	Apollo.RegisterAddon(self)
end

function ActionStar:OnLoad()
	-- Load reticle
	self.xml = XmlDoc.CreateFromFile("ActionStar.xml")
	self.wndReticle = Apollo.LoadForm("ActionStar.xml", "ActionStar_ReticleForm", "InWorldHudStratum", self)
	self.wndReticle:Show(false)
	self:Reticle_UpdatePosition()
	Apollo.RegisterEventHandler("ResolutionChanged", "Reticle_UpdatePosition", self)

	-- Targeting
	Apollo.RegisterEventHandler("MouseOverUnitChanged", "EventHandler_MouseOverUnitChanged", self)

	-- Crawl for frames to hook
	Apollo.CreateTimer("ActionStar_FrameCrawl", 5.0, false)
	Apollo.RegisterTimerHandler("ActionStar_FrameCrawl", "TimerHandler_FrameCrawl", self)

	-- Poll frames for visibility.
	-- I'd much rather use hooks or callbacks or events, but I can't hook, I can't find the right callbacks/they don't work, and the events aren't consistant or listed. 
	-- You made me do this, Carbine.
	Apollo.CreateTimer("ActionStar_FramePollPulse", 0.5, true)
	Apollo.RegisterTimerHandler("ActionStar_FramePollPulse", "TimerHandler_FramePollPulse", self)

	-- Keybinds
	Apollo.RegisterEventHandler("SystemKeyDown", "EventHandler_SystemKeyDown", self)

	-- External windows
	Apollo.RegisterEventHandler("GenericEvent_CombatMode_RegisterPausingWindow", "EventHandler_RegisterPausingWindow", self)

	-- Carbine, plz.
	Apollo.RegisterEventHandler("AbilityWindowHasBeenToggled", "EventHandler_AbilityWindowDecidedToShowUp", self)
end

-- Disover frames we should pause for
local tPauseWindows = {}
local function RegisterWindow(wnd)
	if wnd then
		local sName = wnd:GetName()
		for k,v in pairs(tPauseWindows) do
			if v == sName then
				tPauseWindows[sName] = nil
				break
			end
		end
		tPauseWindows[wnd] = wnd:GetName()
	end
end

function ActionStar:TimerHandler_FrameCrawl()
	for _,strata in ipairs(Apollo.GetStrata()) do
		for _,wnd in ipairs(Apollo.GetWindowsInStratum(strata)) do
			if wnd:IsStyleOn("Escapable") and not wnd:IsStyleOn("CloseOnExternalClick") then
				-- print(wnd:GetName())
				RegisterWindow(wnd)
			end
		end
	end
	-- Hardcoded names, Carbine and authors, plz.
	for _,sName in ipairs(tHardcodedForms) do
		local wnd = Apollo.FindWindowByName(sName)
		if wnd then
			RegisterWindow(wnd)
		end
	end
	self:SetActionMode(true)
end

function ActionStar:EventHandler_RegisterPausingWindow(wndHandle)
	RegisterWindow(wndHandle)
end

-- Poll unlocking frames
-- TODO: Allow resuming with open windows. 
local bWindowUnlock = false
function ActionStar:TimerHandler_FramePollPulse()
	bWindowUnlock = false
	-- Poll windows
	for wnd in pairs(tPauseWindows) do
		if wnd:IsShown() then
			bWindowUnlock = true
		end
	end
	-- Update state 
	if bWindowUnlock then
		self:SuspendActionMode()
	else
		if self.bActiveIntent and not GameLib.IsMouseLockOn() then
			self:SetActionMode(true)
		end
	end
end

-- Ability window is dynamic? Re-register every time it is shown
function ActionStar:EventHandler_AbilityWindowDecidedToShowUp()
	local wnd = Apollo.FindWindowByName("AbilitiesBuilderForm")
	if wnd then
		RegisterWindow(wnd)
	end
end

-- Keys
function ActionStar:EventHandler_SystemKeyDown(iKey)
	-- Open options on Escape
	if iKey == 27 and self.bActiveIntent then
		if GameLib.GetTargetUnit() then
			GameLib.SetTargetUnit()
			self:SetActionMode(true)
		else
			self:SuspendActionMode()
		end
	end

	-- Toggle mode
	if iKey == 67 and Apollo.IsShiftKeyDown()then
		self:SetActionMode(not self.bActiveIntent)
	
	-- Static hotkeys, F7 and F8
	elseif iKey == 118 then
		self:SetActionMode(true)
	elseif iKey == 119 then
		self:SetActionMode(false)
	end
end

-- Targeting
function ActionStar:EventHandler_MouseOverUnitChanged(unit)
	if unit and GameLib.IsMouseLockOn() then
		GameLib.SetTargetUnit(unit)
	end
end

-- Action mode toggle
function ActionStar:SetActionMode(bState)
	self.bActiveIntent = bState
	-- self.bIntentPaused = false
	if GameLib.IsMouseLockOn() ~= bState then
		GameLib.SetMouseLock(bState)
	end
	self.wndReticle:Show(bState)
	-- TODO: Sounds
end

-- Suspend without disabling
function ActionStar:SuspendActionMode()
	-- self.bIntentPaused = true
	if GameLib.IsMouseLockOn() then
		GameLib.SetMouseLock(false)
		self.wndReticle:Show(false)
	end
	-- TODO: Indicate active-but-suspended status
end

-- Adjust reticle
function ActionStar:Reticle_UpdatePosition()
	local nRetW = self.wndReticle:FindChild("ActionStar_ReticleForm"):GetWidth()
	local nRetH = self.wndReticle:FindChild("ActionStar_ReticleForm"):GetHeight() 

	local tSize = Apollo.GetDisplaySize()
	local nMidW, nMidH = tSize.nWidth/2, tSize.nHeight/2

	self.wndReticle:SetAnchorOffsets(nMidW - nRetW/2, nMidH - nRetH/2, nMidW + nRetW/2, nMidH + nRetH/2)
	self.wndReticle:FindChild("ActionStar_ReticleSpriteTarget"):SetOpacity(0.3)
end

ActionStar:Init()
