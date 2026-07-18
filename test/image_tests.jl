@testitem "resolve_scheme" begin
    using ColorSchemes: ColorScheme, colorschemes
    using ColorTypes: RGB
    rs = ImPlotExtra.resolve_scheme
    @test rs(:viridis) === colorschemes[:viridis]
    @test rs(colorschemes[:plasma]) === colorschemes[:plasma]
    cs = rs([RGB(0,0,0), RGB(1,1,1)])
    @test cs isa ColorScheme && length(cs.colors) == 2
    @test_throws Exception rs(:not_a_real_colormap_xyz)
end

@testitem "_colorrange" begin
    using Unitful: @u_str
    cr = ImPlotExtra._colorrange
    @test cr([1.0 2.0; 3.0 4.0], nothing) == (1.0, 4.0)
    @test cr([1.0 NaN; Inf 4.0], nothing) == (1.0, 4.0)          # skips non-finite
    @test cr([1.0 2.0], (0.0, 10.0)) == (0.0, 10.0)               # explicit passthrough
    @test cr([1.0u"m" 5.0u"m"], nothing) == (1.0u"m", 5.0u"m")    # Unitful
    @test_throws Exception cr([NaN NaN], nothing)                 # no finite values
end

@testitem "_scalar_rgba! exact path (lut=false)" begin
    using ColorSchemes: colorschemes
    using ColorTypes: RGBA, N0f8, red, green, blue, alpha
    using Unitful: @u_str
    f(buf, data, scheme; kw...) = ImPlotExtra._scalar_rgba!(buf, data, scheme; lut=false, kw...)  # exact per-pixel path
    sc = colorschemes[:viridis]
    lo = convert(RGBA{N0f8}, get(sc,0.0)); hi = convert(RGBA{N0f8}, get(sc,1.0)); mid = convert(RGBA{N0f8}, get(sc,0.5))
    nanc = RGBA{N0f8}(0,0,0,0)
    bytes(c) = (reinterpret(UInt8,red(c)),reinterpret(UInt8,green(c)),reinterpret(UInt8,blue(c)),reinterpret(UInt8,alpha(c)))

    data = Float64[1 2 3; 4 5 6]                  # 2×3 ⇒ W=2,H=3 ; data[1,1]=min, data[2,3]=max
    buf = Matrix{RGBA{N0f8}}(undef, 2, 3)
    f(buf, data, sc; colorrange=(1.0,6.0), colorscale=identity, nan_color=nanc)
    @test buf[1,1] == lo
    @test buf[2,3] == hi
    @test bytes(buf[1,1]) == (0x44,0x01,0x54,0xff)            # independent hardcoded viridis(0.0)
    @test (@inferred ImPlotExtra._scalar_rgba!(buf, data, sc; colorrange=(1.0,6.0), colorscale=identity, nan_color=nanc, lut=false)) === buf

    d2 = [1.0 NaN; 1.0 6.0]; b2 = Matrix{RGBA{N0f8}}(undef,2,2)
    f(b2, d2, sc; colorrange=(1.0,6.0), colorscale=identity, nan_color=nanc)
    @test b2[1,2] == nanc                                     # NaN → transparent

    d3 = [0.0 100.0; -5.0 10.0]; b3 = Matrix{RGBA{N0f8}}(undef,2,2)
    f(b3, d3, sc; colorrange=(1.0,100.0), colorscale=log10, nan_color=nanc)
    @test b3[1,1] == lo                                       # 0 clamps to lo (no DomainError)

    d4 = reshape([2.0, 2.0],2,1); b4 = Matrix{RGBA{N0f8}}(undef,2,1)
    f(b4, d4, sc; colorrange=(2.0,2.0), colorscale=identity, nan_color=nanc)
    @test b4[1,1] == mid                                      # degenerate ⇒ midpoint

    dU = reshape([1.0u"m", 10.0u"m"],2,1); bU = Matrix{RGBA{N0f8}}(undef,2,1)
    f(bU, dU, sc; colorrange=(1.0u"m",10.0u"m"), colorscale=identity, nan_color=nanc)
    @test bU[1,1] == lo && bU[2,1] == hi                      # Unitful same-unit

    dC = reshape([100.0u"cm"],1,1); bC = Matrix{RGBA{N0f8}}(undef,1,1)
    f(bC, dC, sc; colorrange=(0.0u"m",2.0u"m"), colorscale=identity, nan_color=nanc)
    @test bC[1,1] == mid                                      # 1m within [0,2]m ⇒ t=0.5 (mixed units)

    @test_throws Exception f(b4, d4, sc; colorrange=(0.0,10.0), colorscale=log10, nan_color=nanc)   # log10(0)=-Inf
    @test_throws Exception f(b4, d4, sc; colorrange=(10.0,1.0), colorscale=identity, nan_color=nanc) # inverted
end

@testitem "_scalar_rgba! LUT (default) ≈ exact, all eltypes" begin
    using ColorSchemes: colorschemes, get
    using ColorTypes: RGBA, N0f8, red, green, blue, alpha
    using Unitful: @u_str
    nanc = RGBA{N0f8}(0,0,0,0)
    byte(x) = Int(reinterpret(UInt8, x))
    chdiff(x, y) = maximum(abs, (byte(red(x))-byte(red(y)), byte(green(x))-byte(green(y)),
                                 byte(blue(x))-byte(blue(y)), byte(alpha(x))-byte(alpha(y))))
    # independent exact reference: units divided out (as the impl does), value→colour per pixel, no table
    function ref(data, sc, lo, hi, cs)
        u = oneunit(lo); iu = inv(u); loʹ, hiʹ = lo/u, hi/u; slo, shi = cs(loʹ), cs(hiʹ)
        map(data) do v
            isfinite(v) || return nanc
            t = (cs(clamp(v*iu, loʹ, hiʹ)) - slo) / (shi - slo)
            isfinite(t) ? convert(RGBA{N0f8}, get(sc, clamp(t, 0.0, 1.0))) : nanc
        end
    end
    sc = colorschemes[:viridis]; scb = colorschemes[:balance]
    cases = ((identity,0.0,1.0,sc), (asinh,1e-4,5.0,sc), (log10,1e-3,10.0,sc), (sqrt,0.0,4.0,sc),
             (identity,-1.0,1.0,scb), (asinh,-0.5,0.5,scb))
    mag = 10 .^ (10 .* rand(200,200) .- 5)

    # Float32 ≡ Float64 (no eltype dependency); incl. out-of-range ±1e8, NaN, Inf
    for T in (Float32, Float64)
        d = T.(sign.(randn(200,200)) .* mag); d[1]=T(1e8); d[2]=T(-1e8); d[3]=T(NaN); d[4]=T(Inf)
        buf = Matrix{RGBA{N0f8}}(undef, size(d))
        for (cs, lo, hi, scc) in cases
            ImPlotExtra._scalar_rgba!(buf, d, scc; colorrange=(lo,hi), colorscale=cs, nan_color=nanc)
            @test maximum(chdiff.(buf, ref(d, scc, lo, hi, cs))) ≤ 3
            @test buf[3] == nanc && buf[4] == nanc
        end
    end
    bi = Matrix{RGBA{N0f8}}(undef,4,4); di = rand(Float32,4,4)
    @test (@inferred ImPlotExtra._scalar_rgba!(bi, di, sc; colorrange=(0.0,1.0), colorscale=asinh, nan_color=nanc)) === bi

    # Unitful through the SAME path; log10 works (impossible per-pixel on a Quantity); mixed units convert
    pos = 10 .^ (6 .* rand(200,200) .- 3)
    du = Float32.(pos) .* u"m"; bu = similar(du, RGBA{N0f8})
    for (cs, lo, hi) in ((identity,0.5u"m",8.0u"m"), (log10,1e-2u"m",10.0u"m"))
        ImPlotExtra._scalar_rgba!(bu, du, sc; colorrange=(lo,hi), colorscale=cs, nan_color=nanc)
        @test maximum(chdiff.(bu, ref(du, sc, lo, hi, cs))) ≤ 3
    end
    dcm = Float32.(100 .* pos) .* u"cm"; bcm = similar(dcm, RGBA{N0f8})
    ImPlotExtra._scalar_rgba!(bcm, dcm, sc; colorrange=(0.5u"m",8.0u"m"), colorscale=identity, nan_color=nanc)
    @test maximum(chdiff.(bcm, ref(dcm, sc, 0.5u"m", 8.0u"m", identity))) ≤ 3

    # lut=false agrees with lut=true to ≤3/255 (toggle trades speed for exactness)
    d = Float32.(pos); a = similar(d, RGBA{N0f8}); b = similar(d, RGBA{N0f8})
    ImPlotExtra._scalar_rgba!(a, d, sc; colorrange=(1e-3,10.0), colorscale=log10, nan_color=nanc, lut=true)
    ImPlotExtra._scalar_rgba!(b, d, sc; colorrange=(1e-3,10.0), colorscale=log10, nan_color=nanc, lut=false)
    @test maximum(chdiff.(a, b)) ≤ 3
end

@testitem "_colorant_rgba!" begin
    using ColorTypes: RGB, RGBA, Gray, N0f8, alpha
    f = ImPlotExtra._colorant_rgba!
    data = [RGB(1.0,0.0,0.0) RGB(0.0,1.0,0.0)]      # 1×2 ⇒ W=1,H=2
    buf = Matrix{RGBA{N0f8}}(undef, 1, 2)
    f(buf, data)
    @test buf[1,1] == RGBA{N0f8}(1,0,0,1)
    @test buf[1,2] == RGBA{N0f8}(0,1,0,1)
    bg = Matrix{RGBA{N0f8}}(undef,1,1); f(bg, reshape([Gray(0.5)],1,1))
    @test alpha(bg[1,1]) == 1                         # Gray/RGB ⇒ opaque
end

@testitem "_centers_to_bounds" begin
    using IntervalSets: (..)
    g = ImPlotExtra._centers_to_bounds
    @test g(1..2, 4) == (1 - 1/6, 2 + 1/6)    # Δ=(2-1)/3=1/3 ; edges first-Δ/2 .. last+Δ/2
    @test g(1..2, 2) == (0.5, 2.5)            # Δ=1 ; n=2
    @test g(0..0, 1) == (-0.5, 0.5)           # single pixel, degenerate interval ⇒ unit width
    lo, hi = g(1..2, 4)
    @test (hi - lo) ≈ 4 * ((2-1)/3)           # total width = N·Δ
    @test g(1..4, 4) == (0.5, 4.5)            # default-style: centers 1:4 ⇒ data[i] at i, edges 0.5..4.5
end

@testitem "_needs_update" begin
    using IntervalSets: (..)
    using ColorTypes: RGBA, N0f8
    nu = ImPlotExtra._needs_update
    a = rand(2,2); b = copy(a)
    base = (a, (0.0,1.0), :viridis, identity, RGBA{N0f8}(0,0,0,0), false, (1..2, 1..2))
    @test nu(nothing, base, false)                         # no prior entry
    @test !nu(base, base, false)                            # identical ⇒ no update
    @test nu(base, base, true)                              # refresh forces update
    @test nu(base, (b, base[2:end]...), false)              # different array object (===)
    @test nu(base, (a, (0.0,2.0), base[3:end]...), false)   # colorrange changed
    @test !nu(base, (a, base[2:end]...), false)             # same object, same opts
end

@testitem "SymLog + BaseMulTicks + scale_ticks" begin
    using ImPlotExtra: SymLog, BaseMulTicks, tickvalues, scale_ticks

    # SymLog: asinh-based, odd through 0, value-stable under ===
    s = SymLog(1e-4)
    @test s(0.0) == 0.0
    @test s(3e-4) ≈ asinh(3.0)
    @test s(-2e-4) ≈ -asinh(2.0)                 # odd
    @test SymLog(1e-4) === SymLog(1e-4)          # isbits egal ⇒ no per-frame re-upload

    # inverse auto-derived by InverseFunctions from the same asinh∘(/threshold) composition (no manual sinh)
    inv = ImPlotExtra.inverse(s)
    @test inv(s(3e-4)) ≈ 3e-4                     # round-trip both signs
    @test inv(s(-7e-4)) ≈ -7e-4
    @test inv(0.0) == 0.0
    @test ImPlotExtra.inverse(log10)(log10(50.0)) ≈ 50.0   # built-in scales are invertible too
    @test ImPlotExtra.inverse(identity)(3.0) == 3.0

    # BaseMulTicks: mul·base^pow over a same-sign range
    @test tickvalues(BaseMulTicks([1]), 1e-3, 1e-1) ≈ [1e-3, 1e-2, 1e-1]
    @test isempty(tickvalues(BaseMulTicks([1]), 5.0, 1.0))                  # vmin ≥ vmax ⇒ empty
    @test sort(tickvalues(BaseMulTicks([1]), -1e-1, -1e-3)) ≈ [-1e-1, -1e-2, -1e-3]   # negated flip
    @test_throws Exception tickvalues(BaseMulTicks([1]), -1.0, 1.0)         # straddles 0 ⇒ SymLog method
    @test length(tickvalues(BaseMulTicks(), 1e-4, 1e-2)) ≥ 7                # auto-densifies to ≥ k_min

    # scale_ticks regimes: the vanishing-ticks fix. Each of these returned 0–1 ticks before.
    posn(S, ts, lo, hi) = [(float(S(v)) - float(S(lo))) / (float(S(hi)) - float(S(lo))) for v in ts]
    for (lo, hi, a) in [(-3e-5, 3e-5, 1e-4),     # tiny V, whole range inside the linear core
                        (1e-4, 5e-4, 1e-2),       # narrow sequential
                        (2e-3, 6e-3, 1e-4),       # sub-decade span
                        (-1e-2, 1e-2, 1e-4),      # wide bipolar
                        (0.0, 5e-2, 1e-4)]        # wide sequential incl. 0
        S = SymLog(a); ts = scale_ticks(S, lo, hi)
        @test length(ts) ≥ 2                       # never empty
        @test issorted(ts)
        p = posn(S, ts, lo, hi)
        @test issorted(p)                          # monotone under the scale
        @test all(t -> -1e-9 ≤ t ≤ 1 + 1e-9, p)    # every tick within the bar
    end

    # SymLog bipolar: symmetric about 0, endpoint decade retained despite fp rounding
    bip = scale_ticks(SymLog(1e-4), -1e-2, 1e-2)
    @test 0.0 in bip
    @test bip ≈ -reverse(bip)
    @test any(v -> isapprox(v, 1e-2; rtol=1e-6), bip) && any(v -> isapprox(v, -1e-2; rtol=1e-6), bip)
    @test !(0.0 in scale_ticks(SymLog(1e-4), 1e-4, 1e-2))                   # 0 excluded when unspanned

    # linear / log scale dispatch
    @test scale_ticks(identity, 0.0, 6.3) ≈ [0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0]
    @test scale_ticks(sqrt, 0.0, 4.0) == scale_ticks(identity, 0.0, 4.0)   # sqrt ⇒ linear ticks
    lg = scale_ticks(log10, 1e-4, 1e-2)
    @test count(v -> isapprox(v, 1e-2; rtol=1e-6), lg) == 1                 # endpoint decades kept
    @test count(v -> isapprox(v, 1e-4; rtol=1e-6), lg) == 1
end

@testitem "colorbar! interaction math" begin
    using ImPlotExtra: SymLog, _cbar_zoom_cursor, _cbar_pan, _cbar_zoom_sym
    posn(S, v, lo, hi) = (float(S(v)) - float(S(lo))) / (float(S(hi)) - float(S(lo)))   # colour-fraction of v

    # zoom-about-cursor (identity): the value under the cursor stays fixed; window scales by z
    for f in (0.0, 0.3, 1.0), z in (0.5, 2.0)
        lo, hi = 0.0, 10.0
        nlo, nhi = _cbar_zoom_cursor(identity, lo, hi, f, z)
        @test (lo + f*(hi-lo)) ≈ (nlo + f*(nhi-nlo))       # pivot data value unchanged
        @test (nhi - nlo) ≈ (hi - lo) * z                  # width scaled by z
    end

    # zoom-about-cursor (log10): uniform on the log bar; endpoints stay positive; pivot fraction preserved
    nlo, nhi = _cbar_zoom_cursor(log10, 1e-2, 1e2, 0.5, 0.5)
    @test nlo > 0 && nhi > 0
    @test posn(log10, 1.0, nlo, nhi) ≈ 0.5                 # log-mid pivot (value 1.0) stays at fraction 0.5
    @test log10(nhi) - log10(nlo) ≈ (log10(1e2) - log10(1e-2)) * 0.5

    # zoom-about-cursor (SymLog): pivot value fixed, monotone, uniform in transformed space
    S = SymLog(0.1); zlo, zhi = _cbar_zoom_cursor(S, -5.0, 5.0, 0.3, 0.4)
    @test zlo < zhi
    @test (float(S(zhi)) - float(S(zlo))) ≈ (float(S(5.0)) - float(S(-5.0))) * 0.4
    pivot = ImPlotExtra.inverse(S)(float(S(-5.0)) + 0.3*(float(S(5.0)) - float(S(-5.0))))  # data value under cursor
    @test posn(S, pivot, zlo, zhi) ≈ 0.3                   # its transformed fraction is preserved

    # pan (identity): grab-follow shift adds ds to both endpoints
    @test _cbar_pan(identity, 0.0, 10.0, 2.0) == (2.0, 12.0)
    # pan (log10) shifts multiplicatively, staying positive
    plo, phi = _cbar_pan(log10, 1.0, 100.0, 1.0)           # +1 in log space ⇒ ×10
    @test plo ≈ 10.0 && phi ≈ 1000.0

    # symmetric zoom about 0 (SymLog): remains symmetric; half-width shrinks for z<1
    sl, sh = _cbar_zoom_sym(SymLog(0.1), 0.0, 5.0, 0.5)
    @test sl ≈ -sh && 0 < sh < 5.0
    # symmetric zoom about nonzero center (identity): range = center ± h, h scaled by z
    @test _cbar_zoom_sym(identity, 5.0, 8.0, 0.5) == (3.5, 6.5)   # h: 3 → 1.5
    @test _cbar_zoom_sym(identity, 0.0, 2.0, 2.0) == (-4.0, 4.0)  # zoom out: h 2 → 4

    # fixed-anchor zoom (colorbar! computes f from the anchor's colour-fraction, then reuses zoom-cursor):
    # the anchor value's fraction is preserved ⇒ it stays put on the bar, incl. an anchor OUTSIDE the range
    anchor_zoom(S, lo, hi, a, z) = _cbar_zoom_cursor(S, lo, hi, posn(S, a, lo, hi), z)
    for (S, lo, hi, a) in ((identity, 0.0, 10.0, 3.0), (log10, 1e-2, 1e2, 1.0),
                           (SymLog(0.3), -5.0, 5.0, 0.0), (identity, 5.0, 10.0, 0.0))  # last: anchor below range
        al, ah = anchor_zoom(S, lo, hi, a, 0.5)
        @test al < ah
        @test posn(S, a, al, ah) ≈ posn(S, a, lo, hi)            # anchor pinned at its fraction
        @test (float(S(ah)) - float(S(al))) ≈ (float(S(hi)) - float(S(lo))) * 0.5
    end
end
