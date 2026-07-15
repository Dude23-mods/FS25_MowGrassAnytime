MowGrassAnytime = {}

MowGrassAnytime.PREFIX = "[MowGrassAnytime]"
MowGrassAnytime.TARGET_FRUIT_NAMES = {"GRASS", "MEADOW"}
MowGrassAnytime.EFFECT_TYPES = {"MOWER", "CUTTER"}
MowGrassAnytime.MAX_DROP_BUFFER = 1000
MowGrassAnytime.YIELD_SCALE_BY_STATE_NAME = {
    GREENSMALL = 0.25,
    GREENMIDDLE = 0.50,
    HARVESTREADY = 1.00
}

function MowGrassAnytime:log(message, ...)
    local text = select("#", ...) > 0 and string.format(message, ...) or message

    if Logging ~= nil and Logging.info ~= nil then
        Logging.info("%s %s", self.PREFIX, text)
    else
        print(string.format("%s %s", self.PREFIX, text))
    end
end

function MowGrassAnytime:warning(message, ...)
    local text = select("#", ...) > 0 and string.format(message, ...) or message

    if Logging ~= nil and Logging.warning ~= nil then
        Logging.warning("%s %s", self.PREFIX, text)
    else
        print(string.format("%s WARNING: %s", self.PREFIX, text))
    end
end

function MowGrassAnytime:getFruitTypeByName(name)
    if g_fruitTypeManager == nil or type(g_fruitTypeManager.getFruitTypeByName) ~= "function" then
        return nil
    end

    return g_fruitTypeManager:getFruitTypeByName(name)
end

function MowGrassAnytime:getFruitTypeByIndex(index)
    if g_fruitTypeManager == nil or type(index) ~= "number" or type(g_fruitTypeManager.getFruitTypeByIndex) ~= "function" then
        return nil
    end

    return g_fruitTypeManager:getFruitTypeByIndex(index)
end

function MowGrassAnytime:getGrowthStateName(fruitType, state)
    if fruitType == nil or type(state) ~= "number" then
        return nil
    end

    if type(fruitType.getGrowthStateName) == "function" then
        local stateName = fruitType:getGrowthStateName(state)
        if stateName ~= nil then
            return stateName
        end
    end

    return fruitType.growthStateToName ~= nil and fruitType.growthStateToName[state] or nil
end

function MowGrassAnytime:getGrowthStateByName(fruitType, name)
    if fruitType == nil or type(name) ~= "string" then
        return nil
    end

    if type(fruitType.getGrowthStateByName) == "function" then
        local state = fruitType:getGrowthStateByName(name)
        if state ~= nil then
            return state
        end
    end

    return fruitType.nameToGrowthState ~= nil and fruitType.nameToGrowthState[string.upper(name)] or nil
end

function MowGrassAnytime:getYieldScale(fruitType, state)
    local stateName = self:getGrowthStateName(fruitType, state)
    if type(stateName) ~= "string" then
        return 1, tostring(state)
    end

    local upperName = string.upper(stateName)
    return self.YIELD_SCALE_BY_STATE_NAME[upperName] or 1, stateName
end

function MowGrassAnytime:getFirstVisibleGrowthState(fruitType, originalMinState)
    local greenSmallState = self:getGrowthStateByName(fruitType, "greenSmall")
    if type(greenSmallState) == "number" and greenSmallState < originalMinState then
        return greenSmallState
    end

    for state = 1, originalMinState - 1 do
        local stateName = self:getGrowthStateName(fruitType, state)
        local isGrowing = type(fruitType.getIsGrowing) ~= "function" or fruitType:getIsGrowing(state)
        local isCut = type(fruitType.getIsCut) == "function" and fruitType:getIsCut(state)
        local isWithered = type(fruitType.getIsWithered) == "function" and fruitType:getIsWithered(state)

        if isGrowing and not isCut and not isWithered and type(stateName) == "string" and string.upper(stateName) ~= "INVISIBLE" then
            return state
        end
    end

    return nil
end

function MowGrassAnytime:patchFruitType(fruitType)
    local originalMinState = fruitType.minHarvestingGrowthState
    local cutState = fruitType.cutState

    if type(originalMinState) ~= "number" or type(cutState) ~= "number" then
        self:warning("Fruit type '%s' has no usable harvesting range or cut state", tostring(fruitType.name))
        return nil
    end

    local firstVisibleState = self:getFirstVisibleGrowthState(fruitType, originalMinState)
    if firstVisibleState == nil or firstVisibleState >= originalMinState then
        self:warning("Fruit type '%s' has no detectable early visible growth state", tostring(fruitType.name))
        return nil
    end

    fruitType.yieldScales = fruitType.yieldScales or {}
    fruitType.harvestTransitions = fruitType.harvestTransitions or {}
    fruitType.harvestReadyTransitions = fruitType.harvestReadyTransitions or {}

    local patchedStates = {}
    local stateDescriptions = {}
    local maxHarvestingGrowthState = fruitType.maxHarvestingGrowthState or originalMinState

    for state = firstVisibleState, maxHarvestingGrowthState do
        local yieldScale, stateName = self:getYieldScale(fruitType, state)
        local upperName = type(stateName) == "string" and string.upper(stateName) or ""

        if self.YIELD_SCALE_BY_STATE_NAME[upperName] ~= nil then
            fruitType.yieldScales[state] = yieldScale
            table.insert(stateDescriptions, string.format("%s=%0.3f", tostring(stateName), yieldScale))

            if state < originalMinState then
                fruitType.harvestTransitions[state] = cutState
                fruitType.harvestReadyTransitions[state] = cutState
                table.insert(patchedStates, state)
            end
        end
    end

    if #patchedStates == 0 then
        self:warning("Fruit type '%s' had no eligible early growth states", tostring(fruitType.name))
        return nil
    end

    fruitType.minHarvestingGrowthState = firstVisibleState

    self:log("Patched '%s': minHarvestingGrowthState %d -> %d, cutState=%d, yield profile: %s", tostring(fruitType.name), originalMinState, firstVisibleState, cutState, table.concat(stateDescriptions, ", "))

    return {
        originalMinState = originalMinState,
        states = patchedStates
    }
end

function MowGrassAnytime:patchEffects(statesByOriginalState)
    if g_motionPathEffectManager == nil or type(g_motionPathEffectManager.effectsByType) ~= "table" then
        self:warning("Motion path effect manager is unavailable; gameplay patch remains active")
        return 0
    end

    local changedEntries = 0

    for _, effectTypeName in ipairs(self.EFFECT_TYPES) do
        local effectEntries = g_motionPathEffectManager.effectsByType[effectTypeName]
        if type(effectEntries) == "table" then
            for _, effectEntry in ipairs(effectEntries) do
                if type(effectEntry.growthStates) == "table" then
                    local existingStates = {}
                    for _, state in ipairs(effectEntry.growthStates) do
                        existingStates[state] = true
                    end

                    local entryChanged = false
                    for originalState, earlyStates in pairs(statesByOriginalState) do
                        if existingStates[originalState] then
                            for _, earlyState in ipairs(earlyStates) do
                                if not existingStates[earlyState] then
                                    table.insert(effectEntry.growthStates, earlyState)
                                    existingStates[earlyState] = true
                                    entryChanged = true
                                end
                            end
                        end
                    end

                    if entryChanged then
                        table.sort(effectEntry.growthStates)
                        changedEntries = changedEntries + 1
                    end
                end
            end
        end
    end

    self:log("Extended mower/cutter effects in %d entries", changedEntries)
    return changedEntries
end

function MowGrassAnytime:captureMowerOutputState(vehicle, workArea)
    local spec = vehicle ~= nil and vehicle.spec_mower or nil
    if spec == nil then
        return nil
    end

    local state = {}

    if type(vehicle.getDropArea) == "function" then
        state.dropArea = vehicle:getDropArea(workArea)
        if state.dropArea ~= nil and type(state.dropArea.litersToDrop) == "number" then
            state.dropLitersBefore = state.dropArea.litersToDrop
        end
    end

    if state.dropArea == nil and spec.fillUnitIndex ~= nil and type(vehicle.getFillUnitFillLevel) == "function" then
        state.fillUnitIndex = spec.fillUnitIndex
        state.fillLevelBefore = vehicle:getFillUnitFillLevel(spec.fillUnitIndex)
    end

    return state
end

function MowGrassAnytime:scaleMowerOutput(vehicle, workArea, changedArea, outputState)
    if vehicle == nil or workArea == nil or type(changedArea) ~= "number" or changedArea <= 0 then
        return nil
    end

    local spec = vehicle.spec_mower
    if spec == nil or spec.workAreaParameters == nil then
        return nil
    end

    local inputFruitType = spec.workAreaParameters.lastInputFruitType
    local growthState = spec.workAreaParameters.lastInputGrowthState
    local fruitType = self:getFruitTypeByIndex(inputFruitType)

    if fruitType == nil or type(growthState) ~= "number" then
        return nil
    end

    local fruitName = tostring(fruitType.name or inputFruitType)
    if fruitName ~= "GRASS" and fruitName ~= "MEADOW" then
        return nil
    end

    local yieldScale = self:getYieldScale(fruitType, growthState)
    local originalLiters = type(workArea.lastPickupLiters) == "number" and workArea.lastPickupLiters or 0
    local scaledLiters = originalLiters * yieldScale

    workArea.lastPickupLiters = scaledLiters
    workArea.pickedUpLiters = scaledLiters

    if outputState ~= nil and outputState.dropArea ~= nil and type(outputState.dropLitersBefore) == "number" and type(outputState.dropArea.litersToDrop) == "number" then
        local dropLitersAfter = outputState.dropArea.litersToDrop
        local correction = originalLiters - scaledLiters
        local correctedAfter = dropLitersAfter - correction
        local minimumExpectedAfter = outputState.dropLitersBefore + scaledLiters
        outputState.dropArea.litersToDrop = math.max(0, math.min(self.MAX_DROP_BUFFER, math.max(correctedAfter, minimumExpectedAfter)))
    elseif outputState ~= nil and outputState.fillUnitIndex ~= nil and type(outputState.fillLevelBefore) == "number" and vehicle.isServer == true and type(vehicle.getFillUnitFillLevel) == "function" and type(vehicle.addFillUnitFillLevel) == "function" then
        local fillLevelAfter = vehicle:getFillUnitFillLevel(outputState.fillUnitIndex)
        if type(fillLevelAfter) ~= "number" then
            return
        end

        local desiredFillLevel = outputState.fillLevelBefore + scaledLiters

        if type(vehicle.getFillUnitCapacity) == "function" then
            local capacity = vehicle:getFillUnitCapacity(outputState.fillUnitIndex)
            if type(capacity) == "number" then
                desiredFillLevel = math.min(desiredFillLevel, capacity)
            end
        end

        local converterData = type(spec.fruitTypeConverters) == "table" and spec.fruitTypeConverters[inputFruitType] or nil
        local fillTypeIndex = converterData ~= nil and converterData.fillTypeIndex or nil
        local fillLevelCorrection = desiredFillLevel - fillLevelAfter

        if fillTypeIndex ~= nil and math.abs(fillLevelCorrection) > 0.0001 then
            vehicle:addFillUnitFillLevel(vehicle:getOwnerFarmId(), outputState.fillUnitIndex, fillLevelCorrection, fillTypeIndex, ToolType.UNDEFINED)
        end
    end

end

function MowGrassAnytime.processMowerArea(vehicle, superFunc, workArea, dt)
    local outputState = MowGrassAnytime:captureMowerOutputState(vehicle, workArea)
    local changedArea, totalArea = superFunc(vehicle, workArea, dt)

    if MowGrassAnytime.hasRun and type(changedArea) == "number" and changedArea > 0 then
        MowGrassAnytime:scaleMowerOutput(vehicle, workArea, changedArea, outputState)
    end

    return changedArea, totalArea
end

function MowGrassAnytime:installMowerYieldScaling()
    if self.mowerYieldScalingInstalled then
        return true
    end

    if Mower == nil or type(Mower.processMowerArea) ~= "function" or Utils == nil or type(Utils.overwrittenFunction) ~= "function" then
        self:warning("Mower yield scaling could not be installed because the mower function is unavailable")
        return false
    end

    Mower.processMowerArea = Utils.overwrittenFunction(Mower.processMowerArea, MowGrassAnytime.processMowerArea)
    self.mowerYieldScalingInstalled = true
    self:log("Mower yield scaling installed")
    return true
end

function MowGrassAnytime:applyPatches()
    local patchedFruitCount = 0
    local statesByOriginalState = {}

    for _, fruitName in ipairs(self.TARGET_FRUIT_NAMES) do
        local fruitType = self:getFruitTypeByName(fruitName)
        if fruitType == nil then
            self:warning("Fruit type '%s' was not found", fruitName)
        else
            local result = self:patchFruitType(fruitType)
            if result ~= nil then
                patchedFruitCount = patchedFruitCount + 1
                statesByOriginalState[result.originalMinState] = statesByOriginalState[result.originalMinState] or {}

                local knownStates = {}
                for _, state in ipairs(statesByOriginalState[result.originalMinState]) do
                    knownStates[state] = true
                end

                for _, state in ipairs(result.states) do
                    if not knownStates[state] then
                        table.insert(statesByOriginalState[result.originalMinState], state)
                        knownStates[state] = true
                    end
                end
            end
        end
    end

    if patchedFruitCount > 0 then
        self:patchEffects(statesByOriginalState)
        self:log("Initialization finished; patched fruit types=%d", patchedFruitCount)
    else
        self:warning("Initialization finished without patching a fruit type")
    end
end

function MowGrassAnytime:loadMap()
    self.hasRun = false
    self.waitFrames = 0
end

function MowGrassAnytime:update()
    if self.hasRun or g_currentMission == nil or g_fruitTypeManager == nil then
        return
    end

    self.waitFrames = self.waitFrames + 1
    if self.waitFrames < 3 then
        return
    end

    self.hasRun = true
    local success, errorMessage = pcall(self.applyPatches, self)
    if not success then
        self:warning("Initialization failed: %s", tostring(errorMessage))
    end
end

function MowGrassAnytime:deleteMap()
    self.hasRun = false
    self.waitFrames = 0
end

MowGrassAnytime:installMowerYieldScaling()
addModEventListener(MowGrassAnytime)
