local fs = require("@lune/fs")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")

local name = "EggShop"

local INPUT_FILE = name .. ".rbxm"
local OUTPUT_DIR = "Disassembly"
local OUTPUT_FILE = OUTPUT_DIR .. "/" .. name .. ".json"

-- Ensure output directory exists
if not fs.isDir(OUTPUT_DIR) then
	fs.writeDir(OUTPUT_DIR)
end

-- Load reflection database for property enumeration
local db = roblox.getReflectionDatabase()

-- Collect all property names for a class (including inherited ones)
local classPropsCache = {}
local function getClassProperties(className: string): { string }
	if classPropsCache[className] then
		return classPropsCache[className]
	end

	local props = {}
	local visited = {}
	local current = className

	while current do
		local classInfo = db:GetClass(current)
		if not classInfo then break end

		for propName, _ in classInfo.Properties do
			if not visited[propName] then
				visited[propName] = true
				table.insert(props, propName)
			end
		end

		current = classInfo.Superclass
	end

	table.sort(props)
	classPropsCache[className] = props
	return props
end

-- Convert a Roblox value to a JSON-friendly representation
local function serializeValue(value: any): any
	if value == nil then
		return nil
	end

	local t = typeof(value)

	if t == "string" or t == "boolean" or t == "number" then
		return value
	elseif t == "EnumItem" then
		return {
			Type = "EnumItem",
			Enum = tostring(value.EnumType),
			Name = value.Name,
			Value = value.Value,
		}
	elseif t == "UDim" then
		return { Type = "UDim", Scale = value.Scale, Offset = value.Offset }
	elseif t == "UDim2" then
		return {
			Type = "UDim2",
			X = { Scale = value.X.Scale, Offset = value.X.Offset },
			Y = { Scale = value.Y.Scale, Offset = value.Y.Offset },
		}
	elseif t == "Vector2" then
		return { Type = "Vector2", X = value.X, Y = value.Y }
	elseif t == "Vector3" then
		return { Type = "Vector3", X = value.X, Y = value.Y, Z = value.Z }
	elseif t == "Color3" then
		return {
			Type = "Color3",
			R = math.round(value.R * 255),
			G = math.round(value.G * 255),
			B = math.round(value.B * 255),
		}
	elseif t == "BrickColor" then
		return { Type = "BrickColor", Name = value.Name, Number = value.Number }
	elseif t == "CFrame" then
		local components = { value:GetComponents() }
		return { Type = "CFrame", Components = components }
	elseif t == "Rect" then
		return {
			Type = "Rect",
			Min = { X = value.Min.X, Y = value.Min.Y },
			Max = { X = value.Max.X, Y = value.Max.Y },
		}
	elseif t == "NumberRange" then
		return { Type = "NumberRange", Min = value.Min, Max = value.Max }
	elseif t == "NumberSequence" then
		local keypoints = {}
		for _, kp in value.Keypoints do
			table.insert(keypoints, { Time = kp.Time, Value = kp.Value, Envelope = kp.Envelope })
		end
		return { Type = "NumberSequence", Keypoints = keypoints }
	elseif t == "ColorSequence" then
		local keypoints = {}
		for _, kp in value.Keypoints do
			table.insert(keypoints, {
				Time = kp.Time,
				Color = {
					R = math.round(kp.Value.R * 255),
					G = math.round(kp.Value.G * 255),
					B = math.round(kp.Value.B * 255),
				},
			})
		end
		return { Type = "ColorSequence", Keypoints = keypoints }
	elseif t == "Font" then
		return {
			Type = "Font",
			Family = value.Family,
			Weight = tostring(value.Weight),
			Style = tostring(value.Style),
		}
	elseif t == "Faces" then
		return {
			Type = "Faces",
			Top = value.Top,
			Bottom = value.Bottom,
			Left = value.Left,
			Right = value.Right,
			Front = value.Front,
			Back = value.Back,
		}
	elseif t == "Axes" then
		return {
			Type = "Axes",
			X = value.X,
			Y = value.Y,
			Z = value.Z,
		}
	elseif t == "PhysicalProperties" then
		return {
			Type = "PhysicalProperties",
			Density = value.Density,
			Friction = value.Friction,
			Elasticity = value.Elasticity,
			FrictionWeight = value.FrictionWeight,
			ElasticityWeight = value.ElasticityWeight,
		}
	elseif t == "Ray" then
		return {
			Type = "Ray",
			Origin = { X = value.Origin.X, Y = value.Origin.Y, Z = value.Origin.Z },
			Direction = { X = value.Direction.X, Y = value.Direction.Y, Z = value.Direction.Z },
		}
	elseif t == "Region3" then
		return { Type = "Region3", Value = tostring(value) }
	elseif t == "Vector2int16" then
		return { Type = "Vector2int16", X = value.X, Y = value.Y }
	elseif t == "Vector3int16" then
		return { Type = "Vector3int16", X = value.X, Y = value.Y, Z = value.Z }
	elseif t == "Instance" then
		return { Type = "Instance", ClassName = value.ClassName, Name = value.Name }
	else
		return { Type = t, Value = tostring(value) }
	end
end

-- Properties to always skip (not serializable or cause errors)
local SKIP_PROPS = {
	Parent = true,
	DataCost = true,
	RobloxLocked = true,
	Selection = true,
}

-- Recursively decompose an instance tree
local function decomposeInstance(instance: roblox.Instance): { [string]: any }
	local node: { [string]: any } = {}
	node.ClassName = instance.ClassName
	node.Name = instance.Name

	-- Read properties from reflection database
	local propNames = getClassProperties(instance.ClassName)
	local properties: { [string]: any } = {}

	for _, propName in propNames do
		if SKIP_PROPS[propName] then continue end
		if propName == "Name" or propName == "ClassName" then continue end

		local ok, value = pcall(function()
			return (instance :: any)[propName]
		end)

		if ok and value ~= nil then
			local serialized = serializeValue(value)
			if serialized ~= nil then
				properties[propName] = serialized
			end
		end
	end

	node.Properties = properties

	-- Attributes
	local attributes = instance:GetAttributes()
	if next(attributes) then
		local serializedAttrs = {}
		for attrName, attrValue in attributes do
			serializedAttrs[attrName] = serializeValue(attrValue)
		end
		node.Attributes = serializedAttrs
	end

	-- Tags
	local tags = instance:GetTags()
	if #tags > 0 then
		node.Tags = tags
	end

	-- Children
	local children = instance:GetChildren()
	if #children > 0 then
		local childNodes = {}
		for _, child in children do
			table.insert(childNodes, decomposeInstance(child))
		end
		node.Children = childNodes
	end

	return node
end

-- Custom JSON encoder with controlled key ordering
local function encodeJson(value: any, indent: number?): string
	local level = indent or 0
	local tab = string.rep("  ", level)
	local tabInner = string.rep("  ", level + 1)

	if value == nil then
		return "null"
	end

	local t = type(value)

	if t == "string" then
		-- Escape special characters
		local escaped = value:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t')
		return '"' .. escaped .. '"'
	elseif t == "number" then
		if value ~= value then return "null" end -- NaN
		if value == math.huge then return "1e309" end
		if value == -math.huge then return "-1e309" end
		return tostring(value)
	elseif t == "boolean" then
		return tostring(value)
	elseif t == "table" then
		-- Check if it's an array (sequential integer keys starting at 1)
		local isArray = #value > 0
		if isArray then
			-- Verify it's a proper array
			for k in pairs(value) do
				if type(k) ~= "number" then
					isArray = false
					break
				end
			end
		end

		if isArray then
			local parts = {}
			for _, v in ipairs(value) do
				table.insert(parts, tabInner .. encodeJson(v, level + 1))
			end
			if #parts == 0 then return "[]" end
			return "[\n" .. table.concat(parts, ",\n") .. "\n" .. tab .. "]"
		else
			-- Object: order keys so ClassName, Name, Properties, Attributes, Tags come before Children
			local priorityKeys = { "ClassName", "Name", "Properties", "Attributes", "Tags" }
			local orderedKeys = {}
			local seen = {}

			-- Add priority keys first (if they exist)
			for _, key in ipairs(priorityKeys) do
				if value[key] ~= nil then
					table.insert(orderedKeys, key)
					seen[key] = true
				end
			end

			-- Add remaining keys sorted alphabetically
			local remainingKeys = {}
			for key in pairs(value) do
				if not seen[key] then
					table.insert(remainingKeys, key)
				end
			end
			table.sort(remainingKeys)
			for _, key in ipairs(remainingKeys) do
				table.insert(orderedKeys, key)
			end

			local parts = {}
			for _, key in ipairs(orderedKeys) do
				table.insert(parts, tabInner .. '"' .. key .. '": ' .. encodeJson(value[key], level + 1))
			end
			if #parts == 0 then return "{}" end
			return "{\n" .. table.concat(parts, ",\n") .. "\n" .. tab .. "}"
		end
	end

	return '"' .. tostring(value) .. '"'
end

-- Main
print("Reading " .. INPUT_FILE .. "...")
local fileContents = fs.readFile(INPUT_FILE)
local instances = roblox.deserializeModel(fileContents)
print("Deserialized " .. #instances .. " top-level instance(s)")

local result = {}
for _, instance in instances do
	table.insert(result, decomposeInstance(instance))
end

local json = encodeJson(result, 0)
fs.writeFile(OUTPUT_FILE, json)
print("Written to " .. OUTPUT_FILE)
