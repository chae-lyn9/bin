--// SafetyWrapper — auto-exit on error / anomaly / anticheat flag
--// wrap script ทั้งหมดข้างใน SafeRun()
local Safety = {}

-------------------------------------------------
-- CONFIG
-------------------------------------------------
Safety.Config = {
    ExitOnError       = true,    -- F9 error ใหม่ → ออกเลย
    ExitOnKick        = true,    -- โดน kick message → ออกเลย
    ExitOnHealthDrop  = true,    -- เลือดลดผิดปกติ (โดน flag) → ออก
    ExitOnTeleport    = true,    -- server ส่ง Teleport (ban เคลื่อนไหว) → ออก
    MaxErrors         = 3,       -- 容忍 error 3 ตัวก่อน exit (เริ่มครั้งแรกมันจะ error ปกติ)
    HealthDropThreshold = 30,    -- เลือดลดทีเดียว >30 → flag
    LogFile           = "safety_log.txt",
    SafeModePlaceIds  = {        -- เล่นที่นี่ไม่ exit (test place ของมึง)
        -- 000000000000,  -- ใส่ PlaceId test ของมึงตรงนี้
    },
}

-------------------------------------------------
-- STATE
-------------------------------------------------
local errorCount   = 0
local lastHealth   = 100
local isExiting    = false
local safePlace    = false

local function log(msg)
    local line = os.date("[%H:%M:%S] ") .. msg .. "\n"
    pcall(function()
        if writefile then
            local existing = (readfile and readfile(Safety.Config.LogFile)) or ""
            writefile(Safety.Config.LogFile, existing .. line)
        end
    end)
    warn("[SAFETY] " .. msg)
end

local function forceExit(reason)
    if isExiting then return end
    isExiting = true
    log("EXIT: " .. reason)

    -- ปิดทุก thread ที่มึงเปิดไว้
    if getgenv then
        getgenv().SafetyExit = true
    end

    -- ล้าง connection ทั้งหมด
    pcall(function()
        for _, conn in pairs(Safety._connections or {}) do
            pcall(function() conn:Disconnect() end)
        end
    end)

    -- ปิด script core บางตัว
    pcall(function()
        if syn and syn.queue_on_teleport then end -- ไม่ teleport กลับ
    end)

    -- แจ้งเตือนใน console แล้วหยุด
    warn("[SAFETY] Force exited: " .. reason)
    error("[SAFETY] " .. reason, 0) -- kill current script
end

Safety._connections = {}

function Safety.IsSafePlace()
    local placeId = game.PlaceId
    for _, id in pairs(Safety.Config.SafeModePlaceIds) do
        if placeId == id then
            return true
        end
    end
    return false
end

-------------------------------------------------
-- HOOK 1: F9 Output Error Detection
-- จับ error ใหม่ที่โผล่ใน Output → นับ → เกิน MaxErrors → ออก
-------------------------------------------------
function Safety.HookOutputErrors()
    if not hookfunction then return end

    -- จับผ่าน LogService (มีบาง executor รองรับ)
    pcall(function()
        local LogService = game:GetService("LogService")
        local conn = LogService.MessageOut:Connect(function(message, messageType)
            if messageType == Enum.MessageType.MessageError then
                errorCount = errorCount + 1
                log("Error detected #" .. errorCount .. ": " .. tostring(message))

                if errorCount >= Safety.Config.MaxErrors and Safety.Config.ExitOnError then
                    forceExit("Too many script errors in F9 output")
                end
            end

            -- จับ warning ที่มี keyword อันตราย
            local lower = string.lower(tostring(message))
            local dangerKeywords = {
                "exploit", "cheat", "hack detected",
                "suspicious", "flagged", "integrity",
                "remoteevent rejected", "invalid remote",
                "teleport rejected", "kick",
            }
            for _, kw in pairs(dangerKeywords) do
                if string.find(lower, kw) then
                    forceExit("Danger keyword in output: " .. kw)
                end
            end
        end)
        table.insert(Safety._connections, conn)
        log("Output error hook installed")
    end)
end

-------------------------------------------------
-- HOOK 2: Anti-Kick / Anti-Teleport
-- จับ LocalPlayer:Kick() และ Teleport() ของ server
-------------------------------------------------
function Safety.HookKickTeleport()
    if not hookmetamethod then return end

    -- จับ Kick
    pcall(function()
        local oldNamecall
        oldNamecall = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
            local method = getnamecallmethod()
            local args = {...}

            if method == "Kick" or method == "kick" then
                local reason = tostring(args[1] or "unknown")
                log("Kick detected: " .. reason)
                if Safety.Config.ExitOnKick then
                    forceExit("Kick detected: " .. reason)
                end
            end

            if method == "Teleport" or method == "TeleportToPlaceInstance" then
                local placeId = tostring(args[1] or "unknown")
                log("Server teleport detected → place: " .. placeId)
                if Safety.Config.ExitOnTeleport then
                    forceExit("Server teleport (possible ban): " .. placeId)
                end
            end

            return oldNamecall(self, ...)
        end))
        log("Kick/Teleport hook installed")
    end)
end

-------------------------------------------------
-- HOOK 3: Health Anomaly
-- เลือดลดทีเดียวเยอะผิดปกติ → น่าจะโดน flag → ออก
-------------------------------------------------
function Safety.HookHealth()
    local player = game.Players.LocalPlayer
    if not player or not player.Character then return end

    local humanoid = player.Character:FindFirstChildOfClass("Humanoid")
    if not humanoid then return end

    lastHealth = humanoid.Health

    local conn = humanoid.HealthChanged:Connect(function(newHealth)
        local drop = lastHealth - newHealth

        if drop > Safety.Config.HealthDropThreshold
           and not safePlace
           and Safety.Config.ExitOnHealthDrop then
            log("Health drop anomaly: -" .. drop)
            forceExit("Health anomaly (-" .. drop .. "), likely flagged")
        end

        lastHealth = newHealth
    end)
    table.insert(Safety._connections, conn)
    log("Health monitor installed")
end

-------------------------------------------------
-- HOOK 4: RemoteEvent/Function spam guard
-- ถ้ามึงเรียก remote ถี่เกินไป → เตือนก่อน exit
-------------------------------------------------
function Safety.HookRemotes()
    if not hookmetamethod then return end

    local remoteCallTimes = {}
    local MAX_CALLS_PER_SEC = 15

    pcall(function()
        local oldNamecall
        oldNamecall = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
            local method = getnamecallmethod()

            if method == "FireServer" or method == "InvokeServer" then
                local now = tick()
                local remoteName = tostring(self.Name)

                -- clean old entries
                if not remoteCallTimes[remoteName] then
                    remoteCallTimes[remoteName] = {}
                end
                local calls = remoteCallTimes[remoteName]
                table.insert(calls, now)

                -- keep last 2 sec
                while #calls > 0 and (now - calls[1]) > 2 do
                    table.remove(calls, 1)
                end

                local callsPerSec = #calls / 2
                if callsPerSec > MAX_CALLS_PER_SEC then
                    log("Remote spam: " .. remoteName .. " x" .. callsPerSec .. "/s")
                    forceExit("Remote spam detected: " .. remoteName)
                end
            end

            return oldNamecall(self, ...)
        end))
        log("Remote spam guard installed")
    end)
end

-------------------------------------------------
-- HOOK 5: Anomaly scanner (tick ทุก 5 วิ)
-- เช็ค WalkSpeed, ตําแหน่งกระโดด, gravity ผิดปกติ
-------------------------------------------------
function Safety.AnomalyScanner()
    local player = game.Players.LocalPlayer

    task.spawn(function()
        while not isExiting do
            task.wait(5)
            pcall(function()
                local char = player.Character
                if not char then return end
                local hum = char:FindFirstChildOfClass("Humanoid")
                local hrp = char:FindFirstChild("HumanoidRootPart")
                if not hum or not hrp then return end

                -- WalkSpeed ผิดปกติ (ค่า default = 16, สูงกว่า 50 น่าสงสัย)
                if hum.WalkSpeed > 50 and not safePlace then
                    log("WalkSpeed anomaly: " .. hum.WalkSpeed)
                    forceExit("WalkSpeed anomaly: " .. hum.WalkSpeed)
                end

                -- Gravity ผิดปกติ (default = 196.2)
                if workspace.Gravity < 50 and not safePlace then
                    log("Gravity anomaly: " .. workspace.Gravity)
                    forceExit("Gravity anomaly: " .. workspace.Gravity)
                end

                -- Position teleport ผิดธรรมชาติ (กระเด็น > 100 studs ใน 5 วิ)
                -- ใช้กับ上次 position
                if Safety._lastPos then
                    local dist = (hrp.Position - Safety._lastPos).Magnitude
                    if dist > 100 and not safePlace then
                        log("Position anomaly: " .. math.floor(dist) .. " studs in 5s")
                        forceExit("Position anomaly: " .. math.floor(dist) .. " studs")
                    end
                end
                Safety._lastPos = hrp.Position
            end)
        end
    end)
    log("Anomaly scanner started")
end

-------------------------------------------------
-- SAFE RUNNER — wrap โค้ดมึงทั้งหมดตรงนี้
-------------------------------------------------
function Safety.SafeRun(mainFunction)
    safePlace = Safety.IsSafePlace()

    if safePlace then
        log("Safe mode: test place detected, safety exits disabled")
    end

    -- ติด hooks ทั้งหมด
    Safety.HookOutputErrors()
    Safety.HookKickTeleport()
    Safety.HookRemotes()
    Safety.HookHealth()
    Safety.AnomalyScanner()

    -- รันโค้ดหลักของมึง
    log("Running main script...")
    local success, err = pcall(mainFunction)

    if not success then
        errorCount = errorCount + 1
        log("Main script error: " .. tostring(err))
        if errorCount >= Safety.Config.MaxErrors and Safety.Config.ExitOnError then
            forceExit("Main script errors exceeded limit")
        end
    end
end

-------------------------------------------------
-- AUTO-CLEANUP เมื่อ script หลุด
-------------------------------------------------
if CleanupOnTeleport then
    game:GetService("Players").LocalPlayer.OnTeleport:Connect(function()
        for _, conn in pairs(Safety._connections or {}) do
            pcall(function() conn:Disconnect() end)
        end
    end)
end

return Safety
