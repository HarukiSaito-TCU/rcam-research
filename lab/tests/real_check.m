% Entry used by Test-MatlabJobRunner.ps1 -RealMatlab (copied to src/real_check.m of the temp repo).
% Writes what the runner set up into JOB_OUT\check.txt.
if exist('make_error', 'var') && make_error
    error('intentional test error');
end
fid = fopen(fullfile(JOB_OUT, 'check.txt'), 'w', 'n', 'UTF-8');
fprintf(fid, 'threads=%d\n', maxNumCompThreads);
fprintf(fid, 'max_workers=%s\n', getenv('MATLAB_MAX_WORKERS'));
fprintf(fid, 'tag=%s\n', tag);
fprintf(fid, 'list=%s\n', strtrim(sprintf('%g ', list)));
fprintf(fid, 'flag=%d %s\n', flag, class(flag));
fprintf(fid, 'n=%g\n', n);
fprintf(fid, 'pwd=%s\n', pwd);
fprintf(fid, 'version=%s\n', version);
fclose(fid);
