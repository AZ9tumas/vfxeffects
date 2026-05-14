local module = {}

-- Each entry stores { part, originalTransparency } so the part can be
-- restored to its pre-modification transparency later.
module.Characters = {} :: { [number]: { part: BasePart, originalTransparency: number } }

function module.EnableCharacterTransparency(char: Model, transparency: number)
    for _, part in char:GetDescendants() do
        if part:IsA("BasePart") then
            table.insert(module.Characters, { part = part, originalTransparency = part.Transparency })
            part.Transparency = transparency
        elseif part:IsA("Decal") then
            part.Transparency = transparency
            table.insert(module.Characters, { part = part, originalTransparency = part.Transparency })
        elseif part:IsA("ParticleEmitter") then
            part.Enabled = transparency < 1
            table.insert(module.Characters, { part = part, originalTransparency = if part.Enabled then 0 else 1 })
        end
    end
end

function module.RestoreCharacterTransparency(char: Model)
    for _, entry in module.Characters do
        if entry.part:IsDescendantOf(char) then
            if entry.part:IsA("BasePart") or entry.part:IsA("Decal") then
                entry.part.Transparency = entry.originalTransparency
            elseif entry.part:IsA("ParticleEmitter") then
                entry.part.Enabled = entry.originalTransparency < 1
            end
        end
    end
end

return module