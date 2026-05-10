-- export_classic_with_meta.lua
-- Recursive Rojo export + correct init.meta.json handling.
--
-- Key behaviors:
--   • Script with ANY children → folder with init.<ext> file
--   • Script with non-script children → ignoreUnknownInstances: true in meta
--     so Rojo won't remove Frames / templates / etc. parented under the script
--   • Non-script containers (Folders, Models, etc.) → directory with
--     ignoreUnknownInstances: true
--   • Recursive traversal ensures parents are always processed before children

local remodel = require("./remodel")

-- ========= CONFIG =========
local PLACE_PATH = "./vfxeffects.rbxl"
local SRC_ROOT   = "src"

local SERVICE_NAMES = {
    "ReplicatedStorage",
    "ServerScriptService",
    "ServerStorage",
    "ReplicatedFirst",
    "StarterGui",
    "StarterPack",
    "StarterPlayer",
    "Workspace",
    "Lighting",
    "SoundService",
    "Chat",
    "TextChatService",
    "Players",
}

-- ========= UTIL =========
local function sanitize(name)
    local s = name:gsub("[/%\\:*?\"<>|]", "_")
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then s = "Unnamed" end
    return s
end

local function extFor(className)
    if className == "Script" then return "server.luau"
    elseif className == "LocalScript" then return "client.luau"
    else return "luau" end -- ModuleScript
end

local function isScript(className)
    return className == "Script" or className == "LocalScript" or className == "ModuleScript"
end

local function writeFile(path, contents)
    remodel.writeFile(path, contents or "")
end

local function fileExists(path)
    local ok = pcall(function() remodel.readFile(path) end)
    return ok
end

local function uniquePath(path)
    if not fileExists(path) then return path end
    local base, ext = path:match("^(.*)%.([%w%.]+)$")
    if not base then base, ext = path, "" end
    local n = 2
    while true do
        local try = ext ~= "" and (base .. "_" .. n .. "." .. ext) or (base .. "_" .. n)
        if not fileExists(try) then return try end
        n += 1
    end
end

-- ========= META JSON =========
-- init.meta.json never needs className for script folders because the
-- init.server.luau / init.client.luau / init.luau file already tells Rojo
-- what class the directory represents.
-- className IS needed for non-script, non-Folder instances (ScreenGui, Frame,
-- Part, Model, Tool, etc.) so Rojo creates the correct instance type instead
-- of defaulting to Folder.

local function buildMetaJson(ignoreUnknown, className)
    local fields = {}
    if className and className ~= "Folder" then
        table.insert(fields, '  "className": "' .. className .. '"')
    end
    if ignoreUnknown then
        table.insert(fields, '  "ignoreUnknownInstances": true')
    end
    if #fields == 0 then
        return '{\n}\n'
    end
    return '{\n' .. table.concat(fields, ',\n') .. '\n}\n'
end

local function writeMetaJson(dirPath, ignoreUnknown, className)
    local metaPath = dirPath .. "/init.meta.json"
    writeFile(metaPath, buildMetaJson(ignoreUnknown, className))
end

-- ========= HELPERS =========
local function hasChildren(inst)
    return #inst:GetChildren() > 0
end

local function hasNonScriptChildren(inst)
    for _, ch in ipairs(inst:GetChildren()) do
        if not isScript(ch.ClassName) then
            return true
        end
    end
    return false
end

local function hasScriptDescendants(inst)
    for _, ch in ipairs(inst:GetDescendants()) do
        if isScript(ch.ClassName) then
            return true
        end
    end
    return false
end

-- ========= RECURSIVE EXPORT =========
-- Walks the instance tree depth-first, parent before children, so every
-- directory and its init.meta.json are created before any child is written.

local function exportTree(inst, parentDir)
    local name = sanitize(inst.Name)
    local cls  = inst.ClassName

    if isScript(cls) then
        local src = inst.Source or "-- empty"
        local ext = extFor(cls)

        if hasChildren(inst) then
            -- Script has children → folder with init file
            local folder = parentDir .. "/" .. name
            remodel.createDirAll(folder)

            -- ignoreUnknownInstances keeps non-script children (Frames,
            -- templates, values, etc.) alive when Rojo syncs
            writeMetaJson(folder, hasNonScriptChildren(inst))

            -- The init file determines the script class for Rojo
            writeFile(folder .. "/init." .. ext, src)

            -- Recurse into children that are scripts or contain scripts
            for _, child in ipairs(inst:GetChildren()) do
                if isScript(child.ClassName) or hasScriptDescendants(child) then
                    exportTree(child, folder)
                end
            end
        else
            -- Leaf script → flat file
            local filePath = uniquePath(parentDir .. "/" .. name .. "." .. ext)
            writeFile(filePath, src)
        end
    else
        -- Non-script container (Folder, Model, Configuration, etc.)
        -- Only create a directory if it (or a descendant) contains scripts
        local folder = parentDir .. "/" .. name
        remodel.createDirAll(folder)
        writeMetaJson(folder, true, cls) -- className + ignore unknown for containers

        for _, child in ipairs(inst:GetChildren()) do
            if isScript(child.ClassName) or hasScriptDescendants(child) then
                exportTree(child, folder)
            end
        end
    end
end

-- ========= SERVICE EXPORT =========
local function exportService(service, basePath)
    remodel.createDirAll(basePath)
    writeMetaJson(basePath, true)

    for _, child in ipairs(service:GetChildren()) do
        if isScript(child.ClassName) or hasScriptDescendants(child) then
            exportTree(child, basePath)
        end
    end
end

local function exportStarterPlayer(sp, basePath)
    remodel.createDirAll(basePath)
    writeMetaJson(basePath, true)

    local sps = sp:FindFirstChild("StarterPlayerScripts")
    local scs = sp:FindFirstChild("StarterCharacterScripts")

    if sps then
        exportService(sps, basePath .. "/StarterPlayerScripts")
    end
    if scs then
        exportService(scs, basePath .. "/StarterCharacterScripts")
    end
end

-- ========= EXECUTE =========
print("[Remodel] Reading place: " .. PLACE_PATH)
local game = remodel.readPlaceFile(PLACE_PATH)

remodel.createDirAll(SRC_ROOT)
writeMetaJson(SRC_ROOT, true)

for _, svcName in ipairs(SERVICE_NAMES) do
    local service
    local ok = pcall(function() service = game:GetService(svcName) end)
    if not ok or service == nil then
        service = game:FindFirstChild(svcName)
    end

    if service then
        local base = SRC_ROOT .. "/" .. svcName

        if svcName == "StarterPlayer" then
            exportStarterPlayer(service, base)
        else
            exportService(service, base)
        end

        print(("[Remodel] Exported %-20s -> %s"):format(svcName, base))
    end
end

print("[Remodel] Export complete -> src/<Service>/...")
