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

@testitem "_scalar_rgba!" begin
    using ColorSchemes: colorschemes
    using ColorTypes: RGBA, N0f8, red, green, blue, alpha
    using Unitful: @u_str
    f = ImPlotExtra._scalar_rgba!
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
    @test (@inferred f(buf, data, sc; colorrange=(1.0,6.0), colorscale=identity, nan_color=nanc)) === buf

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
