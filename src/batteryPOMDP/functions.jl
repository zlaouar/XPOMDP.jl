function POMDPs.states(m::TSPOMDPBattery) 
    nonterm = vec(collect(TSStateBattery(SVector(c[1],c[2]), SVector(c[3],c[4]), d) for c in Iterators.product(1:m.size[1], 1:m.size[2], 1:m.size[1], 1:m.size[2]) for d in 1:m.maxbatt))
    return push!(nonterm, TSStateBattery([-1,-1],[-1,-1],-1))
end

function POMDPs.stateindex(m::TSPOMDPBattery, s)
    if s.robot == SA[-1,-1]
        return m.size[1]^2 * m.size[2]^2 + 1
    else 
        return LinearIndices((1:m.size[1], 1:m.size[2], 1:m.size[1], 1:m.size[2], 1:m.maxbatt))[s.robot..., s.target..., s.battery]
    end
end

function POMDPs.initialstate(m::TSPOMDPBattery)
    #return Deterministic(TSStateBattery(m.robot_init,m.targetloc,m.maxbatt))
    return POMDPTools.Uniform(TSStateBattery(m.robot_init, SVector(x, y), z) for x in 1:m.size[1], y in 1:m.size[2], z in 1:m.maxbatt)
end

"""
    actions
"""

POMDPs.actions(m::TSPOMDPBattery) = (:left, :right, :up, :down, :stay)

POMDPs.discount(m::TSPOMDPBattery) = 0.95


POMDPs.actionindex(m::TSPOMDPBattery, a) = actionind[a]


function bounce(m::TSPOMDPBattery, pos, offset)
    new = clamp.(pos + offset, SVector(1,1), m.size)
end

function POMDPs.transition(m::TSPOMDPBattery, s, a)
    states = TSStateBattery[]
    probs = Float64[]
    remaining_prob = 1.0

    if isequal(s.robot, s.target)
        return Deterministic(TSStateBattery([-1,-1], copy(s.target), -1))
    end

    newrobot = bounce(m, s.robot, actiondir[a])

    push!(states, TSStateBattery(newrobot, s.target, s.battery-1))
    push!(probs, remaining_prob)

    return SparseCat(states, probs)

end

function POMDPs.reward(m::TSPOMDPBattery, s::TSStateBattery, a::Symbol, sp::TSStateBattery)
    reward_running = -1.0
    reward_target = 0.0

    if isequal(sp.robot, sp.target) # if target is found
        reward_running = 0.0
        reward_target = 1000.0 
        return reward_running + reward_target
    end

    if isterminal(m, sp) # IS THIS NECCESSARY?
        return 0.0
    end
        
    return reward_running + reward_target
end

set_default_graphic_size(18cm,14cm)

function POMDPTools.ModelTools.render(m::TSPOMDPBattery, step)
    #set_default_graphic_size(14cm,14cm)
    nx, ny = m.size
    cells = []
    target_marginal = zeros(nx, ny)

    if haskey(step, :bp) && !ismissing(step[:bp])
        for sp in support(step[:bp])
            p = pdf(step[:bp], sp)
            if sp.target != [-1,-1] # TO-DO Fix this
                target_marginal[sp.target...] += p
            end
        end
    end
    #display(target_marginal)
    norm_top = normalize(target_marginal)
    #display(norm_top)
    for x in 1:nx, y in 1:ny
        cell = cell_ctx((x,y), m.size)
        t_op = norm_top[x,y]
        
        # TO-DO Fix This
        if t_op > 1.0
            if t_op < 1.001
                t_op = 0.999
            else
                @error("t_op > 1.001", t_op)
            end
        end
        opval = t_op
        if opval > 0.0 
           opval = clamp(t_op*2,0.05,1.0)
        end
        max_op = maximum(norm_top)
        min_op = minimum(norm_top)
        frac = (opval-min_op)/(max_op-min_op)
        clr = get(ColorSchemes.bamako, frac)
        
        target = compose(context(), rectangle(), fill(clr), stroke("gray"))
        #println("opval: ", t_op)
        compose!(cell, target)

        push!(cells, cell)
    end
    grid = compose(context(), linewidth(0.00000001mm), cells...)
    outline = compose(context(), linewidth(0.01mm), rectangle(), fill("white"), stroke("black"))

    if haskey(step, :sp)
        robot_ctx = cell_ctx(step[:sp].robot, m.size)
        robot = compose(robot_ctx, circle(0.5, 0.5, 0.5), fill("blue"))
        target_ctx = cell_ctx(step[:sp].target, m.size)
        target = compose(target_ctx, star(0.5,0.5,0.8,5,0.5), fill("orange"), stroke("black"))
    else
        robot = nothing
        target = nothing
    end 
    #img = read(joinpath(@__DIR__,"../..","drone.png"));
    #robot = compose(robot_ctx, bitmap("image/png",img, 0, 0, 1, 1))
    #person = read(joinpath(@__DIR__,"../..","missingperson.png"));
    #target = compose(target_ctx, bitmap("image/png",person, 0, 0, 1, 1))

    sz = min(w,h)
    
    return compose(context((w-sz)/2, (h-sz)/2, sz, sz), robot, target, grid, outline)
end

function normie(input, a)
    return (input-minimum(a))/(maximum(a)-minimum(a))
end

function rewardinds(m, pos::SVector{2, Int64})
    correct_ind = reverse(pos)
    xind = m.size[2]+1 - correct_ind[1]
    inds = [xind, correct_ind[2]]

    return inds
end


function POMDPTools.ModelTools.render(m::TSPOMDPBattery, step, plt_reward::Bool)
    nx, ny = m.size
    cells = []
    
    minr = minimum(m.reward)-1
    maxr = maximum(m.reward)
    for x in 1:nx, y in 1:ny
        cell = cell_ctx((x,y), m.size)
        r = m.reward[rewardinds(m, SA[x,y])...]
        if iszero(r)
            target = compose(context(), rectangle(), fill("black"), stroke("gray"))
        else
            frac = (r-minr)/(maxr-minr)
            clr = get(ColorSchemes.turbo, frac)
            target = compose(context(), rectangle(), fill(clr), stroke("gray"), fillopacity(0.5))
        end

        compose!(cell, target)
        push!(cells, cell)
    end
    grid = compose(context(), linewidth(0.00000001mm), cells...)
    outline = compose(context(), linewidth(0.01mm), rectangle(), fill("white"), stroke("black"))

    if haskey(step, :sp)
        robot_ctx = cell_ctx(step[:sp].robot, m.size)
        robot = compose(robot_ctx, circle(0.5, 0.5, 0.5), fill("blue"))
        target_ctx = cell_ctx(step[:sp].target, m.size)
        target = compose(target_ctx, star(0.5,0.5,1.0,5,0.5), fill("orange"), stroke("black"))
    else
        robot = nothing
        target = nothing
    end
    sz = min(w,h)
    #return compose(context((w-sz)/2, (h-sz)/2, sz, (ny/nx)*sz), robot, target, grid, outline)
    return compose(context((w-sz)/2, (h-sz)/2, sz, sz), robot, target, grid, outline)
end

#POMDPs.isterminal(m::TSPOMDPBattery, s::TSStateBattery) = s.robot == SA[-1,-1]
function dist(curr, start)
    sum(abs.(curr-start))
end

function POMDPs.isterminal(m::TSPOMDPBattery, s::TSStateBattery)
    required_batt = dist(s.robot, m.robot_init)
    return s.battery - required_batt <= 1 || s.robot == SA[-1,-1] 
end