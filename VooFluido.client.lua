--!nocheck
-- VooFluido.client.lua
-- LocalScript em StarterPlayer > StarterPlayerScripts
-- Compatível com personagens padrão R6 e R15.
-- Animação procedural: não exige assets de animação.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")

local player = Players.LocalPlayer

---------------------------------------------------------------------
-- CONFIGURAÇÃO
---------------------------------------------------------------------

local CONFIG = {
    Speed = 44,
    BoostSpeed = 78,
    VerticalSpeed = 34,

    Acceleration = 5.5,
    Deceleration = 7.5,

    OrientationResponsiveness = 16,
    PoseResponsiveness = 11,

    EnterResponsiveness = 8,
    ExitResponsiveness = 12,

    MaxBodyPitch = 34,
    MaxBodyBank = 25,

    IdleBobSpeed = 1.7,
    IdleBobAmount = 0.10,

    WindFrequency = 7,
    WindAmount = 1.3,

    InputPriority = Enum.ContextActionPriority.High.Value + 10,
}

local ACTION = {
    Toggle = "ProceduralFlight_Toggle",
    Up = "ProceduralFlight_Up",
    Down = "ProceduralFlight_Down",
    Boost = "ProceduralFlight_Boost",
}

local ZERO = Vector3.zero
local IDENTITY = CFrame.new()

local character
local humanoid
local root
local animateScript

local attachment
local linearVelocity
local alignOrientation

local flying = false
local posing = false
local poseWeight = 0
local clock = 0

local velocity = ZERO
local lastForward = Vector3.new(0, 0, -1)

local motors = {}
local savedState = nil
local diedConnection
local setupVersion = 0

local held = {
    Up = false,
    Down = false,
    Boost = false,
}

---------------------------------------------------------------------
-- UTILITÁRIOS
---------------------------------------------------------------------

local function expAlpha(rate, dt)
    return 1 - math.exp(-rate * dt)
end

local function smoothNumber(current, target, rate, dt)
    return current + (target - current) * expAlpha(rate, dt)
end

local function normalizedOr(vector, fallback)
    if vector.Magnitude > 0.001 then
        return vector.Unit
    end

    return fallback
end

local function angle(x, y, z)
    return CFrame.Angles(
        math.rad(x),
        math.rad(y),
        math.rad(z)
    )
end

local function resetInput()
    held.Up = false
    held.Down = false
    held.Boost = false
end

local function destroyActuators()
    if linearVelocity then
        linearVelocity:Destroy()
        linearVelocity = nil
    end

    if alignOrientation then
        alignOrientation:Destroy()
        alignOrientation = nil
    end

    if attachment then
        attachment:Destroy()
        attachment = nil
    end
end

local function collectMotors()
    table.clear(motors)

    if not character then
        return
    end

    for _, object in character:GetDescendants() do
        if object:IsA("Motor6D") then
            local key = object.Name:gsub("%s+", ""):lower()

            motors[key] = {
                Joint = object,
                Base = object.C0,
                Offset = IDENTITY,
            }
        end
    end
end

---------------------------------------------------------------------
-- POSES PROCEDURAIS
---------------------------------------------------------------------

-- Os offsets são aplicados no espaço local de cada articulação.
-- As poses retornam suavemente ao estado original ao encerrar o voo.

local function restoreMotors()
    for _, data in pairs(motors) do
        if data.Joint.Parent then
            data.Joint.C0 = data.Base
        end

        data.Offset = IDENTITY
    end
end

local function updatePose(dt)
    if not posing or not humanoid or not root then
        return
    end

    local weightTarget = flying and 1 or 0
    local response = flying
        and CONFIG.EnterResponsiveness
        or CONFIG.ExitResponsiveness

    poseWeight = smoothNumber(
        poseWeight,
        weightTarget,
        response,
        dt
    )

    local localVelocity = root.CFrame:VectorToObjectSpace(velocity)

    local forwardAmount = math.clamp(
        -localVelocity.Z / CONFIG.BoostSpeed,
        -1,
        1
    )

    local sideAmount = math.clamp(
        localVelocity.X / CONFIG.Speed,
        -1,
        1
    )

    local speedAmount = math.clamp(
        velocity.Magnitude / CONFIG.BoostSpeed,
        0,
        1
    )

    local breathing = math.sin(clock * 2.2)
    local bob = math.sin(clock * CONFIG.IdleBobSpeed)
        * CONFIG.IdleBobAmount

    local wind = math.sin(clock * CONFIG.WindFrequency)
        * CONFIG.WindAmount
        * speedAmount

    local flutter = math.sin(clock * 3.1 + 0.8)
    local moving = math.abs(forwardAmount)

    local targets = {}

    if humanoid.RigType == Enum.HumanoidRigType.R15 then
        targets.root = CFrame.new(0, bob, 0)
            * angle(
                -3 * forwardAmount,
                -sideAmount * 3,
                -sideAmount * 3
            )

        targets.waist = angle(
            -5 * forwardAmount + breathing * 0.8,
            -sideAmount * 4,
            -sideAmount * 4
        )

        targets.neck = angle(
            forwardAmount * 16 - breathing,
            -sideAmount * 5,
            sideAmount * 3
        )

        -- Braços relaxados na flutuação, abertos durante manobras.
        targets.rightshoulder = angle(
            8 + moving * 22 + wind,
            -5 - sideAmount * 5,
            12 + moving * 10 + sideAmount * 8
        )

        targets.leftshoulder = angle(
            8 + moving * 22 - wind,
            5 - sideAmount * 5,
            -12 - moving * 10 + sideAmount * 8
        )

        targets.rightelbow = angle(
            -12 - moving * 16 + flutter * 2,
            0,
            0
        )

        targets.leftelbow = angle(
            -12 - moving * 16 - flutter * 2,
            0,
            0
        )

        targets.rightwrist = angle(
            -4 + wind * 0.5,
            0,
            5
        )

        targets.leftwrist = angle(
            -4 - wind * 0.5,
            0,
            -5
        )

        targets.righthip = angle(
            -7 - moving * 8 + flutter * 2,
            -3,
            5 + sideAmount * 3
        )

        targets.lefthip = angle(
            -10 - moving * 8 - flutter * 2,
            3,
            -5 + sideAmount * 3
        )

        targets.rightknee = angle(
            12 + moving * 9 + breathing * 2,
            0,
            0
        )

        targets.leftknee = angle(
            17 + moving * 9 - breathing * 2,
            0,
            0
        )

        targets.rightankle = angle(-10 - moving * 12, 0, 0)
        targets.leftankle = angle(-10 - moving * 12, 0, 0)
    else
        -- No R6, os eixos locais das juntas são diferentes.
        -- A inclinação principal é feita no HumanoidRootPart.
        targets.rootjoint = CFrame.new(0, 0, -bob)
            * angle(breathing * 0.7, 0, -sideAmount * 3)

        targets.neck = angle(
            -forwardAmount * 16 + breathing,
            0,
            -sideAmount * 4
        )

        targets.rightshoulder = angle(
            wind * 0.5,
            8 + moving * 20,
            12 + moving * 12 + sideAmount * 7
        )

        targets.leftshoulder = angle(
            -wind * 0.5,
            -8 - moving * 20,
            -12 - moving * 12 + sideAmount * 7
        )

        targets.righthip = angle(
            flutter,
            -3,
            6 + moving * 10 + breathing
        )

        targets.lefthip = angle(
            -flutter,
            3,
            -9 - moving * 10 + breathing
        )
    end

    local alpha = expAlpha(CONFIG.PoseResponsiveness, dt)

    for name, data in pairs(motors) do
        local joint = data.Joint

        if joint.Parent then
            local desired = targets[name] or IDENTITY
            local weighted = IDENTITY:Lerp(desired, poseWeight)

            data.Offset = data.Offset:Lerp(weighted, alpha)
            joint.C0 = data.Base * data.Offset
        end
    end
end

---------------------------------------------------------------------
-- CONTROLE DAS ANIMAÇÕES PADRÃO
---------------------------------------------------------------------

local function stopAnimationTracks()
    if not humanoid then
        return
    end


    local animator = humanoid:FindFirstChildOfClass("Animator")

    if animator then
        for _, track in animator:GetPlayingAnimationTracks() do
            track:Stop(0.15)
        end
    end
end

local function finishPose()
    restoreMotors()

    if animateScript and animateScript.Parent and savedState then
        animateScript.Disabled = savedState.AnimateDisabled
    end

    posing = false
    poseWeight = 0
    savedState = nil
end

---------------------------------------------------------------------
-- ATIVAR / DESATIVAR
---------------------------------------------------------------------

local function stopFlight(immediate)
    local wasFlying = flying
    flying = false

    resetInput()
    destroyActuators()

    if humanoid and humanoid.Parent and savedState then
        humanoid.AutoRotate = savedState.AutoRotate

        if wasFlying and humanoid.Health > 0 then
            humanoid:ChangeState(Enum.HumanoidStateType.Freefall)
        end
    end

    if immediate then
        velocity = ZERO
        finishPose()
    end
end

local function startFlight()
    if flying then
        return
    end

    if not character or not humanoid or not root then
        return
    end

    if humanoid.Health <= 0 or root.Anchored or humanoid.SeatPart then
        return
    end

    -- Finaliza uma transição de saída anterior antes de recomeçar.
    if posing then
        finishPose()
    end

    -- Captura novamente as bases, respeitando alterações do avatar.
    collectMotors()

    savedState = {
        AutoRotate = humanoid.AutoRotate,
        AnimateDisabled = animateScript and animateScript.Disabled or false,
    }

    if animateScript then
        animateScript.Disabled = true
    end

    stopAnimationTracks()
    resetInput()

    humanoid.AutoRotate = false
    humanoid.Jump = false
    humanoid:ChangeState(Enum.HumanoidStateType.Physics)

    local look = root.CFrame.LookVector
    lastForward = normalizedOr(
        Vector3.new(look.X, 0, look.Z),
        Vector3.new(0, 0, -1)
    )

    velocity = root.AssemblyLinearVelocity

    -- Evita herdar velocidades extremas de uma queda ou impulso.
    if velocity.Magnitude > CONFIG.BoostSpeed then
        velocity = velocity.Unit * CONFIG.BoostSpeed
    end

    attachment = Instance.new("Attachment")
    attachment.Name = "ProceduralFlightAttachment"
    attachment.Parent = root

    linearVelocity = Instance.new("LinearVelocity")
    linearVelocity.Name = "ProceduralFlightVelocity"
    linearVelocity.Attachment0 = attachment
    linearVelocity.RelativeTo = Enum.ActuatorRelativeTo.World
    linearVelocity.VelocityConstraintMode =
        Enum.VelocityConstraintMode.Vector
    linearVelocity.ForceLimitsEnabled = false
    linearVelocity.VectorVelocity = velocity
    linearVelocity.Parent = root

    alignOrientation = Instance.new("AlignOrientation")
    alignOrientation.Name = "ProceduralFlightOrientation"
    alignOrientation.Attachment0 = attachment
    alignOrientation.Mode =
        Enum.OrientationAlignmentMode.OneAttachment
    alignOrientation.RigidityEnabled = false
    alignOrientation.Responsiveness =
        CONFIG.OrientationResponsiveness
    alignOrientation.MaxTorque = math.huge
    alignOrientation.MaxAngularVelocity = math.rad(360)
    alignOrientation.CFrame = CFrame.lookAt(ZERO, lastForward)
    alignOrientation.Parent = root

    clock = 0
    poseWeight = 0
    posing = true
    flying = true
end

---------------------------------------------------------------------
-- MOVIMENTO
---------------------------------------------------------------------

local function updateFlight(dt)
    if not flying then
        return
    end

    if not humanoid or not root or not root.Parent then
        stopFlight(true)
        return
    end

    if humanoid.Health <= 0 then
        stopFlight(true)
        return
    end

    if root.Anchored or humanoid.SeatPart then
        stopFlight(false)
        return
    end

    local camera = workspace.CurrentCamera
    local forward = lastForward

    if camera then
        local cameraLook = camera.CFrame.LookVector
        local flatLook = Vector3.new(cameraLook.X, 0, cameraLook.Z)

        -- Mantém a orientação anterior ao olhar totalmente para cima/baixo.
        if flatLook.Magnitude > 0.05 then
            forward = flatLook.Unit
        end
    end

    lastForward = forward

    -- MoveDirection usa os controles padrão do Roblox:
    -- teclado, controle e analógico virtual.
    local move = humanoid.MoveDirection
    local horizontalMove = Vector3.new(move.X, 0, move.Z)

    if horizontalMove.Magnitude > 1 then
        horizontalMove = horizontalMove.Unit
    end

    local verticalInput =
        (held.Up and 1 or 0) - (held.Down and 1 or 0)

    local speed = held.Boost
        and CONFIG.BoostSpeed
        or CONFIG.Speed


    local verticalSpeed = CONFIG.VerticalSpeed
        * (held.Boost and 1.35 or 1)

    local targetVelocity = horizontalMove * speed
        + Vector3.new(0, verticalInput * verticalSpeed, 0)

    local hasInput = horizontalMove.Magnitude > 0.01
        or verticalInput ~= 0

    local response = hasInput
        and CONFIG.Acceleration
        or CONFIG.Deceleration

    velocity = velocity:Lerp(
        targetVelocity,
        expAlpha(response, dt)
    )

    if not hasInput and velocity.Magnitude < 0.03 then
        velocity = ZERO
    end

    if linearVelocity then
        linearVelocity.VectorVelocity = velocity
    end

    -- Inclinação proporcional à velocidade real suavizada.
    local facing = CFrame.lookAt(ZERO, forward)
    local relativeVelocity = facing:VectorToObjectSpace(velocity)

    local forwardRatio = math.clamp(
        -relativeVelocity.Z / CONFIG.BoostSpeed,
        -1,
        1
    )

    local sideRatio = math.clamp(
        relativeVelocity.X / CONFIG.BoostSpeed,
        -1,
        1
    )

    local pitch = -forwardRatio * CONFIG.MaxBodyPitch
    local bank = -sideRatio * CONFIG.MaxBodyBank

    if alignOrientation then
        alignOrientation.CFrame = facing * angle(pitch, 0, bank)
    end

    -- Impede que o botão padrão de pulo gere saltos durante o voo.
    humanoid.Jump = false
end

---------------------------------------------------------------------
-- ENTRADAS: TECLADO, CONTROLE E TOUCH
---------------------------------------------------------------------

local function handleAction(actionName, inputState)
    local began = inputState == Enum.UserInputState.Begin
    local ended = inputState == Enum.UserInputState.End
        or inputState == Enum.UserInputState.Cancel

    if actionName == ACTION.Toggle then
        if UserInputService:GetFocusedTextBox() then
            return Enum.ContextActionResult.Pass
        end

        if began then
            if flying then
                stopFlight(false)
            else
                startFlight()
            end
        end

        return Enum.ContextActionResult.Sink
    end

    local inputKey

    if actionName == ACTION.Up then
        inputKey = "Up"
    elseif actionName == ACTION.Down then
        inputKey = "Down"
    elseif actionName == ACTION.Boost then
        inputKey = "Boost"
    end

    if not inputKey then
        return Enum.ContextActionResult.Pass
    end

    -- Sempre libera o estado, inclusive se o voo terminou
    -- enquanto o botão ainda estava pressionado.
    if ended then
        held[inputKey] = false
    end

    if not flying or UserInputService:GetFocusedTextBox() then
        return Enum.ContextActionResult.Pass
    end

    if began then
        held[inputKey] = true
    end

    return Enum.ContextActionResult.Sink
end

local function bindControls()
    ContextActionService:BindActionAtPriority(
        ACTION.Toggle,
        handleAction,
        true,
        CONFIG.InputPriority,
        Enum.KeyCode.F,
        Enum.KeyCode.ButtonY
    )

    ContextActionService:BindActionAtPriority(
        ACTION.Up,
        handleAction,
        true,
        CONFIG.InputPriority,
        Enum.KeyCode.Space,
        Enum.KeyCode.ButtonA
    )

    ContextActionService:BindActionAtPriority(
        ACTION.Down,
        handleAction,
        true,
        CONFIG.InputPriority,
        Enum.KeyCode.LeftControl,
        Enum.KeyCode.ButtonB
    )

    ContextActionService:BindActionAtPriority(
        ACTION.Boost,
        handleAction,
        true,
        CONFIG.InputPriority,
        Enum.KeyCode.LeftShift,
        Enum.KeyCode.ButtonR1
    )

    ContextActionService:SetTitle(ACTION.Toggle, "VOO")
    ContextActionService:SetTitle(ACTION.Up, "SUBIR")
    ContextActionService:SetTitle(ACTION.Down, "DESCER")
    ContextActionService:SetTitle(ACTION.Boost, "TURBO")

    ContextActionService:SetPosition(
        ACTION.Toggle,
        UDim2.new(1, -240, 1, -230)
    )

    ContextActionService:SetPosition(
        ACTION.Up,
        UDim2.new(1, -160, 1, -230)
    )

    ContextActionService:SetPosition(
        ACTION.Down,
        UDim2.new(1, -160, 1, -150)
    )

    ContextActionService:SetPosition(
        ACTION.Boost,
        UDim2.new(1, -240, 1, -150)
    )
end

---------------------------------------------------------------------
-- PERSONAGEM / RESPAWN
---------------------------------------------------------------------

local function setupCharacter(newCharacter)
    setupVersion += 1
    local version = setupVersion

    stopFlight(true)

    if diedConnection then
        diedConnection:Disconnect()
        diedConnection = nil
    end

    character = newCharacter
    humanoid = nil
    root = nil
    animateScript = nil

    table.clear(motors)

    local newHumanoid = newCharacter:WaitForChild("Humanoid", 10)
    local newRoot = newCharacter:WaitForChild("HumanoidRootPart", 10)

    if version ~= setupVersion then
        return
    end

    if player.Character ~= newCharacter then
        return
    end


    if not newHumanoid or not newRoot then
        warn("[VooFluido] Humanoid ou HumanoidRootPart não encontrado.")
        return
    end

    if not newHumanoid:IsA("Humanoid")
        or not newRoot:IsA("BasePart") then
        return
    end

    -- Aguarda o script padrão de animação, quando presente.
    local newAnimate = newCharacter:FindFirstChild("Animate")
        or newCharacter:WaitForChild("Animate", 5)

    -- O personagem pode ter sido substituído durante a espera.
    if version ~= setupVersion
        or player.Character ~= newCharacter then
        return
    end

    humanoid = newHumanoid
    root = newRoot

    if newAnimate and newAnimate:IsA("LocalScript") then
        animateScript = newAnimate
    end

    velocity = ZERO
    clock = 0
    poseWeight = 0
    flying = false
    posing = false

    resetInput()
    collectMotors()

    diedConnection = humanoid.Died:Connect(function()
        if version ~= setupVersion then
            return
        end

        stopFlight(true)
    end)
end

---------------------------------------------------------------------
-- LOOP PRINCIPAL
---------------------------------------------------------------------

local connections = {}
local shuttingDown = false

bindControls()

-- PreSimulation acontece depois da avaliação das animações
-- e antes da simulação física.
connections[#connections + 1] = RunService.PreSimulation:Connect(
    function(deltaTime)
        if shuttingDown then
            return
        end

        -- Limita saltos de tempo após travamentos ou perda de foco.
        local dt = math.clamp(deltaTime, 0, 1 / 15)

        if flying then
            updateFlight(dt)
        end

        if posing then
            clock += dt
            updatePose(dt)

            if not flying and poseWeight < 0.001 then
                finishPose()
            end
        end
    end
)

---------------------------------------------------------------------
-- PROTEÇÕES DE ENTRADA
---------------------------------------------------------------------

connections[#connections + 1] =
    UserInputService.WindowFocusReleased:Connect(function()
        resetInput()
    end)

connections[#connections + 1] =
    UserInputService.TextBoxFocused:Connect(function()
        resetInput()
    end)

---------------------------------------------------------------------
-- CICLO DE VIDA
---------------------------------------------------------------------

connections[#connections + 1] =
    player.CharacterAdded:Connect(function(newCharacter)
        if not shuttingDown then
            setupCharacter(newCharacter)
        end
    end)

connections[#connections + 1] =
    player.CharacterRemoving:Connect(function(oldCharacter)
        if oldCharacter ~= character then
            return
        end

        -- Invalida qualquer configuração ainda aguardando objetos.
        setupVersion += 1

        stopFlight(true)

        if diedConnection then
            diedConnection:Disconnect()
            diedConnection = nil
        end

        character = nil
        humanoid = nil
        root = nil
        animateScript = nil

        table.clear(motors)
    end)

script.Destroying:Connect(function()
    shuttingDown = true
    setupVersion += 1

    stopFlight(true)

    if diedConnection then
        diedConnection:Disconnect()
        diedConnection = nil
    end

    for _, connection in ipairs(connections) do
        connection:Disconnect()
    end

    table.clear(connections)

    for _, actionName in pairs(ACTION) do
        ContextActionService:UnbindAction(actionName)
    end
end)

-- Também funciona se o personagem já existir quando o script iniciar.
local initialCharacter = player.Character

if initialCharacter then
    task.spawn(function()
        if not shuttingDown
            and player.Character == initialCharacter
            and character ~= initialCharacter then
            setupCharacter(initialCharacter)
        end
    end)
end

-- FIM DO ARQUIVO VooFluido.client.lua
