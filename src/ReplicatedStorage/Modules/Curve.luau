export type Curve = { 
    {Position: number, Value: number} 
}

local Curve = {}

function Curve.getValueAtPosition(curve: Curve, position: number) : number
    for i = 1, #curve do
        local curveData = curve[i]
        local lastCurveData = curve[i - 1]
        if position < curveData.Position then
            continue
        end

        if lastCurveData == nil then
            return curveData.Value
        end

        local alpha = (position - curveData.Position) / (lastCurveData.Position - curveData.Position)
        return math.lerp(curveData.Value, lastCurveData.Value, math.min(1, alpha))
    end

    return 0
end

return Curve