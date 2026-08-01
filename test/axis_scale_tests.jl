@testitem "setup_axis_scale! trampolines" begin
    using ImPlotExtra: SymLog, _scale_fwd, _scale_inv, _scale_pack
    # build the C-callback pair exactly as setup_axis_scale! does, then call through it as ImPlot would
    fwd(::Type{T}) where {T} = @cfunction(_scale_fwd, Cdouble, (Cdouble, Ptr{T}))
    inv(::Type{T}) where {T} = @cfunction(_scale_inv, Cdouble, (Cdouble, Ptr{T}))
    call(p, v, d) = ccall(p, Cdouble, (Cdouble, Ptr{Cvoid}), v, d)
    data(s) = Ptr{Cvoid}(fieldcount(typeof(s)) == 0 ? UInt(0) : UInt(_scale_pack(getfield(s, 1))))

    # SymLog(20): forward asinh(v/20), inverse 20·sinh(v). Hardcoded expected values.
    d20 = data(SymLog(20.0))
    @test call(fwd(SymLog), 200.0, d20) ≈ 2.99822295029797     # asinh(10)
    @test call(fwd(SymLog), 0.0, d20) ≈ 0.0
    @test call(fwd(SymLog), -200.0, d20) ≈ -2.99822295029797   # odd through 0
    @test call(inv(SymLog), 2.99822295029797, d20) ≈ 200.0     # round-trip

    # threshold rides in user_data: a different value through the SAME pointer
    @test call(fwd(SymLog), 4.0, data(SymLog(2.0))) ≈ 1.4436354751788103   # asinh(2)

    # 0-field singleton scale: log10 / exp10, value slot unused
    dl = data(log10)
    @test call(fwd(typeof(log10)), 1000.0, dl) ≈ 3.0
    @test call(inv(typeof(log10)), 3.0, dl) ≈ 1000.0

    # monomorphic and allocation-free at the FFI boundary (measured in a function barrier — a bare
    # @allocated at test-item top level would count global-variable boxing, not the call itself)
    @test (@inferred _scale_fwd(200.0, Ptr{SymLog}(d20))) ≈ 2.99822295029797
    function noalloc()
        p = Ptr{SymLog}(Ptr{Cvoid}(UInt(_scale_pack(20.0))))
        _scale_fwd(200.0, p)                                   # warm up
        @allocated _scale_fwd(200.0, p)
    end
    @test noalloc() == 0
end

@testitem "setup_axis_scale! rejects unsupported scales" begin
    using ImPlotExtra: setup_axis_scale!
    struct TwoField; a::Float64; b::Float64 end            # >1 field ⇒ can't pointer-encode
    @test_throws AssertionError setup_axis_scale!(3, TwoField(1.0, 2.0))   # assert fires before `axis` is used
end
