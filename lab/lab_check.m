% Check job for the lab PC setup (docs/lab_setup.md, step 7). Run it through a job file:
%   {"id": "20261014_lab_check", "entry": "lab/lab_check.m"}
%   {"id": "20261014_lab_check_error", "entry": "lab/lab_check.m", "vars": {"make_error": true}}
% Writes JOB_OUT/check.txt; with make_error = true it fails on purpose (state "failed", error in matlab.log).
if exist('make_error', 'var') && make_error
    error('lab_check:intentional', 'intentional test error (make_error = true)');
end
fid = fopen(fullfile(JOB_OUT, 'check.txt'), 'w', 'n', 'UTF-8');
fprintf(fid, 'maxNumCompThreads=%d\n', maxNumCompThreads);
fprintf(fid, 'MATLAB_MAX_WORKERS=%s\n', getenv('MATLAB_MAX_WORKERS'));
fprintf(fid, 'JOB_ID=%s\n', JOB_ID);
fprintf(fid, 'JOB_OUT=%s\n', JOB_OUT);
fprintf(fid, 'version=%s\n', version);
fprintf(fid, 'time=%s\n', char(datetime('now')));
fclose(fid);
