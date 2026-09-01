require "ISUI/ISContextMenu"
require "ISUI/ISDisassembleMenu"
require "ISUI/ISWorldObjectContextMenu"
require "Moveables/ISMoveableSpriteProps"
require "Moveables/ISMoveablesAction"
require "TimedActions/ISQueueActionsAction"
require "TimedActions/ISTimedActionQueue"

QueueDismantle = QueueDismantle or {}


-- ============================================================================
-- Dedicated-MP end-window fix
--
-- On a dedicated server the authoritative scrap can remove the object on the
-- client a fraction before the local LuaTimedActionNew has finished. Vanilla
-- ISMoveablesAction:isValid() then calls stop(), and ISBaseTimedAction:stop()
-- resets the ENTIRE Lua queue.
--
-- We do NOT fake completion and do NOT call scrapObjectViaCursor(). We only
-- preserve QueueDismantle wrappers that vanilla would otherwise wipe, and
-- restore them after the invalid Java timed action has actually disappeared.
-- The exception is intentionally narrow: our own scrap action, missing object,
-- >= 95% job progress, with at least one of our wrappers waiting behind it.
-- ============================================================================
local END_WINDOW_TAG = "[QueueDismantle][END-WINDOW-FIX]"
local END_WINDOW_MIN_DELTA = 0.95
local END_WINDOW_MAX_WAIT_TICKS = 30
local pendingRestore = {}

local function getQueue(character)
    if not character then return nil end
    local ok, q = pcall(function()
        return ISTimedActionQueue.getTimedActionQueue(character)
    end)
    if ok then return q end
    return nil
end

local function isObjectMissingFromActionSquare(action)
    if not action or not action.square or not action.moveProps then return false end
    local object = action.moveProps.object
    if not object then return true end
    local objects = action.square:getObjects()
    return not objects or not objects:contains(object)
end

local function collectQueuedDismantleWrappers(q)
    local preserved = {}
    if not q or not q.queue then return preserved end
    for i = 2, #q.queue do
        local action = q.queue[i]
        if action and action._queueDismantleWrapper then
            preserved[#preserved + 1] = action
        end
    end
    return preserved
end

local function installEndWindowFix()
    if QueueDismantle._endWindowFixInstalled then return end
    QueueDismantle._endWindowFixInstalled = true

    local originalStop = ISMoveablesAction.stop

    ISMoveablesAction.stop = function(self, ...)
        local shouldPreserve = false
        local wrappers = nil
        local delta = -1

        if isClient()
            and self
            and self.mode == "scrap"
            and self._queueDismantleManaged
            and self.character
            and isObjectMissingFromActionSquare(self) then

            local q = getQueue(self.character)
            if q and q.current == self and q.queue and q.queue[1] == self then
                wrappers = collectQueuedDismantleWrappers(q)
                if #wrappers > 0 then
                    local okDelta, value = pcall(function() return self:getJobDelta() end)
                    if okDelta and type(value) == "number" then delta = value end
                    shouldPreserve = delta >= END_WINDOW_MIN_DELTA
                end
            end
        end

        if shouldPreserve then
            pendingRestore[self.character] = {
                actions = wrappers,
                ticks = 0,
            }
            print(END_WINDOW_TAG .. " preserve after authoritative disappearance"
                .. " delta=" .. tostring(delta)
                .. " wrappers=" .. tostring(#wrappers))
        end

        -- Keep vanilla semantics for the action that just became invalid. This
        -- cancels/resetQueue exactly as vanilla wants; we only saved OUR future
        -- wrappers beforehand.
        local result = originalStop(self, ...)

        return result
    end

    Events.OnTick.Add(function()
        for character, pending in pairs(pendingRestore) do
            pending.ticks = pending.ticks + 1

            if not character or character:isDead() then
                pendingRestore[character] = nil
            else
                local javaEmpty = false
                local okJava, value = pcall(function()
                    return character:getCharacterActions():isEmpty()
                end)
                if okJava then javaEmpty = value == true end

                if javaEmpty then
                    local q = getQueue(character)
                    -- resetQueue() should have left the Lua queue empty. If
                    -- something else has already started, respect it and abort.
                    if q and q.queue and #q.queue == 0 and q.current == nil then
                        local actions = pending.actions
                        pendingRestore[character] = nil
                        print(END_WINDOW_TAG .. " restore wrappers=" .. tostring(#actions)
                            .. " afterTicks=" .. tostring(pending.ticks))
                        for _, action in ipairs(actions) do
                            ISTimedActionQueue.add(action)
                        end
                    else
                        print(END_WINDOW_TAG .. " abort restore: Lua queue no longer empty")
                        pendingRestore[character] = nil
                    end
                elseif pending.ticks >= END_WINDOW_MAX_WAIT_TICKS then
                    print(END_WINDOW_TAG .. " abort restore: old Java action still present after "
                        .. tostring(pending.ticks) .. " ticks")
                    pendingRestore[character] = nil
                end
            end
        end
    end)

    print(END_WINDOW_TAG .. " installed minDelta=" .. tostring(END_WINDOW_MIN_DELTA))
end

installEndWindowFix()

local MOD_TAG = "[QueueDismantle]"

local function logError(message)
    print(MOD_TAG .. " " .. tostring(message))
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

    -- Remember which queue entries existed before vanilla expands the scrap.
    -- ISQueueActionsAction causes all child actions to be inserted immediately
    -- behind the wrapper, so we can mark only the ISMoveablesAction created by
    -- this queued target without changing vanilla constructors globally.
    local q = getQueue(playerObj)
    local before = {}
    if q and q.queue then
        for _, action in ipairs(q.queue) do before[action] = true end
    end

    ISDisassembleMenu.disassemble(playerObj, freshData)

    q = getQueue(playerObj)
    if q and q.queue then
        for _, action in ipairs(q.queue) do
            if action and not before[action] and action.Type == "ISMoveablesAction" and action.mode == "scrap" then
                action._queueDismantleManaged = true
            end
        end
    end
end

function QueueDismantle.queueTarget(playerObj, data)
    if not playerObj or playerObj:isDead() or not data or not data.object then
        return
    end

    local wrapper = ISQueueActionsAction:new(
        playerObj,
        QueueDismantle.expandQueuedTarget,
        data.object
    )
    wrapper._queueDismantleWrapper = true
    ISTimedActionQueue.add(wrapper)
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
