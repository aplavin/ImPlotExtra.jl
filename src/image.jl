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

const LUT_BITS = 16                       # 65536-entry value→colour table (256 KB); top bits of the Float32 key
const LUT_N = 1 << LUT_BITS

# order-preserving Float32↔UInt32 key (radix transform); top LUT_BITS ⇒ log-spaced bin (one table fits lin & log)
@inline _floatkey(x::Float32) = (ui = reinterpret(UInt32, x); ui ⊻ ifelse(ui & 0x80000000 == 0x00000000, 0x80000000, 0xffffffff))
@inline _unkey(k::UInt32)     = reinterpret(Float32, k ⊻ ifelse(k & 0x80000000 == 0x00000000, 0xffffffff, 0x80000000))
@inline _binindex(x::Float32) = Int(_floatkey(x) >> (32 - LUT_BITS))

# to plain Real: `*iu` divides out the unit (×1 for reals); `clamp` vs plain bounds strips the Unitful ratio
@inline _strip(v, iu, lo, hi) = clamp(v * iu, lo, hi)

# value→colour table; bin-centre → clamp→stretch→normalise→colormap; non-finite bin ⇒ nan_color
function _stretch_lut(scheme, cfg)
    (; lo, hi, colorscale, slo, shi, nanc) = cfg
    shift = 32 - LUT_BITS
    map(0:LUT_N-1) do i
        v = _unkey((UInt32(i) << shift) | ((UInt32(1) << shift) >> 1))   # bin-centre value
        isfinite(v) || return nanc
        t = (colorscale(clamp(v, lo, hi)) - slo) / (shi - slo)
        isfinite(t) ? convert(RGBA{N0f8}, get(scheme, clamp(t, 0.0, 1.0))) : nanc
    end
end

function _scalar_rgba!(buf::AbstractMatrix{RGBA{N0f8}}, data, scheme; colorrange, colorscale, nan_color, lut::Bool=true)
    Base.require_one_based_indexing(data)            # clearer error than map!'s axis-mismatch for offset arrays
    size(buf) == size(data) || error("buffer size $(size(buf)) ≠ $(size(data))")
    lo, hi = colorrange
    lo <= hi || error("colorrange lo ($lo) must be ≤ hi ($hi)")     # fail loud, not silent clamp-to-top
    u = oneunit(lo); iu = inv(u); lo, hi = lo / u, hi / u           # dimensionless colorrange (÷unit; no-op for reals)
    slo, shi = colorscale(lo), colorscale(hi)
    (isfinite(slo) && isfinite(shi)) || error("colorscale(colorrange) not finite: ($slo,$shi); e.g. log requires colorrange > 0")
    nanc = convert(RGBA{N0f8}, nan_color)
    slo == shi && return (c = convert(RGBA{N0f8}, get(scheme, 0.5)); map!(v -> isfinite(v) ? c : nanc, buf, data))  # degenerate range ⇒ midpoint
    cfg = (; lo, hi, colorscale, slo, shi, nanc)
    lut ? _recolor_lut!(buf, data, iu, scheme, cfg) : _recolor_perpixel!(buf, data, iu, scheme, cfg)
end

# lut=true: table indexed by the value's Float32 bits — ≤3/255 vs exact, ~40× faster
function _recolor_lut!(buf, data, iu, scheme, cfg)
    (; lo, hi, nanc) = cfg
    tbl = _stretch_lut(scheme, cfg)
    map!(v -> isfinite(v) ? (@inbounds tbl[_binindex(Float32(_strip(v, iu, lo, hi))) + 1]) : nanc, buf, data)
end

# lut=false: exact stretch + colormap per pixel
function _recolor_perpixel!(buf, data, iu, scheme, cfg)
    (; lo, hi, colorscale, slo, shi, nanc) = cfg
    map!(buf, data) do v
        isfinite(v) || return nanc
        t = (colorscale(_strip(v, iu, lo, hi)) - slo) / (shi - slo)
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

_needs_update(::Nothing, _, _) = true
# tuple === is element-wise egal: identity for the `data` array, value for the isbits rest
# (colorrange/nan_color/interpolate/extent intervals) and singleton funcs/Symbols. Verified.
_needs_update(old::Tuple, new::Tuple, refresh::Bool) = refresh || old !== new

mutable struct _ImageTexture
    tex::Union{Nothing,ig.lib.ImTextureRef}
    w::Int
    h::Int
end
_ImageTexture() = _ImageTexture(nothing, 0, 0)

function _ensure_texture!(p::_ImageTexture, w::Int, h::Int)
    if p.tex === nothing || p.w != w || p.h != h
        p.tex === nothing || ig.destroy_image_texture(p.tex)   # destroy BEFORE reassigning ⇒ no leak
        p.tex = ig.create_image_texture(w, h)
        p.w, p.h = w, h
    end
    p
end

_upload!(p::_ImageTexture, buf::AbstractMatrix{RGBA{N0f8}}) = ig.update_image_texture(p.tex, buf, p.w, p.h)

# ImGui 1.92's GL backend binds a LINEAR sampler that overrides any per-texture filter, so nearest-
# neighbor must be requested per draw via the backend's SetSamplerNearest callback (restored to Linear
# afterwards). `interpolate=true` just keeps the default Linear sampler.
function _draw(p::_ImageTexture, label::AbstractString, bmin, bmax, interpolate::Bool, flags)
    dl = ImPlot.GetPlotDrawList()
    interpolate || ig.AddCallback(dl, unsafe_load(ig.GetPlatformIO().DrawCallback_SetSamplerNearest), C_NULL, 0)
    ImPlot.PlotImage(label, p.tex,
        ImPlot.ImPlotPoint(bmin[1], bmin[2]), ImPlot.ImPlotPoint(bmax[1], bmax[2]),
        ig.ImVec2(0, 1), ig.ImVec2(1, 0),     # uv0,uv1 ⇒ full-Makie orientation (data[1,1] bottom-left)
        ig.ImVec4(1, 1, 1, 1),                # tint
        ImPlot.ImPlotSpec(; Flags = flags))
    interpolate || ig.AddCallback(dl, unsafe_load(ig.GetPlatformIO().DrawCallback_SetSamplerLinear), C_NULL, 0)
end

Base.close(p::_ImageTexture) = (p.tex !== nothing && (ig.destroy_image_texture(p.tex); p.tex = nothing); nothing)

struct _Entry
    tex::_ImageTexture
    inputs::Tuple
    last_used::Float64
end

const _CACHE = Dict{Tuple{Ptr{ig.lib.ImGuiContext},ig.lib.ImGuiID},_Entry}()
const cache_grace_seconds = Ref(30.0)                       # set to Inf to disable eviction
const _last_sweep_frame = Dict{Ptr{ig.lib.ImGuiContext},Int}()

function _sweep!(ctx, now)
    isfinite(cache_grace_seconds[]) || return
    for k in collect(keys(_CACHE))                          # collect ⇒ safe to delete! during loop
        e = _CACHE[k]
        if k[1] == ctx && (now - e.last_used) > cache_grace_seconds[]
            close(e.tex); delete!(_CACHE, k)
        end
    end
end

# render-exit handler: free this context's textures (GL still alive) + drop its entries, so a reused
# context pointer can't hit a stale entry and draw a dead/reassigned texture id (font atlas)
function _release_textures!()
    ctx = ig.GetCurrentContext()
    filter!(_CACHE) do (k, e)
        k[1] != ctx && return true
        close(e.tex); false
    end
    delete!(_last_sweep_frame, ctx)
    nothing
end

# Shared orchestration; `fill!` runs ONLY on update (so resolve_scheme/_colorrange/recolor are skipped when cached).
function _image!(fill!::F, label, x, y, inputs, n1, n2, interpolate, flags, refresh) where {F}
    ctx = ig.GetCurrentContext()
    now = ig.GetTime()
    fc = Int(ig.GetFrameCount())
    if get(_last_sweep_frame, ctx, -1) != fc
        _last_sweep_frame[ctx] = fc
        _sweep!(ctx, now)
    end
    key = (ctx, ig.GetID(label))
    old = get(_CACHE, key, nothing)
    p = old === nothing ? _ImageTexture() : old.tex
    if _needs_update(old === nothing ? nothing : old.inputs, inputs, refresh)
        _ensure_texture!(p, n1, n2)
        buf = Matrix{RGBA{N0f8}}(undef, n1, n2)
        fill!(buf)
        _upload!(p, buf)
    end
    _CACHE[key] = _Entry(p, inputs, now)                    # re-stamp last_used every frame ⇒ kept alive
    xb = _centers_to_bounds(x, n1); yb = _centers_to_bounds(y, n2)   # (xmin,xmax),(ymin,ymax)
    _draw(p, label, (xb[1], yb[1]), (xb[2], yb[2]), interpolate, flags)   # corner points (xmin,ymin),(xmax,ymax)
    nothing
end

"""
    image!(label, data; kwargs...)
    image!(label, xs::Interval, ys::Interval, data; kwargs...)

Draw a matrix/image into the current `ImPlot` plot (call between `ImPlot.BeginPlot`/`EndPlot`),
as a performant replacement for `ImPlot.PlotHeatmap`: `data` is uploaded once as a GPU texture and
drawn as a single quad, so pan/zoom is free and the (CPU) colormap is recomputed only when inputs change.

`data::AbstractMatrix{<:Number}` is colormapped; `data::AbstractMatrix{<:Colorant}` is shown as-is.
Indexing follows Makie's `image`: the first index → x (rightward), the second → y (upward), so
`data[1,1]` is at the bottom-left. By default `data[i,j]` is centered at plot coordinate `(i,j)`
(extent `1..size(data,1)` × `1..size(data,2)`); pass `xs`/`ys` as `IntervalSets` intervals giving the
first/last pixel *centers* (uniformly spaced, so the drawn rectangle extends ±½ pixel beyond).

# Keyword arguments (scalar path)
- `colormap = :viridis`: a `ColorSchemes` `Symbol`/name, a `ColorScheme`, or a `Vector{<:Colorant}`.
- `colorrange = nothing`: `(lo, hi)` in data units; `nothing` ⇒ finite extrema. `lo == hi` ⇒ midpoint color.
- `colorscale = identity`: callable applied to data and to `colorrange` (e.g. `log10`, `sqrt`); must be
  finite on `colorrange` (fails loud otherwise).
- `interpolate = false`: `false` ⇒ nearest (crisp pixels), `true` ⇒ bilinear.
- `flags = ImPlotItemFlags_None`: `ImPlotItemFlags` bitmask (e.g. `ImPlotItemFlags_NoFit` ⇒ excluded from auto-fit).
- `nan_color = RGBA(0,0,0,0)`: color for `NaN`/`Inf` (incl. non-finite after `colorscale`).
- `refresh = false`: force re-upload even if the array object is unchanged (see preconditions).
- `lut = true`: colormap via a value→colour table (~40× faster, ≤3/255 vs exact); `false` ⇒ exact per pixel.

The Colorant path takes only `interpolate`, `flags` and `refresh`.

# Preconditions / contract
- **Backend:** uses CImGui's GLFW/OpenGL texture helpers; the host must `import GLFW` and
  `CImGui.set_backend(:GlfwOpenGL3)` before drawing (ImPlotExtra does not depend on GLFW). Otherwise
  it fails loud via CImGui's backend check.
- **Stable identities:** the texture is re-uploaded only when an input changes. Pass `colormap`/
  `colorscale` as stable objects (a `Symbol`, a named function, or a kept `ColorScheme`); a freshly
  built `ColorScheme` or an inline anonymous `colorscale` created every frame re-uploads every frame.
- **In-place mutation:** re-upload triggers on `data` *identity* (`===`). If you mutate the same array
  buffer in place, pass `refresh = true`.
- **Single-threaded:** call from the ImGui render thread (the cache is plain global state).

The cache evicts a call-site's texture after it has been idle for `cache_grace_seconds[]` (default 30 s;
set to `Inf` to disable).
"""
function image!(label::AbstractString, x::AbstractInterval, y::AbstractInterval, data::AbstractMatrix{<:Number};
                colormap=:viridis, colorrange=nothing, colorscale=identity, interpolate::Bool=false,
                flags=ImPlot.ImPlotItemFlags_None, nan_color=RGBA{N0f8}(0,0,0,0), refresh::Bool=false, lut::Bool=true)
    inputs = (data, colorrange, colormap, colorscale, nan_color, interpolate, (x, y), lut)
    _image!(label, x, y, inputs, size(data,1), size(data,2), interpolate, flags, refresh) do buf
        _scalar_rgba!(buf, data, resolve_scheme(colormap);
                      colorrange=_colorrange(data, colorrange), colorscale, nan_color, lut)
    end
end
image!(label, data::AbstractMatrix{<:Number}; kw...) = image!(label, 1..size(data,1), 1..size(data,2), data; kw...)

function image!(label::AbstractString, x::AbstractInterval, y::AbstractInterval, data::AbstractMatrix{<:Colorant};
                interpolate::Bool=false, flags=ImPlot.ImPlotItemFlags_None, refresh::Bool=false)
    inputs = (data, nothing, nothing, identity, nothing, interpolate, (x, y))
    _image!(label, x, y, inputs, size(data,1), size(data,2), interpolate, flags, refresh) do buf
        _colorant_rgba!(buf, data)
    end
end
image!(label, data::AbstractMatrix{<:Colorant}; kw...) = image!(label, 1..size(data,1), 1..size(data,2), data; kw...)
