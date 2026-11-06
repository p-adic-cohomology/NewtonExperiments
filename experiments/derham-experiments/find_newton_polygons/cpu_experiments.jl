
function cpu_example_fast_random(n, d, p, N, resultsdict)

    if d < n
        T = collect(0:(d-1))
    else
        T = collect(0:(n-1))
    end

    l = ReentrantLock()

    Threads.@threads for i = 1:N
        f = DeRham.random_hypersurface(n, d, p)
        np = DeRham.newton_polygon(f, S = T, fastevaluation = true, algorithm = :naive)


        if np != false # f is smooth
            #np_key = tuple(np.slopes, np.slopelengths)

            @lock l begin
                if !haskey(resultsdict, np)
                    resultsdict[np] = f
                end
            end
        end
    end

    resultsdict
end

function cpu_vector_fast_random(n, d, p, N) end

function all_monomial_random_order(n, d, p) end

function cpu_example_fast_fermat(n, d, p, N) end

function cpu_vector_fast_fermat(n, d, p, N) end
