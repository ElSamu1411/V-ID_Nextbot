include("shared.lua")

-- ============================================================================
-- CACHÉ DE MATERIALES (.VMT UnlitGeneric con $translucent 1 y $nocull 1)
-- ============================================================================
local MAT_FACE_BASE = Material("entities/npc_void/face_1_VOID")
local MAT_FACE_HYPER = Material("entities/npc_void/face_2_VOID")
local COLOR_WHITE = Color(255, 255, 255, 255)

language.Add("npc_void", "VØID")
killicon.Add("npc_void", "entities/npc_void/face_2_VOID", COLOR_WHITE)

-- Limpieza preventiva de canales heredados si hubo AutoRefresh desde una versión anterior
if _G.VOID_GlobalAudioChannels then
    for k, oldEntry in pairs(_G.VOID_GlobalAudioChannels) do
        if oldEntry.loopTimerName then timer.Remove(oldEntry.loopTimerName) end
        if IsValid(oldEntry.screamChannel) then oldEntry.screamChannel:Stop() end
        if IsValid(oldEntry.loopChannel) then oldEntry.loopChannel:Stop() end
        _G.VOID_GlobalAudioChannels[k] = nil
    end
end

-- ============================================================================
-- ESTADO DE OCULTACIÓN DE TELETRANSPORTE Y DIRECTOR DE AUDIO BASS EN CLIENTE
-- ============================================================================
_G.VOID_ClientAudioStates = _G.VOID_ClientAudioStates or {}
local VOID_ClientAudioStates = _G.VOID_ClientAudioStates

_G.VOID_ParanoiaActiveChannels = _G.VOID_ParanoiaActiveChannels or {}
local VOID_ParanoiaActiveChannels = _G.VOID_ParanoiaActiveChannels

_G.VOID_ClientCloakUntil = _G.VOID_ClientCloakUntil or {}
local VOID_ClientCloakUntil = _G.VOID_ClientCloakUntil

local MODE_SOUND_INFO = {
    [VOID_AUDIO_IDLE] = {
        path = VOID_CONFIG.sound_idle,
        loop = true,
        duration = VOID_CONFIG.duration_idle_loop,
    },
    [VOID_AUDIO_CHASE] = {
        path = VOID_CONFIG.sound_chase,
        loop = true,
        duration = VOID_CONFIG.duration_chase_loop,
    },
    [VOID_AUDIO_PARALYSIS] = {
        path = VOID_CONFIG.sound_paralysis,
        loop = false,
        duration = VOID_CONFIG.duration_paralysis_sound,
    },
    [VOID_AUDIO_HYPER] = {
        path = VOID_CONFIG.sound_hyper_loop,
        loop = true,
        duration = VOID_CONFIG.duration_hyper_loop,
    },
}

local function StopEntityAudioChannels(state)
    if not state then return end
    state.reqToken = (state.reqToken or 0) + 1
    if IsValid(state.loopChannel) then
        state.loopChannel:Stop()
    end
    if IsValid(state.screamChannel) then
        state.screamChannel:Stop()
    end
    state.loopChannel = nil
    state.screamChannel = nil
    state.openingLoop = false
end

local function DestroyEntityAudioState(entIndex)
    local state = VOID_ClientAudioStates[entIndex]
    if not state then return end
    StopEntityAudioChannels(state)
    VOID_ClientAudioStates[entIndex] = nil
    VOID_ClientCloakUntil[entIndex] = nil
end

local function ComputeDesiredVolume(bot, mode)
    if mode == VOID_AUDIO_HYPER then
        return 1.0
    end

    local lp = LocalPlayer()
    if not IsValid(lp) or not IsValid(bot) then
        return 1.0
    end

    local dist = lp:EyePos():Distance(bot:GetPos())

    if mode == VOID_AUDIO_IDLE then
        local nearDist = 250.0
        local farDist = VOID_CONFIG.volume_idle_falloff_dist or 1800.0
        if dist <= nearDist then
            return VOID_CONFIG.volume_idle_max
        elseif dist >= farDist then
            return VOID_CONFIG.volume_idle_min
        else
            local frac = (dist - nearDist) / (farDist - nearDist)
            return Lerp(frac, VOID_CONFIG.volume_idle_max, VOID_CONFIG.volume_idle_min)
        end

    elseif mode == VOID_AUDIO_CHASE then
        if bot.GetCurrentTarget and bot:GetCurrentTarget() == lp then
            return VOID_CONFIG.volume_chase_target
        end
        if dist <= 650.0 then
            return VOID_CONFIG.volume_chase_target
        elseif dist >= 2200.0 then
            return VOID_CONFIG.volume_chase_min
        else
            local frac = (dist - 650.0) / (2200.0 - 650.0)
            return Lerp(frac, VOID_CONFIG.volume_chase_target, VOID_CONFIG.volume_chase_min)
        end

    elseif mode == VOID_AUDIO_PARALYSIS then
        if dist <= 700.0 then
            return 1.0
        elseif dist >= 2000.0 then
            return 0.25
        else
            local frac = (dist - 700.0) / (2000.0 - 700.0)
            return Lerp(frac, 1.0, 0.25)
        end
    end

    return 0.0
end

local function TransitionEntityAudioMode(entIndex, bot, newMode, playHyperScream)
    local state = VOID_ClientAudioStates[entIndex]
    if not state then
        state = {
            activeMode = VOID_AUDIO_NONE,
            reqToken = 0,
            loopChannel = nil,
            screamChannel = nil,
            openingLoop = false,
            nextLoopAt = 0,
            chaseHoldUntil = 0,
            retryAfter = 0,
        }
        VOID_ClientAudioStates[entIndex] = state
    end

    local modeChanged = (state.activeMode ~= newMode)
    StopEntityAudioChannels(state)
    state.activeMode = newMode
    if modeChanged then
        state.retryAfter = 0
    end

    if newMode == VOID_AUDIO_NONE then
        return
    end

    local info = MODE_SOUND_INFO[newMode]
    if not info then
        return
    end

    local myToken = state.reqToken

    if newMode == VOID_AUDIO_HYPER and playHyperScream then
        sound.PlayFile("sound/" .. VOID_CONFIG.sound_hyper_scream, "noplay", function(station)
            if not VOID_ClientAudioStates[entIndex] or state.reqToken ~= myToken then
                if IsValid(station) then station:Stop() end
                return
            end
            if IsValid(station) then
                state.screamChannel = station
                station:SetVolume(1.0)
                station:Play()
            else
                surface.PlaySound(VOID_CONFIG.sound_hyper_scream)
            end
        end)
    end

    state.openingLoop = true
    sound.PlayFile("sound/" .. info.path, "noplay", function(station)
        if not VOID_ClientAudioStates[entIndex] or state.reqToken ~= myToken then
            if IsValid(station) then station:Stop() end
            return
        end
        state.openingLoop = false
        if IsValid(station) then
            state.retryAfter = 0
            state.loopChannel = station
            station:SetVolume(ComputeDesiredVolume(Entity(entIndex), newMode))
            station:Play()
            state.nextLoopAt = RealTime() + math.max(0.5, info.duration - 0.04)
        else
            state.retryAfter = RealTime() + 2.0
            if newMode == VOID_AUDIO_HYPER then
                surface.PlaySound(info.path)
            end
        end
    end)
end

-- ============================================================================
-- RECEPTORES DE RED (Audio Global, Paranoia y Enmascaramiento de Teletransporte)
-- ============================================================================
net.Receive("Void_PlayGlobalAudio", function()
    local entIndex = net.ReadUInt(16)
    local playScream = net.ReadBool()
    local bot = Entity(entIndex)
    if IsValid(bot) then
        bot.VoidAudioRemoved = false
    end
    TransitionEntityAudioMode(entIndex, bot, VOID_AUDIO_HYPER, playScream)
end)

net.Receive("Void_StopGlobalAudio", function()
    local entIndex = net.ReadUInt(16)
    local isRemoving = net.ReadBool()
    if entIndex == 0 then
        for idx, _ in pairs(VOID_ClientAudioStates) do
            DestroyEntityAudioState(idx)
        end
    elseif isRemoving then
        local bot = Entity(entIndex)
        if IsValid(bot) then
            bot.VoidAudioRemoved = true
        end
        DestroyEntityAudioState(entIndex)
    else
        local state = VOID_ClientAudioStates[entIndex]
        if state and state.activeMode == VOID_AUDIO_HYPER then
            local bot = Entity(entIndex)
            local botMode = IsValid(bot) and ((bot.GetAudioMode and bot:GetAudioMode()) or bot:GetNWInt("VoidAudioMode", VOID_AUDIO_IDLE)) or VOID_AUDIO_NONE
            if IsValid(bot) and not bot.VoidAudioRemoved and botMode ~= VOID_AUDIO_NONE then
                TransitionEntityAudioMode(entIndex, bot, VOID_AUDIO_IDLE, false)
            else
                DestroyEntityAudioState(entIndex)
            end
        end
    end
end)

net.Receive("Void_TeleportCloak", function()
    local entIndex = net.ReadUInt(16)
    local duration = net.ReadFloat()
    VOID_ClientCloakUntil[entIndex] = RealTime() + math.Clamp(duration or 0.28, 0.05, 2.0)
    local bot = Entity(entIndex)
    if IsValid(bot) then
        bot.LastDrawWorldPos = nil
    end
end)

net.Receive("Void_PlayParanoiaSound", function()
    local sndRelPath = net.ReadString()
    local emitPos = net.ReadVector()
    if not sndRelPath or sndRelPath == "" then
        return
    end

    sound.PlayFile("sound/" .. sndRelPath, "3d noplay", function(station)
        if IsValid(station) then
            station:SetPos(emitPos)
            station:Set3DFadeDistance(280, 3200)
            station:SetVolume(VOID_CONFIG.volume_paranoia or 1.0)
            station:Play()
            VOID_ParanoiaActiveChannels[#VOID_ParanoiaActiveChannels + 1] = {
                ch = station,
                expire = RealTime() + 35.0,
            }
        else
            sound.PlayFile("sound/" .. sndRelPath, "noplay", function(st2d)
                if IsValid(st2d) then
                    st2d:SetVolume(0.88)
                    st2d:Play()
                    VOID_ParanoiaActiveChannels[#VOID_ParanoiaActiveChannels + 1] = {
                        ch = st2d,
                        expire = RealTime() + 35.0,
                    }
                else
                    surface.PlaySound(sndRelPath)
                end
            end)
        end
    end)
end)

-- ============================================================================
-- FILTRO DE COLOR GRISÁCEO ATMOSFÉRICO MIENTRAS VØID ESTÁ EN EL MAPA (#5)
-- Se aplica al instante al spawnear a VØID y desaparece de inmediato al borrarlo
-- ============================================================================
local VOID_ColorModifyTab = {
    ["$pp_colour_addr"] = 0,
    ["$pp_colour_addg"] = 0,
    ["$pp_colour_addb"] = 0.008,
    ["$pp_colour_brightness"] = -0.015,
    ["$pp_colour_contrast"] = 1.05,
    ["$pp_colour_colour"] = 0.38,
    ["$pp_colour_mulr"] = 0,
    ["$pp_colour_mulg"] = 0,
    ["$pp_colour_mulb"] = 0,
}

hook.Add("RenderScreenspaceEffects", "Void_AtmosphericColorFilter", function()
    local bots = ents.FindByClass("npc_void")
    local anyActive = false
    for i = 1, #bots do
        if IsValid(bots[i]) then
            anyActive = true
            break
        end
    end

    if not anyActive then
        return
    end

    VOID_ColorModifyTab["$pp_colour_brightness"] = VOID_CONFIG.color_filter_brightness or -0.015
    VOID_ColorModifyTab["$pp_colour_contrast"] = VOID_CONFIG.color_filter_contrast or 1.05
    VOID_ColorModifyTab["$pp_colour_colour"] = VOID_CONFIG.color_filter_saturation or 0.38
    DrawColorModify(VOID_ColorModifyTab)
end)

-- ============================================================================
-- ACTUALIZACIÓN CONTINUA POR FRAME DEL DIRECTOR DE AUDIO
-- ============================================================================
hook.Add("Think", "Void_ClientAudioDirector", function()
    local now = RealTime()
    local seenIndices = {}

    for _, bot in ipairs(ents.FindByClass("npc_void")) do
        if IsValid(bot) and not bot.VoidAudioRemoved then
            local idx = bot:EntIndex()
            seenIndices[idx] = true

            local state = VOID_ClientAudioStates[idx]
            if not state then
                state = {
                    activeMode = VOID_AUDIO_NONE,
                    reqToken = 0,
                    loopChannel = nil,
                    screamChannel = nil,
                    openingLoop = false,
                    nextLoopAt = 0,
                    chaseHoldUntil = 0,
                    retryAfter = 0,
                }
                VOID_ClientAudioStates[idx] = state
            end

            local rawMode = (bot.GetAudioMode and bot:GetAudioMode()) or bot:GetNWInt("VoidAudioMode", VOID_AUDIO_IDLE)
            if bot.GetIsHyper and bot:GetIsHyper() then
                rawMode = VOID_AUDIO_HYPER
            end

            local effectiveMode = rawMode
            if rawMode == VOID_AUDIO_CHASE then
                state.chaseHoldUntil = now + (VOID_CONFIG.chase_audio_hold_time or 0.65)
            elseif rawMode == VOID_AUDIO_IDLE and now < (state.chaseHoldUntil or 0) then
                effectiveMode = VOID_AUDIO_CHASE
            end

            if effectiveMode ~= state.activeMode then
                local wantScream = (effectiveMode == VOID_AUDIO_HYPER)
                TransitionEntityAudioMode(idx, bot, effectiveMode, wantScream)
            else
                local ch = state.loopChannel
                local info = MODE_SOUND_INFO[effectiveMode]
                if IsValid(ch) and info then
                    ch:SetVolume(ComputeDesiredVolume(bot, effectiveMode))
                    if info.loop then
                        if ch:GetState() ~= GMOD_CHANNEL_PLAYING or now >= state.nextLoopAt then
                            ch:SetTime(0)
                            ch:Play()
                            state.nextLoopAt = now + math.max(0.5, info.duration - 0.04)
                        end
                    end
                elseif info and info.loop and not state.openingLoop and effectiveMode ~= VOID_AUDIO_NONE and now >= (state.retryAfter or 0) then
                    TransitionEntityAudioMode(idx, bot, effectiveMode, false)
                end
            end
        end
    end

    for idx, _ in pairs(VOID_ClientAudioStates) do
        if not seenIndices[idx] and not IsValid(Entity(idx)) then
            DestroyEntityAudioState(idx)
        end
    end

    for i = #VOID_ParanoiaActiveChannels, 1, -1 do
        local item = VOID_ParanoiaActiveChannels[i]
        if not item or now >= item.expire or not IsValid(item.ch) then
            table.remove(VOID_ParanoiaActiveChannels, i)
        end
    end
end)

-- ============================================================================
-- CICLO DE VIDA Y RENDERIZADO BILLBOARD 2D SIN FRAMES FANTASMA (#3)
-- ============================================================================
function ENT:Initialize()
    self:DrawShadow(false)
    self:SetRenderBounds(Vector(-96, -96, -16), Vector(96, 96, 140))
    self.VoidRenderBoundsApplied = true
    self.LastDrawWorldPos = nil
    self.LastDrawTime = 0
    self.SuppressInterpUntil = 0
end

function ENT:Think()
    if not self.VoidRenderBoundsApplied then
        self:SetRenderBounds(Vector(-96, -96, -16), Vector(96, 96, 140))
        self.VoidRenderBoundsApplied = true
    end
end

function ENT:Draw()
end

function ENT:DrawTranslucent()
    local now = RealTime()
    local idx = self:EntIndex()

    -- Capa 1: Supresión explícita pre-teletransporte desde servidor (cero movimiento visible)
    local isCloaked = (self.GetTeleportCloak and self:GetTeleportCloak())
        or self:GetNWBool("VoidTeleportCloak", false)
        or (VOID_ClientCloakUntil[idx] and now < VOID_ClientCloakUntil[idx])

    if isCloaked then
        self.LastDrawWorldPos = nil
        self.LastDrawTime = 0
        return
    end

    local worldPos = self:GetPos()
    local isFlying = (self.GetIsFlyingHyper and self:GetIsFlyingHyper()) or self:GetNWBool("VoidFlyingHyper", false)
    local maxStepPerFrame = isFlying and 360 or 165

    -- Capa 2: Guardia instantánea contra interpolación cl_interp de Source tras SetPos() (independiente de FPS)
    if self.LastDrawWorldPos then
        local jumpSqr = worldPos:DistToSqr(self.LastDrawWorldPos)
        local dt = now - (self.LastDrawTime or now)
        local isInterpSpike = (jumpSqr > (maxStepPerFrame * maxStepPerFrame))
        if not isInterpSpike and not isFlying and dt > 0.0005 and jumpSqr > (28 * 28) then
            local apparentSpeed = math.sqrt(jumpSqr) / dt
            if apparentSpeed > 1650 then
                isInterpSpike = true
            end
        end
        if isInterpSpike then
            self.SuppressInterpUntil = now + 0.22
            self.LastDrawWorldPos = worldPos
            self.LastDrawTime = now
            return
        end
    end
    self.LastDrawWorldPos = worldPos
    self.LastDrawTime = now

    if self.SuppressInterpUntil and now < self.SuppressInterpUntil then
        return
    end

    local activeMat = self:GetIsHyper() and MAT_FACE_HYPER or MAT_FACE_BASE
    if not activeMat or activeMat:IsError() then
        return
    end

    local center = worldPos + Vector(0, 0, VOID_CONFIG.sprite_z_offset)
    local eyeAng = EyeAngles()

    local billAng = Angle(math.Clamp(eyeAng.p * 0.25, -15, 15), eyeAng.y, 0)
    local right = billAng:Right()
    local up = billAng:Up()

    local halfW = VOID_CONFIG.sprite_width * 0.5
    local halfH = VOID_CONFIG.sprite_height * 0.5

    local topLeft = center - right * halfW + up * halfH
    local topRight = center + right * halfW + up * halfH
    local bottomRight = center + right * halfW - up * halfH
    local bottomLeft = center - right * halfW - up * halfH

    render.SetMaterial(activeMat)
    render.DrawQuad(topLeft, topRight, bottomRight, bottomLeft, COLOR_WHITE)
end

function ENT:OnRemove()
    self.VoidAudioRemoved = true
    local entIndex = self:EntIndex()
    DestroyEntityAudioState(entIndex)
    timer.Simple(0, function()
        if not IsValid(self) and not IsValid(Entity(entIndex)) then
            DestroyEntityAudioState(entIndex)
        end
    end)
end
