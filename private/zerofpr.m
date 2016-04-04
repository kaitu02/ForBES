% Copyright (C) 2015, Lorenzo Stella and Panagiotis Patrinos
%
% This file is part of ForBES.
% 
% ForBES is free software: you can redistribute it and/or modify
% it under the terms of the GNU Lesser General Public License as published by
% the Free Software Foundation, either version 3 of the License, or
% (at your option) any later version.
% 
% ForBES is distributed in the hope that it will be useful,
% but WITHOUT ANY WARRANTY; without even the implied warranty of
% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
% GNU Lesser General Public License for more details.
% 
% You should have received a copy of the GNU Lesser General Public License
% along with ForBES. If not, see <http://www.gnu.org/licenses/>.

function out = zerofpr(prob, opt)

% initialize output stuff
ts = zeros(1, opt.maxit);
taus = zeros(1, opt.maxit);
residual = zeros(1, opt.maxit);
objective = zeros(1, opt.maxit);
msgTerm = '';

% initialize operations counter
ops = OpsInit();

% initialize stuff
gam = SelectGamma(prob, opt);

% display header
if opt.display >= 2
    fprintf('%6s%11s%11s%11s%11s\n', 'iter', 'gamma', 'optim.', 'object.', 'tau');
end

if opt.toRecord
    record = [];
end

alpha = 0.5;
thetabar = 0.1;
flag = -1; % to track what happened at every iteration
flagTerm = 0;

MAXIMUM_Lf = 1e15;
MINIMUM_tau = 1e-15;
MINIMUM_d = 1e-15;

t0 = tic();

cache_current = CacheInit(prob, prob.x0, gam);
[cache_current, ops1] = CacheProxGradStep(cache_current, gam);
ops = OpsSum(ops, ops1);
cache_0 = cache_current;

for it = 1:opt.maxit
    
    flagGamma = 0;
    
    % backtracking on gamma
    
    cache_z = CacheInit(prob, cache_current.z, gam);
    
    if prob.unknownLf || opt.adaptive
        [cache_z, ops1] = CacheEvalf(cache_z);
        ops = OpsSum(ops, ops1);
        while cache_z.fx > cache_current.fx ...
                + cache_current.gradfx'*cache_current.diff ...
                + prob.Lf/2*cache_current.normdiff^2
            if prob.Lf >= MAXIMUM_Lf, break; end
            prob.Lf = 2*prob.Lf;
            gam = SelectGamma(prob, opt);
            flagGamma = 1;
            [cache_current, ops1] = CacheProxGradStep(cache_current, gam);
            ops = OpsSum(ops, ops1);
            cache_z = CacheInit(prob, cache_current.z, gam);
            [cache_z, ops1] = CacheEvalf(cache_z);
            ops = OpsSum(ops, ops1);
        end
    end
    
    % adjust sigma
    
    sig = SelectSigma(prob, opt, gam);
    
    if prob.Lf >= MAXIMUM_Lf
        msgTerm = ['estimate for Lf became too large: ', num2str(prob.Lf)];
        flagTerm = 1;
        break;
    end
    
    % trace stuff
    
    ts(1, it) = toc(t0);
    residual(1, it) = norm(cache_current.diff, 'inf');
    if opt.toRecord
        record = [record, opt.record(prob, it, gam, cache_0, cache_current, ops)];
    end
    
    % compute FBE at current point
    % this should count zero operations if gamma hasn't changed
    [cache_current, ops1] = CacheFBE(cache_current, gam);
    ops = OpsSum(ops, ops1);
    
    objective(1,it) = cache_current.FBE;
    
    % check for termination
    
    if isnan(cache_current.normdiff)
        msgTerm = 'something went wrong';
        flagTerm = 1;
        break;
    end
    if ~flagGamma
        if residual(1, it) <= opt.tol
            msgTerm = 'reached optimum (up to tolerance)';
            flagTerm = 0;
            break;
        end
    end
    
    % select a direction
    
    [cache_z, ops1] = CacheProxGradStep(cache_z, gam);
    ops = OpsSum(ops, ops1);
    
    switch opt.method
        case 11 % Broyden
            if it == 1 || flagGamma
                R = eye(prob.n);
                d = cache_z.diff;
            else
                s = cache_current.x - cache_previous.x;
                y = cache_previous.diff-cache_current.diff;
                sts = s'*s;
                lambda = (R*y)'*s/sts;
                if abs(lambda) >= thetabar, theta = 1.0;
                else theta = (1-sign(lambda)*thetabar)/(1+lambda); end
                v = R*y-s;
                R = R - (theta/(sts+theta*(v'*s)))*(v*(s'*R));
                d = R*cache_z.diff;
            end
        case 12 % BFGS
            opt.optsL.UT = true; opt.optsL.TRANSA = true;
            opt.optsU.UT = true;
            if it == 1 || flagGamma
                d = cache_z.diff;
                R = eye(prob.n);
            else
                %%% x' - x %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
                Sk = cache_current.x - cache_previous.x;
                Yk = cache_previous.diff-cache_current.diff ;
                %%% other options (is this additional gradient eval needed?)
                YSk = Yk'*Sk;
                Bs = R'*(R*Sk);
                sBs = Sk'*Bs;
                if YSk>= 0.2*sBs
                    theta = 1;
                else
                    theta = (0.8*sBs)/(sBs-YSk);
                end
                r = theta*Yk + (1-theta)*Bs;
                R = cholupdate(cholupdate(R,r/sqrt(Sk'*r)),Bs/sqrt(sBs),'-');
%                 if YSk > 0
%                     R = cholupdate(cholupdate(R,Yk/sqrt(YSk)),Bs/sqrt(sBs),'-');
%                 else
%                     skipCount = skipCount+1;
%                 end
                d = linsolve(R,linsolve(R,cache_z.diff,opt.optsL),opt.optsU);
                %                     dir = -R\(R'\cache_current.gradFBE);
            end
        case 13
            if it == 1 || flagGamma
                alphaC = 0.01;
                d = cache_z.diff;
                skipCount = 0;
                LBFGS_col = 0;
                LBFGS_mem = 0;
            else
                %%% x' - x %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
                Sk = cache_current.x - cache_previous.x;
                Yk = cache_previous.diff-cache_current.diff;
                %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
                YSk = Yk'*Sk;
                if cache_current.normdiff<1
                    alphaC = 3;
                end
                if YSk/(Sk'*Sk) > 1e-6*cache_current.normdiff^alphaC
                    LBFGS_col = 1 + mod(LBFGS_col, opt.memory);
                    LBFGS_mem = min(LBFGS_mem+1, opt.memory);
                    S(:,LBFGS_col) = Sk;
                    Y(:,LBFGS_col) = Yk;
                    YS(LBFGS_col) = YSk;
                else
                    skipCount = skipCount+1;
                end
                if LBFGS_mem > 0
                    H = YS(LBFGS_col)/(Y(:,LBFGS_col)'*Y(:,LBFGS_col));
                    d = LBFGS(S, Y, YS, H, cache_z.diff, int32(LBFGS_col), int32(LBFGS_mem));
                else
                    d = cache_z.diff;
                end
            end
        case 14
            if it == 1 || flagGamma
                d = cache_z.diff;
                skipCount = 0;
                LB_col = 0;
                LB_mem = 0;
                S = zeros(length(d), opt.memory);
                Y = S;
                HY = S;
                YS = zeros(opt.memory, 1);
                SHY = zeros(opt.memory, 1);
            else
                Sk = cache_current.x - cache_previous.x;
                Yk = cache_previous.diff-cache_current.diff;
                LB_col      = 1 + mod(LB_col, opt.memory) ;
                LB_mem      = min(LB_mem+1, opt.memory) ;
                S(:,LB_col) = Sk;
                Y(:,LB_col) = Yk;
                HYk = Yk ;
                for jm = 0:LB_mem-2
                    j     = mod(LB_col+jm, LB_mem) + 1;
                    HYj  = HY(:,j);
                    Sj   = S(:,j);
                    SHyj = SHY(j);
                    HYk  = HYk + (Sj-HYj)*((Sj'*HYk)/SHyj);
                end
                HY(:,LB_col) = HYk;
                SHY(LB_col)  = Sk'*HYk;
                d = cache_z.diff;
                for jm = 1:LB_mem-1
                    j     = mod(LB_col+jm, LB_mem) + 1;
                    HYj  = HY(:,j);
                    Sj   = S(:,j);
                    SHyj = SHY(j);
                    d    = d + (Sj-HYj)*((Sj'*d)/SHyj);
                end

            end
        otherwise
            error('search direction not implemented');
    end
    
    % select a stepsize
    
    if norm(d) <= MINIMUM_d
        % if d is zero then tau = 0.0 and the algorithm becomes FBS
        tau = 0.0;
    else
        tau = 1.0;
    end
    
    while 1
        if tau ~= 0.0 && tau <= MINIMUM_tau
            msgTerm = strcat('tau became too small: ', num2str(tau));
            flagTerm = 1;
            break;
        end
        % compute candidate next point
        x = cache_current.z + tau*d;
        [cache_z, ~] = CacheFBE(cache_z, gam);
        % compute FBE at candidate next point
        cache_next = CacheInit(prob, x, gam);
        [cache_next, ops1] = CacheFBE(cache_next, gam);
        ops = OpsSum(ops, ops1);
        % check for sufficient decrease in the FBE
        if cache_next.FBE <= cache_current.FBE - sig*cache_current.normdiff^2
            cache_previous = cache_z;
            cache_current = cache_next;
            break;
        end
        tau = alpha*tau;
    end
    taus(1,it) = tau;
    if flagTerm == 1
        break;
    end

    % display stuff
    if opt.display == 1
        PrintProgress(it);
    elseif opt.display >= 2
        fprintf('%6d %7.4e %7.4e %7.4e %7.4e\n', it, gam, residual(1,it), objective(1,it), tau);
    end

end

if it == opt.maxit
    msgTerm = 'exceeded maximum iterations';
    flagTerm = 1;
end

if opt.display == 1
    PrintProgress(it, flagTerm);
end

% pack up results
out.name = opt.name;
out.message = msgTerm;
out.flag = flagTerm;
out.x = cache_current.z;
out.iterations = it;
out.operations = ops;
out.residual = residual(1, 1:it);
out.objective = objective(1, 1:it);
if opt.toRecord
    out.record = record(:, 1:it);
end
out.ts = ts(1, 1:it);
out.tau = taus(1, 1:it-1);
out.prob = prob;
out.opt = opt;
out.gam = gam;

function gam = SelectGamma(prob, opt)

gam = 0.95/prob.Lf;

function sig = SelectSigma(prob, opt, gam)

sig = (1-gam*prob.Lf)/(4*gam);