module SystemStructures

using DataStructures
using SymbolicUtils: istree, operation, arguments, Symbolic
using ..ModelingToolkit
import ..ModelingToolkit: isdiffeq, var_from_nested_derivative, vars!, flatten, value
using ..BipartiteGraphs
using UnPack
using Setfield
using SparseArrays

#=
When we don't do subsitution, variable information is split into two different
places, i.e. `states` and the right-hand-side of `observed`.

eqs = [0 ~ z + x; 0 ~ y + z^2]
states = [y, z]
observed = [x ~ sin(y) + z]
struct Reduced
    var
    expr
    idxs
end
fullvars = [Reduced(x, sin(y) + z, [2, 3]), y, z]
active_𝑣vertices = [false, true, true]
      x   y   z
eq1:  1       1
eq2:      1   1

      x   y   z
eq1:      1   1
eq2:      1   1

for v in 𝑣vertices(graph); active_𝑣vertices[v] || continue

end
=#

export SystemStructure, initialize_system_structure
export diffvars_range, dervars_range, algvars_range
export isdiffvar, isdervar, isalgvar, isdiffeq, isalgeq
export DIFFERENTIAL_VARIABLE, ALGEBRAIC_VARIABLE, DERIVATIVE_VARIABLE
export DIFFERENTIAL_EQUATION, ALGEBRAIC_EQUATION
export vartype, eqtype

struct SystemStructure
    dxvar_offset::Int
    fullvars::Vector # [diffvars; dervars; algvars]
    varassoc::Vector{Int}
    algeqs::BitVector
    graph::BipartiteGraph{Int,Nothing}
    solvable_graph::BipartiteGraph{Int,Vector{Vector{Int}}}
    is_linear_equations::BitVector
    assign::Vector{Int}
    inv_assign::Vector{Int}
    scc::Vector{Vector{Int}}
    partitions::Vector{NTuple{4, Vector{Int}}}
end

diffvars_range(s::SystemStructure) = 1:s.dxvar_offset
# TODO: maybe dervars should be in the end.
dervars_range(s::SystemStructure) = s.dxvar_offset+1:2s.dxvar_offset
algvars_range(s::SystemStructure) = 2s.dxvar_offset+1:length(s.fullvars)

isdiffvar(s::SystemStructure, var::Integer) = var in diffvars_range(s)
isdervar(s::SystemStructure, var::Integer) = var in dervars_range(s)
isalgvar(s::SystemStructure, var::Integer) = var in algvars_range(s)

@enum VariableType DIFFERENTIAL_VARIABLE ALGEBRAIC_VARIABLE DERIVATIVE_VARIABLE

function vartype(s::SystemStructure, var::Integer)::VariableType
    isdiffvar(s, var) ? DIFFERENTIAL_VARIABLE :
    isdervar(s, var)  ? DERIVATIVE_VARIABLE :
    isalgvar(s, var)  ? ALGEBRAIC_VARIABLE : error("Variable $var out of bounds")
end

@enum EquationType DIFFERENTIAL_EQUATION ALGEBRAIC_EQUATION

isalgeq(s::SystemStructure, eq::Integer) = s.algeqs[eq]
isdiffeq(s::SystemStructure, eq::Integer) = !isalgeq(s, eq)
eqtype(s::SystemStructure, eq::Integer)::EquationType = isalgeq(s, eq) ? ALGEBRAIC_EQUATION : DIFFERENTIAL_EQUATION

function initialize_system_structure(sys)
    sys, dxvar_offset, fullvars, varassoc, algeqs, graph = init_graph(flatten(sys))

    solvable_graph = BipartiteGraph(neqs, nvars, metadata=map(_->Int[], 1:nsrcs(graph)))

    @set sys.structure = SystemStructure(
                                         dxvar_offset,
                                         fullvars,
                                         varassoc,
                                         algeqs,
                                         graph,
                                         solvable_graph,
                                         falses(ndsts(graph)),
                                         Int[],
                                         Int[],
                                         Vector{Int}[],
                                         NTuple{4, Vector{Int}}[]
                                        )
end

function Base.show(io::IO, s::SystemStructure)
    @unpack fullvars, dxvar_offset, solvable_graph, graph = s
    algvar_offset = 2dxvar_offset
    print(io, "xvars: ")
    print(io, fullvars[1:dxvar_offset])
    print(io, "\ndxvars: ")
    print(io, fullvars[dxvar_offset+1:algvar_offset])
    print(io, "\nalgvars: ")
    print(io, fullvars[algvar_offset+1:end], '\n')

    S = incidence_matrix(graph, Num(Sym{Real}(:×)))
    print(io, "Incidence matrix:")
    show(io, S)
end

function init_graph(sys)
    iv = independent_variable(sys)
    eqs = equations(sys)
    neqs = length(eqs)
    algeqs = trues(neqs)
    varsadj = Vector{Any}(undef, neqs)
    dervars = OrderedSet()
    diffvars = OrderedSet()

    for (i, eq) in enumerate(eqs)
        vars = OrderedSet()
        vars!(vars, eq)
        isalgeq = true
        for var in vars
            if istree(var) && operation(var) isa Differential
                isalgeq = false
                diffvar = arguments(var)[1]
                @assert !(diffvar isa Differential) "The equation [ $eq ] is not first order"
                push!(dervars, var)
                push!(diffvars, diffvar)
            end
        end
        algeqs[i] = isalgeq
        varsadj[i] = vars
    end

    algvars  = setdiff(states(sys), diffvars)
    fullvars = [collect(diffvars); collect(dervars); algvars]

    dxvar_offset = length(diffvars)
    algvar_offset = 2dxvar_offset

    nvars = length(fullvars)
    idxmap = Dict(fullvars .=> 1:nvars)
    graph = BipartiteGraph(neqs, nvars)

    vs = Set()
    for (i, eq) in enumerate(eqs)
        # TODO: custom vars that handles D(x)
        # TODO: add checks here
        lhs = eq.lhs
        if isdiffeq(eq)
            v = lhs
            haskey(idxmap, v) && add_edge!(graph, i, idxmap[v])
        else
            vars!(vs, lhs)
        end
        vars!(vs, eq.rhs)
        for v in vs
            haskey(idxmap, v) && add_edge!(graph, i, idxmap[v])
        end
        empty!(vs)
    end

    varassoc = Int[(1:dxvar_offset) .+ dxvar_offset; zeros(Int, length(fullvars) - dxvar_offset)] # variable association list
    sys, dxvar_offset, fullvars, varassoc, algeqs, graph
end

function find_solvables!(sys)
    s = structure(sys)
    @unpack fullvars, graph, solvable_graph, is_linear_equations = s
    eqs = equations(sys)
    empty!(solvable_graph)
    for (i, eq) in enumerate(eqs); isdiffeq(eq) && continue
        term = value(eq.rhs - eq.lhs)
        linear_term = 0
        all_int_algvars = true
        for j in 𝑠neighbors(graph, i)
            if !isalgvar(s, j)
                all_int_algvars = false
                continue
            end
            var = fullvars[j]
            c = expand_derivatives(Differential(var)(term), false)
            # test if `var` is linear in `eq`.
            if !(c isa Symbolic) && c isa Number && c != 0
                if isinteger(c)
                    c = convert(Integer, c)
                else
                    all_int_algvars = false
                end
                linear_term += c * var
                add_edge!(solvable_graph, i, j, c)
            end
        end

        # Check if there are only algebraic variables and the equation is both
        # linear and homogeneous, i.e. it is in the form of
        #
        #       ``∑ c_i * a_i = 0``,
        #
        # where ``c_i`` ∈ ℤ and ``a_i`` denotes algebraic variables.
        if all_int_algvars && isequal(linear_term, term)
            is_linear_equations[i] = true
        else
            # We use 0 as a sentinel value for a nonlinear or non-integer term.

            # Don't move the reference, because it might lead to pointer
            # invalidations.
            is_linear_equations[i] = false
            fill!(solvable_graph.metadata[i], 0)
        end
    end
    s
end

end # module
