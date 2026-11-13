# contour!() — iso-lines of a matrix, traced by Contour.jl and drawn with one ImPlot.PlotLine per level.

import Contour

# `n` levels evenly spaced strictly inside the finite data range (Contour.jl's convention, NaN-safe)
_levels(data, n::Integer) = Contour.contourlevels(_colorrange(data, nothing), n)
_levels(_, levels::AbstractVector{<:Real}) = levels

# one `(; level, x, y)` per level: its curves joined into single x/y vectors, separated by NaN
# (a gap in ImPlot's line strip); closed loops repeat their first point. NaN pixels interrupt curves.
function _contour_lines(xs::AbstractInterval, ys::AbstractInterval, data::AbstractMatrix{<:Real}, levels)
    centers(iv, n) = range(leftendpoint(iv), rightendpoint(iv); length=n)
    cs = Contour.contours(centers(xs, size(data, 1)), centers(ys, size(data, 2)), data, _levels(data, levels);
                          VT=NTuple{2,Float64})                    # ImPlot's native double
    map(Contour.levels(cs)) do cl
        pts = [p for c in Contour.lines(cl) for p in [Contour.vertices(c); [(NaN, NaN)]]]
        (; level=Contour.level(cl), x=first.(pts), y=last.(pts))
    end
end

_imvec4(c::Colorant) = (c = convert(RGBA{Float32}, c); ig.ImVec4(red(c), green(c), blue(c), alpha(c)))

# per-level line colors: ImPlot's auto item color, one fixed color, or a colormap spread evenly by level index
_level_colors(::Nothing, ::Nothing, n) = fill(ImPlot.IMPLOT_AUTO_COL, n)
_level_colors(color::Colorant, ::Nothing, n) = fill(_imvec4(color), n)
_level_colors(::Nothing, colormap, n) = _imvec4.(get(resolve_scheme(colormap), n == 1 ? [0.5] : range(0, 1; length=n)))

const _CONTOUR_CACHE = _ItemCache{Vector{@NamedTuple{x::Vector{Float64}, y::Vector{Float64}, color::ig.ImVec4}}}(Returns(nothing))

"""
    contour!(label, data; levels, kwargs...)
    contour!(label, xs::Interval, ys::Interval, data; levels, kwargs...)

Draw contour lines (iso-lines) of a real matrix into the current `ImPlot` plot (call between
`ImPlot.BeginPlot`/`EndPlot`). Lines are traced with Contour.jl (marching squares) only when inputs
change; each frame just draws one `ImPlot.PlotLine` per level. All levels share `label`, so they form a
single legend entry (toggling it hides all levels).

Placement matches [`image!`](@ref): the first index → x, the second → y, `data[1,1]` at the bottom-left;
by default `data[i,j]` sits at `(i,j)`, and `xs`/`ys` (`IntervalSets` intervals) give the first/last
pixel *centers*. So `contour!` over an `image!` with the same extent lines up exactly.
`NaN` pixels interrupt the curves passing through them.

# Keyword arguments
- `levels` (required): an `Integer` `n` ⇒ `n` levels evenly spaced strictly inside the finite data
  range (excluding its min and max); or a vector of level values (e.g. `exp10.(-3:0.5:0)` for log spacing).
- `color = nothing`: one `Colorant` for all levels.
- `colormap = nothing`: as in [`image!`](@ref) — a Symbol/name, a `ColorScheme`, or a `Vector{<:Colorant}`;
  spread evenly over the levels *by index* (first level ⇒ colormap start, last ⇒ end; a single level ⇒ middle).
  Give at most one of `color`/`colormap`; with neither, the lines take ImPlot's next auto item color.
- `line_weight = 1`: line width in pixels.
- `flags = ImPlotItemFlags_None`: `ImPlotItemFlags`/`ImPlotLineFlags` bitmask (e.g. `ImPlotItemFlags_NoFit`).
- `refresh = false`: force recomputation even if the array object is unchanged (see contract).

# Contract
- **Stable identities:** lines are recomputed only when `data`, `levels`, `color`, `colormap` or the
  extent change, compared by `===`. Pass `levels` as a range or a kept vector — a vector literal
  rebuilt every frame retraces every frame. If you mutate `data` in place, pass `refresh = true`.
- **Single-threaded:** call from the ImGui render thread (the cache is plain global state).

The cache drops a call-site's lines after it has been idle for `cache_grace_seconds[]` (shared with `image!`).
"""
function contour!(label::AbstractString, xs::AbstractInterval, ys::AbstractInterval, data::AbstractMatrix{<:Real};
                  levels, color=nothing, colormap=nothing, line_weight::Real=1,
                  flags=ImPlot.ImPlotItemFlags_None, refresh::Bool=false)
    inputs = (data, levels, color, colormap, (xs, ys))
    lines = _cached!(_CONTOUR_CACHE, label, inputs, refresh) do _
        ls = _contour_lines(xs, ys, data, levels)
        map((l, c) -> (; l.x, l.y, color=c), ls, _level_colors(color, colormap, length(ls)))
    end
    foreach(lines) do l
        ImPlot.PlotLine(label, l.x, l.y; spec=ImPlot.ImPlotSpec(; LineColor=l.color, LineWeight=line_weight, Flags=flags))
    end
end
contour!(label, data::AbstractMatrix{<:Real}; kw...) = contour!(label, 1..size(data,1), 1..size(data,2), data; kw...)
