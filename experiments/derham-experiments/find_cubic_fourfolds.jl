
# using DeRham

function find_0smooth(n, d, p, nExamples)

    nTries = 7 # just some heuristic


    result = []
    while length(result) < nExamples
        f = DeRham.random_hypersurface(n, d, p)

        println("Randomly generated new f\n")

        println("Testing if f is smooth...")
        @time smooth = DeRham.issmooth_linalg(f)


        if !smooth
            println("f is not smooth.\n")
            continue
        end

        GC.gc()
        println("f is smooth!\n")

        for i = 1:nTries # give
            println("Testing if f is {0}-smooth...")
            @time smooth0 = DeRham.is_Ssmooth(f, [0])
            GC.gc()

            if smooth0
                println("f is {0}-smooth!\n")
                println("f = $f\n")
                push!(result, f)
                break
            end

            println("Changing Variables...")

            @time f = DeRham.random_change_of_variables(f)

        end

        println("Done with this f.\n")
    end

    result
end

function find_nsmooth(n, d, p, nExamples)

    nTries = 7 # just some heuristic


    result = []
    while length(result) < nExamples
        f = DeRham.random_hypersurface(n, d, p)

        println("Randomly generated new f\n")

        println("Testing if f is smooth...")
        @time smooth = DeRham.issmooth_linalg(f)


        if !smooth
            println("f is not smooth.\n")
            continue
        end

        GC.gc()
        println("f is smooth!\n")

        for i = 1:nTries # give
            println("Testing if f is {$(n-1)}-smooth...")
            @time smooth0 = DeRham.is_Ssmooth(f, [n-1])
            GC.gc()

            if smooth0
                println("f is {$(n-1)}-smooth!\n")
                println("f = $f\n")
                push!(result, f)
                break
            end

            println("Changing Variables...")

            @time f = DeRham.random_change_of_variables(f)

        end

        println("Done with this f.\n")
    end

    result
end
