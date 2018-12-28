function out = fbtn(prob, opt, lsopt)

% initialize output stuff

if opt.report
    residual = zeros(1, opt.maxit);
    objective = zeros(1, opt.maxit);
    ts = zeros(1, opt.maxit);
    % initialize operations counter
    ops = FBOperations();
else
    ops = [];
end

% get Lipschitz constant & adaptiveness

[Lf, adaptive] = prob.Get_Lipschitz(opt);

% initialize gamma and sigma

gam = (1-opt.beta)/Lf;
sig = opt.beta/(4*gam);
% display header

if opt.display >= 2
    fprintf('\n%s', opt.name);
    fprintf('\n%6s%11s%11s%11s%11s%11s\n', 'iter', 'gamma', 'optim.', 'object.', '||d||', 'tau');
end

nonmonotone = strcmp(opt.linesearch, 'backtracking-nm');

cacheDir.cntSkip = 0;

msgTerm = 'exceeded maximum iterations';
flagTerm = 1;

restart = 0;

cache_x = FBCache(prob, prob.x0, gam, ops);


t0 = tic();

for it = 1:opt.maxit

    % backtracking on gamma

    if adaptive
        [restart, ~] = cache_x.Backtrack_Gamma(opt.beta);
        gam = cache_x.Get_Gamma();
        sig = opt.beta/(4*gam);
    end

    % trace stuff

    if it == 1
        cache_0 = cache_x;
    end

    if opt.report
        objective(1, it) = cache_x.Get_FBE();
        residual(1, it) = norm(cache_x.Get_FPR(), 'inf')/cache_x.Get_Gamma();
        ts(1, it) = toc(t0);
    end
    if opt.toRecord
        record(:, it) = opt.record(prob, it, cache_0, cache_x);
    end

    % check for termination

    if ~restart
        if ~opt.customTerm
            if cache_x.Check_StoppingCriterion(opt.tol)
                msgTerm = 'reached optimum (up to tolerance)';
                flagTerm = 0;
                break;
            end
        else
            %flagStop = opt.term(prob, it, cache_0, cache_x);
            flagStop = opt.term(prob, it, cache_0, cache_x,opt.hack,opt.H);
            if (adaptive == 0 || it > 1) && flagStop
                msgTerm = 'reached optimum (custom criterion)';
                flagTerm = 0;
                break;
            end
        end
    end

    % compute search direction and slope

    if it == 1 || restart
        sk = [];
        yk = [];
    end
    
    nu = 0.5;
    rho = 0.5;
    eta = 0.95;
    
    I          =  eye(length(prob.x0));
    gradient_f =  prob.C1'*(inv(opt.H)*(prob.C1*cache_x.x)+prob.q);
    Gk         =  prob.C1'*inv(opt.H)*prob.C1;
    Q_k        =  I - gam * Gk; 
    %gradphik   = Q_k*cache_x.Get_FPR(); 
    gradphik   = cache_x.Get_GradFBE();
    Hk         = (1/gam)*Q_k*(I - Q_k ) ;
    
    delta_k   = eta*norm(gradphik)^nu;
    Hk        = Hk + delta_k*I; 
    eta_k     = min(0.95,  norm(gradphik)^rho);
    epsilon_k = eta_k*norm(gradphik);
    
    maxit = 1000;
    dir_FB = -cache_x.Get_FPR();
    %alpha = max(sum(abs(Hk),2)./diag(Hk));
    alpha = 0.1;
    %incomplete_cholesky = ichol(sparse(Hk),struct('type','ict','droptol',1e-3,'diagcomp',alpha));
    dir_QN = pcg(Hk,dir_FB,epsilon_k,maxit);%,incomplete_cholesky,incomplete_cholesky',dir_FB);
    %[dir_QN, ~, cacheDir] = opt.methodfun(prob, opt, it, restart, sk, yk, cache_x.Get_FPR(), cacheDir);
    

    % perform line search

    tau = 1.0; % this *must* be 1.0 for this line-search to work
    cache_x.Set_Directions(dir_QN);
    cache_w = cache_x.Get_CacheLine(tau, 1);
    ls_ref = cache_x.Get_FBE() - sig*cache_x.Get_NormFPR()^2;
    
    if ~nonmonotone || it == 1 || restart
        lsopt.Q = 1;
        lsopt.C = ls_ref;
    else
        newQ = lsopt.eta*lsopt.Q+1;
        lsopt.C = (lsopt.eta*lsopt.Q*lsopt.C + ls_ref)/newQ;
        lsopt.Q = newQ;
    end
    
    if cache_w.Get_FBE() > lsopt.C
        cache_x.Set_Directions([], dir_FB);
    end
    while cache_w.Get_FBE() > lsopt.C
        if tau <= 1e-3
            % simply do forward-backward step if line-search fails
            cache_w = FBCache(prob, cache_x.Get_ProxGradStep(), gam, ops);
            % next line is for debugging purposes in case the code reaches this
            % cache_xbar = FBCache(prob, cache_x.Get_ProxGradStep(), gam, []);
            break;
        end
        tau = tau/2;
        cache_w = cache_x.Get_CacheSegment(tau);
    end

    % store pair (s, y) to compute next direction

%     sk = cache_w.Get_Point() - cache_x.Get_Point();
%     yk = cache_w.Get_FPR() - cache_x.Get_FPR();

    % update iterate

    cache_x = cache_w;

    % display stuff

    if opt.display == 1
        Util_PrintProgress(it);
    elseif (opt.display == 2 && mod(it,10) == 0) || opt.display >= 3
        res_curr = norm(cache_x.Get_FPR(), 'inf')/cache_x.Get_Gamma();
        obj_curr = cache_x.Get_FBE();
        fprintf('%6d %7.4e %7.4e %7.4e %7.4e %7.4e\n', it, gam, res_curr, obj_curr, norm(dir_QN), tau);
    end

end

time = toc(t0);

if opt.display == 1
    Util_PrintProgress(it, flagTerm);
elseif opt.display >= 2
    res_curr = norm(cache_x.Get_FPR(), 'inf')/cache_x.Get_Gamma();
    obj_curr = cache_x.Get_FBE();
    fprintf('%6d %7.4e %7.4e %7.4e\n', it, gam, res_curr, obj_curr);
end

% pack up results

out.name = opt.name;
out.message = msgTerm;
out.flag = flagTerm;
if it == opt.maxit
    out.x = cache_x.Get_Point();
else
    out.x = cache_x.Get_ProxGradStep();
end
out.iterations = it;
out.operations = ops;
if opt.report
    out.residual = residual(1, 1:it);
    out.objective = objective(1, 1:it);
    out.ts = ts(1, 1:it);
end
if opt.toRecord, out.record = record; end
out.gam = gam;
out.time = time;
out.cacheDir = cacheDir;

end
