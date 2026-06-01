# image!() and its private helpers — see plan.

resolve_scheme(s::ColorScheme) = s
resolve_scheme(v::AbstractVector{<:Colorant}) = ColorScheme(collect(v))
function resolve_scheme(s::Symbol)
    haskey(ColorSchemes.colorschemes, s) || error("unknown colormap $(repr(s)); see `keys(ColorSchemes.colorschemes)`")
    ColorSchemes.colorschemes[s]
end

_colorrange(_, cr) = (float(cr[1]), float(cr[2]))
function _colorrange(data, ::Nothing)
    lo = hi = nothing
    for v in data
        isfinite(v) || continue
        lo === nothing ? (lo = hi = v) : (lo = min(lo, v); hi = max(hi, v))
    end
    lo === nothing && error("data has no finite values; pass `colorrange` explicitly")
    (float(lo), float(hi))
end
