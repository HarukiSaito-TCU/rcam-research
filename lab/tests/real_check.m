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
fprintf(fid, 'cache=%s\n', Simulink.fileGenControl('get', 'CacheFolder'));
% simulate a small model saved next to this file (a git-tracked folder): its caches must not land here
mdl = 'mjr_check_model';
new_system(mdl);
add_block('simulink/Sources/Constant', [mdl '/C']);
add_block('simulink/Sinks/Out1', [mdl '/O']);
add_line(mdl, 'C/1', 'O/1');
mdlFile = fullfile(fileparts(mfilename('fullpath')), [mdl '.slx']);
save_system(mdl, mdlFile);
out = sim(mdl, 'StopTime', '1');
close_system(mdl, 0);
delete(mdlFile);
fprintf(fid, 'sim=ok %d\n', numel(out.tout) > 0);
fclose(fid);
