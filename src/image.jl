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

function _scalar_rgba!(buf::AbstractMatrix{RGBA{N0f8}}, data, scheme; colorrange, colorscale, nan_color)
    Base.require_one_based_indexing(data)            # clearer error than map!'s axis-mismatch for offset arrays
    size(buf) == size(data) || error("buffer size $(size(buf)) ≠ $(size(data))")
    lo, hi = colorrange
    lo <= hi || error("colorrange lo ($lo) must be ≤ hi ($hi)")     # fail loud, not silent clamp-to-top
    slo, shi = colorscale(lo), colorscale(hi)
    (isfinite(slo) && isfinite(shi)) || error("colorscale(colorrange) not finite: ($slo,$shi); e.g. log requires colorrange > 0")
    degen = slo == shi
    nanc = convert(RGBA{N0f8}, nan_color)
    map!(buf, data) do v       # verified type-stable & zero-alloc; map! preserves index order ⇒ buf[i,j]=f(data[i,j])
        isfinite(v) || return nanc
        # clamp BEFORE colorscale so monotonic scales never see out-of-domain inputs (log10(≤0));
        # clamp(t,0,1) also normalizes a dimensionless Unitful ratio (e.g. m/cm) to a plain Real.
        t = degen ? 0.5 : (colorscale(clamp(v, lo, hi)) - slo) / (shi - slo)
        isfinite(t) ? convert(RGBA{N0f8}, get(scheme, clamp(t, 0.0, 1.0))) : nanc
    end
end

function _colorant_rgba!(buf::AbstractMatrix{RGBA{N0f8}}, data)
    Base.require_one_based_indexing(data)
    size(buf) == size(data) || error("buffer size $(size(buf)) ≠ $(size(data))")
    map!(c -> convert(RGBA{N0f8}, c), buf, data)
end

function _centers_to_bounds(x::AbstractInterval, n::Integer)
    a, b = float(leftendpoint(x)), float(rightendpoint(x))
    Δ = n > 1 ? (b - a) / (n - 1) : (b > a ? (b - a) : 1.0)
    (a - Δ/2, b + Δ/2)
end
