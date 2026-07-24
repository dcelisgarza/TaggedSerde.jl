# Generate README.md from docs/src/index.md.
#
# The package README is derived from the documentation landing page so the two can never
# disagree: `index.md` is the single source for the prose and the (doctested) examples, and
# this script mechanically turns it into a plain-GitHub-Markdown README. The badge block is
# the one thing the README carries that the docs page does not, so it lives here as a
# constant and is spliced in under the title.
#
# The transformation is intentionally tiny:
#   * drop the Documenter `@meta` block(s),
#   * turn ```jldoctest fences into plain ```julia,
#   * flatten `[text](@ref …)` cross-references to just `text`,
#   * insert the badges beneath the `# TaggedSerde` heading.
#
# Run it with `julia --project=docs docs/generate_readme.jl`. The pure `readme_string`
# function is also `include`d by the test suite, which asserts the committed README matches
# what this script would produce — so a stale README fails CI.

const BADGES = """
[![Stable Documentation](https://img.shields.io/badge/docs-stable-blue.svg)](https://dcelisgarza.github.io/TaggedSerde.jl/stable)
[![Development documentation](https://img.shields.io/badge/docs-dev-blue.svg)](https://dcelisgarza.github.io/TaggedSerde.jl/dev)
[![Test workflow status](https://github.com/dcelisgarza/TaggedSerde.jl/actions/workflows/Test.yml/badge.svg?branch=main)](https://github.com/dcelisgarza/TaggedSerde.jl/actions/workflows/Test.yml?query=branch%3Amain)
[![Coverage](https://codecov.io/gh/dcelisgarza/TaggedSerde.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/dcelisgarza/TaggedSerde.jl)
[![Lint workflow Status](https://github.com/dcelisgarza/TaggedSerde.jl/actions/workflows/Lint.yml/badge.svg?branch=main)](https://github.com/dcelisgarza/TaggedSerde.jl/actions/workflows/Lint.yml?query=branch%3Amain)
[![Docs workflow Status](https://github.com/dcelisgarza/TaggedSerde.jl/actions/workflows/Docs.yml/badge.svg?branch=main)](https://github.com/dcelisgarza/TaggedSerde.jl/actions/workflows/Docs.yml?query=branch%3Amain)
[![BestieTemplate](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/JuliaBesties/BestieTemplate.jl/main/docs/src/assets/badge.json)](https://github.com/JuliaBesties/BestieTemplate.jl)"""

const _TITLE = "# TaggedSerde"

"""
    readme_string(index_md::AbstractString) -> String

Turn the contents of `docs/src/index.md` into the README markdown. Pure: no I/O, so the
test suite can compare its result against the committed `README.md`.
"""
function readme_string(index_md::AbstractString)
    s = String(index_md)
    s = replace(s, r"```@meta\r?\n.*?\r?\n```\r?\n"s => "")   # drop @meta block(s)
    s = replace(s, r"```jldoctest[^\r\n]*" => "```julia")     # doctests -> plain julia
    s = replace(s, r"\[([^\]]*)\]\(@ref[^)]*\)" => s"\1")     # flatten @ref links
    s = strip(s)

    any(==(_TITLE), split(s, '\n')) ||
        error("generate_readme: could not find the '$_TITLE' heading in index.md")

    out = String[]
    for line in split(s, '\n')
        push!(out, line)
        if line == _TITLE
            push!(out, "")
            append!(out, split(BADGES, '\n'))
        end
    end
    return rstrip(join(out, '\n')) * "\n"
end

"Path to `docs/src/index.md`, relative to this script."
index_md_path() = normpath(joinpath(@__DIR__, "src", "index.md"))

"Path to the repository's `README.md`, relative to this script."
readme_path() = normpath(joinpath(@__DIR__, "..", "README.md"))

if abspath(PROGRAM_FILE) == @__FILE__
    write(readme_path(), readme_string(read(index_md_path(), String)))
    @info "Wrote $(readme_path()) from $(index_md_path())"
end
