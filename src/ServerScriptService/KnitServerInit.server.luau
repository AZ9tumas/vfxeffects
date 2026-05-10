local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Knit = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Knit"))

Knit.AddServices(ServerScriptService:WaitForChild("Services"))

Knit.Start():catch(warn)
