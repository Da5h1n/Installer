local shapes = {}

-- [[ PERFORMANCE CACHE ]] --
local msqrt = math.sqrt

---Normalizes a 3D vector.
---@param x number|table Either the X component or a table containing {x,y,z}
---@param y number? The Y component
---@param z number? The Z component
---@return number, number, number
local function normalize(x, y, z)
    if type(x) == "table" then
        z = x.z
        y = x.y
        x = x.x
    end
    local mag = msqrt(x*x + y*y + z*z)
    if mag == 0 then return 0, 0, 0 end
    return x / mag, y / mag, z / mag
end

---Calculates the cross product of two vectors.
---@return number, number, number
local function cross(ax, ay, az, bx, by, bz)
    return ay*bz - az*by, az*bx - ax*bz, ax*by - ay*bx
end

---Adds a rectangular face (two triangles) to the object list.
---@param objs table The objects list to insert into.
---@param v0 table {x,y,z} vertex 1
---@param v1 table {x,y,z} vertex 2
---@param v2 table {x,y,z} vertex 3
---@param v3 table {x,y,z} vertex 4
---@param col number The palette color index.
---@param smooth number How blurry reflections are (0 to 1).
---@param emit number Light emission intensity.
---@param oneWay boolean? If true, ray passes through one side.
---@param isFloor boolean? If true, triggers checkerboard logic.
---@param specProb number? Chance of a specular reflection (0 to 1).
function shapes.addFace(objs, v0, v1, v2, v3, col, smooth, emit, oneWay, isFloor, specProb)
    local nx, ny, nz = normalize(cross(
        v1.x - v0.x, v1.y - v0.y, v1.z - v0.z,
        v2.x - v0.x, v2.y - v0.y, v2.z - v0.z
    ))

    -- Triangle 1
    table.insert(objs, {
        type = "triangle",
        v0 = v0, v1 = v1, v2 = v2,
        nx = nx, ny = ny, nz = nz,
        colorIndex = col, smoothness = smooth, emission = emit, oneWay = oneWay, isFloor = isFloor,
        specularProbability = specProb
    })

    -- Triangle 2
    table.insert(objs, {
        type = "triangle",
        v0 = v0, v1 = v2, v2 = v3,
        nx = nx, ny = ny, nz = nz,
        colorIndex = col, smoothness = smooth, emission = emit, oneWay = oneWay, isFloor = isFloor,
        specularProbability = specProb
    })
end

---Creates a sphere and adds it to the objects list.
---@param objs table The objects list.
---@param x number X world position.
---@param y number Y world position.
---@param z number Z world position.
---@param radius number Sphere size.
---@param col number Palette color index.
---@param smooth number How blurry reflections are (0 to 1).
---@param emit number Light emission intensity.
---@param specProb number? Chance of a specular reflection (0 to 1).
function shapes.addSphere(objs, x, y, z, radius, col, smooth, emit, specProb)
    table.insert(objs, {
        type = "sphere",
        x = x, y = y, z = z, r = radius,
        colorIndex = col,
        smoothness = smooth or 0,
        emission = emit or 0,
        specularProbability = specProb or 0
    })
end

local function rotate(v, ax, ay, az)
    local x, y, z = v.x, v.y, v.z
    local radX, radY, radZ = math.rad(ax), math.rad(ay), math.rad(az)
    local cosX, sinX = math.cos(radX), math.sin(radX)
    local y1, z1 = y * cosX - z * sinX, y * sinX + z * cosX
    y, z = y1, z1
    local cosY, sinY = math.cos(radY), math.sin(radY)
    local x2, z2 = x * cosY + z * sinY, -x * sinY + z * cosY
    x, z = x2, z2
    local cosZ, sinZ = math.cos(radZ), math.sin(radZ)
    local x3, y3 = x * cosZ - y * sinZ, x * sinZ + y *cosZ
    return {x = x3, y = y3, z = z}
end

---Adds a 12-triangle cube to the world.
---@param objs table The objects list.
---@param x number X position.
---@param y number Y position.
---@param z number Z position.
---@param size number Cube width/height/depth.
---@param color number Palette color index.
---@param smoothness number Reflection blurriness.
---@param emission number Light intensity.
---@param rx number? Rotation X (degrees).
---@param ry number? Rotation Y (degrees).
---@param rz number? Rotation Z (degrees).
---@param specProb number? Chance of a specular reflection (0 to 1).
function shapes.addCube(objs, x, y, z, size, color, smoothness, emission, rx, ry, rz, specProb)
    local s = size / 2
    local v = {
        {x=-s, y=-s, z=-s}, {x= s, y=-s, z=-s},
        {x= s, y= s, z=-s}, {x=-s, y= s, z=-s},
        {x=-s, y=-s, z= s}, {x= s, y=-s, z= s},
        {x= s, y= s, z= s}, {x=-s, y= s, z= s}
    }

    for i = 1, #v do
        v[i] = rotate(v[i], rx or 0, ry or 0, rz or 0)
        v[i].x, v[i].y, v[i].z = v[i].x + x, v[i].y + y, v[i].z + z
    end

    local faces = {
        {1,2,3}, {1,3,4}, {5,6,7}, {5,7,8}, 
        {1,5,8}, {1,8,4}, {2,6,7}, {2,7,3}, 
        {4,3,7}, {4,7,8}, {1,2,6}, {1,6,5}
    }

    for _, f in ipairs(faces) do
        table.insert(objs, {
            type = "triangle",
            v0 = v[f[1]], v1 = v[f[2]], v2 = v[f[3]],
            colorIndex = color, 
            smoothness = smoothness or 0, 
            emission = emission or 0,
            specularProbability = specProb or 0
        })
    end
end

---Loads an OBJ file and converts it to triangles.
---@param objs table The object list.
---@param filename string The .obj file path.
---@param pos table {x,y,z} World position.
---@param scale number Size multiplier.
---@param col number Palette index.
---@param smooth number? 0 to 1.
---@param emit number? Emission.
---@param spec number? Specular probability.
function shapes.loadOBJ(objs, filename, pos, scale, col, smooth, emit, spec)
    if not fs.exists(filename) then error("File not found: " .. filename) end
    
    local vertices = {}
    local file = fs.open(filename, "r")
    
    while true do
        local line = file.readLine()
        if not line then break end
        
        local parts = {}
        for part in string.gmatch(line, "%S+") do table.insert(parts, part) end
        
        if parts[1] == "v" then
            -- Store vertex (applying scale and position)
            table.insert(vertices, {
                x = (tonumber(parts[2]) * scale) + pos.x,
                y = (tonumber(parts[3]) * scale) + pos.y,
                z = (tonumber(parts[4]) * scale) + pos.z
            })
        elseif parts[1] == "f" then
            local vIndices = {}
            for i = 2, #parts do
                -- Extract index before the slash (e.g., "199/83" -> 199)
                local vIdx = tonumber(string.match(parts[i], "([^/]+)"))
                if vIdx then table.insert(vIndices, vIdx) end
            end
            
            -- Turn any polygon (3+ sides) into triangles
            for i = 2, #vIndices - 1 do
                table.insert(objs, {
                    type = "triangle",
                    v0 = vertices[vIndices[1]],
                    v1 = vertices[vIndices[i]],
                    v2 = vertices[vIndices[i+1]],
                    colorIndex = col,
                    smoothness = smooth or 0,
                    emission = emit or 0,
                    specularProbability = spec or 0
                })
            end
        end
    end
    file.close()
end

return shapes