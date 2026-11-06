
function data_fermat_curves()

    #ps = [7,11,13,17,19,23,29,31,37,41]
    ps = [
        7,
        11,
        13,
        17,
        19,
        23,
        29,
        31,
        37,
        41,
        43,
        47,
        53,
        59,
        61,
        67,
        71,
        73,
        79,
        83,
        89,
        97,
    ]
    ds = [4, 5, 6]
    #ds = [3,4,5,6,7]

    for d in ds
        for p in ps
            f = DeRham.fermat_hypersurface(3, d, p)

            z = DeRham.zeta_function(f, algorithm = :naive, fastevaluation = true)
            println("p: $p, d: $d, p mod d = $(p % d)")
            println(z)
            println()
        end
    end
end

function data_fermat_deform_6()

    #ps = [7,11,13,17,19,23,29,31,37,41]
    ps =
        [11, 13, 17, 19, 23, 29, 31, 37, 41, 43, 47, 53, 59, 61, 67, 71, 73, 79, 83, 89, 97]

    d = 6
    for p in ps
        f = DeRham.fermat_hypersurface(3, 6, p)
        f += prod((gens(parent(f)) .^ 2))

        z = DeRham.zeta_function(f, algorithm = :naive, fastevaluation = true)
        println("p: $p, d: $d, p mod d = $(p % d), p mod 12 = $(p % 12)")
        println(z)
        println()
    end
end
