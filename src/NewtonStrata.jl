module NewtonStrata

using DeRham

export SlopeMultiplicityPolygon
export from_slopes_polygon, to_slopes_polygon
export height, polygon_value, integer_values
export is_symmetric, has_integral_breakpoints, is_valid_symmetric_polygon
export lies_on_or_above, sdim, codim
export is_ordinary, is_supersingular, p_rank
export enumerate_symmetric_polygons

"""
    SlopeMultiplicityPolygon(slopes, slopelengths)

A convex slope polygon represented by its increasing rational slopes and the
horizontal length of each slope segment. Adjacent segments with equal slopes
are combined.
"""
struct SlopeMultiplicityPolygon
    slopes::Vector{Rational{Int}}
    slopelengths::Vector{Int}

    function SlopeMultiplicityPolygon(slopes, slopelengths)
        raw_slopes = collect(slopes)
        raw_lengths = collect(slopelengths)
        length(raw_slopes) == length(raw_lengths) ||
            throw(ArgumentError("slopes and slopelengths must have equal length"))

        exact_slopes = Rational{Int}[_exact_rational(slope) for slope in raw_slopes]
        lengths = Int[]
        for len in raw_lengths
            len isa Integer && !(len isa Bool) ||
                throw(ArgumentError("slopelengths must be positive integers"))
            len > 0 || throw(ArgumentError("slopelengths must be positive integers"))
            push!(lengths, Int(len))
        end

        all(slope -> 0 <= slope <= 1, exact_slopes) ||
            throw(ArgumentError("Newton polygon slopes must lie in [0, 1]"))
        all(i -> exact_slopes[i] <= exact_slopes[i + 1], 1:(length(exact_slopes) - 1)) ||
            throw(ArgumentError("slopes must be nondecreasing"))

        normalized_slopes = Rational{Int}[]
        normalized_lengths = Int[]
        for (slope, len) in zip(exact_slopes, lengths)
            if !isempty(normalized_slopes) && last(normalized_slopes) == slope
                normalized_lengths[end] += len
            else
                push!(normalized_slopes, slope)
                push!(normalized_lengths, len)
            end
        end
        new(normalized_slopes, normalized_lengths)
    end
end

function _exact_rational(value)
    if value isa Integer
        return Int(value) // 1
    elseif value isa Rational
        return Int(numerator(value)) // Int(denominator(value))
    end
    throw(ArgumentError("slopes must be integers or exact rationals"))
end

Base.:(==)(a::SlopeMultiplicityPolygon, b::SlopeMultiplicityPolygon) =
    a.slopes == b.slopes && a.slopelengths == b.slopelengths

Base.isequal(a::SlopeMultiplicityPolygon, b::SlopeMultiplicityPolygon) =
    isequal(a.slopes, b.slopes) && isequal(a.slopelengths, b.slopelengths)

Base.hash(polygon::SlopeMultiplicityPolygon, seed::UInt) =
    hash((polygon.slopes, polygon.slopelengths), seed)

"""Return the total horizontal length of a slope polygon."""
height(polygon::SlopeMultiplicityPolygon) = sum(polygon.slopelengths; init=0)

"""Convert a `DeRham.SlopesPolygon` to this module's exact representation."""
from_slopes_polygon(polygon::DeRham.SlopesPolygon) =
    SlopeMultiplicityPolygon(polygon.slopes, polygon.slopelengths)

"""Convert an integral-breakpoint slope polygon to `DeRham.SlopesPolygon`."""
function to_slopes_polygon(polygon::SlopeMultiplicityPolygon)
    has_integral_breakpoints(polygon) ||
        throw(ArgumentError("DeRham.SlopesPolygon conversion requires integral breakpoints"))

    vertices = Tuple{Int64,Int64}[(0, 0)]
    x = 0
    y = 0 // 1
    for (slope, len) in zip(polygon.slopes, polygon.slopelengths)
        x += len
        y += slope * len
        push!(vertices, (Int64(x), Int64(numerator(y))))
    end
    DeRham.SlopesPolygon(vertices)
end

_as_polygon(polygon::SlopeMultiplicityPolygon) = polygon
_as_polygon(polygon::DeRham.SlopesPolygon) = from_slopes_polygon(polygon)

"""Evaluate the polygon at an integer abscissa between zero and its height."""
function polygon_value(polygon, x::Integer)
    p = _as_polygon(polygon)
    0 <= x <= height(p) || throw(BoundsError(p, x))

    remaining = Int(x)
    y = 0 // 1
    for (slope, len) in zip(p.slopes, p.slopelengths)
        used = min(remaining, len)
        y += slope * used
        remaining -= used
        remaining == 0 && break
    end
    y
end

"""Return the exact polygon values at all integer abscissas from zero to the end."""
integer_values(polygon) = [polygon_value(polygon, x) for x in 0:height(_as_polygon(polygon))]

"""Test the complementary-slope symmetry of a height-`2g` Newton polygon."""
function is_symmetric(polygon)
    p = _as_polygon(polygon)
    iseven(height(p)) || return false
    n = length(p.slopes)
    for i in 1:n
        j = n - i + 1
        p.slopes[i] + p.slopes[j] == 1 // 1 || return false
        p.slopelengths[i] == p.slopelengths[j] || return false
    end
    true
end

"""Test whether every vertex at a slope change has integral coordinates."""
function has_integral_breakpoints(polygon)
    p = _as_polygon(polygon)
    y = 0 // 1
    for (slope, len) in zip(p.slopes, p.slopelengths)
        y += slope * len
        denominator(y) == 1 || return false
    end
    true
end

"""Test complementary-slope symmetry and integral breakpoints together."""
is_valid_symmetric_polygon(polygon) =
    is_symmetric(polygon) && has_integral_breakpoints(polygon)

"""Return whether `upper` lies on or above `lower` pointwise."""
function lies_on_or_above(upper, lower)
    a = _as_polygon(upper)
    b = _as_polygon(lower)
    height(a) == height(b) || return false
    all(x -> polygon_value(a, x) >= polygon_value(b, x), 0:height(a))
end

function _require_integral_symmetric(polygon)
    is_symmetric(polygon) ||
        throw(ArgumentError("Oort invariants require complementary-slope symmetry"))
    has_integral_breakpoints(polygon) ||
        throw(ArgumentError("Oort invariants require integral breakpoints"))
    polygon
end

"""Compute Oort's `sdim` lattice-point count for a symmetric Newton polygon."""
function sdim(polygon)
    p = _require_integral_symmetric(_as_polygon(polygon))
    g = height(p) ÷ 2
    sum((x - ceil(Int, polygon_value(p, x)) for x in 1:g); init=0)
end

"""Compute the codimension of the Newton stratum in `A_g` by Oort's formula."""
function codim(polygon)
    p = _require_integral_symmetric(_as_polygon(polygon))
    g = height(p) ÷ 2
    (g * (g + 1)) ÷ 2 - sdim(p)
end

"""Return the multiplicity of slope zero."""
function p_rank(polygon)
    p = _as_polygon(polygon)
    sum((len for (slope, len) in zip(p.slopes, p.slopelengths) if iszero(slope)); init=0)
end

"""Test whether the polygon is ordinary, with `g` zero and `g` unit slopes."""
function is_ordinary(polygon)
    p = _as_polygon(polygon)
    is_valid_symmetric_polygon(p) || return false
    g = height(p) ÷ 2
    p_rank(p) == g && all(slope -> slope == 0 // 1 || slope == 1 // 1, p.slopes)
end

"""Test whether every slope is one half (the supersingular polygon)."""
function is_supersingular(polygon)
    p = _as_polygon(polygon)
    height(p) > 0 && is_valid_symmetric_polygon(p) &&
        all(==(1 // 2), p.slopes)
end

"""Enumerate all symmetric height-`2g` Newton polygons with integral vertices."""
function enumerate_symmetric_polygons(genus::Integer)
    genus >= 0 || throw(ArgumentError("genus must be nonnegative"))
    g = Int(genus)
    half = 1 // 2
    left = Tuple{Rational{Int},Int}[]
    polygons = SlopeMultiplicityPolygon[]

    function add_reflection()
        slopes = Rational{Int}[]
        lengths = Int[]
        has_central_half = !isempty(left) && last(left)[1] == half
        left_stop = length(left) - Int(has_central_half)

        for i in 1:left_stop
            push!(slopes, left[i][1])
            push!(lengths, left[i][2])
        end
        if has_central_half
            push!(slopes, half)
            push!(lengths, 2 * last(left)[2])
            for i in (length(left) - 1):-1:1
                push!(slopes, 1 // 1 - left[i][1])
                push!(lengths, left[i][2])
            end
        else
            for i in length(left):-1:1
                push!(slopes, 1 // 1 - left[i][1])
                push!(lengths, left[i][2])
            end
        end

        polygon = SlopeMultiplicityPolygon(slopes, lengths)
        is_valid_symmetric_polygon(polygon) ||
            error("internal error: enumeration produced an invalid polygon")
        push!(polygons, polygon)
    end

    function visit(x::Int, y::Rational{Int}, last_slope::Rational{Int})
        if x == g
            add_reflection()
            return
        end

        remaining = g - x
        for len in 1:remaining
            candidates = Rational{Int}[rise // len for rise in 0:fld(len, 2)]
            isodd(len) && push!(candidates, half)
            sort!(unique!(candidates))

            for slope in candidates
                slope > last_slope || continue
                slope <= half || continue
                next_x = x + len
                next_x < g && slope == half && continue
                next_y = y + slope * len
                next_x < g && denominator(next_y) != 1 && continue

                push!(left, (slope, len))
                visit(next_x, next_y, slope)
                pop!(left)
            end
        end
    end

    visit(0, 0 // 1, -1 // 1)
    polygons
end

end
