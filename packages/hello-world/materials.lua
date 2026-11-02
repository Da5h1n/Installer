local materials = {}

function materials.make(params)
    return {
        colourIndex = params.colour or params.colourIndex,
        smoothness  = params.smoothness or 0,
        specProb    = params.specProb or 0,
        emission    = params.emission or 0,

        type = (params.emission and params.emission > 0)
            and "emissive"
            or ((params.specProb or 0) > 0 and "specular" or "diffuse")
    }
end