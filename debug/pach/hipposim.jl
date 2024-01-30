using HIPPO
using POMDPs
using BasicPOMCP
using POMDPTools
using DiscreteValueIteration
using Profile
using ParticleFilters
using D3Trees
using WebSockets: readguarded, open
using JSON


function generate_predicted_path(data, ws_client)
    rewarddist = hcat(data["gridRewards"]...)
    rewarddist = rewarddist .+ abs(minimum(rewarddist)) .+ 0.01

    display(rewarddist)

    mapsize = reverse(size(rewarddist)) # (x,y)
    sinit = RewardState([1, 1], mapsize, vec(trues(mapsize)))#rand(initialstate(msim))
    msolve = RewardPOMDP(sinit, size=mapsize, rewarddist=rewarddist)
    solver = POMCPSolver(tree_queries=1000, max_time=0.2, c=80)
    b0 = initialstate(msolve)
    N = 1000
    particle_up = BootstrapFilter(msolve, N)
    particle_b = initialize_belief(particle_up, b0)


    planner = solve(solver, msolve)

    pachSim = PachSimulator(msolve, planner, particle_up, particle_b, sinit)


    location_dict = data["locationDict"]

    locvec, b, sinit = predicted_path(pachSim)
    @info locvec
    pachSim.sinit = sinit
    pachSim.b = b

    response = [location_dict[locvec[i]] for i in eachindex(locvec)]
    println("Sending path: ", response)
    write(ws_client, JSON.json(Dict("action" => "ReturnPath", "args" => Dict("flightPath" => response))))
end

function generate_sim_path(data, ws_client)
    rewarddist = hcat(data["gridRewards"]...)
    rewarddist = rewarddist .+ abs(minimum(rewarddist)) .+ 0.01

    display(rewarddist)

    mapsize = reverse(size(rewarddist)) # (x,y)
    sinit = RewardState([1, 1], mapsize, vec(trues(mapsize)))#rand(initialstate(msim))
    msolve = RewardPOMDP(sinit, size=mapsize, rewarddist=rewarddist)
    solver = POMCPSolver(tree_queries=1000, max_time=0.2, c=80)
    b0 = initialstate(msolve)
    N = 1000
    particle_up = BootstrapFilter(msolve, N)
    particle_b = initialize_belief(particle_up, b0)


    planner = solve(solver, msolve)

    location_dict = data["locationDict"]

    hipposim = HIPPOSimulator(msim=msolve, planner=planner, up=particle_up, b=particle_b, 
                            sinit=sinit, max_iter=15)
    @info "Running simulation"
    hist, _, _, _, _ = simulateHIPPO(hipposim)
    a_traj = getfield.(hist, :a)
    locvec = HIPPO.loctostr(HIPPO.generatelocation(msolve, a_traj, sinit.robot))

    #locvec, b, sinit = predicted_path(pachSim)
    @info locvec
    #pachSim.sinit = sinit
    #pachSim.b = b

    response = [location_dict[locvec[i]] for i in eachindex(locvec)]
    println("Sending path: ", response)
    write(ws_client, JSON.json(Dict("action" => "ReturnPath", "args" => Dict("flightPath" => response))))
end

function initialize(rewarddist, location_dict, desired_agl_alt)
    mapsize = reverse(size(rewarddist)) # (x,y)
    maxbatt = 100
    sinit = FullState([1, 1], mapsize, vec(trues(mapsize)), maxbatt)#rand(initialstate(msim))

    msolve = create_target_search_pomdp(sinit, 
                                    size=mapsize, 
                                    rewarddist=rewarddist, 
                                    maxbatt=maxbatt, options=Dict(:observation_model=>:falco))

    #msolve = RewardPOMDP(sinit, size=mapsize, rewarddist=rewarddist)
    solver = POMCPSolver(tree_queries=1000, max_time=0.2, c=80)
    b0 = initialstate(msolve)
    N = 1000
    particle_up = BootstrapFilter(msolve, N)
    particle_b = initialize_belief(particle_up, b0)

    planner = solve(solver, msolve)
    pachSim = PachSimulator(msolve, planner, particle_up, particle_b, sinit, location_dict, desired_agl_alt, :nothing)

    return pachSim
end

function update_reward(data, ws_client, pachSim, desired_agl_alt, initialized)
    rewarddist = hcat(data["gridRewards"]...)
    rewarddist = rewarddist .+ abs(minimum(rewarddist)) .+ 0.01
    location_dict = data["locationDict"]

    if initialized
        pachSim.msim.reward = rewarddist
        pachSim.location_dict = location_dict
        println("reward updated")
    else
        pachSim = initialize(rewarddist, location_dict, desired_agl_alt)
        a, _ = BasicPOMCP.action_info(pachSim.planner, pachSim.b)
        loc = HIPPO.loctostr(HIPPO.generatelocation(pachSim.msim, [a], pachSim.sinit.robot))
        response = location_dict[loc[1]]
        commanded_alt = response[3] + pachSim.desired_agl_alt

        println("Sending first action: ", response)

        write(ws_client, JSON.json(Dict("action" => "NextFlightWaypoint", "args" => Dict("latitude" => response[1],
                                                                                    "longitude" => response[2],
                                                                                    "altitude" => commanded_alt,
                                                                                    "speed" => 2))))
        println("pachSim initialized")    
    end

    pachSim.previous_action = a
    return pachSim
end

function update_params(data, pachSim)
    pachSim.desired_agl_alt = data["altitudeCeiling"]
    return pachSim
end

# 1) Update belief
# 2) Plan for reaching next waypoint
# 3) Send next waypoint


function generate_next_action(data, ws_client, pachSim)
    (msim, up, b, sinit, previous_action) = (pachSim.msim, pachSim.up, pachSim.b, 
                                             pachSim.sinit, pachSim.previous_action)
    println("data: ", data)
    status = data["event"]

    if status == "waypoint-reached"
        o = :next_waypoint
    elseif status == "gather-info"
        o = :gather_action 
    else 
        o = :nothing
    end

    #o = status == "waypoint-reached" ? :waypoint_reached : 
    #    status == "gather-info" ? :gather_info : :nothing

    println("status: ", status)
    println("o: ", o)
    b = update(up, b, previous_action, o)
    pachSim.b = b

    #tree, b = conditional_path(pachSim)

    tree = pachSim.planner._tree
    hnode = BasicPOMCP.POMCPObsNode(tree, 1)
    a = next_action(hnode, previous_action)
    loc = HIPPO.loctostr(HIPPO.generatelocation(msim, [a], sinit.robot))

    response = pachSim.location_dict[loc[1]]

    println("Sending waypoint: ", response)
    write(ws_client, JSON.json(Dict("action" => "NextFlightWaypoint", "args" => Dict("latitude" => response[1],
                                                                                    "longitude" => response[2],
                                                                                    "altitude" => response[3],
                                                                                    "speed" => 2))))

    #Plan for reaching next waypoint
    _, info = BasicPOMCP.action_info(pachSim.planner, pachSim.b, tree_in_info = true)
    pachSim.planner._tree = info[:tree]

    pachSim.previous_action = a
    return pachSim
end

function main()
    println("HIPPO: Opening port\n")
    pachSim = nothing
    initialized = false
    desired_agl_alt = 0.0
    while true
        open("ws://127.0.0.1:8082") do ws_client
            print("HIPPO: awaiting data...\n")
            data, success = readguarded(ws_client)
            if success
                # Parse data as JSON {serviceName, args}
                payload = JSON.parse(String(data))
                action = payload["action"]
                arguments = payload["args"]

                println("Executing Action: ", action)

                if action == "CalculatePath"
                    println("initialized: ", initialized)
                    pachSim = update_reward(arguments, ws_client, pachSim, desired_agl_alt, initialized)
                    initialized = true
                    #println("reward updated")
                elseif action == "FlightStatus"
                    pachSim = generate_next_action(arguments, ws_client, pachSim)

                elseif action == "FlightParams"
                    desired_agl_alt = arguments["altitudeCeiling"]
                    #pachSim = update_params(arguments, pachSim)
                    println("desired altitude updated")
                end
            end
        end
    end
end

main()