local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Knit = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Knit"))

local playerScripts = Players.LocalPlayer:WaitForChild("PlayerScripts")
Knit.AddControllers(playerScripts:WaitForChild("Controllers"))

Knit.Start():catch(warn)
