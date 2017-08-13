import JuMP
import Ipopt

const defaultregularizationweight = convert(Float32, 0)
const defaultmaxiter = 1000
const defaultverbosity = 0

"Factorize matrix X (X = W * H)"
function ipopt(X_in::Matrix{Float64}, nk::Int; kw...)
	ipopt(convert(Array{Float32, 2}, X_in), nk; kw...)
end
function ipopt(X_in::Matrix{Float32}, nk::Int; normalize::Bool=false, scale::Bool=false, random::Bool=true, maxiter::Int=defaultmaxiter, verbosity::Int=defaultverbosity, regularizationweight::Float32=defaultregularizationweight, weightinverse::Bool=false, initW::Matrix{Float32}=Array{Float32}(0, 0), initH::Matrix{Float32}=Array{Float32}(0, 0), tolX::Float64=1e-3, tol::Float64=1e-19, maxouteriters::Int=10, quiet::Bool=true)
	X = copy(X_in) # we may overwrite some of the fields if there are NaN's, so make a copy
	if normalize
		X, cmin, cmax = normalizematrix(X)
	elseif scale
		X, cmax = scalematrix(X)
	end
	if weightinverse
		obsweights = convert(Array{Float32,2}, 1. ./ X)
		zis = X .== 0
		obsweights[zis] = maximum(X[!zis]) * 10
	else
		obsweights = ones(Float32, size(X))
	end
	nans = isnan(X)
	X[nans] = 0
	obsweights[nans] = 0
	nummixtures = size(X, 1)
	numconstituents = size(X, 2)
	if sizeof(initW) == 0
		if random
			initW = rand(Float32, nummixtures, nk)
		else
			initW = ones(Float32, nummixtures, nk) / nk
		end
	end
	if sizeof(initH) == 0
		if random
			if !scale || !normalize
				initH = rand(Float32, nk, numconstituents)
			else
				max = maximum(X, 1)
				initH = rand(Float32, nk, numconstituents)
				for i=1:nk
					initH[i:i,:] .*= max
				end
			end
		else
			if !scale || !normalize
				initH = ones(Float32, nk, numconstituents) / 2
			else
				max = maximum(X, 1)
				initH = Array{Float32}(nk, numconstituents)
				for i=1:nk
					initH[i:i,:] = max
				end
			end
		end
	end
	m = JuMP.Model(solver=Ipopt.IpoptSolver(max_iter=maxiter, print_level=verbosity))
	#IMPORTANT the order at which parameters are defined is very important
	@JuMP.variable(m, W[i=1:nummixtures, j=1:nk] >= 0., start = convert(Float32, initW[i, j]))
	@JuMP.variable(m, H[i=1:nk, j=1:numconstituents] >= 0., start = convert(Float32, initH[i, j]))
	@JuMP.constraint(m, W .<= 1) # this is very important constraint to make optimization faster
	@JuMP.NLobjective(m, Min,
		regularizationweight * sum(sum(log(1. + H[i, j])^2 for i=1:nk) for j=1:numconstituents) / nk +
		sum(sum(obsweights[i, j] * (sum(W[i, k] * H[k, j] for k=1:nk) - X[i, j])^2 for i=1:nummixtures) for j=1:numconstituents))
	oldcolval = copy(m.colVal)
	JuMP.solve(m)
	Wbest = JuMP.getvalue(W)
	Hbest = JuMP.getvalue(H)
	of = JuMP.getobjectivevalue(m)
	!quiet && @show of
	ofbest = of
	objvalue = ofbest - regularizationweight * sum(log(1. + Hbest).^2) / nk
	while !(norm(oldcolval - m.colVal) < tolX) && !(objvalue < tol)
		oldcolval = copy(m.colVal)
		JuMP.solve(m)
		of = JuMP.getobjectivevalue(m)
		if of < ofbest
			Wbest = JuMP.getvalue(W)
			Hbest = JuMP.getvalue(H)
			ofbest = of
		end
		objvalue = ofbest - regularizationweight * sum(log(1. + Hbest).^2) / nk
		!quiet && @show of, norm(oldcolval - m.colVal), objvalue
	end
	!quiet && @show ofbest
	objvalue = ofbest - regularizationweight * sum(log(1. + Hbest).^2) / nk
	if normalize
		Hbest = denormalizematrix(Hbest, Wbest, cmin, cmax)
	elseif scale
		Hbest = descalematrix(Hbest, cmax)
	end
	return Wbest, Hbest, objvalue
end