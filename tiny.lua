--[[
Copyright (c) 2015 Calvin Rose

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
]]

--- @module tiny-ecs
-- @author Calvin Rose
-- @license MIT
-- @copyright 2015
local tiny = { _VERSION = "scm" }

-- Local versions of standard lua functions
local tinsert = table.insert
local tremove = table.remove
local tsort = table.sort
local pairs = pairs
local ipairs = ipairs
local setmetatable = setmetatable
local type = type
local select = select

-- Local versions of the library functions
local tiny_manageEntities
local tiny_manageSystems
local tiny_addEntity
local tiny_addSystem
local tiny_add
local tiny_removeEntity
local tiny_removeSystem
local tiny_remove

--- Filter functions.
-- A Filter is a function that selects which Entities apply to a System.
-- Filters take two parameters, the System and the Entity, and return a boolean
-- value indicating if the Entity should be processed by the System.
--
-- Filters must be added to Systems by setting the `filter` field of the System.
-- Filter's returned by `tiny.requireAll` and `tiny.requireAny` are immutable
-- and can be used by multiple Systems.
--
--    local f1 = tiny.requireAll("position", "velocity", "size")
--    local f2 = tiny.requireAny("position", "velocity", "size")
--
--    local e1 = {
--        position = {2, 3},
--        velocity = {3, 3},
--        size = {4, 4}
--    }
--
--    local entity2 = {
--        position = {4, 5},
--        size = {4, 4}
--    }
--
--    local e3 = {
--        position = {2, 3},
--        velocity = {3, 3}
--    }
--
--    print(f1(nil, e1), f1(nil, e2), f1(nil, e3)) -- prints true, false, false
--    print(f2(nil, e1), f2(nil, e2), f2(nil, e3)) -- prints true, true, true
--
-- Filters can also be passed as arguments to other Filter constructors. This is
-- a powerful way to create complex, custom Filters that select a very specific
-- set of Entities.
--
--    -- Selects Entities with an "image" Component, but not Entities with a
--    -- "Player" or "Enemy" Component.
--    filter = tiny.requireAll("image", tiny.rejectAny("Player", "Enemy"))
--
-- @section Filter

--- Makes a Filter that selects Entities with all specified Components and
-- Filters.
-- @param ... List of required Components and other Filters.
function tiny.requireAll(...)
    local components = {...}
    local len = #components
    return function(system, e)
        local c
        for i = 1, len do
            c = components[i]
            if type(c) == 'function' then
                if not c(system, e) then
                    return false
                end
            elseif e[c] == nil then
                return false
            end
        end
        return true
    end
end

--- Makes a Filter that selects Entities with at least one of the specified
-- Components and Filters.
-- @param ... List of required Components and other Filters.
function tiny.requireAny(...)
    local components = {...}
    local len = #components
    return function(system, e)
        local c
        for i = 1, len do
            c = components[i]
            if type(c) == 'function' then
                if c(system, e) then
                    return true
                end
            elseif e[c] ~= nil then
                return true
            end
        end
        return false
    end
end

--- Makes a Filter that rejects Entities with all specified Components and
-- Filters, and selects all other Entities.
-- @param ... List of required Components and other Filters.
function tiny.rejectAll(...)
    local components = {...}
    local len = #components
    return function(system, e)
        local c
        for i = 1, len do
            c = components[i]
            if type(c) == 'function' then
                if not c(system, e) then
                    return true
                end
            elseif e[c] == nil then
                return true
            end
        end
        return false
    end
end

--- Makes a Filter that rejects Entities with at least one of the specified
-- Components and Filters, and selects all other Entities.
-- @param ... List of required Components and other Filters.
function tiny.rejectAny(...)
    local components = {...}
    local len = #components
    return function(system, e)
        local c
        for i = 1, len do
            c = components[i]
            if type(c) == 'function' then
                if c(system, e) then
                    return false
                end
            elseif e[c] ~= nil then
                return false
            end
        end
        return true
    end
end

--- System functions.
-- A System is a wrapper around function callbacks for manipulating Entities.
-- Systems are implemented as tables that contain at least one method;
-- an update function that takes parameters like so:
--
--   * `function system:update(dt)`.
--
-- There are also a few other optional callbacks:
--
--   * `function system:filter(entity)`
--   * `function system:onAdd(entity)`
--   * `function system:onRemove(entity)`
--   * `function system:onModify(dt)`
--
-- For Filters, it is convenient to use `tiny.requireAll` or `tiny.requireAny`,
-- but one can write their own filters as well. Set the Filter of a System like
-- so:
--    system.filter = tiny.requireAll("a", "b", "c")
-- or
--    function system:filter(entity)
--        return entity.myRequiredComponentName ~= nil
--    end
--
-- All Systems also have a few important fields that are initialized when the
-- system is added to the World. A few are important, and few should be less
-- commonly used.
--
--   * The `active` flag is whether or not the System is updated automatically.
-- Inactive Systems should be updated manually or not at all via
-- `system:update(dt)`. Defaults to true.
--   * The 'entities' field is an ordered list of Entities in the System. This
-- list can be used to quickly iterate through all Entities in a System.
--   * The `indices` field is a table of Entity keys to their indices in the
-- `entities` list. Most Systems can ignore this.
--   * The `modified` flag is an indicator if the System has been modified in
-- the last update. If so, the `onModify` callback will be called on the System
-- in the next update, if it has one. This is usually managed by tiny-ecs, so
-- users should mostly ignore this, too.
--
-- @section System

-- Use an empty table as a key for identifying Systems. Any table that contains
-- this key is considered a System rather than an Entity.
local systemTableKey = { "SYSTEM_TABLE_KEY" }

-- Check if tables are systems.
local function isSystem(table)
    return table[systemTableKey]
end

--- Creates a default System.
-- @param table A table to be used as a System, or `nil` to create a new System.
-- @return A new System or System class
function tiny.system(table)
    table = table or {}
    table[systemTableKey] = true
    return table
end

-- Update function for all Processing Systems.
local function processingSystemUpdate(system, dt)
    local entities = system.entities
    local preProcess = system.preProcess
    local process = system.process
    local postProcess = system.postProcess
    local entity

    if preProcess then
        preProcess(system, dt)
    end

    if process then
        local len = #entities
        for i = 1, len do
            entity = entities[i]
            process(system, entity, dt)
        end
    end

    if postProcess then
        postProcess(system, dt)
    end
end

--- Creates a Processing System.
--
-- A Processing System iterates through its Entities in no particluar order, and
-- updates them individually. It has two important fields:
--
--   * `function system:process(entity, dt)`
--   * `function system:filter(entity)`
--
-- There are also a few other optional callbacks, including the optional
-- callbacks in `tiny.system`:
--
--   * `function system:preProcess(entities, dt)`
--   * `function system:postProcess(entities, dt)`
--
-- @param table A table to be used as a System, or `nil` to create a new
-- Processing System.
-- @see system
-- @return A new Processing System or Processing System class
function tiny.processingSystem(table)
    table = table or {}
    table[systemTableKey] = true
    table.update = processingSystemUpdate
    return table
end

-- Sorts Systems by a function system.sort(entity1, entity2) on modify.
local function sortedSystemOnModify(system, dt)
    local entities = system.entities
    local entityIndices = system.entityIndices
    local sortDelegate = system.sortDelegate
    if not sortDelegate then
        local compare = system.compare
        sortDelegate = function(e1, e2)
            compare(system, e1, e2)
        end
        system.sortDelegate = sortDelegate
    end
    tsort(entities, sortDelegate)
    for i = 1, #entities do
        local entity = entities[i]
        entityIndices[entity] = i
    end
end

--- Creates a Sorted Processing System. A Sorted System iterates through its
-- Entities in a specific order, and updates them individually. It has three
-- important methods:
--
--   * `function system:process(entity, dt)`
--   * `function system:compare(entity1, entity2)`
--   * `function system:filter(entity)`
--
-- Sorted Systems have the same optitonal callbacks as ProcessingSystems.
-- @param table A table to be used as a System, or `nil` to create a new
-- Sorted System.
-- @see system
-- @see processingSystem
-- @return A new Sorted System or Sorted System class
function tiny.sortedSystem(table)
    table = table or {}
    table[systemTableKey] = true
    table.update = processingSystemUpdate
    table.onModify = sortedSystemOnModify
    table.sort = sortedSystemOnModify
    return table
end

--- World functions.
-- A World is a container that manages Entities and Systems. Typically, a
-- program uses one World at a time.
--
-- For all World functions except `tiny.world(...)`, object-oriented syntax can
-- be used instead of the documented syntax. For example,
-- `tiny.add(world, e1, e2, e3)` is the same as `world:add(e1, e2, e3)`.
-- @section World

-- Forward declaration
local worldMetaTable

--- Creates a new World.
-- Can optionally add default Systems and Entities.
-- @param ... Systems and Entities to add to the World
-- @return A new World
function tiny.world(...)

    local ret = {

        -- List of Entities to add
        entitiesToAdd = {},

        -- List of Entities to remove
        entitiesToRemove = {},

        -- List of Entities to add
        systemsToAdd = {},

        -- List of Entities to remove
        systemsToRemove = {},

        -- Set of Entities
        entities = {},

        -- Number of Entities in World.
        entityCount = 0,

        -- List of System Data. A data element is a table with 4
        -- keys: system, indices, entities, and active.
        systems = {},

        -- Table of Systems to System Indices
        systemIndices = {}
    }

    tiny_add(ret, ...)
    tiny_manageSystems(ret)
    tiny_manageEntities(ret)

    return setmetatable(ret, worldMetaTable)

end

--- Adds an Entity to the world.
-- Also call this on Entities that have changed Components such that they
-- match different Filters.
-- @param world
-- @param entity
function tiny.addEntity(world, entity)
    local e2a = world.entitiesToAdd
    e2a[#e2a + 1] = entity
    if world.entities[entity] then
        tiny_removeEntity(world, entity)
    end
end
tiny_addEntity = tiny.addEntity

--- Adds a System to the world.
-- @param world
-- @param system
function tiny.addSystem(world, system)
    local s2a = world.systemsToAdd
    s2a[#s2a + 1] = system
end
tiny_addSystem = tiny.addSystem

--- Shortcut for adding multiple Entities and Systems to the World.
-- @param world
-- @param ... Systems and Entities
-- @see addEntity
-- @see addSystem
function tiny.add(world, ...)
    local obj
    for i = 1, select("#", ...) do
        obj = select(i, ...)
        if obj then
            if isSystem(obj) then
                tiny_addSystem(world, obj)
            else -- Assume obj is an Entity
                tiny_addEntity(world, obj)
            end
        end
    end
end
tiny_add = tiny.add

--- Removes an Entity to the World.
-- @param world
-- @param entity
function tiny.removeEntity(world, entity)
    local e2r = world.entitiesToRemove
    e2r[#e2r + 1] = entity
end
tiny_removeEntity = tiny.removeEntity

--- Removes a System from the world.
-- @param world
-- @param system
function tiny.removeSystem(world, system)
    local s2r = world.systemsToRemove
    s2r[#s2r + 1] = system
end
tiny_removeSystem = tiny.removeSystem

--- Shortcut for removing multiple Entities and Systems from the World.
-- @param world
-- @param ... Systems and Entities
-- @see removeEntity
-- @see removeSystem
function tiny.remove(world, ...)
    local obj
    for i = 1, select("#", ...) do
        obj = select(i, ...)
        if obj then
            if isSystem(obj) then
                tiny_removeSystem(world, obj)
            else -- Assume obj is an Entity
               tiny_removeEntity(world, obj)
            end
        end
    end
end
tiny_remove = tiny.remove

-- Adds and removes Systems that have been marked from the World.
function tiny_manageSystems(world)

        local s2a, s2r = world.systemsToAdd, world.systemsToRemove

        -- Early exit
        if #s2a == 0 and #s2r == 0 then
            return
        end

        local systemIndices = world.systemIndices
        local entities = world.entities
        local systems = world.systems
        local system, index, filter
        local entityList, entityIndices, entityIndex, onRemove, onAdd

        -- Remove Systems
        for i = 1, #s2r do
            system = s2r[i]
            index = systemIndices[system]
            if index then
                onRemove = system.onRemove
                if onRemove then
                    entityList = system.entities
                    for j = 1, #entityList do
                        onRemove(system, entityList[j])
                    end
                end
                systemIndices[system] = nil
                tremove(systems, index)
                for j = index, #systems do
                    systemIndices[systems[j]] = j
                end
            end
            s2r[i] = nil
        end

        -- Add Systems
        for i = 1, #s2a do
            system = s2a[i]
            if not systemIndices[system] then
                entityList = {}
                entityIndices = {}
                system.entities = entityList
                system.indices = entityIndices
                system.active = true
                system.modified = true
                index = #systems + 1
                systemIndices[system] = index
                systems[index] = system

                -- Try to add Entities
                onAdd = system.onAdd
                filter = system.filter
                if filter then
                    for entity in pairs(entities) do
                        if filter(system, entity) then
                            entityIndex = #entityList + 1
                            entityList[entityIndex] = entity
                            entityIndices[entity] = entityIndex
                            if onAdd then
                                onAdd(system, entity)
                            end
                        end
                    end
                end
            end
            s2a[i] = nil
        end

end

-- Adds and removes Entities that have been marked.
function tiny_manageEntities(world)

    local e2a, e2r = world.entitiesToAdd, world.entitiesToRemove

    -- Early exit
    if #e2a == 0 and #e2r == 0 then
        return
    end

    local entities = world.entities
    local systems = world.systems
    local entityCount = world.entityCount
    local entity, system, index
    local onRemove, onAdd, ses, seis, filter, tmpEntity

    -- Remove Entities
    for i = 1, #e2r do
        entity = e2r[i]
        if entities[entity] then
            entities[entity] = nil

            for j = 1, #systems do
                system = systems[j]
                ses = system.entities
                seis = system.indices
                index = seis[entity]

                if index then
                    system.modified = true
                    tmpEntity = ses[#ses]
                    ses[index] = tmpEntity
                    seis[tmpEntity] = index
                    seis[entity] = nil
                    ses[#ses] = nil
                    entityCount = entityCount - 1
                    onRemove = system.onRemove
                    if onRemove then
                        onRemove(system, entity)
                    end
                end

            end

        end
        e2r[i] = nil
    end


    -- Add Entities
    for i = 1, #e2a do
        entity = e2a[i]
        if not entities[entity] then
            entities[entity] = true

            for j = 1, #systems do
                system = systems[j]
                ses = system.entities
                seis = system.indices
                filter = system.filter
                if filter and filter(system, entity) then
                    system.modified = true
                    index = #ses + 1
                    ses[index] = entity
                    seis[entity] = index
                    entityCount = entityCount + 1
                    onAdd = system.onAdd
                    if onAdd then
                        onAdd(system, entity)
                    end
                end

            end

        end
        e2a[i] = nil
    end

    -- Update Entity count
    world.entityCount = entityCount

end

--- Updates the World.
-- Put this in your main loop.
-- @param world
-- @param dt Delta time
function tiny.update(world, dt)

    tiny_manageSystems(world)
    tiny_manageEntities(world)

    local systems = world.systems
    local system, update, onModify, entities

    --  Iterate through Systems IN ORDER
    for i = 1, #systems do
        system = systems[i]
        if system.active then

            -- Call the modify callback on Systems that have been modified.
            onModify = system.onModify
            if onModify and system.modified then
                onModify(system, dt)
            end

            --Update Systems that have an update method (most Systems)
            update = system.update
            if update then
                update(system, dt)
            end

            system.modified = false
        end
    end
end

--- Removes all Entities from the World.
-- @param world
function tiny.clearEntities(world)
    for e in pairs(world.entities) do
        tiny_removeEntity(world, e)
    end
end

--- Removes all Systems from the World.
-- @param world
function tiny.clearSystems(world)
    local systems = world.systems
    for i = #systems, 1, -1 do
        tiny_removeSystem(world, systems[i])
    end
end

--- Gets number of Entities in the World.
-- @param world
-- @return An integer
function tiny.getEntityCount(world)
    return world.entityCount
end

--- Gets number of Systems in World.
-- @param world
-- @return An integer
function tiny.getSystemCount(world)
    return #(world.systems)
end

--- Gets the index of a System in the World. Lower indexed Systems are processed
-- before higher indexed systems.
-- @param world
-- @param system
-- @return An integer between 1 and world:getSystemCount() inclusive
function tiny.getSystemIndex(world, system)
    return world.systemIndices[system]
end

--- Sets the index of a System in the World. Changes the order in
-- which they Systems processed, because lower indexed Systems are processed
-- first.
-- @param world
-- @param system
-- @param index
-- @return Old index
function tiny.setSystemIndex(world, system, index)
    local systemIndices = world.systemIndices
    local oldIndex = systemIndices[system]
    local systems = world.systems
    local system = systems[oldIndex]

    tremove(systems, oldIndex)
    tinsert(systems, index, system)

    for i = oldIndex, index, index >= oldIndex and 1 or -1 do
        systemIndices[systems[i]] = i
    end

    return oldIndex
end

-- Construct world metatable.
worldMetaTable = {
    __index = {
        add = tiny.add,
        addEntity = tiny.addEntity,
        addSystem = tiny.addSystem,
        remove = tiny.remove,
        removeEntity = tiny.removeEntity,
        update = tiny.update,
        clearEntities = tiny.clearEntities,
        clearSystems = tiny.clearSystems,
        getEntityCount = tiny.getEntityCount,
        getSystemCount = tiny.getSystemCount,
        getSystemIndex = tiny.getSystemIndex,
        setSystemIndex = tiny.setSystemIndex
    }
}

return tiny
