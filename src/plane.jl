import Pkg; Pkg.activate(joinpath(@__DIR__,".."))
using TrajectoryOptimization
using Altro
using RobotZoo
using RobotDynamics
using StaticArrays
using LinearAlgebra
using Rotations
using Plots
using TrajOptPlots
using MeshCat
using Blink
using Colors
using ForwardDiff
const RD = RobotDynamics
const TO = TrajectoryOptimization

include("costfuns.jl")
include("ilqr.jl")

function slerp(qa::UnitQuaternion{T}, qb::UnitQuaternion{T}, t::T) where {T}
    # http://www.euclideanspace.com/maths/algebra/realNormedAlgebra/quaternions/slerp/
    coshalftheta = qa.w * qb.w + qa.x * qb.x + qa.y * qb.y + qa.z * qb.z;

    if coshalftheta < 0
        qm = -qb
        coshalftheta = -coshalftheta
    else
        qm = qb
    end
    abs(coshalftheta) >= 1.0 && return qa

    halftheta    = acos(coshalftheta)
    sinhalftheta = sqrt(one(T) - coshalftheta * coshalftheta)

    if abs(sinhalftheta) < 0.001
        return Quaternion(
            T(0.5) * (qa.w + qb.w),
            T(0.5) * (qa.x + qb.x),
            T(0.5) * (qa.y + qb.y),
            T(0.5) * (qa.z + qb.z),
        )
    end

    ratio_a = sin((one(T) - t) * halftheta) / sinhalftheta
    ratio_b = sin(t * halftheta) / sinhalftheta

    UnitQuaternion(
        qa.w * ratio_a + qm.w * ratio_b,
        qa.x * ratio_a + qm.x * ratio_b,
        qa.y * ratio_a + qm.y * ratio_b,
        qa.z * ratio_a + qm.z * ratio_b,
    )
end

function YakProblems(;
        N = 101,
        vecstate=false,
        scenario=:barrellroll, 
        heading=0.0,  # deg
        Qpos=1.0,
        kwargs...
    )
    model = RobotZoo.YakPlane(UnitQuaternion)

    n,m = size(model)
    ip = SA[1,2,3]
    iq = SA[4,5,6,7]
    iv = SA[8,9,10]
    iw = SA[11,12,13]

    # Discretization
    tf = 1.25
    if scenario == :fullloop 
        tf *= 2
        N = (N-1)*2 + 1
    end
    dt = tf/(N-1)

    # Initial and final orientation 
    vel = 5.0

    if scenario ∈ (:halfloop, :fullloop) 
        ey = @SVector [0,1,0.]

        # Heading
        dq = expm(SA[0,0,1]*deg2rad(heading))
        # pf = pf * dq

        # Initial state
        p0 = MRP(0.997156, 0., 0.075366) # initial orientation (level flight)
        x0 = RD.build_state(model, [-3,0,1.5], p0, [vel,0,0], [0,0,0])

        # Climb
        pm = expm(SA[1,0,0]*deg2rad(180))*expm(SA[0,1,0]*deg2rad(90))
        xm = RD.build_state(model, [0,0,3.], pm, pm * [vel,0,0.], [0,0,0])

        # Top of loop
        pf = MRP(0., -0.0366076, 0.) * dq # final orientation (upside down)
        xf = RD.build_state(model, dq*[3,0,6.], pf, pf * [vel,0,0.], [0,0,0])
        pf2 = RotZ(deg2rad(heading-180))

        # Dive
        xm2 = RD.build_state(model, [-3,3,4.], pm * RotY(pi), [0,0,-vel], [0,0,0])

        # Terminal state
        xf2 = RD.build_state(model, [0,4,1.5], p0, [vel,0,0], [0,0,0])

        t_flat = 5 / (xf[2] - xf[1])
        N_flat = Int(round(t_flat/dt))

        # Xref trajectory
        x̄0 = RBState(model, x0)
        x̄m = RBState(model, xm)
        x̄m2 = RBState(model, xm2)
        x̄f = RBState(model, xf)
        x̄f2 = RBState(model, xf2)
        Xref = map(1:N) do k
            t = (k-1)/(N-1)
            Nmid = N ÷ 4
            if scenario == :fullloop
                if k < Nmid
                    x1 = x̄0
                    x2 = x̄m
                    t = (k-1)/Nmid
                elseif k < 2Nmid
                    t = (k-Nmid)/Nmid
                    x1 = x̄m
                    x2 = x̄f 
                elseif k < 3Nmid
                    t = (k-2Nmid)/Nmid
                    x1 = x̄f
                    x2 = x̄m2
                else
                    t = (k-3Nmid)/Nmid
                    x1 = x̄m2
                    x2 = x̄f2
                end
            else
                if k < 2Nmid
                    t = (k-1)/2Nmid
                    x1 = x̄0
                    x2 = x̄m
                else
                    t = (k-2Nmid)/(2Nmid+1)
                    x1 = x̄m
                    x2 = x̄f
                end
            end
            RBState(
                x1.r + (x2.r - x1.r)*t,
                slerp(x1.q, x2.q, t),
                x1.v + (x2.v - x1.v)*t,
                SA[0,pi/1.25,0]
            )
        end
    else
        throw(ArgumentError("$scenario isn't a known scenario"))
    end

    # Get trim condition
    utrim = get_trim(model, x0, fill(124, 4))

    # Objective
    Qf_diag = RD.fill_state(model, 10, 500*0, 100, 100.)
    Q_diag = RD.fill_state(model, Qpos*0.1, 0.1*0, 0.1, 1.1)
    R = Diagonal(@SVector fill(1e-3,4))
    costs = map(1:N-1) do k
        RigidBodyCost(
            Diagonal(Q_diag[ip])*dt,
            10.0*dt, 
            Diagonal(Q_diag[iv])*dt,
            Diagonal(Q_diag[iw])*dt,
            R*dt,
            Xref[k][ip],
            Xref[k][iq],
            Xref[k][iv],
            Xref[k][iw],
            utrim
        )
    end
    costterm = RigidBodyCost(
            Diagonal(Qf_diag[ip]),
            200.0, 
            Diagonal(Qf_diag[iv]),
            Diagonal(Qf_diag[iw]),
            R*0,
            Xref[N][ip],
            Xref[N][iq],
            Xref[N][iv],
            Xref[N][iw],
            utrim
        )
    push!(costs, costterm)

    # Build problem
    prob = iLQRProblem(model, costs, tf, x0)

    return prob, Xref, utrim
end

function get_trim(model, x_trim, u_guess;
        tol = 1e-4,
        iters = 100,
    )
    x̄ = RBState(model, x_trim)
    ṙ = x̄.v 
    q̇ = Rotations.kinematics(x̄.q, x̄.ω)
    a = zeros(3)
    α = zeros(3)
    v_trim = [ṙ; q̇; a; α]
    n,m = size(model)
    G = zeros(n,n-1)
    RobotDynamics.state_diff_jacobian!(G, model, x_trim)

    iu = SVector{m}(1:m)
    ic = SVector{6}(m .+ (1:6))
    ia = SVector{6}(1:6) .+ 7
    ∇f(u) = ForwardDiff.jacobian(u_->dynamics(model, x_trim, u_), u)[ia,:]

    r(z) = [z[iu] - u_guess + ∇f(z[iu])'z[ic]; dynamics(model, x_trim, z[iu])[ia] ]
    ∇r(z) = begin
        u,λ = z[iu], z[ic] 
        B = ∇f(u)
        [I B'; B -I(6)*1e-6]
    end
    # r([u_guess; @SVector zeros(n-1)])
    λ = @SVector zeros(6)
    z = [u_guess; λ]

    for i = 1:iters
        res = r(z)
        println(norm(res))
        if norm(res) < tol 
            println("converged in $i iterations")
            break
        end
        R = ∇r(z) 
        # display(R)
        dz = -(R \ res)
        z += dz
    end
    return z[iu]
end

function rollout(model, x0::StaticVector{n}, U, times) where n
    N = length(U0) + 1
    X = [@SVector zeros(n) for k = 1:N]
    X[1] = x0
    for k = 1:N-1
        dt = times[k+1] - times[k]
        X[k+1] = discrete_dynamics(RK4, model, X[k], U[k], times[k], dt)
    end
    return X
end

## Launch Visualizer
vis = Visualizer()
open(vis, Blink.Window())
delete!(vis)
model = RobotZoo.YakPlane(UnitQuaternion)
TrajOptPlots.set_mesh!(vis, model, color=colorant"yellow")


##
# utrim = get_trim(prob.model, x0, fill(100,4), tol=1e-4)
prob_half, Xref_half, utrim = YakProblems(costfun=:QuatLQR, scenario=:halfloop, heading=130)
U0 = [copy(utrim) for k = 1:prob_half.T-1]
X0 = rollout(prob_half.model, prob_half.x0, U0, prob_half.times)
plot(X0, inds=1:3)
visualize!(vis, prob_half.model, prob_half.tf, Xref)

Xhalf, Uhalf = solve_ilqr(prob_half, X0, U0, verbose=1, eps=1e-4, reg_min=1e-6)
visualize!(vis, prob_half.model, prob_half.tf, Xhalf)

##
prob, Xref2 = YakProblems(costfun=:QuatLQR, scenario=:fullloop, heading=130, Qpos=100)
visualize!(vis, prob.model, prob.tf, Xref2)

# Design initial control
U0 = [copy(utrim) for k = 1:prob.T-1]
for k = 1:length(Uhalf)
    U0[k] = Uhalf[k]
end
U0[1+length(Uhalf):end] .= reverse(Uhalf)
X0 = rollout(prob.model, prob.x0, U0, prob.times)
visualize!(vis, prob.model, prob.tf, X0)

# Solve
Xfull, Ufull = solve_ilqr(prob, X0, U0, verbose=1, eps=1e-2, reg_min=1e-8, iters=500)
visualize!(vis, prob.model, prob.tf, Xfull)
