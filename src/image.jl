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

_needs_update(::Nothing, _, _) = true
# tuple === is element-wise egal: identity for the `data` array, value for the isbits rest
# (colorrange/nan_color/interpolate/extent intervals) and singleton funcs/Symbols. Verified.
_needs_update(old::Tuple, new::Tuple, refresh::Bool) = refresh || old !== new

mutable struct _ImageTexture
    tex::Union{Nothing,ig.lib.ImTextureRef}
    w::Int
    h::Int
    interpolate::Bool
end
_ImageTexture() = _ImageTexture(nothing, 0, 0, false)

function _ensure_texture!(p::_ImageTexture, w::Int, h::Int, interpolate::Bool)
    if p.tex === nothing || p.w != w || p.h != h || p.interpolate != interpolate
        p.tex === nothing || ig.destroy_image_texture(p.tex)   # destroy BEFORE reassigning ⇒ no leak
        p.tex = ig.create_image_texture(w, h)
        p.w, p.h, p.interpolate = w, h, interpolate
        filt = interpolate ? GL.GL_LINEAR : GL.GL_NEAREST       # backend presets LINEAR; override
        GL.glBindTexture(GL.GL_TEXTURE_2D, GL.GLuint(p.tex._TexID))
        GL.glTexParameteri(GL.GL_TEXTURE_2D, GL.GL_TEXTURE_MIN_FILTER, filt)
        GL.glTexParameteri(GL.GL_TEXTURE_2D, GL.GL_TEXTURE_MAG_FILTER, filt)
    end
    p
end

_upload!(p::_ImageTexture, buf::AbstractMatrix{RGBA{N0f8}}) = ig.update_image_texture(p.tex, buf, p.w, p.h)

function _draw(p::_ImageTexture, label::AbstractString, bmin, bmax)
    ImPlot.PlotImage(label, p.tex,
        ImPlot.ImPlotPoint(bmin[1], bmin[2]), ImPlot.ImPlotPoint(bmax[1], bmax[2]),
        ig.ImVec2(0, 1), ig.ImVec2(1, 0))     # uv0,uv1 ⇒ full-Makie orientation (data[1,1] bottom-left)
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

# Shared orchestration; `fill!` runs ONLY on update (so resolve_scheme/_colorrange/recolor are skipped when cached).
function _image!(fill!::F, label, x, y, inputs, n1, n2, interpolate, refresh) where {F}
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
        _ensure_texture!(p, n1, n2, interpolate)
        buf = Matrix{RGBA{N0f8}}(undef, n1, n2)
        fill!(buf)
        _upload!(p, buf)
    end
    _CACHE[key] = _Entry(p, inputs, now)                    # re-stamp last_used every frame ⇒ kept alive
    _draw(p, label, _centers_to_bounds(x, n1), _centers_to_bounds(y, n2))
    nothing
end

function image!(label::AbstractString, x::AbstractInterval, y::AbstractInterval, data::AbstractMatrix{<:Number};
                colormap=:viridis, colorrange=nothing, colorscale=identity, interpolate::Bool=false,
                nan_color=RGBA{N0f8}(0,0,0,0), refresh::Bool=false)
    inputs = (data, colorrange, colormap, colorscale, nan_color, interpolate, (x, y))
    _image!(label, x, y, inputs, size(data,1), size(data,2), interpolate, refresh) do buf
        _scalar_rgba!(buf, data, resolve_scheme(colormap);
                      colorrange=_colorrange(data, colorrange), colorscale, nan_color)
    end
end
image!(label, data::AbstractMatrix{<:Number}; kw...) = image!(label, 1..size(data,1), 1..size(data,2), data; kw...)
