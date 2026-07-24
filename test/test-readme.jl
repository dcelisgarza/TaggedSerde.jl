# The README is generated from docs/src/index.md by docs/generate_readme.jl. This test
# asserts the committed README.md is byte-for-byte what the generator would produce, so the
# two can never silently drift. If it fails, regenerate and commit:
#
#     julia --project=docs docs/generate_readme.jl

# `include`ing the generator defines `readme_string` without running its writer (that is
# guarded by `abspath(PROGRAM_FILE) == @__FILE__`, false under `include`).
include(joinpath(@__DIR__, "..", "docs", "generate_readme.jl"))

@testset "README is in sync with docs/src/index.md" begin
    expected = readme_string(read(index_md_path(), String))
    actual = read(readme_path(), String)
    @test actual == expected
end
