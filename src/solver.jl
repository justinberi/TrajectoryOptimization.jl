include("solver_options.jl")
import Base: copy, length, size

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# FILE CONTENTS:
#     SUMMARY: Solver type and related methods
#
#     TYPES
#         Solver
#
#     METHODS
#         is_inplace_dynamics: Checks if dynamics in Model are in-place
#         wrap_inplace: Makes non-inplace dynamics look in-place
#         getR: Return the quadratic control state cost (augmented if necessary)
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

"""
$(TYPEDEF)
Contains all information to solver a trajectory optimization problem.

The Solver type is immutable so is unique to the particular problem. However,
anything in `Solver.opts` can be changed dynamically.
"""
struct Solver
    model::Model         # Dynamics model
    obj::Objective       # Objective (cost function and constraints)
    opts::SolverOptions  # Solver options (iterations, method, convergence criteria, etc)
    dt::Float64          # Time step
    fd::Function         # Discrete in place dynamics function, `fd(_,x,u)`
    Fd::Function         # Jacobian of discrete dynamics, `fx,fu = F(x,u)`
    fc::Function         # Continuous dynamics function (inplace)
    Fc::Function         # Jacobian of continuous dynamics
    c_fun::Function
    c_jacobian::Function
    N::Int64             # Number of time steps
    integration::Symbol
    control_integration::Symbol

    function Solver(model::Model, obj::Objective; integration::Symbol=:rk4, dt=0.01, opts::SolverOptions=SolverOptions(), infeasible=false)
        N, dt = calc_N(obj.tf, dt)
        n, m = model.n, model.m
        #
        # # Make dynamics inplace
        # if is_inplace_dynamics(model)
        #     f! = model.f
        # else
        #     f! = wrap_inplace(model.f)
        # end
        f! = model.f # checked in model now

        # Get integration scheme
        if isdefined(TrajectoryOptimization,integration)
            discretizer = eval(integration)
        else
            throw(ArgumentError("$integration is not a defined integration scheme"))
        end

        # Determine control integration type
        if integration == :rk3_foh # add more foh options as necessary
            control_integration = :foh
        else
            control_integration = :zoh
        end

        # Generate discrete dynamics equations
        fd! = discretizer(f!, dt)
        f_aug! = f_augmented!(f!, model.n, model.m)

        if control_integration == :foh
            fd_aug! = f_augmented_foh!(fd!,model.n,model.m)
            nm1 = model.n + model.m + model.m + 1
        else
            fd_aug! = discretizer(f_aug!)
            nm1 = model.n + model.m + 1
        end

        # Initialize discrete and continuous dynamics Jacobians
        Jd = zeros(nm1, nm1)
        Sd = zeros(nm1)
        Sdotd = zero(Sd)
        Fd!(Jd,Sdotd,Sd) = ForwardDiff.jacobian!(Jd,fd_aug!,Sdotd,Sd)

        Jc = zeros(model.n+model.m,model.n+model.m)
        Sc = zeros(model.n+model.m)
        Scdot = zero(Sc)
        Fc!(Jc,dS,S) = ForwardDiff.jacobian!(Jc,f_aug!,dS,S)

        function Jacobians_Discrete!(x,u,v=zeros(size(u)))
            infeasible = length(u) != m

            Sd[1:n] = x
            Sd[n+1:n+m] = u[1:m]

            if control_integration == :foh
                Sd[n+m+1:n+m+m] = v[1:m]
            end

            Sd[end] = dt

            Fd!(Jd,Sdotd,Sd)

            if control_integration == :foh
                if infeasible
                    return Jd[1:model.n,1:model.n], [Jd[1:model.n,model.n+1:model.n+model.m] I], [Jd[1:model.n,model.n+model.m+1:model.n+model.m+model.m] I] # fx, [fu I], [fv I]
                else
                    return Jd[1:model.n,1:model.n], Jd[1:model.n,model.n+1:model.n+model.m], Jd[1:model.n,model.n+model.m+1:model.n+model.m+model.m] # fx, fu, fv
                end
            else
                if infeasible
                    return Jd[1:model.n,1:model.n], [Jd[1:model.n,model.n+1:model.n+model.m] I] # fx, [fu I]
                else
                    return Jd[1:model.n,1:model.n], Jd[1:model.n,model.n+1:model.n+model.m] # fx, fu
                end
            end
        end

        function Jacobians_Continuous!(x,u)
            infeasible = size(u,1) != model.m
            Sc[1:model.n] = x
            Sc[model.n+1:model.n+model.m] = u[1:model.m]
            Fc!(Jc,Scdot,Sc)

            if infeasible
                return Jc[1:model.n,1:model.n], [Jc[1:model.n,model.n+1:model.n+model.m] zeros(model.n,model.n)] # fx, [fu 0]
            else
                return Jc[1:model.n,1:model.n], Jc[1:model.n,model.n+1:model.n+model.m] # fx, fu
            end
        end

        function Jacobians_Continuous!(z)
            Fc!(Jc,Scdot,z)
            return Jc[1:n,:]
        end

        # Generate constraint functions
        c_fun, c_jacob = generate_constraint_functions(obj)

        # Copy solver options so any changes don't modify the options passed in
        options = copy(opts)

        new(model, obj, options, dt, fd!, Jacobians_Discrete!, model.f, Jacobians_Continuous!, c_fun, c_jacob, N, integration, control_integration)
    end
end

function Solver(solver::Solver; model=solver.model, obj=solver.obj,
        integration=solver.integration, dt=solver.dt, opts=solver.opts)
     Solver(model, obj, integration=integration, dt=dt, opts=opts)
 end

function calc_N(tf::Float64, dt::Float64)::Tuple
    N = convert(Int64,floor(tf/dt)) + 1
    dt = tf/(N-1)
    return N, dt
end

"""
$(SIGNATURES)
Return the quadratic control stage cost R

If using an infeasible start, will return the augmented cost matrix
"""
function getR(solver::Solver)::Array{Float64,2}
    if solver.opts.infeasible
        R = solver.opts.infeasible_regularization*tr(solver.obj.R)*Diagonal(I,solver.model.m+solver.model.n)
        R[1:solver.model.m,1:solver.model.m] = solver.obj.R
        return R
    else
        return solver.obj.R
    end
end
