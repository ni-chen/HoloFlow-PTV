%                               FASTA.M
%      This method solves the problem
%                        minimize f(Ax)+g(x)
%   Where A is a matrix, f is differentiable, and both f and g are convex.
%   The algorithm is an adaptive/accelerated forward-backward splitting.
%   The user supplies function handles that evaluate 'f' and 'g'.  The user
%   also supplies a function that evaluates the gradient of 'f' and the
%   proximal operator of 'g', which is given by
%                proxg(z,t) = argmin t*g(x)+.5||x-z||^2.
%
%  Inputs:
%    A     : A matrix (or optionally a function handle to a method) that
%             returns A*x
%    At    : The adjoint (transpose) of 'A.' Optionally, a function handle
%             may be passed.
%    gradf : A function of z, computes the gradient of f at z
%    proxg : A function of z and t, the proximal operator of g with
%             stepsize t.
%    x0    : The initial guess, usually a vector of zeros
%    f     : A function of x, computes the value of f
%    g     : A function of x, computes the value of g
%    opts  : An optional struct with options.  The commonly used fields
%             of 'opts' are:
%               maxIters : (integer, default=1e4) The maximum number of iterations
%                               allowed before termination.
%               tol      : (double, default=1e-3) The stopping tolerance.
%                               A smaller value of 'tol' results in more
%                               iterations.
%               verbose  : (boolean, default=false)  If true, print out
%                               convergence information on each iteration.
%               recordObjective:  (boolean, default=false) Compute and
%                               record the objective of each iterate.
%               recordIterates :  (boolean, default=false) Record every
%                               iterate in a cell array.
%            To use these options, set the corresponding field in 'opts'.
%            For example:
%                      >> opts.tol=1e-8;
%                      >> opts.maxIters = 100;
%
%  Outputs:
%    sol  : The approximate solution
%    outs : A struct with convergence information
%    opts : A complete struct of options, containing all the values
%           (including defaults) that were used by the solver.
%
%   For more details, see the FASTA user guide, or the paper "A field guide
%   to forward-backward splitting with a FASTA implementation."
%
%   Copyright: Tom Goldstein, 2014.
%   Modifications: Kevin Mallery 2018

function [sol, outs, opts] = fasta(A, At, f, gradf, g, proxg, x0, opts)
    %%  Check whether we have function handles or matrices
    if ~isnumeric(A)
        assert(~isnumeric(At), 'If A is a function handle, then At must be a handle as well.')
    end

    %  If we have matrices, create functions so we only have to treat one case
    if isnumeric(A)
        At = @(x)A' * x;
        A = @(x) A * x;
    end

    %% Check preconditions, fill missing optional entries in 'opts'
    if ~exist('opts', 'var')% if user didn't pass this arg, then create it
        opts = [];
    end

    opts = setDefaults(opts, A, At, x0, gradf); % fill default values for options
    % Verify that At=A'
    % checkAdjoint(A,At,x0);

    if opts.verbose
        fprintf('%sFASTA:\tmode = %s\n\tmaxIters = %i,\ttol = %1.2d\n', ...
            opts.stringHeader, opts.mode, opts.maxIters, opts.tol);
    end

    %% Record some frequently used information from opts
    tau1 = opts.tau; % initial stepsize
    max_iters = opts.maxIters; % maximum iterations before automatic termination
    W = opts.window; % lookback window for non-montone line search
    % fprintf('tau = %f, L = %f\n', opts.tau, opts.L);

    %% Allocate memory
    residual = zeros(max_iters, 1); %  Residuals
    normalizedResid = zeros(max_iters, 1); %  Normalized residuals
    taus = zeros(max_iters, 1); %  Stepsizes
    fVals = zeros(max_iters, 1); %  The value of 'f', the smooth objective term
    error_norm = zeros(max_iters, 1);
    L1_norm = zeros(max_iters, 1);
    TV_norm = zeros(max_iters, 1);
    sparsity = zeros(max_iters, 1);
    objective = zeros(max_iters + 1, 1); %  The value of the objective function (f+g)
    funcValues = zeros(max_iters, 1); %  Values of the optional 'function' argument in 'opts'
    totalBacktracks = 0; %  How many times was backtracking activated?
    backtrackCount = 0; %  Backtracks on this iterations

    %% Intialize array values
    x1 = x0;
    d1 = A(x1);
    % f1       = f(d1);
    f1 = f(d1) + g(x1);

    try
        fVals(1) = gather(f1);
    catch
        fVals(1) = f1;
    end

    gradf1 = At(gradf(d1));
    % fprintf('Initial f = %f\n', f1);

    %%  Initialize additional storage required for FISTA
    if opts.accelerate
        x_accel1 = x0;
        d_accel1 = d1;
        alpha1 = 1;
    end

    %  To handle non-monotonicity
    maxResidual = -Inf; %  Stores the maximum value of the residual that has been seen. Used to evaluate stopping conditions.
    minObjectiveValue = Inf; %  Stores the best objective value that has been seen.  Used to return best iterate, rather than last iterate

    %  If user has chosen to record objective, then record initial value
    if opts.recordObjective%  record function values
        %     objective(1) = f1+g(x0);
        try
            objective(1) = gather(f1 + g(x0));
        catch
            objective(1) = f1 + g(x0);
        end

    end

    tau_initial = tau1;

    %     if opts.plot_steps
    %         stepsfigure = figure('units', 'normalized', 'outerposition', [0 0 0.5 0.8]);
    %     end

    tic; % Begin recording solve time
    %% Begin Loop
    for i = 1:max_iters
        %     fprintf('Iter %d:', i);
        % simply evaluate norms at begining always
        try
            error_norm(i) = gather(f(A(x1)));
            L1_norm(i) = gather(norm(x1(:), 1));
            TV_norm(i) = gather(TV(x1));
            sparsity(i) = gather(nnz(x1) / numel(x1));
        catch
            error_norm(i) = f(A(x1));
            L1_norm(i) = norm(x1(:), 1);
            TV_norm(i) = TV(x1);
            sparsity(i) = nnz(x1) / numel(x1);
        end

        %     L1_norm(i)  = norm(x1(:),1);
        %     TV_norm(i) = TV(x1);
        %     sparsity(i) = nnz(x1)/numel(x1);

        %         if opts.plot_steps
        %             cmbxz = max(abs(x1), [], 1);
        %             cmbxz = rot90(flipud(squeeze(cmbxz)), -1);
        %             cmbxy = max(abs(x1), [], 3);
        %
        %             figure(stepsfigure);
        %
        %             subplot(2, 2, 1);
        %             imagesc(cmbxy);
        %             axis image;
        %             xlabel('X'); ylabel('Y'); colorbar();
        %             title(sprintf('Iteration %d prebacktrack', i));
        %
        %             subplot(2, 2, 3);
        %             imagesc(cmbxz);
        %             axis image;
        %             xlabel('X'); ylabel('Z'); colorbar();
        %             title(sprintf('Iteration %d prebacktrack', i));
        %
        %             subplot(2, 2, [2, 4]);
        %             hold off;
        %             mu = 0.1;
        %             mu_tv = 0.01;
        %             objective_norm = error_norm + mu * L1_norm + mu_tv * TV_norm;
        %             semilogy(objective_norm);
        %             hold all;
        %             semilogy(error_norm);
        %             semilogy(mu * L1_norm);
        %             semilogy(mu_tv * TV_norm);
        %             semilogy(sparsity * 100);
        %             title('Norms');
        %             legend('Objective', '||Ax - b||_2^2', '||x||_1', 'TV(x)', 'Sparsity (%)', ...
        %                 'Location', 'northeast');
        %             %         legend('Objective', '||Ax - b||_2^2', '||x||_1');
        %             set(gca, 'YScale', 'log');
        %             grid on;
        %
        %             drawnow();
        %         end

        %%  Rename iterates relative to loop index.  "0" denotes index i, and "1" denotes index i+1
        x0 = x1; % x_i <--- x_{i+1}
        gradf0 = gradf1; % gradf0 is now $\nabla f (x_i)$
        %     tau1 = tau_initial;
        tau0 = tau1; % \tau_i <--- \tau_{i+1}

        %%  FBS step: obtain x_{i+1} from x_i
        x1hat = x0 - tau0 * gradf0; % Define \hat x_{i+1}
        x1 = proxg(x1hat, tau0); % Define x_{i+1}
        %         figure;show3d(x1, 0.3);  title(['iter = ' num2str(i)])
        %         disp('')

        %     if i == 2
        %         figure;
        %         cmbxz = max(abs(x1), [], 1);
        %         cmbxz = rot90(flipud(squeeze(cmbxz)),-1);
        %         imagesc(cmbxz);
        %         axis image;
        %         colorbar();
        %         title(sprintf('Iteration %d prebacktrack', i));
        %         drawnow();
        %     end
        %
        %     if (i == 1) && (backtrackCount == 0)
        %         figure;
        %         cmbxz = max(abs(x1), [], 1);
        %         cmbxz = rot90(flipud(squeeze(cmbxz)),-1);
        %         imagesc(cmbxz);
        %         axis image;
        %         colorbar();
        %         title(sprintf('Iteration %d backtrack %d', i, backtrackCount));
        %         drawnow();
        %     end

        %%  Non-monotone backtracking line search
        Dx = x1 - x0;
        d1 = A(x1);
        %     f1 = f(d1);
        f1 = f(d1) + g(x1);

        if opts.backtrack
            M = max(fVals(max(i - W, 1):max(i - 1, 1))); % Get largest of last 10 values of 'f'
            backtrackCount = 0;
            %  Note: 1e-12 is to quench rounding errors
            lim = real(dot(Dx(:), gradf0(:))) + norm(Dx(:))^2 / (2 * tau0);
            %         lim = 0;
            %         if (i ==1), fprintf('M = %f, lim = %f, sum = %f\n', M, lim, M+lim); end
            %         fprintf('M = %f, lim = %f, sum = %f\n', M, lim, M+lim);
            %         fprintf('f1 = %f, M+lim = %f\n', f1, M+lim);
            %         fprintf('Diff = %f, ratio = %f\n', f1-(M+lim), f1 / (M+lim));
            %         fprintf('  lim part1 = %f, part2 = %f\n',real(dot(Dx(:),gradf0(:))),norm(Dx(:))^2/(2*tau0));
            ratio = f1 / (M + lim);
            %         fprintf('   BT test: f1 = %f, M = %f, lim = %f, ratio = %f\n', f1, M, lim, ratio);
            while ((ratio > 1.01) || (ratio < 0)) && backtrackCount < 20% the backtracking loop
                fprintf('Begin backtrack iteration %d\n', backtrackCount);
                %             fprintf('    backtracking: Diff = %f, ratio = %f\n', f1-(M+lim), f1 / (M+lim));
                tau0 = tau0 * opts.stepsizeShrink; % shrink stepsize
                x1hat = x0 - tau0 * gradf0; % redo the FBS
                x1 = proxg(x1hat, tau0);
                d1 = A(x1);
                %             fprintf('         old f = %f', f1);
                old_f = f1;
                %             f1 = f(d1);
                f1 = f(d1) + g(x1);
                %             fprintf(', new = %f, change = %e\n', f1, old_f - f1);
                %             fprintf('         old M+lim = %f', M+lim);
                old = M + lim;
                Dx = x1 - x0;
                backtrackCount = backtrackCount + 1;
                lim = real(dot(Dx(:), gradf0(:))) + norm(Dx(:))^2 / (2 * tau0);
                ratio = f1 / (M + lim);
                %             fprintf(', new = %f, change = %e\n', M+lim, old - (M+lim));
            end

            %         if backtrackCount > 0
            %             fprintf('    end of backT: Diff = %f, ratio = %f\n', f1-(M+lim), f1 / (M+lim));
            %         end
            totalBacktracks = totalBacktracks + backtrackCount;
        end

        if opts.verbose && backtrackCount > 10
            fprintf('%s\tWARNING: excessive backtracking (%d steps), current stepsize is %f\n', ...
                opts.stringHeader, backtrackCount, tau0);
        end

        %% Record convergence information
        try
            taus(i) = gather(tau0); % stepsize
            residual(i) = gather(norm(Dx(:)) / tau0); % Estimate of the gradient, should be zero at solution
            maxResidual = gather(max(maxResidual, residual(i)));
            normalizer = gather(max(norm(gradf0(:)), norm(x1(:) - x1hat(:)) / tau0) + opts.eps_n);

            normalizedResid(i) = residual(i) / normalizer; % Normalized residual:  size of discrepancy between the two derivative terms, divided by the size of the terms

            fVals(i) = gather(f1);
            funcValues(i) = gather(opts.function(x0));

        catch
            taus(i) = tau0; % stepsize
            residual(i) = norm(Dx(:)) / tau0; % Estimate of the gradient, should be zero at solution
            maxResidual = max(maxResidual, residual(i));
            normalizer = max(norm(gradf0(:)), norm(x1(:) - x1hat(:)) / tau0) + opts.eps_n;
            normalizedResid(i) = residual(i) / normalizer; % Normalized residual:  size of discrepancy between the two derivative terms, divided by the size of the terms

            fVals(i) = f1;
            funcValues(i) = opts.function(x0);
        end

        %     normalizedResid(i) = residual(i)/normalizer;  % Normalized residual:  size of discrepancy between the two derivative terms, divided by the size of the terms
        %
        %     fVals(i) = f1;
        %     funcValues(i) = opts.function(x0);

        if opts.recordObjective%  Record function values

            try
                objective(i + 1) = gather(f1 + g(x1));
            catch
                objective(i + 1) = f1 + g(x1);
            end

            newObjectiveValue = objective(i + 1);
        else
            newObjectiveValue = residual(i); %  Use the residual to evalue quality of iterate if we don't have objective
        end

        if opts.recordIterates%  Record function values
            iterates{i} = x1;
        end

        if newObjectiveValue < minObjectiveValue% Methods is non-monotone:  Make sure to record best solution
            bestObjectiveIterate = x1;
            minObjectiveValue = newObjectiveValue;
            id_bestObjectiveIterate = i;
        end

        %% Test stopping criteria
        %  If we stop, then record information in the output struct
        if opts.stopNow(x1, i, residual(i), normalizedResid(i), maxResidual, opts) || i >= max_iters
            outs = [];
            outs.solveTime = toc;
            outs.residuals = residual(1:i);
            outs.stepsizes = taus(1:i);
            outs.normalizedResiduals = normalizedResid(1:i);
            outs.objective = objective(1:i);
            outs.funcValues = funcValues(1:i);
            outs.backtracks = totalBacktracks;
            outs.L = opts.L;
            outs.initialStepsize = opts.tau;
            outs.iterationCount = i;
            outs.fVals = fVals(1:i);

            if ~opts.recordObjective
                outs.objective = 'Not Recorded';
            end

            if opts.recordIterates
                outs.iterates = iterates;
            end

            outs.error_norm = error_norm;
            outs.L1_norm = L1_norm;
            outs.TV_norm = TV_norm;

            %         sol = bestObjectiveIterate;
            sol = x1;

            if opts.verbose
                %             fprintf('%s\tDone:  Returned result from iteration %i\n',opts.stringHeader, id_bestObjectiveIterate);
                fprintf('%s\tDone:  Returned result from iteration %i\n', opts.stringHeader, i);
                fprintf('%s\tDone:  time = %0.3f secs, iterations = %i\n', opts.stringHeader, toc, outs.iterationCount);
            end

            cmbxz = max(abs(x1), [], 1);
            cmbxz = rot90(flipud(squeeze(cmbxz)), -1);

            if ismatrix(cmbxz)
                figure;
                imagesc(cmbxz);
                axis image;
                colorbar();
                title(sprintf('Iteration %d (end)', i));
                drawnow();
            end

            return;
        end

        if opts.adaptive &&~opts.accelerate
            %% Compute stepsize needed for next iteration using BB/spectral method
            gradf1 = At(gradf(d1));
            Dg = gradf1 + (x1hat - x0) / tau0; % Delta_g, note that Delta_x was recorded above during backtracking
            dotprod = real(dot(Dx(:), Dg(:)));
            tau_s = norm(Dx(:))^2 / dotprod; %  First BB stepsize rule
            tau_m = dotprod / norm(Dg(:))^2; %  Alternate BB stepsize rule
            tau_m = max(tau_m, 0);

            if 2 * tau_m > tau_s%  Use "Adaptive" combination of tau_s and tau_m
                tau1 = tau_m;
            else
                tau1 = tau_s - .5 * tau_m; %  Experiment with this param
            end

            if tau1 <= 0 || isinf(tau1) || isnan(tau1)%  Make sure step is non-negative
                tau1 = tau0 * 1.5; % let tau grow, backtracking will kick in if stepsize is too big
            end

        end

        if opts.accelerate
            %% Use FISTA-type acceleration
            x_accel0 = x_accel1; %  Store the old iterates
            d_accel0 = d_accel1;
            alpha0 = alpha1;
            x_accel1 = x1;
            d_accel1 = d1;
            %  Check to see if the acceleration needs to be restarted
            if opts.restart && (x0(:) - x1(:))' * (x1(:) - x_accel0(:)) > 0
                alpha0 = 1;
                fprintf('restarted FISTA alpha parameter\n');
            end

            %  Calculate acceleration parameter
            alpha1 = (1 + sqrt(1 + 4 * alpha0^2)) / 2;
            %  Over-relax/predict
            x1 = x_accel1 + (alpha0 - 1) / alpha1 * (x_accel1 - x_accel0);
            d1 = d_accel1 + (alpha0 - 1) / alpha1 * (d_accel1 - d_accel0);

            %  Compute the gradient needed on the next iteration
            gradf1 = At(gradf(d1));
            %         fVals(i) = f(d1);
            try
                fVals(i) = gather(f(d1) + g(x1));
            catch
                fVals(i) = f(d1) + g(x1);
            end

            tau1 = tau0;
        end

        if ~opts.adaptive &&~opts.accelerate
            gradf1 = At(gradf(d1));
            tau1 = tau0;
        end

        %     intensity = abs(reshape(MyV2C(x1), 128, 128, 256));
        %     minI = min(intensity(:));
        %     maxI = max(intensity(:));
        %     intensity = (intensity - minI) / (maxI - minI);
        %     cmbxy = max(intensity, [], 3);
        %     cmbxz = max(intensity, [], 1);
        %     cmbxz = rot90(flipud(squeeze(cmbxz)),-1);
        %     out_pathn = '/home/safl/Documents/Kevin/Development/InverseHolography/Matlab_Benchmarking/Outputs/';
        %     imwrite(cmbxy, sprintf([out_pathn, 'Iterations/cmbxy_it%04d.tif'], i));
        %     imwrite(cmbxz, sprintf([out_pathn, 'Iterations/cmbxz_it%04d.tif'], i));
        %     if i == max_iters-1
        %         imwrite(cmbxy, sprintf([out_pathn, 'cmbxy_final.tif']));
        %         imwrite(cmbxz, sprintf([out_pathn, 'cmbxz_final.tif']));
        %     end

        if opts.verbose > 1
            fprintf('%s%d: resid = %0.2d, f = %e, backtrack = %d/%d, tau = %d', ...
                opts.stringHeader, i, residual(i), fVals(i), backtrackCount, totalBacktracks, tau0);

            if opts.recordObjective
                fprintf(', objective = %d\n', objective(i + 1));
            else
                fprintf('\n');
            end

            fprintf('Sparsity = %f\n', nnz(x1(:)) / numel(x1(:)));
            %         fprintf('    f(d1) = %f, g(x1) = %f\n', f(d1), g(x1));
        end

    end

end

function checkAdjoint(A, At, x0)
    x = randn(size(x0));
    Ax = A(x);
    y = randn(size(Ax));
    Aty = At(y);
    innerProduct1 = Ax(:)' * y(:);
    innerProduct2 = x(:)' * Aty(:);

    if ~isreal(Aty(:))
        x = complex(randn(size(x0)), randn(size(x0)));
        Ax = A(x);
        y = complex(randn(size(Ax)), randn(size(Ax)));
        Aty = At(y);
    end

    % innerProduct1 = real(Ax(:))'*real(y(:)) + imag(Ax(:))'*imag(y(:));
    % innerProduct2 = real(x(:))'*real(Aty(:)) + imag(x(:))'*imag(Aty(:));
    innerProduct1 = real(Ax(:)' * y(:));
    innerProduct2 = real(x(:)' * Aty(:));
    error = abs(innerProduct1 - innerProduct2) ...
        / max(abs(innerProduct1), abs(innerProduct2));
    % fprintf('innerProduct1 = %f\n', innerProduct1);
    % fprintf('innerProduct2 = %f\n', innerProduct2);
    % fprintf('adjoint error = %f\n', error);
    assert(error < 1e-9, '"At" is not the adjoint of "A".  Check the definitions of these operators.');

end

%% Fill in the struct of options with the default values
function opts = setDefaults(opts, A, At, x0, gradf)
    %  maxIters: The maximum number of iterations
    if ~isfield(opts, 'maxIters')
        opts.maxIters = 1000;
    end

    % tol:  The relative decrease in the residuals before the method stops
    if ~isfield(opts, 'tol')% Stopping tolerance
        opts.tol = 1e-3;
    end

    % verbose:  If 'true' then print status information on every iteration
    if ~isfield(opts, 'verbose')
        opts.verbose = false;
    end

    % recordObjective:  If 'true' then evaluate objective at every iteration
    if ~isfield(opts, 'recordObjective')
        opts.recordObjective = false;
    end

    % recordIterates:  If 'true' then record iterates in cell array
    if ~isfield(opts, 'recordIterates')
        opts.recordIterates = false;
    end

    % adaptive:  If 'true' then use adaptive method.
    if ~isfield(opts, 'adaptive')%  is Adaptive?
        opts.adaptive = true;
    end

    % accelerate:  If 'true' then use FISTA-type adaptive method.
    if ~isfield(opts, 'accelerate')%  is Accelerated?
        opts.accelerate = false;
    end

    % restart:  If 'true' then restart the acceleration of FISTA.
    %   This only has an effect when opts.accelerate=true
    if ~isfield(opts, 'restart')%  use restart?
        opts.restart = true;
    end

    % backtrack:  If 'true' then use backtracking line search
    if ~isfield(opts, 'backtrack')
        opts.backtrack = true;
    end

    % stepsizeShrink:  Coefficient used to shrink stepsize when backtracking
    % kicks in
    if ~isfield(opts, 'stepsizeShrink')
        opts.stepsizeShrink = 0.2; % The adaptive method can expand the stepsize, so we choose an aggressive value here

        if ~opts.adaptive || opts.accelerate
            opts.stepsizeShrink = 0.5; % If the stepsize is monotonically decreasing, we don't want to make it smaller than we need
        end

    end

    %  Create a mode string that describes which variant of the method is used
    opts.mode = 'plain';

    if opts.adaptive
        opts.mode = 'adaptive';
    end

    if opts.accelerate

        if opts.restart
            opts.mode = 'accelerated(FISTA)+restart';
        else
            opts.mode = 'accelerated(FISTA)';
        end

    end

    % W:  The window to look back when evaluating the max for the line search
    if ~isfield(opts, 'window')% Stopping tolerance
        opts.window = 10;
    end

    % eps_r:  Epsilon to prevent ratio residual from dividing by zero
    if ~isfield(opts, 'eps_r')% Stopping tolerance
        opts.eps_r = 1e-8;
    end

    % eps_n:  Epsilon to prevent normalized residual from dividing by zero
    if ~isfield(opts, 'eps_n')% Stopping tolerance
        opts.eps_n = 1e-8;
    end

    %  L:  Lipschitz constant for smooth term.  Only needed if tau has not been
    %   set, in which case we need to approximate L so that tau can be
    %   computed.
    if (~isfield(opts, 'L') || opts.L <= 0) && (~isfield(opts, 'tau') || opts.tau <= 0)

        for i = 1
            x1 = randn(size(x0));
            x2 = randn(size(x0));
            gradf1 = At(gradf(A(x1)));
            gradf2 = At(gradf(A(x2)));
            opts.L = norm(gradf1(:) - gradf2(:)) / norm(x2(:) - x1(:));
            opts.L = max(opts.L, 1e-6);
            opts.tau = 2 / opts.L / 10;
            %         opts.tau = 2/opts.L;
            fprintf('random L = %f, tau = %f\n', opts.L, opts.tau);
        end

    end

    %  Set tau if L was set by user
    if (~isfield(opts, 'tau') || opts.tau <= 0)
        opts.tau = 1.0 / opts.L;
        %         opts.tau = 2 / opts.L / 10;
    else
        opts.L = 1 / opts.tau;
        %         opts.L = 2 / opts.tau / 10;
    end

    assert(opts.tau > 0, ['Invalid step size: ' num2str(opts.tau)]);

    % function:  An optional function that is computed and stored after every
    % iteration
    if ~isfield(opts, 'function')% This functions gets evaluated on each iterations, and results are stored
        opts.function = @(x) 0;
    end

    % stringHeader:  Append this string to beginning of all output
    if ~isfield(opts, 'stringHeader')% This functions gets evaluated on each iterations, and results are stored
        opts.stringHeader = '';
    end

    %  The code below is for stopping rules
    %  The field 'stopNow' is a function that returns 'true' if the iteration
    %  should be terminated.  The field 'stopRule' is a string that allows the
    %  user to easily choose default values for 'stopNow'.  The default
    %  stopping rule terminates when the relative residual gets small.
    if isfield(opts, 'stopNow')
        opts.stopRule = 'custom';
    end

    if ~isfield(opts, 'stopRule')
        opts.stopRule = 'hybridResidual';
    end

    if strcmp(opts.stopRule, 'residual')
        opts.stopNow = @(x1, iter, resid, normResid, maxResidual, opts) resid < opts.tol;
    end

    if strcmp(opts.stopRule, 'iterations')
        opts.stopNow = @(x1, iter, resid, normResid, maxResidual, opts) iter > opts.maxIters;
    end

    % Stop when normalized residual is small
    if strcmp(opts.stopRule, 'normalizedResidual')
        opts.stopNow = @(x1, iter, resid, normResid, maxResidual, opts) normResid < opts.tol;
    end

    % Divide by residual at iteration k by maximum residual over all iterations.
    % Terminate when this ratio gets small.
    if strcmp(opts.stopRule, 'ratioResidual')
        opts.stopNow = @(x1, iter, resid, normResid, maxResidual, opts) resid / (maxResidual + opts.eps_r) < opts.tol;
    end

    % Default behavior:  Stop if EITHER normalized or ration residual is small
    if strcmp(opts.stopRule, 'hybridResidual')
        opts.stopNow = @(x1, iter, resid, normResid, maxResidual, opts) ...
            resid / (maxResidual + opts.eps_r) < opts.tol ...
            || normResid < opts.tol;
    end

    assert(isfield(opts, 'stopNow'), ['Invalid choice for stopping rule: ' opts.stopRule]);

end
