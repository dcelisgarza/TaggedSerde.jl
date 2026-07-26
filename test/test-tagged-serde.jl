using TypeAgnosticSerialisation
using TypeAgnosticSerialisation:
    SerdeContext, encode, decode, to_json, from_json, from_json_direct
using Test
import TOML

# ---------------------------------------------------------------------------
# A self-contained domain to exercise the whole library. Nothing here depends on
# anything outside Base/Core, so the suite is hermetic.
# ---------------------------------------------------------------------------
module TestSerdeModule

export AbstractShape, Circle, Rect, Square, Color, red, green, blue
export Scene, Doc, KwOnly, Handle, NoDefault

abstract type AbstractShape end

# Parametric struct with a validating inner constructor: `from_json` must enforce the
# `r > 0` invariant, `from_json_direct` must be able to bypass it.
struct Circle{T} <: AbstractShape
    r::T
    function Circle{T}(r::T) where {T}
        r > 0 || error("Circle: radius must be positive (got $r)")
        return new{T}(r)
    end
end
Circle(r::T) where {T} = Circle{T}(r)

struct Rect{T} <: AbstractShape
    w::T
    h::T
end

struct Square <: AbstractShape end   # singleton, zero fields

@enum Color red green blue

# The payoff type: a heterogeneous `Vector{AbstractShape}`, an enum, and an `Any`-valued
# dict — none of the element types are known statically, so each carries its own tag.
struct Scene
    shapes::Vector{AbstractShape}
    bg::Color
    meta::Dict{String,Any}
end

# A "live" non-data handle: a raw pointer that cannot be serialised structurally. Used to
# show `opaque` skipping and the "fail loudly" path.
struct Handle
    ptr::Ptr{Cvoid}
    Handle() = new(C_NULL)
end

# Data wrapping a live handle, to show surrounding data survives when the handle is opaque.
struct Doc
    title::String
    handle::Handle
end

# Only a keyword constructor -> exercises `_construct_safe`'s keyword-by-field-name fallback.
struct KwOnly
    a::Int
    b::Int
    KwOnly(; a, b) = new(a, b)
end

# Opaque type with no zero-argument constructor -> `_construct_opaque` must fail loudly.
struct NoDefault
    x::Int
end

end # module TestSerdeModule

using .TestSerdeModule
const M = TestSerdeModule

# ---------------------------------------------------------------------------
# Test helpers (kept out of the package — they are not public API).
# ---------------------------------------------------------------------------

# Structural equality: user structs rarely define `==`, and `NaN != NaN`, so compare
# field-by-field with `isequal` at the leaves.
function structeq(a, b)
    typeof(a) === typeof(b) || return false
    T = typeof(a)
    if a isa AbstractFloat
        return isequal(a, b)                       # handles NaN / signed zero
    elseif a isa Number ||
           a isa AbstractString ||
           a isa Symbol ||
           a isa AbstractChar ||
           a isa Base.Enum
        return a == b
    elseif a isa AbstractArray
        size(a) == size(b) || return false
        return all(structeq(x, y) for (x, y) in zip(a, b))
    elseif a isa AbstractDict
        length(a) == length(b) || return false
        for (k, v) in a
            haskey(b, k) || return false
            structeq(v, b[k]) || return false
        end
        return true
    elseif a isa Tuple || a isa NamedTuple
        return all(structeq(getfield(a, i), getfield(b, i)) for i = 1:nfields(a))
    elseif isstructtype(T)
        for i = 1:fieldcount(T)
            (isdefined(a, i) == isdefined(b, i)) || return false
            isdefined(a, i) || continue
            structeq(getfield(a, i), getfield(b, i)) || return false
        end
        return true
    else
        return isequal(a, b)
    end
end

# Round-trip `x` through BOTH the tree layer (encode/decode) and the text layer
# (to_json/from_json*), returning the reconstructed values and whether they match.
function roundtrip(x; modules = (), opaque = (), validate = false)
    ctx = SerdeContext(modules; opaque = opaque, validate = validate)
    x_tree = decode(encode(x, ctx), ctx)
    js = to_json(x; modules = modules, opaque = opaque)
    x_text =
        validate ? from_json(js; modules = modules, opaque = opaque) :
        from_json_direct(js; modules = modules, opaque = opaque)
    return (;
        tree = x_tree,
        text = x_text,
        ok_tree = structeq(x, x_tree),
        ok_text = structeq(x, x_text),
    )
end

# A representative Scene: three shapes of three different concrete types under one abstract
# element type, plus a heterogeneous metadata dict.
sample_scene() = Scene(
    AbstractShape[Circle(1.5), Rect(3, 4), Square()],
    green,
    Dict{String,Any}("author" => "ada", "count" => 3, "ratio" => 2.5),
)

# ===========================================================================

@testset "core round-trip: Scene (validate=$v)" for v in (false, true)
    scene = sample_scene()
    r = roundtrip(scene; modules = (M,), validate = v)
    @test r.ok_tree
    @test r.ok_text
    # The whole point: abstract-typed fields return as the EXACT concrete types.
    for got in (r.tree, r.text)
        @test got isa Scene
        @test got.shapes[1] isa Circle{Float64}
        @test got.shapes[1].r == 1.5
        @test got.shapes[2] isa Rect{Int}
        @test (got.shapes[2].w, got.shapes[2].h) == (3, 4)
        @test got.shapes[3] isa Square
        @test got.bg === green
        @test got.meta["author"] == "ada"
    end
end

@testset "scalars & primitives round-trip" begin
    scalars = Any[
        0,
        -7,
        Int8(3),
        Int16(-4),
        Int32(5),
        UInt8(9),
        UInt16(10),
        UInt32(11),
        UInt64(12),
        3.14,
        Float32(2.5),
        Float16(1.5),
        true,
        false,
        "hello",
        "",
        :a_symbol,
        'x',
        Int128(2)^70,
        big"123456789012345678901234567890",
        big"1.5",
        1//3,
        Complex(1.0, -2.0),
        nothing,
        missing,
        (1, "two", :three),
        (a = 1, b = "two"),
        [1, 2, 3],
        Float64[],
        [1 2; 3 4],
        Any[1, "two", :three],
        Dict("x" => 1, "y" => 2),
    ]
    @testset "value = $(repr(x))" for x in scalars
        r = roundtrip(x; modules = ())
        @test r.ok_tree
        @test r.ok_text
    end

    @testset "non-finite floats: $(repr(x))" for x in (NaN, Inf, -Inf, NaN32, Inf32, -Inf16)
        r = roundtrip(x; modules = ())
        @test r.ok_tree
        @test r.ok_text
    end
end

@testset "enum round-trip" begin
    for c in instances(Color)
        r = roundtrip(c; modules = (M,))
        @test r.ok_tree
        @test r.ok_text
    end
    # A tag naming a non-existent member is refused.
    ctx = SerdeContext((M,))
    @test_throws ErrorException TypeAgnosticSerialisation._decode_plain(
        "not_a_color",
        Color,
        ctx,
    )
end

@testset "type values round-trip" begin
    ctx = SerdeContext((M,))
    typ(x) = decode(encode(x, ctx), ctx)
    @test typ(Int64) === Int64                 # leaf DataType
    @test typ(Union{}) === Union{}             # Bottom
    @test typ(Tuple{}) === Tuple{}             # empty-tuple special case
    @test typ(M.Circle) === M.Circle           # bare UnionAll wrapper
    @test typ(M.Rect{Int}) === M.Rect{Int}     # parametric DataType
    @test typ(Vector{Float64}) === Vector{Float64}  # value-valued type parameter (the `1`)
    # A field that itself holds a type round-trips too.
    struct_with_type = (kind = M.Circle, dims = Vector{Int})
    @test typ(struct_with_type) === struct_with_type
end

@testset "type-descriptor errors" begin
    ctx = SerdeContext((M,))
    # Partially-applied UnionAll is unsupported.
    @test_throws ErrorException TypeAgnosticSerialisation._type_desc(Array{Float64}, ctx)
    # A Union used as a type parameter is a non-concrete parameter.
    @test_throws ErrorException TypeAgnosticSerialisation._type_desc(
        Union{Int,Float64},
        ctx,
    )
end

@testset "module allowlist" begin
    scene = sample_scene()
    js = to_json(scene; modules = (M,))
    # M not on the allowlist on the way back in -> resolution refused.
    @test_throws ErrorException from_json(js; modules = ())

    ctx = SerdeContext((M,))
    # Nested submodule whose root is allowed resolves (BigFloat lives in Base.MPFR).
    @test TypeAgnosticSerialisation._lookup_module("Base.MPFR", ctx) === Base.MPFR
    @test TypeAgnosticSerialisation._lookup_module("Base.GMP", ctx) === Base.GMP
    # Root not allowed, or a non-existent submodule of an allowed root -> error.
    @test_throws ErrorException TypeAgnosticSerialisation._lookup_module(
        "NoSuchModule",
        ctx,
    )
    @test_throws ErrorException TypeAgnosticSerialisation._lookup_module(
        "Base.NoSuchSubmodule",
        ctx,
    )
end

@testset "resolve-type errors" begin
    ctx = SerdeContext((M,))
    @test_throws ErrorException TypeAgnosticSerialisation._resolve_type(
        Dict{String,Any}("name" => "Nope", "module" => "Base", "params" => Any[]),
        ctx,
    )
    @test_throws ErrorException TypeAgnosticSerialisation._resolve_type(
        Dict{String,Any}("name" => "println", "module" => "Base", "params" => Any[]),
        ctx,
    )
end

@testset "validated invariant enforcement vs direct bypass" begin
    good = to_json(Circle(7.0); modules = (M,))
    bad = replace(good, "7.0" => "-7.0"; count = 1)   # tamper the radius negative

    # from_json (validated): the inner constructor's check fires -> load refused.
    @test_throws ErrorException from_json(bad; modules = (M,))
    # from_json_direct: no validation -> a broken value is materialised.
    broken = from_json_direct(bad; modules = (M,))
    @test broken isa Circle{Float64}
    @test broken.r == -7.0
end

@testset "keyword-fallback constructor (KwOnly)" begin
    x = KwOnly(; a = 1, b = 2)
    for v in (false, true)
        r = roundtrip(x; modules = (M,), validate = v)
        @test r.ok_tree
        @test r.ok_text
    end
end

@testset "opaque handling (validate=$v)" for v in (false, true)
    # A live handle cannot be serialised structurally: without opting it out, encoding
    # fails loudly rather than emitting a broken artifact.
    @test_throws ErrorException to_json(Handle(); modules = (M,))
    @test_throws ErrorException to_json(Doc("report", Handle()); modules = (M,))

    # Marking the handle opaque lets the surrounding data round-trip; the handle itself is
    # skipped and rebuilt with its no-argument constructor.
    r = roundtrip(Doc("report", Handle()); modules = (M,), opaque = (Handle,), validate = v)
    @test r.ok_tree
    @test r.ok_text
    for got in (r.tree, r.text)
        @test got isa Doc
        @test got.title == "report"
        @test got.handle isa Handle
        @test got.handle.ptr == C_NULL
    end
end

@testset "opaque with no zero-arg constructor fails" begin
    ctx = SerdeContext((M,); opaque = (NoDefault,))
    tree = encode(NoDefault(5), ctx)          # placeholder only, ctor not called yet
    @test_throws ErrorException decode(tree, ctx)
    @test_throws ErrorException TypeAgnosticSerialisation._construct_opaque(NoDefault)
end

@testset "file save/load, $label" for (label, loader) in (
    "from_json (validated)" => from_json,
    "from_json_direct" => from_json_direct,
)
    scene = sample_scene()
    path = tempname() * ".json"
    # `modules = M` (a bare Module, not a tuple) exercises the single-Module constructor.
    open(io -> write(io, to_json(scene; modules = M, pretty = 2)), path, "w")
    reloaded = loader(read(path, String); modules = (M,))
    @test typeof(reloaded) === typeof(scene)
    @test structeq(scene, reloaded)
    rm(path)
end

@testset "text-agnostic core (TOML layer)" begin
    # The encode/decode core is text-agnostic. A concrete hint yields a bare structural
    # payload (no envelope), which for `Rect` is a plain table any TOML writer can render.
    ctx = SerdeContext((M,))
    r = Rect(3, 4)
    tree = encode(r, Rect{Int}, ctx)          # concrete hint -> {"w" => 3, "h" => 4}
    io = IOBuffer()
    TOML.print(io, tree)
    tree2 = TOML.parse(String(take!(io)))
    r2 = decode(tree2, Rect{Int}, ctx)
    @test structeq(r, r2)
end

@testset "decode/encode error branches" begin
    ctx = SerdeContext((M,))
    # Untagged payload with an abstract hint cannot be resolved.
    @test_throws ErrorException decode(Dict{String,Any}("w" => 1), M.AbstractShape, ctx)
    # A type with no encode/decode rule.
    @test_throws ErrorException TypeAgnosticSerialisation._encode_plain(
        C_NULL,
        Ptr{Cvoid},
        ctx,
    )
    @test_throws ErrorException TypeAgnosticSerialisation._decode_plain(
        "x",
        Ptr{Cvoid},
        ctx,
    )
    # #undef fields are unsupported.
    incomplete = ccall(:jl_new_struct_uninit, Any, (Any,), Rect{Any})
    @test_throws ErrorException encode(incomplete, ctx)
end

@testset "internal reconstruction guards" begin
    # Field-count mismatch (e.g. a truncated/oversized payload).
    @test_throws ErrorException TypeAgnosticSerialisation._newbuild(
        M.Rect{Int},
        Any[1, 2, 3],
    )
    # `new` cannot build a non-concrete type.
    @test_throws ErrorException TypeAgnosticSerialisation._new_impl(M.AbstractShape, ())
end

@testset "SerdeContext constructors" begin
    @test SerdeContext() isa SerdeContext
    @test SerdeContext(M) isa SerdeContext
    @test SerdeContext((M,)) isa SerdeContext
    @test SerdeContext(; modules = (M,)) isa SerdeContext
    # Base and Core are always present.
    ctx = SerdeContext()
    @test ctx.modules["Base"] === Base
    @test ctx.modules["Core"] === Core
end
