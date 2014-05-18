
-- Rights reserved, etc. Please do not host where not officially posted, distribution to friends is fine.
-- Carbine, full rights if you want to use any of it.

local ActionStar = {}

local function print(...)
	local out = {...}
	for i,v in ipairs(out) do
		out[i] = tostring(v)
	end
	Print(table.concat(out, ", "))
end

function ActionStar:Init()
	Apollo.RegisterAddon(self)
end

function ActionStar:OnLoad()
	-- Load reticle
	self.xml = XmlDoc.CreateFromFile("ActionStar.xml")
	self.wndReticle = Apollo.LoadForm("ActionStar.xml", "ActionStar_ReticleForm", "InWorldHudStratum", self)
	self.wndReticle:Show(false)
	self:Reticle_UpdatePosition()

	-- Targeting
	Apollo.RegisterEventHandler("MouseoverUnitChanged", "EventHandler_MouseOverUnitChanged", self)

	-- Movement detection
	Apollo.CreateTimer("ActionStar_Pulse", 0.2, true)
	Apollo.RegisterTimerHandler("ActionStar_Pulse", "TimerHandler_Pulse", self)
end

-- Targeting
function ActionStar:EventHandler_MouseOverUnitChanged(unit)
	if GameLib.IsMouseLockOn() then
		GameLib.SetTargetUnit(unit)
	end
end

-- Movement detection
local fMathAbs, iTicksTillUnlock, tPositionOld = math.abs, 0
function ActionStar:TimerHandler_Pulse()
	local unit = GameLib.GetPlayerUnit()
	if unit and unit:IsValid() then -- Is this necessary? Will player ever be invalid?
		local new, old = unit:GetPosition(), tPositionOld or unit:GetPosition()
		tPositionOld = new

		if fMathAbs(old.x-new.x) > 0.1 or fMathAbs(old.y-new.y) > 0.1 or fMathAbs(old.z-new.z) > 0.1 then
			if not GameLib.IsMouseLockOn() then
				self:SetActionMode(true)
				iTicksTillUnlock = 5
			end
		elseif GameLib.IsMouseLockOn() then
			-- Don't unlock immediately
			if iTicksTillUnlock > 0 then
				iTicksTillUnlock = iTicksTillUnlock - 1
			else
				self:SetActionMode(false)
			end
		end
	end
end

function ActionStar:SetActionMode(bState)
	GameLib.SetMouseLock(bState)
	self.wndReticle:Show(bState)
end

function ActionStar:Reticle_UpdatePosition()
	local nRetW = self.wndReticle:FindChild("ActionStar_ReticleForm"):GetWidth()
	local nRetH = self.wndReticle:FindChild("ActionStar_ReticleForm"):GetHeight() 

	local tSize = Apollo.GetDisplaySize()
	local nMidW, nMidH = tSize.nWidth/2, tSize.nHeight/2

	self.wndReticle:SetAnchorOffsets(nMidW - nRetW/2, nMidH - nRetH/2, nMidW + nRetW/2, nMidH + nRetH + nRetH/2)
	self.wndReticle:FindChild("ActionStar_ReticleSpriteTarget"):SetOpacity(0.3)
end

ActionStar:Init()
