# colorbar!() — a vertical colour scale that reflects an `image!`'s `colormap` + `colorscale`, with
# tick labels in DATA units placed at their (nonlinear) colour-fraction positions.
#
# ImPlot's own `ColormapScale` widget ticks a strictly LINEAR axis, so under a nonlinear `colorscale`
# (log/sqrt/asinh) its labels are wrong. We reproduce ColormapScale's drawing exactly — calling
# ImPlot's native `RenderColorBar` for the (evenly-drawn) gradient and replicating its frame/border/
# tick styling from ImPlot's style metrics — and change ONLY the tick placement: value `v` sits at
# colour-fraction `t(v) = (S(v) − S(lo)) / (S(hi) − S(lo))`, labelled with its real data value.
# This is exactly how `image!` maps a value to a colour, so bar and image can never disagree.

using Printf: @sprintf
using Accessors: @o
import InverseFunctions: inverse

# ---- colour scales & their tick generators ----------------------------------
# A "scale" is any callable value→position transform, usable directly as `image!`'s `colorscale`.
# `scale_ticks(scale, lo, hi)` returns nice DATA-unit tick values for it (see `BaseMulTicks`); add a
# method to support a custom scale. `identity`, `log10`, `sqrt` and `SymLog` are provided.

"""
    SymLog(threshold)

Signed-logarithmic scale `v -> asinh(v / threshold)`: linear within ±`threshold`, logarithmic beyond,
finite and monotone through 0 (unlike `log10`). Usable both as `image!`'s `colorscale` and as a
`colorbar!` scale. Value-stable under `===` (isbits with one field), so rebuilding one per frame never
forces a texture re-upload. Same asinh family as ImPlot's built-in `ImPlotScale_SymLog` (`2·asinh(v/2)`)
and MakieExtra's `AsinhScale`, differing only in the (here tunable) threshold.

`InverseFunctions.inverse(::SymLog)` is auto-derived (`threshold·sinh`) from the same `asinh ∘ (/threshold)`
composition that defines the forward map, so `colorbar!`'s (invertible) interactive zoom/pan works with it.
"""
_symlog_f(threshold) = @o asinh(_ / threshold)   # asinh ∘ Fix2(/, threshold): isbits, value-stable, invertible
struct SymLog
    threshold::Float64
end
(s::SymLog)(v) = _symlog_f(s.threshold)(v)
inverse(s::SymLog) = inverse(_symlog_f(s.threshold))   # auto-derived by InverseFunctions: Fix2(*, threshold) ∘ sinh

# ---- BaseMulTicks: base^exponent × {subs} tick locator ----------------------
# Ported from MakieExtra's `BaseMulTicks` (Makie-free here). `tickvalues(t, lo, hi)` places
# `mul·base^pow` ticks over a same-sign range; with `subs=nothing` it densifies the subdivision set
# [1]→[1,3]→[1,2,5]→[1,2,3,5]→1:9 until ≥ `k_min` ticks, else falls back to linear. The `SymLog`
# method splits the range at the linear threshold: signed decades outside, a single 0 through the
# linear core, with a coarser retry then a linear fallback when a side is too narrow for decades.

"""
    BaseMulTicks(; subs=nothing, base=10.0, k_min=7)

Tick locator placing `mul · base^pow` values (`mul ∈ subs`). `subs=nothing` auto-densifies the
subdivision set until at least `k_min` ticks fall in range. Ported from MakieExtra's `BaseMulTicks`.
Feed it to `tickvalues(t, lo, hi)` (same-sign range) or `tickvalues(t, ::SymLog, lo, hi)` (signed).
"""
Base.@kwdef struct BaseMulTicks
    subs::Union{Nothing,AbstractVector{<:Real}} = nothing
    base::Float64 = 10.0
    k_min::Int = 7
end
BaseMulTicks(subs; kwargs...) = BaseMulTicks(; subs, kwargs...)

const _SUB_LADDER = ([1], [1, 3], [1, 2, 5], [1, 2, 3, 5], collect(1:9))

# linear 1/2/5·10^e ticks over [lo,hi] — used for `identity`/`sqrt` scales and as the last-resort
# fallback (stands in for MakieExtra's `WilkinsonTicks`).
function _linear_ticks(lo, hi; target::Integer=5)
    lo, hi = float(lo), float(hi)
    (isfinite(lo) && isfinite(hi) && hi > lo) || return [lo]
    raw = (hi - lo) / target
    mag = 10.0^floor(log10(raw))
    r = raw / mag
    step = (r < 1.5 ? 1.0 : r < 3.0 ? 2.0 : r < 7.0 ? 5.0 : 10.0) * mag
    collect(ceil(lo / step) * step : step : hi + step / 2)
end

# `mul·base^pow` ticks over a same-sign range (`vmin < vmax`). A magnitude-scaled slack keeps an
# endpoint decade (e.g. hi == 1e-2, yet 1.0·10.0^-2 rounds just above it) from being dropped — our
# `colorrange` limits are exact, unlike Makie's padded axis limits.
function tickvalues(t::BaseMulTicks, vmin::Real, vmax::Real)
    vmin < vmax || return Float64[]
    (vmin < 0 && vmax <= 0) && return .-tickvalues(t, -vmax, -vmin)
    (vmin >= 0 && vmax >= 0) || error("tickvalues: range straddles 0; use the SymLog method")
    if t.subs !== nothing
        pmin = floor(Int, log(t.base, vmin) - 0.1)
        pmax = ceil(Int, log(t.base, vmax) + 0.1)
        vals = Float64[mul * t.base^pow for pow in pmin:pmax for mul in t.subs]
        tol = 1e-9 * max(abs(vmin), abs(vmax))
        filter!(v -> vmin - tol <= v <= vmax + tol, vals)
        round.(vals; sigdigits=4)
    else
        for sb in _SUB_LADDER
            ts = tickvalues(BaseMulTicks(sb; base=t.base, k_min=t.k_min), vmin, vmax)
            length(ts) >= t.k_min && return ts
        end
        _linear_ticks(vmin, vmax)
    end
end

# signed decades outside ±threshold, a single 0 through the linear core (`vmin < 0 < vmax`, or one-sided).
function tickvalues(t::BaseMulTicks, s::SymLog, vmin::Real, vmax::Real; prev::Bool=false)
    if t.subs !== nothing
        lt = 2 * s.threshold            # SymLog(a)=asinh(v/a) ≡ MakieExtra AsinhScale(2a); linthresh = 2a
        mt = min(lt / 1.1, max(abs(vmax), abs(vmin)))     # 1.1 = MakieExtra's asinh n_linticks (no linscale)
        prev && (mt = t.base^(floor(log(t.base, mt) - 0.01) - 0.01))
        mt = max(vmin, mt)
        ticks = Float64[reverse(tickvalues(t, vmin, -mt)); 0.0; tickvalues(t, mt, vmax)]
        filter!(v -> vmin <= v <= vmax, ticks)
        length(ticks) >= 2 ? ticks :
            !prev ? tickvalues(t, s, vmin, vmax; prev=true) : _linear_ticks(vmin, vmax)
    else
        local ts = Float64[]
        for sb in _SUB_LADDER
            ts = tickvalues(BaseMulTicks(sb; base=t.base, k_min=t.k_min), s, vmin, vmax; prev)
            length(ts) >= t.k_min && return ts
        end
        ts
    end
end

# `scale_ticks(scale, lo, hi)` — DATA-unit ticks for a `colorscale`, dispatched to the locator that
# suits its shape. Define a method to support a custom scale.
function scale_ticks end
scale_ticks(s::SymLog, lo, hi) = tickvalues(BaseMulTicks(), s, float(lo), float(hi))
scale_ticks(::typeof(log10), lo, hi) = tickvalues(BaseMulTicks(), max(float(lo), float(hi) * 1e-6), float(hi))
scale_ticks(::typeof(identity), lo, hi) = _linear_ticks(lo, hi)   # linear scale ⇒ round linear ticks
scale_ticks(::typeof(sqrt), lo, hi) = _linear_ticks(lo, hi)       # mild nonlinearity ⇒ linear ticks read best
scale_ticks(::Any, lo, hi) = _linear_ticks(lo, hi)                # sensible default for an unknown scale

# ---- drawing ----------------------------------------------------------------

# ImPlot's own gradient renderer (unwrapped): draws `colors` evenly into `bounds`, interpolating
# adjacent keys (continuous). `ImRect` is a {ImVec2,ImVec2} isbits struct passed by value.
function _render_color_bar(colors, dl, x0, y0, x1, y1; reversed=true)
    bounds = ig.lib.ImRect(ig.ImVec2(x0, y0), ig.ImVec2(x1, y1))
    ccall((:ImPlot_RenderColorBar, ig.lib.libcimgui), Cvoid,
          (Ptr{UInt32}, Cint, Ptr{Cvoid}, ig.lib.ImRect, Bool, Bool, Bool),
          colors, length(colors), dl, bounds, true, reversed, true)
end

_default_label(v) = @sprintf("%g", v)

# ---- interaction (scroll = zoom, left-drag = pan) ---------------------------
# All operate on the window `[S(lo), S(hi)]` in COLORSCALE space, so a scroll notch zooms the same
# visible fraction everywhere on the (nonlinearly-spaced) bar; `inverse(scale)` maps endpoints back
# to data units. `log10` stays > 0 for free (its inverse `exp10` is always positive).

# zoom about the value under the cursor: `f` ∈ [0,1] from the lo-end to the hi-end, factor `z` (<1 zooms in)
function _cbar_zoom_cursor(scale, lo, hi, f, z)
    Si = inverse(scale)
    slo, shi = float(scale(lo)), float(scale(hi))
    sp = slo + f * (shi - slo)                       # transformed value under the cursor (held fixed)
    w = (shi - slo) * z
    (Si(sp - f * w), Si(sp + (1 - f) * w))
end

# shift the window by `ds` in transformed units (grab-follow: the grabbed value tracks the cursor)
function _cbar_pan(scale, lo, hi, ds)
    Si = inverse(scale)
    (Si(float(scale(lo)) + ds), Si(float(scale(hi)) + ds))
end

# symmetric zoom about a fixed `center`: scale the upper transformed half-width by `z`, mirror to lo
function _cbar_zoom_sym(scale, center, hi, z)
    Si = inverse(scale)
    sc, shi = float(scale(center)), float(scale(hi))
    h = Si(sc + (shi - sc) * z) - center
    (center - h, center + h)
end

# read this frame's scroll/drag over the reserved item and mutate the `colorrange` Ref in place. The
# mutation is picked up next frame by both this bar and the `image!` sharing the Ref (one-frame lag,
# imperceptible). `SetItemKeyOwner(MouseWheelY)` (called at the item) keeps the window from scrolling.
function _cbar_interact!(ref, scale, lo, hi, gy0, gy1, symmetric, anchor, zoom_speed)
    gh = gy1 - gy0
    nlo, nhi = lo, hi
    if ig.IsItemHovered()
        wheel = Float64(unsafe_load(ig.GetIO()).MouseWheel)
        if wheel != 0
            z = exp(-zoom_speed * wheel)                 # wheel up (>0) ⇒ z<1 ⇒ zoom in
            # pivot fraction: symmetric center wins; else fixed anchor value; else the value under the cursor
            nlo, nhi = if symmetric !== nothing
                _cbar_zoom_sym(scale, float(symmetric), hi, z)
            else
                f = anchor === nothing ? clamp((gy1 - ig.GetMousePos().y) / gh, 0.0, 1.0) :
                    (float(scale(anchor)) - float(scale(lo))) / (float(scale(hi)) - float(scale(lo)))
                _cbar_zoom_cursor(scale, lo, hi, f, z)
            end
        end
    end
    if symmetric === nothing && ig.IsItemActive()            # left-drag pan (disabled in symmetric mode)
        d = ig.GetMouseDragDelta(0); ig.ResetMouseDragDelta(0)
        if d.y != 0
            ds = (Float64(d.y) / gh) * (float(scale(nhi)) - float(scale(nlo)))
            nlo, nhi = _cbar_pan(scale, nlo, nhi, ds)
        end
    end
    ref[] = (nlo, nhi)
    nothing
end

"""
    colorbar!(label, colormap, colorrange, colorscale, height; bar_w=20, formatter=v->@sprintf("%g", v),
              symmetric=nothing, anchor=nothing, zoom_speed=0.15)

Draw a vertical colorbar into the current window at the cursor — call it right after `EndPlot` and
`CImGui.SameLine()` — matching an `image!` drawn with the same `colormap`, `colorrange` and
`colorscale`. Tick labels are in data units, placed at their colour-fraction positions, so they stay
correct under a nonlinear `colorscale` (`log10`, `sqrt`, [`SymLog`](@ref), …), which ImPlot's own
`ColormapScale` cannot do.

- `label`: an ImGui id (as in [`image!`](@ref)); unique per bar, may be hidden (`"##bar"`). Used for
  the interactive hit region.
- `colormap`: as in [`image!`](@ref) — a Symbol/name, a `ColorScheme`, or a `Vector{<:Colorant}`.
- `colorrange`: `(lo, hi)` in data units, as a plain tuple (**static**) or a `Ref`/`Base.RefValue`
  holding `(lo, hi)` (**interactive**, see below).
- `colorscale`: the value→position callable passed to `image!` (default-safe with `identity`).
- `height`: bar height in pixels — match the plot's height.
- `bar_w`: gradient width in pixels.
- `formatter`: `value -> String` for tick labels.

# Interaction (Ref `colorrange` only)
When `colorrange` is a `Ref`, scrolling over the bar zooms and left-dragging pans, mutating the `Ref`
in place — pass the SAME `Ref[]` to `image!`'s `colorrange` so the image tracks the bar. Zoom and pan
operate on the window `[colorscale(lo), colorscale(hi)]` and map back with `InverseFunctions.inverse`,
so a notch zooms uniformly on the (nonlinearly-spaced) bar (`identity`, `log10`, [`SymLog`](@ref), …).

`symmetric` and `anchor` set the scroll pivot (both default `nothing`):
- both `nothing`: zoom about the value under the cursor; left-drag pans.
- `anchor = a` (a number): zoom about the fixed value `a`; left-drag still pans.
- `symmetric = c` (a number): constrain the range symmetric about the fixed center `c`
  (`lo = c-h, hi = c+h`); zoom about `c`, panning disabled. Takes precedence over `anchor`.

`zoom_speed` is the zoom fraction per wheel notch (`z = exp(-zoom_speed·wheel)`). A plain-tuple
`colorrange` ignores `symmetric`/`anchor`/`zoom_speed` and just draws (fully static).

Tick values come from `scale_ticks(colorscale, lo, hi)`; define a `scale_ticks` method to support a
custom scale. A degenerate range (`colorscale(lo) == colorscale(hi)`) draws a flat bar with no ticks.
"""
function colorbar!(label, colormap, colorrange, colorscale, height::Real; bar_w::Real=20,
                   formatter=_default_label, symmetric=nothing, anchor=nothing, zoom_speed::Real=0.15)
    interactive = colorrange isa Ref
    lo, hi = interactive ? (float(colorrange[][1]), float(colorrange[][2])) : (float(colorrange[1]), float(colorrange[2]))
    cs = resolve_scheme(colormap)
    slo, shi = float(colorscale(lo)), float(colorscale(hi))
    degen = !(isfinite(slo) && isfinite(shi)) || slo == shi
    midc = reinterpret(UInt32, convert(RGBA{N0f8}, get(cs, 0.5)))
    colors = degen ? [midc, midc] : [reinterpret(UInt32, convert(RGBA{N0f8}, get(cs, t))) for t in range(0, 1, 256)]
    ticks = degen ? Float64[] : scale_ticks(colorscale, lo, hi)
    labels = [formatter(v) for v in ticks]

    sty = ImPlot.GetStyle()
    pp = unsafe_load(sty.PlotPadding); lp = unsafe_load(sty.LabelPadding)
    mtl = unsafe_load(sty.MajorTickLen); mts = unsafe_load(sty.MajorTickSize)
    bw, h = Float32(bar_w), Float32(height)
    maxlabw = isempty(labels) ? 0f0 : maximum(l -> ig.CalcTextSize(l).x, labels)
    frame_w = bw + 2 * pp.x + lp.x + maxlabw + mtl.y      # ColormapScale's frame width

    dl = ig.GetWindowDrawList()
    p = ig.GetCursorScreenPos()
    if interactive                                       # reserve the rect + an id, own the wheel (no window scroll)
        ig.InvisibleButton(label, ig.ImVec2(frame_w, h))
        ig.SetItemKeyOwner(ig.lib.ImGuiKey_MouseWheelY)
    end
    fx0, fy0 = p.x, p.y
    fx1, fy1 = fx0 + frame_w, fy0 + h
    ig.AddRectFilled(dl, ig.ImVec2(fx0, fy0), ig.ImVec2(fx1, fy1), ig.GetColorU32(ig.ImGuiCol_FrameBg))
    # gradient bar, inset by PlotPadding (native RenderColorBar)
    gx0, gy0 = fx0 + pp.x, fy0 + pp.y
    gx1, gy1 = gx0 + bw, fy1 - pp.y
    _render_color_bar(colors, dl, gx0, gy0, gx1, gy1)
    ig.AddRect(dl, ig.ImVec2(gx0, gy0), ig.ImVec2(gx1, gy1), ig.GetColorU32(ig.ImGuiCol_Border))
    # ticks at colour-fraction positions: line contrast-coloured inside the bar, label outside
    gh = gy1 - gy0
    txt = ig.GetColorU32(ig.ImGuiCol_Text)
    fs = ig.GetFontSize()
    for (v, lab) in zip(ticks, labels)
        t = (float(colorscale(v)) - slo) / (shi - slo)
        (0 <= t <= 1) || continue
        y = gy1 - t * gh
        c = get(cs, t)
        lum = 0.299 * red(c) + 0.587 * green(c) + 0.114 * blue(c)      # Rec.601 luma
        tickcol = lum > 0.5 ? 0xff000000 : 0xffffffff
        ig.AddLine(dl, ig.ImVec2(gx1 - 1, y), ig.ImVec2(gx1 - mtl.y, y), tickcol, mts.y)
        ig.AddText(dl, ig.ImVec2(gx1 + lp.x, y - fs / 2), txt, lab)
    end
    interactive ? _cbar_interact!(colorrange, colorscale, lo, hi, gy0, gy1, symmetric, anchor, float(zoom_speed)) :
                  ig.Dummy(ig.ImVec2(frame_w, h))
    nothing
end
