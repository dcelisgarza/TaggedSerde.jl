# TaggedSerde

[![Stable Documentation](https://img.shields.io/badge/docs-stable-blue.svg)](https://dcelisgarza.github.io/TaggedSerde.jl/stable)
[![Development documentation](https://img.shields.io/badge/docs-dev-blue.svg)](https://dcelisgarza.github.io/TaggedSerde.jl/dev)
[![Test workflow status](https://github.com/dcelisgarza/TaggedSerde.jl/actions/workflows/Test.yml/badge.svg?branch=main)](https://github.com/dcelisgarza/TaggedSerde.jl/actions/workflows/Test.yml?query=branch%3Amain)
[![Coverage](https://codecov.io/gh/dcelisgarza/TaggedSerde.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/dcelisgarza/TaggedSerde.jl)
[![Lint workflow Status](https://github.com/dcelisgarza/TaggedSerde.jl/actions/workflows/Lint.yml/badge.svg?branch=main)](https://github.com/dcelisgarza/TaggedSerde.jl/actions/workflows/Lint.yml?query=branch%3Amain)
[![Docs workflow Status](https://github.com/dcelisgarza/TaggedSerde.jl/actions/workflows/Docs.yml/badge.svg?branch=main)](https://github.com/dcelisgarza/TaggedSerde.jl/actions/workflows/Docs.yml?query=branch%3Amain)
[![BestieTemplate](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/JuliaBesties/BestieTemplate.jl/main/docs/src/assets/badge.json)](https://github.com/JuliaBesties/BestieTemplate.jl)

**TaggedSerde** serialises an arbitrary Julia value to JSON and reconstructs it later
*without knowing its type up front*. The JSON carries enough type metadata — the full
concrete type, including type parameters, recursively — to rebuild the exact concrete type
tree. That is what lets a field declared `::AbstractShape` come back as the precise
`Circle{Float64}` you put in.

Type resolution is gated by a **module allowlist**: a `__type__` tag may only name a type
reachable from a module you explicitly trust. There is no `eval` of strings from the
document.

## Installation

```julia
using Pkg
Pkg.add("TaggedSerde")
```

## A worked example

Everything below is a runnable, tested example. First, a small self-contained set of types.
`Circle` is parametric with a validating inner constructor (radius must be positive);
`Square` is a singleton; `Color` is an `@enum`; and `Handle` wraps a raw pointer — a
stand-in for a live, non-data object. `Scene` ties them together, holding a heterogeneous
`Vector{AbstractShape}`. All the names are exported so they can be used unqualified after
`using .Shapes`:

```julia
julia> using TaggedSerde

julia> module Shapes
           export AbstractShape, Circle, Rect, Square, Color, red, green, blue, Scene, Handle, Doc
           abstract type AbstractShape end
           struct Circle{T} <: AbstractShape
               r::T
               function Circle{T}(r::T) where {T}
                   r > 0 || error("Circle: radius must be positive")
                   return new{T}(r)
               end
           end
           Circle(r::T) where {T} = Circle{T}(r)
           struct Rect{T} <: AbstractShape
               w::T
               h::T
           end
           struct Square <: AbstractShape end
           @enum Color red green blue
           struct Scene
               shapes::Vector{AbstractShape}
               bg::Color
           end
           struct Handle
               ptr::Ptr{Cvoid}
               Handle() = new(C_NULL)
           end
           struct Doc
               title::String
               handle::Handle
           end
       end;

julia> using .Shapes
```

### Serialise and reconstruct

`to_json` writes a value out; `from_json` reads it back. The element type of
`shapes` is the abstract `AbstractShape`, yet each element returns as the exact concrete
type it was — that is the whole point:

```julia
julia> scene = Scene(AbstractShape[Circle(1.5), Rect(3, 4), Square()], green);

julia> json = to_json(scene; modules = (Shapes,));

julia> back = from_json(json; modules = (Shapes,));

julia> back.shapes[1] isa Circle{Float64}
true

julia> back.shapes[2] isa Rect{Int}
true

julia> (back.shapes[1].r, back.shapes[2].w, back.shapes[2].h)
(1.5, 3, 4)

julia> back.bg === green
true
```

The `modules` allowlist is what makes reconstruction safe: only types reachable from the
modules you pass (plus the always-present `Base`/`Core`) can be named by a tag. Hand the
same document to a context that does not allow `Shapes`, and resolution is refused rather
than resolving an unexpected type:

```julia
julia> try
           from_json(json; modules = ())
       catch
           :refused
       end
:refused
```

Under the hood, each value is wrapped in a self-describing `{"__type__": …, "__value__": …}`
envelope carrying its full concrete type. For a single `Circle(1.5)` the JSON reads:

```json
{
  "__type__": {
    "module": "Main.Shapes",
    "name": "Circle",
    "params": [
      { "type": { "module": "Core", "name": "Float64", "params": [] } }
    ]
  },
  "__value__": {
    "r": 1.5
  }
}
```

### Validated vs. direct loading

`from_json` is **validated**: every struct is rebuilt through its own constructor, so all
inner-constructor / `@argcheck` invariants run and a tampered or inconsistent document is
refused. `Circle`'s constructor requires `r > 0`; tamper the radius negative and the load
fails:

```julia
julia> bad = replace(json, "1.5" => "-1.5");

julia> try
           from_json(bad; modules = (Shapes,))
       catch
           :refused
       end
:refused
```

`from_json_direct` instead builds each struct field-by-field with Julia's own `new`,
bypassing all constructors. It reconstructs *any* struct and is still type-safe (`new`
type-checks every field), but runs **no** user validation — so the same tampered document
loads a broken value. Use it for JSON you produced and trust, or for types whose
constructor cannot be replayed from its fields:

```julia
julia> from_json_direct(bad; modules = (Shapes,)).shapes[1].r
-1.5
```

### Skipping live, non-data fields with `opaque`

Some fields hold live, non-data objects — open files, solver models, raw pointers — that
cannot (and should not) be serialised structurally. Encoding one that is *not* opted out
fails loudly rather than emitting a broken artifact:

```julia
julia> doc = Doc("annual report", Handle());

julia> try
           to_json(doc; modules = (Shapes,))
       catch
           :failed_loudly
       end
:failed_loudly
```

Mark such a type `opaque` and it is replaced by a placeholder on encode and rebuilt with its
no-argument constructor `T()` on decode. The surrounding data round-trips untouched; the
live object comes back fresh:

```julia
julia> js = to_json(doc; modules = (Shapes,), opaque = (Handle,));

julia> back = from_json(js; modules = (Shapes,), opaque = (Handle,));

julia> back.title
"annual report"

julia> back.handle.ptr == C_NULL
true
```

### The dependency-free core: `encode` / `decode`

`to_json` is just `encode` followed by `JSON.json`. The `encode`/`decode` core has
no dependencies at all — it lowers a value to a **plain tree** of `Dict{String,Any}`,
`Vector{Any}` and scalars, which any text layer can render:

```julia
julia> ctx = SerdeContext((Shapes,));

julia> tree = encode(Circle(2.0), ctx);

julia> tree isa Dict{String,Any}
true

julia> decode(tree, ctx).r
2.0
```

### A different text layer (TOML)

Because the core is text-agnostic, you can serialise the plain tree through any format, not
just JSON. When the type is known at the call site (a concrete `hint`), `encode` emits a
bare structural payload with no envelope — for `Rect` that is a plain table, which round-
trips cleanly through TOML:

```julia
julia> import TOML

julia> payload = encode(Rect(3, 4), Rect{Int}, ctx);   # concrete hint -> no envelope

julia> io = IOBuffer(); TOML.print(io, payload); s = String(take!(io));

julia> rt = decode(TOML.parse(s), Rect{Int}, ctx);

julia> (rt.w, rt.h)
(3, 4)
```

## Reserved keys and limitations

The envelope reserves a handful of JSON keys: `"__type__"`, `"__value__"` (the tagged
envelope); `"type"`/`"value"` (type-parameter wrappers); `"size"`/`"data"` (arrays);
`"pairs"` (dicts); `"names"`/`"values"` (named tuples); and `"__opaque__"` (opaque
placeholders). A struct field literally named `__type__` would collide — a documented
limitation. `#undef` fields are unsupported and are reported rather than silently dropped.

## Reference

Every exported function — `to_json`, `from_json`,
`from_json_direct`, `encode`, `decode` and `SerdeContext` —
is documented in full in the Reference section of the online
documentation.
