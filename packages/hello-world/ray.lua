local shapes = require("shapes")

if not term.setGraphicsMode then error("USE CRAFT-OS PC!") end
term.setGraphicsMode(2)

local msqrt, mabs, mmax, mmin, mfloor, mrandom = math.sqrt, math.abs, math.max, math.min, math.floor, math.random
local tinsert, tremove = table.insert, table.remove
local cos, sin, pi = math.cos, math.sin, math.pi

local width, height = term.getSize(2)

local camera = {x = 0, y = 0, z = -50}

-- [[ DEBUG TRACKING ]] --
local intersection_tests = 0
local complexity_map = {}

-- [[ SETTINGS ]] --
local USE_AMBIENT = true       -- Toggle this to true/false
local AMBIENT_INTENSITY = 1  -- How bright the "void" is (0.1 is dim, 0.5 is bright)

local SAMPLES_PER_PIXEL = 40
local MAX_BOUNCES = 6
local EXPOSURE = 2.5         -- Brightens the final "camera" image
local BOUNCE_ALBEDO = 0.9   -- 85% light conservation (much brighter)
local STEPS = 16          -- Reduced from 48 to allow for 15 unique colors!

local MAX_PALETTE_COLOURS = 15 -- (256 - 16) / 16 steps
local colourCount = 0

local colourCache = {}
local nextPaletteBase = 16

local bvhStack = {}

local function hexToRGB(hex)
    return bit32.extract(hex, 16, 8) / 255, bit32.extract(hex, 8, 8) / 255, bit32.extract(hex, 0, 8) / 255
end

local function registerColour(r, g, b)
    -- check if we already have this colour
    local hexKey = math.floor(r*255)*65536 + math.floor(g*255)*256 + math.floor(b*255)
    if colourCache[hexKey] then return colourCache[hexKey].base end

    -- if we have no palette space
    if colourCount >= MAX_PALETTE_COLOURS then
        return nil
    end

    local base = nextPaletteBase
    for i = 0, (STEPS - 1) do
        local intensity = i / (STEPS - 1)
        term.setPaletteColor(base + i, r * intensity, g * intensity, b * intensity)
    end

    colourCache[hexKey] = {base = base, r = r, g = g, b = b}
    nextPaletteBase = nextPaletteBase + STEPS
    colourCount = colourCount + 1
    return base
end

local function findOrCreatePalette(r, g, b)
    local closest, minDist = 16, math.huge
    for _, data in pairs(colourCache) do
        local dist = (r - data.r)^2 + (g - data.g)^2 + (b - data.b)^2
        if dist < minDist then
            minDist, closest = dist, data.base
        end
    end

    -- if the closest is still different 
    -- and we have space create new palette
    if minDist > 0.05 and colourCount < MAX_PALETTE_COLOURS then
        local newBase = registerColour(r, g, b)
        if newBase then return newBase end
    end

    return closest
end

local function getRGBFromPalette(index)
    local base = mfloor(index / STEPS) * STEPS -- Use the STEPS variable!
    for hex, data in pairs(colourCache) do
        if data.base == base then
            return {r = data.r, g = data.g, b = data.b}
        end
    end
    return {r = 1, g = 1, b = 1}
end

local function registerHex(hex)
    local r, g, b = hexToRGB(hex)
    local base = registerColour(r, g, b)
    return {base = base} -- Return table so your .base calls don't error
end

local function cross(ax, ay, az, bx, by, bz)
    return ay*bz - az*by, az*bx - ax*bz, ax*by - ay*bx
end

local function normalize(x, y, z)
    local mag = msqrt(x*x + y*y + z*z)
    if mag == 0 then return 0, 0, 0 end
    return x / mag, y / mag, z / mag
end

local function reflect(dx, dy, dz, nx, ny, nz)
    local dot = dx * nx + dy * ny + dz * nz
    return
        dx - 2 * dot * nx,
        dy - 2 * dot * ny,
        dz - 2 * dot * nz
    
end

local function getNormal(hitX, hitY, hitZ, obj, rdx, rdy, rdz)
    if obj.type == "sphere" then
        return normalize(hitX - obj.x, hitY - obj.y, hitZ - obj.z)
    else
        local e1x, e1y, e1z = obj.v1.x - obj.v0.x, obj.v1.y - obj.v0.y, obj.v1.z - obj.v0.z
        local e2x, e2y, e2z = obj.v2.x - obj.v0.x, obj.v2.y - obj.v0.y, obj.v2.z - obj.v0.z

        local nx, ny, nz = cross(e1x, e1y, e1z, e2x, e2y, e2z)
        nx, ny, nz = normalize(nx, ny, nz)

        if nx * rdx + ny * rdy + nz * rdz > 0 then
            return -nx, -ny, -nz
        end
        return nx, ny, nz
    end
end

local function randomInHemisphere(nx, ny, nz)
    local r1, r2 = mrandom(), mrandom()
    local phi = 2 * math.pi * r1
    local x, y, z = cos(phi) * msqrt(r2), sin(phi) * msqrt(r2), msqrt(1 - r2)

    local ax, ay, az = mabs(nx) > 0.1 and 0 or 1, mabs(nx) > 0.1 and 1 or 0, 0
    local ux, uy, uz = cross(ax, ay, az, nx, ny, nz)
    ux, uy ,uz = normalize(ux, uy, uz)
    local vx, vy, vz = cross(nx, ny, nz, ux, uy, uz)

    return x*ux + y*vx + z*nx, x*uy + y*vy + z*ny, x*uz + y*vz + z*nz
end

local function intersectAABB(ox, oy, oz, invX, invY, invZ, min, max, bestT)
    intersection_tests = intersection_tests + 1
    local t1 = (min.x - ox) * invX
    local t2 = (max.x - ox) * invX
    local tmin = mmin(t1, t2)
    local tmax = mmax(t1, t2)

    local t3 = (min.y - oy) * invY
    local t4 = (max.y - oy) * invY
    tmin = mmax(tmin, mmin(t3, t4))
    tmax = mmin(tmax, mmax(t3, t4))

    local t5 = (min.z - oz) * invZ
    local t6 = (max.z - oz) * invZ
    tmin = mmax(tmin, mmin(t5, t6))
    tmax = mmin(tmax, mmax(t5, t6))

    return tmax >= math.max(0, tmin) and tmin < bestT
end

local function intersectTriangle(ox, oy, oz, dx, dy, dz, tri)
    intersection_tests = intersection_tests + 1

    local v0, v1, v2 = tri.v0, tri.v1, tri.v2
    local v0x, v0y, v0z = v0.x, v0.y, v0.z

    local e1x, e1y, e1z = v1.x - v0x, v1.y - v0y, v1.z - v0z
    local e2x, e2y, e2z = v2.x - v0x, v2.y - v0y, v2.z - v0z

    local hx, hy, hz = dy * e2z - dz * e2y, dz * e2x - dx * e2z, dx * e2y - dy * e2x
    local a = e1x * hx + e1y * hy + e1z * hz

    
    if tri.oneWay and dz > 0 then return nil end


    if a > -0.000001 and a < 0.000001 then return nil end

    local f = 1.0 / a
    local sx, sy, sz = ox - v0x, oy - v0y, oz - v0z
    local u = f * (sx * hx + sy * hy + sz * hz)
    if u < 0 or u > 1 then return nil end

    local qx, qy, qz = sy * e1z - sz * e1y, sz * e1x - sx * e1z, sx * e1y - sy * e1x
    local v = f * (dx * qx + dy * qy + dz * qz)
    if v < 0 or u + v > 1 then return nil end

    local t = f * (e2x * qx + e2y * qy + e2z * qz)
    return t > 0.001 and t or nil
end

local function intersectSphere(rox, roy, roz, rdx, rdy, rdz, sphere)
    intersection_tests = intersection_tests + 1

    local ocX, ocY, ocZ = rox - sphere.x, roy - sphere.y, roz - sphere.z

    local a = rdx*rdx + rdy*rdy + rdz*rdz
    local b = 2 * (ocX * rdx + ocY * rdy + ocZ * rdz)
    local c = (ocX*ocX + ocY*ocY + ocZ*ocZ) - sphere.r^2

    local discriminant = b^2 - 4 * a * c
    if discriminant < 0 then return nil end
    return (-b - msqrt(discriminant)) / (2 * a)
end

local function buildBVH(triangles)
    local node = {}

    -- calculate bounding box for all triangles in this set
    local min = {x = math.huge, y = math.huge, z = math.huge}
    local max = {x =-math.huge, y =-math.huge, z =-math.huge}

    for _, tri in ipairs(triangles) do
        for _, v in ipairs({tri.v0, tri.v1, tri.v2}) do
            min.x, max.x = math.min(min.x, v.x), math.max(max.x, v.x)
            min.y, max.y = math.min(min.y, v.y), math.max(max.y, v.y)
            min.z, max.z = math.min(min.z, v.z), math.max(max.z, v.z)
        end
    end
    node.min, node.max = min, max

    node.cx = (min.x + max.x) * 0.5
    node.cy = (min.y + max.y) * 0.5
    node.cz = (min.z + max.z) * 0.5

    if #triangles <= 4 then
        node.triangles = triangles
        return node
    end

    local dx, dy, dz = max.x - min.x, max.y - min.y, max.z - min.z
    local axis = "x"
    if dy > dx and dy > dz then axis = "y" elseif dz > dx and dx > dy then axis = "z" end

    table.sort(triangles, function (a, b)
        local centerA = (a.v0[axis] + a.v1[axis] + a.v2[axis]) / 3
        local centerB = (b.v0[axis] + b.v1[axis] + b.v2[axis]) / 3
        return centerA < centerB
    end)

    local mid = math.floor(#triangles / 2)
    local leftTris, rightTris = {}, {}
    for i=1, #triangles do
        if i <= mid then table.insert(leftTris, triangles[i]) else table.insert(rightTris, triangles[i]) end
    end

    node.left = buildBVH(leftTris)
    node.right = buildBVH(rightTris)

    return node
end

local function traceBVH(root, ox, oy, oz, dx, dy, dz, bestT, bestObj)
    local invX = dx ~= 0 and (1/dx) or 1e30
    local invY = dy ~= 0 and (1/dy) or 1e30
    local invZ = dz ~= 0 and (1/dz) or 1e30

    local ptr = 1
    bvhStack[1] = root

    while ptr > 0 do
        local node = bvhStack[ptr]
        ptr = ptr - 1

        if intersectAABB(ox, oy, oz, invX, invY, invZ, node.min, node.max, bestT) then
            if node.triangles then
                -- check triangles in leaf
                for i = 1, #node.triangles do
                    local t = intersectTriangle(ox, oy, oz, dx, dy, dz, node.triangles[i])
                    if t and t < bestT then
                        bestT, bestObj = t, node.triangles[i]
                    end
                end
            else
                -- Front to back sorting
                local left = node.left
                local right = node.right

                local ld = (left.cx - ox)^2 + (left.cy - oy)^2 + (left.cz - oz)^2
                local rd = (right.cx - ox)^2 + (right.cy - oy)^2 + (right.cz - oz)^2

                if rd < ld then
                    -- right is closer: push left first, then right (so right is popped first)
                    ptr = ptr + 1; bvhStack[ptr] = left
                    ptr = ptr + 1; bvhStack[ptr] = right
                else
                    ptr = ptr + 1; bvhStack[ptr] = right
                    ptr = ptr + 1; bvhStack[ptr] = left
                end
            end
        end
    end
    return bestT, bestObj
end

local C_RED    = registerHex(0xFF4444).base
local C_GREEN  = registerHex(0x44FF44).base
local C_BLUE   = registerHex(0x4444FF).base
--local C_PURPLE = registerHex(0xAF00FF).base
local C_GREY   = registerHex(0x888888).base
--local C_GOLD   = registerHex(0xFFD700).base
local C_WHITE  = registerHex(0xFFFFFF). base
local C_BLACK = registerHex(0x050505).base

local objects = {}

-- FLOOR (Adding the 'true' at the end for the isFloor tag)
shapes.addFace(objects, {x=-40, y=-12, z=0}, {x= 40, y=-12, z=0}, {x= 40, y=-12, z=100}, {x=-40, y=-12, z=100}, C_GREY, 0, 0, false, true)

-- CEILING
shapes.addFace(objects, {x=-40, y=30, z=0}, {x= 40, y=30, z=0}, {x= 40, y=30, z=100}, {x=-40, y=30, z=100}, C_GREY, 0, 0)

-- BACK WALL
shapes.addFace(objects, {x=-40, y=-12, z=100}, {x= 40, y=-12, z=100}, {x= 40, y=30, z=100}, {x=-40, y=30, z=100}, C_GREY, 0, 0)

-- LEFT WALL (Red)
shapes.addFace(objects, {x=-40, y=-12, z=0}, {x=-40, y=-12, z=100}, {x=-40, y=30, z=100}, {x=-40, y=30, z=0}, C_RED, 0, 0)

-- RIGHT WALL (Green)
shapes.addFace(objects, {x= 40, y=-12, z=0}, {x= 40, y=30, z=0}, {x= 40, y=30, z=100}, {x= 40, y=-12, z=100}, C_GREEN, 0, 0)

-- ONE-WAY FRONT WALL (z=0)
shapes.addFace(objects, {x=-40, y=-12, z=0}, {x= 40, y=-12, z=0}, {x= 40, y=30, z=0}, {x=-40, y=30, z=0}, C_BLUE, 0, 0, true)

-- CEILING LIGHT
shapes.addFace(objects, {x=-15, y=29.9, z=40}, {x= 15, y=29.9, z=40}, {x= 15, y=29.9, z=60}, {x=-15, y=29.9, z=60}, C_WHITE, 0, 15.0)

-- CUBE
--shapes.addCube(objects, 0, 0, 45, 10, C_WHITE, 0, 0, 0, 0, 0)

--Spheres
--shapes.addSphere(objects, -30, -2, 45, 7, C_WHITE, 1, 0, 1)
--shapes.addSphere(objects, -10, -2, 45, 7, C_WHITE, 1, 0, 0.4)
--shapes.addSphere(objects, 10, -2, 45, 7, C_WHITE, 1, 0, 0.15)
--shapes.addSphere(objects, 30, -2, 45, 7, C_WHITE, 1, 0, 0.02)

--shapes.addSphere(objects, 0, -2, 45, 10, C_RED, 1, 0, 0.2)

--shapes.loadOBJ(objects, "knight.obj",{x=0, y=-2, z=-10}, 7, C_PURPLE, 0, 90, 0)

shapes.loadOBJ(objects, "dragon_vrip_res4.obj",{x=0, y=-20, z=10}, 150, C_WHITE, 1, 0, 1)

local triangleList = {}
local sphereList = {}
for _, obj in ipairs(objects) do
    if obj.type == "sphere" then table.insert(sphereList, obj)
    else table.insert(triangleList, obj) end
end

local bvhRoot = buildBVH(triangleList)

local function findClosestHit(ox, oy, oz, dx, dy, dz)
    local closestT, hitObj = math.huge, nil

    for i=1, #sphereList do
        local obj = sphereList[i]
        local t = intersectSphere(ox, oy, oz, dx, dy, dz, obj)
        if t and t > 0.001 and t < closestT then
            closestT, hitObj = t, obj
        end
    end

    closestT, hitObj = traceBVH(bvhRoot, ox, oy, oz, dx, dy, dz, closestT, hitObj)

    return closestT, hitObj
end

local function tracePath(ox, oy, oz, dx, dy, dz, depth)
    if depth <= 0 then return {r=0, g=0, b=0} end



    local t, hitObj = findClosestHit(ox, oy, oz, dx, dy, dz)

    if not hitObj then
        if USE_AMBIENT then
            return {r=AMBIENT_INTENSITY * 0.05, g=AMBIENT_INTENSITY * 0.1, b=AMBIENT_INTENSITY * 0.2}
        else
            return {r=0, g=0, b=0}
        end
    end

    local hX, hY, hZ = ox + dx * t, oy + dy * t, oz + dz * t
    local hitColour = hitObj.colorIndex

    if hitObj.isFloor then
        if (mfloor(hX / 10) + mfloor(hZ / 10)) % 2 == 0 then
            hitColour = C_BLACK
        else
            hitColour = C_WHITE
        end
    end

    local objRGB = getRGBFromPalette(hitColour)
    local emit = hitObj.emission or 0

    if hitObj.emission > 0 then
        local maxBrightness = 10.0
        return {
            r = mmin(objRGB.r * emit, maxBrightness),
            g = mmin(objRGB.g * emit, maxBrightness),
            b = mmin(objRGB.b * emit, maxBrightness)
        }
    end

    -- [[ RUSSIAN ROULETTE ]] --
    if depth < MAX_BOUNCES - 2 then
        local maxCol = mmax(objRGB.r, mmax(objRGB.g, objRGB.b))
        if maxCol > 0 then
            if mrandom() > maxCol then return {r=0, g=0, b=0} end
            objRGB.r, objRGB.g, objRGB.b = objRGB.r/maxCol, objRGB.g/maxCol, objRGB.b/maxCol
        end
    end

    local nx, ny, nz = getNormal(hX, hY, hZ, hitObj, dx, dy, dz)

    local nextOrigin = {x = hX + nx * 0.1, y = hY + ny * 0.1, z = hZ + nz * 0.1}
    local nextDX, nextDY, nextDZ

    local specProb = hitObj.specularProbability or 1
    local smoothness = hitObj.smoothness or 0

    if mrandom() < specProb then
        -- Specular
        local rx, ry, rz = reflect(dx, dy, dz, nx, ny, nz)
        local diffX, diffY, diffZ = randomInHemisphere(nx, ny, nz)

        nextDX, nextDY, nextDZ = normalize(
            rx * smoothness + diffX * (1 - smoothness),
            ry * smoothness + diffY * (1 - smoothness),
            rz * smoothness + diffZ * (1 - smoothness)
        )
    else
        -- Pure Diffuse
        nextDX, nextDY, nextDZ = randomInHemisphere(nx, ny, nz)
    end

    local incomingLight = tracePath(nextOrigin.x, nextOrigin.y, nextOrigin.z, nextDX, nextDY, nextDZ, depth - 1)

    return {
        r = incomingLight.r * objRGB.r * BOUNCE_ALBEDO,
        g = incomingLight.g * objRGB.g * BOUNCE_ALBEDO,
        b = incomingLight.b * objRGB.b * BOUNCE_ALBEDO
    }
end

term.clear()
-- [[ REFINED MAIN LOOP ]] --
for y = 0, height - 1 do
    for x = 0, width - 1 do
        intersection_tests = 0
        local dx, dy = (x - width/2) / (width/2), (height/2 - y) / (width / 2)
        local rdx, rdy, rdz = normalize(dx, dy, 1)

        local rSum, gSum, bSum = 0, 0, 0

        for i = 1, SAMPLES_PER_PIXEL do
            local jitterX = (mrandom() - 0.5) / width
            local jitterY = (mrandom() - 0.5) / height

            local jdx, jdy = (x + jitterX - width/2) / (width/2), (height/2 - (y + jitterY)) / (width / 2)
            local jrdx, jrdy, jrdz = normalize(jdx, jdy, 1)

            local res = tracePath(camera.x, camera.y, camera.z, jrdx, jrdy, jrdz, MAX_BOUNCES)
            rSum = rSum + res.r
            gSum = gSum + res.g
            bSum = bSum + res.b
        end

        complexity_map[y * width + x] = intersection_tests
        
        local rAvg = (rSum / SAMPLES_PER_PIXEL) * EXPOSURE
        local gAvg = (gSum / SAMPLES_PER_PIXEL) * EXPOSURE
        local bAvg = (bSum / SAMPLES_PER_PIXEL) * EXPOSURE

        local t, hitObj = findClosestHit(camera.x, camera.y, camera.z, rdx, rdy, rdz)

        if hitObj then
            if hitObj.emission > 0 then
                local lightBase = hitObj.colorIndex
                term.setPixel(x, y, lightBase + (STEPS - 1)) --should colour based on light colour instead of fixed white
            else

                local luminance = (rAvg * 0.3 + gAvg * 0.59 + bAvg * 0.11)

                local finalPalette
                if luminance > 0.8 then
                    finalPalette = hitObj.colorIndex
                else
                    finalPalette = findOrCreatePalette(rAvg, gAvg, bAvg)
                end

                local brightness = math.sqrt(math.max(0, math.min(0.99, luminance)))
                local finalCol = finalPalette + math.floor(brightness * (STEPS - 1))

                term.setPixel(x, y, finalCol)
            end
        end
    end
    os.queueEvent("yield")
    os.pullEvent("yield")
end

-- [[ EXPORT DEBUG DATA ]] --
local function exportDebug()
    local success, err = pcall(function()
        local f = fs.open("debug_stats.txt", "w")
        if not f then 
            print("Warning: Could not open debug file (Disk full or read-only?)")
            return 
        end
        
        f.writeLine("Tests per pixel (Width: "..width..")")
        for i = 0, (width * height) - 1 do
            -- f.write returns nil on failure in some CC versions/forks
            local ok = f.write((complexity_map[i] or 0) .. ",")
            if (i + 1) % width == 0 then f.write("\n") end
            
            -- Optional: Yield every 1000 pixels to prevent "Too long without yielding" 
            -- if the file is massive and the disk is slow
            if i % 1000 == 0 then os.queueEvent("yield") os.pullEvent("yield") end
        end
        f.close()
        print("Debug data saved to debug_stats.txt")
    end)

    if not success then
        print("Error saving debug file: " .. tostring(err))
    end
end

exportDebug()

os.pullEvent("key") 
term.setGraphicsMode(0)