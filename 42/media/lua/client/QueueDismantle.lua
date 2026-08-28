require "ISUI/ISContextMenu"
require "ISUI/ISDisassembleMenu"
require "ISUI/ISWorldObjectContextMenu"
require "Moveables/ISMoveableSpriteProps"
require "TimedActions/ISBaseTimedAction"
require "TimedActions/ISTimedActionQueue"

QueueDismantle = QueueDismantle or {}

local MOD_TAG = "[QueueDismantle]"

local function logError(message)
    print(MOD_TAG .. " " .. tostring(message))
end

-- This zero-duration action expands one queued target into the same movement,
-- equipment and dismantling actions used by the vanilla Disassemble command.
--
-- It deliberately completes (rather than stops) when the target is no longer
-- valid. Stopping a timed action clears the actions behind it; completing it
-- lets the next queued dismantle target continue normally.
QueueDismantleDeferredAction = ISBaseTimedAction:derive("QueueDismantleDeferredAction")

function QueueDismantleDeferredAction:isValid()
    return true
end

function QueueDismantleDeferredAction:isValidStart()
    return true
end

function QueueDismantleDeferredAction:waitToStart()
    return false
end

function QueueDismantleDeferredAction:discardAddedActions()
    if self._isAddingActions and tonumber(self._numAddedActions) then
        -- While the current action is in beginAddingActions()/endAddingActions(),
        -- vanilla clear() removes only actions added by this action and preserves
        -- everything that was already waiting behind it.
        ISTimedActionQueue.clear(self.character)
    end
end

function QueueDismantleDeferredAction:update()
    -- Fallback used only if start() itself aborts unexpectedly.
    self:discardAddedActions()
    self._isAddingActions = nil
    self._numAddedActions = nil
    self:forceComplete()
end

function QueueDismantleDeferredAction:start()
    self:beginAddingActions()

    local ok, err = pcall(QueueDismantle.expandQueuedTarget, self.character, self.object)
    if not ok then
        self:discardAddedActions()
        logError("Failed to expand queued dismantle target: " .. tostring(err))
    end

    self:endAddingActions()

    -- Always complete, including when the target vanished, became invalid,
    -- became unreachable, or no longer has the required tools available.
    self:forceComplete()
end

function QueueDismantleDeferredAction:stop()
    self._isAddingActions = nil
    self._numAddedActions = nil
    ISBaseTimedAction.stop(self)
end

function QueueDismantleDeferredAction:perform()
    self._isAddingActions = nil
    self._numAddedActions = nil
    ISBaseTimedAction.perform(self)
end

function QueueDismantleDeferredAction:new(character, object)
    local o = ISBaseTimedAction.new(self, character)
    o.character = character
    o.object = object
    o.stopOnAim = false
    o.stopOnWalk = false
    o.stopOnRun = false
    o.maxTime = -1
    return o
end

local function isDismantleOptionData(data)
    return type(data) == "table"
        and data.object ~= nil
        and data.moveProps ~= nil
        and data.square ~= nil
end

local function findVanillaDisassembleMenu(context)
    if not context or not context.options then
        return nil, nil
    end

    local disassembleLabel = getText("ContextMenu_Disassemble")

    for _, rootOption in ipairs(context.options) do
        if rootOption
            and rootOption.name == disassembleLabel
            and rootOption.subOption ~= nil then

            local sourceSubMenu = context:getSubMenu(rootOption.subOption)
            if sourceSubMenu and sourceSubMenu.options then
                local sourceOptions = {}

                for _, sourceOption in ipairs(sourceSubMenu.options) do
                    if sourceOption and isDismantleOptionData(sourceOption.param1) then
                        table.insert(sourceOptions, sourceOption)
                    end
                end

                if #sourceOptions > 0 then
                    return rootOption, sourceOptions
                end
            end
        end
    end

    return nil, nil
end

local OPTION_FIELDS_TO_COPY = {
    "notAvailable",
    "isDisabled",
    "toolTip",
    "iconTexture",
    "itemForTexture",
    "checkMark",
    "color",
    "badColor",
    "goodColor",
    "onHighlight",
    "onHighlightParams",
}

local function copyVanillaOptionPresentation(sourceOption, targetOption)
    for _, fieldName in ipairs(OPTION_FIELDS_TO_COPY) do
        targetOption[fieldName] = sourceOption[fieldName]
    end
end

-- Rebuilds the target data when its turn arrives, then delegates the actual
-- work to ISDisassembleMenu.disassemble(). This keeps vanilla pathfinding,
-- tool equipping, light-bulb handling, skill checks, sounds, loot and MP logic.
function QueueDismantle.expandQueuedTarget(playerObj, object)
    if not playerObj or playerObj:isDead() or not object then
        return
    end

    local square = object:getSquare()
    if not square or not square:getObjects():contains(object) then
        return
    end

    local moveProps = ISMoveableSpriteProps.fromObject(object)
    if not moveProps then
        return
    end

    -- Match vanilla handling of partially destroyed multi-tile furniture.
    if moveProps.isMultiSprite and not moveProps:getSpriteGridInfo(square, true) then
        return
    end

    local resultScrap, chance, perkName = moveProps:canScrapObject(playerObj)
    if not resultScrap or not resultScrap.craftValid or not resultScrap.canScrap then
        return
    end

    local freshData = {
        object = object,
        moveProps = moveProps,
        square = square,
        chance = chance,
        perkName = perkName,
        resultScrap = resultScrap,
    }

    ISDisassembleMenu.disassemble(playerObj, freshData)
end

function QueueDismantle.queueTarget(playerObj, data)
    if not playerObj or playerObj:isDead() or not data or not data.object then
        return
    end

    ISTimedActionQueue.add(QueueDismantleDeferredAction:new(playerObj, data.object))
end

function QueueDismantle.onFillWorldObjectContextMenu(player, context, worldObjects, test)
    local playerObj = getSpecificPlayer(player)
    if not playerObj or playerObj:isDead() then
        return
    end

    -- Vanilla creates its Disassemble menu before this event fires. Reusing it
    -- avoids duplicating (and eventually drifting from) vanilla eligibility,
    -- labels, tooltips and object-highlight behavior.
    local vanillaRoot, vanillaOptions = findVanillaDisassembleMenu(context)
    if not vanillaRoot or not vanillaOptions then
        return
    end

    if test then
        return ISWorldObjectContextMenu.setTest()
    end

    local queueRoot = context:addOption(
        "Queued Dismantle",
        playerObj,
        nil
    )
    queueRoot.iconTexture = vanillaRoot.iconTexture

    local queueSubMenu = ISContextMenu:getNew(context)
    context:addSubMenu(queueRoot, queueSubMenu)

    -- Move "Queue dismantle" directly after the vanilla "Disassemble" option.
    local vanillaIndex = nil
    local queueIndex = nil

    for i, option in ipairs(context.options) do
        if option == vanillaRoot then
            vanillaIndex = i
        elseif option == queueRoot then
            queueIndex = i
        end
    end

    if vanillaIndex and queueIndex then
        table.remove(context.options, queueIndex)

        -- If Queue Dismantle was located before Disassemble,
        -- removing it shifts the vanilla index by one.
        if queueIndex < vanillaIndex then
            vanillaIndex = vanillaIndex - 1
        end

        table.insert(context.options, vanillaIndex + 1, queueRoot)
    end

    for _, sourceOption in ipairs(vanillaOptions) do
        local sourceData = sourceOption.param1
        local queuedData = { object = sourceData.object }

        local queueOption = queueSubMenu:addOption(
            sourceOption.name,
            playerObj,
            QueueDismantle.queueTarget,
            queuedData
        )

        copyVanillaOptionPresentation(sourceOption, queueOption)
    end
end

-- Avoid duplicate handlers during Lua hot reloads while remaining harmless on
-- normal game startup, where the file is loaded only once.
if QueueDismantle._registeredHandler and Events.OnFillWorldObjectContextMenu.Remove then
    pcall(function()
        Events.OnFillWorldObjectContextMenu.Remove(QueueDismantle._registeredHandler)
    end)
end

QueueDismantle._registeredHandler = QueueDismantle.onFillWorldObjectContextMenu
Events.OnFillWorldObjectContextMenu.Add(QueueDismantle._registeredHandler)
