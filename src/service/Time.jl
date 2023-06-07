"""
Handle contextual epoch time with naive time in SciML    
"""
module Time

export normalize_tspan, get_step

"""
Change arbitrary timespan to the range 0, 1, ...n
"""
function normalize_tspan(tstart, tend, stepsize)
    diff = tend - tstart
    if diff % stepsize != 0
        throw("Steps exceed the end of timespan!")
    end
    (0, floor(diff/stepsize))
end

"""
Transform naive step into epoch
"""
function get_step(tstart, stepsize, step)
    stepsize*step + tstart
end

end # module Time
