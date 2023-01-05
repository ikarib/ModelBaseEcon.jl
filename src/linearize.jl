##################################################################################
# This file is part of ModelBaseEcon.jl
# BSD 3-Clause License
# Copyright (c) 2020-2022, Bank of Canada
# All rights reserved.
##################################################################################

"""
    linearize!(model::Model; <keyword arguments>)

Transform model into its linear approximation about its steady state.

### Keyword arguments
  * `sstate` - linearize about the provided steady state solution
  * `deviation`::Bool - whether or not the linearized model will treat data
    passed to it as deviation from the steady state

See also: [`linearized`](@ref) and [`with_linearized`](@ref)
"""
function linearize! end
export linearize!


"""
    LinearizedModelEvaluationData <: AbstractModelEvaluationData

Model evaluation data for the linearized model.
"""
struct LinearizedModelEvaluationData <: AbstractModelEvaluationData
    deviation::Bool
    sspt::Array{Float64,2}
    med::ModelEvaluationData
end

"""
    islinearized(model::Model)

Return `true` if the given model is linearized and `false` otherwise.
"""
islinearized(model::Model) = hasevaldata(model, :linearize)
export islinearized

# Specialize eval_R! for the new model evaluation type
function eval_R!(res::AbstractVector{Float64}, point::AbstractMatrix{Float64}, lmed::LinearizedModelEvaluationData)
    med = lmed.med
    if lmed.deviation
        res .= med.R .+ med.J * vec(point)
    else
        res .= med.R .+ med.J * vec(point .- lmed.sspt)
    end
    return nothing
end

# Specialize eval_RJ for the new model evaluation type
function eval_RJ(point::AbstractMatrix{Float64}, lmed::LinearizedModelEvaluationData)
    med = lmed.med
    RES = similar(med.R)
    if lmed.deviation
        RES .= med.R .+ med.J * vec(point)
    else
        RES .= med.R .+ med.J * vec(point - lmed.sspt)
    end
    return RES, med.J
end


"""
    LinearizationError <: ModelErrorBase

A concrete error type used when a model cannot be linearized for some reason.
"""
struct LinearizationError <: ModelErrorBase
    reason
    hint::String
    LinearizationError(r) = new(r, "")
    LinearizationError(r, h) = new(r, string(h))
end
msg(le::LinearizationError) = "Cannot linearize model because $(le.reason)"
hint(le::LinearizationError) = le.hint
# export LinearizationError

linearizationerror(args...) = modelerror(LinearizationError, args...)

export linearize!
function linearize!(model::Model;
    # Idea:
    # 
    # We compute the residual and the Jacobian matrix at the steady state and 
    # store them in the model evaluation data. We store that into our new
    # linearized model evaluation data, which we place in the Model instance.
    # When we evaluate the linearized model residual, all we need to do is multiply 
    # the stored steady state Jacobian by the deviation of the given point from 
    # the steady state and add the stored steady state residual.

    sstate::SteadyStateData=model.sstate,
    deviation::Bool=false)

    if !isempty(model.auxvars) || !isempty(model.auxeqns)
        linearizationerror("there are auxiliary variables.",
            "Try setting `model.options.substitutions=false` in your model file.")
    end
    if !all(sstate.mask)
        linearizationerror("the steady state is unknown.", "Solve for the steady state first.")
    end
    if maximum(abs, sstate.values[2:2:end]) > 1e-10
        linearizationerror("the steady state has a non-zero linear growth.")
    end

    # We need a ModelEvaluationData in order to proceed
    med = ModelEvaluationData(model)

    ntimes = 1 + model.maxlag + model.maxlead
    nvars = length(model.variables)
    nshks = length(model.shocks)
    sspt = [repeat(sstate.values[1:2:(2nvars)], inner=ntimes); zeros(ntimes * nshks)]
    sspt = reshape(sspt, ntimes, nvars + nshks)

    res, _ = eval_RJ(sspt, med)  # updates med.J in place, returns updated R and J
    med.R .= res

    setevaldata!(model, linearize=LinearizedModelEvaluationData(deviation, sspt, med))
    return model
end
@assert precompile(linearize!, (Model,))
@assert precompile(deepcopy, (Model,))


export linearized
"""
    linearized(model::Model; <arguments>)

Create a new model that is the linear approximation of the given model about its steady state.

### Keyword arguments
  * `sstate` - linearize about the provided steady state solution
  * `deviation`::Bool - whether or not the linearized model will tread data passed 
to is as deviation from the steady state

See also: [`linearize!`](@ref) and [`with_linearized`](@ref)
"""
linearized(model::Model; kwargs...) = linearize!(deepcopy(model); kwargs...)

export with_linearized
"""
    with_linearized(F::Function, model::Model; <arguments>)

Apply the given function on a new model that is the linear approximation 
of the given model about its steady state.  This is meant to be used
with the `do` syntax, as in the example below.

### Keyword arguments
  * `sstate` - linearize about the provided steady state solution
  * `deviation`::Bool - whether or not the linearized model will tread data passed 
to is as deviation from the steady state

See also: [`linearize!`](@ref) and [`with_linearized`](@ref)

### Example

```julia
with_linearized(m) do lm
    # do something awesome with linearized model `lm`
end
# model `m` is still non-linear.
```
"""
function with_linearized(F::Function, model::Model; kwargs...)
    # store the evaluation data
    which = model.options.which
    lmed = get(model.evaldata, :linearize, nothing)
    ret = try
        # linearize 
        linearize!(model; kwargs...)
        # do what we have to do
        F(model)
    catch
        # restore the original model evaluation data
        if lmed === nothing
            delete!(model.evaldata, :linearize)
        else
            setevaldata!(model, linearize=lmed)
        end
        model.options.which = which
        rethrow()
    end
    if lmed === nothing
        delete!(model.evaldata, :linearize)
    else
        setevaldata!(model, linearize=lmed)
    end
    model.options.which = which
    return ret
end

refresh_med!(m::AbstractModel, ::Val{:linearize}) = linearize!(m; deviation=getevaldata(m, :linearize).deviation)
