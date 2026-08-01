using Accessors: constructorof
import InverseFunctions: inverse

# axis_scale.jl — install an invertible `scale` as an ImPlot axis transform, inline each frame, with no
# module state and no caller-held handle. Works for any scale that is isbits with 0 or 1 field, has an
# `inverse`, and rebuilds via `constructorof` (SymLog, log10, sqrt, identity, …).
#
# All three of {no globals, no caller state, monomorphic} hold at once because:
#  · the scale's single field (≤ 8 bytes) rides inside ImPlot's own `user_data` pointer — ImPlot copies the
#    bytes and never dereferences them, so there is no Julia object to keep alive;
#  · the trampoline's `Ptr{T}` arg is ABI-identical to `void*` but carries the scale type, so one generic
#    `_scale_fwd`/`_scale_inv` compiles monomorphically per `T`, and a static `@cfunction` returns a stable
#    cached raw pointer that needs no rooting (0 allocations).

_scale_uint(::Val{1}) = UInt8
_scale_uint(::Val{2}) = UInt16
_scale_uint(::Val{4}) = UInt32
_scale_uint(::Val{8}) = UInt64
_scale_pack(x) = UInt64(reinterpret(_scale_uint(Val(sizeof(x))), x))
_scale_unpack(::Type{F}, bits::UInt64) where {F} = reinterpret(F, _scale_uint(Val(sizeof(F)))(bits % _scale_uint(Val(sizeof(F)))))

# rebuild a 0/1-field scale from the `user_data` bits (a singleton carries no value)
_rebuild_scale(::Type{T}, bits::UInt64) where {T} =
    fieldcount(T) == 0 ? T.instance : constructorof(T)(_scale_unpack(fieldtype(T, 1), bits))

_scale_fwd(v::Cdouble, d::Ptr{T}) where {T} = Cdouble(_rebuild_scale(T, UInt64(d))(v))
_scale_inv(v::Cdouble, d::Ptr{T}) where {T} = Cdouble(inverse(_rebuild_scale(T, UInt64(d)))(v))

"""
    setup_axis_scale!(axis, scale)

Install `scale` as ImPlot `axis`'s transform — the axis analogue of `image!`/`colorbar!`'s `colorscale`.
Call inline each frame inside `BeginPlot`/`EndPlot`, passing the scale directly:
`setup_axis_scale!(ImPlot.ImAxis_Y1, SymLog(20))`, `setup_axis_scale!(ImPlot.ImAxis_Y1, log10)`.

`scale` is any callable value→coordinate map that is isbits with 0 or 1 field (a `sizeof ≤ 8` field), has an
`InverseFunctions.inverse`, and rebuilds via `ConstructionBase.constructorof` — [`SymLog`](@ref), `log10`,
`sqrt`, `identity`, …. It must be finite on the padded axis range (ImPlot probes past the data); a throw
crosses the C boundary and crashes.
"""
function setup_axis_scale!(axis, scale::T) where {T}
    @assert isbitstype(T) && fieldcount(T) ≤ 1 && sizeof(T) ≤ sizeof(Ptr)
    data = Ptr{Cvoid}(fieldcount(T) == 0 ? UInt(0) : UInt(_scale_pack(getfield(scale, 1))))
    ImPlot.SetupAxisScale(axis, @cfunction(_scale_fwd, Cdouble, (Cdouble, Ptr{T})),
                          @cfunction(_scale_inv, Cdouble, (Cdouble, Ptr{T})), data)
end
